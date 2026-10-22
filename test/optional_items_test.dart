import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/labor_rates.dart';

/// Optional upgrades on a room's estimate: priced for the decision, counted
/// with the parts or apart in their own section, and purged once not bought.
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

  RoomCostSettings room() => RoomCostSettings()
    ..taxPercent = 10
    ..ownTaxRate = true
    ..extraEquipment.addAll([
      const CostLineItem(id: 'EQP_1', description: 'Projector', unitPrice: 1000),
      const CostLineItem(
          id: 'EQP_2', description: 'Laser upgrade', unitPrice: 500),
    ])
    ..optionalLines.add('EQP_2');

  CostEstimate price(RoomCostSettings s) => computeRoomCost(
      model: empty, library: AvDeviceLibrary.empty(), settings: s);

  test('left out: listed apart, both totals worked out', () {
    final e = price(room());
    expect(e.equipment.map((l) => l.key), ['EQP_1']);
    expect(e.optional.map((l) => l.key), ['EQP_2']);
    expect(e.optionalTotal, 500);
    expect(e.grandTotal, 1100);
    expect(e.grandWithoutOptions, 1100);
    expect(e.grandWithOptions, 1650);
    expect(e.hasOptional, isTrue);
  });

  test('counted: listed with the parts, nothing apart', () {
    final e = price(room()..includeOptional = true);
    expect(e.equipment.map((l) => l.key).toSet(), {'EQP_1', 'EQP_2'});
    expect(e.equipmentTotal, 1500);
    expect(e.optional, isEmpty);
    expect(e.inlineOptional, {'EQP_2'});
    expect(e.grandTotal, 1650);
    expect(e.grandWithoutOptions, 1100);
  });

  test('a room with no options is unchanged', () {
    final e = price(room()..optionalLines.clear());
    expect(e.grandTotal, 1650);
    expect(e.hasOptional, isFalse);
  });

  test('the flags and switches are saved', () {
    final s = room()..includeOptional = true;
    final back = RoomCostSettings()..readJson(s.toJson());
    expect(back.optionalLines, {'EQP_2'});
    expect(back.includeOptional, isTrue);
    final plain = RoomCostSettings()..readJson(RoomCostSettings().toJson());
    expect(plain.includeOptional, isFalse);
  });

  test('purging takes the options off the room', () {
    final p = AppStateProvider(autoLoadSettings: false);
    final keep = p.addAvCostExtraEquipment(description: 'Projector');
    final opt = p.addAvCostItem(description: 'Second screen');
    p.setAvCostOptional(opt.id, true);
    expect(p.avCost.optionalLines, {opt.id});

    expect(p.purgeAvCostOptional(), 1);
    expect(p.avCost.items, isEmpty);
    expect(p.avCost.extraEquipment.single.id, keep.id);
    expect(p.avCost.optionalLines, isEmpty);
  });

  testWidgets('on the Cost tab: flagged from the tag, totals both ways',
      (tester) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvCostExtraEquipment(description: 'Projector', unitPrice: 1000);
    final laser = p.addAvCostExtraEquipment(
      description: 'Laser upgrade',
      manufacturer: 'Epson',
      partNumber: 'V11HA25020',
      unitPrice: 500,
    );
    await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
      value: p,
      child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cost_optional_card')), findsNothing);

    await tester.tap(find.byKey(ValueKey('furnished_${laser.id}')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('cost_optional_${laser.id}')));
    await tester.pumpAndSettle();
    expect(p.avCost.optionalLines, {laser.id});

    final card = find.byKey(const ValueKey('cost_optional_card'));
    expect(card, findsOneWidget);
    expect(find.byKey(ValueKey('cost_optional_row_${laser.id}')),
        findsOneWidget);
    // Its maker and part number, while it is still left out of the total.
    expect(p.avCost.includeOptional, isFalse);
    final details = find.byKey(ValueKey('cost_optional_details_${laser.id}'));
    expect(tester.widget<Text>(details).data, contains('Epson'));
    expect(tester.widget<Text>(details).data, contains('Part V11HA25020'));
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('cost_optional_with')),
            matching: find.text(r'$1,500.00')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('cost_optional_without')),
            matching: find.text(r'$1,000.00')),
        findsOneWidget);

    expect(find.byKey(const ValueKey('cost_optional_section')), findsNothing,
        reason: 'one switch only');
    await tester.ensureVisible(
        find.byKey(const ValueKey('cost_optional_include')));
    await tester.tap(find.byKey(const ValueKey('cost_optional_include')));
    await tester.pumpAndSettle();
    expect(p.avCost.includeOptional, isTrue);
    expect(p.roomCost.grandTotal, 1500);
    expect(find.byKey(ValueKey('cost_optional_row_${laser.id}')), findsNothing,
        reason: 'counted, it is listed with the parts');
  });

  test('a drawn line can be optional, and purging takes its boxes off', () {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(const AvNode(
        id: 'CAM1', label: 'Camera', model: 'Cam570', pos: Offset.zero,
        ports: []));
    p.addAvNode(const AvNode(
        id: 'DISP1', label: 'Display', model: 'Display X', pos: Offset.zero,
        ports: []));
    final key = p.roomCost.equipment
        .firstWhere((l) => l.model == 'Cam570')
        .key;
    p.setAvCostOptional(key, true);
    expect(p.roomCost.optional.single.key, key);
    expect(p.roomCost.equipment.map((l) => l.model), ['Display X']);

    expect(p.purgeAvCostOptional(), 1);
    expect(p.avNodes.map((n) => n.id), ['DISP1']);
    expect(p.avCost.optionalLines, isEmpty);
  });

  testWidgets('an Other items line has the Optional tick too',
      (tester) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final mount = p.addAvCostItem(description: 'Mount', unitPrice: 300);
    await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
      value: p,
      child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey('furnished_${mount.id}')));
    await tester.tap(find.byKey(ValueKey('furnished_${mount.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('cost_optional_${mount.id}')));
    await tester.pumpAndSettle();
    expect(p.avCost.optionalLines, {mount.id});
    expect(p.roomCost.optional.single.key, mount.id);
  });

  test('labor can be optional: apart, in the totals, and purged', () {
    final s = room()
      ..labor.add(const LaborLine(id: 'LABOR_1', customRate: 100, hours: 4))
      ..optionalLines.add('LABOR_1');
    var e = price(s);
    expect(e.labor, isEmpty);
    expect(e.optionalLabor.single.id, 'LABOR_1');
    expect(e.optionalTotal, 900);
    expect(e.grandWithoutOptions, 1100);
    expect(e.grandWithOptions, 2050);
    e = price(s..includeOptional = true);
    expect(e.grandTotal, 2050);
    expect(e.laborTotal, 400, reason: 'counted, so listed with the labor');
    expect(e.optionalLabor, isEmpty);

    final p = AppStateProvider(autoLoadSettings: false);
    p.avCost.labor.add(const LaborLine(id: 'LABOR_1', hours: 2));
    p.setAvCostOptional('LABOR_1', true);
    expect(p.purgeAvCostOptional(), 1);
    expect(p.avCost.labor, isEmpty);
  });

  test('the project counts options as it says, room by room', () {
    final ref = const ProjectRoomRef(
      id: 'room1',
      configPath: 'a.json',
      optionalOff: true,
    );
    expect(ProjectRoomRef.fromJson(ref.toJson()).optionalOff, isTrue);
    final project = BuildingProject(includeOptional: true);
    expect(
      BuildingProject.fromJson(project.toJson()).includeOptional,
      isTrue,
    );
  });
}
