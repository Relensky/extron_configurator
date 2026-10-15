import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_compare.dart';
import 'package:extron_configurator/cost_compare_view.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// Comparing two rooms' costs, copying cost items between rooms, and cost
/// presets on the Root Folder.
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

  CostLineItem part(
    String id,
    String name, {
    String pn = '',
    double qty = 1,
    double price = 0,
  }) =>
      CostLineItem(
        id: id,
        description: name,
        manufacturer: 'Extron',
        partNumber: pn,
        qty: qty,
        unitPrice: price,
      );

  CostEstimate priced(RoomCostSettings s) => computeRoomCost(
        model: empty,
        library: AvDeviceLibrary.empty(),
        settings: s,
      );

  group('compareRoomCosts', () {
    test('matches by part number and says how each part differs', () {
      final arts111 = RoomCostSettings()
        ..extraEquipment.addAll([
          part('EQP_1', 'DTP HDMI 4K 330 Tx', pn: '60-1331-12', price: 760),
          part('EQP_2', 'Switcher', pn: '60-1', qty: 1, price: 2000),
          part('EQP_3', 'Same box', pn: '60-9', price: 100),
          part('EQP_4', 'Only here', pn: '60-5', price: 50),
        ]);
      final arts112 = RoomCostSettings()
        ..extraEquipment.addAll([
          // Named differently, same part number: the same part.
          part('EQP_9', 'DTP Tx', pn: '60 1331 12', price: 700),
          part('EQP_8', 'Switcher', pn: '60-1', qty: 2, price: 2000),
          part('EQP_7', 'Same box', pn: '60-9', price: 100),
          part('EQP_6', 'Only there', pn: '60-6', price: 25),
        ]);

      final c = compareRoomCosts(priced(arts111), priced(arts112));
      CostDiffRow row(String pn) =>
          c.rows.singleWhere((r) => r.partNumber == pn);

      expect(row('60-1331-12').kind, CostDiffKind.price);
      expect(row('60-1331-12').unitHere, 760);
      expect(row('60-1331-12').unitThere, 700);
      expect(row('60-1').kind, CostDiffKind.qty);
      expect(row('60-1').totalDifference, -2000);
      expect(row('60-9').kind, CostDiffKind.same);
      expect(row('60-5').kind, CostDiffKind.onlyHere);
      expect(row('60-6').kind, CostDiffKind.onlyThere);
      expect(c.differences, hasLength(4));
      expect(c.grandHere - c.grandThere, 2910 - 4825);
    });
  });

  group('cost items', () {
    RoomCostSettings source() => RoomCostSettings()
      ..extraEquipment.add(part('EQP_1', 'Mount', price: 300))
      ..items.add(const CostLineItem(id: 'ITEM_2', description: 'Trip charge'))
      ..labor.add(const LaborLine(id: 'LABOR_3', rateId: 'tech', hours: 8))
      ..fees.add(const CostFee(id: 'FEE_4', name: 'Freight', percent: 3))
      ..priceOverrides['EQP_1'] = 275
      ..priceOverrides['some_drawn_device'] = 999
      ..equipmentSpares['EQP_1'] = 1;

    test('take only what is keyed to the items', () {
      final set = CostItemSet.fromSettings(source());
      expect(set.prices, {'EQP_1': 275});
      expect(set.spares, {'EQP_1': 1});
      expect(set.lineCount, 4);
    });

    test('survive JSON', () {
      final back = CostItemSet.fromJson(
          CostItemSet.fromSettings(source()).toJson());
      expect(back.extraEquipment.single.description, 'Mount');
      expect(back.labor.single.hours, 8);
      expect(back.fees.single.name, 'Freight');
      expect(back.prices, {'EQP_1': 275});
    });

    test('go on under fresh ids, prices following them, a fee not twice', () {
      final target = RoomCostSettings()
        ..extraEquipment.add(part('EQP_1', 'Already here'))
        ..fees.add(const CostFee(id: 'FEE_1', name: 'freight', percent: 5));
      var n = 10;
      final added = addCostItems(
        target,
        CostItemSet.fromSettings(source()),
        (prefix) => '$prefix${++n}',
      );
      expect(added, 3);
      expect(target.extraEquipment.map((i) => i.id), ['EQP_1', 'EQP_11']);
      expect(target.priceOverrides, {'EQP_11': 275});
      expect(target.equipmentSpares, {'EQP_11': 1});
      expect(target.fees, hasLength(1));
      expect(target.labor.single.id, isNot('LABOR_3'));
    });

    test('apply as one undo step', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Arts 111'},
        };
      p.loadAvFlowForCurrentConfig();
      final n = p.applyAvCostItems(CostItemSet.fromSettings(source()));
      expect(n, 4);
      expect(p.avCost.extraEquipment, hasLength(1));
      p.undoAvFlow(AvUndoScope.cost);
      expect(p.avCost.extraEquipment, isEmpty);
      expect(p.avCost.labor, isEmpty);
    });
  });

  test('a cost preset survives the Root Folder', () async {
    final root = await Directory.systemTemp.createTemp('cost_presets');
    addTearDown(() => root.delete(recursive: true));
    await saveCostPreset(
      root.path,
      CostPreset(
        name: 'Classroom: standard',
        description: 'Mount and a day of labor',
        items: CostItemSet.fromSettings(RoomCostSettings()
          ..extraEquipment.add(part('EQP_1', 'Mount', price: 300))),
      ),
    );
    final back = await loadCostPresets(root.path);
    expect(back.single.name, 'Classroom: standard');
    expect(back.single.items.extraEquipment.single.unitPrice, 300);
    expect(back.single.file, endsWith('Classroom_ standard.costpreset.json'));
  });

  group('copying between rooms', () {
    // Arts 111 has a projector drawn on its diagram; Arts 112 has none.
    AvFlowModel withProjector() => const AvFlowModel(
          nodes: [
            AvNode(
              id: 'AVNODE_1',
              label: 'Projector',
              model: 'EB-PU2010B',
              pos: Offset.zero,
              ports: [],
            ),
          ],
          cables: [],
          racks: [],
          rackSlots: {},
          canvasSize: Size(0, 0),
          roomTitle: '',
          unplaced: [],
        );
    AvDeviceLibrary library() => AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'EB-PU2010B',
        manufacturer: 'Epson',
        partNumber: 'V11HA94020',
        category: 'Projector',
        price: 6000,
        ports: [],
      ));

    test('a drawn projector copies as an added line, room price and all', () {
      final lib = library();
      final s111 = RoomCostSettings();
      final drawn = computeRoomCost(
          model: withProjector(), library: lib, settings: s111);
      s111.priceOverrides[drawn.equipment.single.key] = 5200;
      final e111 = computeRoomCost(
          model: withProjector(), library: lib, settings: s111);
      final s112 = RoomCostSettings();
      final e112 = computeRoomCost(model: empty, library: lib, settings: s112);

      final c = compareRoomCosts(e112, e111); // here = 112, there = 111
      final projector = c.rows.single;
      expect(projector.kind, CostDiffKind.onlyThere);

      final set =
          costItemsFromRows([projector], source: s111, fromThere: true);
      final item = set.extraEquipment.single;
      expect(item.catalogModel, 'EB-PU2010B');
      expect(item.partNumber, 'V11HA94020');
      expect(set.prices[item.id], 5200);

      addCostItems(s112, set, (p) => '${p}1');
      final after = computeRoomCost(model: empty, library: lib, settings: s112);
      expect(after.equipment.single.model, 'EB-PU2010B');
      expect(after.equipment.single.unitPrice, 5200);
    });

    test('what the target already has is skipped', () {
      final lib = library();
      final target = RoomCostSettings()
        ..fees.add(const CostFee(id: 'FEE_9', name: 'freight', percent: 5));
      final targetEstimate = computeRoomCost(
          model: withProjector(), library: lib, settings: target);
      final set = CostItemSet(
        extraEquipment: [
          // Same part number as the drawn projector, typed differently.
          part('EQP_1', 'Projector', pn: 'V11HA94020'),
          part('EQP_2', 'Screen', pn: 'SC-1'),
        ],
        labor: const [LaborLine(id: 'LABOR_1', rateId: 'tech', hours: 4)],
        fees: const [CostFee(id: 'FEE_1', name: 'Freight', percent: 3)],
      );
      final (kept, skipped) = withoutExisting(
        set,
        target: target,
        targetEstimate: targetEstimate,
      );
      expect(kept.extraEquipment.map((i) => i.description), ['Screen']);
      expect(kept.labor, hasLength(1));
      expect(kept.fees, isEmpty);
      expect(skipped, 2);
    });

    test('copying into a room that is not open writes its cost file',
        () async {
      final dir = await Directory.systemTemp.createTemp('copy_into');
      addTearDown(() => dir.delete(recursive: true));
      final config = '${dir.path}${Platform.pathSeparator}config.json';
      File(config).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': 'Arts 112'},
      }));
      final p = AppStateProvider(autoLoadSettings: false);
      final n = await p.addCostItemsToRoomFile(
        config,
        CostItemSet(extraEquipment: [part('EQP_5', 'Screen', price: 900)]),
      );
      expect(n, 1);
      final room = readRoomFromDisk(config);
      expect(room.settings.extraEquipment.single.description, 'Screen');
      expect(room.settings.extraEquipment.single.unitPrice, 900);
    });
  });

  group('the comparison dialog', () {
    Future<AppStateProvider> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Arts 111'},
        };
      p.loadAvFlowForCurrentConfig();
      p.avCost.extraEquipment.add(
          part('EQP_1', 'DTP HDMI 4K 330 Tx', pn: '60-1331-12', price: 11948));
      final there = RoomCostSettings()
        ..extraEquipment.addAll([
          part('EQP_2', 'DTP HDMI 4K 330 Tx', pn: '60-1331-12', price: 700),
          part('EQP_3', 'Ceiling speaker', pn: '42-1', qty: 4, price: 150),
          part('EQP_4', 'Mic', pn: '42-2', price: 90),
        ]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CostCompareDialog(
            provider: p,
            hereName: 'Arts 111',
            thereName: 'Arts 112',
            hereEstimate: priced(p.avCost),
            thereEstimate: priced(there),
            hereSettings: p.avCost,
            thereSettings: there,
            currency: r'$',
          ),
        ),
      ));
      return p;
    }

    testWidgets('shows each room\'s figures', (tester) async {
      await open(tester);
      expect(find.text('Arts 111 vs Arts 112'), findsOneWidget);
      expect(find.text(r'$11,948.00'), findsWidgets);
      expect(find.text(r'$700.00'), findsWidgets);
      expect(find.textContaining('Price differs'), findsOneWidget);
    });

    testWidgets('ticked parts copy in, with the new wording', (tester) async {
      final p = await open(tester);
      await tester.tap(find.byKey(
          const ValueKey('compare_pick_Equipment|Ceiling speaker|42-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('compare_copy')));
      await tester.pumpAndSettle();
      expect(find.text('Adding 1 item from the listed categories:'),
          findsOneWidget);
      expect(find.text('• 4 x Ceiling speaker'), findsOneWidget);
      expect(find.textContaining('without replacing any items'),
          findsOneWidget);
      expect(find.textContaining('Items that already exist are skipped'),
          findsOneWidget);
      expect(find.textContaining('Undo removes them'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('copy_items_go')));
      await tester.pumpAndSettle();
      expect(p.avCost.extraEquipment.map((i) => i.description),
          ['DTP HDMI 4K 330 Tx', 'Ceiling speaker']);
    });

    testWidgets('a part both rooms have cannot be ticked', (tester) async {
      await open(tester);
      expect(
        find.byKey(const ValueKey(
            'compare_pick_Equipment|DTP HDMI 4K 330 Tx|60-1331-12')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('compare_pick_all')));
      await tester.pump();
      expect(find.text('Copy 2 into Arts 111'), findsOneWidget);
    });

    testWidgets('copying the other way needs the other room\'s file',
        (tester) async {
      await open(tester);
      final button = tester.widget<SegmentedButton<CopyDirection>>(
          find.byKey(const ValueKey('compare_direction')));
      expect(button.segments.last.enabled, isFalse);
    });
  });
}
