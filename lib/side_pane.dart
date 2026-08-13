import 'package:flutter/material.dart';

/// ============================================================================
///  THE PANES DOWN EITHER SIDE
/// ============================================================================
///  Every page in this app is a drawing with a column of controls beside it —
///  the navigation rail on the left, the device palette, the sheet list, the
///  location list on the right — and every one of those columns was a fixed
///  width nobody could argue with. On a laptop that is most of the window
///  spent on a list of names; on a 34" panel it is a 320-pixel strip beside a
///  metre of empty canvas.
///
///  This is the one widget both sides use, so a pane behaves the same wherever
///  it turns up:
///
///    * DRAG THE EDGE to resize it. The divider between the pane and the page
///      IS the handle — there is no second thing to aim at — and the cursor
///      changes over it so it can be found without being told about.
///    * FOLD IT AWAY with the chevron. A folded pane leaves a thin strip with
///      the chevron pointing back, because a control that vanishes completely
///      is a control nobody finds again.
///
///  The width and the folded state live in this widget's own State: they are
///  about the window in front of somebody right now, not about the room, and
///  writing them into the room's sidecar would put a colleague's screen size
///  in the project file. They survive tab switches through [storageKey], which
///  is what a [PageStorage] bucket is for.
/// ============================================================================

enum PaneSide { left, right }

/// The same idea across the bottom of a page: a panel whose TOP edge is the
/// handle.
///
/// Its own class rather than a fourth [PaneSide], because a bottom pane is a
/// Column where a side pane is a Row and sharing that through a flag makes
/// both harder to read than either is apart.
///
/// No fold button here: the pages that use one already show it only while
/// something is being edited, so "hide it" is the switch that put it there.
class BottomPane extends StatefulWidget {
  final Widget child;

  /// Remembers the height across rebuilds of the page.
  final String storageKey;

  final double initialHeight;
  final double minHeight;
  final double maxHeight;

  const BottomPane({
    super.key,
    required this.child,
    required this.storageKey,
    this.initialHeight = 190,
    this.minHeight = 90,
    this.maxHeight = 620,
  });

  @override
  State<BottomPane> createState() => _BottomPaneState();
}

