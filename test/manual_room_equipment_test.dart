import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/manual_room_equipment.dart';

/// ============================================================================
///  WHAT IS IN A ROOM NOBODY HAS DRAWN
/// ============================================================================
///  Every line item on the refresh plan used to be a date, a life and a
///  figure, and the first question anybody asked about a red one — "what is
///  actually in there?" — had no answer on the screen it was asked on. The
///  survey of the control systems answers it, and this is what that answer is
///  held to.
///
///  THE TWO THINGS MOST WORTH BREAKING, and both are checked below:
///
///    * THE PLAN MUST NOT MOVE. A line item is ONE thing falling due. Give it
///      eleven surveyed boxes and it is still one thing falling due at the
///      estate's own figure — not eleven items at a total nobody costed. A
///      survey that quietly re-prices the plan is a budget request that no
///      longer matches the sheet it was approved from.
///
///    * AN ESTIMATE MUST SAY SO. Most of this estate is models the catalog
///      stopped carrying, so most of these figures come off the base-cost
///      card. A card figure that reads like a quote is how a budget goes
///      wrong quietly.
/// ============================================================================
void main() {
  ManualRoom room({
    List<ManualRoomItem> equipment = const [],
    double replacementCost = 24434.6,
  }) => ManualRoom(
    id: 'manual1',
    name: 'AGYM 129',
    installedOn: DateTime(2015, 7, 1),
    lifeYears: 8,
    replacementCost: replacementCost,
    equipment: equipment,
  );

  BaseCostBook card() => BaseCostBook(
    costs: [
      const BaseCost(
        category: 'Projector',
        price: 3000,
        educationPrice: 2500,
        standardModel: 'PT-VMZ62BU8',
      ),
      const BaseCost(category: 'Switcher', price: 13000, educationPrice: 7052.8),
      const BaseCost(category: 'Camera', price: 2048, educationPrice: 1600),
      const BaseCost(category: kRoomRefreshCategory, price: 19000),
    ],
  );

  AvDeviceLibrary catalogWith(List<AvDeviceTemplate> entries) {
    final library = AvDeviceLibrary.empty();
    for (final entry in entries) {
      library.upsert(entry);
    }
    return library;
  }

  // -------------------------------------------------------------------------
  group('a surveyed box survives a round trip', () {
    test('model, role and quantity all come back', () {
      final before = room(
        equipment: const [
          ManualRoomItem(
            model: 'Casio XJ-UT310WN',
            category: 'Projector',
            quantity: 2,
          ),
          ManualRoomItem(model: 'Epson DC11'),
        ],
      );

      final after = ManualRoom.fromJson(
        jsonDecode(jsonEncode(before.toJson())) as Map<String, dynamic>,
      );

      expect(after.equipment.length, 2);
      expect(after.equipment.first.model, 'Casio XJ-UT310WN');
      expect(after.equipment.first.category, 'Projector');
      expect(after.equipment.first.quantity, 2);
      // A role the base-cost card has no line for is a real answer, and an
      // absent one is one box rather than none.
      expect(after.equipment.last.category, isEmpty);
      expect(after.equipment.last.quantity, 1);
      expect(after.installedCount, 3);
    });

    test('a room nobody has surveyed writes no equipment key at all', () {
      expect(room().toJson().containsKey('equipment'), isFalse);
      expect(ManualRoom.fromJson(room().toJson()).equipment, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('the same price ladder a drawn room goes down', () {
    test('the catalog price for the model wins, and is not an estimate', () {
      final price = manualRoomItemPrice(
        const ManualRoomItem(
          model: 'PT-VMZ62BU8',
          category: 'Projector',
          quantity: 2,
        ),
        library: catalogWith([
          const AvDeviceTemplate(
            model: 'PT-VMZ62BU8',
            category: 'Projector',
            price: 4200,
            ports: [],
          ),
        ]),
        baseCosts: card(),
      );

      expect(price.unit, 4200);
      expect(price.line, 8400, reason: 'two of them');
      expect(price.estimated, isFalse);
      expect(price.pricedAs, isEmpty, reason: 'the figure is this box own');
    });

    test('a model the catalog never heard of falls to the card, marked', () {
      final price = manualRoomItemPrice(
        const ManualRoomItem(model: 'Casio XJ-UT310WN', category: 'Projector'),
        library: catalogWith(const []),
        baseCosts: card(),
      );

      expect(price.unit, 3000);
      expect(price.estimated, isTrue);
      // A typical figure with the model it was benchmarked on beside it is a
      // number somebody can argue with.
      expect(price.pricedAs, 'PT-VMZ62BU8');
    });

    test('a retired model is priced at what would actually be bought', () {
      final price = manualRoomItemPrice(
        const ManualRoomItem(
          model: 'DTP CrossPoint 84 IPCP SA',
          category: 'Switcher',
        ),
        library: catalogWith([
          const AvDeviceTemplate(
            model: 'DTP CrossPoint 84 IPCP SA',
            category: 'Switcher',
            retired: true,
            replacedBy: 'DTP CrossPoint 84 4K IPCP Q SA',
            ports: [],
          ),
          const AvDeviceTemplate(
            model: 'DTP CrossPoint 84 4K IPCP Q SA',
            category: 'Switcher',
            price: 9450,
            ports: [],
          ),
        ]),
        baseCosts: card(),
      );

      expect(price.unit, 9450);
      expect(price.estimated, isFalse);
      expect(
        price.pricedAs,
        'DTP CrossPoint 84 4K IPCP Q SA',
        reason: 'the row says what the figure is actually for',
      );
    });

    test('the card is asked in the catalog family words too', () {
      final price = manualRoomItemPrice(
        // The survey had no role for it; the catalog files it under what
        // Extron calls a switcher.
        const ManualRoomItem(model: 'DTP CrossPoint 108 4K IPCP MA 70'),
        library: catalogWith([
          const AvDeviceTemplate(
            model: 'DTP CrossPoint 108 4K IPCP MA 70',
            category: 'Matrix',
            ports: [],
          ),
        ]),
        baseCosts: card(),
      );

      expect(price.unit, 13000);
      expect(price.estimated, isTrue);
    });

    test('a box nothing can price reports as unpriced, not as free', () {
      final price = manualRoomItemPrice(
        const ManualRoomItem(model: 'Epson DC11'),
        library: catalogWith(const []),
        baseCosts: card(),
      );

      expect(price.unit, 0);
      expect(price.line, 0);
      expect(price.estimated, isFalse);
    });

    test('the tier the app is set to is the tier the survey is priced at', () {
      const item = ManualRoomItem(
        model: 'Casio XJ-UT310WN',
        category: 'Projector',
      );
      expect(
        manualRoomItemPrice(item, baseCosts: card(), tier: PricingTier.msrp).unit,
        3000,
      );
      expect(
        manualRoomItemPrice(
          item,
          baseCosts: card(),
          tier: PricingTier.education,
        ).unit,
        2500,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('a room adds up', () {
    test('what could not be priced is counted, not folded in as zero', () {
      final total = manualRoomEquipmentTotal(
        room(
          equipment: const [
            ManualRoomItem(
              model: 'Casio XJ-UT310WN',
              category: 'Projector',
              quantity: 2,
            ),
            ManualRoomItem(model: 'Epson DC11'),
            ManualRoomItem(model: 'EBP 108 RAAP', quantity: 2),
          ],
        ),
        baseCosts: card(),
      );

      expect(total.count, 5);
      expect(total.cost, 6000, reason: 'two projectors off the card');
      expect(total.unpriced, 3);
      expect(total.estimated, isTrue);
    });

    test('with no catalog and no card, everything reports unpriced', () {
      final total = manualRoomEquipmentTotal(
        room(
          equipment: const [
            ManualRoomItem(model: 'Casio XJ-UT310WN', category: 'Projector'),
          ],
        ),
      );
      expect(total.cost, 0);
      expect(total.unpriced, 1);
    });
  });

  // -------------------------------------------------------------------------
  group('the survey does not move the plan', () {
    test('eleven surveyed boxes are still ONE thing falling due', () {
      final surveyed = buildManualRoomLifecycle(
        room: room(
          equipment: [
            for (var i = 0; i < 11; i++)
              ManualRoomItem(model: 'Box $i', category: 'Projector'),
          ],
        ),
        baseCosts: card(),
        asOf: DateTime(2026, 6, 15),
      );
      final bare = buildManualRoomLifecycle(
        room: room(),
        baseCosts: card(),
        asOf: DateTime(2026, 6, 15),
      );

      expect(surveyed.items.length, 1);
      expect(surveyed.items.length, bare.items.length);
      expect(surveyed.refreshCost, bare.refreshCost);
      expect(
        surveyed.refreshCost,
        24434.6,
        reason: "the estate's own figure, not the survey priced at the card",
      );
      expect(surveyed.firstDueYear, bare.firstDueYear);
    });
  });

  // -------------------------------------------------------------------------
  group('a box reads as something a person can look for', () {
    test('a model that is a bare word gets its maker in front of it', () {
      expect(
        manualRoomItemLabel(
          const ManualRoomItem(model: 'Controller', category: 'Screen'),
          library: catalogWith([
            const AvDeviceTemplate(
              model: 'Controller',
              manufacturer: 'Da-Lite',
              category: 'Screen',
              ports: [],
            ),
          ]),
        ),
        'Da-Lite Controller',
      );
    });

    test('a model with a number in it identifies itself and is left alone', () {
      expect(
        manualRoomItemLabel(
          const ManualRoomItem(model: 'PT-VMZ62BU8', category: 'Projector'),
          library: catalogWith([
            const AvDeviceTemplate(
              model: 'PT-VMZ62BU8',
              manufacturer: 'Panasonic',
              category: 'Projector',
              ports: [],
            ),
          ]),
        ),
        'PT-VMZ62BU8',
        reason: 'the maker in front of every one of these is a column of noise',
      );
    });

    test('a model the catalog never heard of is shown as surveyed', () {
      expect(
        manualRoomItemLabel(const ManualRoomItem(model: 'Toggle')),
        'Toggle',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('the row says what is in there', () {
    test('rolled up by what the boxes do, most of it first', () {
      final phrase = manualRoomEquipmentSummary(
        room(
          equipment: const [
            ManualRoomItem(model: 'IPCP Pro 350M', category: 'Control processor'),
            ManualRoomItem(
              model: 'Casio XJ-UT310WN',
              category: 'Projector',
              quantity: 2,
            ),
            ManualRoomItem(model: 'Epson DC11'),
          ],
        ),
      );

      expect(phrase, 'in the room: 2 Projector, 1 Control processor, 1 Other');
    });

    test('a lecture hall is capped rather than run off the row', () {
      final phrase = manualRoomEquipmentSummary(
        room(
          equipment: const [
            ManualRoomItem(model: 'a', category: 'Projector'),
            ManualRoomItem(model: 'b', category: 'Switcher'),
            ManualRoomItem(model: 'c', category: 'Camera'),
            ManualRoomItem(model: 'd', category: 'DSP'),
            ManualRoomItem(model: 'e', category: 'Touch panel'),
            ManualRoomItem(model: 'f', category: 'Display'),
          ],
        ),
        most: 4,
      );

      expect(phrase, endsWith('+2 more'));
    });

    test('a room nobody has surveyed says nothing rather than nothing much', () {
      expect(manualRoomEquipmentSummary(room()), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  //  THE IMPORT ITSELF
  // -------------------------------------------------------------------------
  //  The estate's jobs are checked in, so what the importer actually wrote is
  //  a thing this suite can read rather than take on trust. Skipped rather
  //  than failed where the folder is absent: the app does not require anybody
  //  else's campus to be sitting beside it.
  group('the campus on disk', () {
    final folder = Directory('RYG campus');

    test('every line item parses, and the surveyed ones carry models', () {
      if (!folder.existsSync()) return;
      var lines = 0;
      var surveyed = 0;
      var boxes = 0;
      for (final file in folder.listSync().whereType<File>()) {
        if (!file.path.endsWith('_project.json')) continue;
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final project = BuildingProject.fromJson(json);
        for (final line in project.manualRooms) {
          lines++;
          if (line.equipment.isEmpty) continue;
          surveyed++;
          boxes += line.installedCount;
          for (final item in line.equipment) {
            expect(item.model.trim(), isNotEmpty, reason: line.name);
            expect(item.quantity, greaterThan(0), reason: line.name);
          }
        }
      }
      expect(lines, greaterThan(0));
      expect(
        surveyed,
        greaterThan(lines ~/ 2),
        reason: 'most of the estate is on a control system that was polled',
      );
      expect(boxes, greaterThan(surveyed));
    });
  });
}
