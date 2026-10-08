import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/room_locations.dart';

void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  CostLine line(String name, double qty, {bool spare = false}) => CostLine(
    key: name,
    description: name,
    qty: qty,
    unitPrice: 0,
    spare: spare,
  );

  group('the add-device menu', () {
    test('is alphabetical, one entry per name, quantities added', () {
      final choices = roomDeviceChoices([
        line('Projector', 1),
        line('display', 2),
        line('Camera', 1),
        line('Display', 1),
        line('Lamp', 3, spare: true),
      ]);
      expect([for (final c in choices) c.name], [
        'Camera',
        'display',
        'Projector',
      ]);
      expect(choices[1].qty, 3);
      expect(choices.first.shape, 'camera');
      expect(choices.last.shape, 'projector');
    });

    test('guesses the icon from the name', () {
      expect(guessDeviceShape('Extron TLP Pro 725M'), 'touchPanel');
      expect(guessDeviceShape('75" LCD Display'), 'display');
      expect(guessDeviceShape('PTZ Camera'), 'camera');
      expect(guessDeviceShape('Something else'), 'other');
    });
  });

  group('placed devices', () {
    test('survive a save and a reload with their aim and cone', () {
      const sheet = FloorPlan(
        id: 'PLAN_1',
        name: 'L1',
        devices: [
          PlanDevice(
            id: 'DEV_1',
            deviceKey: 'camera',
            label: 'Camera',
            shape: 'camera',
            pos: Offset(100, 200),
            rotation: 90,
            showFov: true,
            fov: 70,
            range: 300,
          ),
        ],
      );
      final back = FloorPlan.fromJson(sheet.toJson()).devices.single;
      expect(back.pos, const Offset(100, 200));
      expect(back.rotation, 90);
      expect(back.showFov, isTrue);
      expect(back.fov, 70);
      expect(back.range, 300);
      expect(sheet.withId('PLAN_2').devices, hasLength(1));
    });

    test('rotation 90 faces right', () {
      const d = PlanDevice(
        id: '',
        deviceKey: '',
        label: '',
        shape: 'camera',
        pos: Offset.zero,
        rotation: 90,
      );
      expect(d.facing.dx, closeTo(1, 1e-9));
      expect(d.facing.dy, closeTo(0, 1e-9));
    });

    test('a sheet takes no more of a device than the estimate buys', () {
      final p = room();
      p.addAvCostExtraEquipment(description: 'Ceiling Speaker', qty: 2);
      final plan = p.addAvFloorPlan(const FloorPlan(id: '', name: 'L1'));
      final key = roomDeviceKey('Ceiling Speaker');
      PlanDevice speaker() => PlanDevice(
        id: '',
        deviceKey: key,
        label: 'Ceiling Speaker',
        shape: 'speaker',
        pos: Offset.zero,
      );

      expect(p.planDeviceLimit(key), 2);
      expect(p.addAvPlanDevice(plan.id, speaker()), isNotNull);
      expect(p.addAvPlanDevice(plan.id, speaker()), isNotNull);
      expect(p.addAvPlanDevice(plan.id, speaker()), isNull);
      expect(p.avFloorPlanById(plan.id)!.devices, hasLength(2));

      // Raising the quantity on the estimate makes room for another.
      final item = p.avCost.extraEquipment.single;
      p.updateAvCostExtraEquipment(
        CostLineItem(id: item.id, description: item.description, qty: 3),
      );
      expect(p.addAvPlanDevice(plan.id, speaker()), isNotNull);
    });

    test('margins carry devices with the drawing', () {
      final p = room();
      p.addAvCostExtraEquipment(description: 'Projector');
      final plan = p.addAvFloorPlan(const FloorPlan(id: '', name: 'L1'));
      p.addAvPlanDevice(
        plan.id,
        PlanDevice(
          id: '',
          deviceKey: roomDeviceKey('Projector'),
          label: 'Projector',
          shape: 'projector',
          pos: const Offset(50, 60),
        ),
      );
      p.setAvPlanMargins(plan.id, const EdgeInsets.only(left: 40, top: 10));
      expect(
        p.avFloorPlanById(plan.id)!.devices.single.pos,
        const Offset(90, 70),
      );
    });
  });

  test('a cabling device box keeps its estimate link and its turn', () {
    const box = CablingBox(
      id: 'box:1',
      label: 'Projector',
      kind: CablingBoxKind.device,
      shape: 'projector',
      deviceKey: 'projector',
      rotation: 45,
    );
    final back = CablingBox.fromJson(box.toJson());
    expect(back.deviceKey, 'projector');
    expect(back.rotation, 45);
  });

  group('units on the AV Flow', () {
    AvNode unit(String id, String label, {String model = 'PJ-1'}) => AvNode(
      id: id,
      label: label,
      model: model,
      pos: Offset.zero,
      ports: const [],
    );

    test('each unit is its own menu entry under its own name', () {
      final choices = roomDeviceChoices(
        [line('Projector A, Projector B', 3)],
        units: {
          'Projector A, Projector B': [
            unit('P1', 'Projector A'),
            unit('P2', 'Projector B'),
          ],
        },
      );
      expect([for (final c in choices) '${c.key} ${c.name} ${c.qty}'], [
        'node:P1 Projector A 1',
        // One more bought than drawn, offered by name.
        'projector a, projector b Projector A, Projector B 1',
        'node:P2 Projector B 1',
      ]);
    });

    test('a device placed by name is tied to a unit, then follows renames',
        () {
      const placed = [
        PlanDevice(id: 'DEV_1', deviceKey: 'projector', label: 'Projector',
            shape: 'projector', pos: Offset.zero),
        PlanDevice(id: 'DEV_2', deviceKey: 'projector', label: 'Projector',
            shape: 'projector', pos: Offset.zero),
      ];
      final nodes = [unit('P1', 'Projector'), unit('P2', 'Projector')];
      final linked = linkPlanDevices(placed, nodes)!;
      expect([for (final d in linked) d.deviceKey], ['node:P1', 'node:P2']);
      expect(linkPlanDevices(linked, nodes), isNull);

      final renamed = linkPlanDevices(
        linked,
        [unit('P1', 'Projector 1', model: 'PJ-2'), unit('P2', 'Projector 2')],
      )!;
      expect([for (final d in renamed) d.label], ['Projector 1', 'Projector 2']);
    });

    test('a rename keeps the count, so a unit is placed once', () {
      final p = room();
      p.addAvNode(unit('PJ_A', 'Projector'));
      final plan = p.addAvFloorPlan(const FloorPlan(id: '', name: 'L1'));
      final choice = p.planDeviceChoices.single;
      expect(choice.key, 'node:PJ_A');
      PlanDevice place() => PlanDevice(
        id: '',
        deviceKey: choice.key,
        label: choice.name,
        shape: choice.shape,
        pos: Offset.zero,
      );
      expect(p.addAvPlanDevice(plan.id, place()), isNotNull);

      p.renameAvDevice('PJ_A', 'Projector 1');
      final sheet = p.avFloorPlanById(plan.id)!;
      expect(sheet.devices.single.label, 'Projector 1');
      expect(p.roomCost.equipment.single.description, 'Projector 1');
      // Still the one unit, and it is already on the sheet.
      expect(p.addAvPlanDevice(plan.id, place()), isNull);
    });
  });
}
