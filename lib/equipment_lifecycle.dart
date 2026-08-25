import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'project_estimate.dart';
import 'report_tools.dart';
import 'room_locations.dart';

/// ============================================================================
///  HOW OLD THE GEAR IS, AND WHEN IT HAS TO BE REPLACED
/// ============================================================================
///  Everything else in this app answers "what is going IN". This answers the
///  question that gets asked every budget cycle about what is already there:
///  which rooms are running equipment past its life, which ones are about to
///  be, and what it costs to stay ahead of them.
///
///  That question was answered on a spreadsheet — the Master RYG sheet — one
///  row per room, one column per year, a coloured cell in each: green while the
///  room is young, amber as it approaches the end of its cycle, red the year it
///  is due, with the replacement figure written in the red cell. It works, and
///  it is maintained by hand from a room list somebody else keeps, so it drifts
///  from the rooms it describes the moment anything is swapped.
///
///  THE SAME SHEET, DERIVED. The dates live on the equipment itself
///  ([AvNode.installedOn]), the rooms come from the project, and the colours
///  come out of the arithmetic below. Nothing is typed twice, and swapping a
///  projector moves that position's clock without touching the rest of the
///  room — see [AvNode.withSwapRecorded].
///
///  THE BANDS ARE THE RYG SHEET'S BANDS. An eight-year cycle counted from the
///  install year, which is "year one":
///
///    * GREEN    years 1 to 5   — in service, nothing to plan
///    * AMBER    years 6 to 8   — inside the planning window; this is the year
///                                it should appear on a budget request
///    * RED      year 9 onward  — past its life, running on borrowed time
///
///  Generalised so a position on a different life bands the same way: amber for
///  the last three years of whatever life it was given, red past the end of it.
///
///  THE AMBER BAND IS GRADED, because three years of it are not one state. It
///  runs yellow the year a position enters the window, amber the year it should
///  be quoted and orange the last year before it is due — and red goes deeper
///  once something is two years past its life and still in the room. Six steps,
///  in [EquipmentTiming]; the four words a document is written in are derived
///  from them, so the colour and the label cannot come apart.
///  WHERE THAT LIFE COMES FROM IS THREE ANSWERS, most specific first — what
///  somebody said about this position, what the catalog says the product does
///  in general, and the blanket cycle for a product nobody has recorded one
///  for. Every row says which of the three it used, because a plan whose
///  figures cannot be traced is one nobody argues a budget from.
///
///  A position with no install date is UNKNOWN and says so — a room whose dates
///  were never entered has to read as unanswered rather than as new, because
///  those two lead to opposite decisions.
///
///  Pure functions over the model, no provider and no widgets, so the room
///  view, the project roll-up, both workbooks and the tests all read the same
///  arithmetic.
/// ============================================================================

// ---------------------------------------------------------------------------
//  THE CYCLE
// ---------------------------------------------------------------------------

/// How long a piece of AV equipment is assumed to last when nobody has said
/// otherwise.
///
/// Eight years, which is the cycle the RYG sheet this is modelled on has been
/// run on: green for five, amber for three, replace in the ninth.
///
/// THE LAST RESORT, not the usual answer. A product with a figure in the
/// catalog uses that ([AvDeviceTemplate.lifeYears]), and a position somebody
/// has said something specific about uses THAT ([AvNode.lifeYears]) — a
/// lectern PC in a teaching lab, a display in a boardroom nobody books. This is
/// what is left when neither has been recorded.
const int kDefaultEquipmentLifeYears = 8;

/// How many years before the end of its life a position starts reading amber.
///
/// Three, so an eight-year cycle is green 1-5 and amber 6-8 exactly as the
/// sheet has it. It is also the right number for its own sake: a replacement
/// has to be budgeted a year out, quoted the year before that, and noticed the
/// year before THAT.
const int kEquipmentWarningYears = 3;

/// Days in the average year, leap years included. Used to turn two dates into
/// an age in years without pretending a year is 365 days.
const double kDaysPerYear = 365.2425;

/// True when [node] is on the refresh cycle at all.
///
/// JACK FIELDS AND PATCH PANELS ARE NOT. A wall plate and a punched-down panel
/// are part of the building, replaced when the room is rebuilt rather than on a
/// life of their own, and listing sixteen of them beside the projector would
/// bury the four things that matter.
///
/// Top-level so the ONE rule serves both readers: the plan that lists the
/// room's items, and the bulk date that sets them. A dialog offering to date
/// "14 items" that then dated eleven would be a dialog nobody trusts again.
bool equipmentIsTracked(AvNode node) => !node.isJackField;

