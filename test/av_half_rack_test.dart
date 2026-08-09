import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// Half-width devices pair up two to a rack unit, and a run can be recoloured
/// away from its signal type. Both have to survive the sidecar round trip, and
/// the occupancy rules have to understand that two halves are not a clash.
void main() {
  late Directory dir;
  late String configPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('av_half_rack_test_');
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

  AvNode device(String id, {required RackWidth width, int units = 1}) => AvNode(
    id: id,
    label: id,
    model: 'Model $id',
    pos: Offset.zero,
    rackUnits: units,
    rackWidth: width,
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

  group('half-rack occupancy', () {
    test('two halves share a U, a third on the same side does not', () {
      final p = openedOn(configPath);
      p.addAvNode(device('LEFT', width: RackWidth.half));
      p.addAvNode(device('RIGHT', width: RackWidth.half));
      final rack = p.addAvRack('Rack 1', 12);

      p.setAvRackSlot(
        'LEFT',
        RackSlot(rackId: rack.id, startU: 4, half: RackHalf.left),
      );

      // The other half of U4 is still free...
      expect(
        p.avRackSpanIsFree(
          rackId: rack.id,
          face: RackFace.front,
          startU: 4,
          heightU: 1,
          half: RackHalf.right,
        ),
        isTrue,
      );
      // ...but the left half is taken, and a full-width device wants both.
      expect(
        p.avRackSpanIsFree(
          rackId: rack.id,
          face: RackFace.front,
          startU: 4,
          heightU: 1,
          half: RackHalf.left,
        ),
        isFalse,
      );
      expect(
        p.avRackSpanIsFree(
          rackId: rack.id,
          face: RackFace.front,
          startU: 4,
          heightU: 1,
          half: RackHalf.full,
        ),
        isFalse,
      );

      p.setAvRackSlot(
        'RIGHT',
        RackSlot(rackId: rack.id, startU: 4, half: RackHalf.right),
      );
      expect(p.avRackSlots.length, 2);
      expect(p.avRackSlots['RIGHT']!.startU, 4);
    });

    test('a full-width device blocks both halves of every U it spans', () {
      final p = openedOn(configPath);
      p.addAvNode(device('BIG', width: RackWidth.full, units: 2));
      final rack = p.addAvRack('Rack 1', 12);
      p.setAvRackSlot('BIG', RackSlot(rackId: rack.id, startU: 6));

      for (final half in [RackHalf.left, RackHalf.right, RackHalf.full]) {
        for (final u in [6, 7]) {
          expect(
            p.avRackSpanIsFree(
              rackId: rack.id,
              face: RackFace.front,
              startU: u,
              heightU: 1,
              half: half,
            ),
            isFalse,
            reason: 'U$u ${half.name} should be blocked by the 2U device',
          );
        }
      }
      // The U above the pair is clear.
      expect(
        p.avRackSpanIsFree(
          rackId: rack.id,
          face: RackFace.front,
          startU: 8,
          heightU: 1,
          half: RackHalf.left,
        ),
        isTrue,
      );
    });

    test('halves on opposite faces never interact', () {
      final p = openedOn(configPath);
      p.addAvNode(device('A', width: RackWidth.half));
      final rack = p.addAvRack('Rack 1', 12);
      p.setAvRackSlot(
        'A',
        RackSlot(
          rackId: rack.id,
          startU: 3,
          face: RackFace.front,
          half: RackHalf.left,
        ),
      );

      expect(
        p.avRackSpanIsFree(
          rackId: rack.id,
          face: RackFace.rear,
          startU: 3,
          heightU: 1,
          half: RackHalf.left,
        ),
        isTrue,
      );
    });
  });

  test('half width and slot side survive the sidecar round trip', () async {
    final p = openedOn(configPath);
    p.addAvNode(device('LEFT', width: RackWidth.half));
    p.addAvNode(device('RIGHT', width: RackWidth.half));
    final rack = p.addAvRack('Rack 1', 12);
    p.setAvRackSlot(
      'LEFT',
      RackSlot(rackId: rack.id, startU: 2, half: RackHalf.left),
    );
    p.setAvRackSlot(
      'RIGHT',
      RackSlot(
        rackId: rack.id,
        startU: 2,
        face: RackFace.rear,
        half: RackHalf.right,
      ),
    );

    expect(await p.saveAvFlow(), isNotEmpty);
    final reopened = openedOn(configPath)..loadAvFlowForCurrentConfig();

    expect(reopened.avNodeById('LEFT')!.rackWidth, RackWidth.half);
    expect(reopened.avNodeById('LEFT')!.isHalfRack, isTrue);
    expect(reopened.avRackSlots['LEFT']!.half, RackHalf.left);
    expect(reopened.avRackSlots['RIGHT']!.half, RackHalf.right);
    expect(reopened.avRackSlots['RIGHT']!.face, RackFace.rear);
  });

  group('cable colours', () {
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
      expect(cable.color, kSignalColors[SignalType.hdmi]);

      const custom = Color(0xFFEF5350);
      final recoloured = cable.copyWith(colorOverride: custom);
      expect(recoloured.hasCustomColor, isTrue);
      expect(recoloured.color, custom);

      // Changing the signal type does NOT drag the override along with it.
      final retyped = recoloured.copyWith(signal: SignalType.dante);
      expect(retyped.color, custom);

      // ...and clearing it hands the run back to the palette.
      final reset = retyped.copyWith(clearColorOverride: true);
      expect(reset.hasCustomColor, isFalse);
      expect(reset.color, kSignalColors[SignalType.dante]);
    });

    test('an overridden colour round-trips through the sidecar', () async {
      final p = openedOn(configPath);
      p.addAvNode(device('A', width: RackWidth.full));
      p.addAvNode(device('B', width: RackWidth.full));
      final cable = p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      )!;
      p.updateAvCable(cable.copyWith(colorOverride: const Color(0xFFEF5350)));

      expect(await p.saveAvFlow(), isNotEmpty);
      final reopened = openedOn(configPath)..loadAvFlowForCurrentConfig();

      final restored = reopened.avCables.single;
      expect(restored.hasCustomColor, isTrue);
      expect(restored.color.toARGB32(), const Color(0xFFEF5350).toARGB32());
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
        nodes: [device('A', width: RackWidth.full)],
        cables: [
          base,
          base.copyWith(colorOverride: const Color(0xFFEF5350)),
        ],
        racks: const [],
        rackSlots: const {},
        canvasSize: const Size(900, 560),
        roomTitle: 'Test',
        unplaced: const [],
      );

      // HDMI still earns its legend line from the un-overridden run...
      expect(model.usedSignals, [SignalType.hdmi]);
      // ...and the page admits that not every line follows the key.
      expect(model.hasCustomCableColors, isTrue);

      final allCustom = AvFlowModel(
        nodes: model.nodes,
        cables: [base.copyWith(colorOverride: const Color(0xFFEF5350))],
        racks: const [],
        rackSlots: const {},
        canvasSize: const Size(900, 560),
        roomTitle: 'Test',
        unplaced: const [],
      );
      expect(allCustom.usedSignals, isEmpty);
    });
  });
}
