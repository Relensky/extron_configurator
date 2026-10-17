import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';

/// A priority that buys only some categories, with lines flagged by hand and
/// the project's add-ons taken off or changed per room.
void main() {
  const empty = AvFlowModel(
    nodes: [],
    cables: [],
    racks: [],
    rackSlots: {},
    canvasSize: Size(0, 0),
    roomTitle: '',
    unplaced: [],
  );
  final library = AvDeviceLibrary.empty()
    ..upsert(const AvDeviceTemplate(
        model: 'RPMAU', category: 'Mount', price: 300, ports: []));

  BuildingProject p5() => BuildingProject(
        priorityBuysOnly: {
          5: ['Projector'],
        },
        priorityAddOns: {
          5: [(model: 'RPMAU', description: 'Chief RPMAU mount', qty: 1.0)],
        },
      );

  RoomCostSettings room() => RoomCostSettings()
    ..extraEquipment.addAll([
      const CostLineItem(
          id: 'EQP_1', description: 'Projector', category: 'Projector',
          unitPrice: 2000),
      const CostLineItem(
          id: 'EQP_2', description: 'Screen', category: 'Screen',
          unitPrice: 800),
    ]);

  CostEstimate scoped(RoomCostSettings s) {
    final whole = computeRoomCost(model: empty, library: library, settings: s);
    final settings = projectScopedSettings(
      project: p5(),
      priority: 5,
      estimate: whole,
      settings: s,
      library: library,
    )!;
    return computeRoomCost(model: empty, library: library, settings: settings);
  }

  test('a line flagged by hand is bought; the rest stay existing', () {
    final s = room();
    expect(scoped(s).equipment.map((l) => l.key), ['EQP_1']);
    s.projectBuys.add('EQP_2');
    expect(scoped(s).equipment.map((l) => l.key), ['EQP_1', 'EQP_2']);
  });

  test('the add-on is under Other items, and can come off one room', () {
    final s = room();
    expect(scoped(s).extras.single.key, projectAddOnId(5, 0));
    s.droppedAddOns.add(projectAddOnId(5, 0));
    expect(scoped(s).extras, isEmpty);
  });

  test('the flags and dropped add-ons are saved', () {
    final s = room()
      ..projectBuys.add('EQP_2')
      ..droppedAddOns.add(projectAddOnId(5, 0));
    final back = RoomCostSettings()..readJson(s.toJson());
    expect(back.projectBuys, {'EQP_2'});
    expect(back.droppedAddOns, {projectAddOnId(5, 0)});
  });

  test('editing the add-on in a room makes it the room\'s own line', () {
    final p = AppStateProvider(autoLoadSettings: false);
    final id = projectAddOnId(5, 0);
    p.updateAvCostItem(const CostLineItem(
      id: 'addon:5:0',
      description: 'Peerless mount',
      catalogModel: 'PRG-UNV',
      category: 'Mount',
    ));
    expect(p.avCost.droppedAddOns, {id});
    final own = p.avCost.items.single;
    expect(own.id, isNot(id));
    expect(own.description, 'Peerless mount');
    expect(p.avCost.projectBuys, {own.id});

    p.removeAvCostItem(projectAddOnId(5, 1));
    expect(p.avCost.droppedAddOns, {id, projectAddOnId(5, 1)});
  });
}
