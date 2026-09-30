import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Lays [child] out at least [minWidth] wide, scrolling sideways with a
/// visible scrollbar when the window is narrower than that.
///
/// The tree is the same shape at every width, so crossing [minWidth] while a
/// window is resized keeps whatever state the page holds.
class MinWidthScroll extends StatefulWidget {
  final double minWidth;
  final Widget child;

  const MinWidthScroll({
    super.key,
    required this.minWidth,
    required this.child,
  });

  @override
  State<MinWidthScroll> createState() => _MinWidthScrollState();
}

class _MinWidthScrollState extends State<MinWidthScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? math.max(widget.minWidth, constraints.maxWidth)
            : widget.minWidth;
        return Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          child: ScrollConfiguration(
            // Our own scrollbar only; the page below gets its usual ones back.
            behavior: behavior.copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: width,
                height: constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : null,
                child: ScrollConfiguration(
                  behavior: behavior,
                  child: widget.child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// An X that empties [controller], shown only while it holds text. Meant for
/// an [InputDecoration.suffixIcon].
class ClearFieldButton extends StatelessWidget {
  final TextEditingController controller;

  /// Called after the text is cleared, for fields whose owner filters on
  /// `onChanged` (clearing a controller does not fire it).
  final VoidCallback? onCleared;

  final double size;

  const ClearFieldButton({
    super.key,
    required this.controller,
    this.onCleared,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (value.text.isEmpty) return const SizedBox.shrink();
        return IconButton(
          tooltip: 'Clear',
          icon: Icon(Icons.close, size: size),
          visualDensity: VisualDensity.compact,
          onPressed: () {
            controller.clear();
            onCleared?.call();
          },
        );
      },
    );
  }
}

/// Room left at the bottom of every page for the Screenshot and Export
/// buttons that float over the lower right. Without it the last row's
/// right-hand buttons, a delete or an edit, can sit under them with no way
/// to scroll clear. The buttons' own height plus the Scaffold's margin.
const double kFloatingButtonClearance = 150;
