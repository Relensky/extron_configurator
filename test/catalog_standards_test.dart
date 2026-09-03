import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/catalog_standards.dart';

/// ============================================================================
///  WHAT THE ESTATE IS PRICED ON
/// ============================================================================
///  Every figure the project and campus reports fall back to comes off one
///  line of the base-cost card, and each of those lines can name the model it
///  was benchmarked on. The question this answers is asked once a year, of the
///  whole card at once: is anything here still benchmarked on a product we
///  cannot buy?
///
///  What is held here, and both matter more than the arithmetic:
///
///    * A LINE ALREADY ON A CURRENT MODEL IS NEVER PROPOSED AGAINST. Setting
///      eighteen categories re-prices four hundred rooms; doing it to a line
///      that was already right, because a price list moved, is a plan that
///      changed under somebody who did not ask it to.
///
///    * THE PROPOSAL IS THE DEAREST CURRENT MODEL, not the cheapest. A base
///      cost is what a room done properly comes to, and benchmarking an estate
///      on the cheapest thing in the aisle is how a budget comes in short in
///      the one direction nobody checks.
/// ============================================================================
void main() {
  final asOf = DateTime(2026, 9, 3);

  AvDeviceLibrary catalogWith(List<AvDeviceTemplate> entries) {
    final library = AvDeviceLibrary.empty();
    for (final entry in entries) {
      library.upsert(entry);
    }
    return library;
  }

  AvDeviceTemplate projector(
    String model, {
    double price = 0,
    bool retired = false,
    String replacedBy = '',
  }) => AvDeviceTemplate(
    model: model,
    category: 'Projector',
    price: price,
    retired: retired,
    replacedBy: replacedBy,
    ports: const [],
  );

  group('reading the card against the catalog', () {
    test('a benchmark the catalog has retired follows its own successor', () {
      final rows = readCategoryStandards(
        card: BaseCostBook(
          costs: [
            const BaseCost(
              category: 'Projector',
              price: 3000,
              standardModel: 'PT-VMZ60U',
            ),
          ],
        ),
        library: catalogWith([
          projector('PT-VMZ60U', retired: true, replacedBy: 'PT-VMZ62BU8'),
          projector('PT-VMZ62BU8', price: 4200),
          projector('Something dearer', price: 9000),
        ]),
        asOf: asOf,
      );

      final row = rows.single;
      expect(row.stale, isTrue);
      expect(row.because, 'retired');
      expect(
        row.proposed?.model,
        'PT-VMZ62BU8',
        reason: 'the successor is the answer the catalog already gives',
      );
    });

    test('a line with nothing set takes the dearest current model', () {
      final rows = readCategoryStandards(
        card: BaseCostBook(
          costs: [const BaseCost(category: 'Projector', price: 3000)],
        ),
        library: catalogWith([
          projector('cheap', price: 1200),
          projector('proper', price: 4200),
          projector('retired and dearest', price: 9000, retired: true),
        ]),
        asOf: asOf,
      );

      final row = rows.single;
      expect(row.stale, isFalse, reason: 'unset is not the same as wrong');
      expect(row.because, 'nothing set');
      expect(row.proposed?.model, 'proper');
    });

    test('a benchmark the catalog has never heard of is stale, not silent', () {
      final rows = readCategoryStandards(
        card: BaseCostBook(
          costs: [
            const BaseCost(
              category: 'Projector',
              price: 3000,
              standardModel: 'whatever Dave typed in 2021',
            ),
          ],
        ),
        library: catalogWith([projector('proper', price: 4200)]),
        asOf: asOf,
      );

      expect(rows.single.stale, isTrue);
      expect(rows.single.because, 'not in the catalog');
    });

    test('a line already on a current model is left entirely alone', () {
      final rows = readCategoryStandards(
        card: BaseCostBook(
          costs: [
            const BaseCost(
              category: 'Projector',
              price: 4200,
              standardModel: 'proper',
            ),
          ],
        ),
        library: catalogWith([
          projector('proper', price: 4200),
          projector('dearer', price: 9000),
        ]),
        asOf: asOf,
      );

      expect(rows.single.stale, isFalse);
      expect(
        rows.single.proposed,
        isNull,
        reason: 're-pricing a right answer is a decision, not a tidy-up',
      );
    });

    test('an entry with no price cannot be a benchmark', () {
      final rows = readCategoryStandards(
        card: BaseCostBook(costs: [const BaseCost(category: 'Projector')]),
        library: catalogWith([projector('no price at all')]),
        asOf: asOf,
      );
      expect(rows.single.proposed, isNull);
    });
  });

  group('which lines are worth pointing at', () {
    test('nothing set, gone from the catalog, or set a long time ago', () {
      final card = BaseCostBook(
        costs: [
          const BaseCost(category: 'Projector'),
          BaseCost(
            category: 'Switcher',
            price: 9000,
            standardModel: 'current',
            standardSetOn: asOf.subtract(const Duration(days: 30)),
          ),
          BaseCost(
            category: 'Camera',
            price: 2000,
            standardModel: 'current',
            standardSetOn: DateTime(2019, 1, 1),
          ),
        ],
      );
      final rows = readCategoryStandards(
        card: card,
        library: catalogWith([
          const AvDeviceTemplate(
            model: 'current',
            category: 'Switcher',
            price: 9000,
            ports: [],
          ),
        ]),
        asOf: asOf,
      );

      final byName = {for (final r in rows) r.category: r};
      expect(standardNeedsLooking(byName['Projector']!, asOf), isTrue);
      expect(standardNeedsLooking(byName['Switcher']!, asOf), isFalse);
      expect(
        standardNeedsLooking(byName['Camera']!, asOf),
        isTrue,
        reason: 'benchmarked on a name the catalog cannot find, and seven '
            'years old',
      );
    });
  });

  test('applying a proposal writes both tiers and the day', () {
    final rows = readCategoryStandards(
      card: BaseCostBook(costs: [const BaseCost(category: 'Projector')]),
      library: catalogWith([
        const AvDeviceTemplate(
          model: 'proper',
          category: 'Projector',
          price: 4200,
          educationPrice: 3100,
          ports: [],
        ),
      ]),
      asOf: asOf,
    );

    final written = standardApplied(
      rows.single,
      rows.single.proposed!,
      setOn: asOf,
    );

    expect(written.category, 'Projector');
    expect(written.price, 4200);
    expect(
      written.educationPrice,
      3100,
      reason: 'a card with one price has every estimate at the other tier '
          'reading high or low depending on which way the job went',
    );
    expect(written.standardModel, 'proper');
    expect(written.standardSetOn, asOf);
  });

  test('the card reads as a sentence somebody can act on', () {
    final rows = readCategoryStandards(
      card: BaseCostBook(
        costs: [
          const BaseCost(category: 'Projector'),
          const BaseCost(
            category: 'Switcher',
            price: 9000,
            standardModel: 'gone',
          ),
        ],
      ),
      library: catalogWith([
        const AvDeviceTemplate(
          model: 'gone',
          category: 'Switcher',
          price: 9000,
          retired: true,
          ports: [],
        ),
      ]),
      asOf: asOf,
    );

    final said = describeCategoryStandards(rows, asOf);
    expect(said, contains('2 categories'));
    expect(said, contains('1 on a product that is gone'));
    expect(said, contains('1 with nothing set'));
  });
}
