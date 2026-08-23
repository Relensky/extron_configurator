import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_workbook.dart';

/// Spares, rolled up from the rooms to the job.
///
/// A room says "spare" two different ways — a count against a device on the
/// diagram, and a whole line typed in for the shelf — and the failure this
/// guards is the job seeing one of them and not the other. A quote that reads
/// as having spares on it when half of them were not counted is worse than one
/// with none.
void main() {
  MasterPartLine line({
    required String description,
    double qty = 4,
    double spareQty = 0,
    Map<String, double> spareByRoom = const {},
    MasterPartKind kind = MasterPartKind.equipment,
    double unitPrice = 100,
  }) => MasterPartLine(
    key: masterPartKey(kind: kind.name, description: description),
    kind: kind,
    description: description,
    model: '',
    partNumber: '',
    manufacturer: '',
    category: '',
    qty: qty,
    total: qty * unitPrice,
    unitPrice: unitPrice,
    maxUnitPrice: unitPrice,
    qtyByRoom: const {},
    vendor: null,
    tagSource: VendorTagSource.none,
    unpriced: false,
    spareQty: spareQty,
    spareByRoom: spareByRoom,
  );

  ProjectEstimate estimateOf(List<MasterPartLine> master) => ProjectEstimate(
    project: BuildingProject(),
    currency: r'$',
    rooms: const [],
    costedRooms: const [],
    master: master,
    vendors: const [],
    grandTotal: 0,
    equipmentTotal: 0,
    hardwareTotal: 0,
    cablingTotal: 0,
    extrasTotal: 0,
    laborTotal: 0,
    laborHours: 0,
    feeTotal: 0,
    taxTotal: 0,
    failedRooms: 0,
    unpricedParts: 0,
    untaggedParts: 0,
    controlGaps: const [],
    mixedCurrency: false,
  );

  group('what a line says about its spares', () {
    test('the spare units are separated from the ones being installed', () {
      final l = line(description: 'Display', qty: 4, spareQty: 1);
      expect(l.hasSpares, isTrue);
      expect(l.spareQty, 1);
      // Three go into rooms; the fourth is money no drawing accounts for.
      expect(l.drawnQty, 3);
    });

    test('a part nobody spared says so', () {
      final l = line(description: 'Switcher');
      expect(l.hasSpares, isFalse);
      expect(l.spareQty, 0);
      expect(l.drawnQty, l.qty);
    });
  });

  group('both kinds of spare reach the job', () {
    test('a spares figure on a device group counts', () {
      // What RoomCostSettings.equipmentSpares produces: part of the line's
      // quantity is spare.
      final l = CostLine(
        key: 'k',
        description: 'Display',
        qty: 4,
        spareQty: 1,
        unitPrice: 100,
        source: PriceSource.catalog,
      );
      expect(l.spareQty, 1);
      expect(l.drawnQty, 3);
    });

    test('a whole line typed in for the shelf counts', () {
      // What CostLineItem.spare produces: the entire line is a spare, and
      // spareQty on it is 0 — a job that only read spareQty would miss it.
      final l = CostLine(
        key: 'k',
        description: 'Spare switcher for the store',
        qty: 1,
        spare: true,
        unitPrice: 900,
        source: PriceSource.catalog,
      );
      expect(l.spare, isTrue);
      expect(l.spareQty, 0);
    });
  });

  group('the job-wide answer', () {
    test('spared parts come back most-spared first', () {
      final estimate = estimateOf([
        line(description: 'Display', spareQty: 1),
        line(description: 'Switcher', spareQty: 3),
        line(description: 'Camera'),
      ]);

      expect(
        [for (final l in estimate.sparedParts) l.description],
        ['Switcher', 'Display'],
      );
      expect(estimate.spareUnits, 4);
    });

    test('the ones with none are reported, equipment only', () {
      final estimate = estimateOf([
        line(description: 'Display', spareQty: 1),
        line(description: 'Switcher'),
        // Nobody wants a report nagging about a spare blanking plate.
        line(description: 'Blanking plate', kind: MasterPartKind.hardware),
        line(description: 'HDMI cable', kind: MasterPartKind.cabling),
      ]);

      expect(
        [for (final l in estimate.partsWithoutSpares) l.description],
        ['Switcher'],
      );
    });

    test('the spares cost what the line costs', () {
      final estimate = estimateOf([
        line(description: 'Display', spareQty: 2, unitPrice: 1500),
        line(description: 'Switcher', spareQty: 1, unitPrice: 900),
      ]);
      // The point of a spare living on its line is that it is the same product
      // at the same price.
      expect(estimate.sparesTotal, 3900);
    });

    test('a job with no spares totals zero rather than blank', () {
      final estimate = estimateOf([line(description: 'Switcher')]);
      expect(estimate.spareUnits, 0);
      expect(estimate.sparesTotal, 0);
      expect(estimate.sparedParts, isEmpty);
      expect(estimate.partsWithoutSpares, hasLength(1));
    });
  });

  group('the report', () {
    test('names what is spared, what is not, and who asked', () {
      final estimate = estimateOf([
        line(
          description: 'Display',
          qty: 4,
          spareQty: 1,
          spareByRoom: {'room1': 1},
        ),
        line(description: 'Switcher'),
      ]);

      final sections = projectSparesSections(estimate);
      final titles = [for (final s in sections) s.title];
      expect(titles.first, 'Spares on this job');
      expect(titles[1], contains('NO spare'));
      expect(titles.last, 'Spares total');

      // The spared row carries both halves of the quantity.
      final spared = sections.first.rows.single;
      expect(spared.first, 'Display');
      expect(spared.contains(1.0), isTrue); // spares
      expect(spared.contains(3.0), isTrue); // for install

      expect(sections[1].rows.single.first, 'Switcher');
    });

    test('a job with nothing spared still produces both tables', () {
      final sections = projectSparesSections(
        estimateOf([line(description: 'Switcher')]),
      );
      // Saying "nothing is spared" is the whole point — an empty sheet would
      // read as a question nobody was asked.
      expect(sections.first.rows.single.first, contains('Nothing on this job'));
      expect(sections[1].rows.single.first, 'Switcher');
    });

    test('a job where everything is spared says that too', () {
      final sections = projectSparesSections(
        estimateOf([line(description: 'Display', spareQty: 1)]),
      );
      expect(sections[1].rows.single.first, contains('Every product'));
    });
  });
}
