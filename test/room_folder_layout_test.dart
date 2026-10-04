import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_setup_dialog.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// A room saved as `<room>\config.json`, the name the processor reads, with
/// everything else in `<room>\room_files`.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rcb_room_folder');
    AppStateProvider.moveRoomsIntoFolders = true;
  });
  tearDown(() {
    AppStateProvider.moveRoomsIntoFolders = false;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String write(String relative, [Object contents = const {}]) {
    final file = File(path.join(dir.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      contents is String ? contents : jsonEncode(contents),
    );
    return file.path;
  }

  group('paths', () {
    test('a config.json is named for its folder', () {
      final config = path.join('jobs', 'ARTS_111', 'config.json');
      expect(isFolderLayoutConfig(config), isTrue);
      expect(roomStem(config), 'ARTS_111');
      expect(roomFolderPath(config), path.join('jobs', 'ARTS_111', 'room_files'));
      expect(
        roomSidecarPath(config, RoomSidecarPart.cost),
        path.join('jobs', 'ARTS_111', 'room_files', 'ARTS_111_cost.json'),
      );
      expect(roomConfigDisplayName(config), path.join('ARTS_111', 'config.json'));
    });

    test('in the processor\'s layout the room is the folder above code\\'
        'upload_to_root', () {
      final config = path.join(
          'rooms', 'SCI248', 'code', 'upload_to_root', 'config.json');
      expect(roomStem(config), 'SCI248');
      expect(
        roomSidecarPath(config, RoomSidecarPart.cost),
        path.join('rooms', 'SCI248', 'code', 'upload_to_root', 'room_files',
            'SCI248_cost.json'),
      );
      // Only those two folders are stepped over.
      expect(roomStem(path.join('rooms', 'SCI248', 'config.json')), 'SCI248');
      expect(
          roomStem(path.join('upload_to_root', 'config.json')), 'upload_to_root');
    });

    test('files named for upload_to_root are renamed for the room on open, '
        'and still read until then', () {
      final config = write(path.join(
          'rooms', 'SCI248', 'code', 'upload_to_root', 'config.json'));
      final files = path.join(path.dirname(config), 'room_files');
      for (final suffix in ['av_flow', 'cabling', 'cost', 'floor_plans',
          'history', 'racks']) {
        write(path.relative(
            path.join(files, 'upload_to_root_$suffix.json'),
            from: dir.path));
      }
      write(path.relative(path.join(files, 'upload_to_root_plan.png'),
          from: dir.path), 'png');
      // A part already under the room's name wins over the old one.
      write(path.relative(path.join(files, 'SCI248_cost.json'), from: dir.path),
          {'mine': true});

      // Before the rename the old names are still found.
      expect(
        readableRoomSidecarPath(config, RoomSidecarPart.racks),
        path.join(files, 'upload_to_root_racks.json'),
      );

      final renamed = renameRoomFilesToStem(config);

      expect(renamed.toSet(), {
        'SCI248_av_flow.json',
        'SCI248_cabling.json',
        'SCI248_floor_plans.json',
        'SCI248_history.json',
        'SCI248_racks.json',
      });
      expect(File(path.join(files, 'SCI248_racks.json')).existsSync(), isTrue);
      expect(
          File(path.join(files, 'upload_to_root_racks.json')).existsSync(),
          isFalse);
      // The kept one is untouched, and the old cost file left beside it.
      expect(File(path.join(files, 'SCI248_cost.json')).readAsStringSync(),
          contains('mine'));
      expect(
          File(path.join(files, 'upload_to_root_cost.json')).existsSync(),
          isTrue);
      // Pictures keep their names - the plans name them.
      expect(File(path.join(files, 'upload_to_root_plan.png')).existsSync(),
          isTrue);
      expect(renameRoomFilesToStem(config), isEmpty);
    });

    test('an older room keeps its old paths', () {
      final config = path.join('jobs', 'ARTS_111_config.json');
      expect(isFolderLayoutConfig(config), isFalse);
      expect(roomStem(config), 'ARTS_111_config');
      expect(roomFolderPath(config), path.join('jobs', 'ARTS_111_config'));
    });

    test('a picked file name becomes the room folder', () {
      expect(
        folderLayoutPathFor(path.join('jobs', 'ARTS_111_config.json')),
        path.join('jobs', 'ARTS_111', 'config.json'),
      );
      // Picked from inside the room's own folder: not nested again.
      expect(
        folderLayoutPathFor(path.join('jobs', 'ARTS_111', 'ARTS_111_config.json')),
        path.join('jobs', 'ARTS_111', 'config.json'),
      );
      expect(
        folderLayoutPathFor(path.join('jobs', 'BSS103.json')),
        path.join('jobs', 'BSS103', 'config.json'),
      );
      final already = path.join('jobs', 'ARTS_111', 'config.json');
      expect(folderLayoutPathFor(already), already);
    });

    test('room_files is a room folder; the room folder is not', () {
      final config = write(path.join('ARTS_111', 'config.json'));
      Directory(roomFolderPath(config)).createSync();
      expect(isRoomFolder(roomFolderPath(config)), isTrue);
      expect(isRoomFolder(path.dirname(config)), isFalse);
    });

    test('the project scan finds config.json rooms and skips room_files', () {
      final a = write(path.join('ARTS_111', 'config.json'));
      final b = write(path.join('ARTS_112', 'config.json'));
      write(path.join('ARTS_111', 'room_files', 'ARTS111_old_config.json'));
      expect(findRoomConfigs(dir.path), [a, b]);
    });
  });

  group('moving an older room', () {
    test('files named for config.json itself are read, then moved in under '
        'the name of the room', () {
      final config = write(
          path.join('BSS103', 'code', 'upload_to_root', 'config.json'));
      final dir103 = path.dirname(config);
      write(path.join('BSS103', 'code', 'upload_to_root', 'config_cost.json'),
          {'cost': {}});
      write(path.join('BSS103', 'code', 'upload_to_root', 'config', 'config_racks.json'),
          {'racks': []});

      // Found where they are, before anything moves.
      expect(readableRoomSidecarPath(config, RoomSidecarPart.cost),
          path.join(dir103, 'config_cost.json'));
      expect(readableRoomSidecarPath(config, RoomSidecarPart.racks),
          path.join(dir103, 'config', 'config_racks.json'));

      moveOldConfigFolderIntoRoomFiles(config);
      moveRoomFilesIntoFolder(config);

      expect(readableRoomSidecarPath(config, RoomSidecarPart.cost),
          path.join(dir103, 'room_files', 'BSS103_cost.json'));
      expect(readableRoomSidecarPath(config, RoomSidecarPart.racks),
          path.join(dir103, 'room_files', 'BSS103_racks.json'));
      expect(File(path.join(dir103, 'config_cost.json')).existsSync(), isFalse);
    });

    test('the config, its folder, loose files and pictures all move', () {
      final old = write('ARTS_111_config.json', {'SYSTEM_SETUP': {}});
      write(path.join('ARTS_111_config', 'ARTS_111_config_av_flow.json'));
      write(path.join('ARTS_111_config', 'ARTS_111_config_floorplan.png'), '');
      write('ARTS_111_config_cost.json');
      write('ARTS_111_config_floorplan2.png', '');
      write('ARTS111_old_config.json');
      // Another room's files stay put.
      write('ARTS_112_config.json');
      write('ARTS_112_config_cost.json');

      final moved = migrateRoomToFolderLayout(old);

      expect(moved, path.join(dir.path, 'ARTS_111', 'config.json'));
      expect(File(moved).existsSync(), isTrue);
      expect(File(old).existsSync(), isFalse);
      expect(Directory(path.join(dir.path, 'ARTS_111_config')).existsSync(),
          isFalse);
      final files = path.join(dir.path, 'ARTS_111', 'room_files');
      expect(
        (Directory(files).listSync().map((e) => path.basename(e.path)).toList()
          ..sort()),
        [
          'ARTS111_old_config.json',
          'ARTS_111_av_flow.json',
          'ARTS_111_config_floorplan.png',
          'ARTS_111_config_floorplan2.png',
          'ARTS_111_cost.json',
        ],
      );
      expect(File(path.join(dir.path, 'ARTS_112_config_cost.json')).existsSync(),
          isTrue);
      // What the app reads the room from now.
      expect(File(roomSidecarPath(moved, RoomSidecarPart.cost)).existsSync(),
          isTrue);
    });

    test('a room whose folder shares its name moves into it', () {
      final old = write('BSS103.json');
      write(path.join('BSS103', 'BSS103_av_flow.json'));
      final moved = migrateRoomToFolderLayout(old);
      expect(moved, path.join(dir.path, 'BSS103', 'config.json'));
      expect(
        File(path.join(dir.path, 'BSS103', 'room_files', 'BSS103_av_flow.json'))
            .existsSync(),
        isTrue,
      );
    });

    test('nothing moves over a room already in the way', () {
      final old = write('ARTS_111_config.json');
      write(path.join('ARTS_111', 'config.json'));
      expect(migrateRoomToFolderLayout(old), '');
      expect(File(old).existsSync(), isTrue);
    });

    test('a config.json keeps the config folder an older build made', () {
      final config = write(path.join('ARTS_111', 'config.json'));
      write(path.join('ARTS_111', 'config', 'config_cost.json'));
      expect(moveOldConfigFolderIntoRoomFiles(config), isTrue);
      expect(File(roomSidecarPath(config, RoomSidecarPart.cost)).existsSync(),
          isTrue);
      expect(Directory(path.join(dir.path, 'ARTS_111', 'config')).existsSync(),
          isFalse);
    });
  });

  group('the app', () {
    AppStateProvider provider() => AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path
      ..autosaveFolderForTest = path.join(dir.path, '_recovery');

    test('opening an older room moves it and repoints the project', () async {
      final old = write('ARTS_111_config.json', {
        'SYSTEM_SETUP': {'gve_bldg': 'ARTS', 'gve_room': '111'},
      });
      final p = provider();
      p.newProject(name: 'Layout');
      p.currentProjectPath = path.join(dir.path, 'job.project.json');
      expect(p.addRoomToProject(old), '');

      expect(await p.openConfigAtPath(old), isTrue);

      final moved = path.join(dir.path, 'ARTS_111', 'config.json');
      expect(p.currentConfigPath, moved);
      expect(
        BuildingProject.resolvePath(
          p.project.rooms.single.configPath,
          p.currentProjectPath,
        ),
        moved,
      );
      expect(p.projectDirty, isTrue);
      // The conversion backup and change log went into room_files.
      expect(Directory(roomFolderPath(moved)).existsSync(), isTrue);
    });

    test('a link to the old file opens the moved room', () async {
      final old = write('ARTS_111_config.json', {'SYSTEM_SETUP': {}});
      final moved = migrateRoomToFolderLayout(old);
      final p = provider();
      expect(await p.openConfigAtPath(old), isTrue);
      expect(p.currentConfigPath, moved);
    });

    test('Save As builds the room folder', () async {
      final p = provider()
        ..roomConfig = {
          'SYSTEM_SETUP': {'gve_bldg': 'ARTS', 'gve_room': '111'},
        };
      final target = folderLayoutPathFor(
        path.join(dir.path, p.defaultRoomConfigFileName),
      );
      expect(await p.saveRoomConfigTo(target), isTrue);
      expect(target, path.join(dir.path, 'ARTS_111', 'config.json'));
      expect(File(target).existsSync(), isTrue);
      // The AV Flow file is written with it, even with nothing to draw.
      expect(File(roomSidecarPath(target, RoomSidecarPart.flow)).existsSync(),
          isTrue);
    });

    test('a new room is saved with its AV Flow drawn from the config',
        () async {
      final p = provider();
      expect(await p.createNewConfig(), isTrue);
      p.setRoomIdentity(building: 'ARTS', room: '111');
      p.roomConfig['SYSTEM_SETUP']
        ..['dev_switchers'] = '1'
        ..['dev_projectors'] = '1';
      p.roomConfig['SWITCHERDEVICE_1'] = {'name': 'Switcher', 'model': ''};
      p.roomConfig['PROJECTORDEVICE_1'] = {'name': 'Projector', 'model': ''};
      final target = roomConfigPathIn(dir.path, p.defaultRoomFolderName);
      expect(await p.saveRoomConfigTo(target), isTrue);

      final flow = File(roomSidecarPath(target, RoomSidecarPart.flow));
      expect(flow.existsSync(), isTrue);
      final nodes = (jsonDecode(flow.readAsStringSync()) as Map)['nodes'];
      expect(nodes, isNotEmpty);
      expect(
        File(roomSidecarPath(target, RoomSidecarPart.cost)).existsSync(),
        isTrue,
      );
    });
  });
}
