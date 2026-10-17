import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_parts_copy.dart';
import 'package:extron_configurator/room_presets.dart';

/// Copying the AV flow, racks, plan sheets and cabling of one room into
/// another, with the catalog checked for what it lacks first.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_parts_copy'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvPort port(String id, String label, PortDirection d) => AvPort(
    id: id,
    label: label,
    signal: SignalType.values.first,
    direction: d,
    side: PortSide.values.first,
  );

  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: [port('in1', 'IN 1', PortDirection.input)],
  );

  final jacks = AvNode(
    id: 'jf1',
    label: 'Wall plate',
    model: '',
    pos: Offset.zero,
    kind: AvNodeKind.jackField,
    ports: [port('j1', '10501', PortDirection.output)],
  );

  Map<String, dynamic> doc() => {
    'nodes': [
      jacks.toJson(),
      device('n1', 'Display 1', 'Display X').toJson(),
      device('n2', 'Camera 2', 'Mystery Cam').toJson(),
    ],
    'cables': [
      AvCable(
        id: 'c1',
        fromNodeId: 'jf1',
        fromPortId: 'j1',
        toNodeId: 'n1',
        toPortId: 'in1',
        signal: SignalType.values.first,
      ).toJson(),
      AvCable(
        id: 'c2',
        fromNodeId: 'jf1',
        fromPortId: 'j1',
        toNodeId: 'n2',
        toPortId: 'in1',
        signal: SignalType.values.first,
      ).toJson(),
    ],
    'racks': [
      {'id': 'RACK_1', 'name': 'Credenza', 'heightU': 12},
    ],
    'rackItems': <Object>[],
    'rackSlots': {
      'n2': {'rackId': 'RACK_1', 'topU': 3},
    },
    'locations': <Object>[],
    'floorPlans': <Object>[],
    'cablingSchematic': {'extraBoxes': <Object>[]},
  };

  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(const AvDeviceTemplate(
      model: 'Display X',
      category: 'Display',
      price: 1000,
      ports: [],
    ));

  test('only the parts ticked come across', () {
    final flowOnly = roomPresetFromDocument(doc(),
        name: 'A', include: {RoomPresetPart.flow});
    expect(flowOnly.nodes, hasLength(3));
    expect(flowOnly.racks, isEmpty);
    expect(flowOnly.cabling, isEmpty);

    final racksOnly = roomPresetFromDocument(doc(),
        name: 'A', include: {RoomPresetPart.racks, RoomPresetPart.cabling});
    expect(racksOnly.nodes, isEmpty);
    expect(racksOnly.racks.single.name, 'Credenza');
    expect(racksOnly.cabling, isNotEmpty);
  });

  test('finds what the catalog lacks, and leaving it out takes its cables',
      () {
    final preset = roomPresetFromDocument(doc(),
        name: 'A', include: {RoomPresetPart.flow, RoomPresetPart.racks});
    final missing = missingFromCatalog(preset, catalog());
    expect(missing.map((m) => m.model), ['Mystery Cam']);
    expect(missing.single.category, 'Camera');
    expect(missing.single.entry.ports, hasLength(1));

    final without = presetWithout(preset, {'mystery cam'});
    expect(without.nodes.map((n) => n.id), ['jf1', 'n1']);
    expect(without.cables.map((c) => c.id), ['c1']);
    expect(without.rackSlots, isEmpty);
  });

  PlanDevice gear(String id, String key, String label) => PlanDevice(
    id: id,
    deviceKey: key,
    label: label,
    shape: 'display',
    pos: const Offset(10, 20),
  );

  test('a box left out takes its gear; one put in place keeps it', () {
    final preset = roomPresetFromDocument(doc(),
            name: 'A', include: {RoomPresetPart.flow, RoomPresetPart.racks})
        .copyWith(floorPlans: [
      FloorPlan(id: 'PLAN_1', name: 'Level 1', devices: [
        gear('DEV_1', nodeDeviceKey('n1'), 'Display 1'),
        gear('DEV_2', nodeDeviceKey('n2'), 'Camera 2'),
      ]),
    ]);

    final left = presetWithoutNodes(preset, {'n2'});
    expect(left.nodes.map((n) => n.id), ['jf1', 'n1']);
    expect(left.cables.map((c) => c.id), ['c1']);
    expect(left.rackSlots, isEmpty);
    expect(left.floorPlans.single.devices.map((d) => d.id), ['DEV_1']);

    final swapped = presetWithoutNodes(preset, {'n2'}, keepGear: true);
    expect(swapped.nodes.map((n) => n.id), ['jf1', 'n1']);
    expect(swapped.floorPlans.single.devices, hasLength(2));

    final ticked = presetWithPlanGear(preset, {'PLAN_1|DEV_2'});
    expect(ticked.floorPlans.single.devices.map((d) => d.id), ['DEV_2']);
  });

  test('matching by type pairs each box with one of the same kind', () {
    String kind(AvNode n) => guessCategory(n.label).toLowerCase();
    final m = matchBoxesByKind(
      [
        device('a', 'Projector 1', 'New Proj'),
        device('b', 'Projector 2', 'New Proj'),
        device('c', 'Camera 1', 'Cam'),
      ],
      [
        device('x', 'Projector 1', 'Old Proj'),
        device('y', 'Display 1', 'Display X'),
      ],
      kind,
    );
    expect(m, {'a': 'x'});
  });

  test('gear goes onto a sheet the room has, tied to the right boxes',
      () async {
    final p = AppStateProvider(autoLoadSettings: false);
    final mine = p.addAvNode(device('', 'Projector 1', 'Old Proj'));
    final sheet = p.addAvFloorPlan(const FloorPlan(id: '', name: 'Level 1'));

    final preset = RoomPreset.fromJson({
      'name': 'A',
      'nodes': [device('n1', 'Display 1', 'Display X').toJson()],
    }).copyWith(floorPlans: [
      FloorPlan(id: 'PLAN_9', name: 'level 1', devices: [
        gear('DEV_1', nodeDeviceKey('n1'), 'Display 1'),
        gear('DEV_2', nodeDeviceKey('n7'), 'Projector 1'),
      ]),
      FloorPlan(id: 'PLAN_8', name: 'Ceiling', devices: [
        gear('DEV_1', nodeDeviceKey('gone'), 'Speaker 1'),
      ]),
    ]);
    await p.copyRoomPartsFrom('', preset, linkedNodes: {'n7': mine.id});

    final added = p.avNodes.firstWhere((n) => n.model == 'Display X');
    final level = p.avFloorPlanById(sheet.id)!;
    expect(p.avFloorPlans, hasLength(2), reason: 'Level 1 is not doubled');
    expect(level.devices.map((d) => d.deviceKey),
        [nodeDeviceKey(added.id), nodeDeviceKey(mine.id)]);
    final ceiling = p.avFloorPlans.firstWhere((s) => s.name == 'Ceiling');
    expect(ceiling.devices.single.deviceKey, roomDeviceKey('Speaker 1'));
  });

  test('copies into the open room, jacks renumbered for it', () async {
    String writeRoom(String name, String number, Map<String, dynamic>? flow) {
      final folder = Directory(path.join(dir.path, name, 'room_files'))
        ..createSync(recursive: true);
      final config = path.join(dir.path, name, 'config.json');
      File(config).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': name, 'gve_room': number},
      }));
      if (flow != null) {
        File(path.join(folder.path, '${name}_av_flow.json'))
            .writeAsStringSync(jsonEncode(flow));
      }
      return config;
    }

    final from = writeRoom('ARTS_105', '105', doc());
    final to = writeRoom('ARTS_106', '106', null);
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path;
    p.avDeviceLibrary = catalog();
    expect(await p.openConfigAtPath(to, remember: false), isTrue);

    final read = await readRoomDocumentAsync(from);
    final preset = presetWithout(
      roomPresetFromDocument(read!,
          name: 'ARTS 105',
          include: {RoomPresetPart.flow, RoomPresetPart.racks}),
      {'mystery cam'},
    );
    final done = await p.copyRoomPartsFrom(from, preset,
        fromSetup: {'gve_room': '105'});

    expect(done.devices, 1);
    expect(p.avNodes.map((n) => n.model), containsAll(['Display X']));
    expect(p.avNodes.any((n) => n.model == 'Mystery Cam'), isFalse);
    expect(p.avCables, hasLength(1));
    expect(p.avRacks.single.name, 'Credenza');
    final jack = p.avNodes.firstWhere((n) => n.isJackField);
    expect(jack.ports.single.label, '10601');
  });
}
