import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate.dart';

/// A drawn line's quantity can be typed on the Cost tab. Fewer than the
/// drawing has is the quote's own count; more adds units to the drawing,
/// named on in sequence.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    for (final id in ['D1', 'D2']) {
      p.addAvNode(
        AvNode(
          id: id,
          label: 'Display',
          model: 'Display X',
          pos: Offset.zero,
          ports: const [],
        ),
        recordUndo: false,
      );
    }
    return p;
  }

  CostEstimate estimateOf(AppStateProvider p) {
    final library = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(model: 'Display X', price: 1000, ports: []),
      );
    return computeRoomCost(
      model: buildAvFlowModel(p),
      library: library,
      settings: p.avCost,
    );
  }

  List<String> labels(AppStateProvider p) => [
    for (final n in p.avNodes)
      if (n.model == 'Display X') n.label,
  ];

  test('fewer than drawn replaces the drawn count on the quote', () {
    final p = room();
    final line = estimateOf(p).equipment.single;
    expect(line.qty, 2);
    expect(line.onDiagram, isNull);

    p.setAvEquipmentQty(line.key, 1, drawn: 2);
    final now = estimateOf(p).equipment.single;
    expect(now.qty, 1);
    expect(now.onDiagram, 2);
    expect(now.total, 1000);
    // The drawing is untouched.
    expect(labels(p), ['Display', 'Display']);
  });

  test('more than drawn adds units, numbered on from the rest', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 4, drawn: 2);
    expect(labels(p), ['Display 1', 'Display 2', 'Display 3', 'Display 4']);
    expect(p.avCost.qtyOverrides, isEmpty);
    final now = estimateOf(p).equipment.single;
    expect(now.qty, 4);
    expect(now.onDiagram, isNull);

    p.setAvEquipmentQty(key, 5, drawn: 4);
    expect(labels(p).last, 'Display 5');
  });

  test('the name typed on the line is the base of the numbers', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvCostLineName(key, 'Network PDU TV');
    p.setAvEquipmentQty(key, 3, drawn: 2);
    expect(labels(p), [
      'Network PDU TV 1',
      'Network PDU TV 2',
      'Network PDU TV 3',
    ]);
  });

  test('one fewer takes the highest-numbered loose unit off', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 4, drawn: 2);
    p.removeAvEquipmentUnit(key, quoted: 4);
    expect(labels(p), ['Display 1', 'Display 2', 'Display 3']);
    expect(p.avCost.qtyOverrides, isEmpty);
  });

  test('back down to one, the unit loses its number', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.removeAvEquipmentUnit(key, quoted: 2);
    expect(labels(p), ['Display']);
    p.setAvEquipmentQty(key, 2, drawn: 1);
    p.removeAvEquipmentUnit(key, quoted: 2);
    expect(labels(p), ['Display']);
  });

  test('one fewer takes a cabled unit off too, with its cable', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    for (final id in ['D1', 'D2']) {
      p.avCables.add(
        AvCable(
          id: 'C$id',
          fromNodeId: id,
          fromPortId: 'out',
          toNodeId: 'X',
          toPortId: 'in',
          signal: SignalType.hdmi,
        ),
      );
    }
    p.removeAvEquipmentUnit(key, quoted: 2);
    expect(labels(p), ['Display']);
    expect(p.avCables.map((c) => c.id), ['CD1']);
    expect(p.avCost.qtyOverrides.containsKey(key), isFalse);
  });

  test('one fewer takes a unit in the config out of the config', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.roomConfig['SYSTEM_SETUP'] = {'dev_projectors': '3'};
    for (final n in [1, 2, 3]) {
      p.roomConfig['PROJECTORDEVICE_$n'] = {'name': 'Projector $n'};
    }
    // Three drawn units, the third tied to the config's third projector.
    p.setAvEquipmentQty(key, 3, drawn: 2);
    final third = p.avNodes.last;
    expect(p.rekeyAvNode(third.id, 'PROJECTORDEVICE_3'), isTrue);
    p.removeAvEquipmentUnit(key, quoted: 3);
    p.removeAvEquipmentUnit(key, quoted: 2);
    p.removeAvEquipmentUnit(key, quoted: 1);
    expect(labels(p), isEmpty);
    expect(p.roomConfig.containsKey('PROJECTORDEVICE_3'), isFalse);
    expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '2');
  });

  test('spares still go on top, and it round-trips', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 1, drawn: 2);
    p.setAvEquipmentSpares(key, 1);
    expect(estimateOf(p).equipment.single.qty, 2);

    final back = RoomCostSettings()..readJson(p.avCost.toJson());
    expect(back.qtyOverrides[key], 1);
  });

  test('clearing it, or typing the drawn count, follows the drawing again',
      () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 1, drawn: 2);
    p.setAvEquipmentQty(key, null, drawn: 2);
    expect(p.avCost.qtyOverrides, isEmpty);
    p.setAvEquipmentQty(key, 1, drawn: 2);
    p.setAvEquipmentQty(key, 2, drawn: 2);
    expect(p.avCost.qtyOverrides, isEmpty);
    expect(estimateOf(p).equipment.single.onDiagram, isNull);
  });

  test('a typo far past the count stays a quote figure', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 200, drawn: 2);
    expect(labels(p), hasLength(2));
    expect(p.avCost.qtyOverrides[key], 200);
  });

  test('fewer typed takes units off once the typing is done', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 6, drawn: 2);
    // Per keystroke it is only the quote's figure.
    p.setAvEquipmentQty(key, 3, drawn: 6);
    expect(labels(p), hasLength(6));
    p.settleAvEquipmentQty(key);
    expect(labels(p), ['Display 1', 'Display 2', 'Display 3']);
    expect(p.avCost.qtyOverrides, isEmpty);
    // Settled twice, nothing more goes.
    p.settleAvEquipmentQty(key);
    expect(labels(p), hasLength(3));
  });

  test('typing more passes through fewer without losing units', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 13, drawn: 2);
    // "20" typed over "13": "2", then "20", then done.
    p.setAvEquipmentQty(key, 2, drawn: 13);
    p.setAvEquipmentQty(key, 20, drawn: 13);
    p.settleAvEquipmentQty(key);
    expect(labels(p), hasLength(20));
    expect(labels(p).last, 'Display 20');
  });

  test('settled fewer takes cabled units off too', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 4, drawn: 2);
    p.avCables.add(
      const AvCable(
        id: 'C1',
        fromNodeId: 'D1',
        fromPortId: 'out',
        toNodeId: 'X',
        toPortId: 'in',
        signal: SignalType.hdmi,
      ),
    );
    p.setAvEquipmentQty(key, 0, drawn: 4);
    p.settleAvEquipmentQty(key);
    expect(labels(p), isEmpty);
    expect(p.avCables, isEmpty);
    expect(p.avCost.qtyOverrides.containsKey(key), isFalse);
  });
}
