import 'av_device_library.dart';
import 'base_costs.dart';
import 'campus_lifecycle.dart';
import 'equipment_lifecycle.dart';

/// ============================================================================
///  WHAT WE WOULD BUY THIS YEAR
/// ============================================================================
///  A refresh plan is a list of years and a pile of money, and the money comes
///  from one number per kind of thing: what a projector costs, what a switcher
///  costs, what an interface costs. Those numbers were typed onto the base cost
///  card once, by somebody, with nothing recorded about WHICH projector at what
///  spec in which year - and then a forty-room estate was budgeted off them for
///  four years running.
///
///  Two ways that goes wrong, both quietly:
///
///    THE NUMBER GOES STALE. It was right in 2022. Nobody re-typed it, nothing
///    on the screen was older than anything else, and the 2026 plan is short by
///    four years of price rises across every room on the estate.
///
///    THE NUMBER CANNOT BE ARGUED WITH. A finance office asked to approve
///    eleven projectors wants to know what they are eleven OF. "About 4,200"
///    is not a specification, and the person who knew what it meant has left.
///
///  So this is the arithmetic behind a tab that answers both. For every kind of
///  thing the estate actually holds it says: how many there are, which models
///  they are, what the plan presently budgets them at, and - once somebody
///  picks this year's model out of the catalog - what the same estate would
///  come to at that. Setting it writes the model, the price and the DATE onto
///  the base card, which is the card the room cost page, the project report and
///  the campus report all already price from.
///
///  NOTHING HERE DECIDES ANYTHING. It is a comparison somebody reads and a
///  figure they choose to accept; the tab that shows it is the one place on the
///  estate where "what does a projector cost" is a question with a visible
///  answer rather than a number in a file.
/// ============================================================================

/// One model, and how many of it the estate holds.
typedef InstalledModel = ({String model, int count});

/// One kind of thing on the estate, with what it is budgeted at now and what it
/// would be budgeted at on a chosen current model.
typedef ModelStandard = ({
  /// 'Projector', 'Switcher', 'Interface' - the base card's own category, and
  /// the category every position here resolved to. See [EquipmentLife.category].
  String category,

  /// How many positions on the estate are this kind of thing.
  int positions,

  /// How many of those the plan can put a figure against at all. The rest are
  /// unpriced - no catalog price and no card - and are the reason a total can
  /// be honest about what it is missing.
  int priced,

  /// What the plan presently budgets all of them at, added up off the rows
  /// themselves. THE FIGURE ON THE SHEET, not a recomputation of it: if this
  /// disagreed with the year grid, one of the two would be lying.
  double budgetedNow,

  /// Which models are actually in them, commonest first.
  List<InstalledModel> models,

  /// How many of those positions hold a model the catalog has retired. The
  /// number that makes the case for re-benchmarking on its own - see
  /// [AvDeviceTemplate.replacedBy].
  int retiredPositions,

  /// The base card this category prices from, when there is one.
  BaseCost? card,

  /// The catalog entry the card is currently benchmarked on - see
  /// [BaseCost.standardModel]. Null when nobody has set one, or when the name
  /// on the card no longer resolves.
  AvDeviceTemplate? standard,

  /// How many whole years ago the benchmark was set. Null when there is none.
  int? standardAgeYears,
});

/// What one estate would come to if [positions] of something were bought at
/// [unitPrice] - the comparison the tab is read for.
typedef StandardQuote = ({
  int positions,
  double unitPrice,
  double total,

  /// [total] against what the plan budgets today. Positive means the standard
  /// is DEARER than the plan assumes, which is the direction that matters: a
  /// budget short by this much is a budget that fails at purchase order time.
  double delta,
});

/// [positions] of something at [unitPrice], against [budgetedNow].
StandardQuote quoteAtStandard({
  required int positions,
  required double unitPrice,
  required double budgetedNow,
}) {
  final total = positions * unitPrice;
  return (
    positions: positions,
    unitPrice: unitPrice,
    total: total,
    delta: total - budgetedNow,
  );
}

