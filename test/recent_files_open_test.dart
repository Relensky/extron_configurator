import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_file.dart';
import 'package:extron_configurator/campus_lifecycle_view.dart'
    show rememberCampusAsRecent;
import 'package:extron_configurator/recent_files.dart';

/// ============================================================================
///  EVERY OPEN AND EVERY SAVE COUNTS
/// ============================================================================
///  The recent list is written by the LOADERS AND THE WRITERS, not by the
///  buttons, and that is the whole of what makes it useful. A room reached from
///  the Project tab is as opened as one picked out of a file dialog - and a
///  list that only knew about the dialog would be a list that forgot the room
///  somebody spent the afternoon in.
///
///  Saving matters as much as opening, because half the documents here are
///  never opened at all: a room comes out of the wizard, a job out of New
///  Project, an estate out of a list assembled by hand. Each of them becomes a
///  file at its first save, and that is when it goes on the list.
///
///  The one open that is NOT recorded is the app walking the job on somebody's
///  behalf - see the Save All sweep at the end.
///
///  What is held here: that either kind of document, opened or written, lands
///  on its own list under the name it calls itself, and that the lists never
///  mix.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_recent_open'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A room file with a name of its own, so the list has something to show
  /// that is not the file name.
  String room(String stem, {String named = ''}) {
    final file = path.join(dir.path, '$stem.json');
    File(file).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gve_bldg': 'BSS',
        'gve_room': '103',
        if (named.isNotEmpty) 'gui_full_room_name': named,
      },
    }));
    return file;
  }

  String job(String stem, {String named = ''}) {
    final file = path.join(dir.path, '${stem}_project.json');
    File(file).writeAsStringSync(
      jsonEncode(BuildingProject(name: named, building: stem).toJson()),
    );
    return file;
  }

  // autoLoadSettings: false keeps the developer's own app_config.json out of
  // it — the list is held in memory here and never written.
  AppStateProvider fresh() => AppStateProvider(autoLoadSettings: false);

  test('opening a room puts it on the room list, by its own name', () async {
    final p = fresh();
    final file = room('bss103', named: 'Behavioral And Social Science 103');
    expect(await p.openConfigAtPath(file), isTrue);

    final entry = p.recentFiles[RecentKind.room].single;
    expect(entry.file, file);
    // THE NAME IN THE CONFIG, not the file name. A folder of rooms is a folder
    // of codes, and a menu of codes is a menu somebody has to decode.
    expect(entry.label, 'Behavioral And Social Science 103');
    expect(p.recentFiles[RecentKind.project], isEmpty);
    expect(p.recentFiles[RecentKind.campus], isEmpty);
  });

  test('a room with no name of its own is listed by its file', () async {
    final p = fresh();
    expect(await p.openConfigAtPath(room('bss103')), isTrue);
    expect(p.recentFiles[RecentKind.room].single.label, 'bss103');
  });

  test('opening a project puts it on the project list', () async {
    final p = fresh();
    final file = job('bessey', named: 'Bessey Hall');
    expect(await p.openProject(file), '');

    expect(p.recentFiles[RecentKind.project].single.label, 'Bessey Hall');
    expect(p.recentFiles[RecentKind.room], isEmpty);
  });

  test('a file that will not open does not go on the list', () async {
    // A list of things somebody TRIED to open is a list of dead ends.
    final p = fresh();
    final broken = path.join(dir.path, 'broken.json');
    File(broken).writeAsStringSync('{ not json');

    expect(await p.openConfigAtPath(broken), isFalse);
    expect(await p.openProject(broken), isNot(''));
    expect(p.recentFiles.isEmpty, isTrue);
  });

  test('switching between two rooms all afternoon keeps two lines', () async {
    final p = fresh();
    final a = room('a', named: 'Room A');
    final b = room('b', named: 'Room B');
    for (int i = 0; i < 6; i++) {
      await p.openConfigAtPath(a);
      await p.openConfigAtPath(b);
    }

    expect(p.recentFiles[RecentKind.room], hasLength(2));
    expect(p.recentFiles[RecentKind.room].first.label, 'Room B');
  });

  test('forgetting and clearing go through the provider', () async {
    final p = fresh();
    final a = room('a', named: 'Room A');
    await p.openConfigAtPath(a);
    await p.openProject(job('bessey', named: 'Bessey Hall'));

    await p.forgetRecentFile(RecentKind.room, a);
    expect(p.recentFiles[RecentKind.room], isEmpty);
    expect(p.recentFiles[RecentKind.project], hasLength(1));

    await p.clearRecentFiles();
    expect(p.recentFiles.isEmpty, isTrue);
  });

  testWidgets('opening a campus puts it on the campus list', (tester) async {
    // BOTH DOORS, ONE LIST. Open File hands a campus to the sheet, and the
    // sheet's own Open button replaces the estate without going through that -
    // so the recording sits in the one function both of them call.
    final p = fresh();
    // Written and built synchronously: a widget test runs in a fake-async
    // zone, where a Future waiting on the disk never completes at all.
    final file = path.join(dir.path, 'chico_campus.json');
    File(file).writeAsStringSync(jsonEncode(
        {'kind': 'campus', 'name': 'Chico campus', 'projects': <String>[]}));
    const campus =
        CampusFile(name: 'Chico campus', projects: [], file: 'CAMPUS_FILE');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              // Behind a press rather than in the builder: the real caller is
              // an Open button, and recording from inside a build would be
              // notifying listeners mid-build.
              onPressed: () => rememberCampusAsRecent(
                context,
                CampusFile(
                    name: campus.name, projects: campus.projects, file: file),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();

    expect(p.recentFiles[RecentKind.campus].single.label, 'Chico campus');
    expect(p.recentFiles[RecentKind.campus].single.file, file);
    expect(p.recentFiles[RecentKind.project], isEmpty);
  });

  testWidgets('a campus nobody has saved has no file to remember',
      (tester) async {
    final p = fresh();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => rememberCampusAsRecent(
                context,
                const CampusFile(name: 'Assembled just now', projects: []),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();

    expect(p.recentFiles.isEmpty, isTrue);
  });

  group('saving', () {
    test('saving a room in place puts it on the list', () async {
      // A ROOM BUILT IN THE WIZARD HAS NEVER BEEN OPENED. Without this the
      // only way onto the list would be to close it and open it again.
      final p = fresh();
      final file = room('bss103', named: 'BSS 103');
      p
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'BSS 103'}
        }
        ..currentConfigPath = file;

      expect(await p.saveRoomInPlace(), file);
      expect(p.recentFiles[RecentKind.room].single.label, 'BSS 103');
    });

    test('saving a project puts it on the list', () async {
      final p = fresh()..newProject(name: 'Bessey Hall');
      final file = path.join(dir.path, 'bessey_project.json');

      expect(await p.saveProject(to: file), '');
      expect(p.recentFiles[RecentKind.project].single.label, 'Bessey Hall');
      expect(p.recentFiles[RecentKind.project].single.file, file);
    });

    test('a Save As moves the entry to the file now being worked from',
        () async {
      // Both files exist afterwards, but only one of them is the job this
      // session is on - and that is the one the list should reopen.
      final p = fresh()..newProject(name: 'Bessey Hall');
      final first = path.join(dir.path, 'bessey_project.json');
      final second = path.join(dir.path, 'bessey_v2_project.json');
      await p.saveProject(to: first);
      await p.saveProject(to: second);

      final list = p.recentFiles[RecentKind.project];
      expect(list, hasLength(2));
      expect(list.first.file, second);
    });

    test('saving the same room twice keeps one line', () async {
      final p = fresh();
      final file = room('bss103', named: 'BSS 103');
      p
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'BSS 103'}
        }
        ..currentConfigPath = file;

      await p.saveRoomInPlace();
      await p.saveRoomInPlace();
      await p.saveRoomInPlace();
      expect(p.recentFiles[RecentKind.room], hasLength(1));
    });

    test('a room the app opens on somebody behalf is not recorded', () async {
      // THE SAVE ALL SWEEP. It walks every room of the job to photograph it,
      // and nine rooms swept through in one press would push a week of real
      // history off the list - so that walk passes remember: false.
      final p = fresh();
      await p.openConfigAtPath(room('a', named: 'Room A'));
      expect(
        await p.openConfigAtPath(room('b', named: 'Room B'), remember: false),
        isTrue,
      );

      // The room is genuinely open - it is only the list that was left alone.
      expect(p.currentConfigPath, endsWith('b.json'));
      expect(p.recentFiles[RecentKind.room].single.label, 'Room A');
    });
  });

  test('the lists are written into app_config.json with the settings', () async {
    final p = fresh();
    await p.openConfigAtPath(room('bss103', named: 'BSS 103'));
    await p.openProject(job('bessey', named: 'Bessey Hall'));

    // SETTINGS, NOT SESSION. The list has to survive closing the app, and the
    // one file that does that is the one every other preference lives in.
    final saved = p.settingsAsJson()['recentFiles'];
    final back = RecentFiles.fromJson(saved);
    expect(back[RecentKind.room].single.label, 'BSS 103');
    expect(back[RecentKind.project].single.label, 'Bessey Hall');
  });
}