/// Where the life a position is held to came from.
///
/// Reported rather than left implicit, for the same reason the cable schedule
/// says which of its counts were typed over: a plan whose figures cannot be
/// traced is one nobody argues a budget from. The three sources are also the
/// resolution ORDER — most specific first.
enum EquipmentLifeSource {
  /// Somebody said so about THIS position: [AvNode.lifeYears].
  position,

  /// The catalog's average for the product: [AvDeviceTemplate.lifeYears].
  catalog,

  /// Nobody has said, so the blanket cycle applies.
  fallback,
}

const Map<EquipmentLifeSource, String> kEquipmentLifeSourceLabels = {
  EquipmentLifeSource.position: 'set on this item',
  EquipmentLifeSource.catalog: 'from the catalog',
  EquipmentLifeSource.fallback: 'default cycle',
};

/// Where one position sits in its life.
enum EquipmentCondition {
  /// No install date recorded. Not a judgement — a gap.
  unknown,

  /// In service, with more than [kEquipmentWarningYears] left.
  good,

  /// Inside the planning window: due within [kEquipmentWarningYears].
  ageing,

  /// Past the end of its life.
  overdue,
}

const Map<EquipmentCondition, String> kEquipmentConditionLabels = {
  EquipmentCondition.unknown: 'No install date',
  EquipmentCondition.good: 'In service',
  EquipmentCondition.ageing: 'Due soon',
  EquipmentCondition.overdue: 'Past its life',
};

/// The one-word form for a table column that has to stay narrow, and for the
/// colour key on the sheet this is modelled on.
const Map<EquipmentCondition, String> kEquipmentConditionCodes = {
  EquipmentCondition.unknown: '-',
  EquipmentCondition.good: 'Green',
  EquipmentCondition.ageing: 'Amber',
  EquipmentCondition.overdue: 'Red',
};

/// Worst first, so a room can be summarised by the state of its worst item and
/// a list can be sorted by "what needs attention".
///
/// UNKNOWN sits between amber and green rather than at either end: a room with
/// no dates is not a crisis and is not fine, and putting it last would hide the
/// rooms whose survey has not been done.
const List<EquipmentCondition> kEquipmentConditionSeverity = [
  EquipmentCondition.overdue,
  EquipmentCondition.ageing,
  EquipmentCondition.unknown,
  EquipmentCondition.good,
];

int _severity(EquipmentCondition c) => kEquipmentConditionSeverity.indexOf(c);

/// The worse of two conditions.
EquipmentCondition worstCondition(EquipmentCondition a, EquipmentCondition b) =>
    _severity(a) <= _severity(b) ? a : b;

// ---------------------------------------------------------------------------
//  THE RAMP
// ---------------------------------------------------------------------------

/// How close to due a position is, in finer steps than [EquipmentCondition].
///
/// WHY BOTH. The four conditions are what a document SAYS — 'Due soon', 'Past
/// its life' — and they are the right words for a table and for a count. They
/// are the wrong resolution for a colour, because 'due soon' covers the item
/// that has to be quoted this month and the one that has three budget cycles
/// left, and painting those the same amber tells a reader looking at the sheet
/// that they are the same problem.
///
/// So the warning window is split three ways and the ramp runs the way the
/// colours do: green while it is in service, YELLOW the year it enters the
/// planning window, amber the year it should be quoted, orange the last year
/// before it is due, red the day it is past, and a deeper red once it is two
/// years past and nobody has done anything about it.
///
/// [EquipmentCondition] is DERIVED from this rather than computed beside it,
/// so the words and the colour cannot come apart.
enum EquipmentTiming {
  /// No install date recorded.
  unknown,

  /// In service, still outside the planning window.
  inService,

  /// Just inside the window: the first year it belongs on a list.
  watch,

  /// Inside the window and close enough to price.
  approaching,

  /// The last year before it falls due.
  imminent,

  /// Past its life.
  overdue,

  /// Well past it — two years or more.
  wellOverdue,
}

const Map<EquipmentTiming, String> kEquipmentTimingLabels = {
  EquipmentTiming.unknown: 'No install date',
  EquipmentTiming.inService: 'In service',
  EquipmentTiming.watch: 'Coming up',
  EquipmentTiming.approaching: 'Budget it',
  EquipmentTiming.imminent: 'Due next',
  EquipmentTiming.overdue: 'Past its life',
  EquipmentTiming.wellOverdue: 'Years past its life',
};

/// The colour each step reads as, for the key beside the sheet and for the
/// mono copy somebody prints.
const Map<EquipmentTiming, String> kEquipmentTimingCodes = {
  EquipmentTiming.unknown: '-',
  EquipmentTiming.inService: 'Green',
  EquipmentTiming.watch: 'Yellow',
  EquipmentTiming.approaching: 'Amber',
  EquipmentTiming.imminent: 'Orange',
  EquipmentTiming.overdue: 'Red',
  EquipmentTiming.wellOverdue: 'Deep red',
};

