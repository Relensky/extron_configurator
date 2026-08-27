import 'dart:convert';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/model_swap.dart';
import 'package:extron_configurator/room_locations.dart';

/// How old the gear is, when it falls due, and what that costs.
///
/// Every figure here is checked against a FIXED `asOf` rather than the clock:
/// a replacement plan that reads differently tomorrow is one nobody can check,
/// which is the whole reason the arithmetic takes the day as an argument.
void main() {
  final asOf = DateTime(2026, 6, 15);

  AvNode box(
    String id, {
    DateTime? installedOn,
    int lifeYears = 0,
    String model = 'PROJ-1',
    List<EquipmentSwap> swaps = const [],
    AvNodeKind kind = AvNodeKind.device,
  }) => AvNode(
    id: id,
    label: id,
    model: model,
    pos: Offset.zero,
    ports: const [],
    kind: kind,
    installedOn: installedOn,
    lifeYears: lifeYears,
    swaps: swaps,
  );

  AvFlowModel roomOf(List<AvNode> nodes, {List<RoomLocation> locations = const []}) =>
      AvFlowModel(
        nodes: nodes,
        cables: const [],
        racks: const [],
        rackSlots: const {},
        rackItems: const [],
        canvasSize: Size.zero,
        roomTitle: 'Test Room',
        unplaced: const [],
        locations: locations,
      );

  EquipmentLife lifeOf(AvNode node) =>
      buildRoomLifecycle(model: roomOf([node]), asOf: asOf).items.single;

  // -------------------------------------------------------------------------
  //  THE BANDS
  // -------------------------------------------------------------------------

  group('the red / amber / green bands', () {
    test('the install year is year one, and years one to five are green', () {
      // The RYG sheet's own reading: a room done in 2022 is in year five in
      // 2026 and still green on an eight-year cycle.
      for (final year in [2026, 2025, 2024, 2023, 2022]) {
        final item = lifeOf(box('a', installedOn: DateTime(year, 6, 1)));
        expect(
          item.condition,
          EquipmentCondition.good,
          reason: 'installed $year should still be green in 2026',
        );
      }
    });

    test('years six to eight are amber - the planning window', () {
      for (final year in [2021, 2020, 2019]) {
        final item = lifeOf(box('a', installedOn: DateTime(year, 6, 1)));
        expect(
          item.condition,
          EquipmentCondition.ageing,
          reason: 'installed $year should be amber in 2026',
        );
      }
    });

    test('year nine onward is red', () {
      for (final year in [2018, 2015, 2004]) {
        final item = lifeOf(box('a', installedOn: DateTime(year, 6, 1)));
        expect(
          item.condition,
          EquipmentCondition.overdue,
          reason: 'installed $year should be red in 2026',
        );
      }
    });

    test('the day it falls due is the install date plus its life', () {
      final item = lifeOf(box('a', installedOn: DateTime(2018, 3, 14)));
      expect(item.dueOn, DateTime(2026, 3, 14));
      expect(item.dueYear, 2026);
      // Due in March, read in June: past it.
      expect(item.condition, EquipmentCondition.overdue);
    });

    test('a 29 February install falls due on a day that exists', () {
      final item = lifeOf(box('a', installedOn: DateTime(2020, 2, 29)));
      // 2020 + 8 = 2028, which IS a leap year, so the day survives.
      expect(item.dueOn, DateTime(2028, 2, 29));
      // Seven years, which is not a leap year: the 28th rather than 1 March.
      final seven = lifeOf(
        box('b', installedOn: DateTime(2020, 2, 29), lifeYears: 7),
      );
      expect(seven.dueOn, DateTime(2027, 2, 28));
    });

    test('a position with its own life is banded against that life', () {
      // A five-year lectern PC installed in 2022 is amber in 2026 even though
      // the same date on the default eight-year cycle is green.
      final short = lifeOf(
        box('a', installedOn: DateTime(2022, 6, 1), lifeYears: 5),
      );
      expect(short.lifeYears, 5);
      expect(short.dueYear, 2027);
      expect(short.condition, EquipmentCondition.ageing);
    });

    test('a very short life still gets a green year', () {
      // Amber is the last three years of a life, and three years of a
      // two-year cycle is the whole thing - which would read amber the day it
      // was installed.
      final item = lifeOf(
        box('a', installedOn: DateTime(2026, 1, 1), lifeYears: 2),
      );
      expect(item.condition, EquipmentCondition.good);
    });

    test('no install date is unknown, not new', () {
      final item = lifeOf(box('a'));
      expect(item.condition, EquipmentCondition.unknown);
      expect(item.dueYear, isNull);
      expect(item.ageYears, isNull);
      expect(formatEquipmentAge(item.ageYears), 'not recorded');
    });

    test('a date in the future reads as not yet installed', () {
      final item = lifeOf(box('a', installedOn: DateTime(2027, 1, 1)));
      expect(formatEquipmentAge(item.ageYears), 'not yet installed');
      expect(item.condition, EquipmentCondition.good);
    });
  });

  // -------------------------------------------------------------------------
  //  THE ROOM
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  //  THE GRADED WARNING BAND
  // -------------------------------------------------------------------------

  group('the ramp inside the amber band', () {
    test('the three warning years are three different colours', () {
      // An eight-year cycle read in 2026: year six is yellow, seven amber,
      // eight orange. One amber for all three is what this replaces.
      final steps = {
        2021: EquipmentTiming.watch,
        2020: EquipmentTiming.approaching,
        2019: EquipmentTiming.imminent,
      };
      steps.forEach((year, expected) {
        final item = lifeOf(box('a', installedOn: DateTime(year, 6, 1)));
        expect(
          item.timing,
          expected,
          reason: 'installed $year should read as ${expected.name} in 2026',
        );
        // The words never come apart from the colour: all three are still
        // 'due soon' on any sheet that only has the four bands.
        expect(item.condition, EquipmentCondition.ageing);
      });
    });

    test('past its life goes deeper red once it is two years past', () {
      final justPast = lifeOf(box('a', installedOn: DateTime(2018, 1, 1)));
      expect(justPast.timing, EquipmentTiming.overdue);
      final longPast = lifeOf(box('b', installedOn: DateTime(2015, 1, 1)));
      expect(longPast.timing, EquipmentTiming.wellOverdue);
      // Both are red on the four-band reading.
      expect(justPast.condition, EquipmentCondition.overdue);
      expect(longPast.condition, EquipmentCondition.overdue);
    });

    test('a short life still gets a green year rather than opening amber', () {
      // Two years, installed today: the window would be the whole life if it
      // were not clamped, and a position that reads amber the day it goes in
      // is one nobody believes.
      final item = lifeOf(
        box('a', installedOn: DateTime(2026, 6, 1), lifeYears: 2),
      );
      expect(item.timing, EquipmentTiming.inService);
    });

    test('no install date is not a step on the ramp', () {
      expect(lifeOf(box('a')).timing, EquipmentTiming.unknown);
      expect(
        timingFor(yearsRemaining: null, lifeYears: 8),
        EquipmentTiming.unknown,
      );
    });

    test('the worse of two steps wins, and unknown is not the worst', () {
      expect(
        worstTiming(EquipmentTiming.watch, EquipmentTiming.imminent),
        EquipmentTiming.imminent,
      );
      expect(
        worstTiming(EquipmentTiming.unknown, EquipmentTiming.inService),
        EquipmentTiming.unknown,
      );
      expect(
        worstTiming(EquipmentTiming.unknown, EquipmentTiming.overdue),
        EquipmentTiming.overdue,
      );
    });

    test('a room row warms up across the year grid', () {
      final room = buildRoomLifecycle(
        model: roomOf([box('a', installedOn: DateTime(2020, 6, 1))]),
        asOf: asOf,
      );
      // Due 2028 on the default cycle: green until 2024, then one year each of
      // yellow, amber and orange, then red.
      expect(room.timingIn(2019), EquipmentTiming.unknown);
      expect(room.timingIn(2021), EquipmentTiming.inService);
      expect(room.timingIn(2025), EquipmentTiming.watch);
      expect(room.timingIn(2026), EquipmentTiming.approaching);
      expect(room.timingIn(2027), EquipmentTiming.imminent);
      expect(room.timingIn(2028), EquipmentTiming.overdue);
      expect(room.timingIn(2030), EquipmentTiming.wellOverdue);
    });
  });

  group('a room', () {
    test('reads as its worst item, not its average', () {
      final room = buildRoomLifecycle(
        model: roomOf([
          box('new1', installedOn: DateTime(2026, 1, 1)),
          box('new2', installedOn: DateTime(2026, 1, 1)),
          box('old', installedOn: DateTime(2010, 1, 1)),
        ]),
        asOf: asOf,
      );
      expect(room.condition, EquipmentCondition.overdue);
      expect(room.countOf(EquipmentCondition.good), 2);
      expect(room.countOf(EquipmentCondition.overdue), 1);
      // The room was last done when its OLDEST piece went in.
      expect(room.oldestInstall, DateTime(2010, 1, 1));
      expect(room.firstDueYear, 2018);
    });

    test('the worst item is listed first', () {
      final room = buildRoomLifecycle(
        model: roomOf([
          box('new', installedOn: DateTime(2026, 1, 1)),
          box('old', installedOn: DateTime(2010, 1, 1)),
          box('undated'),
        ]),
        asOf: asOf,
      );
      expect(room.items.first.node.id, 'old');
      expect(room.items.last.node.id, 'new');
    });

    test('jack fields and patch panels are not on the refresh cycle', () {
      final room = buildRoomLifecycle(
        model: roomOf([
          box('device', installedOn: DateTime(2020, 1, 1)),
          box('plate', kind: AvNodeKind.jackField),
          box('panel', kind: AvNodeKind.patchPanel),
        ]),
        asOf: asOf,
      );
      expect(room.items.map((i) => i.node.id), ['device']);
    });

    test('an empty room reports nothing rather than a false green', () {
      final room = buildRoomLifecycle(model: roomOf([]), asOf: asOf);
      expect(room.items, isEmpty);
      expect(room.condition, EquipmentCondition.unknown);
      expect(roomLifecycleSections(room), isEmpty);
    });

    test('the catalog prices the replacement, and says nothing when it cannot',
        () {
      final library = AvDeviceLibrary.empty()
        ..upsert(const AvDeviceTemplate(model: 'PROJ-1', price: 4200, ports: []));
      final room = buildRoomLifecycle(
        model: roomOf([
          box('priced', installedOn: DateTime(2010, 1, 1)),
          box('unpriced', installedOn: DateTime(2010, 1, 1), model: 'NOPE'),
        ]),
        library: library,
        asOf: asOf,
      );
      expect(room.refreshCost, 4200);
      expect(room.overdueCost, 4200);
      // Unpriced is reported as unpriced rather than as free.
      final unpriced =
          room.items.firstWhere((i) => i.node.id == 'unpriced');
      expect(unpriced.replacementCost, 0);
      expect(formatLifecycleMoney(unpriced.replacementCost, r'$'), '');
    });
  });

  // -------------------------------------------------------------------------
  //  WHERE THE LIFE COMES FROM
  // -------------------------------------------------------------------------
  //  Three answers, most specific first, and every row says which it used.

  group('how many, and what it costs', () {
    AvDeviceLibrary catalog(double price) => AvDeviceLibrary.empty()
      ..upsert(AvDeviceTemplate(model: 'PROJ-1', price: price, ports: const []));

    RoomLifecycle roomWith(List<AvNode> nodes) => buildRoomLifecycle(
      model: roomOf(nodes),
      library: catalog(4000),
      asOf: asOf,
    );

    test('a band carries its count and its money together', () {
      final room = roomWith([
        // Past its life, inside the window, and fine.
        box('old', installedOn: DateTime(2010, 6, 1)),
        box('soon', installedOn: DateTime(2020, 6, 1)),
        box('new', installedOn: DateTime(2025, 6, 1)),
      ]);
      expect(room.countOf(EquipmentCondition.overdue), 1);
      expect(room.costOf(EquipmentCondition.overdue), 4000);
      expect(room.countOf(EquipmentCondition.ageing), 1);
      expect(room.costOf(EquipmentCondition.ageing), 4000);
      // The one figure a refresh is asked for: past its life plus the window.
      expect(room.toReplaceCount, 2);
      expect(room.toReplaceCost, 8000);
      // And the room that is fine is not in it.
      expect(room.refreshCost, 12000);
    });

    test('the count follows a life changed on one item', () {
      // The same room, with the middle position put on a short cycle: it
      // crosses out of the window and into red, and the money moves with it.
      final before = roomWith([box('a', installedOn: DateTime(2020, 6, 1))]);
      expect(before.toReplaceCount, 1);
      expect(before.costOf(EquipmentCondition.overdue), 0);

      final after = roomWith([
        box('a', installedOn: DateTime(2020, 6, 1), lifeYears: 4),
      ]);
      expect(after.costOf(EquipmentCondition.overdue), 4000);
      expect(after.toReplaceCost, 4000);
    });

    test('a band says it is unpriced rather than reading as free', () {
      expect(formatEquipmentBand(0, 0, r'$'), '0 items');
      expect(formatEquipmentBand(1, 0, r'$'), '1 item, not priced');
      expect(formatEquipmentBand(3, 12000, r'$'), r'3 items, $12,000');
    });
  });

  // -------------------------------------------------------------------------
  //  THE THINGS THAT ARE NEVER REPLACED
  // -------------------------------------------------------------------------

  group('a position taken off the refresh cycle', () {
    RoomLifecycle roomOfThree() => buildRoomLifecycle(
      model: roomOf([
        box('projector', installedOn: DateTime(2016, 6, 1)),
        box('mount', installedOn: DateTime(2016, 6, 1), lifeYears: -1),
        box('pole', lifeYears: -1),
      ]),
      asOf: asOf,
    );

    test('is held off the plan, not thrown away', () {
      final room = roomOfThree();
      expect(room.items.map((i) => i.node.label), ['projector']);
      expect(room.neverReplaced.map((i) => i.node.label), ['mount', 'pole']);
      expect(room.neverCount, 2);
    });

    test('is out of every figure the plan is read from', () {
      final room = roomOfThree();
      // The pole has no install date, and would otherwise have been one more
      // room-with-unknowns on a survey that is actually finished.
      expect(room.undated, 0);
      expect(room.items.length, 1);
      expect(room.condition, EquipmentCondition.overdue);
      expect(room.toReplaceCount, 1);
    });

    test('has no due date, because it is not on a cycle', () {
      final room = roomOfThree();
      final mount = room.neverReplaced.first;
      expect(mount.neverReplaced, isTrue);
      expect(mount.dueOn, isNull);
      expect(mount.dueYear, isNull);
      expect(mount.timing, EquipmentTiming.unknown);
      // The install date is still recorded — the room still has the thing.
      expect(mount.installedOn, DateTime(2016, 6, 1));
    });

    test('the sheet says what is being held back, and lists it', () {
      final sections = roomLifecycleSections(roomOfThree());
      final summary = sections.firstWhere((s) => s.title == 'Equipment Age');
      expect(
        summary.rows.any((r) => r.first == 'Never replaced'),
        isTrue,
        reason: 'a plan with two items held back must not read as a room with '
            'two items fewer',
      );
      final off = sections.firstWhere(
        (s) => s.title == 'Not On The Refresh Cycle',
      );
      expect(off.rows.map((r) => r.first), ['mount', 'pole']);
    });

    test('the sentinel survives the file, and nonsense does not', () {
      final node = box('mount', lifeYears: -1);
      expect(node.toJson()['lifeYears'], -1);
      expect(AvNode.fromJson(node.toJson()).lifeYears, -1);
      // Anything below it is not a life anybody meant.
      final wild = Map<String, dynamic>.from(node.toJson())
        ..['lifeYears'] = -8;
      expect(AvNode.fromJson(wild).lifeYears, 0);
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT REPLACING IT COSTS
  // -------------------------------------------------------------------------
  //  A refresh plan is read years before the models are chosen, and half the
  //  boxes on an old drawing are positions nobody ever catalogued. Pricing
  //  only what the catalog knows left the plan reporting most of a building as
  //  free, which is the one direction a budget must not be wrong in.

  group('what a replacement costs', () {
    BaseCostBook cardWith(String category, double price) => BaseCostBook(
      costs: [BaseCost(category: category, price: price)],
    );

    EquipmentLife priced({
      AvDeviceLibrary? library,
      BaseCostBook? baseCosts,
      String id = 'PROJECTORDEVICE_1',
      String model = 'PROJ-1',
    }) => buildRoomLifecycle(
      model: roomOf([box(id, model: model, installedOn: DateTime(2018, 6, 1))]),
      library: library,
      baseCosts: baseCosts,
      asOf: asOf,
    ).items.single;

    test('the catalog price wins, and is not an estimate', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(model: 'PROJ-1', price: 4200, ports: const []),
        );
      final item = priced(
        library: library,
        baseCosts: cardWith('Projector', 3000),
      );
      expect(item.replacementCost, 4200);
      expect(item.costIsEstimate, isFalse);
    });

    test('a model the catalog cannot price falls back to the base card', () {
      // The rung the estimate itself falls back to. Better than a hole in the
      // total, as long as the figure says what it is.
      final item = priced(baseCosts: cardWith('Projector', 3000));
      expect(item.replacementCost, 3000);
      expect(item.costIsEstimate, isTrue);
    });

    test('the card is read in the catalog category first', () {
      // 'Matrix' is what a switcher is filed under when the entry was imported
      // from the manufacturer; the card is written in this app's words, and
      // [BaseCostBook.priceFor] translates the families that mean one thing.
      final library = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(
            model: 'DTP-CP',
            category: 'Matrix',
            ports: const [],
          ),
        );
      final item = priced(
        library: library,
        baseCosts: cardWith('Switcher', 5500),
        id: 'PROJECTORDEVICE_1',
        model: 'DTP-CP',
      );
      expect(item.replacementCost, 5500);
      expect(item.costIsEstimate, isTrue);
    });

    test('a position with no model at all is priced by what it does', () {
      // The only category such a position has is the one its config section
      // key makes it - which is exactly the case the plan used to report free.
      final item = priced(
        baseCosts: cardWith('Camera', 1800),
        id: 'CAMERADEVICE_1',
        model: '',
      );
      expect(item.replacementCost, 1800);
      expect(item.costIsEstimate, isTrue);
    });

    test('neither is unpriced, not free', () {
      final item = priced();
      expect(item.replacementCost, 0);
      expect(item.costIsEstimate, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  //  A ROOM IS RARELY ONE DATE
  // -------------------------------------------------------------------------
  //  The projector went in in 2016 and the displays in 2019. On an eight-year
  //  cycle that is two replacement dates, and a sheet with one row per room can
  //  only ever show the first - which leaves the rest of the room's money
  //  invisible until the year it lands.

  group('the room, split by due date', () {
    RoomLifecycle roomOfDates(List<AvNode> nodes) =>
        buildRoomLifecycle(model: roomOf(nodes), asOf: asOf);

    test('everything due in one year is one tranche', () {
      final room = roomOfDates([
        box('a', installedOn: DateTime(2019, 6, 1)),
        box('b', installedOn: DateTime(2019, 8, 1)),
      ]);
      final group = room.dueGroups.single;
      expect(group.dueYear, 2027);
      expect(group.startYear, 2019);
      expect(group.items, hasLength(2));
    });

    test('two dates are two tranches, earliest first', () {
      final room = roomOfDates([
        box('display', installedOn: DateTime(2019, 6, 1)),
        box('projector', installedOn: DateTime(2016, 6, 1)),
      ]);
      expect([for (final g in room.dueGroups) g.dueYear], [2024, 2027]);
      // Each run starts where ITS equipment went in, not where the room did.
      expect([for (final g in room.dueGroups) g.startYear], [2016, 2019]);
    });

    test('a tranche spans the oldest install in it', () {
      // Two boxes landing in the same year having gone in two years apart - a
      // five-year display beside a seven-year projector. The run has to cover
      // both or it says the room was done later than it was.
      final room = roomOfDates([
        box('short', installedOn: DateTime(2020, 6, 1), lifeYears: 5),
        box('long', installedOn: DateTime(2018, 6, 1), lifeYears: 7),
      ]);
      final group = room.dueGroups.single;
      expect(group.dueYear, 2025);
      expect(group.startYear, 2018);
      // Banded on the longest life in it, so the run warms up over its whole
      // length rather than turning red two thirds of the way along.
      expect(group.lifeYears, 8);
    });

    test('an undated position is on no tranche at all', () {
      // It has no span to draw. Inventing one would put a year on the sheet
      // that nobody recorded.
      final room = roomOfDates([
        box('dated', installedOn: DateTime(2019, 6, 1)),
        box('never surveyed'),
      ]);
      expect(room.dueGroups.single.items.single.node.id, 'dated');
      expect(room.undated, 1);
    });
  });

  group('the life a position is held to', () {
    AvDeviceLibrary catalogWith(int life) => AvDeviceLibrary.empty()
      ..upsert(AvDeviceTemplate(model: 'PROJ-1', lifeYears: life, ports: const []));

    EquipmentLife withCatalog(AvNode node, AvDeviceLibrary? library) =>
        buildRoomLifecycle(
          model: roomOf([node]),
          library: library,
          asOf: asOf,
        ).items.single;

    test('the catalog average is used when the position says nothing', () {
      final item = withCatalog(
        box('a', installedOn: DateTime(2022, 6, 1)),
        catalogWith(4),
      );
      expect(item.lifeYears, 4);
      expect(item.lifeSource, EquipmentLifeSource.catalog);
      // 2022 + 4 = 2026, so a four-year product installed in 2022 is past it
      // where the same date on the blanket cycle would still be green.
      expect(item.dueYear, 2026);
      expect(item.condition, EquipmentCondition.overdue);
    });

    test('the position beats the catalog', () {
      final item = withCatalog(
        box('a', installedOn: DateTime(2022, 6, 1), lifeYears: 12),
        catalogWith(4),
      );
      expect(item.lifeYears, 12);
      expect(item.lifeSource, EquipmentLifeSource.position);
      expect(item.condition, EquipmentCondition.good);
    });

    test('the blanket cycle is what is left', () {
      // No catalog at all...
      final noLibrary = withCatalog(
        box('a', installedOn: DateTime(2022, 6, 1)),
        null,
      );
      expect(noLibrary.lifeYears, kDefaultEquipmentLifeYears);
      expect(noLibrary.lifeSource, EquipmentLifeSource.fallback);

      // ...and a catalog that has the model but no life on it.
      final unrecorded = withCatalog(
        box('a', installedOn: DateTime(2022, 6, 1)),
        catalogWith(0),
      );
      expect(unrecorded.lifeYears, kDefaultEquipmentLifeYears);
      expect(unrecorded.lifeSource, EquipmentLifeSource.fallback);
    });

    test('a model the catalog has never heard of falls back too', () {
      final item = withCatalog(
        box('a', installedOn: DateTime(2022, 6, 1), model: 'NOT-IN-CATALOG'),
        catalogWith(4),
      );
      expect(item.lifeSource, EquipmentLifeSource.fallback);
    });

    test('the room sheet says where each figure came from', () {
      final room = buildRoomLifecycle(
        model: roomOf([
          box('fromCatalog', installedOn: DateTime(2022, 6, 1)),
          box('fromPosition', installedOn: DateTime(2022, 6, 1), lifeYears: 12),
        ]),
        library: catalogWith(4),
        asOf: asOf,
      );
      final schedule = roomLifecycleSections(room)
          .firstWhere((s) => s.title == 'Equipment Replacement Schedule');
      final column = schedule.header.indexOf('Life from');
      expect(column, isNonNegative);
      final byName = {
        for (final row in schedule.rows) row.first as String: row[column],
      };
      expect(byName['fromCatalog'], 'from the catalog');
      expect(byName['fromPosition'], 'set on this item');
    });
  });

  group('the catalog entry', () {
    test('carries the average life through a save and a reload', () {
      const entry = AvDeviceTemplate(
        model: 'PROJ-1',
        lifeYears: 6,
        ports: [],
      );
      expect(entry.toJson()['lifeYears'], 6);
      final round = AvDeviceTemplate.fromJson(
        jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
      );
      expect(round.lifeYears, 6);
    });

    test('an entry with no life recorded writes no key for one', () {
      const entry = AvDeviceTemplate(model: 'PROJ-1', ports: []);
      expect(entry.toJson().containsKey('lifeYears'), isFalse);
      expect(entry.lifeYears, 0);
    });

    test('a figure that is not a sane number of years reads as unrecorded', () {
      // Text where a number belongs, a negative, and a plain typo. All of them
      // would sit green on the plan for ever if honoured.
      for (final raw in <Object>['about 8 years', -4, 0, 600]) {
        final round = AvDeviceTemplate.fromJson({
          'model': 'PROJ-1',
          'lifeYears': raw,
          'ports': <dynamic>[],
        });
        expect(round.lifeYears, 0, reason: 'lifeYears: $raw');
      }
    });

    test('a catalog written before this existed reads as unrecorded', () {
      final round = AvDeviceTemplate.fromJson({
        'model': 'PROJ-1',
        'ports': <dynamic>[],
      });
      expect(round.lifeYears, 0);
    });
  });

  // -------------------------------------------------------------------------
  //  THE SWAP RECORD
  // -------------------------------------------------------------------------

  group('swapping the box out', () {
    test('files the unit that came out and restarts the clock', () {
      final before = box('a', model: 'OLD-1', installedOn: DateTime(2016, 4, 1));
      final after = before.withSwapRecorded(
        on: DateTime(2026, 6, 15),
        reason: 'end of life',
      );

      expect(after.installedOn, DateTime(2026, 6, 15));
      expect(after.swaps, hasLength(1));
      expect(after.swaps.single.model, 'OLD-1');
      expect(after.swaps.single.installedOn, DateTime(2016, 4, 1));
      expect(after.swaps.single.removedOn, DateTime(2026, 6, 15));
      expect(after.swaps.single.reason, 'end of life');
      // Ten years and change, which is what the last one actually lasted -
      // the figure a refresh policy is argued from.
      expect(after.swaps.single.servedYears, closeTo(10.2, 0.1));
    });

    test('a box with nothing recorded files nothing', () {
      final fresh = box('a', model: '');
      final after = fresh.withSwapRecorded(on: DateTime(2026, 6, 15));
      expect(after.swaps, isEmpty);
      expect(after.installedOn, DateTime(2026, 6, 15));
    });

    test('a model swap records it without being asked', () {
      final node = box('a', model: 'OLD-1', installedOn: DateTime(2016, 4, 1));
      final plan = planModelSwap(
        node: node,
        cables: const [],
        template: const AvDeviceTemplate(model: 'NEW-1', ports: []),
        config: const {},
        swappedOn: DateTime(2026, 6, 15),
        swapReason: 'room refresh',
      );
      expect(plan.node.model, 'NEW-1');
      expect(plan.node.installedOn, DateTime(2026, 6, 15));
      expect(plan.node.swaps.single.model, 'OLD-1');
    });

    test('re-picking the model already under the box changes no dates', () {
      // A correction, not a replacement: nothing was unplugged.
      final node = box('a', model: 'OLD-1', installedOn: DateTime(2016, 4, 1));
      final plan = planModelSwap(
        node: node,
        cables: const [],
        template: const AvDeviceTemplate(model: 'old-1', ports: []),
        config: const {},
        swappedOn: DateTime(2026, 6, 15),
      );
      expect(plan.node.installedOn, DateTime(2016, 4, 1));
      expect(plan.node.swaps, isEmpty);
    });

    test('the history is on the room sheet, with how long each one lasted', () {
      final room = buildRoomLifecycle(
        model: roomOf([
          box(
            'a',
            installedOn: DateTime(2024, 1, 1),
            swaps: [
              EquipmentSwap(
                model: 'OLD-1',
                installedOn: DateTime(2016, 1, 1),
                removedOn: DateTime(2024, 1, 1),
                reason: 'lamp failure',
              ),
            ],
          ),
        ]),
        asOf: asOf,
      );
      final section = roomLifecycleSections(room)
          .firstWhere((s) => s.title == 'Equipment Replaced Before');
      expect(section.rows.single, containsAll(<dynamic>['OLD-1', '8 years']));
    });
  });

  // -------------------------------------------------------------------------
  //  THE FILE
  // -------------------------------------------------------------------------

  group('the config file', () {
    test('carries the install date, the life and the history', () {
      final node = box(
        'a',
        installedOn: DateTime(2019, 7, 4),
        lifeYears: 6,
        swaps: [
          EquipmentSwap(
            model: 'OLD-1',
            installedOn: DateTime(2011, 1, 2),
            removedOn: DateTime(2019, 7, 4),
          ),
        ],
      );
      final round = AvNode.fromJson(
        jsonDecode(jsonEncode(node.toJson())) as Map<String, dynamic>,
      );
      expect(round.installedOn, DateTime(2019, 7, 4));
      expect(round.lifeYears, 6);
      expect(round.swaps.single.model, 'OLD-1');
      expect(round.swaps.single.removedOn, DateTime(2019, 7, 4));
    });

    test('a box that was never dated writes none of it', () {
      final json = box('a').toJson();
      expect(json.containsKey('installedOn'), isFalse);
      expect(json.containsKey('lifeYears'), isFalse);
      expect(json.containsKey('swaps'), isFalse);
    });

    test('a room saved before this existed reads as undated', () {
      final round = AvNode.fromJson({'id': 'a', 'label': 'a', 'ports': []});
      expect(round.installedOn, isNull);
      expect(round.lifeYears, 0);
      expect(round.swaps, isEmpty);
    });

    test('the dates survive copyWith, and clearing is its own answer', () {
      final node = box('a', installedOn: DateTime(2019, 7, 4), lifeYears: 6);
      expect(node.copyWith(label: 'b').installedOn, DateTime(2019, 7, 4));
      expect(node.copyWith(clearInstalledOn: true).installedOn, isNull);
      expect(node.withId('z').installedOn, DateTime(2019, 7, 4));
      expect(node.withId('z').lifeYears, 6);
    });
  });

  // -------------------------------------------------------------------------
  //  THE BUILDING
  // -------------------------------------------------------------------------

  group('the building sheet', () {
    BuildingLifecycle building() => buildBuildingLifecycle(
      rooms: [
        buildRoomLifecycle(
          model: roomOf([box('a', installedOn: DateTime(2016, 1, 1))]),
          roomName: 'BSS 101',
          asOf: asOf,
        ),
        buildRoomLifecycle(
          model: roomOf([box('b', installedOn: DateTime(2024, 1, 1))]),
          roomName: 'BSS 103',
          asOf: asOf,
        ),
      ],
      asOf: asOf,
    );

    test('counts rooms and items separately', () {
      final b = building();
      expect(b.rooms, hasLength(2));
      expect(b.items, hasLength(2));
      expect(b.roomsOf(EquipmentCondition.overdue), 1); // 2016 + 8 = 2024
      expect(b.roomsOf(EquipmentCondition.good), 1);
    });

    test('the year columns span install to due, and always include today', () {
      final years = building().years();
      expect(years.first, 2016);
      expect(years.last, 2032); // 2024 + 8
      expect(years, contains(2026));
    });

    test('one very old item does not stretch the grid across thirty columns',
        () {
      final b = buildBuildingLifecycle(
        rooms: [
          buildRoomLifecycle(
            model: roomOf([box('ancient', installedOn: DateTime(1998, 1, 1))]),
            roomName: 'BSS 101',
            asOf: asOf,
          ),
        ],
        asOf: asOf,
      );
      expect(b.years(maxColumns: 12).first, 2014);
    });

    test('a building nobody has surveyed writes no sheet', () {
      final b = buildBuildingLifecycle(
        rooms: [
          buildRoomLifecycle(
            model: roomOf([box('a'), box('b')]),
            roomName: 'BSS 101',
            asOf: asOf,
          ),
        ],
        asOf: asOf,
      );
      expect(b.anyDated, isFalse);
      expect(buildingLifecycleSections(b), isEmpty);
    });

    test('the grid carries the money in the year it falls due', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(const AvDeviceTemplate(model: 'PROJ-1', price: 4200, ports: []));
      final b = buildBuildingLifecycle(
        rooms: [
          buildRoomLifecycle(
            model: roomOf([box('a', installedOn: DateTime(2020, 1, 1))]),
            roomName: 'BSS 101',
            library: library,
            asOf: asOf,
          ),
        ],
        asOf: asOf,
        currency: r'$',
      );
      expect(b.costDueIn(2028), 4200);
      expect(b.costDueIn(2027), 0);

      final grid = buildingLifecycleSections(b)
          .firstWhere((s) => s.title == 'Replacement Year Grid');
      final years = b.years();
      final row = grid.rows.first;
      // Column 0 is the room name; the rest line up with the year headings.
      expect(row.first, 'BSS 101');
      expect(row[1 + years.indexOf(2020)], '1');
      expect(row[1 + years.indexOf(2024)], '5');
      expect(row[1 + years.indexOf(2028)], r'$4,200');
    });
  });

  group('how it reads', () {
    test('an age is whole years, in words', () {
      expect(formatEquipmentAge(0.4), 'this year');
      expect(formatEquipmentAge(1.9), '1 year');
      expect(formatEquipmentAge(11.2), '11 years');
    });

    test('money is grouped and has no cents on it', () {
      expect(formatLifecycleMoney(4200, r'$'), r'$4,200');
      expect(formatLifecycleMoney(1234567.4, r'$'), r'$1,234,567');
      expect(formatLifecycleMoney(0, r'$'), '');
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT THE ROOM COSTS IF IT IS DONE IN A GIVEN YEAR
  // -------------------------------------------------------------------------
  //  A room with two dates is not two separate budget requests. The 2022 money
  //  is still owed in 2026 unless somebody spent it, so the room's own row on
  //  the plan carries the RUNNING total and the lines under it carry what each
  //  date adds. Reading the columns as separate asks is how a refresh gets
  //  approved at half its cost and comes back for the rest two years later.

  group('the running total for a room', () {
    RoomLifecycle phased() => buildRoomLifecycle(
      model: roomOf([
        // Eight-year cycle: 2014 + 8 = 2022, 2018 + 8 = 2026.
        box('DISPLAYDEVICE_1', model: 'DISP-1', installedOn: DateTime(2014, 5, 1)),
        box('PROJECTORDEVICE_1', model: 'PROJ-1', installedOn: DateTime(2018, 5, 1)),
      ]),
      library: AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(model: 'DISP-1', price: 2499, ports: []),
        )
        ..upsert(
          const AvDeviceTemplate(model: 'PROJ-1', price: 4173, ports: []),
        ),
      asOf: asOf,
    );

    test('each date still says what it adds on its own', () {
      final room = phased();
      expect(room.dueGroups.map((g) => g.dueYear), [2022, 2026]);
      expect(room.costDueIn(2022), 2499);
      expect(room.costDueIn(2026), 4173);
    });

    test('the room carries everything owed by that year', () {
      final room = phased();
      expect(room.costDueBy(2021), 0);
      expect(room.costDueBy(2022), 2499);
      // The one the whole change is about: 4,173 lands in 2026 and 2,499 is
      // still owed from 2022, so doing the room that year costs both.
      expect(room.costDueBy(2026), 2499 + 4173);
      // And it does not keep growing after the last date.
      expect(room.costDueBy(2030), 2499 + 4173);
    });

    test('the items behind the figure are the ones owed by then', () {
      final room = phased();
      expect(room.dueBy(2021), isEmpty);
      expect(room.dueBy(2022).map((i) => i.node.id), ['DISPLAYDEVICE_1']);
      expect(
        room.dueBy(2026).map((i) => i.node.id),
        containsAll(['DISPLAYDEVICE_1', 'PROJECTORDEVICE_1']),
      );
    });

    test('a room that falls due once reads the same either way', () {
      final room = buildRoomLifecycle(
        model: roomOf([
          box('PROJECTORDEVICE_1', installedOn: DateTime(2018, 5, 1)),
        ]),
        baseCosts: BaseCostBook(
          costs: const [BaseCost(category: 'Projector', price: 3000)],
        ),
        asOf: asOf,
      );
      expect(room.costDueIn(2026), 3000);
      expect(room.costDueBy(2026), 3000);
    });
  });
}
