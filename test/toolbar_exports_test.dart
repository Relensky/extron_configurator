import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  final exportMenu = find.byKey(const ValueKey('export_menu'));
  final screenshotMenu = find.byKey(const ValueKey('screenshot_menu'));

  Future<void> openExport(WidgetTester tester) async {
    await tester.tap(exportMenu);
    await tester.pumpAndSettle();
  }

  testWidgets('export floats in the lower right, on every tab',
      (tester) async {
    final p = room();
    await pumpApp(tester, p);
    final screen = tester.getRect(find.byType(Scaffold).first);
    for (final tab in [AppTab.devices, AppTab.cost, AppTab.racks]) {
      p.selectTab(tab.index);
      await tester.pumpAndSettle();
      expect(exportMenu, findsOneWidget);
      expect(find.descendant(of: find.byType(AppBar), matching: exportMenu),
          findsNothing, reason: 'not in the title bar any more');
      final r = tester.getRect(exportMenu);
      expect(r.right, greaterThan(screen.right - 60));
      expect(r.bottom, greaterThan(screen.bottom - 60));
      // The screenshot floats just above it, right edges lined up.
      final shot = tester.getRect(screenshotMenu);
      expect(shot.bottom, lessThanOrEqualTo(r.top));
      expect(r.top - shot.bottom, lessThan(24));
      expect((shot.right - r.right).abs(), lessThan(2));
    }
  });

  testWidgets('with nothing to export the screenshot takes the corner',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    await pumpApp(tester, p);
    final screen = tester.getRect(find.byType(Scaffold).first);
    expect(exportMenu, findsNothing);
    final shot = tester.getRect(screenshotMenu);
    expect(shot.right, greaterThan(screen.right - 60));
    expect(shot.bottom, greaterThan(screen.bottom - 60));
  });

  testWidgets('the corner buttons fade and shrink until hovered',
      (tester) async {
    final p = room();
    await pumpApp(tester, p);
    await tester.pumpAndSettle();
    double opacityOf(Finder f) => tester
        .widget<AnimatedOpacity>(
            find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).first)
        .opacity;
    final small = tester.getRect(screenshotMenu);
    expect(opacityOf(screenshotMenu), lessThan(1));
    expect(opacityOf(exportMenu), lessThan(1));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(screenshotMenu));
    await tester.pumpAndSettle();
    expect(opacityOf(screenshotMenu), 1);
    expect(tester.getRect(screenshotMenu).width, greaterThan(small.width));
    expect(opacityOf(exportMenu), lessThan(1),
        reason: 'each button wakes on its own');

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(opacityOf(screenshotMenu), lessThan(1));
  });

  testWidgets('with nothing loaded there is nothing to export', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    await pumpApp(tester, p);
    expect(exportMenu, findsNothing);
  });

  testWidgets('the catalog exports without a room - it is the price list',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    await pumpApp(tester, p);
    p.selectTab(AppTab.deviceEditor.index);
    await tester.pumpAndSettle();
    await openExport(tester);
    expect(find.byKey(const ValueKey('export_item_tab_xlsx')), findsOneWidget);
    expect(find.byKey(const ValueKey('export_item_room_workbook')),
        findsNothing);
  });

  testWidgets('on the Cost tab the estimate is listed once, not twice',
      (tester) async {
    final p = room();
    p.selectTab(AppTab.cost.index);
    await pumpApp(tester, p);
    await tester.pumpAndSettle();

    await openExport(tester);
    for (final v in [
      'room_workbook',
      'sheets_room',
      'publish_room',
      'cost_pdf',
      'cost_xlsx',
      'cost_txt',
      'cost_copy',
    ]) {
      expect(find.byKey(ValueKey('export_item_$v')), findsOneWidget,
          reason: '$v is on the export menu');
    }
    // The generic "this tab" lines would repeat the estimate's own.
    expect(find.byKey(const ValueKey('export_item_tab_xlsx')), findsNothing);
    expect(find.text('Room to Google Sheets'), findsOneWidget);
  });

  testWidgets('switching to the Cost tab puts the PDF on the export menu',
      (tester) async {
    // The page registers its exports as it mounts, after the button has been
    // built - so the menu must decide what to list when it opens.
    final p = room();
    p.selectTab(AppTab.devices.index);
    await pumpApp(tester, p);
    await tester.pumpAndSettle();
    p.selectTab(AppTab.cost.index);
    await tester.pump();
    await openExport(tester);
    expect(find.byKey(const ValueKey('export_item_cost_pdf')), findsOneWidget);
    expect(find.text('Cost estimate as PDF'), findsOneWidget);
  });

  testWidgets('other tabs offer their own tables', (tester) async {
    final p = room();
    p.selectTab(AppTab.devices.index);
    await pumpApp(tester, p);
    await openExport(tester);
    expect(find.byKey(const ValueKey('export_item_cost_pdf')), findsNothing);
    expect(find.byKey(const ValueKey('export_item_tab_xlsx')), findsOneWidget);
    expect(find.textContaining('spreadsheet (.xlsx)'), findsOneWidget);
  });

  testWidgets('the screenshot menu offers the estimate on the Cost tab',
      (tester) async {
    final p = room();
    p.selectTab(AppTab.cost.index);
    await pumpApp(tester, p);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screenshot_menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screenshot_screen')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('screenshot_estimate_light')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('screenshot_estimate_dark')), findsOneWidget);
  });

  testWidgets('Ctrl+Shift+S is Save All', (tester) async {
    final p = room();
    await pumpApp(tester, p);
    p.newProject(name: 'Job');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    // Save All saves the room as well as the job: a room with no file yet
    // is what it reaches first, and that asks where to put it - so the
    // proof here is that it did not take the Save As path for the job
    // alone. The menu names the key.
    await tester.tap(find.byKey(const ValueKey('save_menu')));
    await tester.pumpAndSettle();
    expect(find.text('Save All'), findsOneWidget);
    expect(find.text('Ctrl+Shift+S'), findsOneWidget);
    expect(find.byKey(const ValueKey('save_av_setup')), findsOneWidget);
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
