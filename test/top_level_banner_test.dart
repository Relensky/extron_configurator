import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart'
    show kProjectFileSuffix;
import 'package:extron_configurator/save_actions.dart' show isProjectFile;
import 'package:extron_configurator/main.dart'
    show RoomConfigApp, TopLevelBar, roomModeBannerFill;
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
    // With a job open: the banner's own button is only offered once there is
    // a job to go to — see the group at the end of this file.
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    await pump(tester, p);

    // The banner: the job, and the buttons that act on the open document.
    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget);

    // The exports act on the DOCUMENT — "give me this as a spreadsheet" is
    // the same kind of question as "convert this" — so they sit on the
    // document row rather than up beside the theme toggle.
    for (final key in ['export_workbook', 'export_tab_menu']) {
      expect(
        find.descendant(
          of: find.byType(TopLevelBar),
          matching: find.byKey(ValueKey(key)),
        ),
        findsOneWidget,
        reason: '$key acts on the open document, so it is on the document row',
      );
    }

    // ...and Open says all three documents it takes. It has accepted a campus
    // since campus files existed; a tooltip that named two of them left the
    // third to be found by accident.
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('open_config')))
          .tooltip,
      'Open a room config, a project or a campus',
    );

    // The title bar: the app's own corner — the gear, Help, the theme and the
    // screenshot, none of which changes with the tab — and, at the other end,
    // everything that begins, steps, puts back or writes a FILE: New (a menu
    // over the two things there are to start), Open, Undo and Redo, the
    // history, the revert to the last saved backup, and Save.
    for (final key in [
      'new_menu',
      'open_config',
      'toolbar_undo',
      'toolbar_redo',
      'show_history',
      'revert_to_backup',
      'save_context',
      'banner_app_config',
      'open_help',
    ]) {
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(ValueKey(key)),
        ),
        findsOneWidget,
        reason: '$key belongs in the title bar',
      );
      expect(
        find.descendant(
          of: find.byType(TopLevelBar),
          matching: find.byKey(ValueKey(key)),
        ),
        findsNothing,
        reason: '$key is not also on the document row',
      );
    }

    // SAVE IS THE FAR CORNER, and the app's own four are the near one. The
    // most-pressed button on the bar is the one worth being unable to move,
    // and a corner is the only place on a row that cannot: what sits between
    // the two ends changes with the tab, the ends do not.
    final barRight = tester.getRect(find.byType(AppBar)).right;
    final saveRight = tester
        .getRect(find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(const ValueKey('save_context')),
        ))
        .right;
    for (final key in ['new_menu', 'open_config', 'toolbar_undo',
        'toolbar_redo', 'show_history', 'revert_to_backup']) {
      expect(
        tester
            .getRect(find.descendant(
              of: find.byType(AppBar),
              matching: find.byKey(ValueKey(key)),
            ))
            .right,
        lessThan(saveRight),
        reason: '$key belongs to the left of Save',
      );
    }
    // Only the save menu's own arrow is further right than Save itself.
    expect(barRight - saveRight, lessThan(80));

    for (final key in ['banner_app_config', 'open_help']) {
      expect(
        tester
            .getRect(find.descendant(
              of: find.byType(AppBar),
              matching: find.byKey(ValueKey(key)),
            ))
            .left,
        lessThan(tester
            .getRect(find.descendant(
              of: find.byType(AppBar),
              matching: find.byKey(const ValueKey('new_menu')),
            ))
            .left),
        reason: '$key is in the left corner, ahead of the job and the file '
            'buttons',
      );
    }

    // ONE "NEW", NOT TWO ICONS THAT BOTH MEAN NEW. The two things there are
    // to start are named under it rather than left to a hover.
    await tester.tap(find.byKey(const ValueKey('new_menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new_project')), findsOneWidget);
    expect(find.byKey(const ValueKey('new_config')), findsOneWidget);
    expect(find.text('New Project'), findsOneWidget);
    expect(find.text('New Config'), findsOneWidget);
    // ...and it is a menu: nothing is started by opening it.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new_project')), findsNothing);

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
    //
    // CONTAINING, not equal to: on a room page the line names the room after
    // the job - see the group below - so the job's name is one half of it.
    Finder inBanner(String text) => find.descendant(
          of: find.byType(TopLevelBar),
          matching: find.textContaining(text),
        );

    expect(inBanner('Bessey Hall'), findsOneWidget);

    p.setProjectField(stakeholder: 'Facilities');
    await tester.pump();
    expect(inBanner('Bessey Hall - unsaved'), findsOneWidget);
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
    // The LAST control on the banner — the per-tab export menu, which is the
    // end of the document row now that Save, Undo and Help have gone up to the
    // title bar.
    final lastOnBanner = tester.getRect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.byKey(const ValueKey('export_tab_menu')),
      ),
    );
    expect(lastOnBanner.right, closeTo(banner.right, 1),
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
    final lastOnBanner = tester.getRect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.byKey(const ValueKey('export_tab_menu')),
      ),
    );
    expect(lastOnBanner.right, closeTo(banner.right, 1));
    expect(banner.contains(lastOnBanner.centerLeft), isTrue);
  });

  testWidgets('the banner survives the rail being folded away',
      (tester) async {
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    await pump(tester, p);

    await tester.tap(find.byKey(const ValueKey('pane_fold_nav_rail')));
    await tester.pumpAndSettle();

    expect(find.byType(NavRailRow), findsNothing);
    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget,
        reason: 'the way back to the job must not fold away with the rail');
    expect(find.byKey(const ValueKey('banner_app_config')), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  //  WHAT THE BANNER IS ABOUT
  // ---------------------------------------------------------------------------
  //  A session that has only ever opened one room has no job in front of it.
  //  The way in to the Project tab used to be offered anyway, which led to an
  //  empty room list answering a question nobody asked — and worse, said
  //  "Project" beside a room, which is the app telling somebody they are
  //  working on something they are not.

  testWidgets('a cold start offers neither - there is nothing open yet',
      (tester) async {
    final p = fresh();
    await pump(tester, p);

    expect(find.byKey(const ValueKey('banner_project')), findsNothing);
    expect(find.byKey(const ValueKey('banner_room')), findsNothing);
    // The way to start one is in the title bar, where the things that BEGIN a
    // session live.
    expect(find.byKey(const ValueKey('new_menu')), findsOneWidget);
  });

  testWidgets('one room and no job says Room, and goes nowhere',
      (tester) async {
    final p = fresh();
    // The state a room load leaves behind, set directly: the loader itself is
    // real file I/O, which a widget test's fake clock never lets finish.
    final roomPath = path.join(dir.path, 'BSS_101_config.json');
    p.roomConfig = {
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '101'},
    };
    p.currentConfigPath = roomPath;
    await pump(tester, p);

    expect(find.byKey(const ValueKey('banner_room')), findsOneWidget);
    expect(find.text('Room'), findsOneWidget);
    expect(find.byKey(const ValueKey('banner_project')), findsNothing);
    // It names the document that IS open rather than a project that is not.
    expect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.text('BSS_101_config.json'),
      ),
      findsOneWidget,
    );

    // Said, not offered: there is nothing here to press, because the only
    // thing it could do is lead to a job that does not exist.
    await tester.tap(find.byKey(const ValueKey('banner_room')));
    await tester.pumpAndSettle();
    expect(p.selectedTabIndex, isNot(AppTab.project.index));
  });

  //  A ROOM THAT HAS BEEN NAMED IS CALLED BY ITS NAME.
  //
  //  Every room on the site is a file called config.json, so the file name on
  //  its own is the one thing that cannot say WHICH room this window is on.
  //  The wizard's generated full room name goes first, the file stays after it.

  testWidgets('a named room says the room name and then the file',
      (tester) async {
    final p = fresh();
    p.roomConfig = {
      'SYSTEM_SETUP': {
        'gve_bldg': 'BSS',
        'gve_room': '101',
        'gui_full_room_name': 'Behavioral and Social Science 101',
      },
    };
    p.currentConfigPath = path.join(dir.path, 'config.json');
    await pump(tester, p);

    expect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.text('Behavioral and Social Science 101 - config.json'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a named room that was never saved still says its name',
      (tester) async {
    final p = fresh();
    p.roomConfig = {
      'SYSTEM_SETUP': {'gui_full_room_name': 'Bessey Hall 103'},
    };
    await pump(tester, p);

    expect(
      find.descendant(
        of: find.byType(TopLevelBar),
        matching: find.text('Bessey Hall 103 - Unsaved room'),
      ),
      findsOneWidget,
    );
  });

  //  THE MODE IS SAID AT A SIZE SOMEBODY READS WITHOUT LOOKING FOR IT.
  //
  //  Which of the two modes this session is in is the thing on the strip that
  //  is worth getting wrong the least, and the button that changes it is the
  //  only control up there that does. Both are bigger than the small buttons
  //  they sit among.

  testWidgets('the mode controls are bigger than the buttons beside them',
      (tester) async {
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    await pump(tester, p);

    final project = tester.getRect(find.byKey(const ValueKey('banner_project')));
    expect(project.height, greaterThanOrEqualTo(44));
    // Taller than the close button that sits next to it.
    final close =
        tester.getRect(find.byKey(const ValueKey('banner_project_close')));
    expect(project.height, greaterThan(close.height));

    // ...and the room label matches it rather than whispering in small print.
    p.closeProject();
    p.roomConfig = {
      'SYSTEM_SETUP': {'gve_bldg': 'BSS'},
    };
    p.currentConfigPath = path.join(dir.path, 'BSS_101_config.json');
    await tester.pump();
    final room = tester.getRect(find.byKey(const ValueKey('banner_room')));
    expect(room.height, greaterThanOrEqualTo(40));

    await tester.pumpAndSettle(const Duration(seconds: 8));
  });

  testWidgets('starting a job puts the way back on the banner',
      (tester) async {
    final p = fresh();
    await pump(tester, p);
    expect(find.byKey(const ValueKey('banner_project')), findsNothing);

    // What New Project does to the state, without the setup dialog in the way.
    p.newProject(name: 'Bessey Hall');
    await tester.pump();

    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget);
    expect(find.byKey(const ValueKey('banner_room')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('banner_project')));
    await tester.pumpAndSettle();
    expect(p.selectedTabIndex, AppTab.project.index);

    // ...and closing it takes the way back off again.
    p.closeProject();
    await tester.pump();
    expect(find.byKey(const ValueKey('banner_project')), findsNothing);
  });

  testWidgets('closing the job from the banner goes back to the room',
      (tester) async {
    final p = fresh();
    p.roomConfig = {
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '101'},
    };
    p.currentConfigPath = path.join(dir.path, 'BSS_101_config.json');
    // Standing in the middle of room work, then up to the job and back.
    p.selectTab(AppTab.cabling.index);
    p.newProject(name: 'Bessey Hall');
    p.selectTab(AppTab.project.index);
    await pump(tester, p);

    expect(find.byKey(const ValueKey('banner_project_close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('banner_project_close')));
    await tester.pumpAndSettle();

    expect(p.hasOpenProject, isFalse);
    // BACK WHERE THE ROOM WORK WAS, not on a tab the app picked: somebody who
    // closed a project from the middle of cabling a room lands in cabling.
    expect(p.selectedTabIndex, AppTab.cabling.index);
    expect(find.byKey(const ValueKey('banner_project')), findsNothing);
    expect(find.byKey(const ValueKey('banner_room')), findsOneWidget);

    await tester.pumpAndSettle(const Duration(seconds: 8));
  });

  testWidgets('the strip is a different colour in each mode', (tester) async {
    // Read without being looked at: the mistake this prevents - working on a
    // room believing it is on the job - is not one anybody makes on purpose.
    final p = fresh();
    p.roomConfig = {'SYSTEM_SETUP': {'gve_bldg': 'BSS'}};
    p.currentConfigPath = path.join(dir.path, 'BSS_101_config.json');
    await pump(tester, p);

    // The bar's OWN Material — the buttons on it build Materials of their own,
    // so the first one under the bar is the strip and the rest are its
    // contents.
    Color fillNow() => tester
        .widgetList<Material>(find.descendant(
          of: find.byType(TopLevelBar),
          matching: find.byType(Material),
        ))
        .firstWhere((m) => m.color != null)
        .color!;

    final inRoom = fillNow();
    expect(inRoom, roomModeBannerFill(Theme.of(tester.element(
      find.byType(TopLevelBar),
    ))));

    p.newProject(name: 'Bessey Hall');
    await tester.pump();
    final inProject = fillNow();
    expect(inProject, isNot(inRoom));
  });

  group('Open File takes either document', () {
    // A room and a job are both a .json in the same folder, and somebody who
    // picks the job out of that folder means to open the job. Being told it
    // is not a room config would be the app refusing to do the obvious thing.

    test('a project is recognised by the name this app writes', () {
      final file = path.join(dir.path, 'bessey$kProjectFileSuffix');
      File(file).writeAsStringSync('{}');
      expect(isProjectFile(file), isTrue);
    });

    test('...and by what is inside it when it has been renamed', () {
      final file = path.join(dir.path, 'the_job.json');
      File(file).writeAsStringSync(jsonEncode({'rooms': [], 'name': 'Job'}));
      expect(isProjectFile(file), isTrue);
    });

    test('a room config is not a project', () {
      final file = path.join(dir.path, 'BSS_101_config.json');
      File(file).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': 'BSS'},
      }));
      expect(isProjectFile(file), isFalse);
    });

    test('and neither is something unreadable', () {
      // The room loader gives a better message about a broken file than the
      // project loader would, so a file nothing can parse goes that way.
      final file = path.join(dir.path, 'broken.json');
      File(file).writeAsStringSync('{ not json');
      expect(isProjectFile(file), isFalse);
      expect(isProjectFile(path.join(dir.path, 'missing.json')), isFalse);
    });
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
    expect(find.text('Start a New Project'), findsNothing);
    // Open stays: it is not the project half of the screen, it is the way in
    // for any of the three documents.
    expect(find.byKey(const ValueKey('start_open_any')), findsOneWidget);
    // ...and it says which job is open rather than leaving them wondering.
    expect(find.textContaining('Bessey Hall is open'), findsOneWidget);
  });

  // ==========================================================================
  //  WHICH DOCUMENT THE PAGE UNDERNEATH IS ABOUT
  // ==========================================================================
  //  With a job open the strip named the job and nothing else, on every tab -
  //  so a reader who opened a building and then went to a room page was
  //  looking at a drawing with the BUILDING's name over it. On a job whose
  //  rooms have never been drawn - the refresh imports, where every room is a
  //  line item and there is no config anywhere - that page was a room editor
  //  with nothing on it and nothing saying so.
  // ==========================================================================

  group('the banner names the page it is over', () {
    /// A job with one real room file on it, and that room open.
    Future<AppStateProvider> jobWithRoom(WidgetTester tester) async {
      final p = fresh();
      p.newProject(name: 'Bessey Hall');
      final roomPath = path.join(dir.path, 'bss103_config.json');
      File(roomPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {
          'gve_bldg': 'BSS',
          'gve_room': '103',
          'gui_full_room_name': 'Bessey Hall 103',
        },
      }));
      expect(p.addRoomToProject(roomPath), isEmpty);
      await tester.runAsync(() => p.openConfigAtPath(roomPath));
      return p;
    }

    String bannerLine(WidgetTester tester) {
      // The one Text inside the strip that is neither a button nor the mode
      // chip: the widest one, which is the name line.
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(TopLevelBar),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? '')
          .where((t) => t.isNotEmpty)
          .toList();
      return texts.firstWhere(
        (t) => t.contains('Bessey Hall'),
        orElse: () => texts.join(' | '),
      );
    }

    testWidgets('a room page under a job names them both', (tester) async {
      final p = await jobWithRoom(tester);
      p.selectTab(AppTab.cost.index);
      await pump(tester, p);

      final line = bannerLine(tester);
      expect(line, contains('Bessey Hall'), reason: 'the job is still named');
      expect(
        line,
        contains('Bessey Hall 103'),
        reason: 'and so is the room the page is actually about',
      );
      expect(line, contains('bss103_config.json'));
    });

    testWidgets('the Project tab names the job alone', (tester) async {
      final p = await jobWithRoom(tester);
      p.selectTab(AppTab.project.index);
      await pump(tester, p);

      // That page IS the job, so a room name on it would be naming something
      // the reader is not looking at.
      expect(bannerLine(tester), isNot(contains('bss103_config.json')));
    });

    testWidgets('a job with no room open says so on a room page', (
      tester,
    ) async {
      // The refresh imports exactly: thirty-four buildings of line items and
      // not one config file. The job's own name standing over an empty room
      // editor reads as that being the document on screen.
      final p = fresh();
      p.newProject(name: 'Acker Gymnasium refresh');
      p.addProjectManualRoom(name: 'AGYM 129');
      p.selectTab(AppTab.cost.index);
      await pump(tester, p);

      expect(find.textContaining('no room open'), findsOneWidget);
    });
  });

  // ==========================================================================
  //  THE WAY OUT OF A ROOM
  // ==========================================================================
  //  A job could be closed and a room could only ever be SWAPPED - for another
  //  room, or for a new one off the template. So the empty session this app
  //  starts the day on could not be got back to without restarting it.
  // ==========================================================================

  group('closing the room', () {
    testWidgets('a room on its own closes to the start screen', (tester) async {
      final p = fresh();
      final roomPath = path.join(dir.path, 'bss103_config.json');
      File(roomPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
      }));
      await tester.runAsync(() => p.openConfigAtPath(roomPath));
      p.selectTab(AppTab.cost.index);
      await pump(tester, p);

      expect(find.byKey(const ValueKey('banner_room')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('banner_room_close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(p.roomConfig, isEmpty);
      expect(p.currentConfigPath, isEmpty);
      // Nothing open is the start screen, which is what this app shows when
      // there is no config and the tab needs one.
      expect(find.text('Create a New File'), findsOneWidget);
      expect(find.byKey(const ValueKey('start_open_any')), findsOneWidget);
      // Past the "closed" bar, which is a timer that would otherwise still be
      // running when the tree comes down.
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('closing the room leaves the job open', (tester) async {
      final p = fresh();
      p.newProject(name: 'Bessey Hall');
      final roomPath = path.join(dir.path, 'bss103_config.json');
      File(roomPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
      }));
      expect(p.addRoomToProject(roomPath), isEmpty);
      await tester.runAsync(() => p.openConfigAtPath(roomPath));
      p.selectTab(AppTab.cost.index);
      await pump(tester, p);

      await tester.tap(find.byKey(const ValueKey('banner_room_close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Closing means the room, not everything on screen - the same bargain
      // closing a job makes with the room.
      expect(p.roomConfig, isEmpty);
      expect(p.hasOpenProject, isTrue);
      expect(find.byKey(const ValueKey('banner_project')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('nothing open offers no room to close', (tester) async {
      await pump(tester, fresh());
      expect(find.byKey(const ValueKey('banner_room_close')), findsNothing);
    });
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
  // -------------------------------------------------------------------------
  //  THREE LEVELS, EACH WITH ITS OWN WAY OUT
  // -------------------------------------------------------------------------
  //  Room, then the job it belongs to, then the estate the job is one of.
  //  Each level says what it is in the same place and closes down to the one
  //  below it, so "where am I" and "how do I get out of here" have one answer
  //  each rather than three.

  testWidgets('a job offers the campus over it', (tester) async {
    final p = fresh();
    await pump(tester, p);
    // Nothing to compare across a campus until there is a job on it.
    expect(find.byKey(const ValueKey('banner_campus_open')), findsNothing);

    p.newProject(name: 'Bessey Hall');
    await tester.pump();
    expect(find.byKey(const ValueKey('banner_campus_open')), findsOneWidget);
  });

  testWidgets('the campus says it is the campus, and closes down to the job',
      (tester) async {
    final p = fresh();
    p.newProject(name: 'Bessey Hall');
    await pump(tester, p);

    await tester.tap(find.byKey(const ValueKey('banner_campus_open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The mode control now reads CAMPUS, in the same shape and size the
    // banner's own uses one level down.
    final campus = find.byKey(const ValueKey('banner_campus'));
    expect(campus, findsOneWidget);
    expect(tester.getRect(campus).height, greaterThanOrEqualTo(44));
    expect(
      tester.getRect(campus).height,
      greaterThan(
        tester.getRect(find.byKey(const ValueKey('campus_close'))).height,
      ),
    );
    // And it can be saved and reopened as a document of its own.
    expect(find.byKey(const ValueKey('campus_save')), findsOneWidget);
    expect(find.byKey(const ValueKey('campus_open')), findsOneWidget);

    // Pressing it is how you stop being in it: back down to the job, whose
    // own X goes back down to the room.
    await tester.tap(campus);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('banner_campus')), findsNothing);
    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('banner_project_close')),
      findsOneWidget,
      reason: 'and the job still closes down to the room',
    );
  });

  for (final width in [1100.0, 1280.0, 1600.0]) {
    testWidgets('the campus bar fits a $width window', (tester) async {
      // The bar carries the mode strip and four controls; on a laptop the
      // four of them with their labels on ran off the right-hand edge, which
      // is a button that cannot be pressed on a screen that had room for it.
      final p = fresh();
      p.newProject(name: 'Bessey Hall');
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const RoomConfigApp(),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('banner_campus_open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const ValueKey('banner_campus')), findsOneWidget);
      // Every control still there, whichever shape it is in.
      for (final key in ['campus_add', 'campus_open', 'campus_save']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(tester.takeException(), isNull, reason: 'overflowed at $width');
    });
  }

}
