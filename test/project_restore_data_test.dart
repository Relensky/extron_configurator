import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_backups.dart';
import 'package:extron_configurator/project_restore_data.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// The workbook carries the whole job, and puts it back.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('restore_data'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A job of two rooms, each with a drawing beside it.
  String makeJob(String root) {
    final project = BuildingProject(name: 'Job')..taxPercent = 9.25;
    final projectFile = path.join(root, 'Job_project.json');
    for (final room in ['ARTS_111', 'THMA_116']) {
      final config = path.join(root, room, 'config.json');
      Directory(path.join(root, room, 'room_files')).createSync(recursive: true);
      File(config).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': room},
      }));
      File(path.join(root, room, 'room_files', '${room}_av_flow.json'))
          .writeAsStringSync(jsonEncode({'nodes': List.filled(500, room)}));
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: BuildingProject.storePath(config, projectFile),
      ));
    }
    File(projectFile).writeAsStringSync(jsonEncode(project.toJson()));
    return projectFile;
  }

  test('the project and every room file go into a hidden tab and come back',
      () async {
    final source = path.join(dir.path, 'source');
    final projectFile = makeJob(source);
    final project = BuildingProject.fromJson(
        jsonDecode(File(projectFile).readAsStringSync()) as Map<String, dynamic>);
    final files = await gatherProjectRestoreFiles(project, projectFile);
    expect(files, hasLength(5));

    final book = buildXlsx([
      XlsxSheet(name: 'Summary', rows: [['Job']]),
      (await projectDataSheetFor(project, projectFile))!,
    ]);
    expect(projectDataSheet(files).rows.length,
        (await projectDataSheetFor(project, projectFile))!.rows.length);
    final workbookXml = utf8.decode(ZipDecoder()
        .decodeBytes(book)
        .findFile('xl/workbook.xml')!
        .content as List<int>);
    expect(workbookXml, contains('state="hidden"'));

    final target = path.join(dir.path, 'back');
    final result = restoreProjectFromWorkbook(book, target);
    expect(result.error, isEmpty);
    expect(result.written, hasLength(5));
    final back = BuildingProject.fromJson(
        jsonDecode(File(result.projectFile).readAsStringSync())
            as Map<String, dynamic>);
    expect(back.rooms, hasLength(2));
    for (final r in back.rooms) {
      final config = BuildingProject.resolvePath(r.configPath, result.projectFile);
      expect(File(config).existsSync(), isTrue);
    }
    expect(
        File(path.join(target, 'THMA_116', 'room_files', 'THMA_116_av_flow.json'))
            .readAsStringSync(),
        File(path.join(source, 'THMA_116', 'room_files', 'THMA_116_av_flow.json'))
            .readAsStringSync());

    // Again over the top: the project is copied aside, rooms there are kept.
    final again = restoreProjectFromWorkbook(book, target);
    expect(again.written, ['Job_project.json']);
    expect(again.kept, hasLength(4));
    expect(Directory(path.join(target, 'restore_backups')).listSync(),
        hasLength(1));
  });

  test('a workbook without the tab says so', () {
    final book = buildXlsx([XlsxSheet(name: 'Summary', rows: [['Job']])]);
    expect(restoreProjectFromWorkbook(book, dir.path).error,
        contains('no Project data tab'));
  });

  test('a room save keeps whole copies beside it, newest 10', () {
    final projectFile = makeJob(dir.path);
    final config = path.join(path.dirname(projectFile), 'ARTS_111', 'config.json');
    final start = DateTime(2026, 10, 16, 12);
    for (var i = 0; i < 12; i++) {
      backUpRoomDocument(config, at: start.add(Duration(seconds: i)));
    }
    final kept = Directory(
            path.join(dir.path, 'ARTS_111', 'room_files', 'backups'))
        .listSync()
        .whereType<Directory>()
        .toList();
    expect(kept, hasLength(kRoomBackupsBeside));
    expect(kept.first.listSync().map((f) => path.basename(f.path)),
        containsAll(['config.json', 'ARTS_111_av_flow.json']));
  });

  test('an empty room is never saved over a real one', () async {
    final projectFile = makeJob(dir.path);
    final config = path.join(path.dirname(projectFile), 'ARTS_111', 'config.json');
    final p = AppStateProvider(autoLoadSettings: false)
      ..currentConfigPath = config
      ..roomConfig = {};
    await expectLater(p.saveCurrentConfigToFile(), throwsStateError);
    expect(roomFileHasContent(config), isTrue);
  });

  test('a campus save keeps copies beside it', () {
    final campus = path.join(dir.path, 'Chico_campus.json');
    File(campus).writeAsStringSync('{"kind":"campus","projects":[]}');
    backUpCampusFile(campus);
    expect(Directory(path.join(dir.path, 'campus_backups')).listSync(),
        hasLength(1));
  });
}
