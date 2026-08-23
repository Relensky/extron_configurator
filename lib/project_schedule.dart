import 'building_project.dart';
import 'project_estimate.dart';

/// ============================================================================
///  WHEN THE ORDER HAS TO GO IN
/// ============================================================================
///  A quote says what a building costs. It says nothing about the question that
///  actually loses installs, which is WHEN each box had to be bought — and that
///  question has never been answerable in this app, because the three facts it
///  needs sat in three different heads: the date the room has to be finished,
///  how long each part takes to arrive, and the handful of parts that are
///  wanted weeks before the rest.
///
///  This file is the arithmetic between them, and it is deliberately one
///  subtraction:
///
///      order by  =  the date it is needed  −  how long it takes to come
///
///  NOTHING HERE IS STORED. Every date on the screen is derived from the
///  project's deadline and its lead times on the spot, so moving the deadline
///  moves every order-by date with it. The alternative — writing the computed
///  dates into the project — produces a file that is quietly wrong the first
///  time a deadline slips, and a slipped deadline is the normal case.
///
///  THE UNIT IS CALENDAR DAYS, because that is what vendors quote ("6-8 weeks",
///  "in stock", "ask") and converting to working days at the keyboard is an
///  invitation to get it wrong in the safe-looking direction. A job that needs
///  the weekends taken out can say so by adding the slack to the lead time,
///  which is a decision somebody makes on purpose rather than one the app makes
///  quietly on their behalf.
///
///  A PART WITH NO LEAD TIME IS NOT A PART WITH A LEAD TIME OF ZERO. Absent
///  means nobody has asked the vendor yet, and that is reported as its own
///  state ([OrderStatus.unknown]) rather than folded into "fine". The part
///  nobody asked about is the part that holds up the install, so it gets a row
///  that says so instead of a reassuring date computed from a guess.
/// ============================================================================

/// Where a part stands against the day it has to be ordered.
enum OrderStatus {
  /// The order-by date has already passed. Ordering it today lands it after it
  /// is needed — the schedule is already broken and this says by how much.
  late,

  /// Due within [kOrderDueSoonDays]. Still recoverable, and the only reason
  /// this is separate from [onTrack] is that a list where everything is green
  /// until the day it turns red gives nobody time to act.
  dueSoon,

  /// There is time.
  onTrack,

  /// No lead time recorded, so there is no order-by date to have an opinion
  /// about. Not a problem with the part — a question nobody has asked yet.
  unknown,

  /// Nothing has said when this is needed: no project deadline and no date on
  /// the part itself.
  noDeadline,

  /// ON ORDER, and the vendor's promised date lands AFTER the day it is
  /// needed. Ordered in time or not, this one is still going to be late — and
  /// it is the problem nobody would otherwise see until the week it mattered,
  /// which is why it ranks with the things that have already gone wrong.
  arrivingLate,

  /// On order. Not late, not due, not a question — bought, and the only thing
  /// left is for it to turn up.
  ordered,

  /// It has arrived. Finished with.
  received,
}

const Map<OrderStatus, String> kOrderStatusLabels = {
  OrderStatus.late: 'Order date passed',
  OrderStatus.dueSoon: 'Order now',
  OrderStatus.onTrack: 'On track',
  OrderStatus.unknown: 'No lead time',
  OrderStatus.noDeadline: 'No date set',
  OrderStatus.arrivingLate: 'Ordered - arriving late',
  OrderStatus.ordered: 'On order',
  OrderStatus.received: 'Received',
};

/// How close an order-by date has to be before the list stops calling it fine.
///
/// Two weeks because that is roughly how long it takes to get a quote back,
/// raise the purchase order and have it acknowledged — a part whose order date
/// is inside that window is one somebody has to start on now, not one to note
/// and come back to.
const int kOrderDueSoonDays = 14;

/// One core component, with the dates worked out.
class PartScheduleLine {
  final MasterPartLine line;

  /// Calendar days this part takes to arrive, or null when nobody has recorded
  /// one. Null and zero are different answers — see the header.
  final int? leadDays;

  /// True when [leadDays] came from the CATALOG rather than from a figure
  /// recorded against this part on this job.
  ///
  /// Worth saying on screen: a date worked back from what the catalog
  /// remembers is a different kind of promise from one worked back from what a
  /// vendor quoted last week, and somebody checking a schedule should be able
  /// to tell which they are looking at.
  final bool leadFromCatalog;

