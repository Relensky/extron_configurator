import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_compare.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/preset_library_panel.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_preset_save_dialog.dart';
import 'package:extron_configurator/room_presets.dart';

/// "Save Room as Preset" carries the whole room - AV flow, racks, floor plan
/// sheets, cabling sheet, cost page and control schematic - and a room made
/// from it gets all of it.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('whole_room_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Lets the panel's folder reads finish. They are real file reads, which
  /// the test clock does not advance, and its progress bar never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  AppStateProvider room(String name) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = root.path
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': name, 'gve_room': '111'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  /// Arts 111, built out: a projector, a sheet, a laid-out cabling box, a
  /// cost page with words, a line and a price, and a schematic block.
  AppStateProvider arts111() {
    final p = room('Arts 111');
    p.addAvNode(const AvNode(
      id: 'AVNODE_1',
      label: 'Projector',
      model: 'EB-PU2010B',
      pos: Offset(100, 100),
      ports: [],
    ));
    p.addAvFloorPlan(const FloorPlan(id: '', name: 'Level 1'));
    p.avCabling.positions['AVNODE_1'] = const Offset(40, 50);
    p.avCost.scopeOfWork = 'Replace the projector and screen.';
    p.addAvCostItem(description: 'Projector mount', unitPrice: 280);
    p.avCost.taxPercent = 7.25;
    p.schematicPositions['SWITCHERDEVICE_1'] = const Offset(10, 20);
    return p;
  }

  test('every part goes in, and survives the file', () {
    final preset = arts111().currentRoomAsPreset(
      name: 'Standard classroom',
      description: 'One projector',
      sourceName: '1 Projector',
      include: {...RoomPresetPart.values},
    );
    final back = RoomPreset.fromJson(preset.toJson());
    expect(back.nodes.single.model, 'EB-PU2010B');
    expect(back.floorPlans.single.name, 'Level 1');
    expect(back.cabling, isNotEmpty);
    expect(back.cost['scopeOfWork'], 'Replace the projector and screen.');
    expect(back.schematic, isNotEmpty);
    expect(back.sourceName, '1 Projector');
    expect(back.summary, contains('cost page'));
    expect(back.summary, contains('control schematic'));
  });

  test('a cost page saved without the AV flow keeps its drawn devices', () {
    final preset = arts111().currentRoomAsPreset(
      name: 'Money only',
      include: {RoomPresetPart.cost},
    );
    final page = RoomCostSettings()..readJson(preset.cost);
    expect(page.extraEquipment.map((i) => i.catalogModel),
        contains('EB-PU2010B'));
    expect(page.items.single.description, 'Projector mount');
    expect(page.scopeOfWork, 'Replace the projector and screen.');
  });

  test('a part left unticked stays out', () {
    final preset = arts111().currentRoomAsPreset(
      name: 'No money',
      include: {RoomPresetPart.flow},
    );
    expect(preset.nodes, hasLength(1));
    expect(preset.cost, isEmpty);
    expect(preset.schematic, isEmpty);
    expect(preset.floorPlans, isEmpty);
  });

  test('a new room made from it gets the whole room, and keeps its own tax',
      () {
    final preset = arts111().currentRoomAsPreset(
      name: 'Standard classroom',
      include: {...RoomPresetPart.values},
    );
    // Its own rate, which is the room's to keep.
    final arts112 = room('Arts 112');
    arts112.avCost
      ..ownTaxRate = true
      ..taxPercent = 8.5;
    arts112.applyRoomPreset(preset);

    expect(arts112.avNodes.single.model, 'EB-PU2010B');
    expect(arts112.avFloorPlans.single.name, 'Level 1');
    expect(arts112.avCabling.positions['AVNODE_1'], const Offset(40, 50));
    expect(arts112.avCost.scopeOfWork, 'Replace the projector and screen.');
    expect(arts112.avCost.items.single.description, 'Projector mount');
    expect(arts112.avCost.taxPercent, 8.5);
    expect(arts112.schematicPositions['SWITCHERDEVICE_1'],
        const Offset(10, 20));
  });

  test('into a room with its own cost page, lines and words are added', () {
    final preset = arts111().currentRoomAsPreset(
      name: 'Standard classroom',
      include: {...RoomPresetPart.values},
    );
    final other = room('Arts 112')..avCost.scopeOfWork = 'Our own words';
    other.applyRoomPreset(preset);
    expect(other.avCost.scopeOfWork,
        'Our own words\n\nReplace the projector and screen.');
    expect(other.avCost.items.single.description, 'Projector mount');
    // And the next line typed here cannot take the copied line's id.
    final next = other.addAvCostItem(description: 'Freight');
    expect(next.id, isNot(other.avCost.items.first.id));
    expect(highestCostId(other.avCost), isPositive);
  });

  testWidgets('the window names it, and its ticks decide what goes in',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = arts111();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSaveRoomPresetDialog(context, p),
            child: const Text('save'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    expect(find.text('Save Room as Preset'), findsOneWidget);
    // The estate sheet name and the jack prefix sit on one line.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('room_preset_jacks'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('room_preset_source'))).dy,
    );
    await tester.enterText(
        find.byKey(const ValueKey('room_preset_name')), 'Arts lecture');
    await tester.enterText(
        find.byKey(const ValueKey('room_preset_description')),
        'Projector, mount, one sheet');
    await tester.ensureVisible(
        find.byKey(const ValueKey('room_preset_part_cost')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room_preset_part_cost')));
    await tester.pump();
    expect(
      tester
          .widget<CheckboxListTile>(
              find.byKey(const ValueKey('room_preset_part_cost')))
          .value,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('room_preset_save')));
    await tester.pumpAndSettle();

    final saved = loadRoomPresets(root.path)
        .singleWhere((x) => x.name == 'Arts lecture');
    expect(saved.description, 'Projector, mount, one sheet');
    expect(saved.nodes, hasLength(1));
    expect(saved.cost, isEmpty);
    expect(saved.schematic, isNotEmpty);
  });

  testWidgets('App Config lists the presets and can delete one',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = arts111();
    saveRoomPreset(
      root.path,
      p.currentRoomAsPreset(name: 'Arts lecture', include: {
        ...RoomPresetPart.values,
      }),
    );
    // A real file write, so on the real clock.
    await tester.runAsync(() => saveCostPreset(
          root.path,
          CostPreset(
            name: 'Mount and labor',
            items: CostItemSet(items: [
              const CostLineItem(id: 'ITEM_1', description: 'Mount'),
            ]),
          ),
        ));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: PresetLibraryPanel(provider: p)),
      ),
    ));
    await settle(tester);
    expect(find.byKey(const ValueKey('preset_row_room_Arts lecture')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('preset_row_cost_Mount and labor')),
        findsOneWidget);

    await tester.ensureVisible(
        find.byKey(const ValueKey('preset_delete_room_Arts lecture')));
    await tester.pump();
    await tester.tap(
        find.byKey(const ValueKey('preset_delete_room_Arts lecture')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preset_delete_go')));
    await settle(tester);
    expect(loadRoomPresets(root.path).where((x) => x.name == 'Arts lecture'),
        isEmpty);
  });
}
