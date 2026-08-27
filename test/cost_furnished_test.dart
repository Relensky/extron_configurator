import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/report_tools.dart';

/// FURNISHED FROM SOMEWHERE ELSE.
///
/// Not everything in a room is bought on the job that installs it: the network
/// department pulls the cat6, a display comes out of campus stock, the owner
/// hands over a codec. Deleting those lines was the only way to keep them off
/// the total, and it took them off the pack list, the cable schedule and the
/// replacement plan as well — so the room's own documents stopped describing
/// the room.
///
/// The line stays. It carries its quantity and its price, it adds nothing to
/// this quote, and it says who is providing it.
void main() {
  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  AvDeviceLibrary catalog() {
    final library = AvDeviceLibrary.empty();
    library.upsert(
      const AvDeviceTemplate(model: 'Display X', price: 1000, ports: []),
    );
    library.upsert(
      const AvDeviceTemplate(model: 'Switcher Y', price: 2500, ports: []),
    );
    return library;
  }

  CostEstimate estimateOf(AppStateProvider p) => computeRoomCost(
    model: buildAvFlowModel(p),
    library: catalog(),
    settings: p.avCost,
    baseCosts: p.baseCosts,
  );

  group('equipment somebody else is furnishing', () {
    test('is listed at its price and adds nothing to the total', () {
      final p = room();
      p.addAvNode(device('D1', 'Display', 'Display X'));
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y'));

      expect(estimateOf(p).grandTotal, 3500);

      p.setAvCostFurnished('model:display x', 'stock');
      final after = estimateOf(p);
      final display = after.equipment.firstWhere(
        (l) => l.model == 'Display X',
      );

      // Still on the quote, still a display, still worth a thousand dollars.
      expect(display.qty, 1);
      expect(display.unitPrice, 1000);
      expect(display.listTotal, 1000);
      // And costing this job nothing.
      expect(display.total, 0);
      expect(display.furnished, isTrue);
      expect(after.equipmentTotal, 2500);
      expect(after.grandTotal, 2500);
    });

    test('does not drag fees or tax up with it', () {
      final p = room();
      p.addAvNode(device('D1', 'Display', 'Display X'));
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y'));
      p.addAvCostFee(name: 'Freight', percent: 10);
      p.setAvCostTax(percent: 10, label: 'Tax');

      p.setAvCostFurnished('model:display x', 'the owner');
      final after = estimateOf(p);

      // 2500 of equipment, 250 of freight on top of it, and tax on both.
      expect(after.subtotal, 2500);
      expect(after.feeTotal, 250);
      expect(after.tax, 275);
      expect(after.grandTotal, 3025);
    });

    test('is not reported as an unpriced hole in the quote', () {
      final p = room();
      // A box with no price anywhere. Normally that is money missing from the
      // quote and the page says so; furnished, it is a decision.
      p.addAvNode(device('X1', 'Owner codec', 'Nothing In The Catalog'));

      expect(estimateOf(p).unpricedLines, 1);

      p.setAvCostFurnished('model:nothing in the catalog', 'the owner');
      final after = estimateOf(p);
      expect(after.unpricedLines, 0);
      expect(after.isComplete, isTrue);
    });

    test('says who is furnishing it, on the page and in the report', () {
      final p = room();
      p.addAvNode(device('D1', 'Display', 'Display X'));

      p.setAvCostFurnished('model:display x', 'Campus IT');
      final line = estimateOf(p).equipment.single;
      expect(priceFromLabel(line), 'Furnished by Campus IT');
      expect(furnishedNote(line), 'furnished by Campus IT');

      // Nobody named is still an answer.
      p.setAvCostFurnished('model:display x', '');
      final anon = estimateOf(p).equipment.single;
      expect(priceFromLabel(anon), 'Furnished by others');

      // And it reaches the exported quote, where the money column reads zero
      // and the reason has to be beside it.
      final sections = costReportSections(estimateOf(p));
      final equipment = sections.firstWhere((s) => s.title == 'Equipment');
      expect(equipment.rows.single.last, 'Furnished by others');
    });

    test('goes back on the quote when it is cleared', () {
      final p = room();
      p.addAvNode(device('D1', 'Display', 'Display X'));
      p.setAvCostFurnished('model:display x', 'stock');
      expect(estimateOf(p).grandTotal, 0);

      p.setAvCostFurnished('model:display x', null);
      expect(estimateOf(p).grandTotal, 1000);
      expect(estimateOf(p).equipment.single.furnished, isFalse);
    });

    test('survives being written out and read back', () {
      final p = room();
      p.setAvCostFurnished('model:display x', 'Campus IT');
      // '' is a real answer - "by others" - and must not read back as absent.
      p.setAvCostFurnished('cable:network', '');

      final written = jsonDecode(jsonEncode(p.avCost.toJson()));
      final read = RoomCostSettings()
        ..readJson(Map<String, dynamic>.from(written as Map));

      expect(read.furnishedLines['model:display x'], 'Campus IT');
      expect(read.furnishedLines.containsKey('cable:network'), isTrue);
      expect(read.furnishedLines['cable:network'], '');
    });
  });

  group('cable somebody else is pulling', () {
    test('keeps its runs on the schedule and leaves the total alone', () {
      final p = room();
      final a = p.addAvNode(device('A', 'Box A', ''));
      final b = p.addAvNode(device('B', 'Box B', ''));
      p.avNodes[0] = a.copyWith(
        ports: const [
          AvPort(
            id: 'out_1',
            label: 'OUT',
            signal: SignalType.network,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
        ],
      );
      p.avNodes[1] = b.copyWith(
        ports: const [
          AvPort(
            id: 'in_1',
            label: 'IN',
            signal: SignalType.network,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
        ],
      );
      p.addAvCable(
        fromNodeId: a.id,
        fromPortId: 'out_1',
        toNodeId: b.id,
        toPortId: 'in_1',
        signal: SignalType.network,
      );
      // A shop price for the run, so there is money to take off.
      p.baseCosts.upsert(
        BaseCost(category: cableBaseCategory('Network', 0), price: 60),
      );

      final priced = estimateOf(p);
      final key = priced.cabling.single.key;
      expect(priced.cablingTotal, greaterThan(0));

      p.setAvCostFurnished(key, 'another department');
      final after = estimateOf(p);
      final cable = after.cabling.single;

      // The run is still counted and still priced per lead — the cable
      // schedule and the pack list are about the room, not about the invoice.
      expect(cable.qty, 1);
      expect(cable.unitPrice, greaterThan(0));
      expect(cable.total, 0);
      expect(after.cablingTotal, 0);
      expect(priceFromLabel(cable), 'Furnished by another department');
    });
  });

  group('the replacement plan', () {
    test('still carries a furnished device, with the cost of the next one',
        () {
      final p = room();
      p.addAvNode(device('D1', 'Display', 'Display X'));
      p.setAvCostFurnished('model:display x', 'the owner');

      // The lifecycle plan is built from the ROOM, not from the invoice: a
      // display the campus handed over still dies on schedule and still has
      // to be replaced by somebody, so it keeps its replacement figure.
      final plan = buildRoomLifecycle(
        model: buildAvFlowModel(p),
        library: catalog(),
        baseCosts: p.baseCosts,
      );
      final item = plan.items.single;
      expect(item.node.label, 'Display');
      expect(item.replacementCost, 1000);

    });
  });

  group('driven through the page', () {
    testWidgets('the row button takes the line off the total and says so',
        (tester) async {
      tester.view.physicalSize = const Size(1700, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = room()..avDeviceLibrary = catalog();
      p.addAvNode(device('D1', 'Display', 'Display X'));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'$1,000.00'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey('furnished_model:display x')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Used from stock'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(p.avCostFurnishedBy('model:display x'), 'stock');
      // The row says it rather than showing a bare zero.
      expect(find.text('furnished'), findsOneWidget);
      expect(find.text('Furnished by stock'), findsOneWidget);
    });
  });
}
