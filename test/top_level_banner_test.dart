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

  testWidgets('the two rows carry the two kinds of thing', (tester) async {
    final p = fresh();
    await pump(tester, p);

    // The banner: the job, and the buttons that act on the open document.
    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.byKey(const ValueKey('save_context')),
      ),
      findsOneWidget,
      reason: 'Save acts on the document, so it belongs beside the job',
    );

    // The title bar: the things that are about the application.
    for (final key in ['export_workbook', 'export_tab_menu',
        'banner_app_config']) {
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(ValueKey(key)),
        ),
        findsOneWidget,
        reason: '$key is about the app, so it belongs in the title bar',
      );
    }

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

  testWidgets('the banner runs to the corner, not to the middle',
      (tester) async {
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    await pump(tester, p);

    // MEASURED, not eyeballed. The first attempt at this bar used a Flexible
    // for the job name AND a Spacer, both flex:1 — so they split the free
    // width between them and the half the short name did not use was left
    // over to the RIGHT of the buttons, parking the corner control 600 pixels
    // from the corner.
    final banner = tester.getRect(find.byType(TopLevelBar));
    final saveMenu = tester.getRect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.byKey(const ValueKey('save_menu')),
      ),
    );
    expect(saveMenu.right, closeTo(banner.right, 1),
        reason: 'the last button on the banner is flush with its right edge');
  });

  testWidgets('a long job name pushes nothing off either row', (tester) async {
    final p = fresh();
    p.newProject(
      name: 'Bessey Hall Phase Two Instructional Technology Refresh, '
          'Rooms 101 through 240 inclusive',
    );
    await pump(tester, p);

    expect(tester.takeException(), isNull,
        reason: 'a long name ellipsises rather than overflowing');

    final banner = tester.getRect(find.byType(TopLevelBar));
    final saveMenu = tester.getRect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.byKey(const ValueKey('save_menu')),
      ),
    );
    expect(saveMenu.right, closeTo(banner.right, 1));
    expect(banner.contains(saveMenu.centerLeft), isTrue);
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

  testWidgets('a job already open means only the file half is offered',
      (tester) async {
    // Somebody with a job open is not looking for a way to start one — they
    // are here because the ROOM slot is empty, and "Start a New Project" next
    // to that is an invitation to throw away the job they just opened.
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    // A real file: addRoomToProject checks, and a project with no rooms and
    // no file of its own is not an open project.
    final roomPath = path.join(dir.path, 'a_config.json');
    File(roomPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '101'},
    }));
    expect(p.addRoomToProject(roomPath), isEmpty);
    await pump(tester, p);

    expect(find.text('Create a New File'), findsOneWidget);
    expect(find.text('Open a File'), findsOneWidget);
    expect(find.text('Start a New Project'), findsNothing);
    expect(find.text('Open a Project'), findsNothing);
    // ...and it says which job is open rather than leaving them wondering.
    expect(find.textContaining('Bessey Hall is open'), findsOneWidget);
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
