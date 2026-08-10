import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart';
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
      final labour = p.addAvCostItem(
        description: 'Labour',
        qty: 10,
        unitPrice: 100,
      ); // 1000
      p.updateAvCostItem(labour.copyWith(taxable: false));
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
      // 2500 equipment + 350 taxable freight; the untaxed labour and the
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

  test('the cost estimate round-trips through the AV flow sidecar', () {
    final p = room();
    p.setAvCostTax(percent: 8.25, label: 'State tax', currency: r'$');
    p.addAvCostFee(name: 'Freight', percent: 4);
    p.addAvCostItem(description: 'Labour', qty: 8, unitPrice: 95);
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
