import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_backups.dart';

/// A project file is never lost to an empty save: a blank job is refused
/// over a real one, every save keeps a copy beside the file, and each person
/// keeps copies of their own.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('proj_backups'));
  tearDown(() => dir.deleteSync(recursive: true));

  String writeJob(String name, int rooms) {
    final file = path.join(dir.path, 'job_project.json');
    File(file).writeAsStringSync(jsonEncode({
      'name': name,
      'rooms': [
        for (var i = 0; i < rooms; i++) {'id': 'room$i', 'configPath': 'R$i'},
      ],
    }));
    return file;
  }

  test('a blank job is refused over a file that has rooms', () {
    final file = writeJob('600k', 30);
    expect(blankProjectOverJob(BuildingProject(), file), contains('30 rooms'));
    // A real job, or a file with nothing in it, is saved as usual.
    expect(blankProjectOverJob(BuildingProject(name: 'x'), file), isEmpty);
    expect(blankProjectOverJob(BuildingProject(), writeJob('', 0)), isEmpty);
  });

  test('every save keeps a copy beside the file, newest 20', () {
    final file = writeJob('600k', 3);
    final start = DateTime(2026, 10, 16, 12);
    for (var i = 0; i < 25; i++) {
      backUpProjectFile(file, at: start.add(Duration(seconds: i)));
    }
    final kept = Directory(path.join(dir.path, 'project_backups')).listSync();
    expect(kept, hasLength(kProjectBackupsBeside));
  });

  test('your own copies skip an empty file, so it never pushes good ones '
      'out', () {
    final mine = path.join(dir.path, 'mine');
    expect(backUpProjectForUser(writeJob('', 0), mine), isNull);
    final copy = backUpProjectForUser(writeJob('600k', 30), mine);
    expect(copy, isNotNull);
    expect(projectFileRoomCount(copy!), 30);
  });

  test('the same file, whatever the case and slashes', () {
    expect(samePath(r'\\srv\Share\A\job.json', '//srv/share/a/JOB.json'),
        isTrue);
    expect(samePath(r'C:\a\b.json', r'C:\a\c.json'), isFalse);
  });

  test('a closed project is never saved into the file it came from', () async {
    final file = writeJob('600k', 30);
    final p = AppStateProvider(autoLoadSettings: false)
      ..currentProjectPath = file;
    // The empty project a close leaves behind, still pointing at the file.
    final error = await p.saveProject(to: file);
    expect(error, isNotEmpty);
    expect(projectFileRoomCount(file), 30);
  });
}
