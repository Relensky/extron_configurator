import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate.dart';

/// A drawn line's quantity can be typed on the Cost tab; the drawing keeps
/// its own count.
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

  test('a typed quantity replaces the drawn count on the quote', () {
    final p = room();
    final line = estimateOf(p).equipment.single;
    expect(line.qty, 2);
    expect(line.onDiagram, isNull);

    p.setAvEquipmentQty(line.key, 12, drawn: 2);
    final now = estimateOf(p).equipment.single;
    expect(now.qty, 12);
    expect(now.drawnQty, 12);
    expect(now.onDiagram, 2);
    expect(now.total, 12000);
    // The drawing is untouched.
    expect(p.avNodes.where((n) => n.model == 'Display X'), hasLength(2));
  });

  test('spares still go on top, and it round-trips', () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 5, drawn: 2);
    p.setAvEquipmentSpares(key, 1);
    expect(estimateOf(p).equipment.single.qty, 6);

    final back = RoomCostSettings()..readJson(p.avCost.toJson());
    expect(back.qtyOverrides[key], 5);
  });

  test('clearing it, or typing the drawn count, follows the drawing again',
      () {
    final p = room();
    final key = estimateOf(p).equipment.single.key;
    p.setAvEquipmentQty(key, 7, drawn: 2);
    p.setAvEquipmentQty(key, null, drawn: 2);
    expect(p.avCost.qtyOverrides, isEmpty);
    p.setAvEquipmentQty(key, 7, drawn: 2);
    p.setAvEquipmentQty(key, 2, drawn: 2);
    expect(p.avCost.qtyOverrides, isEmpty);
    expect(estimateOf(p).equipment.single.onDiagram, isNull);
  });
}
