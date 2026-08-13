import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

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

  testWidgets('Raw JSON sits directly after System in the rail',
      (tester) async {
    expect(AppTab.values[AppTab.system.index + 1], AppTab.rawJson);

    await pumpApp(tester, room());
    // NavigationRailDestination is a description, not a widget, so the rail
    // itself is what carries the order.
    final labels = [
      for (final d in tester
          .widget<NavigationRail>(find.byType(NavigationRail))
          .destinations)
        (d.label as Text).data,
    ];
    expect(labels.indexOf('Raw JSON'), labels.indexOf('System') + 1);
    // The rail order and the enum order have to agree, or every tab shows the
    // page of its neighbour.
    expect(labels.length, AppTab.values.length);
  });

  testWidgets('the rail folds away and comes back', (tester) async {
    await pumpApp(tester, room());
    expect(find.text('Devices'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('pane_fold_nav_rail')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const ValueKey('pane_unfold_nav_rail')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pane_unfold_nav_rail')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
  });
}
