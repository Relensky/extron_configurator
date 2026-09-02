import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/online_copy.dart';
import 'package:extron_configurator/project_view.dart';

/// THE COPY SOMEBODY ELSE CAN READ.
///
/// The app runs on one machine and the people who ask about a job do not sit
/// at it. Publishing writes the workbook into a folder OneDrive or Google
/// Drive already syncs, so the job opens in Excel Online or as a Google Sheet
/// without an account to connect or an app to register.
///
/// The failures worth guarding are all about TRUST IN THE COPY. A file name
/// that drifts breaks the share link somebody sent in March. A "published"
/// stamp set when nothing was written tells the one lie nobody could catch,
/// because the stamp is the only thing saying how stale the sheet being read
/// is. And a publish that quietly swallowed a locked file would leave somebody
/// quoting last month's figures off a copy they believed was current.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_online_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider job({String name = 'Bessey Hall'}) {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: name);
    final file = path.join(dir.path, 'bss101_config.json');
    File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
    p.addRoomToProject(file);
    return p;
  }

  String syncFolder() {
    final folder = path.join(dir.path, 'OneDrive', 'AV jobs');
    Directory(folder).createSync(recursive: true);
    return folder;
  }

  group('publishing', () {
    test('writes the workbook and the project file, and says what it wrote',
        () async {
      final p = job();
      final folder = syncFolder();

      final result = await p.publishOnlineCopy(folder: folder);

      expect(result.failed, isEmpty);
      expect(result.written, [
        'Bessey_Hall_project.xlsx',
        'Bessey_Hall_project.json',
      ]);
      for (final name in result.written) {
        expect(File(path.join(folder, name)).existsSync(), isTrue);
      }

      // A real workbook, not an empty file: it has to open at the other end.
      final archive = ZipDecoder().decodeBytes(
        File(path.join(folder, 'Bessey_Hall_project.xlsx')).readAsBytesSync(),
      );
      expect(
        archive.files.any((f) => f.name == 'xl/workbook.xml'),
        isTrue,
      );

      // And the project file beside it is the job, openable from there.
      final back = BuildingProject.fromJson(
        jsonDecode(
          File(path.join(folder, 'Bessey_Hall_project.json')).readAsStringSync(),
        ) as Map<String, dynamic>,
      );
      expect(back.name, 'Bessey Hall');
      expect(back.rooms, hasLength(1));
    });

    test('the second publish rewrites the same names', () async {
      final p = job();
      final folder = syncFolder();

      await p.publishOnlineCopy(folder: folder);
      await p.publishOnlineCopy(folder: folder);

      // THE WHOLE TRICK. A share link points at a FILE, so a second publish
      // that wrote Bessey_Hall_project(1).xlsx would leave everybody reading
      // the March figures through a link that still worked.
      final names = Directory(folder)
          .listSync()
          .map((f) => path.basename(f.path))
          .toList()
        ..sort();
      expect(names, ['Bessey_Hall_project.json', 'Bessey_Hall_project.xlsx']);
    });

    test('the folder is remembered, and the moment recorded', () async {
      final p = job();
      final folder = syncFolder();
      expect(p.project.onlinePublishedAt, isNull);

      await p.publishOnlineCopy(folder: folder);

      expect(p.project.onlineFolder, folder);
      expect(
        p.project.onlinePublishedAt!.difference(DateTime.now()).abs().inMinutes,
        lessThan(5),
      );
      // A second press needs no folder: the job knows where it goes.
      final again = await p.publishOnlineCopy();
      expect(again.folder, folder);
      expect(again.written, isNotEmpty);

      expect(
        p.project.history.where((h) => h.field == 'Online copy'),
        isNotEmpty,
      );
    });

    test('a folder that cannot be written says so and sets no stamp', () async {
      final p = job();
      // A path with a FILE where a folder should be: the write fails the way a
      // folder somebody deleted or has no rights to does.
      final blocked = path.join(dir.path, 'not_a_folder');
      File(blocked).writeAsStringSync('');

      final result = await p.publishOnlineCopy(folder: blocked);

      expect(result.written, isEmpty);
      expect(result.failed, isNotEmpty);
      // NOT stamped. A job that says it was published just now, over a copy
      // that was never written, is the one lie nobody reading the sheet could
      // catch.
      expect(p.project.onlinePublishedAt, isNull);
    });

    test('nowhere to publish is refused rather than guessed at', () async {
      final p = job();
      final result = await p.publishOnlineCopy();

      expect(result.written, isEmpty);
      expect(result.failed.single, contains('no folder'));
      expect(p.project.onlinePublishedAt, isNull);
    });

    test('the workbook alone, when the project file is not wanted', () async {
      final p = job();
      final folder = syncFolder();

      final result =
          await p.publishOnlineCopy(folder: folder, includeProjectFile: false);

      expect(result.written, ['Bessey_Hall_project.xlsx']);
      expect(
        File(path.join(folder, 'Bessey_Hall_project.json')).existsSync(),
        isFalse,
      );
    });
  });

  group('the button on the Project tab', () {
    Future<void> openTab(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1700, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('opens the box, which says it has never been published', (
      tester,
    ) async {
      final p = job();
      await openTab(tester, p);

      await tester.tap(find.byKey(const ValueKey('project_online_copy')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('online_copy_dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('online_copy_freshness')))
            .data,
        contains('Not published'),
      );
      // Nothing to publish into yet, so the button that would write files is
      // not offering to.
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('online_copy_publish')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('publishes into the folder the job already knows', (
      tester,
    ) async {
      final p = job();
      final folder = syncFolder();
      p.setProjectOnlineFolder(folder);
      await openTab(tester, p);

      await tester.tap(find.byKey(const ValueKey('project_online_copy')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('online_copy_folder')))
            .data,
        folder,
      );

      // Real file I/O, so it runs outside the fake clock - a pumpAndSettle
      // over a spinner that is waiting on a disk write never settles.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('online_copy_publish')));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();

      expect(
        File(path.join(folder, 'Bessey_Hall_project.xlsx')).existsSync(),
        isTrue,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('online_copy_result')))
            .data,
        contains('written'),
      );
      expect(p.project.onlinePublishedAt, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  //  THE OTHER TWO SCOPES
  // -------------------------------------------------------------------------
  //  A job is not the only thing people ask about. "What is in BSS 103" is a
  //  room and "what does the estate need next year" is a campus, and all three
  //  land in ONE folder under names that sort beside each other — which is
  //  what makes it a set of records rather than three features' output.

  group('publishing a room', () {
    test('writes the room workbook and the room config, named for the room',
        () async {
      final file = path.join(dir.path, 'bss103_config.json');
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"103"}}',
      );
      final p = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = file
        ..roomConfig = {
          'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
        };
      final f = syncFolder();

      final result = await p.publishRoomOnlineCopy(folder: f);

      expect(result.failed, isEmpty);
      expect(result.written, ['BSS_103_room.xlsx', 'BSS_103_room_config.json']);
      // Beside the job and the campus, under a name that sorts with them.
      for (final name in result.written) {
        expect(File(path.join(f, name)).existsSync(), isTrue);
      }
      // The folder is remembered for everything else that publishes.
      expect(p.onlineFolder, f);
    });

    test('no room open is said, not guessed at', () async {
      final p = AppStateProvider(autoLoadSettings: false);
      final result = await p.publishRoomOnlineCopy(folder: syncFolder());
      expect(result.written, isEmpty);
      expect(result.failed.single, contains('no room'));
    });
  });

  group('publishing a campus', () {
    test('writes the plan and the campus file beside the jobs it lists',
        () async {
      final p = AppStateProvider(autoLoadSettings: false);
      final f = syncFolder();
      final campusFile = path.join(dir.path, 'chico_campus.json');
      File(campusFile).writeAsStringSync(
        '{"kind":"campus","name":"Chico","projects":[]}',
      );

      final result = await p.publishCampusOnlineCopy(
        workbook: Uint8List.fromList([1, 2, 3]),
        stem: 'Chico',
        folder: f,
        campusFilePath: campusFile,
      );

      expect(result.written, ['Chico_campus.xlsx', 'Chico_campus.json']);
      // The campus file is COPIED, not re-serialized: it is somebody's
      // document and may have been hand-edited.
      expect(
        File(path.join(f, 'Chico_campus.json')).readAsStringSync(),
        contains('"name":"Chico"'),
      );
    });

    test('a campus file that cannot be read still publishes the plan',
        () async {
      final p = AppStateProvider(autoLoadSettings: false);
      final f = syncFolder();

      final result = await p.publishCampusOnlineCopy(
        workbook: Uint8List.fromList([1, 2, 3]),
        stem: 'Chico',
        folder: f,
        campusFilePath: path.join(dir.path, 'gone.json'),
      );

      // The half that could be written was written, which is what somebody
      // asked for. Half a publish beats none.
      expect(result.written, ['Chico_campus.xlsx']);
    });

    test('nowhere to publish is refused rather than guessed at', () async {
      final p = AppStateProvider(autoLoadSettings: false);
      final result = await p.publishCampusOnlineCopy(
        workbook: Uint8List.fromList([1]),
        stem: 'Chico',
      );
      expect(result.written, isEmpty);
      expect(result.failed.single, contains('no folder'));
    });
  });

  group('the file names', () {
    test('are the job, made safe, and fall back rather than come out blank',
        () {
      expect(
        onlineWorkbookName(BuildingProject(name: 'Bessey Hall: phase 2')),
        'Bessey_Hall_phase_2_project.xlsx',
      );
      expect(
        onlineProjectFileName(BuildingProject(building: 'BSS')),
        'BSS_project.json',
      );
      expect(onlineFileStem(BuildingProject()), 'project');
    });
  });

  group('how stale the copy is', () {
    test('is said in days, because the days are the question', () {
      final now = DateTime(2026, 4, 20);
      expect(onlineFreshnessText(null), contains('Not published'));
      expect(
        onlineFreshnessText(DateTime(2026, 4, 20, 9), asOf: now),
        'Published today.',
      );
      expect(
        onlineFreshnessText(DateTime(2026, 4, 19), asOf: now),
        'Published yesterday.',
      );
      expect(
        onlineFreshnessText(DateTime(2026, 4, 15), asOf: now),
        'Published 5 days ago.',
      );
      // Past a fortnight it stops being a fact and starts being a warning.
      expect(
        onlineFreshnessText(DateTime(2026, 3, 1), asOf: now),
        contains('stale'),
      );
    });
  });

  group('the file', () {
    test('carries where it is published and when it last went', () {
      final project = BuildingProject(name: 'Bessey Hall')
        ..onlineFolder = r'C:\Users\me\OneDrive\AV jobs'
        ..onlinePublishedAt = DateTime(2026, 4, 20, 9, 30);

      final json = project.toJson();
      expect(json['onlineFolder'], r'C:\Users\me\OneDrive\AV jobs');

      final back = BuildingProject.fromJson(json);
      expect(back.onlineFolder, r'C:\Users\me\OneDrive\AV jobs');
      expect(back.onlinePublishedAt, DateTime(2026, 4, 20, 9, 30));

      // And an undo copy keeps both, so undoing a room removal does not lose
      // where the job publishes.
      expect(back.clone().onlineFolder, back.onlineFolder);
      expect(back.clone().onlinePublishedAt, back.onlinePublishedAt);
    });

    test('a job nobody has published writes no keys for it', () {
      final json = BuildingProject(name: 'Bessey Hall').toJson();
      expect(json.containsKey('onlineFolder'), isFalse);
      expect(json.containsKey('onlinePublishedAt'), isFalse);
    });
  });
}
