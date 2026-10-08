import 'package:material_ui/material_ui.dart';

/// [showDialog] whose box can be dragged out of the way of the sheet behind
/// it. Drags start on any plain part of the box; fields, sliders and lists
/// inside keep their own drags.
Future<T?> showMovableDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    builder: (ctx) => MovableDialog(child: builder(ctx)),
  );
}

/// Wraps a dialog so it can be moved by dragging.
class MovableDialog extends StatefulWidget {
  final Widget child;

  const MovableDialog({super.key, required this.child});

  @override
  State<MovableDialog> createState() => _MovableDialogState();
}

class _MovableDialogState extends State<MovableDialog> {
  Offset _offset = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Transform.translate(
      offset: _offset,
      child: MouseRegion(
        // Only over the box itself, not the clear space around it.
        hitTestBehavior: HitTestBehavior.deferToChild,
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onPanUpdate: (d) => setState(() {
            // Loose bound so the box can't be lost off screen.
            final o = _offset + d.delta;
            _offset = Offset(
              o.dx.clamp(-size.width * 0.8, size.width * 0.8),
              o.dy.clamp(-size.height * 0.8, size.height * 0.8),
            );
          }),
          child: widget.child,
        ),
      ),
    );
  }
}