/// Worst first, the same ordering rule [kEquipmentConditionSeverity] uses, and
/// unknown sits in the same place in it — between the warning band and green,
/// because a room nobody has surveyed is neither a crisis nor fine.
const List<EquipmentTiming> kEquipmentTimingSeverity = [
  EquipmentTiming.wellOverdue,
  EquipmentTiming.overdue,
  EquipmentTiming.imminent,
  EquipmentTiming.approaching,
  EquipmentTiming.watch,
  EquipmentTiming.unknown,
  EquipmentTiming.inService,
];

int _timingSeverity(EquipmentTiming t) => kEquipmentTimingSeverity.indexOf(t);

/// The worse of two steps on the ramp.
EquipmentTiming worstTiming(EquipmentTiming a, EquipmentTiming b) =>
    _timingSeverity(a) <= _timingSeverity(b) ? a : b;

/// The words [timing] belongs to.
EquipmentCondition conditionOfTiming(EquipmentTiming timing) =>
    switch (timing) {
      EquipmentTiming.unknown => EquipmentCondition.unknown,
      EquipmentTiming.inService => EquipmentCondition.good,
      EquipmentTiming.watch ||
      EquipmentTiming.approaching ||
      EquipmentTiming.imminent => EquipmentCondition.ageing,
      EquipmentTiming.overdue ||
      EquipmentTiming.wellOverdue => EquipmentCondition.overdue,
    };

/// How long before the end of [lifeYears] the warning window opens.
///
/// [kEquipmentWarningYears] on any normal life. Clamped on a short one so a
/// position on a two-year cycle still gets a green year rather than reading
/// amber from the day it goes in.
int equipmentWarningWindow(int lifeYears) =>
    lifeYears <= kEquipmentWarningYears
        ? (lifeYears - 1).clamp(0, kEquipmentWarningYears)
        : kEquipmentWarningYears;

/// How many years past due a position has to be before it reads as WELL past
/// it. Two, which is one whole budget cycle of nothing having been done.
const double kEquipmentWellOverdueYears = 2;

/// Where [yearsRemaining] sits on the ramp, for a position on [lifeYears].
///
/// Top-level and pure, because three readers need the same arithmetic on
/// different inputs: an item measured against today, a room measured against a
/// column on the year grid, and the tests.
EquipmentTiming timingFor({
  required double? yearsRemaining,
  required int lifeYears,
}) {
  final remaining = yearsRemaining;
  if (remaining == null) return EquipmentTiming.unknown;
  if (remaining <= -kEquipmentWellOverdueYears) {
    return EquipmentTiming.wellOverdue;
  }
  if (remaining <= 0) return EquipmentTiming.overdue;

  final window = equipmentWarningWindow(lifeYears);
  if (window <= 0 || remaining > window) return EquipmentTiming.inService;

  // The window in three. On the eight-year cycle the sheet is modelled on
  // that is one year per step: year six yellow, seven amber, eight orange.
  final step = window / 3;
  if (remaining <= step) return EquipmentTiming.imminent;
  if (remaining <= step * 2) return EquipmentTiming.approaching;
  return EquipmentTiming.watch;
}

// ---------------------------------------------------------------------------
//  ONE POSITION
// ---------------------------------------------------------------------------

/// Where one piece of equipment is in its life, and what replacing it costs.
class EquipmentLife {
  /// The box on the drawing. Its [AvNode.label] is the position — "Projector
  /// 1" — and its [AvNode.model] is whatever is in that position now.
  final AvNode node;

  /// Where in the room it is, already resolved to a name so a report does not
  /// have to carry the location list around with it.
  final String locationName;
  final RoomZone zone;

  /// The day this unit went in, or null when nobody recorded one.
  final DateTime? installedOn;

  /// The life this position is being held to.
  ///
  /// THREE SOURCES, MOST SPECIFIC FIRST — the same shape the schedule resolves
  /// a lead time with. The position's own [AvNode.lifeYears] is somebody
  /// saying "this one, sooner"; the catalog's [AvDeviceTemplate.lifeYears] is
  /// what the product does in general; the default is the blanket cycle for a
  /// product nobody has recorded one for. Each level only ever narrows, so a
  /// catalog with no lives in it behaves exactly as it did before they
  /// existed.
  final int lifeYears;

  /// Which of those three [lifeYears] came from.
  final EquipmentLifeSource lifeSource;

  /// The day this was measured on. Carried rather than read from the clock at
  /// render time, so every figure on one sheet is as of the same day.
  final DateTime asOf;

  /// What it costs to replace, from the catalog at the job's tier. 0 when the
  /// model is not in the catalog or carries no price — reported as unpriced
  /// rather than as free.
  final double replacementCost;