/// Every kind of thing on [campus], with what it is budgeted at and what it is
/// benchmarked on.
///
/// SORTED BY WHAT IS AT STAKE - the money the plan has riding on the category,
/// biggest first. A campus holds four hundred positions in twenty categories
/// and the two that matter are the ones the budget is mostly made of; sorting
/// alphabetically would put 'Amplifier' above 'Projector' on every estate in
/// the world.
///
/// CATEGORIES WITH NOTHING IN THEM ARE NOT HERE. The base card ships with every
/// family this app knows and most estates use a third of them; a tab listing
/// the other two thirds is a tab where the answer is buried in blanks.
List<ModelStandard> campusModelStandards({
  required CampusLifecycle campus,
  AvDeviceLibrary? library,
  BaseCostBook? baseCosts,
}) => modelStandardsFor(
  items: campus.items,
  asOf: campus.asOf,
  library: library,
  baseCosts: baseCosts,
);

/// The same reading over any pile of aged positions — one building's, or a
/// whole estate's.
///
/// Split out from [campusModelStandards] so a single project can show the same
/// tab off [BuildingLifecycle.items] without a campus having to be assembled
/// first.
List<ModelStandard> modelStandardsFor({
  required List<EquipmentLife> items,
  required DateTime asOf,
  AvDeviceLibrary? library,
  BaseCostBook? baseCosts,
}) {
  // Keyed case-insensitively, because 'projector' and 'Projector' are one kind
  // of thing and a report that split them would be a report saying the estate
  // holds half as many of each.
  final byKey = <String, List<EquipmentLife>>{};
  final spelling = <String, String>{};
  for (final item in items) {
    final name = item.category.trim();
    if (name.isEmpty) continue;
    final key = name.toLowerCase();
    byKey.putIfAbsent(key, () => []).add(item);
    spelling.putIfAbsent(key, () => name);
  }

  final out = <ModelStandard>[];
  for (final entry in byKey.entries) {
    final rows = entry.value;
    final category = spelling[entry.key]!;

    final counts = <String, int>{};
    final modelSpelling = <String, String>{};
    var budgeted = 0.0;
    var priced = 0;
    var retired = 0;
    for (final row in rows) {
      budgeted += row.replacementCost;
      if (row.replacementCost > 0) priced++;

      final model = row.node.model.trim();
      if (model.isNotEmpty) {
        final key = model.toLowerCase();
        counts[key] = (counts[key] ?? 0) + 1;
        modelSpelling.putIfAbsent(key, () => model);
        if (library?.templateForModel(model)?.retired == true) retired++;
      }
    }

    final models = [
      for (final c in counts.entries)
        (model: modelSpelling[c.key]!, count: c.value),
    ]..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0
          ? byCount
          : a.model.toLowerCase().compareTo(b.model.toLowerCase());
    });

    final card = baseCosts?.byCategory(category);
    final benchmark = card?.standardModel.trim() ?? '';
    out.add((
      category: category,
      positions: rows.length,
      priced: priced,
      budgetedNow: budgeted,
      models: List.unmodifiable(models),
      retiredPositions: retired,
      card: card,
      standard: benchmark.isEmpty ? null : library?.templateForModel(benchmark),
      standardAgeYears: card?.standardAgeYears(asOf),
    ));
  }

  out.sort((a, b) {
    final byMoney = b.budgetedNow.compareTo(a.budgetedNow);
    if (byMoney != 0) return byMoney;
    final byCount = b.positions.compareTo(a.positions);
    return byCount != 0
        ? byCount
        : a.category.toLowerCase().compareTo(b.category.toLowerCase());
  });
  return out;
}

/// How stale a benchmark is allowed to get before the tab says so.
///
/// Two years. AV list prices move enough in that time that a plan built on a
/// three-year-old figure is wrong by more than the rounding anybody applies to
/// it, and a warning that fires in the first year would fire on every card
/// somebody had just set.
const int kStaleStandardYears = 2;

/// True when [standard] is worth re-visiting: the benchmark is old, or there is
/// none at all, or the estate is mostly holding discontinued gear.
///
/// ONE RULE, so the tab's badge and any report that lists them agree. A row
/// flagged on screen and quiet in the spreadsheet is a row nobody acts on.
bool standardNeedsAttention(ModelStandard standard) {
  if (standard.card == null || !standard.card!.isSet) return true;
  if (standard.standard == null) return true;
  final age = standard.standardAgeYears;
  if (age == null || age >= kStaleStandardYears) return true;
  return standard.retiredPositions > 0;
}
