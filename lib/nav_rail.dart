import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ============================================================================
///  THE LEFT RAIL
/// ============================================================================
///  Fifteen tabs down the side of a window that is not always fifteen tabs
///  tall, in a pane that can be dragged down to 72 pixels wide, with an app
///  text size somebody can push to 150% from App Config. Any two of those
///  three fight each other, so the rail sizes itself to the pane it is given,
///  in both directions:
///
///    * IT SHRINKS ITS LABELS TO THE WIDTH. Two-word labels wrap by
///      themselves, but 'Schematic' is one word: at 130% text in a narrow pane
///      it ran off the side and was quietly clipped mid-word. The type size is
///      measured against the pane instead, so the longest word always fits.
///    * IT SHRINKS ITS ROWS TO THE HEIGHT, so every tab is on screen at once.
///      A rail you have to scroll to reach App Config is a rail where App
///      Config may as well not exist — nobody scrolls a navigation bar looking
///      for something they are not sure is there.
///
///  WHY THIS IS NOT A [NavigationRail]. It was, and the height half cannot be
///  done with one. Its destinations have a floor of about 55 pixels each
///  whatever you set: the icon-size properties do not move it at all, and
///  wringing the label down to 7pt only gets there. Fifteen of those need 830
///  pixels and a laptop has 600. So the rail is drawn here instead — one
///  Column of rows whose padding, icon and type are all computed from the
///  space available, which is the only way "always fits" is a promise rather
///  than a hope.
///
///  Scrolling survives as the last resort, for a window so short that even the
///  minimum legible row cannot fit fifteen times. It is no longer the normal
///  case, which is the point.
/// ============================================================================

/// One entry in the rail: an icon, the word under it, and nothing else. The
/// order is the order of `AppTab`, because the rail's index IS the tab index.
class NavTab {
  final IconData icon;
  final String label;
  const NavTab(this.icon, this.label);
}

const List<NavTab> kNavTabs = [
  NavTab(Icons.apartment, 'Project'),
  NavTab(Icons.request_quote, 'Cost'),
  NavTab(Icons.auto_awesome, 'Wizard'),
  NavTab(Icons.router, 'Devices'),
  NavTab(Icons.settings, 'System'),
  NavTab(Icons.data_object, 'Raw JSON'),
  NavTab(Icons.account_tree, 'Schematic'),
  NavTab(Icons.cable, 'AV Flow'),
  NavTab(Icons.map, 'Floor Plan'),
  NavTab(Icons.account_tree_outlined, 'Cabling'),
  NavTab(Icons.view_day, 'Racks'),
  NavTab(Icons.inventory_2, 'Catalog'),
  NavTab(Icons.schema, 'Schema'),
  NavTab(Icons.rule_folder, 'Flow Rules'),
  NavTab(Icons.build_circle, 'App Config'),
];

/// Breathing room either side of a label, so a word that measures exactly the
/// pane's width is not left touching both edges.
const double _kLabelPadding = 8 * 2 + 2;

/// The comfortable end of each dimension, used whenever the window can afford
/// it, and the floor below which shrinking stops making things smaller and
/// starts making them unusable.
const double _kIconMax = 22, _kIconMin = 12;
const double _kPadMax = 7, _kPadMin = 1.5;

/// The smallest type the rail will set a label in before giving up on labels
/// altogether.
///
/// Low on purpose. Dropping a point of type is a much smaller loss than
/// dropping the words, and it is often the difference between 'Floor Plan'
/// taking one line and taking two — which is worth about 10 pixels a row, or
/// 150 down the rail. The app-wide text scale multiplies this, so somebody at
/// 150% is reading 10.5, not 7.
const double _kFontMin = 7;

/// Tighter than the theme's, because a rail label is one or two short words
/// and the leading between them is pure height. Applied when the row is
/// measured AND when it is drawn, or the two would disagree by exactly the
/// amount that overflows.
const double _kLabelLineHeight = 1.05;

