import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/control_gaps.dart';
import 'package:extron_configurator/model_swap.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_swap.dart';

/// Swapping a product in every room that has it, and the control-module rule
/// that says which of them nothing will drive afterwards.
///
/// This is the only thing on the Project tab that WRITES to room files, so the
/// checks here are about exactly that: what changes, what is left alone, and
/// what the plan promised beforehand.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_swap_test'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  //  FIXTURES
  // -------------------------------------------------------------------------

  /// Two projectors with one HDMI input each, and a switcher to feed them.
  /// The replacement has a DIFFERENT second input, so a run drawn on the input
  /// the new box lacks is dropped and a run on the shared one carries.
  AvDeviceLibrary catalog() {
    final library = AvDeviceLibrary.empty();
    library.upsert(const AvDeviceTemplate(
      model: 'PowerLite L630U',
      manufacturer: 'Epson',
      partNumber: 'V11H903020',
      category: 'Projector',
      rackUnits: 0,
      price: 2200,
      ports: [
        AvPort(
            id: 'hdmi1',
            label: 'HDMI 1',
            signal: SignalType.hdmi,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
        AvPort(
            id: 'vga1',
            label: 'VGA 1',
            signal: SignalType.vga,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
      ],
    ));
    library.upsert(const AvDeviceTemplate(
      model: 'PT-MZ682BU8',
      manufacturer: 'Panasonic',
      partNumber: 'PT-MZ682',
      category: 'Projector',
      rackUnits: 2,
      price: 3400,
      ports: [
        // Same id as the old box's, so a run on it carries across.
        AvPort(
            id: 'hdmi1',
            label: 'HDMI 1',
            signal: SignalType.hdmi,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
      ],
    ));
    library.upsert(const AvDeviceTemplate(
      model: 'DTP CrossPoint 84',
      manufacturer: 'Extron',
      partNumber: '60-1234-01',
      category: 'Switcher',
      price: 5000,
      ports: [
        AvPort(
            id: 'out1',
            label: 'Out 1',
            signal: SignalType.hdmi,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
        AvPort(
            id: 'out2',
            label: 'Out 2',
            signal: SignalType.vga,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
      ],
    ));
    return library;
  }

  AvNode projector(String id, String label, {String model = 'PowerLite L630U'}) =>
      AvNode(
        id: id,
        label: label,
        model: model,
        pos: Offset.zero,
        ports: const [
          AvPort(
            id: 'hdmi1',
            label: 'HDMI 1',
            signal: SignalType.hdmi,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
          AvPort(
            id: 'vga1',
            label: 'VGA 1',
            signal: SignalType.vga,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
        ],
      );

  AvNode switcher(String id) => AvNode(
    id: id,
    label: 'Switcher',
    model: 'DTP CrossPoint 84',
    pos: const Offset(400, 0),
    ports: const [
      AvPort(
            id: 'out1',
            label: 'Out 1',
            signal: SignalType.hdmi,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
      AvPort(
            id: 'out2',
            label: 'Out 2',
            signal: SignalType.vga,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
    ],
  );

  /// A room with a switcher feeding one projector on HDMI and, optionally, the
  /// same projector on VGA — the run that has nowhere to go after the swap.
  String writeRoom(
    String stem, {
    required String name,
    bool projectorIsConfigDevice = true,
    bool vgaRun = false,
    String projectorModel = 'PowerLite L630U',
    String module = 'modules.device.epson_l630u',
  }) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gui_full_room_name': name,
        if (projectorIsConfigDevice) 'dev_projectors': '1',
      },
      if (projectorIsConfigDevice)
        'PROJECTORDEVICE_1': {
          'name': 'Projector 1 - $projectorModel',
          'model': projectorModel,
          'module': module,
          'ip_address': '10.0.0.7',
          'port': '4352',
        },
    }));

    final nodeId =
        projectorIsConfigDevice ? 'PROJECTORDEVICE_1' : 'hand_projector';
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      '__readme': 'left alone by the swap',
      'roomMode': 'full',
      'nodes': [
        projector(nodeId, 'Projector 1 - $projectorModel',
            model: projectorModel).toJson(),
        switcher('sw1').toJson(),
      ],
      'cables': [
        const AvCable(
          id: 'c1',
          fromNodeId: 'sw1',
          fromPortId: 'out1',
          toNodeId: '',
          toPortId: 'hdmi1',
          signal: SignalType.hdmi,
        ).copyWith(toNodeId: nodeId).toJson(),
        if (vgaRun)
          const AvCable(
            id: 'c2',
            fromNodeId: 'sw1',
            fromPortId: 'out2',
            toNodeId: '',
            toPortId: 'vga1',
            signal: SignalType.vga,
          ).copyWith(toNodeId: nodeId).toJson(),
      ],
    }));
    return configPath;
  }

  /// The schema's device-count map, as the app would supply it.
  const countMap = {'dev_projectors': 'PROJECTORDEVICE_'};

  /// A module registry that knows the old projector and nothing else, so the
  /// new one lands with no driver — the case the flagging exists for.
  String moduleForModel(String model) =>
      model == 'PowerLite L630U' ? 'modules.device.epson_l630u' : '';

  BuildingProject projectOver(List<String> configs) {
    final project = BuildingProject(name: 'Swap test');
    final projectPath = path.join(dir.path, 'job_project.json');
    for (final c in configs) {
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: BuildingProject.storePath(c, projectPath),
      ));
    }
    return project;
  }

  Future<ProjectSwapPlan> planFor(
    BuildingProject project, {
    String from = 'PowerLite L630U',
    String to = 'PT-MZ682BU8',
    String openConfigPath = '',
  }) => planProjectSwap(
    project: project,
    projectPath: path.join(dir.path, 'job_project.json'),
    fromModel: from,
    template: catalog().templateForModel(to)!,
    moduleForModel: moduleForModel,
    deviceCountMap: countMap,
    openConfigPath: openConfigPath,
  );

  Future<ProjectSwapResult> apply(FutureOr<ProjectSwapPlan> plan) async =>
      applyProjectSwap(
    plan: await plan,
    moduleForModel: moduleForModel,
    deviceCountMap: countMap,
  );

  Map<String, dynamic> readJson(String file) =>
      Map<String, dynamic>.from(jsonDecode(File(file).readAsStringSync()));

  // -------------------------------------------------------------------------
  //  PLANNING
  // -------------------------------------------------------------------------

  group('planning a swap', () {
    test('finds the product in every room and writes nothing', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B');
      final before = File(a).readAsStringSync();

      final plan = await planFor(projectOver([a, b]));

      expect(plan.affectedRooms, hasLength(2));
      expect(plan.boxes, 2);
      expect(plan.to.model, 'PT-MZ682BU8');
      expect(File(a).readAsStringSync(), before, reason: 'planning is a read');
    });

    test('a room without the product is not an affected room', () async {
      final a = writeRoom('a', name: 'Has one');
      final b = writeRoom(
        'b',
        name: 'Has a different one',
        projectorModel: 'PT-MZ682BU8',
      );

      final plan = await planFor(projectOver([a, b]));

      expect(plan.affectedRooms, hasLength(1));
      expect(plan.affectedRooms.single.roomName, 'Has one');
    });

    test('counts the runs that carry and the ones that get dropped', () async {
      // The VGA run lands on a connector the new projector does not have.
      final a = writeRoom('a', name: 'Room A', vgaRun: true);

      final plan = await planFor(projectOver([a]));

      expect(plan.carried, 1, reason: 'the HDMI run moves across');
      expect(plan.dropped, 1, reason: 'the VGA run has nowhere to go');
    });

    test('says when the new product has no driver', () async {
      final a = writeRoom('a', name: 'Room A');

      final plan = await planFor(projectOver([a]));

      expect(plan.newModule, isEmpty);
      expect(plan.blocks, 1);
      expect(plan.losesModule, isTrue);
    });

    test('says when the rack height changes', () async {
      final a = writeRoom('a', name: 'Room A');
      expect((await planFor(projectOver([a]))).anyRackHeightChanged, isTrue);
    });

    test('an unreadable room is carried on the plan, not skipped silently', () async {
      final a = writeRoom('a', name: 'Room A');
      final project = projectOver([a]);
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: 'gone_config.json',
      ));

      final plan = await planFor(project);

      expect(plan.failedRooms, hasLength(1));
      expect(plan.affectedRooms, hasLength(1));
    });

    test('marks the room that is open in the editor', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B');

      final plan = await planFor(projectOver([a, b]), openConfigPath: a);

      expect(plan.affectedRooms.first.isOpenRoom, isTrue);
      expect(plan.affectedRooms.last.isOpenRoom, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  //  APPLYING
  // -------------------------------------------------------------------------

  group('applying a swap', () {
    test('moves the box in every room', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B');

      final result = await apply(planFor(projectOver([a, b])));

      expect(result.rooms, 2);
      expect(result.boxes, 2);
      expect(result.failures, isEmpty);

      for (final config in [a, b]) {
        final room = readRoomFromDisk(config);
        final node = room.model.nodes.firstWhere((n) => n.id.contains('PROJ'));
        expect(node.model, 'PT-MZ682BU8');
        expect(node.rackUnits, 2, reason: 'the new product is 2U');
      }
    });

    test('renames only the model-shaped part of the label', () async {
      final a = writeRoom('a', name: 'Room A');

      await apply(planFor(projectOver([a])));

      final node = readRoomFromDisk(a)
          .model
          .nodes
          .firstWhere((n) => n.id.contains('PROJ'));
      expect(node.label, 'Projector 1 - PT-MZ682BU8');
    });

    test('a given name goes on every box and control block', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B');

      await applyProjectSwap(
        plan: await planFor(projectOver([a, b])),
        moduleForModel: moduleForModel,
        deviceCountMap: countMap,
        label: 'Main Projector',
      );

      for (final config in [a, b]) {
        final node = readRoomFromDisk(config)
            .model
            .nodes
            .firstWhere((n) => n.id.contains('PROJ'));
        expect(node.label, 'Main Projector');
        expect((readJson(config)['PROJECTORDEVICE_1'] as Map)['name'],
            'Main Projector');
      }
    });

    test('the plan lists the names the boxes would get', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B');
      expect((await planFor(projectOver([a, b]))).labels,
          ['Projector 1 - PT-MZ682BU8']);
    });

    test('carries the runs it can and removes the ones it cannot', () async {
      final a = writeRoom('a', name: 'Room A', vgaRun: true);

      final result = await apply(planFor(projectOver([a])));

      expect(result.carried, 1);
      expect(result.dropped, 1);

      final cables = readRoomFromDisk(a).model.cables;
      expect(cables.map((c) => c.id), ['c1']);
      expect(cables.single.toPortId, 'hdmi1');
    });

    test('points the control block at the new model and CLEARS the module '
        'when nothing claims it', () async {
      final a = writeRoom('a', name: 'Room A');

      await apply(planFor(projectOver([a])));

      final block = readJson(a)['PROJECTORDEVICE_1'] as Map;
      expect(block['model'], 'PT-MZ682BU8');
      expect(block['module'], '',
          reason: 'a block naming the old driver would commission the wrong '
              'projector');
      expect(block['name'], 'Projector 1 - PT-MZ682BU8');
      // The facts about this install survive the product changing.
      expect(block['ip_address'], '10.0.0.7');
      expect(block['port'], '4352');
    });

    test('sets the module when one does claim the new model', () async {
      final a = writeRoom(
        'a',
        name: 'Room A',
        projectorModel: 'PT-MZ682BU8',
        module: '',
      );

      await applyProjectSwap(
        plan: await planProjectSwap(
          project: projectOver([a]),
          projectPath: path.join(dir.path, 'job_project.json'),
          fromModel: 'PT-MZ682BU8',
          template: catalog().templateForModel('PowerLite L630U')!,
          moduleForModel: moduleForModel,
          deviceCountMap: countMap,
        ),
        moduleForModel: moduleForModel,
        deviceCountMap: countMap,
      );

      final block = readJson(a)['PROJECTORDEVICE_1'] as Map;
      expect(block['model'], 'PowerLite L630U');
      expect(block['module'], 'modules.device.epson_l630u');
    });

    test('a box with no config block behind it still swaps on the drawing',
        () async {
      final a = writeRoom('a', name: 'Room A', projectorIsConfigDevice: false);

      final result = await apply(planFor(projectOver([a])));

      expect(result.boxes, 1);
      expect(result.blocks, 0, reason: 'there is no block to update');
      expect(
        readRoomFromDisk(a)
            .model
            .nodes
            .firstWhere((n) => n.id == 'hand_projector')
            .model,
        'PT-MZ682BU8',
      );
    });

    test('leaves everything else in the sidecar alone', () async {
      final a = writeRoom('a', name: 'Room A');
      final flow = path.join(dir.path, 'a_config_av_flow.json');

      await apply(planFor(projectOver([a])));

      final doc = readJson(flow);
      expect(doc['__readme'], 'left alone by the swap');
      expect(doc['roomMode'], 'full');
      // The switcher was never part of the swap.
      final sw = (doc['nodes'] as List)
          .cast<Map>()
          .firstWhere((n) => n['id'] == 'sw1');
      expect(sw['model'], 'DTP CrossPoint 84');
    });

    test('the open room is skipped so the editor and the disk cannot '
        'disagree', () async {
      final a = writeRoom('a', name: 'Open room');
      final b = writeRoom('b', name: 'Other room');

      final result = await apply(planFor(projectOver([a, b]), openConfigPath: a));

      expect(result.rooms, 1, reason: 'only the closed room was written');
      expect(
        readRoomFromDisk(a)
            .model
            .nodes
            .firstWhere((n) => n.id.contains('PROJ'))
            .model,
        'PowerLite L630U',
        reason: 'the open room is applied in memory by the provider instead',
      );
      expect(
        readRoomFromDisk(b)
            .model
            .nodes
            .firstWhere((n) => n.id.contains('PROJ'))
            .model,
        'PT-MZ682BU8',
      );
    });

    test('one unwritable room does not stop the others', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B');
      final plan = await planFor(projectOver([a, b]));

      // The room goes away between the plan and the apply — the share dropped
      // out, somebody renamed it. The other room must still go.
      File(a).deleteSync();

      final result = await apply(plan);

      expect(result.failures, hasLength(1));
      expect(result.rooms, 1);
      expect(
        readRoomFromDisk(b)
            .model
            .nodes
            .firstWhere((n) => n.id.contains('PROJ'))
            .model,
        'PT-MZ682BU8',
      );
    });

    test('counts rooms as it goes, planning and writing', () async {
      final configs = [
        for (var i = 0; i < 6; i++) writeRoom('r$i', name: 'Room $i'),
      ];
      final seen = <(int, int)>[];
      final plan = await planProjectSwap(
        project: projectOver(configs),
        projectPath: path.join(dir.path, 'job_project.json'),
        fromModel: 'PowerLite L630U',
        template: catalog().templateForModel('PT-MZ682BU8')!,
        moduleForModel: moduleForModel,
        deviceCountMap: countMap,
        onProgress: (d, t) => seen.add((d, t)),
      );
      expect(seen.first, (0, 6));
      expect(seen.last, (6, 6));
      expect([for (final r in plan.rooms) r.roomName],
          [for (var i = 0; i < 6; i++) 'Room $i'],
          reason: 'in the project\'s order, however they finished');

      seen.clear();
      final result = await applyProjectSwap(
        plan: plan,
        moduleForModel: moduleForModel,
        deviceCountMap: countMap,
        onProgress: (d, t) => seen.add((d, t)),
      );
      expect(seen.last, (6, 6));
      expect(result.boxes, 6);
    });

    test('a box keeps what the swap does not own', () async {
      final a = writeRoom('a', name: 'Room A');
      final flow = path.join(dir.path, 'a_config_av_flow.json');
      final doc = readJson(flow);
      (doc['nodes'] as List).first['futureField'] = 'kept';
      (doc['nodes'] as List).last['futureField'] = 'kept too';
      File(flow).writeAsStringSync(jsonEncode(doc));

      await apply(planFor(projectOver([a])));

      final nodes = readJson(flow)['nodes'] as List;
      // The switcher was not swapped, so it is written back exactly.
      expect(nodes.last['futureField'], 'kept too');
      expect(nodes.first['model'], 'PT-MZ682BU8');
    });

    test('re-reads rather than writing back a stale plan', () async {
      final a = writeRoom('a', name: 'Room A');
      final plan = await planFor(projectOver([a]));

      // The room gains a second projector after the plan was made.
      final flow = path.join(dir.path, 'a_config_av_flow.json');
      final doc = readJson(flow);
      (doc['nodes'] as List).add(projector('extra', 'Projector 2').toJson());
      File(flow).writeAsStringSync(jsonEncode(doc));

      final result = await apply(plan);

      // Both are swapped, because the write reads the room as it is now — and
      // the box added in between is still there rather than being erased by a
      // stale copy of the diagram.
      expect(result.boxes, 2);
      final nodes = readRoomFromDisk(a).model.nodes;
      expect(nodes, hasLength(3));
      expect(
        nodes.where((n) => n.model == 'PT-MZ682BU8'),
        hasLength(2),
      );
    });
  });

  // -------------------------------------------------------------------------
  //  THE ARITHMETIC, ON ITS OWN
  // -------------------------------------------------------------------------

  group('renaming without swapping', () {
    Future<List<RoomSwapPlan>> planRename(BuildingProject project,
            {String openConfigPath = '',
            void Function(int, int)? onProgress}) =>
        planProjectRename(
          project: project,
          projectPath: path.join(dir.path, 'job_project.json'),
          model: 'PowerLite L630U',
          deviceCountMap: countMap,
          openConfigPath: openConfigPath,
          onProgress: onProgress,
        );

    Future<ProjectSwapResult> rename(List<RoomSwapPlan> rooms,
            {void Function(int, int)? onProgress}) =>
        applyProjectRename(
          rooms: rooms,
          model: 'PowerLite L630U',
          label: 'Main Projector',
          deviceCountMap: countMap,
          onProgress: onProgress,
        );

    test('lists the rooms and their current names, writing nothing', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B', projectorModel: 'PT-MZ682BU8');
      final before = File(a).readAsStringSync();

      final rooms = await planRename(projectOver([a, b]));

      expect([for (final r in rooms) if (r.affected) r.roomName], ['Room A']);
      expect(rooms.first.labels, ['Projector 1 - PowerLite L630U']);
      expect(rooms.first.blocks, 1);
      expect(File(a).readAsStringSync(), before);
    });

    test('an unreadable room is on the plan, in its place', () async {
      final a = writeRoom('a', name: 'Room A');
      final project = projectOver([a]);
      project.rooms.insert(
        0,
        ProjectRoomRef(id: project.nextRoomId(), configPath: 'gone_config.json'),
      );

      final rooms = await planRename(project);

      expect(rooms.first.ok, isFalse);
      expect(rooms.last.affected, isTrue);
    });

    test('names every box and block, and leaves the model and runs alone',
        () async {
      final a = writeRoom('a', name: 'Room A', vgaRun: true);
      final b = writeRoom('b', name: 'Room B');
      final project = projectOver([a, b]);

      final result = await rename(await planRename(project));

      expect(result.rooms, 2);
      expect(result.boxes, 2);
      expect(result.blocks, 2);
      for (final config in [a, b]) {
        final room = readRoomFromDisk(config);
        final node = room.model.nodes.firstWhere((n) => n.id.contains('PROJ'));
        expect(node.label, 'Main Projector');
        expect(node.model, 'PowerLite L630U');
        final block = readJson(config)['PROJECTORDEVICE_1'] as Map;
        expect(block['name'], 'Main Projector');
        expect(block['module'], 'modules.device.epson_l630u');
      }
      expect(readRoomFromDisk(a).model.cables, hasLength(2));
      expect(readRoomFromDisk(a).model.nodes.firstWhere((n) => n.id == 'sw1')
          .label, 'Switcher');
      // The rest of the drawing file is as it was.
      final flow = readJson(readRoomFromDisk(a).flowPath);
      expect(flow['__readme'], 'left alone by the swap');
    });

    test('counts rooms as it goes, reading and writing', () async {
      final configs = [
        for (var i = 0; i < 6; i++) writeRoom('r$i', name: 'Room $i'),
      ];
      final seen = <(int, int)>[];

      final rooms = await planRename(
        projectOver(configs),
        onProgress: (d, t) => seen.add((d, t)),
      );
      expect(seen.first, (0, 6));
      expect(seen.last, (6, 6));

      seen.clear();
      await rename(rooms, onProgress: (d, t) => seen.add((d, t)));
      expect(seen.last, (6, 6));
    });

    test('a room already named that is not written again', () async {
      final a = writeRoom('a', name: 'Room A');
      final project = projectOver([a]);
      await rename(await planRename(project));
      final flowPath = readRoomFromDisk(a).flowPath;
      final stamps = [
        File(a).lastModifiedSync(),
        File(flowPath).lastModifiedSync(),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await rename(await planRename(project));

      expect(File(a).lastModifiedSync(), stamps[0]);
      expect(File(flowPath).lastModifiedSync(), stamps[1]);
    });

    test('the open room is left for the editor', () async {
      final a = writeRoom('a', name: 'Room A');
      final before = File(a).readAsStringSync();

      await rename(await planRename(projectOver([a]), openConfigPath: a));

      expect(File(a).readAsStringSync(), before);
    });
  });

  group('the swap arithmetic', () {
    test('a run with one end orphaned is dropped, not half-moved', () {
      final node = projector('p1', 'Projector 1');
      final plan = planModelSwap(
        node: node,
        cables: [
          const AvCable(
            id: 'c1',
            fromNodeId: 'sw1',
            fromPortId: 'out2',
            toNodeId: 'p1',
            toPortId: 'vga1',
            signal: SignalType.vga,
          ),
        ],
        template: catalog().templateForModel('PT-MZ682BU8')!,
        config: const {},
      );

      expect(plan.moved, isEmpty);
      expect(plan.dropped, ['c1']);
    });

    test('a label that never mentioned the model comes back untouched', () {
      expect(
        renamedForModel('Lectern projector', 'PowerLite L630U', 'PT-MZ682BU8'),
        'Lectern projector',
      );
    });

    test('a model that is a prefix of the one in the name cannot eat it', () {
      expect(renamedForModel('L630U', 'L630', 'PT-MZ682'), 'L630U');
      expect(renamedForModel('Proj - L630', 'L630', 'PT-MZ682'),
          'Proj - PT-MZ682');
    });

    test('a Dell makes a confidence monitor a PC monitor, and back', () {
      expect(renamedForMaker('Confidence monitor 2', 'Dell'), 'PC monitor 2');
      expect(renamedForMaker('PC monitor', 'Panasonic'), 'Confidence monitor');
      expect(renamedForMaker('PC monitor', 'Extron', category: 'Switcher'),
          'PC monitor');
      expect(renamedForMaker('Projector 1', 'Dell'), 'Projector 1');
    });

    test('swapping a confidence monitor to a Dell renames it', () {
      const dell = AvDeviceTemplate(
        model: 'Dell Monitor',
        manufacturer: 'Dell',
        category: 'Display',
        ports: [],
      );
      final plan = planModelSwap(
        node: AvNode(
          id: 'AVSOURCE_OUTPUT_MONITOR_1',
          label: 'Confidence monitor',
          model: 'Confidence Monitor',
          pos: Offset.zero,
          ports: const [],
        ),
        cables: const [],
        template: dell,
        config: const {},
      );
      expect(plan.node.label, 'PC monitor');
    });
  });

  // -------------------------------------------------------------------------
  //  THE CONTROL-MODULE RULE, ROLLED UP
  // -------------------------------------------------------------------------

  group('devices without a control module', () {
    ProjectEstimate priceWith(BuildingProject project) =>
        computeProjectEstimate(
          project: project,
          projectPath: path.join(dir.path, 'job_project.json'),
          library: catalog(),
          deviceCountMap: countMap,
          moduleForModel: moduleForModel,
        );

    test('a driven room reports no gaps', () {
      final a = writeRoom('a', name: 'Room A');
      // The switcher has no config block, so it is the box added by hand with
      // no driver — leave only the projector by giving it its module.
      final estimate = priceWith(projectOver([a]));

      expect(
        estimate.controlGaps.where((g) => g.gap.model == 'PowerLite L630U'),
        isEmpty,
        reason: 'the projector block names a module that claims its model',
      );
    });

    test('a swap onto a model nothing drives puts it on the list', () async {
      final a = writeRoom('a', name: 'Room A');
      expect(
        priceWith(projectOver([a]))
            .controlGaps
            .where((g) => g.gap.model == 'PT-MZ682BU8'),
        isEmpty,
        reason: 'not yet swapped',
      );

      await apply(planFor(projectOver([a])));

      final after = priceWith(projectOver([a]));
      final gap = after.controlGaps
          .firstWhere((g) => g.gap.model == 'PT-MZ682BU8');
      expect(gap.gap.kind, ControlGapKind.noModuleClaims);
      expect(gap.room.name, 'Room A');
    });

    test('the master list says which rooms a part is undriven in', () async {
      final a = writeRoom('a', name: 'Room A');
      final b = writeRoom('b', name: 'Room B');
      final project = projectOver([a, b]);

      await apply(planFor(project));

      final estimate = priceWith(project);
      final line = estimate.master
          .firstWhere((l) => l.model == 'PT-MZ682BU8');
      expect(line.hasControlGap, isTrue);
      expect(line.undrivenQty, 2);
      expect(line.undrivenByRoom, hasLength(2));
    });

    test('cable and rack hardware are never flagged as undriven', () {
      final a = writeRoom('a', name: 'Room A');
      final estimate = priceWith(projectOver([a]));

      for (final line in estimate.master) {
        if (line.kind == MasterPartKind.equipment) continue;
        expect(line.hasControlGap, isFalse, reason: line.description);
      }
    });

    test('no module lookup means the rule does not run at all', () {
      // Silence rather than a wrong answer: without the registry there is no
      // basis for calling anything undriven.
      final a = writeRoom('a', name: 'Room A');
      final estimate = computeProjectEstimate(
        project: projectOver([a]),
        projectPath: path.join(dir.path, 'job_project.json'),
        library: catalog(),
      );

      expect(estimate.controlGaps, isEmpty);
      expect(estimate.undrivenDevices, 0);
    });
  });
}
