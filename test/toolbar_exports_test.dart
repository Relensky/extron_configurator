import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/nav_rail.dart';

/// Two things that used to depend on which page somebody happened to be
/// standing on: the room workbook lived on two of the twelve tabs, and "can I
/// get this as a spreadsheet" had a different answer per tab. Both are on the
/// toolbar now, in the same place on every page.
///
/// And the rail itself: Raw JSON sits beside System, because the two are the
/// same document seen two ways.
void main() {
  AppStateProvider room() => AppStateProvider(autoLoadSettings: false)
    ..settingsLoaded = true
    ..firstRunSetupNeeded = false
    ..roomConfig = {
      'SYSTEM_SETUP': {
        'gve_bldg': 'BSS',
        'gve_room': '103',
        'gui_full_room_name': 'Business Services 103',
      },
    };

  Future<void> pumpApp(
    WidgetTester tester,
    AppStateProvider provider, {
    Size size = const Size(1900, 1200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
  }

  final workbook = find.byKey(const ValueKey('export_workbook'));
  final tabExport = find.byKey(const ValueKey('export_tab_menu'));

  testWidgets('both export buttons are on the toolbar, on every tab',
      (tester) async {
    final p = room();
    await pumpApp(tester, p);
    for (final tab in [AppTab.devices, AppTab.cost, AppTab.racks]) {
      p.selectTab(tab.index);
      await tester.pump();
      expect(workbook, findsOneWidget);
      expect(tabExport, findsOneWidget);
    }
  });

  testWidgets('with nothing loaded there is nothing to export', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    await pumpApp(tester, p);
    expect(tester.widget<IconButton>(workbook).onPressed, isNull);
    expect(
      tester.widget<PopupMenuButton<String>>(tabExport).enabled,
      isFalse,
    );
  });

  testWidgets('the catalog exports without a room — it is the price list',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    await pumpApp(tester, p);
    p.selectTab(AppTab.deviceEditor.index);
    await tester.pump();
    expect(tester.widget<PopupMenuButton<String>>(tabExport).enabled, isTrue);
  });

  testWidgets('the per-tab menu offers the three ways out', (tester) async {
    final p = room();
    p.selectTab(AppTab.cost.index);
    await pumpApp(tester, p);

    await tester.tap(tabExport);
    await tester.pumpAndSettle();
    expect(find.textContaining('spreadsheet (.xlsx)'), findsOneWidget);
    expect(find.textContaining('plain text (.txt)'), findsOneWidget);
    expect(find.textContaining('clipboard'), findsOneWidget);
    // Named for the tab it is on, so it is obvious what is being exported.
    expect(find.textContaining('Cost estimate'), findsWidgets);
  });

  testWidgets("every page's own report menu offers the clipboard too",
      (tester) async {
    // The toolbar's per-tab menu is the floor under every page, but the button
    // people actually press is the one on the page — "Run schedule",
    // "Location report", "Report". Each of those has to offer the same three
    // answers, or "can I paste this into an email" depends on which page you
    // are standing on all over again.
    final p = room();
    await pumpApp(tester, p);

    for (final (tab, menu) in [
      (AppTab.cabling, const ValueKey('cabling_schedule_menu')),
      (AppTab.floorPlan, const ValueKey('plan_report_menu')),
    ]) {
      p.selectTab(tab.index);
      await tester.pumpAndSettle();

      // The button is behind an IgnorePointer so the menu takes the tap.
      await tester.tap(find.byKey(menu), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        find.text('Copy text to clipboard'),
        findsOneWidget,
        reason: '${tab.name} has no clipboard option',
      );

      await tester.tapAt(const Offset(20, 20)); // dismiss the menu
      await tester.pumpAndSettle();
    }
  });

  testWidgets('Raw JSON sits directly after System in the rail',
      (tester) async {
    expect(AppTab.values[AppTab.system.index + 1], AppTab.rawJson);

    await pumpApp(tester, room());
    // The rail draws its own rows now — NavigationRail could not shrink far
    // enough to fit them all — so the order is read off the rows themselves.
    final labels = [
      for (final row in tester.widgetList<NavRailRow>(find.byType(NavRailRow)))
        row.tab.label,
    ];
    expect(labels.indexOf('Raw JSON'), labels.indexOf('System') + 1);
    // Every tab is reachable: the rail plus the two in the banner above it
    // (Project and App Config) have to account for the whole enum, with no
    // tab in both lists and none in neither.
    final reached = {
      for (final row in tester.widgetList<NavRailRow>(find.byType(NavRailRow)))
        row.tab.tab,
      ...kBannerTabs,
    };
    expect(reached, AppTab.values.toSet());
    expect(labels.length, AppTab.values.length - kBannerTabs.length);
    // ...and the two that moved are NOT still in the rail.
    expect(labels, isNot(contains('Project')));
    expect(labels, isNot(contains('App Config')));
  });

  testWidgets('the rail folds away and comes back', (tester) async {
    await pumpApp(tester, room());
    expect(find.text('Devices'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('pane_fold_nav_rail')));
    await tester.pumpAndSettle();
    expect(find.byType(NavRailRow), findsNothing);
    expect(find.byKey(const ValueKey('pane_unfold_nav_rail')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pane_unfold_nav_rail')));
    await tester.pumpAndSettle();
    expect(find.byType(NavRailRow), findsNWidgets(kNavTabs.length));
  });
}
