import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/model_standards.dart';

/// ============================================================================
///  A RETIRED PRICE IS THE WRONG PRICE, AND IT IS WRONG SILENTLY
/// ============================================================================
///  Retiring a catalog entry kept it out of the pickers, which is right, and
///  left every room already holding one being budgeted at the list price of a
///  product nobody can buy. On a four-year refresh plan for forty rooms that is
///  the entire budget, wrong by whatever the successor went up by, with nothing
///  on any screen saying so - because the figure was a real price for a real
///  catalog entry.
void main() {
  /// A room holding nothing but the boxes given - the whole model this reading
  /// needs, and nothing else it does not.
  AvFlowModel roomOf(List<AvNode> nodes) => AvFlowModel(
    nodes: nodes,
    cables: const [],
    racks: const [],
    rackSlots: const {},
    rackItems: const [],
    canvasSize: Size.zero,
    roomTitle: 'Test Room',
    unplaced: const [],
  );

  AvNode node(String id, String model) => AvNode(
    id: id,
    label: id,
    model: model,
    pos: Offset.zero,
    ports: const [],
    installedOn: DateTime(2018, 6, 1),
  );

  /// A catalog where the 2016 projector was replaced by the 2020 one, which
  /// was replaced by this year's.
  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 4000,
        educationPrice: 3400,
        retired: true,
        replacedBy: 'PowerLite L730U',
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'PowerLite L730U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 5200,
        educationPrice: 4400,
        retired: true,
        replacedBy: 'PowerLite L775U',
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'PowerLite L775U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 6100,
        educationPrice: 5200,
        ports: [],
      ),
    );

  // -------------------------------------------------------------------------
  //  FOLLOWING THE CHAIN
  // -------------------------------------------------------------------------

  group('what you would actually buy', () {
    test('a current model is its own successor', () {
      final library = catalog();
      expect(library.successorFor('PowerLite L775U')?.model, 'PowerLite L775U');
      expect(library.hasSuccessor('PowerLite L775U'), isFalse);
    });

    test('a retired one resolves to the end of the chain, not one hop', () {
      // A 2016 model replaced by a 2020 one replaced by a 2024 one prices at
      // the 2024 one, because that is what the purchase order would say.
      final library = catalog();
      expect(library.successorFor('PowerLite L610U')?.model, 'PowerLite L775U');
      expect(library.hasSuccessor('PowerLite L610U'), isTrue);
    });

    test('a name the catalog has never heard of is not a successor', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: 'Old One',
            category: 'Projector',
            price: 1000,
            retired: true,
            replacedBy: 'A Model Nobody Entered',
            ports: [],
          ),
        );
      // The chain stops on the retired entry, whose own price is still the
      // best figure anybody has - never a crash and never a zero.
      expect(library.successorFor('Old One')?.model, 'Old One');
      expect(library.hasSuccessor('Old One'), isFalse);
    });

    test('a loop stops rather than spinning', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: 'A',
            category: 'Projector',
            price: 100,
            retired: true,
            replacedBy: 'B',
            ports: [],
          ),
        )
        ..upsert(
          const AvDeviceTemplate(
            model: 'B',
            category: 'Projector',
            price: 200,
            retired: true,
            replacedBy: 'A',
            ports: [],
          ),
        );
      expect(library.successorFor('A')?.model, isNotNull);
      expect(library.successorFor('B')?.model, isNotNull);
    });

    test('a model that is not in the catalog at all has no successor', () {
      expect(catalog().successorFor('Something Else'), isNull);
      expect(catalog().hasSuccessor('Something Else'), isFalse);
    });

    test('it survives a save and a reload', () {
      const template = AvDeviceTemplate(
        model: 'Old',
        category: 'Projector',
        retired: true,
        replacedBy: 'New',
        ports: [],
      );
      final back = AvDeviceTemplate.fromJson(template.toJson());
      expect(back.replacedBy, 'New');
      expect(back.retired, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT THE PLAN BUDGETS
  // -------------------------------------------------------------------------

  group('a retired position is budgeted at its replacement', () {
    RoomLifecycle aged({AvDeviceLibrary? library, BaseCostBook? card}) =>
        buildRoomLifecycle(
          model: roomOf([node('PROJECTORDEVICE_1', 'PowerLite L610U')]),
          library: library ?? catalog(),
          baseCosts: card,
          asOf: DateTime(2026, 1, 1),
        );

    test('the figure is the successor\'s, not the discontinued one\'s', () {
      final room = aged();
      final item = room.items.single;
      expect(
        item.replacementCost,
        6100,
        reason: 'the L610U lists at 4,000 and nobody can buy one',
      );
      expect(item.costIsEstimate, isFalse);
    });

    test('and the row says whose price it is', () {
      final item = aged().items.single;
      expect(item.replacementModel, 'PowerLite L775U');
      expect(
        item.replacedByAnother,
        isTrue,
        reason: 'a replacement cost that is not this model\'s has to say so',
      );
    });

    test('a current model prices at its own, and names nothing', () {
      final room = buildRoomLifecycle(
        model: roomOf([node('PROJECTORDEVICE_1', 'PowerLite L775U')]),
        library: catalog(),
        asOf: DateTime(2026, 1, 1),
      );
      final item = room.items.single;
      expect(item.replacementCost, 6100);
      expect(
        item.replacementModel,
        isEmpty,
        reason: 'naming it on the ordinary row repeats what the row says',
      );
      expect(item.replacedByAnother, isFalse);
    });

    test('without the library it prices exactly as it always did', () {
      // The feature is off without a catalog to follow the chain through, and
      // a caller that only has a template still gets the old answer.
      final price = equipmentReplacementPrice(
        node: node('PROJECTORDEVICE_1', 'PowerLite L610U'),
        template: catalog().templateForModel('PowerLite L610U'),
      );
      expect(price.cost, 4000);
      expect(price.model, isEmpty);
    });

    test('a retired entry naming nothing keeps its own price', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: 'PowerLite L610U',
            category: 'Projector',
            price: 4000,
            retired: true,
            ports: [],
          ),
        );
      final item = aged(library: library).items.single;
      expect(item.replacementCost, 4000);
      expect(item.replacementModel, isEmpty);
    });

    test('the education tier follows the successor too', () {
      final room = buildRoomLifecycle(
        model: roomOf([node('PROJECTORDEVICE_1', 'PowerLite L610U')]),
        library: catalog(),
        tier: PricingTier.education,
        asOf: DateTime(2026, 1, 1),
      );
      expect(room.items.single.replacementCost, 5200);
    });

    test('a base card figure names what the card was benchmarked on', () {
      // A position with no catalog price at all falls to the card, and the
      // card can say which product it assumes - see [BaseCost.standardModel].
      final card = BaseCostBook(costs: [
        BaseCost(
          category: 'Projector',
          price: 4200,
          standardModel: 'PowerLite L775U',
          standardSetOn: DateTime(2026, 1, 1),
        ),
      ]);
      final room = buildRoomLifecycle(
        model: roomOf([node('PROJECTORDEVICE_1', 'Unknown Box')]),
        library: AvDeviceLibrary.empty(),
        baseCosts: card,
        asOf: DateTime(2026, 1, 1),
      );
      final item = room.items.single;
      expect(item.replacementCost, 4200);
      expect(item.costIsEstimate, isTrue);
      expect(item.replacementModel, 'PowerLite L775U');
    });
  });

  // -------------------------------------------------------------------------
  //  THE BENCHMARK ON THE CARD
  // -------------------------------------------------------------------------

  group('the base card records what it was priced on', () {
    test('it survives a save and a reload', () {
      final card = BaseCost(
        category: 'Projector',
        price: 6100,
        standardModel: 'PowerLite L775U',
        standardSetOn: DateTime(2026, 3, 4),
      );
      final back = BaseCost.fromJson(card.toJson());
      expect(back.standardModel, 'PowerLite L775U');
      expect(back.standardSetOn, DateTime(2026, 3, 4));
    });

    test('its age is whole years, and never negative', () {
      final card = BaseCost(
        category: 'Projector',
        standardSetOn: DateTime(2024, 6, 1),
      );
      expect(card.standardAgeYears(DateTime(2026, 5, 31)), 1);
      expect(card.standardAgeYears(DateTime(2026, 6, 1)), 2);
      // A card dated in the future is somebody's typo, not a negative age.
      expect(card.standardAgeYears(DateTime(2020, 1, 1)), 0);
    });

    test('a card nobody benchmarked has no age', () {
      expect(
        const BaseCost(category: 'Projector', price: 4200)
            .standardAgeYears(DateTime(2026, 1, 1)),
        isNull,
      );
    });

    test('editing a price leaves the benchmark alone unless asked', () {
      final card = BaseCost(
        category: 'Projector',
        price: 6100,
        standardModel: 'PowerLite L775U',
        standardSetOn: DateTime(2026, 3, 4),
      );
      expect(card.copyWith(price: 6300).standardModel, 'PowerLite L775U');
      expect(card.copyWith(clearStandard: true).standardModel, isEmpty);
      expect(card.copyWith(clearStandard: true).standardSetOn, isNull);
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT WE WOULD BUY THIS YEAR
  // -------------------------------------------------------------------------

  group('the current-models reading', () {
    List<EquipmentLife> estate(AvDeviceLibrary library) => [
      for (final (id, model) in [
        ('PROJECTORDEVICE_1', 'PowerLite L610U'),
        ('PROJECTORDEVICE_2', 'PowerLite L610U'),
        ('PROJECTORDEVICE_3', 'PowerLite L775U'),
        ('SWITCHERDEVICE_1', 'DTP Switcher'),
      ])
        ...buildRoomLifecycle(
          model: roomOf([node(id, model)]),
          library: library,
          asOf: DateTime(2026, 1, 1),
        ).items,
    ];

    AvDeviceLibrary withSwitcher() => catalog()
      ..upsert(
        const AvDeviceTemplate(
          model: 'DTP Switcher',
          manufacturer: 'Extron',
          category: 'Switcher',
          price: 2000,
          ports: [],
        ),
      );

    test('one row per kind of thing, biggest budget first', () {
      final library = withSwitcher();
      final rows = modelStandardsFor(
        items: estate(library),
        asOf: DateTime(2026, 1, 1),
        library: library,
      );
      expect(rows.map((r) => r.category), ['Projector', 'Switcher']);
      expect(rows.first.positions, 3);
      // Two retired L610Us priced at the successor's 6,100, plus one L775U.
      expect(rows.first.budgetedNow, 6100 * 3);
    });

    test('it says how many positions hold discontinued gear', () {
      final library = withSwitcher();
      final rows = modelStandardsFor(
        items: estate(library),
        asOf: DateTime(2026, 1, 1),
        library: library,
      );
      expect(rows.first.retiredPositions, 2);
      // Commonest model first, which is how a decision gets made off the list.
      expect(rows.first.models.first.model, 'PowerLite L610U');
      expect(rows.first.models.first.count, 2);
    });

    test('the estate at a chosen model, against what the plan budgets', () {
      final quote = quoteAtStandard(
        positions: 41,
        unitPrice: 6100,
        budgetedNow: 172400,
      );
      expect(quote.total, 250100);
      expect(
        quote.delta,
        250100 - 172400,
        reason: 'positive means the standard is DEARER than the plan assumes, '
            'which is the direction that fails at purchase order time',
      );
    });

    test('a category with no card at all wants a look', () {
      final library = withSwitcher();
      final rows = modelStandardsFor(
        items: estate(library),
        asOf: DateTime(2026, 1, 1),
        library: library,
      );
      expect(standardNeedsAttention(rows.first), isTrue);
    });

    test('a fresh benchmark with nothing retired does not', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: 'PowerLite L775U',
            category: 'Projector',
            price: 6100,
            ports: [],
          ),
        );
      final card = BaseCostBook(costs: [
        BaseCost(
          category: 'Projector',
          price: 6100,
          standardModel: 'PowerLite L775U',
          standardSetOn: DateTime(2026, 1, 1),
        ),
      ]);
      final rows = modelStandardsFor(
        items: buildRoomLifecycle(
          model: roomOf([node('PROJECTORDEVICE_1', 'PowerLite L775U')]),
          library: library,
          baseCosts: card,
          asOf: DateTime(2026, 1, 1),
        ).items,
        asOf: DateTime(2026, 1, 1),
        library: library,
        baseCosts: card,
      );
      expect(standardNeedsAttention(rows.single), isFalse);
    });

    test('a benchmark older than the stale window wants a look again', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: 'PowerLite L775U',
            category: 'Projector',
            price: 6100,
            ports: [],
          ),
        );
      final card = BaseCostBook(costs: [
        BaseCost(
          category: 'Projector',
          price: 6100,
          standardModel: 'PowerLite L775U',
          standardSetOn: DateTime(2026, 1, 1),
        ),
      ]);
      final rows = modelStandardsFor(
        items: buildRoomLifecycle(
          model: roomOf([node('PROJECTORDEVICE_1', 'PowerLite L775U')]),
          library: library,
          baseCosts: card,
          asOf: DateTime(2026, 1, 1),
        ).items,
        // Read three years later. The figure was right once.
        asOf: DateTime(2029, 1, 1),
        library: library,
        baseCosts: card,
      );
      expect(rows.single.standardAgeYears, 3);
      expect(standardNeedsAttention(rows.single), isTrue);
    });

    test('a category the estate has nothing in is not on the list', () {
      final library = withSwitcher();
      final card = BaseCostBook(costs: const [
        BaseCost(category: 'Camera', price: 3000),
      ]);
      final rows = modelStandardsFor(
        items: estate(library),
        asOf: DateTime(2026, 1, 1),
        library: library,
        baseCosts: card,
      );
      expect(
        rows.map((r) => r.category),
        isNot(contains('Camera')),
        reason: 'a tab listing the families nobody uses buries the answer in '
            'blanks',
      );
    });
  });
}
