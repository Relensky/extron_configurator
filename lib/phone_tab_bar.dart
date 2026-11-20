import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'form_factor.dart';
import 'nav_rail.dart';

/// The iPhone's tabs, along the bottom of the screen in place of the side
/// rail - see [isPhone]. Every tab the rail holds, with Project first when a
/// job is open: the ones used most in a room ([kPhoneTabs]) first, then the
/// rest - Schematic, AV Flow, Cabling and so on - a swipe sideways away.
class PhoneTabBar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool hasConfig;
  final bool estimateOnly;

  const PhoneTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.hasConfig,
    required this.estimateOnly,
  });

  @override
  State<PhoneTabBar> createState() => _PhoneTabBarState();
}

class _PhoneTabBarState extends State<PhoneTabBar> {
  final _scroll = ScrollController();
  final _keys = <AppTab, GlobalKey>{};
  int _shown = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the selected tab on screen when it is picked from somewhere
  /// other than the bar - a link, Undo, the start screen.
  void _reveal(int index) {
    if (index == _shown) return;
    _shown = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tab = index >= 0 && index < AppTab.values.length
          ? AppTab.values[index]
          : null;
      final ctx = tab == null ? null : _keys[tab]?.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = widget.selectedIndex;
    final onSelect = widget.onSelect;
    final theme = Theme.of(context);
    final hasProject =
        context.select((AppStateProvider p) => p.hasOpenProject);
    final all = visibleNavTabs(estimateOnly: widget.estimateOnly);
    final tabs = <NavTab>[
      if (hasProject)
        const NavTab(AppTab.project, Icons.apartment, 'Project'),
      if (!widget.hasConfig) ...[
        kStartNavTab,
        // The catalog, schema and rules work with no room open.
        for (final t in all)
          if (t.tab.worksWithoutConfig) t,
      ] else ...[
        for (final t in all)
          if (kPhoneTabs.contains(t.tab)) t,
        for (final t in all)
          if (!kPhoneTabs.contains(t.tab)) t,
      ],
    ];
    _reveal(selectedIndex);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          // On its side, icons only: the labels cost a third of the bar's
          // height on a screen with little to spare.
          height: phoneLandscape(context) ? 40 : 54,
          child: LayoutBuilder(
            builder: (context, box) {
              // Every tab on screen at once when they fit; otherwise the row
              // scrolls, with the edge of the next tab showing so it is
              // plain there is more.
              // When they scroll anyway, each takes its label's width and a
              // gap either side: squeezed to one fixed width, "Lifecycle"
              // and "Floor Plan" shrank and ran into each other.
              final fit = box.maxWidth / tabs.length;
              final double? each = fit >= 64 ? fit.clamp(64.0, 120.0) : null;
              return ListView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                children: [
                  for (final t in tabs)
                    _PhoneTab(
                      key: _keys.putIfAbsent(t.tab, GlobalKey.new),
                      tab: t,
                      width: each,
                      selected: t.tab.index == selectedIndex,
                      onTap: () => onSelect(t.tab.index),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PhoneTab extends StatelessWidget {
  final NavTab tab;

  /// A fixed width when every tab fits on screen; null sizes the tab to its
  /// label, for a bar that scrolls.
  final double? width;
  final bool selected;
  final VoidCallback onTap;

  const _PhoneTab({
    super.key,
    required this.tab,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final label = Text(
      tab.label,
      maxLines: 1,
      style: theme.textTheme.labelSmall?.copyWith(
        color: ink,
        fontWeight: selected ? FontWeight.w600 : null,
      ),
    );
    final body = SizedBox(
      width: width,
      child: Tooltip(
        message: tab.label,
        child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                tab.icon,
                size: 22,
                color: selected ? theme.colorScheme.onSecondaryContainer : ink,
              ),
            ),
            if (!phoneLandscape(context)) ...[
            const SizedBox(height: 2),
            width == null
                ? label
                : FittedBox(fit: BoxFit.scaleDown, child: label),
            ],
          ],
        ),
      ),
      ),
    );
    if (width != null) return body;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: body,
      ),
    );
  }
}
