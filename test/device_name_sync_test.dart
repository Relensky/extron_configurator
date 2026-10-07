import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// A config device's box on the AV Flow carries the block's `name`, both ways,
/// and a room the app has saved opens as saved - nothing is added back to it
/// until Convert is pressed.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_name_sync'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvNode box(String id, String label) => AvNode(
        id: id,
        label: label,
        model: 'PowerLite L630U',
        pos: Offset.zero,
        ports: const [],
        fromConfig: true,
      );

  /// A room whose saved drawing still titles the projector 'Old title'.
  Future<AppStateProvider> openRoom() async {
    final configPath = path.join(dir.path, 'r_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': 'Room', 'dev_projectors': '1'},
      'PROJECTORDEVICE_1': {'name': 'Front projector', 'model': 'L630U'},
    }));
    File(path.join(dir.path, 'r_config_av_flow.json')).writeAsStringSync(
      jsonEncode({
        'nodes': [box('PROJECTORDEVICE_1', 'Old title').toJson()],
      }),
    );
    final p = AppStateProvider(autoLoadSettings: false);
    await p.openConfigAtPath(configPath);
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  String projectorName(AppStateProvider p) =>
      (p.roomConfig['PROJECTORDEVICE_1'] as Map)['name'].toString();

  group('device names', () {
    test('an opened room titles its boxes from the config', () async {
      final p = await openRoom();
      expect(p.avNodeById('PROJECTORDEVICE_1')!.label, 'Front projector');
      expect(projectorName(p), 'Front projector');
    });

    test('a name changed in the config retitles the box', () async {
      final p = await openRoom();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'name', 'Rear projector');
      expect(p.avNodeById('PROJECTORDEVICE_1')!.label, 'Rear projector');
    });

    test('a box retitled on the flow renames the device', () async {
      final p = await openRoom();
      final node = p.avNodeById('PROJECTORDEVICE_1')!;
      p.updateAvNode(node.copyWith(label: 'Left projector'));
      expect(projectorName(p), 'Left projector');
      expect(p.avNodeById('PROJECTORDEVICE_1')!.label, 'Left projector');
    });
  });

  group('a saved room', () {
    test('opens as saved until Convert is pressed', () async {
      final configPath = path.join(dir.path, 'legacy_config.json');
      File(configPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': 'Legacy'},
      }));
      final p = AppStateProvider(autoLoadSettings: false);

      // First open converts: the missing counts are added.
      await p.openConfigAtPath(configPath);
      expect(p.conversionSkipped, isFalse);
      expect(p.lastLoadHadChanges, isTrue);
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup.containsKey('dev_projectors'), isTrue);

      // Somebody takes a key out and saves.
      setup.remove('dev_projectors');
      await p.saveCurrentConfigToFile();
      expect(roomWasConverted(configPath), isTrue);

      await p.openConfigAtPath(configPath);
      expect(p.conversionSkipped, isTrue);
      expect(p.lastLoadHadChanges, isFalse);
      expect(
        (p.roomConfig['SYSTEM_SETUP'] as Map).containsKey('dev_projectors'),
        isFalse,
      );

      // Convert puts it back, as a change that can be reviewed.
      await p.convertOpenRoom();
      expect(p.conversionSkipped, isFalse);
      expect(p.lastLoadHadChanges, isTrue);
      expect(
        (p.roomConfig['SYSTEM_SETUP'] as Map).containsKey('dev_projectors'),
        isTrue,
      );
    });
  });
}
