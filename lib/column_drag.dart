import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// ============================================================================
///  MOVING A COLUMN BY ITS GRIP
/// ============================================================================
///  Shared by the procurement log and the responsibility matrix. The grip is
///  the handle (dragging a heading pans the sheet); the heading is the target,
///  and which HALF of it the pointer is over says whether the column lands
///  before or after it - the line shows on that side. While a drag is on, the
///  grid scrolls sideways near its edges - see [PinnedGrid.dragging].
/// ============================================================================

/// Where a dropped column goes, as a final index in the list without it:
/// [from] the dragged column's index, [target] the heading it was dropped on.
int columnDropIndex(int from, int target, {required bool after}) {
  final t = target - (from < target ? 1 : 0);
  return t + (after ? 1 : 0);
}

/// The handle a column is dragged by. Sets [dragging] to [id] for as long as
/// the drag lasts, so the grid can scroll and the column can dim.
class ColumnDragGrip extends StatelessWidget {
  final String id;
  final String label;
  final double width;
  final ValueNotifier<String?> dragging;
  final Widget child;

  /// What the ghost under the pointer is filled with.
  final Color? fill;
  final Color? ink;

  const ColumnDragGrip({
    super.key,
    required this.id,
    required this.label,
    required this.width,
    required this.dragging,
    required this.child,
    this.fill,
    this.ink,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ghostWidth = width.clamp(80.0, 260.0);
    return Draggable<String>(
      data: id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => dragging.value = id,
      onDragEnd: (_) => dragging.value = null,
      onDraggableCanceled: (_, _) => dragging.value = null,
      // Centered on the pointer, a little see-through, so the line it is
      // being dropped against stays visible under it.
      feedback: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Opacity(
          opacity: 0.85,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(6),
            color: fill ?? theme.colorScheme.surfaceContainerHigh,
            child: Container(
              width: ghostWidth,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: ink,
                ),
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
    );
  }
}

/// A heading a column can be dropped on. [onDrop] hears the dragged id and
/// whether it goes after this one.
class ColumnDropTarget extends StatefulWidget {
  final String id;
  final void Function(String dragged, bool after) onDrop;
  final Widget child;

  /// Dims the heading while its own column is the one being dragged.
  final ValueListenable<String?>? dragging;

  const ColumnDropTarget({
    super.key,
    required this.id,
    required this.onDrop,
    required this.child,
    this.dragging,
  });

  @override
  State<ColumnDropTarget> createState() => _ColumnDropTargetState();
}

class _ColumnDropTargetState extends State<ColumnDropTarget> {
  /// Null when nothing is over this heading.
  bool? _after;

  bool _sideOf(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    return box.globalToLocal(global).dx > box.size.width / 2;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final target = DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != widget.id,
      onMove: (d) {
        if (d.data == widget.id) return;
        final after = _sideOf(d.offset);
        if (after != _after) setState(() => _after = after);
      },
      onLeave: (_) => setState(() => _after = null),
      onAcceptWithDetails: (d) {
        final after = _after ?? _sideOf(d.offset);
        setState(() => _after = null);
        widget.onDrop(d.data, after);
      },
      // Drawn over the heading, not around it, so the row does not widen.
      builder: (context, candidate, _) {
        final side = BorderSide(color: accent, width: 3);
        return Container(
          foregroundDecoration: candidate.isEmpty || _after == null
              ? null
              : BoxDecoration(
                  color: accent.withValues(alpha: 0.08),
                  border: _after!
                      ? Border(right: side)
                      : Border(left: side),
                ),
          child: widget.child,
        );
      },
    );
    final dragging = widget.dragging;
    if (dragging == null) return target;
    return ValueListenableBuilder<String?>(
      valueListenable: dragging,
      builder: (context, id, child) => AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: id == widget.id ? 0.4 : 1,
        child: child,
      ),
      child: target,
    );
  }
}
