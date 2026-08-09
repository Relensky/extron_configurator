import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// Several devices can share one rack unit — a Revolabs receiver, a DTP
/// receiver and a micro PC on the same shelf. The rail splits evenly between
/// however many are on it, closes ranks when one leaves, and the whole thing
/// has to survive the sidecar round trip.
///
/// Also covers the room's signal palette: recolouring a type moves every run
/// of it, which is the difference between a legend and a decoration.
void main() {
  late Directory dir;
  late String configPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('av_shared_rack_test_');
    configPath = path.join(dir.path, 'BSS103_config.json');
    File(configPath).writeAsStringSync('{}');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider openedOn(String configFile) =>
      AppStateProvider(autoLoadSettings: false)..currentConfigPath = configFile;

  AvNode device(String id, {int units = 1}) => AvNode(
    id: id,
    label: id,
    model: 'Model $id',
    pos: Offset.zero,
    rackUnits: units,
    ports: const [
      AvPort(
        id: 'out_1',
        label: 'OUT',
        signal: SignalType.hdmi,
        direction: PortDirection.output,
        side: PortSide.right,
      ),
      AvPort(
        id: 'in_1',
        label: 'IN',
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
      ),
    ],
  );

  group('sharing a rack unit', () {
    test('three devices on one U each take a third of the rail', () {
      final p = openedOn(configPath);
      for (final id in ['REVOLABS', 'DTPRX', 'MICROPC']) {
        p.addAvNode(device(id));
      }
      final rack = p.addAvRack('Rack 1', 12);

      for (final id in ['REVOLABS', 'DTPRX', 'MICROPC']) {
        expect(
          p.avRackPlaceSharing(
            nodeId: id,
            rackId: rack.id,
            face: RackFace.front,
            startU: 5,
          ),
          isTrue,
          reason: '$id should fit on the shared rail',
        );
      }

      final order = p.avRackOccupantsAt(
        rackId: rack.id,
        face: RackFace.front,
        startU: 5,
      );
      expect(order, ['REVOLABS', 'DTPRX', 'MICROPC']);
      for (int i = 0; i < 3; i++) {
        final slice = p.avRackSlots[order[i]]!.slice;
        expect(slice.columns, 3);
        expect(slice.column, i);
      }
      expect(p.avRackSlots['MICROPC']!.slice.label, '3/3');
    });

    test('three devices can share a 2U span', () {
      final p = openedOn(configPath);
      for (final id in ['REVOLABS', 'DTPRX', 'MICROPC']) {
        p.addAvNode(device(id, units: 2));
      }
      final rack = p.addAvRack('Rack 1', 12);
      for (final id in ['REVOLABS', 'DTPRX', 'MICROPC']) {
        p.avRackPlaceSharing(
          nodeId: id,
          rackId: rack.id,
          face: RackFace.front,
          startU: 3,
        );
      }

      expect(p.avRackSlots.length, 3);
      // They span U3-U4, so U4 is not separately available.
      expect(
        p.avRackSpanIsFree(
          rackId: rack.id,
          face: RackFace.front,
          startU: 4,
          heightU: 1,
        ),
        isFalse,
      );
    });

    test('a rail will not take more than the maximum', () {
      final p = openedOn(configPath);
      final rack = p.addAvRack('Rack 1', 12);
      for (int i = 0; i < kMaxRackColumns; i++) {
        p.addAvNode(device('D$i'));
        expect(
          p.avRackPlaceSharing(
            nodeId: 'D$i',
            rackId: rack.id,
            face: RackFace.front,
            startU: 2,
          ),
          isTrue,
        );
      }
      p.addAvNode(device('ONETOOMANY'));
      expect(
        p.avRackPlaceSharing(
          nodeId: 'ONETOOMANY',
          rackId: rack.id,
          face: RackFace.front,
          startU: 2,
        ),
        isFalse,
      );
    });

    test('the survivors close ranks when one leaves', () {
      final p = openedOn(configPath);
      for (final id in ['A', 'B', 'C']) {
        p.addAvNode(device(id));
      }
      final rack = p.addAvRack('Rack 1', 12);
      for (final id in ['A', 'B', 'C']) {
        p.avRackPlaceSharing(
          nodeId: id,
          rackId: rack.id,
          face: RackFace.front,
          startU: 6,
        );
      }
      expect(p.avRackSlots['A']!.slice.columns, 3);

      p.setAvRackSlot('B', null); // un-rack the middle one

      expect(p.avRackSlots['A']!.slice.columns, 2);
      expect(p.avRackSlots['A']!.slice.column, 0);
      expect(p.avRackSlots['C']!.slice.columns, 2);
      expect(p.avRackSlots['C']!.slice.column, 1);

      // Down to one, and it takes the whole rail back.
      p.setAvRackSlot('C', null);
      expect(p.avRackSlots['A']!.slice.columns, 1);
      expect(p.avRackSlots['A']!.slice.label, 'Full');
    });

    test('reordering slides the neighbours rather than swapping', () {
      final p = openedOn(configPath);
      for (final id in ['A', 'B', 'C']) {
        p.addAvNode(device(id));
      }
      final rack = p.addAvRack('Rack 1', 12);
      for (final id in ['A', 'B', 'C']) {
        p.avRackPlaceSharing(
          nodeId: id,
          rackId: rack.id,
          face: RackFace.front,
          startU: 1,
        );
      }

      p.avRackReorderRow('C', 0); // C to the front

      expect(
        p.avRackOccupantsAt(rackId: rack.id, face: RackFace.front, startU: 1),
        ['C', 'A', 'B'],
      );
    });

    test('a taller neighbour spanning in still blocks the rail', () {
      final p = openedOn(configPath);
      p.addAvNode(device('TALL', units: 3));
      p.addAvNode(device('SMALL'));
      final rack = p.addAvRack('Rack 1', 12);
      p.setAvRackSlot('TALL', RackSlot(rackId: rack.id, startU: 4));

      // U5 is inside the 3U device, and nothing is registered as starting
      // there, so this is the "spanning in from elsewhere" case.
      expect(
        p.avRackPlaceSharing(
          nodeId: 'SMALL',
          rackId: rack.id,
          face: RackFace.front,
          startU: 5,
        ),
        isFalse,
      );
    });

    test('faces never interact', () {
      final p = openedOn(configPath);
      p.addAvNode(device('FRONT'));
      p.addAvNode(device('REAR'));
      final rack = p.addAvRack('Rack 1', 12);

      p.avRackPlaceSharing(
        nodeId: 'FRONT',
        rackId: rack.id,
        face: RackFace.front,
        startU: 3,
      );
      p.avRackPlaceSharing(
        nodeId: 'REAR',
        rackId: rack.id,
        face: RackFace.rear,
        startU: 3,
      );

      // Each is alone on its own face, so each keeps the whole rail.
      expect(p.avRackSlots['FRONT']!.slice.columns, 1);
      expect(p.avRackSlots['REAR']!.slice.columns, 1);
    });
  });

  test('shared slices and the rack type survive the sidecar round trip',
      () async {
    final p = openedOn(configPath);
    for (final id in ['A', 'B']) {
      p.addAvNode(device(id));
    }
    final rack = p.addAvRack('Rack 1', 12, kind: 'Lectern built-in rack');
    for (final id in ['A', 'B']) {
      p.avRackPlaceSharing(
        nodeId: id,
        rackId: rack.id,
        face: RackFace.front,
        startU: 2,
      );
    }

    expect(await p.saveAvFlow(), isNotEmpty);
    final reopened = openedOn(configPath)..loadAvFlowForCurrentConfig();

    expect(reopened.avRacks.single.kind, 'Lectern built-in rack');
    expect(reopened.avRackSlots['A']!.slice.columns, 2);
    expect(reopened.avRackSlots['A']!.slice.column, 0);
    expect(reopened.avRackSlots['B']!.slice.column, 1);
  });

  test('a diagram saved with the old left/right halves still opens', () {
    // Files written before rails could be split any number of ways used
    // "half": "left" / "right". They have to keep working.
    File(path.join(dir.path, 'BSS103_config_av_flow.json')).writeAsStringSync('''
{
  "nodes": [
    {"id": "A", "label": "A", "model": "", "x": 0, "y": 0, "rackUnits": 1,
     "rackWidth": "half", "ports": []},
    {"id": "B", "label": "B", "model": "", "x": 0, "y": 0, "rackUnits": 1,
     "rackWidth": "half", "ports": []}
  ],
  "cables": [],
  "racks": [{"id": "R1", "name": "Rack 1", "heightU": 12, "x": 0}],
  "rackSlots": {
    "A": {"rack": "R1", "startU": 4, "face": "front", "half": "left"},
    "B": {"rack": "R1", "startU": 4, "face": "front", "half": "right"}
  }
}
''');

    final p = openedOn(configPath)..loadAvFlowForCurrentConfig();

    expect(p.avRackSlots['A']!.slice.columns, 2);
    expect(p.avRackSlots['A']!.slice.column, 0);
    expect(p.avRackSlots['B']!.slice.column, 1);
  });

  group('the signal palette', () {
    test('recolouring a type moves every run of it, and the legend', () {
      final p = openedOn(configPath);
      expect(p.avSignalColor(SignalType.hdmi), kSignalColors[SignalType.hdmi]);

      const orange = Color(0xFFFFA726);
      p.setAvSignalColor(SignalType.hdmi, orange);

      expect(p.avSignalColor(SignalType.hdmi), orange);
      // Only HDMI moved.
      expect(
        p.avSignalColor(SignalType.hdbaset),
        kSignalColors[SignalType.hdbaset],
      );

      const cable = AvCable(
        id: 'C1',
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );
      expect(cable.colorFor(p.avSignalColors), orange);
      // The legend reads the same function, so key and drawing cannot drift.
      expect(signalColor(SignalType.hdmi, p.avSignalColors), orange);

      p.setAvSignalColor(SignalType.hdmi, null);
      expect(cable.colorFor(p.avSignalColors), kSignalColors[SignalType.hdmi]);
    });

    test('a per-cable override still beats the palette', () {
      final p = openedOn(configPath);
      p.setAvSignalColor(SignalType.hdmi, const Color(0xFFFFA726));

      const cable = AvCable(
        id: 'C1',
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
        colorOverride: Color(0xFFEF5350),
      );
      expect(cable.colorFor(p.avSignalColors), const Color(0xFFEF5350));
    });

    test('the palette round-trips through the sidecar', () async {
      final p = openedOn(configPath);
      p.setAvSignalColor(SignalType.power, const Color(0xFFEF5350));
      p.setAvSignalColor(SignalType.hdbaset, const Color(0xFF9CCC65));

      expect(await p.saveAvFlow(), isNotEmpty);
      final reopened = openedOn(configPath)..loadAvFlowForCurrentConfig();

      expect(
        reopened.avSignalColor(SignalType.power).toARGB32(),
        const Color(0xFFEF5350).toARGB32(),
      );
      expect(
        reopened.avSignalColor(SignalType.hdbaset).toARGB32(),
        const Color(0xFF9CCC65).toARGB32(),
      );
      expect(
        reopened.avSignalColor(SignalType.hdmi),
        kSignalColors[SignalType.hdmi],
      );
    });
  });

  group('cable colour overrides', () {
    test('a run follows its signal type until it is overridden', () {
      const cable = AvCable(
        id: 'C1',
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );

      expect(cable.hasCustomColor, isFalse);
      expect(cable.colorFor(), kSignalColors[SignalType.hdmi]);

      const custom = Color(0xFFEF5350);
      final recoloured = cable.copyWith(colorOverride: custom);
      expect(recoloured.hasCustomColor, isTrue);
      expect(recoloured.colorFor(), custom);

      // Changing the signal type does NOT drag the override along with it.
      expect(recoloured.copyWith(signal: SignalType.dante).colorFor(), custom);

      final reset = recoloured.copyWith(clearColorOverride: true);
      expect(reset.hasCustomColor, isFalse);
      expect(reset.colorFor(), kSignalColors[SignalType.hdmi]);
    });

    test('the legend only speaks for runs drawn in their signal colour', () {
      const base = AvCable(
        id: 'C1',
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );
      final model = AvFlowModel(
        nodes: [device('A')],
        cables: [base, base.copyWith(colorOverride: const Color(0xFFEF5350))],
        racks: const [],
        rackSlots: const {},
        canvasSize: const Size(900, 560),
        roomTitle: 'Test',
        unplaced: const [],
      );

      expect(model.usedSignals, [SignalType.hdmi]);
      expect(model.hasCustomCableColors, isTrue);
    });
  });
}
