import 'dart:convert';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
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
}