  const EquipmentLife({
    required this.node,
    required this.locationName,
    required this.zone,
    required this.installedOn,
    required this.lifeYears,
    this.lifeSource = EquipmentLifeSource.fallback,
    required this.asOf,
    required this.replacementCost,
  });

  /// How long it has been in, in years and fractions of one. Null with no
  /// install date.
  ///
  /// Negative for a date in the future, which is a real thing to record — gear
  /// specified now and going in next summer — and reads as "not yet installed"
  /// rather than as an error.
  double? get ageYears => installedOn == null
      ? null
      : asOf.difference(installedOn!).inDays / kDaysPerYear;

  /// The RYG sheet's cell: the install year is year ONE, the next is year two.
  /// Null with no install date.
  int? get serviceYear {
    final age = ageYears;
    if (age == null) return null;
    return age.floor() + 1;
  }

  /// The day it falls due: the install date plus its life.
  ///
  /// Built by adding to the YEAR rather than by adding days, so a unit put in
  /// on 1 March is due on 1 March and not two days either side of it. A 29
  /// February install lands on the 28th of a non-leap year, which is what
  /// [DateTime]'s own rollover would get wrong by a day.
  DateTime? get dueOn {
    final from = installedOn;
    if (from == null) return null;
    final year = from.year + lifeYears;
    final day = from.day.clamp(1, DateTime(year, from.month + 1, 0).day);
    return DateTime(year, from.month, day);
  }

  /// The budget year the replacement belongs in — the RYG sheet's red cell.
  int? get dueYear => dueOn?.year;

  /// Years left before it falls due; negative once it is past.
  double? get yearsRemaining {
    final due = dueOn;
    if (due == null) return null;
    return due.difference(asOf).inDays / kDaysPerYear;
  }

  /// Where this position sits on the colour ramp — see [EquipmentTiming].
  EquipmentTiming get timing =>
      timingFor(yearsRemaining: yearsRemaining, lifeYears: lifeYears);

  /// The words for [timing]. Derived rather than computed alongside it, so a
  /// row's colour and its label can never disagree.
  EquipmentCondition get condition => conditionOfTiming(timing);

  /// True when this position has been through at least one swap, so the room
  /// report can say how long the last unit lasted.
  bool get hasHistory => node.swaps.isNotEmpty;

  /// How long the previous units in this position actually lasted, in years,
  /// oldest first. Only the ones whose install date was recorded.
  List<double> get servedYears => [
    for (final s in node.swaps)
      if (s.servedYears != null) s.servedYears!,
  ];
}

// ---------------------------------------------------------------------------
//  ONE ROOM
// ---------------------------------------------------------------------------

/// A room's equipment, aged.
class RoomLifecycle {
  /// What to call the room on a building-wide sheet.
  final String roomName;

  /// One entry per box on the drawing, worst condition first.
  final List<EquipmentLife> items;

  final DateTime asOf;

  const RoomLifecycle({
    required this.roomName,
    required this.items,
    required this.asOf,
  });

  int countOf(EquipmentCondition c) =>
      items.where((i) => i.condition == c).length;

  /// What the items in [c] cost to replace.
  ///
  /// COUNTS ARE HALF AN ANSWER. 'Four items due soon' is a fact nobody can act
  /// on; 'four items, 18,000 dollars' is a budget line. Every band on this screen
  /// carries both for that reason, and both move the moment a date or a life
  /// is changed on one item.
  double costOf(EquipmentCondition c) => items
      .where((i) => i.condition == c)
      .fold<double>(0, (sum, i) => sum + i.replacementCost);

  int countOfTiming(EquipmentTiming t) =>
      items.where((i) => i.timing == t).length;

  double costOfTiming(EquipmentTiming t) => items
      .where((i) => i.timing == t)
      .fold<double>(0, (sum, i) => sum + i.replacementCost);

  /// The room reads as its WORST item.
  ///
  /// Not as its average and not as its oldest: a room with one dead projector
  /// and nine new speakers is a room that does not work, and averaging it into
  /// green is how a sheet like this stops being believed.
  EquipmentTiming get timing => items.isEmpty
      ? EquipmentTiming.unknown
      : items.map((i) => i.timing).reduce(worstTiming);

  EquipmentCondition get condition => conditionOfTiming(timing);

  /// How many items are past their life or inside the planning window — the
  /// count a refresh is written for.
  int get toReplaceCount =>
      countOf(EquipmentCondition.overdue) + countOf(EquipmentCondition.ageing);

  /// What those items cost. [overdueCost] is the part of it that is already
  /// late; this is the whole ask.
  double get toReplaceCost =>
      costOf(EquipmentCondition.overdue) + costOf(EquipmentCondition.ageing);

