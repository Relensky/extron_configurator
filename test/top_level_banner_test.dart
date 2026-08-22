import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/nav_rail.dart';

/// ============================================================================
///  THE TWO THINGS THAT ARE NOT VIEWS OF A ROOM
/// ============================================================================
///  The job and the gear used to be the first and last rows of a fifteen-row
///  navigation rail, which said they were the same kind of thing as Racks and
///  Cabling. They are not: one is what the room belongs to and the other is
///  the application's own settings. Both now live in a banner across the top
///  of the page, and the rail is thirteen rows of "ways of looking at a room".
///
///  The knock-on is the one worth testing hardest. The Project tab works with
///  no room open — that is the whole point of it — so an app that STARTED
///  there opened on an empty job list, and the start screen with "start a new
///  project" and "open a file" on it was never seen by anybody.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_banner'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AppStateProvider fresh() => AppStateProvider(autoLoadSettings: false)
    ..settingsLoaded = true
    ..firstRunSetupNeeded = false;

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
  }

  testWidgets('a cold start lands on the start screen, not the job list',
      (tester) async {
    final p = fresh();
    expect(p.selectedTabIndex, AppTab.cost.index,
        reason: 'starting on Project meant the start screen never appeared');

    await pump(tester, p);
    expect(find.text('Start a New Project'), findsOneWidget);
    expect(find.text('Create a New File'), findsOneWidget);
  });

  testWidgets('the banner carries the job and the gear', (tester) async {
    final p = fresh();
    await pump(tester, p);

    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget);
    expect(find.byKey(const ValueKey('banner_app_config')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('banner_project')));
    await tester.pumpAndSettle();
    expect(p.selectedTabIndex, AppTab.project.index);

    await tester.tap(find.byKey(const ValueKey('banner_app_config')));
    await tester.pumpAndSettle();
    expect(p.selectedTabIndex, AppTab.appConfig.index);
  });

  testWidgets('the banner names the open job, and says when it is behind '
      'its file', (tester) async {
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    final projectPath = path.join(dir.path, 'bessey_project.json');
    File(projectPath).writeAsStringSync(jsonEncode(p.project.toJson()));
    p.currentProjectPath = projectPath;
    await pump(tester, p);

    // Scoped to the banner: the start screen's Project card names the open job
    // too, and this test is about the strip along the top.
    Finder inBanner(String text) => find.descendant(
          of: find.byType(TopLevelBar),
          matching: find.text(text),
        );

    expect(inBanner('Bessey Hall'), findsOneWidget);

    p.setProjectField(client: 'Facilities');
    await tester.pump();
    expect(inBanner('Bessey Hall — unsaved'), findsOneWidget);
  });

  testWidgets('the gear sits in the corner, not in the middle',
      (tester) async {
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    await pump(tester, p);

    // MEASURED, not eyeballed. The first attempt at this bar used a Flexible
    // for the job name AND a Spacer, both flex:1 — so they split the free
    // width between them and the half the short name did not use was left
    // over to the RIGHT of the gear, parking a corner button 600 pixels from
    // the corner.
    final gear = tester.getRect(find.byKey(const ValueKey('banner_app_config')));
    final window = tester.getRect(find.byType(TopLevelBar));
    expect(gear.right, closeTo(window.right, 1),
        reason: 'the gear is flush with the right edge of the banner');
  });

  testWidgets('a long job name pushes nothing off the end', (tester) async {
    final p = fresh();
    p.newProject(
      name: 'Bessey Hall Phase Two Instructional Technology Refresh, '
          'Rooms 101 through 240 inclusive',
    );
    await pump(tester, p);

    expect(tester.takeException(), isNull);
    final gear = tester.getRect(find.byKey(const ValueKey('banner_app_config')));
    final window = tester.getRect(find.byType(TopLevelBar));
    expect(gear.right, closeTo(window.right, 1));
    expect(window.contains(gear.centerLeft), isTrue);
  });

  testWidgets('the banner survives the rail being folded away',
      (tester) async {
    final p = fresh();
    await pump(tester, p);

    await tester.tap(find.byKey(const ValueKey('pane_fold_nav_rail')));
    await tester.pumpAndSettle();

    expect(find.byType(NavRailRow), findsNothing);
    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget,
        reason: 'the way back to the job must not fold away with the rail');
    expect(find.byKey(const ValueKey('banner_app_config')), findsOneWidget);
  });

  test('the rail and the banner between them cover every tab, once', () {
    final railTabs = kNavTabs.map((t) => t.tab).toList();
    expect({...railTabs, ...kBannerTabs}, AppTab.values.toSet());
    expect(railTabs.length + kBannerTabs.length, AppTab.values.length,
        reason: 'a tab in both lists is a tab with two doorways and one of '
            'them highlighted wrongly');
    for (final banner in kBannerTabs) {
      expect(railTabs, isNot(contains(banner)));
    }
  });
}
