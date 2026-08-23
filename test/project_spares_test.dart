import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_flow_model.dart';
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

  /// A room on the job, named so a rollup has something to print. The spares
  /// question is asked about ROOMS, and 'room1' is not a room.
  ProjectRoomCost room(String id, String bldg, String number) =>
      ProjectRoomCost(
        ref: ProjectRoomRef(
          id: id,
          configPath: '/rooms/${bldg}_${number}_config.json',
        ),
        room: LoadedRoom(
          configPath: '/rooms/${bldg}_${number}_config.json',
          title: '$bldg $number',
          model: const AvFlowModel(
            nodes: [],
            cables: [],
            racks: [],
            rackSlots: {},
            canvasSize: Size(900, 560),
            roomTitle: '',
            unplaced: [],
          ),
          settings: RoomCostSettings(),
          config: const {},
        ),
      );

  ProjectEstimate estimateOf(
    List<MasterPartLine> master, {
    List<ProjectRoomCost> rooms = const [],
  }) => ProjectEstimate(
    project: BuildingProject(),
    currency: r'$',
    rooms: rooms,
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

  group('whose spares they are', () {
    // The master list merges the rooms together on purpose — one line per part
    // is the entire reason it exists — and that merge is exactly what makes a
    // spare impossible to account for afterwards. "Eleven, four of them spare"
    // is a figure nobody can approve or trim without knowing whose four.
    ProjectEstimate job() => estimateOf(
      [
        line(
          description: 'Display',
          qty: 9,
          spareQty: 3,
          spareByRoom: {'room1': 2, 'room2': 1},
          unitPrice: 1500,
        ),
        line(
          description: 'Switcher',
          qty: 4,
          spareQty: 1,
          spareByRoom: {'room2': 1},
          unitPrice: 900,
        ),
        line(description: 'Camera', qty: 2),
      ],
      rooms: [room('room1', 'BSS', '103'), room('room2', 'ENG', '210')],
    );

    test('a part names the rooms that asked, most spares first', () {
      final display = job().master.first;
      expect(display.spareRoomIdsByQty(), ['room1', 'room2']);
      // The rooms it is INSTALLED in are a different question, and this line
      // deliberately answers only the one it was asked.
      expect(display.roomIdsByQty(), isEmpty);
    });

    test('the job breaks its spares back down to the rooms', () {
      final byRoom = job().sparesByRoom;
      expect(byRoom, hasLength(2));

      // Dearest first: the money is what gets questioned. Both rooms asked for
      // two units and they are not the same decision — BSS wants two displays
      // and ENG a display and a switcher — so units cannot be what this is
      // sorted on.
      expect(byRoom.first.name, 'BSS 103');
      expect(byRoom.first.units, 2);
      expect(byRoom.first.parts, 1);
      expect(byRoom.first.cost, 3000);

      expect(byRoom[1].name, 'ENG 210');
      expect(byRoom[1].units, 2);
      expect(byRoom[1].parts, 2);
      expect(byRoom[1].cost, 2400);
    });

    test('the rooms add back up to the job', () {
      final estimate = job();
      final units = estimate.sparesByRoom.fold(0.0, (s, r) => s + r.units);
      final cost = estimate.sparesByRoom.fold(0.0, (s, r) => s + r.cost);
      // The whole point of the breakdown is that it IS the total, split up. A
      // room list that did not add up would be a second, quieter figure.
      expect(units, estimate.spareUnits);
      expect(cost, estimate.sparesTotal);
    });

    test('one room’s spares come back dearest first', () {
      final mine = job().sparedPartsForRoom('room2');
      expect([for (final l in mine) l.description], ['Display', 'Switcher']);
      // A room that spared nothing is the ordinary case, not a fault.
      expect(job().sparedPartsForRoom('room404'), isEmpty);
    });

    test('a spare filed against a room no longer on the job still lists', () {
      // Money that quietly disappears off a quote is worse than money on it
      // under a name nobody recognises.
      final orphan = estimateOf([
        line(
          description: 'Display',
          spareQty: 1,
          spareByRoom: {'room9': 1},
          unitPrice: 1500,
        ),
      ]);
      expect(orphan.sparesByRoom.single.roomId, 'room9');
      expect(orphan.sparesByRoom.single.name, 'room9');
      expect(orphan.sparesByRoom.single.cost, 1500);
    });

    test('a job with no spares has no rooms to name', () {
      expect(estimateOf([line(description: 'Camera')]).sparesByRoom, isEmpty);
    });
  });

  group('the report', () {
    test('it breaks the spares down by room as well as by part', () {
      final estimate = estimateOf(
        [
          line(
            description: 'Display',
            qty: 9,
            spareQty: 3,
            spareByRoom: {'room1': 2, 'room2': 1},
            unitPrice: 1500,
          ),
        ],
        rooms: [room('room1', 'BSS', '103'), room('room2', 'ENG', '210')],
      );

      final byRoom = projectSparesSections(estimate)
          .firstWhere((s) => s.title.startsWith('Spares by room'));
      expect(byRoom.rows, hasLength(2));
      expect(byRoom.rows.first.first, 'BSS 103');
      // What each room actually asked for, not just how much of it.
      expect(byRoom.rows.first.last, 'Display ×2');
    });

    test('a job with nothing spared says so on the room table too', () {
      final byRoom = projectSparesSections(estimateOf([line(description: 'X')]))
          .firstWhere((s) => s.title.startsWith('Spares by room'));
      expect(byRoom.rows.single.first, contains('No room on this job'));
    });

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