  /// How many items are due soon but not yet late, and what they cost.
  int get dueSoonCount => countOf(EquipmentCondition.ageing);
  double get dueSoonCost => costOf(EquipmentCondition.ageing);

  /// The life driving [firstDueYear], so the year grid bands its columns on
  /// the same window the item itself is banded on. Falls back to the blanket
  /// cycle on a room with nothing dated.
  int get _drivingLifeYears {
    final first = firstDueYear;
    if (first == null) return kDefaultEquipmentLifeYears;
    for (final i in items) {
      if (i.dueYear == first) return i.lifeYears;
    }
    return kDefaultEquipmentLifeYears;
  }

  /// Where the room sits in [year] — the ramp, read across a column of the
  /// year grid rather than measured against today.
  ///
  /// The room's own first due year is what the column counts down to, so a row
  /// runs green, yellow, amber, orange and then red across the sheet the way
  /// the hand-coloured one did.
  EquipmentTiming timingIn(int year) {
    final installed = oldestInstall?.year;
    final due = firstDueYear;
    if (installed == null || due == null) return EquipmentTiming.unknown;
    if (year < installed) return EquipmentTiming.unknown;
    return timingFor(
      yearsRemaining: (due - year).toDouble(),
      lifeYears: _drivingLifeYears,
    );
  }

  /// The earliest year anything in the room falls due, or null when nothing in
  /// it has a date. This is the room's row on the building sheet.
  int? get firstDueYear {
    int? out;
    for (final i in items) {
      final year = i.dueYear;
      if (year == null) continue;
      if (out == null || year < out) out = year;
    }
    return out;
  }

  /// The oldest install date in the room — when the room itself was last done.
  DateTime? get oldestInstall {
    DateTime? out;
    for (final i in items) {
      final when = i.installedOn;
      if (when == null) continue;
      if (out == null || when.isBefore(out)) out = when;
    }
    return out;
  }

  /// What it costs to replace everything past its life today.
  double get overdueCost => items
      .where((i) => i.condition == EquipmentCondition.overdue)
      .fold<double>(0, (sum, i) => sum + i.replacementCost);

  /// What it costs to replace everything in the room, whatever its age — the
  /// figure a full refresh is budgeted at.
  double get refreshCost =>
      items.fold<double>(0, (sum, i) => sum + i.replacementCost);

  /// Replacement cost falling in [year], from the items due that year. This is
  /// the number the RYG sheet writes into the red cell.
  double costDueIn(int year) => items
      .where((i) => i.dueYear == year)
      .fold<double>(0, (sum, i) => sum + i.replacementCost);

  /// Items due in [year].
  List<EquipmentLife> dueIn(int year) =>
      items.where((i) => i.dueYear == year).toList();

  /// How many items carry no install date. The survey's to-do list.
  int get undated => countOf(EquipmentCondition.unknown);
}

/// Ages every box in [model].
///
/// [library] and [tier] price the replacement; without a library every item
/// simply comes back unpriced, which is right for a caller that only wants the
/// ages.
///
/// [asOf] is the day it is measured on and defaults to today. Passed explicitly
/// by the reports and by every test, because a figure that changes with the
/// clock cannot be checked.
RoomLifecycle buildRoomLifecycle({
  required AvFlowModel model,
  String roomName = '',
  AvDeviceLibrary? library,
  PricingTier tier = PricingTier.msrp,
  DateTime? asOf,
  int defaultLifeYears = kDefaultEquipmentLifeYears,
}) {
  final now = asOf ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);

  final items = <EquipmentLife>[];
  for (final node in model.nodes) {
    if (!equipmentIsTracked(node)) continue;

    final template = library?.templateForModel(node.model);

    // Most specific first — see [EquipmentLife.lifeYears].
    final int life;
    final EquipmentLifeSource source;
    if (node.lifeYears > 0) {
      life = node.lifeYears;
      source = EquipmentLifeSource.position;
    } else if ((template?.lifeYears ?? 0) > 0) {
      life = template!.lifeYears;
      source = EquipmentLifeSource.catalog;
    } else {
      life = defaultLifeYears;
      source = EquipmentLifeSource.fallback;
    }

    items.add(EquipmentLife(
      node: node,
      locationName: model.locationNameOf(node.id),
      zone: model.zoneOf(node.id),
      installedOn: node.installedOn,
      lifeYears: life,
      lifeSource: source,
      asOf: day,
      replacementCost: template?.priceForTier(tier).price ?? 0,
    ));
  }

  // Worst first, then by due date, then by name — so the top of the list is
  // always what to do something about, and two readings of the same room come
  // out in the same order.
  items.sort((a, b) {
    final bySeverity =
        _severity(a.condition).compareTo(_severity(b.condition));
    if (bySeverity != 0) return bySeverity;
    final ad = a.dueOn, bd = b.dueOn;
    if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
    if (ad == null && bd != null) return 1;
    if (ad != null && bd == null) return -1;
    return a.node.label.toLowerCase().compareTo(b.node.label.toLowerCase());
  });

  return RoomLifecycle(roomName: roomName, items: items, asOf: day);
}

