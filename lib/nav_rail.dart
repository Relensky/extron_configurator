import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ============================================================================
///  THE LEFT RAIL
/// ============================================================================
///  Fourteen tabs down the side of a window that is not always fourteen tabs
///  tall, in a pane that can be dragged down to 72 pixels wide, with an app
///  text size somebody can push to 150% from App Config. Any two of those
///  three fight each other, so the rail has to do two things on its own:
///
///    * SCROLL when it is taller than the window — with the wheel, by dragging
///      the scrollbar, and by keeping the tab that just became current in
///      view. [NavigationRail] is a Column and a Column does not scroll; the
///      tabs at the bottom were simply cut off on a laptop.
///    * SHRINK ITS LABELS to whatever width the pane has been dragged to.
///      Two-word labels wrap by themselves, but 'Schematic' is one word: at
///      130% text in a narrow pane it ran off the side and was quietly clipped
///      mid-word. The type size is measured against the pane instead, so the
///      longest word always fits.
///
///  Both are about the window in front of somebody right now, which is why
///  none of it is written into the room.
/// ============================================================================

/// One entry in the rail: an icon, the word under it, and nothing else. The
/// order is the order of `AppTab`, because the rail's index IS the tab index.
class NavTab {
  final IconData icon;
  final String label;
  const NavTab(this.icon, this.label);
}

const List<NavTab> kNavTabs = [
  NavTab(Icons.auto_awesome, 'Wizard'),
  NavTab(Icons.router, 'Devices'),
  NavTab(Icons.settings, 'System'),
  NavTab(Icons.data_object, 'Raw JSON'),
  NavTab(Icons.account_tree, 'Schematic'),
  NavTab(Icons.cable, 'AV Flow'),
  NavTab(Icons.map, 'Floor Plan'),
  NavTab(Icons.account_tree_outlined, 'Cabling'),
  NavTab(Icons.view_day, 'Racks'),
  NavTab(Icons.request_quote, 'Cost'),
  NavTab(Icons.inventory_2, 'Catalog'),
  NavTab(Icons.schema, 'Schema'),
  NavTab(Icons.rule_folder, 'Flow Rules'),
  NavTab(Icons.build_circle, 'App Config'),
];

/// What [NavigationRail] keeps either side of a destination's label. Its own
/// constant is private to the framework, so it is repeated here — with two
/// pixels of slack, so a label that measures exactly the full width is not
/// left touching the edge.
const double _kDestinationPadding = 8 * 2 + 2;

class AppNavRail extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const AppNavRail({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  State<AppNavRail> createState() => _AppNavRailState();
}

class _AppNavRailState extends State<AppNavRail> {
  /// Ours rather than the framework's, so the scrollbar has something to drag
  /// and so the rail can scroll the selected tab back into view.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AppNavRail old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) _revealSelected();
  }

  /// Tabs change from places other than the rail — the wizard hands over to
  /// Devices, a report jumps to Cabling — and on a short window the tab that
  /// just became current can be off the bottom. Every destination is the same
  /// height, so where it sits is arithmetic rather than a hunt through the
  /// render tree.
  void _revealSelected() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent <= 0) return;
    final rowHeight =
        (pos.viewportDimension + pos.maxScrollExtent) / kNavTabs.length;
    final top = rowHeight * widget.selectedIndex;
    final bottom = top + rowHeight;
    final double target;
    if (top < pos.pixels) {
      target = top;
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      target = bottom - pos.viewportDimension;
    } else {
      return; // already on screen — moving it would just be motion
    }
    _scroll.animateTo(
      target.clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  /// How wide the longest word in the rail is painted at [style].
  ///
  /// Words one at a time, because a two-word label wraps on its own: it is the
  /// longest single word that decides how small the type has to go. App
  /// Config's app-wide text scaler is folded in, so this answers the real
  /// question — how wide will this actually be painted — at any text size.
  double _widestWord(TextStyle style, TextScaler scaler) {
    double widest = 0;
    for (final tab in kNavTabs) {
      for (final word in tab.label.split(' ')) {
        final painter = TextPainter(
          text: TextSpan(text: word, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        widest = math.max(widest, painter.width);
      }
    }
    return widest;
  }

  /// The biggest type size at which every label still fits [width].
  ///
  /// Measured rather than calculated, and measured again after each guess:
  /// halving the type size does not halve the word, because letter spacing is
  /// a flat number of pixels that stays where it is. Two or three passes over
  /// fourteen short words settles it, and the loop stops the moment it fits.
  double _fittedFontSize(double width, TextStyle style) {
    final base = style.fontSize ?? 12;
    if (width <= 0) return base;
    final scaler = MediaQuery.textScalerOf(context);
    double size = base;
    for (int pass = 0; pass < 6; pass++) {
      final widest = _widestWord(style.copyWith(fontSize: size), scaler);
      if (widest <= width || widest <= 0) break;
      size *= width / widest;
    }
    return size;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final railTheme = theme.navigationRailTheme;
    final TextStyle unselected =
        railTheme.unselectedLabelTextStyle ?? theme.textTheme.labelMedium!;
    final TextStyle selected =
        railTheme.selectedLabelTextStyle ?? theme.textTheme.labelMedium!;

    return LayoutBuilder(
      builder: (context, constraints) {
        // One size for both states, or the rail would change height as the
        // selection moves down it.
        final fitted = _fittedFontSize(
          constraints.maxWidth - _kDestinationPadding,
          unselected,
        );
        return Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            // The documented way to make a rail scroll: give it the viewport's
            // height as a MINIMUM, so the normal case still fills the side of
            // the window, and let anything past that scroll — under the wheel,
            // the scrollbar, or a trackpad.
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: NavigationRail(
                  selectedIndex: widget.selectedIndex,
                  onDestinationSelected: widget.onDestinationSelected,
                  // Fills whatever the pane has been dragged to, so the labels
                  // wrap instead of overflowing when it is narrowed.
                  minWidth: constraints.maxWidth,
                  labelType: NavigationRailLabelType.all,
                  selectedLabelTextStyle: selected.copyWith(fontSize: fitted),
                  unselectedLabelTextStyle:
                      unselected.copyWith(fontSize: fitted),
                  destinations: [
                    for (final tab in kNavTabs)
                      NavigationRailDestination(
                        icon: Icon(tab.icon),
                        label: Text(tab.label, textAlign: TextAlign.center),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