  /// The date this part has to be on site by: its own date when it has one,
  /// otherwise the project's deadline, otherwise null.
  final DateTime? needBy;

  /// True when [needBy] came from the part rather than from its track or the
  /// job — the screen that has to be in before the walls close.
  final bool needByIsOwn;

  /// The phase this part is delivered in, or null when it goes with the job as
  /// a whole. See [ProjectTrack].
  final ProjectTrack? track;

  /// What has been bought against this part, or null when nothing has.
  final PartOrder? order;

  /// True when this part is bought and needs no more scheduling.
  bool get isBought =>
      status == OrderStatus.ordered ||
      status == OrderStatus.arrivingLate ||
      status == OrderStatus.received;

  /// What the timeline calls this part's phase.
  String get trackName => track?.name ?? 'The job';

  /// [needBy] minus [leadDays], and null when either is missing.
  final DateTime? orderBy;

  final OrderStatus status;

  /// Days from today to [orderBy]: negative when the date has passed, and null
  /// when there is no date. What the row prints as "3 days late" or "in 21
  /// days" without every caller re-deriving it.
  final int? daysUntilOrder;

  const PartScheduleLine({
    required this.line,
    required this.leadDays,
    required this.needBy,
    required this.needByIsOwn,
    required this.orderBy,
    required this.status,
    required this.daysUntilOrder,
    this.track,
    this.leadFromCatalog = false,
    this.order,
  });

  /// True when this row is something to act on rather than something to read.
  ///
  /// [OrderStatus.arrivingLate] counts: it is bought, so nothing on the
  /// ordering side can be done about it, but somebody has to know the room is
  /// not going to have it in time.
  bool get needsAttention =>
      status == OrderStatus.late ||
      status == OrderStatus.dueSoon ||
      status == OrderStatus.arrivingLate;
}

/// The job's core components, in the order they have to be bought.
class ProjectSchedule {
  /// The project's own delivery deadline, null when nobody has set one.
  final DateTime? deadline;

  /// The day the schedule was worked out against — passed in rather than read
  /// from the clock inside, so a test can ask what a job looks like in March
  /// and a report can say which day it was true on.
  final DateTime asOf;

  /// Every core component, earliest order-by date first. Rows with no date
  /// sort last: they are the questions to go and answer, and floating them to
  /// the top would bury the dates that are real.
  final List<PartScheduleLine> lines;

  const ProjectSchedule({
    required this.deadline,
    required this.asOf,
    required this.lines,
  });

  List<PartScheduleLine> _withStatus(OrderStatus s) =>
      [for (final l in lines) if (l.status == s) l];

  /// Parts whose order-by date has already gone.
  List<PartScheduleLine> get lateLines => _withStatus(OrderStatus.late);

  /// Parts to order inside the next [kOrderDueSoonDays].
  List<PartScheduleLine> get dueSoonLines => _withStatus(OrderStatus.dueSoon);

  /// Parts nobody has recorded a lead time for.
  List<PartScheduleLine> get unknownLines => _withStatus(OrderStatus.unknown);

  /// Parts bought and not yet arrived.
  List<PartScheduleLine> get onOrderLines => [
    for (final l in lines)
      if (l.status == OrderStatus.ordered ||
          l.status == OrderStatus.arrivingLate)
        l,
  ];

  /// Bought, and the vendor's date lands after the day it is needed. Nothing
  /// on the ordering side can fix these — but the room is not going to have
  /// them in time, and that is worth knowing before the week it matters.
  List<PartScheduleLine> get arrivingLateLines =>
      _withStatus(OrderStatus.arrivingLate);

  /// Parts that have turned up.
  List<PartScheduleLine> get receivedLines =>
      _withStatus(OrderStatus.received);

  /// Parts still to buy — what the order dates are actually about.
  List<PartScheduleLine> get toBuyLines =>
      [for (final l in lines) if (!l.isBought) l];

  int get lateCount => lateLines.length;
  int get dueSoonCount => dueSoonLines.length;
  int get unknownCount => unknownLines.length;
  int get onOrderCount => onOrderLines.length;
  int get arrivingLateCount => arrivingLateLines.length;
  int get receivedCount => receivedLines.length;