// ---------------------------------------------------------------------------
//  THE WHOLE BUILDING
// ---------------------------------------------------------------------------

/// Every room on the job, aged — the RYG sheet.
class BuildingLifecycle {
  final List<RoomLifecycle> rooms;
  final DateTime asOf;

  /// The currency the replacement figures are in, for the report headings.
  final String currency;

  const BuildingLifecycle({
    required this.rooms,
    required this.asOf,
    this.currency = '\$',
  });

  List<EquipmentLife> get items => [for (final r in rooms) ...r.items];

  int countOf(EquipmentCondition c) =>
      items.where((i) => i.condition == c).length;

  /// What the items in [c] cost to replace across the job — the figure a band
  /// on the summary strip is only half of without.
  double costOf(EquipmentCondition c) => items
      .where((i) => i.condition == c)
      .fold<double>(0, (sum, i) => sum + i.replacementCost);

  int roomsOf(EquipmentCondition c) =>
      rooms.where((r) => r.condition == c).length;

  /// Everything past its life or inside the planning window, and its cost.
  int get toReplaceCount =>
      countOf(EquipmentCondition.overdue) + countOf(EquipmentCondition.ageing);

  double get toReplaceCost =>
      costOf(EquipmentCondition.overdue) + costOf(EquipmentCondition.ageing);

  double get overdueCost =>
      rooms.fold<double>(0, (sum, r) => sum + r.overdueCost);

  double costDueIn(int year) =>
      rooms.fold<double>(0, (sum, r) => sum + r.costDueIn(year));

  /// True when anything on the job has an install date on it.
  ///
  /// The line between "this building has not been surveyed" and "this building
  /// is new": with no dates anywhere there is no plan to draw, only a list of
  /// rooms with blank rows, and a sheet of those in an issued workbook says
  /// less than no sheet at all.
  bool get anyDated => items.any((i) => i.installedOn != null);

  /// The span of years the sheet has to cover: from the earliest install year
  /// on the job to the last year anything falls due, and always including the
  /// current year so a building with nothing recorded still has a column to
  /// read.
  ///
  /// Capped at [maxColumns] years from today, because a single unit installed
  /// in 1998 should not stretch the grid across thirty columns of nothing.
  List<int> years({int maxColumns = 12}) {
    var first = asOf.year;
    var last = asOf.year;
    for (final i in items) {
      final installed = i.installedOn?.year;
      if (installed != null && installed < first) first = installed;
      final due = i.dueYear;
      if (due != null && due > last) last = due;
    }
    if (first < asOf.year - maxColumns) first = asOf.year - maxColumns;
    if (last > asOf.year + maxColumns) last = asOf.year + maxColumns;
    return [for (var y = first; y <= last; y++) y];
  }
}

/// Ages every room on the job.
///
/// Reads the ROOMS THE ESTIMATE ALREADY LOADED rather than going back to disk:
/// the project tab prices its rooms on every rebuild and caches the reads, and
/// a second pass over forty files to answer "how old is this" would make the
/// tab feel broken for a figure that is already in memory.
///
/// Rooms that could not be read are left out — an unreadable room has no
/// equipment to age — and the count of them is on the Rooms pane already, so
/// nothing is being hidden here that is not said louder elsewhere.
BuildingLifecycle buildProjectLifecycle({
  required ProjectEstimate estimate,
  AvDeviceLibrary? library,
  PricingTier tier = PricingTier.msrp,
  DateTime? asOf,
  int defaultLifeYears = kDefaultEquipmentLifeYears,
}) {
  final now = asOf ?? DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  return buildBuildingLifecycle(
    rooms: [
      for (final room in estimate.rooms)
        if (room.ok)
          buildRoomLifecycle(
            model: room.room.model,
            roomName: room.codeName,
            library: library,
            tier: tier,
            asOf: day,
            defaultLifeYears: defaultLifeYears,
          ),
    ],
    asOf: day,
    currency: estimate.currency,
  );
}

/// Builds the building sheet from rooms that have already been aged.
///
/// Takes [RoomLifecycle]s rather than reading anything itself, because the two
/// callers get their rooms from different places — the project tab from the
/// priced estimate it already holds, a test from a map it made — and neither
/// should have to go through the other's loader.
BuildingLifecycle buildBuildingLifecycle({
  required List<RoomLifecycle> rooms,
  DateTime? asOf,
  String currency = '\$',
}) {
  final now = asOf ?? DateTime.now();
  return BuildingLifecycle(
    rooms: rooms,
    asOf: DateTime(now.year, now.month, now.day),
    currency: currency,
  );
}

