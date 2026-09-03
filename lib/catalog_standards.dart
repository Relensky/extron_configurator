import 'av_device_library.dart' show AvDeviceLibrary, AvDeviceTemplate, PricingTier;
import 'base_costs.dart' show BaseCost, BaseCostBook;

/// ============================================================================
///  WHAT THE WHOLE ESTATE IS PRICED ON, IN ONE PLACE
/// ============================================================================
///  Every figure the project and campus reports fall back to comes off one
///  line of the base-cost card: what a projector costs, what a switcher costs,
///  what a touch panel costs. The card can name the MODEL each of those was
///  benchmarked on and the day it was set - see [BaseCost.standardModel] -
///  which is what turns "about 4,200" into a number a finance office can
///  argue with.
///
///  Setting them one at a time, off the campus report, is right when somebody
///  is reading that report and has an opinion about projectors. It is the
///  wrong shape entirely for the job this exists for: the start of a budget
///  year, eighteen categories, a new price list just imported, and one
///  question - "is anything on this card still benchmarked on a product we
///  cannot buy?"
///
///  So the card can be read and set AS A CARD, against the catalog, in one
///  pass. What is proposed for each line is not a guess:
///
///    * a benchmark the catalog has RETIRED follows its own successor chain,
///      because the successor is the answer the catalog already gives
///      everywhere else - see [AvDeviceLibrary.successorFor];
///    * a line with NO benchmark takes the dearest current model the catalog
///      files under that category, because a base cost is a typical figure for
///      a room being done properly and the cheapest thing in an aisle is not
///      what anybody specifies;
///    * a line already benchmarked on a current model is LEFT ALONE. Re-pricing
///      it because a price list moved is a decision, and it is one somebody
///      makes per line with the estate's own counts in front of them.
///
///  NOTHING HERE WRITES, and nothing here is applied without being shown. A
///  button that silently re-prices eighteen categories re-prices four hundred
///  rooms.
/// ============================================================================

/// One line of the card, read against the catalog.
typedef CategoryStandard = ({
  /// The card's own category - 'Projector'.
  String category,

  /// What it is benchmarked on now, or '' when nobody has said.
  String benchmark,

  /// The day that benchmark was set, or null.
  DateTime? setOn,

  /// True when the benchmark names a model the catalog has retired, or one it
  /// has never heard of. The line that makes the case for itself.
  bool stale,

  /// What the catalog would put here instead, or null when it has nothing to
  /// offer and nothing to correct.
  AvDeviceTemplate? proposed,

  /// Why [proposed] is being offered, for the reader: 'retired', 'not in the
  /// catalog', 'nothing set'. Empty when nothing is proposed.
  String because,
});

/// How old a benchmark is allowed to get before the card says so, in years.
///
/// Not a rule and not enforced anywhere: a card set on the right projector in
/// 2024 is still the right projector. It is the age at which the screen starts
/// pointing at it, which is the whole job of a date on a figure.
const int kStandardStaleYears = 2;

/// The card, read against the catalog. Nothing is written.
///
/// [asOf] only decides which lines report as old; it never changes what is
/// proposed.
List<CategoryStandard> readCategoryStandards({
  required BaseCostBook card,
  required AvDeviceLibrary library,
  DateTime? asOf,
}) {
  final out = <CategoryStandard>[];
  for (final cost in card.costs) {
    final category = cost.category.trim();
    if (category.isEmpty) continue;
    final benchmark = cost.standardModel.trim();
    final entry = benchmark.isEmpty
        ? null
        : library.templateForModel(benchmark);

    AvDeviceTemplate? proposed;
    var because = '';
    var stale = false;

    if (benchmark.isEmpty) {
      proposed = _dearestIn(library, category);
      because = proposed == null ? '' : 'nothing set';
    } else if (entry == null) {
      // Benchmarked on a name the catalog cannot find. Worse than nothing set,
      // because it reads on every report as though somebody checked.
      stale = true;
      proposed = _dearestIn(library, category);
      because = proposed == null ? '' : 'not in the catalog';
    } else if (entry.retired) {
      stale = true;
      proposed = library.successorFor(benchmark) ?? _dearestIn(library, category);
      because = proposed == null ? '' : 'retired';
    }

    out.add((
      category: category,
      benchmark: benchmark,
      setOn: cost.standardSetOn,
      stale: stale,
      // A proposal that is what is already there is not a proposal.
      proposed: proposed != null &&
              proposed.model.trim().toLowerCase() == benchmark.toLowerCase()
          ? null
          : proposed,
      because: because,
    ));
  }
  out.sort((a, b) => a.category.compareTo(b.category));
  return out;
}

/// The dearest CURRENT model the catalog files under [category], or null.
///
/// Dearest rather than cheapest on purpose: a base cost is what a room done
/// properly comes to, and benchmarking an estate on the cheapest thing in the
/// aisle is how a plan comes in short in the one direction nobody checks. An
/// entry with no price cannot be a benchmark - the whole point of the line is
/// the figure it carries.
AvDeviceTemplate? _dearestIn(AvDeviceLibrary library, String category) {
  final needle = category.trim().toLowerCase();
  AvDeviceTemplate? best;
  for (final entry in library.active) {
    if (entry.category.trim().toLowerCase() != needle) continue;
    if (entry.priceForTier(PricingTier.msrp).price <= 0) continue;
    if (best == null ||
        entry.priceForTier(PricingTier.msrp).price >
            best.priceForTier(PricingTier.msrp).price) {
      best = entry;
    }
  }
  return best;
}

/// True when [row] is worth pointing at: benchmarked on something that is gone,
/// never benchmarked at all, or set long enough ago to be worth a look.
bool standardNeedsLooking(CategoryStandard row, DateTime asOf) {
  if (row.stale || row.benchmark.isEmpty) return true;
  final set = row.setOn;
  return set != null && asOf.difference(set).inDays > kStandardStaleYears * 365;
}

/// The card as one sentence, for the button that opens it and the dialog that
/// heads it.
String describeCategoryStandards(
  List<CategoryStandard> rows,
  DateTime asOf,
) {
  final unset = rows.where((r) => r.benchmark.isEmpty).length;
  final stale = rows.where((r) => r.stale).length;
  final old = rows
      .where((r) => !r.stale && r.benchmark.isNotEmpty && standardNeedsLooking(r, asOf))
      .length;
  if (unset == 0 && stale == 0 && old == 0) {
    return '${rows.length} categories, every one benchmarked on a current '
        'model';
  }
  return [
    '${rows.length} categories',
    if (stale > 0) '$stale on a product that is gone',
    if (unset > 0) '$unset with nothing set',
    if (old > 0) '$old set more than $kStandardStaleYears years ago',
  ].join('  ·  ');
}

/// What writing [row]'s proposal onto the card would produce. Nothing is
/// written.
///
/// BOTH TIERS, off the catalog entry's own two figures - a card with one price
/// on it has every estimate at the other tier reading high or low depending on
/// which way the job went.
BaseCost standardApplied(
  CategoryStandard row,
  AvDeviceTemplate model, {
  BaseCost? existing,
  DateTime? setOn,
}) =>
    (existing ?? BaseCost(category: row.category)).copyWith(
      category: row.category,
      price: model.price,
      educationPrice: model.educationPrice,
      standardModel: model.model,
      standardSetOn: setOn ?? DateTime.now(),
    );
