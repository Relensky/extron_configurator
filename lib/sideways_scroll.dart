import 'package:material_ui/material_ui.dart';

/// ============================================================================
///  SCROLLING SIDEWAYS FROM THE KEYBOARD
/// ============================================================================
///  Flutter scrolls with the arrow keys only when the scroll view itself has
///  the keyboard, and with nothing selected nothing does - so a table wider
///  than the window could only be moved with the scrollbar or Shift and the
///  wheel. The sideways scrollers register here, and Left and Right, when
///  nothing else answers them, scroll the one under the pointer (else the
///  innermost one on screen that can move).
/// ============================================================================

class SidewaysScrollRegistry {
  SidewaysScrollRegistry._();

  static final List<ScrollController> _all = [];
  static ScrollController? _hovered;

  static void _add(ScrollController c) => _all.add(c);

  static void _remove(ScrollController c) {
    _all.remove(c);
    if (identical(_hovered, c)) _hovered = null;
  }

  static bool _movable(ScrollController c) =>
      c.hasClients &&
      c.positions.length == 1 &&
      c.position.maxScrollExtent > 0;

  /// The scroller Left and Right move, or null when none can.
  static ScrollController? get target {
    final hovered = _hovered;
    if (hovered != null && _movable(hovered)) return hovered;
    // Registered parent first, so the last movable one is the innermost.
    for (final c in _all.reversed) {
      if (_movable(c)) return c;
    }
    return null;
  }
}

/// Registers [controller] - a horizontal scroll view's - for the arrow keys,
/// and marks it as the one to move while the pointer is over [child].
class SidewaysScrollTarget extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  const SidewaysScrollTarget({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<SidewaysScrollTarget> createState() => _SidewaysScrollTargetState();
}

class _SidewaysScrollTargetState extends State<SidewaysScrollTarget> {
  @override
  void initState() {
    super.initState();
    SidewaysScrollRegistry._add(widget.controller);
  }

  @override
  void didUpdateWidget(SidewaysScrollTarget old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      SidewaysScrollRegistry._remove(old.controller);
      SidewaysScrollRegistry._add(widget.controller);
    }
  }

  @override
  void dispose() {
    SidewaysScrollRegistry._remove(widget.controller);
    super.dispose();
  }

  // The innermost region under the pointer is entered last and wins; leaving
  // it hands back to whichever region the pointer is still over on the next
  // move.
  @override
  Widget build(BuildContext context) => MouseRegion(
    opaque: false,
    onEnter: (_) => SidewaysScrollRegistry._hovered = widget.controller,
    onHover: (_) {
      if (!identical(SidewaysScrollRegistry._hovered, widget.controller) &&
          SidewaysScrollRegistry._hovered == null) {
        SidewaysScrollRegistry._hovered = widget.controller;
      }
    },
    onExit: (_) {
      if (identical(SidewaysScrollRegistry._hovered, widget.controller)) {
        SidewaysScrollRegistry._hovered = null;
      }
    },
    child: widget.child,
  );
}

/// Left or right, by a step, on [SidewaysScrollRegistry.target].
class ScrollSidewaysIntent extends Intent {
  final bool right;
  const ScrollSidewaysIntent({required this.right});
}

class ScrollSidewaysAction extends Action<ScrollSidewaysIntent> {
  /// How far one press moves, in logical pixels.
  static const double step = 80;

  /// Off while a text box has the keyboard: there Left and Right move the
  /// cursor.
  static bool _typing() {
    final context = primaryFocus?.context;
    if (context == null) return false;
    if (context is StatefulElement && context.state is EditableTextState) {
      return true;
    }
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  @override
  bool isEnabled(ScrollSidewaysIntent intent) =>
      !_typing() && SidewaysScrollRegistry.target != null;

  @override
  Object? invoke(ScrollSidewaysIntent intent) {
    final c = SidewaysScrollRegistry.target;
    if (c == null) return null;
    final p = c.position;
    final to = (p.pixels + (intent.right ? step : -step))
        .clamp(p.minScrollExtent, p.maxScrollExtent);
    c.jumpTo(to);
    return null;
  }
}