  /// True when there is nothing to schedule against — no deadline anywhere.
  bool get hasNoDates =>
      deadline == null && lines.every((l) => l.needBy == null);

  /// The earliest date anything has to be ordered by, or null when nothing has
  /// one. The date the job actually starts, as opposed to the date it is due.
  DateTime? get firstOrderDate {
    DateTime? first;
    for (final l in lines) {
      final d = l.orderBy;
      if (d == null) continue;
      if (first == null || d.isBefore(first)) first = d;
    }
    return first;
  }

  /// The last date anything is needed on site — the far end of the timeline.
  DateTime? get lastNeedDate {
    DateTime? last;
    for (final l in lines) {
      final d = l.needBy;
      if (d == null) continue;
      if (last == null || d.isAfter(last)) last = d;
    }
    return last;
  }

  /// The parts on one phase, or the ones going with the job when [id] is ''.
  List<PartScheduleLine> linesForTrack(String id) => [
    for (final l in lines)
      if ((l.track?.id ?? '') == id) l,
  ];

  /// Every phase that has parts on it, in the project's own track order, plus
  /// the job itself when anything is delivered against the job's own deadline.
  ///
  /// The reading the timeline is for: two phases side by side, each with its
  /// own delivery date and its own first order, so it is visible whether the
  /// infrastructure order going in three months before the tech order actually
  /// lines up with when the walls close.
  List<({ProjectTrack? track, List<PartScheduleLine> parts})> byTrack(
    BuildingProject project,
  ) {
    final out = <({ProjectTrack? track, List<PartScheduleLine> parts})>[];
    for (final t in project.tracks) {
      final parts = linesForTrack(t.id);
      if (parts.isEmpty) continue;
      out.add((track: t, parts: parts));
    }
    final loose = linesForTrack('');
    if (loose.isNotEmpty) out.add((track: null, parts: loose));
    return out;
  }

  /// The distinct order-by dates, earliest first, with the parts due on each.
  ///
  /// What the timeline draws: an order date is a trip to the purchasing office,
  /// and eleven parts sharing one is one trip, not eleven rows.
  List<({DateTime date, List<PartScheduleLine> parts})> get orderDays =>
      orderDaysOf(lines);

  /// [orderDays] over any subset — what one track's own strip is drawn from.
  static List<({DateTime date, List<PartScheduleLine> parts})> orderDaysOf(
    List<PartScheduleLine> lines,
  ) {
    final byDate = <String, List<PartScheduleLine>>{};
    final dates = <String, DateTime>{};
    for (final l in lines) {
      // Already bought: there is no trip to purchasing left to schedule, and
      // leaving it on the strip would put a date in somebody's calendar for
      // an order that went out last week.
      if (l.isBought) continue;
      final d = l.orderBy;
      if (d == null) continue;
      final key = formatIsoDate(d);
      dates[key] = d;
      byDate.putIfAbsent(key, () => []).add(l);
    }
    final keys = byDate.keys.toList()..sort();
    return [for (final k in keys) (date: dates[k]!, parts: byDate[k]!)];
  }
}

/// Works out when each core component has to be ordered.
///
/// [asOf] is the day "late" and "due soon" are measured from; it defaults to
/// today and is only ever passed explicitly by tests and reports, which need an
/// answer that does not change with the clock.
ProjectSchedule buildProjectSchedule({
  required ProjectEstimate estimate,
  DateTime? asOf,
}) {
  final project = estimate.project;
  final now = dateOnly(asOf ?? DateTime.now());

  final lines = [
    for (final line in estimate.master)
      schedulePart(line: line, project: project, asOf: now),
  ];

  // Earliest order first, undated last, and the part description breaks a tie
  // so the list does not reshuffle itself between two identical readings.
  lines.sort((a, b) {
    final ad = a.orderBy;
    final bd = b.orderBy;
    if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
    if (ad == null && bd != null) return 1;
    if (ad != null && bd == null) return -1;
    return a.line.description.toLowerCase().compareTo(
      b.line.description.toLowerCase(),
    );
  });

  return ProjectSchedule(
    deadline: project.deliveryDeadline,
    asOf: now,
    lines: lines,
  );
}

