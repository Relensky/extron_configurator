import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';

/// The job keeps a note of what each room's files said, brings it up to date
/// on opening, and only re-reads a room whose files changed.
void main() {
  late Directory dir;
  late String projectFile;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_room_check'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvNode device(String id, String model) => AvNode(
    id: id,
    label: model,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  String costFile(String name) =>
      path.join(dir.path, name, 'room_files', '${name}_cost.json');

  void writeCost(String name, Map<String, double> prices) {
    File(costFile(name)).writeAsStringSync(jsonEncode({
      'cost': {'currency': r'$', 'priceOverrides': prices},
    }));
  }

  String writeRoom(String name, String model) {
    final folder = Directory(path.join(dir.path, name, 'room_files'))
      ..createSync(recursive: true);
    final config = path.join(dir.path, name, 'config.json');
    File(config).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(folder.path, '${name}_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [device('n1', model).toJson()],
    }));
    writeCost(name, const {});
    return config;
  }

  AppStateProvider provider() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path;
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'Display X',
        manufacturer: 'Generic',
        category: 'Display',
        price: 1000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'Camera Y',
        manufacturer: 'Generic',
        category: 'Camera',
        price: 2000,
        ports: [],
      ));
    return p;
  }

  Future<void> makeProject() async {
    final p = provider()..newProject(name: 'Check');
    p.addRoomToProject(writeRoom('A', 'Display X'));
    p.addRoomToProject(writeRoom('B', 'Camera Y'));
    projectFile = path.join(dir.path, 'Check_project.json');
    expect(await p.saveProject(to: projectFile), isEmpty);
  }

  /// Moves a file's time on, so a change is seen however fast the test runs.
  void touch(String file, int minutes) => File(file).setLastModifiedSync(
    DateTime.now().add(Duration(minutes: minutes)),
  );

  BuildingProject onDisk() => BuildingProject.fromJson(
    jsonDecode(File(projectFile).readAsStringSync()) as Map<String, dynamic>,
  );

  test('opening a job never writes it; the check goes with the next save',
      () async {
    await makeProject();
    final stamp = File(projectFile).lastModifiedSync();
    final bytes = File(projectFile).readAsStringSync();
    final p = provider();
    expect(await p.openProject(projectFile), isEmpty);

    expect(p.roomsChangedOnOpen, isEmpty, reason: 'nothing to compare yet');
    expect(p.projectDirty, isFalse);
    expect(File(projectFile).lastModifiedSync(), stamp);
    expect(File(projectFile).readAsStringSync(), bytes);
    expect(onDisk().roomSnapshots, isEmpty);

    expect(await p.saveProject(), isEmpty);
    final saved = onDisk();
    expect(saved.roomSnapshots, hasLength(2));
    expect(
      saved.roomSnapshots.values.map((s) => s.total).toSet(),
      {1000.0, 2000.0},
    );
    expect(saved.roomsCheckedAt, isNotNull);
  });

  test('a room saved elsewhere since is reported on open, not written',
      () async {
    await makeProject();
    final first = provider();
    expect(await first.openProject(projectFile), isEmpty);
    expect(await first.saveProject(), isEmpty);

    writeCost('B', {'model:camera y': 2500});
    touch(costFile('B'), 2);

    final p = provider();
    expect(await p.openProject(projectFile), isEmpty);
    expect(p.roomsChangedOnOpen, hasLength(1));
    expect(p.roomsChangedOnOpen.single.room, 'B');
    expect(p.roomsChangedOnOpen.single.before, 2000);
    expect(p.roomsChangedOnOpen.single.after, 2500);
    expect(p.projectDirty, isFalse, reason: 'nothing the user changed');
    expect(
      onDisk().roomSnapshots.values.map((s) => s.total).toSet(),
      {1000.0, 2000.0},
      reason: 'the file is left as it was',
    );

    // Once somebody saves, it says nothing more.
    expect(await p.saveProject(), isEmpty);
    final again = provider();
    await again.openProject(projectFile);
    expect(again.roomsChangedOnOpen, isEmpty);
  });

  test('a catalog price moving, with no room touched, is not written',
      () async {
    await makeProject();
    final first = provider();
    expect(await first.openProject(projectFile), isEmpty);
    expect(await first.saveProject(), isEmpty);
    final stamp = File(projectFile).lastModifiedSync();
    final checked = onDisk().roomsCheckedAt;

    // Another PC whose catalog prices the camera differently.
    final p = provider();
    p.avDeviceLibrary.upsert(const AvDeviceTemplate(
      model: 'Camera Y',
      manufacturer: 'Generic',
      category: 'Camera',
      price: 2400,
      ports: [],
    ));
    expect(await p.openProject(projectFile), isEmpty);
    expect(p.roomsChangedOnOpen, isEmpty);
    expect(p.projectDirty, isFalse);
    expect(File(projectFile).lastModifiedSync(), stamp);
    expect(onDisk().roomsCheckedAt, checked);
  });

  test('a device pricing an unchanged room lower never lowers the job',
      () async {
    await makeProject();
    final first = provider();
    expect(await first.openProject(projectFile), isEmpty);
    expect(await first.saveProject(), isEmpty);

    // A device with a cheaper (wrong) catalog opens the job and saves it.
    final p = provider();
    p.avDeviceLibrary.upsert(const AvDeviceTemplate(
      model: 'Camera Y',
      manufacturer: 'Generic',
      category: 'Camera',
      price: 500,
      ports: [],
    ));
    expect(await p.openProject(projectFile), isEmpty);
    p.project.notes = 'edited';
    expect(await p.saveProject(), isEmpty);
    expect(
      onDisk().roomSnapshots.values.map((s) => s.total).toSet(),
      {1000.0, 2000.0},
    );
  });

  test('opening a room re-reads a room whose files changed', () async {
    await makeProject();
    final p = provider();
    await p.openProject(projectFile);
    expect(p.priceProject().grandTotal, 3000);

    writeCost('B', {'model:camera y': 2500});
    touch(costFile('B'), 2);
    await p.openProjectRoomRef(p.project.rooms.first);

    expect(p.priceProject().grandTotal, 3500);
  });

  test('opening a room keeps a room whose files did not change', () async {
    await makeProject();
    final p = provider();
    await p.openProject(projectFile);
    final before = File(costFile('B')).lastModifiedSync();

    // Different on disk with the same time: only a full re-read would see it,
    // which shows the room was not read again.
    writeCost('B', {'model:camera y': 2500});
    File(costFile('B')).setLastModifiedSync(before);
    await p.openProjectRoomRef(p.project.rooms.first);

    expect(p.priceProject().grandTotal, 3000);
  });
}
