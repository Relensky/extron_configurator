import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'form_factor.dart';
import 'nav_rail.dart';

/// The iPhone's tabs, along the bottom of the screen in place of the side
/// rail - see [isPhone]. The same tabs the rail holds, cut to [kPhoneTabs],
/// with Project first when a job is open.
class PhoneTabBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasProject =
        context.select((AppStateProvider p) => p.hasOpenProject);
    final tabs = <NavTab>[
      if (hasProject)
        const NavTab(AppTab.project, Icons.apartment, 'Project'),
      if (!hasConfig)
        kStartNavTab
      else
        for (final t in visibleNavTabs(estimateOnly: estimateOnly))
          if (kPhoneTabs.contains(t.tab)) t,
    ];
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: LayoutBuilder(
            builder: (context, box) {
              // Every tab on screen at once when they fit; a long row scrolls.
              final each = (box.maxWidth / tabs.length).clamp(64.0, 120.0);
              return ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final t in tabs)
                    _PhoneTab(
                      key: ValueKey('phone_tab_${t.tab.name}'),
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
  final double width;
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
    return SizedBox(
      width: width,
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
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                tab.label,
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: ink,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
