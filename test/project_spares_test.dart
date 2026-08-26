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
    BuildingProject? project,
  }) => ProjectEstimate(
    project: project ?? BuildingProject(),
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

    test('the building s own shelf list is a table of its own', () {
      final estimate = estimateOf(
        [
          line(
            description: 'Display',
            qty: 42,
            spareQty: 2,
            unitPrice: 1500,
          ),
        ],
        rooms: [room('room1', 'BSS', '103')],
      );

      final shelf = projectSparesSections(estimate)
          .firstWhere((s) => s.title.startsWith('Spares for the building'));
      // Nothing is on the building here - every spare on this fixture is a
      // room's - and a table that said nothing would read as a question
      // nobody was asked.
      expect(shelf.rows.single.first, contains('Nothing is spared'));
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
      expect(titles.any((t) => t.contains('NO spare')), isTrue);
      expect(titles.last, 'Spares total');

      // The spared row carries both halves of the quantity.
      final spared = sections.first.rows.single;
      expect(spared.first, 'Display');
      expect(spared.contains(1.0), isTrue); // spares
      expect(spared.contains(3.0), isTrue); // for install

      // Found by title rather than by position: sections get added between
      // these two, and a test that counted them would fail for the wrong
      // reason every time one does.
      final without = sections.firstWhere((x) => x.title.contains('NO spare'));
      expect(without.rows.single.first, 'Switcher');
    });

    test('a job with nothing spared still produces both tables', () {
      final sections = projectSparesSections(
        estimateOf([line(description: 'Switcher')]),
      );
      // Saying "nothing is spared" is the whole point — an empty sheet would
      // read as a question nobody was asked.
      expect(sections.first.rows.single.first, contains('Nothing on this job'));
      expect(
        sections
            .firstWhere((s) => s.title.contains('NO spare'))
            .rows
            .single
            .first,
        'Switcher',
      );
    });

    test('a job where everything is spared says that too', () {
      final sections = projectSparesSections(
        estimateOf([line(description: 'Display', spareQty: 1)]),
      );
      expect(
        sections
            .firstWhere((s) => s.title.contains('NO spare'))
            .rows
            .single
            .first,
        contains('Every product'),
      );
    });

    test('the cover table prices every installed part as a percentage', () {
      final sections = projectSparesSections(
        // 42 bought, 2 of them spare: 40 installed, five per cent covered.
        estimateOf([
          line(description: 'Display', qty: 42, spareQty: 2),
        ]),
      );
      final cover = sections.firstWhere((s) => s.title.contains('Spare cover'));
      // Nothing on this job is unspared, so the title is the plain one.
      expect(cover.title, isNot(contains('no spare')));

      final row = cover.rows.single;
      expect(row.first, 'Display');
      expect(row.contains(40.0), isTrue); // installed
      expect(row.contains('5.0%'), isTrue);
      // Two on the shelf is at least one, so the rule is met.
      expect(row.last, 'yes');
    });

    test('a part with nothing spared is called out in the title and the row',
        () {
      final sections = projectSparesSections(
        estimateOf([line(description: 'Display', qty: 40, spareQty: 0)]),
      );
      final cover = sections.firstWhere((s) => s.title.contains('Spare cover'));
      expect(cover.title, contains('1 with no spare'));
      expect(cover.rows.single.contains('0%'), isTrue);
      expect(cover.rows.single.last, 'none');
    });
  });

  // -------------------------------------------------------------------------
  //  THE JOB'S OWN RULE
  // -------------------------------------------------------------------------
  //  ONE SPARE, OR NONE. A part the job installs and holds nothing spare of is
  //  the row worth acting on; the second spare of a part that already has one
  //  is a judgement nobody needs a table for.
  //
  //  This replaced a percentage target the job had to be told before the table
  //  would flag anything - which asked for four spare wall plates on a job
  //  with forty and said nothing about the one switcher the building runs
  //  through. The percentage is still what every row SAYS.

  group('one spare of everything', () {
    test('a part with nothing spared is short by one', () {
      final estimate = estimateOf([
        line(description: 'Display', qty: 40, spareQty: 0),
      ]);
      final cover = estimate.spareCover.single;
      expect(cover.short, isTrue);
      expect(cover.shortfall, 1);
      // The percentage is still worked out: it is what the row says, not what
      // decides whether the row is flagged.
      expect(cover.coverage, 0);
      expect(
        [for (final c in estimate.unsparedParts) c.line.description],
        ['Display'],
      );
    });

    test('one spare is enough, however many are installed', () {
      // Forty installed and one on the shelf is 2.5% cover, and it is not a
      // fault: somebody looked at this part and bought one.
      final estimate = estimateOf([
        line(description: 'Display', qty: 41, spareQty: 1),
      ]);
      final cover = estimate.spareCover.single;
      expect(cover.installed, 40);
      expect(cover.spares, 1);
      expect(cover.short, isFalse);
      expect(cover.shortfall, 0);
      expect(cover.coverage, closeTo(0.025, 1e-9));
      expect(estimate.unsparedParts, isEmpty);
    });

    test('the unspared come first, then the thinnest cover', () {
      final estimate = estimateOf([
        line(description: 'Fine', qty: 12, spareQty: 2),
        line(description: 'Thin', qty: 41, spareQty: 1),
        line(description: 'Bare', qty: 20, spareQty: 0),
      ]);
      expect(
        [for (final c in estimate.spareCover) c.line.description],
        ['Bare', 'Thin', 'Fine'],
      );
      expect(
        [for (final c in estimate.unsparedParts) c.line.description],
        ['Bare'],
      );
    });

    test('the recommendation is a percentage of what goes in', () {
      // Forty installed, one held. It meets the RULE - somebody looked at this
      // part and bought one - and it is a long way under what ten per cent of
      // forty would be, which is the other half of the question and the half
      // the rule cannot answer.
      final estimate = estimateOf([
        line(description: 'Plate', qty: 41, spareQty: 1),
      ]);
      final cover = estimate.spareCover.single;
      expect(cover.installed, 40);
      expect(cover.recommended, 4);
      expect(cover.toRecommend, 3);
      // ...and it is STILL NOT FLAGGED. Only a part with nothing spared is.
      expect(cover.short, isFalse);
      expect(estimate.unsparedParts, isEmpty);
      expect(
        [for (final c in estimate.partsUnderRecommendedCover) c.line.description],
        ['Plate'],
      );
      expect(estimate.unitsToRecommendedCover, 3);
    });

    test('the recommendation rounds up and never asks for less than one', () {
      // Four installed is 0.4 of a unit at ten per cent, and nobody can buy
      // 0.4 of a projector. It must also never come out below the rule it sits
      // beside, or the two would contradict each other on the same row.
      final estimate = estimateOf([
        line(description: 'Display', qty: 4, spareQty: 0),
      ]);
      final cover = estimate.spareCover.single;
      expect(cover.recommended, 1);
      expect(cover.toRecommend, 1);
      expect(cover.short, isTrue);
    });

    test('a part that meets the recommendation asks for nothing', () {
      final estimate = estimateOf([
        line(description: 'Plate', qty: 44, spareQty: 4),
      ]);
      final cover = estimate.spareCover.single;
      expect(cover.installed, 40);
      expect(cover.recommended, 4);
      expect(cover.toRecommend, 0);
      expect(estimate.partsUnderRecommendedCover, isEmpty);
      expect(estimate.unitsToRecommendedCover, 0);
    });

    test('a part nothing installs is left off the table', () {
      // A spare kept for a model every room has since been swapped off. Its
      // cover is not nought per cent, it is undefined - and a row saying 0%
      // would be a part somebody went and bought a spare for.
      final estimate = estimateOf([
        line(description: 'Orphan', qty: 2, spareQty: 2),
      ]);
      expect(estimate.spareCover, isEmpty);
      expect(estimate.unsparedParts, isEmpty);
    });

    test('cable and hardware are never asked about', () {
      // The same rule the "no spare" list follows: nobody wants to be told a
      // blanking plate has no spare.
      final estimate = estimateOf([
        line(
          description: 'Patch lead',
          qty: 40,
          kind: MasterPartKind.cabling,
        ),
      ]);
      expect(estimate.spareCover, isEmpty);
    });

    test('a job file that carries a target opens with it in force', () {
      // The same key the old policy was written under, holding the same
      // number and meaning very nearly the same thing - so a file written by
      // that version opens with its target back, rather than silently at the
      // suggestion.
      final read = BuildingProject.fromJson({
        'rooms': const [],
        'spareTargetPercent': 12.5,
      });
      expect(read.spareCoverTarget, closeTo(0.125, 1e-9));
      expect(read.toJson()['spareTargetPercent'], closeTo(12.5, 1e-9));
      // A percentage on its own is still not a job.
      expect(read.isEmpty, isTrue);
    });

    test('a target that is not a percentage is read as the suggestion', () {
      // '200%' in a hand-edited file is a typo, and honouring it would put a
      // recommendation of two hundred spare wall plates on the sheet.
      for (final bad in [200, -5, 'soon', null]) {
        final read = BuildingProject.fromJson({
          'rooms': const [],
          // A null here is the fourth case: the key absent altogether.
          'spareTargetPercent': ?bad,
        });
        expect(read.spareCoverTarget, kSuggestedSpareCover, reason: '$bad');
        // At the suggestion the key is not written at all.
        expect(read.toJson().containsKey('spareTargetPercent'), isFalse);
      }
    });

    test('the target is what the recommendation is worked out from', () {
      // Forty installed. At the suggestion that is four; at nought it is the
      // rule and nothing more, which is one of everything.
      final rich = estimateOf(
        [line(description: 'Plate', qty: 40, spareQty: 0)],
        project: BuildingProject(spareCoverTarget: 0.25),
      );
      expect(rich.spareCover.single.recommended, 10);
      expect(rich.spareCover.single.toRecommend, 10);

      final oneEach = estimateOf(
        [line(description: 'Plate', qty: 40, spareQty: 0)],
        project: BuildingProject(spareCoverTarget: 0),
      );
      expect(oneEach.spareCover.single.recommended, 1);
      expect(oneEach.spareCover.single.toRecommend, 1);
      // And it is still the only thing flagged, at either setting.
      expect(rich.unsparedParts, hasLength(1));
      expect(oneEach.unsparedParts, hasLength(1));
    });
  });
}
