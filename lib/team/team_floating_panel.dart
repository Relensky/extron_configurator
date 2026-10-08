import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import 'team_host.dart';

// ============================================================================
// [FEATURE - FLOATING PANELS]: the shared chrome for an in-app window —
// draggable title bar, resize grip, and the pop-out/close controls.
//
// One frame for every floating panel (the network trace and the four docked
// pop-outs), so drag behavior, clamping and geometry memory are defined once
// rather than re-implemented per panel and drifting.
//
// ----------------------------------------------------------------------------
// [PERFORMANCE - DRAG SMOOTHNESS]
//
// The trace panel used to hold its position in State and call setState on
// every onPanUpdate. A pointer move produces one of those per frame, and each
// one rebuilt the ENTIRE panel — title bar, toolbar, and the ListView of log
// lines underneath. Dragging a window therefore cost a full rebuild of the
// most expensive thing in it, per frame, which is exactly the roughness you
// feel in the hand.
//
// Here the geometry lives in ValueNotifiers and the body is passed as the
// `child` of the ValueListenableBuilders, so it is captured ONCE and handed
// back by identity on every drag frame. Element.updateChild short-circuits on
// an identical widget, so a drag now relayouts the panel without rebuilding
// anything inside it. The same applies to the resize grip.
// ============================================================================

/// Where each panel was last left, by key, so reopening one puts it back
/// instead of dropping it on the default spot over whatever is already there.
///
/// [WINDOW MEMORY]: also kept across restarts (window_memory.json). This used
/// to be session-only, for fear of a remembered spot landing off a monitor
/// that had changed - but the app is now always laid out at 1920x1080 and
/// scaled to the monitor (AppScaleFrame), and [_fit]/[_clamp] keep the whole
/// panel inside the window, so a remembered spot is always one you can find.
final Map<String, (Offset, Size)> _rememberedGeometry = {};

/// Where panel [key] was left, from the host's settings ('panel.<key>':
/// {x, y, w, h}).
(Offset, Size)? _savedGeometry(String key) {
  final p = TeamHost.readSetting('panel.$key');
  if (p is! Map) return null;
  final x = p['x'], y = p['y'], w = p['w'], h = p['h'];
  if (x is! num || y is! num || w is! num || h is! num) return null;
  if (w <= 0 || h <= 0) return null;
  return (Offset(x.toDouble(), y.toDouble()), Size(w.toDouble(), h.toDouble()));
}

class TeamFloatingPanelFrame extends StatefulWidget {
  const TeamFloatingPanelFrame({
    super.key,
    required this.geometryKey,
    required this.title,
    required this.child,
    required this.onClose,
    this.titleBarActions = const [],
    this.initialSize = const Size(620, 400),
    this.minSize = const Size(320, 200),
    this.liveResize = false,
  });

  /// Resize as the grip moves, the way the configurator's chat does, rather
  /// than outlining the new size and taking it on release. For panels whose
  /// contents lay out quickly (the team chat).
  final bool liveResize;

  /// Identifies this panel for position memory; usually the PopoutType name.
  final String geometryKey;

  final String title;

  /// The panel body. Built by the caller and never rebuilt by a drag.
  final Widget child;

  final VoidCallback onClose;

  /// Extra title-bar controls, placed before the close button.
  final List<Widget> titleBarActions;

  final Size initialSize;
  final Size minSize;

  @override
  State<TeamFloatingPanelFrame> createState() => _TeamFloatingPanelFrameState();
}

class _TeamFloatingPanelFrameState extends State<TeamFloatingPanelFrame> {
  late final ValueNotifier<Offset> _position;
  late final ValueNotifier<Size> _size;

