import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/report_tools.dart';

/// The room estimate: quantities come off the AV diagram, prices off the
/// catalog (or the room's own override), fees are percentages of the pre-tax
/// subtotal, and tax lands only on the taxable part. The numbers here are the
/// ones that end up on a quote, so each rule gets its own check.
void main() {
  AvNode device(String id, String label, String model, {double watts = 0}) =>
      AvNode(
        id: id,
        label: label,
        model: model,
        pos: Offset.zero,
        powerWatts: watts,
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

  /// A catalog with two priced models and nothing else, so the built-ins
  /// can't quietly supply a price the test didn't ask for.
  AvDeviceLibrary catalog() {
    final library = AvDeviceLibrary.empty();
    library.upsert(
      const AvDeviceTemplate(
        model: 'Display X',
        price: 1000,
        powerWatts: 150,
        ports: [],
      ),
    );
    library.upsert(
      const AvDeviceTemplate(
        model: 'Switcher Y',
        price: 2500,
        rackUnits: 2,
        powerWatts: 90,
        ports: [],
      ),
    );
    return library;
  }

  ReportSection sectionNamed(List<ReportSection> all, String title) =>
      all.firstWhere((s) => s.title == title);

  group('the estimate', () {
    test('quantities come from the diagram and prices from the catalog', () {
      final p = room();
      p.addAvNode(device('D1', 'Display 1', 'Display X'));
      p.addAvNode(device('D2', 'Display 2', 'Display X'));
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y'));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );

      // Two identical displays are ONE line of quantity 2 — the same grouping
      // the pack list uses.
      expect(estimate.equipment.length, 2);
      final displays = estimate.equipment.firstWhere(
        (l) => l.model == 'Display X',
      );
      expect(displays.qty, 2);
      expect(displays.unitPrice, 1000);
      expect(displays.total, 2000);
      expect(displays.source, PriceSource.catalog);

      expect(estimate.equipmentTotal, 4500);
      expect(estimate.grandTotal, 4500);
      expect(estimate.isComplete, isTrue);
    });

    test('a room price overrides the catalog and says so', () {
      final p = room();
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y'));
      p.setAvCostPrice('model:switcher y', 1900);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(estimate.equipment.single.unitPrice, 1900);
      expect(estimate.equipment.single.source, PriceSource.override);

      // Clearing it falls back to the catalog rather than to zero.
      p.setAvCostPrice('model:switcher y', null);
      final back = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(back.equipment.single.unitPrice, 2500);
      expect(back.equipment.single.source, PriceSource.catalog);
    });

    test('devices nobody priced are counted, not silently treated as free', () {
      final p = room();
      p.addAvNode(device('D1', 'Display', 'Display X'));
      p.addAvNode(device('X1', 'Mystery box', 'Not In Catalog'));
      p.addAvNode(device('X2', 'Mystery box 2', 'Not In Catalog'));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(estimate.isComplete, isFalse);
      expect(estimate.unpricedLines, 1);
      expect(estimate.unpricedDevices, 2);
      expect(estimate.grandTotal, 1000);
    });

    test('every fee is a percentage of the same pre-tax subtotal', () {
      final p = room();
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y')); // 2500
      p.addAvCostFee(name: 'Freight', percent: 4);
      p.addAvCostFee(name: 'Install', percent: 10);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );

      // 100 and 250 — NOT 4% then 10% of the grown total, which would
      // compound one fee onto the other.
      expect(estimate.fees.map((f) => f.amount), [100, 250]);
      expect(estimate.feeTotal, 350);
      expect(estimate.grandTotal, 2850);
    });

    test('other items join the subtotal that fees are worked out on', () {
      final p = room();
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y')); // 2500
      p.addAvCostItem(description: 'Cable', qty: 5, unitPrice: 100); // 500
      p.addAvCostFee(name: 'Contingency', percent: 10);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(estimate.subtotal, 3000);
      expect(estimate.fees.single.amount, 300);
    });

    test('tax lands on equipment plus only the taxable items and fees', () {
      final p = room();
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y')); // 2500
      final labor = p.addAvCostItem(
        description: 'Labor',
        qty: 10,
        unitPrice: 100,
      ); // 1000
      p.updateAvCostItem(labor.copyWith(taxable: false));
      final freight = p.addAvCostFee(name: 'Freight', percent: 10); // 350
      final overhead = p.addAvCostFee(name: 'Overhead', percent: 10); // 350
      p.updateAvCostFee(overhead.copyWith(taxable: false));
      p.setAvCostTax(percent: 10);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );

      expect(estimate.subtotal, 3500);
      expect(estimate.feeTotal, 700);
      // 2500 equipment + 350 taxable freight; the untaxed labor and the
      // untaxed overhead fee stay out of the base.
      expect(estimate.taxableBase, 2850);
      expect(estimate.tax, 285);
      expect(estimate.grandTotal, 4485);
      expect(freight.taxable, isTrue);
    });

    test('the totals section names each fee and its rate', () {
      final p = room();
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y'));
      p.addAvCostFee(name: 'Freight', percent: 4.5);
      p.setAvCostTax(percent: 8.25, label: 'State tax');

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      final totals = sectionNamed(costReportSections(estimate), 'Totals');
      final labels = totals.rows.map((r) => r[0].toString()).toList();

      expect(labels.any((l) => l.contains('Freight (4.5% of subtotal)')), isTrue);
      expect(labels.any((l) => l.contains('State tax (8.25%)')), isTrue);
      expect(labels.last, contains('TOTAL'));
    });
  });

  /// Not everything on a quote is on the drawing. A line added on the Cost tab
  /// has to land in the EQUIPMENT total — not in "Other items", where nobody
  /// checking what the gear costs would ever see it.
  group('equipment added by hand', () {
    test('a plain line prices off the figure typed on it', () {
      final p = room();
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y')); // 2500
      final line = p.addAvCostExtraEquipment(
        description: 'Owner-furnished display',
        qty: 2,
      );
      p.setAvCostPrice(line.id, 1200);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );

      final added = estimate.equipment.firstWhere((l) => l.key == line.id);
      expect(added.description, 'Owner-furnished display');
      expect(added.qty, 2);
      expect(added.unitPrice, 1200);
      expect(added.source, PriceSource.override);
      // In the equipment total, and nowhere near "Other items".
      expect(estimate.equipmentTotal, 4900);
      expect(estimate.extras, isEmpty);
      expect(estimate.grandTotal, 4900);
    });

    test('a line off the catalog follows a price revision', () {
      final p = room();
      p.addAvCostExtraEquipment(
        catalogModel: 'Switcher Y',
        description: 'Spare switcher',
      );

      expect(
        computeRoomCost(
          model: buildAvFlowModel(p),
          library: catalog(),
          settings: p.avCost,
        ).equipmentTotal,
        2500,
      );

      final revised = catalog()
        ..upsert(
          const AvDeviceTemplate(model: 'Switcher Y', price: 2700, ports: []),
        );
      final after = computeRoomCost(
        model: buildAvFlowModel(p),
        library: revised,
        settings: p.avCost,
      );
      expect(after.equipmentTotal, 2700);
      expect(after.equipment.single.source, PriceSource.catalog);
    });

    test('a line with no price anywhere is reported, not costed at zero', () {
      final p = room();
      p.addAvCostExtraEquipment(description: 'Something nobody priced', qty: 3);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(estimate.isComplete, isFalse);
      expect(estimate.unpricedLines, 1);
      expect(estimate.unpricedDevices, 3);
      expect(estimate.grandTotal, 0);
    });

    test('survives a round trip through the AV sidecar', () async {
      final p = room();
      final line = p.addAvCostExtraEquipment(description: 'Loaner camera');
      p.setAvCostPrice(line.id, 800);

      final back = RoomCostSettings()..readJson(p.avCost.toJson());
      expect(back.extraEquipment.single.description, 'Loaner camera');
      expect(back.priceOverrides[line.id], 800);
    });

    test('removing a line takes its room price with it', () {
      final p = room();
      final line = p.addAvCostExtraEquipment(description: 'Loaner camera');
      p.setAvCostPrice(line.id, 800);
      p.removeAvCostExtraEquipment(line.id);

      expect(p.avCost.extraEquipment, isEmpty);
      expect(p.avCost.priceOverrides, isEmpty);
    });
  });

  /// Not everything on the drawing is being bought. An existing display, an
  /// owner-furnished codec, the building's network switch: all of them have to
  /// be drawn, because the signal goes through them, and none of them belongs
  /// on the quote.
  group('devices marked not on the cost estimate', () {
    test('are left off the total and reported', () {
      final p = room();
      p.addAvNode(device('D1', 'New display', 'Display X'));
      p.addAvNode(device('S1', 'Existing switcher', 'Switcher Y'));
      p.updateAvNode(
        p.avNodeById('S1')!.copyWith(excludeFromCost: true),
      );

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );

      expect(estimate.equipment.single.model, 'Display X');
      expect(estimate.equipmentTotal, 1000);
      expect(estimate.grandTotal, 1000);
      // Short on purpose is still short — the estimate says so rather than
      // leaving the next reader hunting for the missing switcher.
      expect(estimate.excludedLines, 1);
      expect(estimate.excludedDevices, 1);
      // And it is not counted as a hole in the pricing, which is a different
      // problem with a different fix.
      expect(estimate.unpricedLines, 0);
      expect(estimate.isComplete, isTrue);
    });

    test('one of two identical models does not drag the other off', () {
      final p = room();
      p.addAvNode(device('D1', 'Existing display', 'Display X'));
      p.addAvNode(device('D2', 'New display', 'Display X'));
      p.updateAvNode(
        p.avNodeById('D1')!.copyWith(excludeFromCost: true),
      );

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );

      // Two of a model where one is bought and one is not are two lines, not
      // one of quantity two.
      expect(estimate.equipment.single.qty, 1);
      expect(estimate.equipmentTotal, 1000);
      expect(estimate.excludedDevices, 1);
    });

    test('the room still owns its power, heat and rack space', () {
      final p = room();
      p.addAvNode(device('S1', 'Existing switcher', 'Switcher Y', watts: 90));
      p.updateAvNode(
        p.avNodeById('S1')!.copyWith(excludeFromCost: true, rackUnits: 2),
      );

      // Whoever paid for it, it draws current and takes two rails.
      final node = p.avNodeById('S1')!;
      expect(node.powerWatts, 90);
      expect(node.rackUnits, 2);
      expect(p.avNodes.where((n) => n.rackUnits > 0).length, 1);
    });

    test('the flag survives a round trip through the sidecar', () {
      final p = room();
      p.addAvNode(device('S1', 'Existing switcher', 'Switcher Y'));
      p.updateAvNode(
        p.avNodeById('S1')!.copyWith(excludeFromCost: true),
      );

      final back = AvNode.fromJson(p.avNodeById('S1')!.toJson());
      expect(back.excludeFromCost, isTrue);
      // Absent in every file written before this existed, and the default has
      // to be "quote it" so an old room's total does not change.
      expect(
        AvNode.fromJson({'id': 'X', 'label': 'X'}).excludeFromCost,
        isFalse,
      );
      // withId rebuilds the node field by field; a new field dropped there is
      // silently lost on the way into the room.
      expect(p.avNodeById('S1')!.withId('S2').excludeFromCost, isTrue);
    });

    test('the totals sheet names them', () {
      final p = room();
      p.addAvNode(device('D1', 'New display', 'Display X'));
      p.addAvNode(device('S1', 'Existing switcher', 'Switcher Y'));
      p.updateAvNode(p.avNodeById('S1')!.copyWith(excludeFromCost: true));

      final totals = sectionNamed(
        costReportSections(
          computeRoomCost(
            model: buildAvFlowModel(p),
            library: catalog(),
            settings: p.avCost,
          ),
        ),
        'Totals',
      );
      expect(
        totals.rows.any((r) => r[0].toString().startsWith('Not quoted')),
        isTrue,
      );
    });
  });

  /// The base-cost card is the last rung the estimate falls back to, and it
  /// carries both published prices for the same reason the catalog does: an
  /// early budget still gets quoted at one tier or the other.
  group('base costs at each tier', () {
    AppStateProvider roomWithUnmodeledSwitcher() {
      final p = room();
      p.addAvNode(
        AvNode(
          id: 'SWITCHERDEVICE_1',
          label: 'Main switcher',
          model: '',
          pos: Offset.zero,
          ports: const [],
        ),
      );
      return p;
    }

    BaseCostBook card({double msrp = 0, double edu = 0}) =>
        BaseCostBook(costs: [
          BaseCost(category: 'Switcher', price: msrp, educationPrice: edu),
        ]);

    test('each tier costs off its own figure', () {
      final p = roomWithUnmodeledSwitcher();
      final book = card(msrp: 3000, edu: 2100);

      final list = computeRoomCost(
        model: buildAvFlowModel(p),
        library: AvDeviceLibrary.empty(),
        settings: p.avCost,
        baseCosts: book,
      );
      expect(list.equipment.single.unitPrice, 3000);
      expect(list.equipment.single.source, PriceSource.baseCost);
      expect(list.otherTierLines, 0);

      final edu = computeRoomCost(
        model: buildAvFlowModel(p),
        library: AvDeviceLibrary.empty(),
        settings: p.avCost,
        baseCosts: book,
        tier: PricingTier.education,
      );
      expect(edu.equipment.single.unitPrice, 2100);
      expect(edu.isBudgetary, isTrue);
    });

    test('a card priced at one tier only falls back and says so', () {
      final p = roomWithUnmodeledSwitcher();
      final edu = computeRoomCost(
        model: buildAvFlowModel(p),
        library: AvDeviceLibrary.empty(),
        settings: p.avCost,
        baseCosts: card(msrp: 3000),
        tier: PricingTier.education,
      );
      expect(edu.equipment.single.unitPrice, 3000);
      expect(edu.equipment.single.source, PriceSource.baseCost);
      // Worth a look before it goes on a quote: it is a list figure on an
      // education job.
      expect(edu.otherTierLines, 1);
    });

    test('a category with neither tier set is unpriced, not free', () {
      final p = roomWithUnmodeledSwitcher();
      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: AvDeviceLibrary.empty(),
        settings: p.avCost,
        baseCosts: card(),
      );
      expect(estimate.equipment.single.source, PriceSource.none);
      expect(estimate.unpricedLines, 1);
      expect(card().costs.single.isSet, isFalse);
      expect(card(edu: 2100).costs.single.isSet, isTrue);
    });

    test('both tiers round trip through the card file', () {
      const cost = BaseCost(
        category: 'Camera',
        price: 4000,
        educationPrice: 2800,
      );
      final back = BaseCost.fromJson(cost.toJson());
      expect(back.price, 4000);
      expect(back.educationPrice, 2800);
      // 'eduPrice' is what a hand-written card tends to say.
      expect(
        BaseCost.fromJson({'category': 'Camera', 'eduPrice': 2800})
            .educationPrice,
        2800,
      );
    });
  });

  group('money formatting', () {
    test('separates thousands and always shows cents', () {
      expect(formatMoney(0), r'$0.00');
      expect(formatMoney(1234.5), r'$1,234.50');
      expect(formatMoney(1234567.891), r'$1,234,567.89');
      expect(formatMoney(1500, '£'), '£1,500.00');
    });

    test('percentages and field values lose their trailing zeros', () {
      expect(formatPercent(8.25), '8.25%');
      expect(formatPercent(3), '3%');
      expect(trimNumber(90), '90');
      expect(trimNumber(12.5), '12.5');
    });
  });

  group('the power estimate', () {
    test('totals the recorded watts and counts what is missing', () {
      final p = room();
      p.addAvNode(device('D1', 'Display', 'Display X', watts: 150));
      p.addAvNode(device('S1', 'Switcher', 'Switcher Y', watts: 90));
      p.addAvNode(device('X1', 'Unmetered box', 'Mystery'));

      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Estimate',
      );
      Object? valueFor(String item) => power.rows
          .firstWhere((r) => r[0].toString().startsWith(item))[1];

      expect(valueFor('Estimated total draw'), 240);
      expect(valueFor('Estimated current @ 120 V'), '2.0');
      // 240 W x 3.412
      expect(valueFor('Heat load'), 819);
      expect(
        valueFor('Devices with no power figure').toString(),
        startsWith('1'),
      );
    });

    test('a device on PoE is left out of the mains current', () {
      final p = room();
      p.addAvNode(
        device('C1', 'Camera', 'Cam', watts: 12).copyWith(
          powerSource: PowerSource.poe,
        ),
      );
      p.addAvNode(
        device('S1', 'Switcher', 'Switcher Y', watts: 90).copyWith(
          powerSource: PowerSource.wall,
        ),
      );

      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Estimate',
      );
      Object? valueFor(String item) => power.rows
          .firstWhere((r) => r[0].toString().startsWith(item))[1];

      expect(valueFor('Estimated total draw'), 102);
      expect(valueFor('Mains-fed draw'), 90);
    });
  });

  /// A cost-only document gets signed off without anybody opening the AV
  /// report, so the devices the control system cannot drive have to be on it.
  group('the warning that travels with a cost-only report', () {
    test('an undriven device is named under the money', () {
      final p = room();
      // A model no Python module claims, added by hand.
      p.addAvNode(device('P1', 'Projector', 'Some Projector 9000'));
      final model = buildAvFlowModel(p);
      final estimate = computeRoomCost(
        model: model,
        library: catalog(),
        settings: p.avCost,
      );

      final gaps = driverGapSections(p, model);
      final section = sectionNamed(gaps, 'Devices Without a Control Module');
      expect(section.rows.single[1], 'Some Projector 9000');

      // The estimate itself is unchanged; the warning rides after it, which is
      // exactly how every cost export assembles the document.
      final document = [...costReportSections(estimate), ...gaps];
      expect(
        document.map((s) => s.title),
        containsAllInOrder(['Totals', 'Devices Without a Control Module']),
      );
    });

    test('a fully driven room grows no warning at all', () {
      final p = room();
      final model = buildAvFlowModel(p);
      expect(driverGapSections(p, model), isEmpty);
    });
  });

  group('what is on the rails', () {
    /// A rack item added straight to the provider, placed or not — the estimate
    /// prices it either way.
    RackItem part(String label, String category, {double price = 0}) =>
        RackItem(id: '', label: label, category: category, price: price);

    test('a plate is hardware and a switch racked beside it is equipment', () {
      final p = room();
      p.addAvRackItem(part('2U vent plate', 'Vent plate', price: 40));
      p.addAvRackItem(part('Cisco C9300-24P', 'Network switch'));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
        baseCosts: BaseCostBook(),
      );

      expect(
        estimate.hardware.map((l) => l.description),
        ['2U vent plate'],
      );
      expect(
        estimate.equipment.map((l) => l.description),
        contains('Cisco C9300-24P'),
      );
    });

    test('a box with no price is reported as needing one', () {
      final p = room();
      p.addAvRackItem(part('Cisco C9300-24P', 'Network switch'));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
        baseCosts: BaseCostBook(),
      );

      final line = estimate.equipment
          .firstWhere((l) => l.description == 'Cisco C9300-24P');
      expect(line.source, PriceSource.none);
      expect(estimate.isComplete, isFalse);
      expect(estimate.unpricedDevices, greaterThan(0));

      // ...and a price typed on the line is the whole fix.
      p.setAvCostPrice(line.key, 4200);
      final priced = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
        baseCosts: BaseCostBook(),
      );
      expect(priced.isComplete, isTrue);
      expect(
        priced.equipment
            .firstWhere((l) => l.description == 'Cisco C9300-24P')
            .unitPrice,
        4200,
      );
    });

    test('an item written before there were kinds is still hardware', () {
      final p = room();
      p.addAvRackItem(part('Blank plate', ''));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
        baseCosts: BaseCostBook(),
      );

      expect(estimate.hardware.single.description, 'Blank plate');
      expect(estimate.equipment, isEmpty);
    });
  });

  test('the cost estimate round-trips through the AV flow sidecar', () {
    final p = room();
    p.setAvCostTax(percent: 8.25, label: 'State tax', currency: r'$');
    p.addAvCostFee(name: 'Freight', percent: 4);
    p.addAvCostItem(description: 'Labor', qty: 8, unitPrice: 95);
    p.setAvCostPrice('model:switcher y', 1900);

    final json = p.avCost.toJson();
    final restored = RoomCostSettings()..readJson(json);

    expect(restored.taxPercent, 8.25);
    expect(restored.taxLabel, 'State tax');
    expect(restored.fees.single.name, 'Freight');
    expect(restored.fees.single.percent, 4);
    expect(restored.items.single.qty, 8);
    expect(restored.priceOverrides['model:switcher y'], 1900);
  });
}