/// The dates for ONE core component.
///
/// Split out of [buildProjectSchedule] so the Core Components list can work out
/// the row it is drawing without deriving the whole job's schedule for every
/// row — a hundred parts costing a hundred passes over a hundred parts is the
/// kind of arithmetic that only shows up on the biggest job somebody owns.
PartScheduleLine schedulePart({
  required MasterPartLine line,
  required BuildingProject project,
  DateTime? asOf,
}) {
  final now = dateOnly(asOf ?? DateTime.now());

  // THREE DATES, MOST SPECIFIC FIRST. The part's own date is somebody saying
  // "this one, earlier"; the track's is the phase it is delivered in; the
  // job's is the fallback for a project that never split into phases. Each
  // level only ever narrows, so a job with no tracks behaves exactly as it did
  // before they existed.
  final own = project.partNeedBy[line.key];
  final track = project.trackForPart(line.key);
  final needBy = own ?? track?.deadline ?? project.deliveryDeadline;

  // TWO SOURCES FOR THE LEAD TIME, job first. What a vendor quoted for THIS
  // order beats what the catalog remembers about the product in general — but
  // the catalog is what stops the figure being retyped on every job, and a
  // product whose lead time was recorded once now schedules itself.
  final jobLead = project.partLeadTimes[line.key];
  final leadDays = jobLead ?? line.catalogLeadDays;
  final leadFromCatalog = jobLead == null && line.catalogLeadDays != null;

  DateTime? orderBy;
  if (needBy != null && leadDays != null) {
    // Calendar days, not a Duration — see [addDays]. A Duration loses a
    // day across the clock change, which is a day of lead time.
    orderBy = addDays(needBy, -leadDays);
  }

  // WHAT HAS BEEN BOUGHT COMES FIRST. A part on order is not late and not due
  // — it is bought, and the only question left is whether the vendor's date
  // still clears the day it is needed. Asking "was this ordered late" of
  // something already ordered is how a warning list starts crying wolf.
  final order = project.orderForPart(line.key);

  final OrderStatus status;
  if (order != null && order.isReceived) {
    status = OrderStatus.received;
  } else if (order != null && order.isOrdered) {
    status = order.arrivesLate(needBy)
        ? OrderStatus.arrivingLate
        : OrderStatus.ordered;
  } else if (needBy == null) {
    status = OrderStatus.noDeadline;
  } else if (leadDays == null) {
    status = OrderStatus.unknown;
  } else if (orderBy!.isBefore(now)) {
    status = OrderStatus.late;
  } else if (daysBetween(now, orderBy) <= kOrderDueSoonDays) {
    status = OrderStatus.dueSoon;
  } else {
    status = OrderStatus.onTrack;
  }

  return PartScheduleLine(
    line: line,
    leadDays: leadDays,
    needBy: needBy,
    needByIsOwn: own != null,
    orderBy: orderBy,
    status: status,
    daysUntilOrder: orderBy == null ? null : daysBetween(now, orderBy),
    track: track,
    leadFromCatalog: leadFromCatalog,
    order: order,
  );
}

/// A date as the timeline writes it: `14 Mar 2026`.
///
/// Spelled month rather than a numeric one, because this app is read on both
/// sides of the Atlantic and 03/04 is two different days depending on who is
/// looking at it. A delivery date is exactly the wrong thing to be ambiguous
/// about.
String formatScheduleDate(DateTime when) =>
    '${when.day} ${_months[when.month - 1]} ${when.year}';

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "in 21 days" / "3 days late" / "today" — a day count in words.
String formatDayGap(int days) {
  if (days == 0) return 'today';
  if (days > 0) return days == 1 ? 'tomorrow' : 'in $days days';
  final late = -days;
  return late == 1 ? '1 day late' : '$late days late';
}

/// A lead time in words: "in stock", "10 days", "6 weeks".
///
/// Weeks once it is past a fortnight, because that is the unit the figure was
/// quoted in and "42 days" makes a reader do arithmetic to recognize the six
/// weeks they were told.
String formatLeadTime(int? days) {
  if (days == null) return 'not asked';
  if (days == 0) return 'in stock';
  if (days < 14 || days % 7 != 0) return '$days days';
  final weeks = days ~/ 7;
  return '$weeks weeks';
}