  /// [PERFORMANCE - RESIZE]: the size being dragged to, drawn as an outline;
  /// the panel itself takes it once the grip is let go, so its contents lay
  /// out once instead of on every step of the drag.
  final ValueNotifier<Size?> _resizeTo = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    final remembered = _rememberedGeometry[widget.geometryKey] ??
        _savedGeometry(widget.geometryKey);
    // Cascade each new panel a little so opening two does not stack them
    // exactly on top of one another.
    final int index = _rememberedGeometry.length;
    _position = ValueNotifier(
        remembered?.$1 ?? Offset(100 + index * 28.0, 100 + index * 28.0));
    _size = ValueNotifier(remembered?.$2 ?? widget.initialSize);
  }

  @override
  void dispose() {
    _keepGeometry();
    _position.dispose();
    _size.dispose();
    _resizeTo.dispose();
    super.dispose();
  }

  /// The size the panel is shown at: the size it was given, shrunk to fit
  /// the app window when the window is smaller. Fitted on display only, so
  /// the window growing again brings the panel back to the size it was left.
  Size _fit(Size size, Size screen) => Size(
        size.width.clamp(0.0, screen.width),
        size.height.clamp(0.0, screen.height),
      );

  /// Keeps the whole panel on screen however the app window is resized or
  /// the panel dragged. [size] is the fitted size (see [_fit]).
  Offset _clamp(Offset pos, Size screen, Size size) {
    return Offset(
      pos.dx.clamp(0.0, (screen.width - size.width).clamp(0.0, screen.width)),
      pos.dy
          .clamp(0.0, (screen.height - size.height).clamp(0.0, screen.height)),
    );
  }

  /// Remembers where the panel is now, for this session and the next.
  void _keepGeometry() {
    _rememberedGeometry[widget.geometryKey] = (_position.value, _size.value);
    TeamHost.writeSetting('panel.${widget.geometryKey}', {
      'x': _position.value.dx.round(),
      'y': _position.value.dy.round(),
      'w': _size.value.width.round(),
      'h': _size.value.height.round(),
    });
  }

  void _drag(DragUpdateDetails details) {
    final screen = MediaQuery.of(context).size;
    // From where the panel is SHOWN, so a position stored off screen does
    // not swallow the first part of the drag.
    final size = _fit(_size.value, screen);
    _position.value = _clamp(
        _clamp(_position.value, screen, size) + details.delta, screen, size);
  }

  void _resize(DragUpdateDetails details) {
    final screen = MediaQuery.of(context).size;
    final from = _resizeTo.value ?? _fit(_size.value, screen);
    final to = Size(
      // The minimum gives way to a window smaller than it (clamp throws
      // when its lower bound is above its upper one).
      (from.width + details.delta.dx)
          .clamp(math.min(widget.minSize.width, screen.width), screen.width),
      (from.height + details.delta.dy)
          .clamp(math.min(widget.minSize.height, screen.height), screen.height),
    );
    if (widget.liveResize) {
      _size.value = to;
    } else {
      _resizeTo.value = to;
    }
  }

  void _endResize() {
    final to = _resizeTo.value;
    _resizeTo.value = null;
    if (to != null) _size.value = to;
    _keepGeometry();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Built once per real rebuild and handed to the geometry builders below as
    // a constant `child`; see the drag-smoothness note at the top.
    final Widget body = Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.black87 : Colors.white,
          border: Border.all(color: isDark ? Colors.white24 : Colors.black26),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- DRAGGABLE TITLE BAR ---
            GestureDetector(
              // From the moment the button goes down: the default waits for
              // a few pixels of movement first, which reads as a jump.
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: _drag,
              onPanEnd: (_) => _keepGeometry(),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  color: isDark ? Colors.grey[850] : Colors.grey[300],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ...widget.titleBarActions,
                          const SizedBox(width: 16),
                          TeamFloatingPanelIcon(
                            icon: Icons.close,
                            tooltip: 'Close panel',
                            onTap: widget.onClose,
                            color: Colors.redAccent,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // --- BODY ---
            Expanded(child: widget.child),

            // --- RESIZE GRIP ---
            GestureDetector(
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: _resize,
              onPanEnd: (_) => _endResize(),
              onPanCancel: _endResize,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeDownRight,
                child: Container(
                  height: 16,
                  color: isDark ? Colors.grey[900] : Colors.grey[200],
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 4),
                  child: const Icon(Icons.drag_indicator,
                      size: 12, color: Colors.grey),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return ListenableBuilder(
      listenable: Listenable.merge([_position, _size]),
      builder: (context, child) {
        // A window resize can strand a panel off screen or leave it bigger
        // than the window, so the stored geometry is fitted again for
        // display. Fitted on READ rather than written back: assigning to the
        // notifiers here would notify their own listener mid-build, which is a
        // setState during build.
        final screen = MediaQuery.of(context).size;
        final size = _fit(_size.value, screen);
        final visible = _clamp(_position.value, screen, size);
        return Positioned(
          left: visible.dx,
          top: visible.dy,
          width: size.width,
          height: size.height,
          child: child!,
        );
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // [PERFORMANCE - DRAG]: its own layer, so moving the panel
          // shifts a finished picture rather than repainting it.
          Positioned.fill(child: RepaintBoundary(child: body)),
          // The size a resize will land on, while the grip is held.
          ValueListenableBuilder<Size?>(
            valueListenable: _resizeTo,
            builder: (context, to, _) => to == null
                ? const SizedBox.shrink()
                : Positioned(
                    left: 0,
                    top: 0,
                    width: to.width,
                    height: to.height,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withValues(alpha: 0.06),
                          border:
                              Border.all(color: Colors.blueAccent, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The small icon-button style every floating panel's title bar uses.
class TeamFloatingPanelIcon extends StatelessWidget {
  const TeamFloatingPanelIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Icon(icon, size: 16, color: color),
        ),
      );
}