// ---------------------------------------------------------------------------
//  HOW IT READS
// ---------------------------------------------------------------------------

/// An age in words: 'this year', '3 years', '11 years'.
String formatEquipmentAge(double? years) {
  if (years == null) return 'not recorded';
  if (years < 0) return 'not yet installed';
  final whole = years.floor();
  if (whole == 0) return 'this year';
  return whole == 1 ? '1 year' : '$whole years';
}

/// What is left, in words: 'due 2029', 'overdue since 2024'.
String formatEquipmentDue(EquipmentLife item) {
  final year = item.dueYear;
  if (year == null) return 'no install date';
  return item.condition == EquipmentCondition.overdue
      ? 'overdue since $year'
      : 'due $year';
}

/// A band as both halves of the answer: 'four items, $18,000'.
///
/// The count on its own is not something anybody can act on and the money on
/// its own does not say how big a job it is, so every band on these sheets and
/// on the screen carries the pair. An unpriced band says so rather than
/// reading as free.
String formatEquipmentBand(int count, double cost, String currency) {
  final items = '$count item${count == 1 ? '' : 's'}';
  if (count == 0) return items;
  if (cost <= 0) return '$items, not priced';
  return '$items, ${formatLifecycleMoney(cost, currency)}';
}

/// A money figure as the lifecycle sheets write one: no decimals, because a
/// replacement budget five years out is not accurate to the cent and printing
/// it to the cent implies it is.
String formatLifecycleMoney(double amount, String currency) {
  if (amount <= 0) return '';
  final rounded = amount.round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < rounded.length; i++) {
    if (i > 0 && (rounded.length - i) % 3 == 0) buffer.write(',');
    buffer.write(rounded[i]);
  }
  return '$currency$buffer';
}

// ---------------------------------------------------------------------------
//  THE SHEETS
// ---------------------------------------------------------------------------

/// One room's lifecycle, as tables: the summary, the item list, and whatever
/// has been swapped out of it before.
List<ReportSection> roomLifecycleSections(
  RoomLifecycle room, {
  String currency = '\$',
}) {
  if (room.items.isEmpty) return const [];

  final sections = <ReportSection>[
    (
      title: 'Equipment Age',
      header: const ['Item', 'Value'],
      rows: [
        ['As of', formatEquipmentDate(room.asOf)],
        ['Items tracked', room.items.length],
        // Count AND cost on the same line. Which items and how much is one
        // question in a budget meeting, and answering half of it sends
        // somebody back to the spreadsheet for the other half.
        for (final c in kEquipmentConditionSeverity)
          [
            kEquipmentConditionLabels[c]!,
            formatEquipmentBand(room.countOf(c), room.costOf(c), currency),
          ],
        [
          'Room reads as',
          '${kEquipmentConditionCodes[room.condition]} - '
              '${kEquipmentConditionLabels[room.condition]}',
        ],
        [
          'Room last done',
          room.oldestInstall == null
              ? 'not recorded'
              : formatEquipmentDate(room.oldestInstall!),
        ],
        ['First replacement due', room.firstDueYear ?? 'not recorded'],
        [
          'Past its life today',
          formatLifecycleMoney(room.overdueCost, currency),
        ],
        [
          'Due soon, to budget',
          formatLifecycleMoney(room.dueSoonCost, currency),
        ],
        [
          'To replace, past and due',
          formatEquipmentBand(
            room.toReplaceCount,
            room.toReplaceCost,
            currency,
          ),
        ],
        [
          'Full refresh at catalog price',
          formatLifecycleMoney(room.refreshCost, currency),
        ],
      ],
    ),
    (
      title: 'Equipment Replacement Schedule',
      header: [
        'Position',
        'Model',
        'Location',
        'Installed',
        'Age',
        'Life (yrs)',
        'Life from',
        'Due',
        'Status',
        'Timing',
        'Replacement',
      ],
      rows: [
        for (final i in room.items)
          [
            i.node.label,
            i.node.model,
            i.locationName,
            i.installedOn == null ? '' : formatEquipmentDate(i.installedOn!),
            formatEquipmentAge(i.ageYears),
            i.lifeYears,
            kEquipmentLifeSourceLabels[i.lifeSource]!,
            i.dueYear ?? '',
            kEquipmentConditionCodes[i.condition]!,
            // The finer step, so a printed sheet carries the same six-step
            // ramp the screen paints — a mono copy of a colour-coded sheet
            // that only says 'Amber' has lost the half of it that says which
            // of the three amber years it is in.
            kEquipmentTimingCodes[i.timing]!,
            formatLifecycleMoney(i.replacementCost, currency),
          ],
      ],
    ),
  ];

  // What has already been replaced, and how long each of those lasted. The
  // half of the record that says whether the eight-year cycle is the right
  // number for this building — which is the question a refresh policy is
  // actually argued over.
  final swapped = room.items.where((i) => i.hasHistory).toList();
  if (swapped.isNotEmpty) {
    sections.add((
      title: 'Equipment Replaced Before',
      header: const [
        'Position',
        'Model removed',
        'Installed',
        'Removed',
        'Lasted',
        'Why',
      ],
      rows: [
        for (final i in swapped)
          for (final s in i.node.swaps)
            [
              i.node.label,
              s.model,
              s.installedOn == null ? '' : formatEquipmentDate(s.installedOn!),
              formatEquipmentDate(s.removedOn),
              formatEquipmentAge(s.servedYears),
              s.reason,
            ],
      ],
    ));
  }

  return sections;
}

