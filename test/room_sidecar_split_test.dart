import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// A room's document is written across several files — the flow, the racks,
/// the plans, the cabling, the estimate — so that working on one of them is
/// not working on all of them. The in-memory shape does not change: the split
/// happens on the way to disk and is undone on the way back.
void main() {
  group('splitting and merging', () {
    test('every key the document writes is owned by exactly one part', () {
      // A key nobody claims would be quietly dropped on the next save. This is
      // the check that stops that happening when a field is added.
      final p = AppStateProvider(autoLoadSettings: false);
      final combined = p.avFlowAsJson()..remove('__readme');

      final counts = <String, int>{};
      for (final keys in kRoomSidecarKeys.values) {
        for (final key in keys) {
          counts[key] = (counts[key] ?? 0) + 1;
        }
      }
      for (final key in combined.keys) {
        expect(counts[key], 1, reason: '"$key" must belong to one part');
      }
    });

    test('a document survives the round trip unchanged', () {
      final combined = <String, dynamic>{
        '__readme': 'ignored',
        'nodes': [
          {'id': 'A'},
        ],
        'racks': [
          {'id': 'R1'},
        ],
        'floorPlans': [
          {'id': 'P1'},
        ],
        'locations': [
          {'id': 'L1'},
        ],
        'screenSwitches': [
          {'id': 'S1'},
        ],
        'cost': {'taxPercent': 8.25},
      };

      final parts = splitRoomSidecar(combined);
      expect(parts[RoomSidecarPart.racks]!['racks'], isNotNull);
      expect(parts[RoomSidecarPart.cost]!['cost'], isNotNull);
      // The plans keep their places: a callout points at a location, and a
      // sheet whose places had gone would be unlabeled dots.
      expect(parts[RoomSidecarPart.floorPlans]!['locations'], isNotNull);
      // The flow file does not carry a second copy of anything.
      expect(parts[RoomSidecarPart.flow]!.containsKey('racks'), isFalse);
      expect(parts[RoomSidecarPart.flow]!.containsKey('cost'), isFalse);

      final back = mergeRoomSidecar(parts);
      expect(back, equals(combined..remove('__readme')));
    });

    test('an old combined file merges back to itself', () {
      // What every room saved before the split looks like: one file with all
      // the keys, and no companions to overlay it.
      final old = <String, dynamic>{
        'nodes': [
          {'id': 'A'},
        ],
        'racks': [
          {'id': 'R1'},
        ],
        'cost': {'taxPercent': 8.25},
      };
      expect(
        mergeRoomSidecar({RoomSidecarPart.flow: old}),
        equals(old),
      );
    });

    test('a companion wins over a stale copy in the flow file', () {
      final merged = mergeRoomSidecar({
        RoomSidecarPart.flow: {
          'nodes': [
            {'id': 'A'},
          ],
          'cost': {'taxPercent': 0},
        },
        RoomSidecarPart.cost: {
          'cost': {'taxPercent': 8.25},
        },
      });
      expect(merged['cost'], {'taxPercent': 8.25});
    });

    test('a key no part claims stays with the flow rather than vanishing', () {
      // Far likelier to be something a later build added than something safe
      // to throw away.
      final parts = splitRoomSidecar({'somethingNew': 42});
      expect(parts[RoomSidecarPart.flow]!['somethingNew'], 42);
      expect(mergeRoomSidecar(parts)['somethingNew'], 42);
    });

    test('the files are named for the config they sit beside', () {
      const config = r'C:\rooms\BSS103_config.json';
      expect(
        path.basename(roomSidecarPath(config, RoomSidecarPart.flow)),
        'BSS103_config_av_flow.json',
      );
      expect(
        path.basename(roomSidecarPath(config, RoomSidecarPart.floorPlans)),
        'BSS103_config_floor_plans.json',
      );
      expect(
        path.basename(roomSidecarPath(config, RoomSidecarPart.cost)),
        'BSS103_config_cost.json',
      );
      expect(roomSidecarPath('', RoomSidecarPart.cost), '');
    });
  });

  group('on disk', () {
    late Directory dir;
    late String configPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('room_sidecar_split_');
      configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    AppStateProvider opened() =>
        AppStateProvider(autoLoadSettings: false)..currentConfigPath = configPath;

    /// A room with something in every part.
    AppStateProvider furnished() {
      final p = opened();
      p.addAvNode(
        const AvNode(
          id: 'SW1',
          label: 'Switcher',
          model: 'SW4',
          pos: Offset(10, 10),
          rackUnits: 2,
          ports: [],
        ),
      );
      p.addAvRack('Rack 1', 12);
      p.addAvLocation(const RoomLocation(id: 'LOC_1', name: 'Lectern'));
      p.addAvFloorPlan(const FloorPlan(id: 'PLAN_1', name: 'Level 1'));
      p.setAvCostTax(percent: 8.25, label: 'State tax');
      return p;
    }

    String named(String suffix) =>
        path.join(dir.path, 'BSS103_config_$suffix.json');

    test('saving writes a file per part', () async {
      final p = furnished();
      expect(await p.saveAvFlow(), isNotEmpty);

      for (final suffix in const [
        'av_flow',
        'racks',
        'floor_plans',
        'cabling',
        'cost',
      ]) {
        expect(
          File(named(suffix)).existsSync(),
          isTrue,
          reason: '$suffix should have been written',
        );
      }

      // And each one holds its own section and not the others'.
      final racks = jsonDecode(File(named('racks')).readAsStringSync()) as Map;
      expect(racks['racks'], isNotEmpty);
      expect(racks.containsKey('nodes'), isFalse);

      final flow = jsonDecode(File(named('av_flow')).readAsStringSync()) as Map;
      expect(flow['nodes'], isNotEmpty);
      expect(flow.containsKey('cost'), isFalse);
      expect(flow.containsKey('racks'), isFalse);
    });

    test('the room opens again from the several files', () async {
      await furnished().saveAvFlow();

      final back = opened()..loadAvFlowForCurrentConfig();
      expect(back.avNodes.single.label, 'Switcher');
      expect(back.avRacks.single.name, 'Rack 1');
      expect(back.avLocations.single.name, 'Lectern');
      expect(back.avFloorPlans.single.name, 'Level 1');
      expect(back.avCost.taxPercent, 8.25);
      expect(back.avCost.taxLabel, 'State tax');
    });

    test('a room saved before the split still opens', () async {
      // One file with every key in it, exactly as older rooms have on disk.
      final p = furnished();
      File(named('av_flow')).writeAsStringSync(jsonEncode(p.avFlowAsJson()));

      final back = opened()..loadAvFlowForCurrentConfig();
      expect(back.avNodes.single.label, 'Switcher');
      expect(back.avRacks.single.name, 'Rack 1');
      expect(back.avFloorPlans.single.name, 'Level 1');
      expect(back.avCost.taxPercent, 8.25);
    });

    test('re-saving an old room splits it, and drops the duplicate keys',
        () async {
      final p = furnished();
      File(named('av_flow')).writeAsStringSync(jsonEncode(p.avFlowAsJson()));

      final reopened = opened()..loadAvFlowForCurrentConfig();
      await reopened.saveAvFlow();

      final flow = jsonDecode(File(named('av_flow')).readAsStringSync()) as Map;
      expect(flow.containsKey('racks'), isFalse);
      expect(flow.containsKey('cost'), isFalse);
      expect(File(named('cost')).existsSync(), isTrue);

      final back = opened()..loadAvFlowForCurrentConfig();
      expect(back.avRacks.single.name, 'Rack 1');
      expect(back.avCost.taxPercent, 8.25);
    });

    test('one broken part costs its own section and nothing else', () async {
      await furnished().saveAvFlow();
      File(named('cost')).writeAsStringSync('not json at all');

      final back = opened()..loadAvFlowForCurrentConfig();
      // The estimate is gone, because its file is unreadable.
      expect(back.avCost.taxPercent, 0);
      // Everything else came back.
      expect(back.avNodes.single.label, 'Switcher');
      expect(back.avRacks.single.name, 'Rack 1');
      expect(back.avFloorPlans.single.name, 'Level 1');
    });

    test('a room whose only saved part is the estimate is still protected',
        () async {
      // hasSavedAvFlow drives the "keep mine or load the saved one" prompt; a
      // room with a quote and no diagram has work worth not overwriting.
      final p = opened()..setAvCostTax(percent: 8.25);
      await p.saveAvFlow();
      File(named('av_flow')).deleteSync();

      expect(opened().hasSavedAvFlow, isTrue);
    });
  });
}
