import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_presets.dart';

/// Three things that stop a room being re-entered by hand, and one that stops
/// it being wired wrong:
///
///   * jack numbers are the room's addressing scheme, so two boxes numbered
///     alike is caught before it reaches the wall;
///   * a room TYPE stamps in the gear, the locations and the numbering that
///     every room of that kind shares;
///   * a room budgeted before its control config can have the control blocks
///     built from what was drawn, rather than typed a second time.
void main() {
  AvNode jackField(
    String id,
    String label,
    List<String> labels, {
    String locationId = kNoLocationId,
  }) => AvNode(
    id: id,
    label: label,
    model: '${labels.length}-jack field',
    pos: Offset.zero,
    kind: AvNodeKind.jackField,
    powerSource: PowerSource.none,
    locationId: locationId,
    ports: [
      for (int i = 0; i < labels.length; i++)
        AvPort(
          id: 'jack_${i + 1}',
          label: labels[i],
          signal: SignalType.network,
          direction: PortDirection.bidirectional,
          side: PortSide.left,
        ),
    ],
  );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'gve_room': '1110',
        },
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  group('duplicate jack numbers', () {
    test('a number already on another box is reported with the box', () {
      final p = room();
      p.addAvNode(jackField('WB1', 'Lectern plate', ['111001', '111002']));

      final clashes = duplicateJackLabels(['111002', '111003'], p.avNodes);
      expect(clashes.length, 1);
      expect(clashes.single.label, '111002');
      expect(clashes.single.usedBy, 'Lectern plate');
    });

    test('case and separators do not hide a clash', () {
      final p = room();
      p.addAvNode(jackField('WB1', 'Plate', ['AV-01']));

      // Three spellings of one jack. A check that misses these is a check
      // nobody can rely on.
      for (final spelling in ['av01', 'AV 01', 'Av_01']) {
        expect(
          duplicateJackLabels([spelling], p.avNodes),
          hasLength(1),
          reason: spelling,
        );
      }
    });

    test('leading zeros are kept, so 01 and 1 are different jacks', () {
      final p = room();
      p.addAvNode(jackField('WB1', 'Plate', ['111001']));
      expect(duplicateJackLabels(['11101'], p.avNodes), isEmpty);
    });

    test('a device connector is not a jack number', () {
      final p = room();
      p.addAvNode(
        const AvNode(
          id: 'SW',
          label: 'Switcher',
          model: 'SW4',
          pos: Offset.zero,
          ports: [
            AvPort(
              id: 'in_1',
              label: 'HDMI 1',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          ],
        ),
      );
      // Every switcher in a room has an "HDMI 1"; that is not a clash.
      expect(duplicateJackLabels(['HDMI 1'], p.avNodes), isEmpty);
    });

    test('a box does not clash with its own numbers when edited', () {
      final p = room();
      p.addAvNode(jackField('WB1', 'Plate', ['111001', '111002']));
      expect(
        duplicateJackLabels(
          ['111001', '111002', '111003'],
          p.avNodes,
          exceptNodeId: 'WB1',
        ),
        isEmpty,
      );
    });

    test('a block colliding with itself is caught before it is created', () {
      final p = room();
      final clashes = duplicateJackLabels(['05', '05'], p.avNodes);
      expect(clashes.single.usedBy, 'twice in this box');
    });

    test('the next free block steps over what is taken', () {
      final p = room();
      p.addAvNode(
        jackField('WB1', 'Plate', ['111001', '111002', '111003', '111004']),
      );
      // Four consecutive from 01 will not fit; 05 onward will.
      final next = nextFreeJackStart(
        prefix: '1110',
        start: 1,
        count: 4,
        width: 2,
        nodes: p.avNodes,
      );
      expect(next, 5);
    });
  });

  group('room type presets', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('room_presets_test_');
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('the four shipped types are written to the project root', () {
      expect(ensureBuiltInRoomPresets(root.path), 4);
      final presets = loadRoomPresets(root.path);
      expect(
        presets.map((p) => p.name),
        containsAll([
          'Basic classroom',
          'Hyflex',
          'Huddle',
          'Active learning',
        ]),
      );
      expect(presets.every((p) => p.builtIn), isTrue);
    });

    test('an edited built-in is never quietly overwritten', () {
      ensureBuiltInRoomPresets(root.path);
      final mine = loadRoomPresets(root.path)
          .firstWhere((p) => p.name == 'Basic classroom');
      saveRoomPreset(
        root.path,
        RoomPreset(name: mine.name, description: 'Ours, not theirs'),
      );

      // A second pass must leave the edited copy alone.
      expect(ensureBuiltInRoomPresets(root.path), 0);
      expect(
        loadRoomPresets(root.path)
            .firstWhere((p) => p.name == 'Basic classroom')
            .description,
        'Ours, not theirs',
      );
    });

    test('a preset survives the trip to disk and back', () {
      final preset = RoomPreset(
        name: 'Seminar room',
        description: 'Two displays and a plate',
        jackPrefix: 'RM',
        locations: const [
          RoomLocation(
            id: 'LOC_1',
            name: 'Front wall',
            zone: RoomZone.wall,
            callout: 'C',
          ),
        ],
        nodes: [jackField('N1', 'Plate', ['RM01', 'RM02'], locationId: 'LOC_1')],
        screenSwitches: const [
          ScreenSwitch(id: 'SCRSW_1', label: 'Screen', cableType: '18/2'),
        ],
      );
      expect(saveRoomPreset(root.path, preset), isNotEmpty);

      final back =
          loadRoomPresets(root.path).firstWhere((p) => p.name == 'Seminar room');
      expect(back.description, 'Two displays and a plate');
      expect(back.jackPrefix, 'RM');
      expect(back.locations.single.zone, RoomZone.wall);
      expect(back.nodes.single.ports.length, 2);
      expect(back.screenSwitches.single.cableType, '18/2');
      expect(back.builtIn, isFalse, reason: 'a saved preset is the user\'s');
    });

    test('applying a preset brings its gear, locations and wiring', () {
      final p = room();
      final preset = builtInRoomPresets()
          .firstWhere((x) => x.name == 'Basic classroom');

      final summary = p.applyRoomPreset(preset);

      expect(p.avNodes.length, preset.nodes.length);
      expect(p.avCables.length, summary.cables);
      expect(p.avRacks.length, 1);
      expect(p.avScreenSwitches.length, 1);
      expect(p.avLocations.length, preset.locations.length);
      // Every node landed in one of the room's real locations.
      for (final node in p.avNodes) {
        expect(p.avLocationById(node.locationId), isNotNull);
      }
      // The wiring survived the renumbering.
      for (final cable in p.avCables) {
        expect(p.avNodeById(cable.fromNodeId), isNotNull);
        expect(p.avNodeById(cable.toNodeId), isNotNull);
      }
      // And the rack placement points at the rack that was actually created.
      for (final slot in p.avRackSlots.values) {
        expect(p.avRacks.map((r) => r.id), contains(slot.rackId));
      }
    });

    test('the jacks are renumbered into this room\'s scheme', () {
      final p = room();
      p.applyRoomPreset(
        builtInRoomPresets().firstWhere((x) => x.name == 'Basic classroom'),
        jackPrefix: '1110',
      );

      final jacks = [
        for (final n in p.avNodes)
          if (n.isJackField)
            for (final port in n.ports) port.label,
      ];
      expect(jacks, isNotEmpty);
      expect(
        jacks.every((j) => j.startsWith('1110')),
        isTrue,
        reason: 'jacks: $jacks',
      );
    });

    test('applying twice doubles the gear rather than colliding with it', () {
      final p = room();
      final preset = builtInRoomPresets()
          .firstWhere((x) => x.name == 'Huddle');

      p.applyRoomPreset(preset);
      final afterOne = p.avNodes.length;
      p.applyRoomPreset(preset);

      expect(p.avNodes.length, afterOne * 2);
      // The ids stayed distinct — a collision would have silently dropped the
      // second copy onto the first.
      expect(p.avNodes.map((n) => n.id).toSet().length, p.avNodes.length);
      // The locations were REUSED by name rather than duplicated: two entries
      // called "Table" makes every per-location count meaningless.
      expect(
        p.avLocations.map((l) => l.name).toSet().length,
        p.avLocations.length,
      );
    });

    test('a room saved as a preset drops its identity and its prices', () {
      final p = room();
      p.applyRoomPreset(
        builtInRoomPresets().firstWhere((x) => x.name == 'Basic classroom'),
        jackPrefix: '1110',
      );
      p.setAvCostTax(percent: 8.25);

      final preset = p.currentRoomAsPreset(name: 'Our classroom');
      expect(preset.name, 'Our classroom');
      expect(preset.nodes.length, p.avNodes.length);
      // The prefix is detected so the next room can renumber from it.
      expect(preset.jackPrefix, '1110');
      // Nothing in the saved document carries the room's own name.
      expect(
        preset.toJson().toString().contains('Test Room'),
        isFalse,
        reason: 'a preset must be reusable in another room',
      );
    });
  });

  group('building the control side', () {
    AppStateProvider budgetedRoom() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {
            'gui_full_room_name': 'Budget Room',
            'gve_room': '1110',
          },
        };
      p.loadAvFlowForCurrentConfig();
      p.setRoomMode(RoomMode.avOnly);
      return p;
    }

    AvNode drawn(String id, String label, String model) => AvNode(
      id: id,
      label: label,
      model: model,
      pos: Offset.zero,
      ports: const [],
    );

    test('plans one block per drawn device, named in order', () {
      final p = budgetedRoom();
      p.addAvNode(drawn('AVNODE_1', 'front proj', 'Projector'));
      p.addAvNode(drawn('AVNODE_2', 'rear proj', 'Projector'));
      p.addAvNode(drawn('AVNODE_3', 'APC', 'Power controller'));

      final plan = planControlSide(p);
      expect(plan.creatable.length, 3);

      final projectors = plan.creatable
          .where((e) => e.family!.prefix == 'PROJECTORDEVICE_')
          .toList();
      expect(projectors.length, 2);
      // Sequential from the FAMILY, not from what was typed on the canvas —
      // a config named "front proj" is one nobody can cross-reference.
      expect(projectors.map((e) => e.name), ['Projector 1', 'Projector 2']);
      expect(
        projectors.map((e) => e.sectionKey),
        ['PROJECTORDEVICE_1', 'PROJECTORDEVICE_2'],
      );
      // The drawn label is not lost.
      expect(projectors.first.nodeLabel, 'front proj');
    });

    test('a jack field is never given a control block', () {
      final p = budgetedRoom();
      p.addAvNode(jackField('WB1', 'Plate', ['111001']));
      expect(planControlSide(p).entries, isEmpty);
    });

    test('a device no module claims is created blank and flagged', () {
      final p = budgetedRoom();
      p.addAvNode(drawn('AVNODE_1', 'Projector', 'Some Unclaimed Model 9000'));

      final plan = planControlSide(p);
      expect(plan.withoutModule.length, 1);
      expect(plan.creatable.single.module, isEmpty);
      expect(plan.creatable.single.needsModule, isTrue);

      final result = applyControlSide(p, plan);
      expect(result.created, 1);
      expect(result.withoutModule, 1);
      // Blank rather than a plausible guess: the empty one is on every
      // missing-module list in the app, the wrong one looks finished.
      expect(p.roomConfig['PROJECTORDEVICE_1']['module'], '');
      expect(
        p.devicesMissingModules.map((d) => d.key),
        contains('PROJECTORDEVICE_1'),
      );
    });

    test('applying it fills the block from the application defaults', () {
      final p = budgetedRoom();
      p.addAvNode(drawn('AVNODE_1', 'front proj', 'Projector'));

      applyControlSide(p, planControlSide(p));

      final block = p.roomConfig['PROJECTORDEVICE_1'];
      expect(block, isA<Map>());
      expect(block['name'], 'Projector 1');
      expect(block['model'], 'Projector');
      // The family's schema defaults are present, the same ones the Setup
      // Wizard would have written.
      for (final prop in p.uiSchema.defaultsFor('PROJECTORDEVICE_1').keys) {
        if (p.uiSchema.isHiddenFor(prop, block,
            sectionKey: 'PROJECTORDEVICE_1')) {
          continue;
        }
        expect(block.containsKey(prop), isTrue, reason: prop);
      }
      // And the family count was raised to match.
      expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '1');
    });

    test('the diagram and the config become one device, cables and all', () {
      final p = budgetedRoom();
      p.addAvNode(
        const AvNode(
          id: 'AVNODE_1',
          label: 'front proj',
          model: 'Projector',
          pos: Offset.zero,
          ports: [
            AvPort(
              id: 'in_1',
              label: 'HDMI',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          ],
        ),
      );
      p.addAvNode(
        const AvNode(
          id: 'AVNODE_2',
          label: 'switcher',
          model: 'Switcher',
          pos: Offset(400, 0),
          ports: [
            AvPort(
              id: 'out_1',
              label: 'OUT',
              signal: SignalType.hdmi,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
          ],
        ),
      );
      p.addAvCable(
        fromNodeId: 'AVNODE_2',
        fromPortId: 'out_1',
        toNodeId: 'AVNODE_1',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );

      applyControlSide(p, planControlSide(p));

      // The nodes were re-keyed onto their blocks...
      expect(p.avNodeById('PROJECTORDEVICE_1'), isNotNull);
      expect(p.avNodeById('AVNODE_1'), isNull);
      // ...the cable came with them...
      expect(p.avCables.single.toNodeId, 'PROJECTORDEVICE_1');
      expect(p.avCables.single.fromNodeId, 'SWITCHERDEVICE_1');
      // ...and nothing is left on the "drawn but not configured" list.
      expect(p.avDevicesWithoutControl, isEmpty);
    });

    test('a second run adds to the room rather than renumbering it', () {
      final p = budgetedRoom();
      p.addAvNode(drawn('AVNODE_1', 'front proj', 'Projector'));
      applyControlSide(p, planControlSide(p));

      p.addAvNode(drawn('AVNODE_9', 'rear proj', 'Projector'));
      final second = planControlSide(p);
      expect(second.alreadyConfigured, 1);
      expect(second.creatable.single.sectionKey, 'PROJECTORDEVICE_2');

      applyControlSide(p, second);
      expect(p.roomConfig['PROJECTORDEVICE_1']['name'], 'Projector 1');
      expect(p.roomConfig['PROJECTORDEVICE_2']['name'], 'Projector 2');
      expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '2');
    });

    test('a device no family claims is reported, not silently dropped', () {
      final p = budgetedRoom();
      p.addAvNode(drawn('AVNODE_1', 'Ceiling speakers', 'Speaker pair'));

      final plan = planControlSide(p);
      expect(plan.unplaceable.length, 1);
      expect(plan.creatable, isEmpty);
      // Nothing to create means nothing gets written, rather than an empty
      // block appearing in some default family.
      expect(applyControlSide(p, plan).created, 0);
    });
  });
}