/// The row geometry chosen for one pane size.
///
/// [labels] is false in the last-resort mode, where the words come off and the
/// rail is icons with tooltips. That is not a nice rail, and it beats the two
/// alternatives at 400 pixels of height: type nobody can read, or five tabs
/// hidden below the fold.
typedef RailFit = ({
  double icon,
  double font,
  double pad,
  double rowHeight,
  bool labels,
});

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
  /// and so the rail can scroll the selected tab back into view on the short
  /// windows where scrolling is still needed.
  final ScrollController _scroll = ScrollController();

  /// The last fit, keyed on what it was computed from. A LayoutBuilder rebuilds
  /// whenever its parent lays out, and the fit costs a few dozen text
  /// measurements — cheap once, wasteful on every frame of a window drag.
  String _fitKey = '';
  RailFit? _fit;

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
  /// Devices, a report jumps to Cabling — and on a window too short even for
  /// the minimum row the tab that just became current can be off the bottom.
  /// Every row is the same height, so where it sits is arithmetic rather than
  /// a hunt through the render tree.
  void _revealSelected() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent <= 0) return; // everything is already on screen
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

  /// How wide the longest single word in the rail is painted at [style].
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

  /// The tallest label in the rail once wrapped into [width] at [style] — the
  /// real number, measured, because 'Floor Plan' takes two lines and 'Racks'
  /// takes one and every row has to be tall enough for the worst of them.
  double _tallestLabel(double width, TextStyle style, TextScaler scaler) {
    double tallest = 0;
    for (final tab in kNavTabs) {
      final painter = TextPainter(
        text: TextSpan(text: tab.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        textAlign: TextAlign.center,
        maxLines: 2,
      )..layout(maxWidth: math.max(1, width));
      tallest = math.max(tallest, painter.height);
    }
    return tallest;
  }

  /// The biggest type size at which every label still fits [width].
  ///
  /// Measured rather than calculated, and measured again after each guess:
  /// halving the type size does not halve the word, because letter spacing is
  /// a flat number of pixels that stays where it is. Two or three passes over
  /// fifteen short words settles it, and the loop stops the moment it fits.
  double _fontForWidth(double width, TextStyle style, TextScaler scaler) {
    final base = style.fontSize ?? 12;
    if (width <= 0) return base;
    double size = base;
    for (int pass = 0; pass < 6; pass++) {
      final widest = _widestWord(style.copyWith(fontSize: size), scaler);
      if (widest <= width || widest <= 0) break;
      size *= width / widest;
    }
    return size;
  }

  /// Picks the row geometry for a pane of [width] x [height].
  ///
  /// WIDTH DECIDES THE TYPE SIZE FIRST, because a clipped label is worse than
  /// a cramped one — there is no reading half a word. Then the rows are
  /// squeezed towards the floor until fifteen of them fit the height, taking
  /// the padding, the icon and the type down together. The first candidate
  /// that fits wins, so a tall window gets the comfortable end and only a
  /// short one pays for being short.
  RailFit _computeFit(double width, double height, TextStyle style) {
    final scaler = MediaQuery.textScalerOf(context);
    final labelWidth = math.max(1.0, width - _kLabelPadding);
    final widthFont = _fontForWidth(labelWidth, style, scaler);

    /// [t] runs 1 (comfortable) down to 0 (the floor).
    RailFit candidate(double t) {
      final icon = _kIconMin + (_kIconMax - _kIconMin) * t;
      final pad = _kPadMin + (_kPadMax - _kPadMin) * t;
      // Never grows the type past what the WIDTH allowed, and never shrinks it
      // below the legibility floor — even when the width already forced it
      // under, in which case the width's answer stands.
      final font = widthFont <= _kFontMin
          ? widthFont
          : _kFontMin + (widthFont - _kFontMin) * t;
      final labelH = _tallestLabel(
        labelWidth,
        style.copyWith(fontSize: font, height: _kLabelLineHeight),
        scaler,
      );
      // pad, icon, a hair of gap, the label, pad.
      return (
        icon: icon,
        font: font,
        pad: pad,
        rowHeight: pad * 2 + icon + 2 + labelH,
        labels: true,
      );
    }

    for (int step = 0; step <= 8; step++) {
      final fit = candidate(1 - step / 8);
      if (fit.rowHeight * kNavTabs.length <= height) return fit;
    }

    // THE WORDS COME OFF. Fifteen legible labelled rows need more height than
    // this window has, and the two ways of pretending otherwise are both
    // worse: type below the floor is a label nobody can read, and letting it
    // scroll hides a third of the rail behind a gesture nobody makes on a
    // navigation bar. Icons carry the tabs, and every one of them gets a
    // tooltip so the word is still a hover away.
    final iconOnly = math.max(
      12.0,
      math.min(_kIconMax, height / kNavTabs.length - _kPadMin * 2 - 1),
    );
    return (
      icon: iconOnly,
      font: math.max(_kFontMin, widthFont),
      pad: _kPadMin,
      rowHeight: math.max(iconOnly + _kPadMin * 2, height / kNavTabs.length),
      labels: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final railTheme = theme.navigationRailTheme;
    final TextStyle base =
        railTheme.unselectedLabelTextStyle ?? theme.textTheme.labelMedium!;
    final scaler = MediaQuery.textScalerOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final key =
            '${constraints.maxWidth}x${constraints.maxHeight}'
            '@${scaler.scale(10)}:${base.fontSize}';
        if (key != _fitKey || _fit == null) {
          _fit = _computeFit(constraints.maxWidth, constraints.maxHeight, base);
          _fitKey = key;
        }
        final fit = _fit!;
        final fits = fit.rowHeight * kNavTabs.length <= constraints.maxHeight;

        return Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            // Never scrolls when it fits. A rail that can be nudged by a stray
            // wheel event while every tab is already visible only loses people
            // their place.
            physics: fits ? const NeverScrollableScrollPhysics() : null,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                children: [
                  for (int i = 0; i < kNavTabs.length; i++)
                    NavRailRow(
                      tab: kNavTabs[i],
                      selected: i == widget.selectedIndex,
                      fit: fit,
                      style: base,
                      onTap: () => widget.onDestinationSelected(i),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One tab: the icon, the word under it, and the band behind the current one.
///
/// Public so a test can find the rows and read the order off them — the thing
/// [NavigationRail]'s `destinations` list used to be asked for.
class NavRailRow extends StatelessWidget {
  final NavTab tab;
  final bool selected;
  final RailFit fit;
  final TextStyle style;
  final VoidCallback onTap;

  const NavRailRow({
    super.key,
    required this.tab,
    required this.selected,
    required this.fit,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    final row = SizedBox(
      height: fit.rowHeight,
      width: double.infinity,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          // The whole row is the target, so a pane dragged narrow is still
          // easy to hit.
          child: Ink(
            decoration: BoxDecoration(
              color: selected ? scheme.secondaryContainer : null,
            ),
            padding: EdgeInsets.symmetric(vertical: fit.pad, horizontal: 4),
            // BoxFit.scaleDown is the belt to the measurement's braces. The
            // row height comes from measuring these very words, so it should
            // always be enough — but a fallback font, a rounding scaler or a
            // platform whose metrics differ by a pixel would otherwise paint
            // an overflow stripe down the side of the app. Scaling down by
            // that pixel is invisible; the stripe is not.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tab.icon, size: fit.icon, color: color),
                  if (fit.labels) ...[
                    const SizedBox(height: 2),
                    Text(
                      tab.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: style.copyWith(
                        fontSize: fit.font,
                        height: _kLabelLineHeight,
                        color: color,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // In icon-only mode the word is the tooltip, because it is the only place
    // left for it. With labels on, the label already says it and a tooltip
    // repeating it is just something that pops up under the pointer.
    return fit.labels
        ? row
        : Tooltip(
            message: tab.label,
            waitDuration: const Duration(milliseconds: 400),
            child: row,
          );
  }
}
