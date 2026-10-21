import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:material_ui/material_ui.dart';

/// ============================================================================
///  BARS THAT FOLD AWAY, AND A HEADER THAT SCROLLS
/// ============================================================================
///  At a large Interface Size the button rows over a drawing can fill the
///  page and leave the drawing no height at all. Two tools for that:
///
///    * [CollapsibleBar] folds one row of controls to its name.
///    * [ScrollingHeader] caps everything above the page's body at a share of
///      the height and scrolls it with a visible scrollbar past that.
///
///  Fold states last while the app runs, so a tab switch does not undo them.
/// ============================================================================

/// Which bars are folded, by id.
class BarFolds {
  BarFolds._();

  static final Set<String> _folded = {};

  /// Fires on every fold or unfold, for bars drawn outside a page's state.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static bool isFolded(String id) => _folded.contains(id);

  static void setFolded(String id, bool folded) {
    final changed = folded ? _folded.add(id) : _folded.remove(id);
    if (changed) changes.value++;
  }

  static void toggle(String id) => setFolded(id, !isFolded(id));

  /// Folds or unfolds every bar in [ids] at once.
  static void setAll(Iterable<String> ids, bool folded) {
    var changed = false;
    for (final id in ids) {
      changed = (folded ? _folded.add(id) : _folded.remove(id)) || changed;
    }
    if (changed) changes.value++;
  }

  static bool allFolded(Iterable<String> ids) => ids.every(_folded.contains);
}

/// A page's name, smaller once its controls are folded away.
class PageTitle extends StatelessWidget {
  final String text;
  final bool folded;

  const PageTitle(this.text, {super.key, required this.folded});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Text(
      text,
      style: folded ? theme.titleSmall : theme.titleLarge,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Two small icons that fold or unfold every bar on a page. [onChanged]
/// runs after either, for pages that keep folds of their own.
class FoldAllButtons extends StatelessWidget {
  final String page;
  final List<String> ids;
  final void Function(bool folded)? onChanged;

  const FoldAllButtons({
    super.key,
    required this.page,
    required this.ids,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).hintColor;
    Widget button(bool fold) => IconButton(
          key: ValueKey('${page}_${fold ? 'collapse' : 'expand'}_all'),
          tooltip: fold ? 'Collapse all' : 'Expand all',
          iconSize: 16,
          color: color,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          icon: Icon(fold ? Icons.unfold_less : Icons.unfold_more),
          onPressed: () {
            BarFolds.setAll(ids, fold);
            onChanged?.call(fold);
          },
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [button(true), button(false)],
    );
  }
}

/// The button that folds or unfolds bar [id], for a page that draws its own
/// folded state. [name] is what the tooltip calls it.
class FoldButton extends StatelessWidget {
  final String id;
  final String name;
  final VoidCallback? onChanged;

  const FoldButton({
    super.key,
    required this.id,
    required this.name,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final folded = BarFolds.isFolded(id);
    return IconButton(
      key: ValueKey('fold_$id'),
      tooltip: folded ? 'Show $name' : 'Hide $name',
      visualDensity: VisualDensity.compact,
      icon: Icon(folded ? Icons.unfold_more : Icons.unfold_less),
      onPressed: () {
        BarFolds.toggle(id);
        onChanged?.call();
      },
    );
  }
}

/// A row of controls with a chevron in front that folds it to [title].
class CollapsibleBar extends StatelessWidget {
  final String id;
  final String title;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const CollapsibleBar({
    super.key,
    required this.id,
    required this.title,
    required this.child,
    this.padding = const EdgeInsets.only(left: 8),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: BarFolds.changes,
      builder: (context, _, _) {
        final folded = BarFolds.isFolded(id);
        final toggle = Tooltip(
          message: folded ? 'Show $title' : 'Hide $title',
          child: InkWell(
            key: ValueKey('collapse_$id'),
            borderRadius: BorderRadius.circular(4),
            onTap: () => BarFolds.toggle(id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    folded ? Icons.chevron_right : Icons.expand_more,
                    size: 18,
                    color: theme.hintColor,
                  ),
                  if (folded)
                    Text(
                      title,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        return Padding(
          padding: padding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 6), child: toggle),
              if (!folded) Expanded(child: child),
            ],
          ),
        );
      },
    );
  }
}

/// [header] over [body], with the header held to [maxFraction] of the height
/// and scrolled, with its scrollbar showing, when it needs more.
///
/// The grip under the header drags it taller or shorter, like a side pane;
/// a double-click puts it back. The height is kept per [id] while the app
/// runs.
class ScrollingHeader extends StatefulWidget {
  final String id;
  final Widget header;
  final Widget body;
  final double maxFraction;

  const ScrollingHeader({
    super.key,
    required this.id,
    required this.header,
    required this.body,
    this.maxFraction = 0.5,
  });

  /// Heights dragged to, by [id]. Absent is the default share.
  static final Map<String, double> _heights = {};

  /// Least the header can be dragged down to, and least the page keeps.
  static const double minHeader = 32;
  static const double minBody = 80;

  /// The drag grip under the header.
  static const double grip = 7;

  @override
  State<ScrollingHeader> createState() => _ScrollingHeaderState();
}

class _ScrollingHeaderState extends State<ScrollingHeader> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double _shown() =>
      (_headerKey.currentContext?.findRenderObject() as RenderBox?)
          ?.size
          .height ??
      ScrollingHeader.minHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final finite = box.maxHeight.isFinite;
        final most = finite
            ? math.max(
                ScrollingHeader.minHeader,
                box.maxHeight - ScrollingHeader.minBody - ScrollingHeader.grip,
              )
            : double.infinity;
        final dragged = ScrollingHeader._heights[widget.id];
        final cap = dragged != null
            ? dragged.clamp(ScrollingHeader.minHeader, most)
            : finite
                ? math.max(48.0, box.maxHeight * widget.maxFraction)
                : double.infinity;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              key: _headerKey,
              constraints: BoxConstraints(maxHeight: cap),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: widget.header,
                ),
              ),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: GestureDetector(
                key: ValueKey('header_grip_${widget.id}'),
                behavior: HitTestBehavior.opaque,
                // Counted from where the pointer went down, so the edge
                // keeps up with it.
                dragStartBehavior: DragStartBehavior.down,
                // From what is shown now, so the edge follows the pointer
                // even when the header was shorter than its cap.
                onVerticalDragStart: (_) =>
                    ScrollingHeader._heights[widget.id] = _shown(),
                onVerticalDragUpdate: (d) => setState(() {
                  final now =
                      ScrollingHeader._heights[widget.id] ?? _shown();
                  ScrollingHeader._heights[widget.id] = (now + d.delta.dy)
                      .clamp(ScrollingHeader.minHeader, most);
                }),
                onDoubleTap: () =>
                    setState(() => ScrollingHeader._heights.remove(widget.id)),
                child: Tooltip(
                  message: 'Drag to resize the controls · double-click for '
                      'the default height',
                  waitDuration: const Duration(milliseconds: 600),
                  child: SizedBox(
                    height: ScrollingHeader.grip,
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
            Expanded(child: widget.body),
          ],
        );
      },
    );
  }
}
