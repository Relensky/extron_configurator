import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/online_index.dart';

/// THE INDEX THAT JOINS THE FOLDER UP.
///
/// Publishing put a campus, its jobs and their rooms into one folder. That
/// makes it browsable and not readable: eleven jobs and ninety rooms is a
/// hundred files, and somebody opening it cold cannot tell which rooms are in
/// Bessey or which job is on which campus.
///
/// The failures worth guarding are the ones that would make the index lie. An
/// index that forgot everything published before this morning. A room
/// republished on its own erasing the link its job recorded. A child the index
/// silently dropped because it has never been published — which is the row
/// somebody opening the index is most often looking for.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_index_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String folder() {
    final f = path.join(dir.path, 'OneDrive');
    Directory(f).createSync(recursive: true);
    return f;
  }

  /// A job with two rooms on it, saved to its own file so the index has a path
  /// to join by.
  Future<AppStateProvider> job() async {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final stem in ['bss101', 'bss103']) {
      final file = path.join(dir.path, '${stem}_config.json');
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"${stem.substring(3)}"}}',
      );
      p.addRoomToProject(file);
    }
    await p.saveProject(to: path.join(dir.path, 'bessey_project.json'));
    return p;
  }

  Map<String, dynamic> indexJson(String folder) => jsonDecode(
    File(path.join(folder, kOnlineIndexJson)).readAsStringSync(),
  ) as Map<String, dynamic>;

  List<Map<String, dynamic>> entriesIn(String folder) => [
    for (final e in indexJson(folder)['entries'] as List)
      Map<String, dynamic>.from(e as Map),
  ];

  group('a publish writes the index', () {
    test('the job lands on it, with its rooms named', () async {
      final p = await job();
      final f = folder();

      final result = await p.publishOnlineCopy(folder: f);

      // The index is NOT one of the documents: 'the workbook and the project
      // file and index.xlsx and index.json' reads as four things when two were
      // asked for.
      expect(result.written, [
        'Bessey_Hall_project.xlsx',
        'Bessey_Hall_project.json',
      ]);
      expect(File(path.join(f, kOnlineIndexJson)).existsSync(), isTrue);
      expect(File(path.join(f, kOnlineIndexWorkbook)).existsSync(), isTrue);

      final entries = entriesIn(f);
      expect(entries, hasLength(1));
      expect(entries.single['kind'], 'project');
      expect(entries.single['name'], 'Bessey Hall');
      expect(entries.single['children'], hasLength(2));
      expect(entries.single['note'], contains('2 rooms'));
      // Joined by the PATH each document carries, not by a name that collides
      // or a stem that drifts when somebody renames a job.
      expect(
        entries.single['source'],
        path.join(dir.path, 'bessey_project.json'),
      );
    });

    test('a room published after it joins up underneath', () async {
      final p = await job();
      final f = folder();
      await p.publishOnlineCopy(folder: f);

      final roomFile = path.join(dir.path, 'bss103_config.json');
      p
        ..currentConfigPath = roomFile
        ..roomConfig = {
          'SYSTEM_SETUP': {
            'gve_bldg': 'BSS',
            'gve_room': '103',
            'gui_full_room_name': 'Bessey 103 Lecture Hall',
          },
        };
      await p.publishRoomOnlineCopy(folder: f);

      final entries = entriesIn(f);
      expect(entries, hasLength(2), reason: 'the job is still on it');
      final room = entries.firstWhere((e) => e['kind'] == 'room');
      expect(room['name'], 'BSS 103');
      expect(room['note'], 'Bessey 103 Lecture Hall');
      // The room knows its job, because the job was open when it published.
      expect(room['parent'], path.join(dir.path, 'bessey_project.json'));
    });

    test('the sheet says which rooms are not in the folder yet', () async {
      final p = await job();
      final f = folder();
      await p.publishOnlineCopy(folder: f);

      final archive = ZipDecoder().decodeBytes(
        File(path.join(f, kOnlineIndexWorkbook)).readAsBytesSync(),
      );
      final sheet = utf8.decode(
        archive.files
            .firstWhere((x) => x.name == 'xl/worksheets/sheet1.xml')
            .content as List<int>,
      );

      expect(sheet, contains('Bessey Hall'));
      // THE ROW SOMEBODY IS LOOKING FOR: a room on the job that is not in this
      // folder, so they stop hunting for a file that was never published.
      expect(sheet, contains('On the job but not in this folder'));
      expect(sheet, contains('bss101_config'));
      expect(sheet, contains('0 of 2 rooms published'));
    });
  });

  group('it accumulates rather than replaces', () {
    test('a campus published later keeps the job that was there', () async {
      final p = await job();
      final f = folder();
      await p.publishOnlineCopy(folder: f);

      final campusFile = path.join(dir.path, 'chico_campus.json');
      File(campusFile).writeAsStringSync('{"kind":"campus","projects":[]}');
      await p.publishCampusOnlineCopy(
        workbook: Uint8List.fromList([1, 2, 3]),
        stem: 'Chico',
        name: 'Chico campus',
        folder: f,
        campusFilePath: campusFile,
        jobs: [(path: path.join(dir.path, 'bessey_project.json'), name: 'Bessey Hall')],
      );

      final entries = entriesIn(f);
      expect(entries.map((e) => e['kind']), containsAll(['campus', 'project']));
      // Campus first, then the jobs on it: the order the folder is read in.
      expect(entries.first['kind'], 'campus');
      expect(entries.first['note'], '1 job');
      expect(
        entries.first['children'].single,
        path.join(dir.path, 'bessey_project.json'),
      );
    });

    test('republishing one room does not erase what the job recorded', () {
      final job = (
        kind: 'project',
        name: 'Bessey Hall',
        source: r'C:\AV\bessey_project.json',
        parent: r'C:\AV\chico_campus.json',
        children: [r'C:\AV\bss103_config.json'],
        files: ['Bessey_Hall_project.xlsx'],
        note: '1 room',
        at: DateTime(2026, 4, 1),
      );
      // A room published on its own cannot say which job it is in.
      final room = (
        kind: 'room',
        name: 'BSS 103',
        source: r'C:\AV\bss103_config.json',
        parent: '',
        children: <String>[],
        files: ['BSS_103_room.xlsx'],
        note: '',
        at: DateTime(2026, 4, 2),
      );

      var index = mergeOnlineIndex([job], [room]);
      expect(index, hasLength(2));

      // Published again later, still on its own: the link the job recorded is
      // not lost, and neither is the job's own parent.
      final withLink = mergeOnlineIndex(index, [
        (
          kind: 'room',
          name: 'BSS 103',
          source: r'C:\AV\bss103_config.json',
          parent: r'C:\AV\bessey_project.json',
          children: <String>[],
          files: ['BSS_103_room.xlsx'],
          note: '',
          at: DateTime(2026, 4, 3),
        ),
      ]);
      index = mergeOnlineIndex(withLink, [room]);
      expect(
        index.firstWhere((e) => e.kind == 'room').parent,
        r'C:\AV\bessey_project.json',
        reason: 'saying nothing must not read as saying "no parent"',
      );
      expect(index.firstWhere((e) => e.kind == 'project').children, hasLength(1));
    });

    test('the same document published twice is one row, freshly dated', () {
      final first = (
        kind: 'project',
        name: 'Bessey Hall',
        source: r'C:\AV\bessey_project.json',
        parent: '',
        children: <String>[],
        files: ['Bessey_Hall_project.xlsx'],
        note: '2 rooms',
        at: DateTime(2026, 4, 1),
      );
      // The same file, spelled the way another document happens to carry it.
      final again = (
        kind: 'project',
        name: 'Bessey Hall',
        source: r'C:/AV/BESSEY_PROJECT.JSON',
        parent: '',
        children: <String>[],
        files: ['Bessey_Hall_project.xlsx'],
        note: '3 rooms',
        at: DateTime(2026, 5, 1),
      );

      final index = mergeOnlineIndex([first], [again]);
      expect(index, hasLength(1));
      expect(index.single.at, DateTime(2026, 5, 1));
      expect(index.single.note, '3 rooms');
    });
  });

  group('the file itself', () {
    test('a corrupt index is rebuilt rather than fatal', () async {
      final p = await job();
      final f = folder();
      File(path.join(f, kOnlineIndexJson)).writeAsStringSync('not json {{');

      final result = await p.publishOnlineCopy(folder: f);

      // An index is a convenience built from the folder's own contents. A
      // corrupt one must never be the reason a publish fails.
      expect(result.failed, isEmpty);
      expect(entriesIn(f), hasLength(1));
    });

    test('nothing written means no index claiming otherwise', () async {
      final p = await job();
      final blocked = path.join(dir.path, 'not_a_folder');
      File(blocked).writeAsStringSync('');

      final result = await p.publishOnlineCopy(folder: blocked);

      expect(result.written, isEmpty);
      expect(File(path.join(blocked, kOnlineIndexJson)).existsSync(), isFalse);
    });
  });
}