class _BottomPaneState extends State<BottomPane> {
  late double _height = widget.initialHeight;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: 'bottom_pane_${widget.storageKey}',
    );
    if (stored is num) {
      _height = stored.toDouble().clamp(widget.minHeight, widget.maxHeight);
    }
  }

  void _remember() => PageStorage.maybeOf(context)?.writeState(
        context,
        _height,
        identifier: 'bottom_pane_${widget.storageKey}',
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.resizeUpDown,
          child: GestureDetector(
            key: ValueKey('pane_grip_${widget.storageKey}'),
            behavior: HitTestBehavior.opaque,
            // Dragging the top edge UP makes the panel taller, which is the
            // direction the edge itself moves.
            onVerticalDragUpdate: (d) {
              setState(() {
                _height = (_height - d.delta.dy)
                    .clamp(widget.minHeight, widget.maxHeight);
              });
              _remember();
            },
            onDoubleTap: () {
              setState(() => _height = widget.initialHeight);
              _remember();
            },
            child: Tooltip(
              message: 'Drag to resize · double-click for the default height',
              child: SizedBox(
                height: 9,
                width: double.infinity,
                child: Center(
                  child: Container(
                    height: 3,
                    width: 44,
                    decoration: BoxDecoration(
                      color: theme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: _height, child: widget.child),
      ],
    );
  }
}

/// How wide the strip left behind when a pane is folded away.
const double kFoldedPaneWidth = 26;

class SidePane extends StatefulWidget {
  final PaneSide side;

  /// Named on the header bar and on the folded strip, so a folded pane still
  /// says what is inside it.
  final String title;

  final Widget child;

  final double initialWidth;
  final double minWidth;
  final double maxWidth;

  /// Starts folded. The default is open: a pane somebody has to go and find on
  /// first use is a pane they never find.
  final bool initiallyOpen;

  /// Remembers the width and the fold across rebuilds of the page — pass
  /// something stable per pane ('floor_plan_side').
  final String storageKey;

  const SidePane({
    super.key,
    required this.side,
    required this.title,
    required this.child,
    required this.storageKey,
    this.initialWidth = 320,
    this.minWidth = 180,
    this.maxWidth = 620,
    this.initiallyOpen = true,
  });

  @override
  State<SidePane> createState() => _SidePaneState();
}

class _SidePaneState extends State<SidePane> {
  late double _width = widget.initialWidth;
  late bool _open = widget.initiallyOpen;

  /// Restored on the first build, once there is a [PageStorage] to read.
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: 'side_pane_${widget.storageKey}',
    );
    if (stored is Map) {
      final w = (stored['w'] as num?)?.toDouble();
      if (w != null) _width = w.clamp(widget.minWidth, widget.maxWidth);
      _open = stored['open'] != false;
    }
  }

  void _remember() {
    PageStorage.maybeOf(context)?.writeState(
      context,
      {'w': _width, 'open': _open},
      identifier: 'side_pane_${widget.storageKey}',
    );
  }

  void _resize(double delta) {
    setState(() {
      // Dragging the right pane's edge LEFT makes it wider, which is the
      // opposite of the left pane and the reason this is not one sum.
      _width = (widget.side == PaneSide.right ? _width - delta : _width + delta)
          .clamp(widget.minWidth, widget.maxWidth);
    });
    _remember();
  }

  void _toggle() {
    setState(() => _open = !_open);
    _remember();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_open) return _folded(theme);

    final pane = SizedBox(
      width: _width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme),
          const Divider(height: 1),
          Expanded(child: widget.child),
        ],
      ),
    );

    final grip = _grip(theme);
    return Row(
      children: widget.side == PaneSide.right ? [grip, pane] : [pane, grip],
    );
  }

  /// The divider between the pane and the page, which is also the handle.
  Widget _grip(ThemeData theme) => MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          key: ValueKey('pane_grip_${widget.storageKey}'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => _resize(d.delta.dx),
          // Back to the width it opened at. A pane dragged to a silly size
          // needs a way back that is not "guess where it was".
          onDoubleTap: () {
            setState(() => _width = widget.initialWidth);
            _remember();
          },
          child: Tooltip(
            message: 'Drag to resize · double-click for the default width',
            child: SizedBox(
              width: 7,
              child: Center(
                child: Container(
                  width: 1,
                  color: theme.dividerColor,
                ),
              ),
            ),
          ),
        ),
      );

  Widget _header(ThemeData theme) => SizedBox(
        height: 30,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.title,
                style: theme.textTheme.labelMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              key: ValueKey('pane_fold_${widget.storageKey}'),
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              icon: Icon(
                widget.side == PaneSide.right
                    ? Icons.chevron_right
                    : Icons.chevron_left,
              ),
              tooltip: 'Hide this panel',
              onPressed: _toggle,
            ),
            const SizedBox(width: 2),
          ],
        ),
      );

  /// What is left when the pane is folded: a strip the width of a scrollbar,
  /// with the way back on it.
  Widget _folded(ThemeData theme) => SizedBox(
        width: kFoldedPaneWidth,
        child: Column(
          children: [
            IconButton(
              key: ValueKey('pane_unfold_${widget.storageKey}'),
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 30),
              icon: Icon(
                widget.side == PaneSide.right
                    ? Icons.chevron_left
                    : Icons.chevron_right,
              ),
              tooltip: 'Show ${widget.title}',
              onPressed: _toggle,
            ),
            // The name, read bottom-to-top up the strip, so a folded pane is
            // still identifiable when three of them are folded.
            Expanded(
              child: GestureDetector(
                onTap: _toggle,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Center(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
