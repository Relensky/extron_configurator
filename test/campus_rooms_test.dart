import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/campus_file.dart';
import 'package:extron_configurator/campus_lifecycle.dart';
import 'package:extron_configurator/save_actions.dart';

/// A campus is a file built from rooms and projects, and a room can be on one
/// on its own.
void main() {
  late Directory dir;
  late AppStateProvider provider;
  late String projectFile;
  late String roomFile;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('campus_rooms_');
    provider = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = Directory.current.path;
    await provider.loadUiSchema();
    await provider.loadKeyMap();
    await provider.loadAvDeviceLibrary();
    provider.newProject(name: 'Langdon');
    provider.addProjectManualRoomList(
      'LANG 300\t2 Projector 1 Cam 1 Mic\nHOLT 171\t2 Projector',
    );
    projectFile = path.join(dir.path, 'Langdon_project.json');
    expect(await provider.saveProject(to: projectFile), isEmpty);
    final built = await buildLineItemRooms(
      provider,
      List.of(provider.project.manualRooms),
      dir.path,
    );
    expect(built.built, hasLength(2));
    expect(await provider.saveProject(), isEmpty);
    // HOLT 171 goes on the campus by itself, off the project.
    provider.removeRoomFromProject(provider.project.rooms.last.id);
    expect(await provider.saveProject(), isEmpty);
    roomFile = path.join(dir.path, 'HOLT_171', 'config.json');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a room file is told apart from a project', () {
    expect(isRoomConfigFile(roomFile), isTrue);
    expect(isRoomConfigFile(projectFile), isFalse);
  });

  test('a room on the campus is read as a job of one room', () async {
    final campus = await readCampus(
      provider: provider,
      projectPaths: [projectFile, roomFile],
    );
    expect(campus.failed, isEmpty);
    final room = campus.jobs.firstWhere((j) => j.path == roomFile);
    expect(room.name, 'HOLT 171');
    expect(room.rooms, 1);
    expect(room.lifecycle, isNotNull);
  });

  test('saving a campus never rewrites a room as a project', () async {
    final before = File(roomFile).readAsStringSync();
    final result = await stampCampusIntoProjects(
      campusPath: path.join(dir.path, 'North_campus.json'),
      projects: [projectFile, roomFile],
    );
    expect(result.failed, isEmpty);
    expect(result.written, 1);
    expect(File(roomFile).readAsStringSync(), before);
  });
}