/// The building sheet: a row per room, a column per year, exactly the shape of
/// the RYG spreadsheet this replaces.
///
/// The year cells carry the SERVICE YEAR as a number while the room is inside
/// its cycle and the replacement figure in the year it falls due, so the sheet
/// can be read two ways: across a row to see one room's life, and down a
/// column to see what a given budget year has to cover.
List<ReportSection> buildingLifecycleSections(
  BuildingLifecycle building, {
  int maxColumns = 12,
}) {
  // Nothing dated is nothing to plan — see [BuildingLifecycle.anyDated]. The
  // pane still shows the rooms and says how many items are waiting on a date;
  // a document that leaves the building does not carry a grid of blanks.
  if (building.rooms.isEmpty || !building.anyDated) return const [];
  final currency = building.currency;
  final years = building.years(maxColumns: maxColumns);

  /// What goes in the cell for [room] in [year].
  ///
  /// The year it falls due carries the money, because that is the cell a
  /// budget is read out of. Every other year in service carries the service
  /// year as a plain number — 1, 2, 3 — which is what the colours on the
  /// original sheet were counting.
  String cell(RoomLifecycle room, int year) {
    final due = room.costDueIn(year);
    if (due > 0) return formatLifecycleMoney(due, currency);
    if (room.dueIn(year).isNotEmpty) return 'due';
    final installed = room.oldestInstall?.year;
    if (installed == null || year < installed) return '';
    final first = room.firstDueYear;
    if (first != null && year > first) return '';
    return '${year - installed + 1}';
  }

  return [
    (
      title: 'Equipment Age Across the Building',
      header: const ['Item', 'Value'],
      rows: [
        ['As of', formatEquipmentDate(building.asOf)],
        ['Rooms', building.rooms.length],
        ['Items tracked', building.items.length],
        for (final c in kEquipmentConditionSeverity)
          [
            kEquipmentConditionLabels[c]!,
            '${building.roomsOf(c)} room'
                '${building.roomsOf(c) == 1 ? '' : 's'}, '
                '${formatEquipmentBand(
                  building.countOf(c),
                  building.costOf(c),
                  currency,
                )}',
          ],
        [
          'Past its life today',
          formatLifecycleMoney(building.overdueCost, currency),
        ],
        [
          'To replace, past and due',
          formatEquipmentBand(
            building.toReplaceCount,
            building.toReplaceCost,
            currency,
          ),
        ],
      ],
    ),
    (
      title: 'Replacement Plan by Room',
      header: const [
        'Room',
        'Status',
        'Last done',
        'Oldest item',
        'First due',
        'Past its life',
        'Full refresh',
        'Undated items',
      ],
      rows: [
        for (final room in building.rooms)
          [
            room.roomName,
            kEquipmentConditionCodes[room.condition]!,
            room.oldestInstall == null
                ? ''
                : formatEquipmentDate(room.oldestInstall!),
            formatEquipmentAge(
              room.oldestInstall == null
                  ? null
                  : room.asOf.difference(room.oldestInstall!).inDays /
                      kDaysPerYear,
            ),
            room.firstDueYear ?? '',
            formatLifecycleMoney(room.overdueCost, currency),
            formatLifecycleMoney(room.refreshCost, currency),
            room.undated == 0 ? '' : room.undated,
          ],
      ],
    ),
    (
      title: 'Replacement Year Grid',
      header: ['Room', for (final y in years) '$y'],
      rows: [
        for (final room in building.rooms)
          [room.roomName, for (final y in years) cell(room, y)],
        [
          'Due this year',
          for (final y in years) formatLifecycleMoney(building.costDueIn(y), currency),
        ],
      ],
    ),
  ];
}
