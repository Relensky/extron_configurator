import 'building_project.dart';
import 'cost_estimate.dart' show formatMoney;
import 'project_estimate.dart';
import 'project_schedule.dart';

/// ============================================================================
///  WHAT CHANGED WHILE YOU WERE AWAY
/// ============================================================================
///  A project gets picked up weeks after it was put down, usually because
///  somebody asked a question about it. Everything needed to answer that
///  question is already in the app — spread across four panes, two of which
///  have to be scrolled and one of which nobody opens unless they suspect
///  something is wrong.
///
///  So opening a project produces a BRIEFING: the handful of things that have
///  gone from "fine" to "needs a decision" since anybody last looked, in one
///  reading, in the order they matter.
///
///    1. WHAT IS LATE — an order date that has passed, a note past its date.
///       These cannot be fixed by working faster and every day of delay costs
///       another day.
///    2. WHAT IS ABOUT TO BE — an order due inside a fortnight, a note due
///       inside a week. Still recoverable, which is the whole point of saying
///       so now.
///    3. WHAT IS NOT ANSWERED — parts with no lead time, no price, no vendor,
///       no spare, no control module. None of these is urgent today and all of
///       them become urgent on somebody else's schedule.
///
///  NOTHING HERE IS NEW INFORMATION. Every line is derived from the project and
///  the rooms, and every line names the pane it can be fixed on. The value is
///  entirely in the fact that nobody had to go looking — a warning that has to
///  be navigated to is a warning that gets found the week after it mattered.
///
///  IT IS ALSO NOT A BLOCKER. A project with nothing wrong produces a briefing
///  that says so and can be dismissed with one key; see [ProjectBriefing.isQuiet],
///  which is what the caller checks before deciding to show it at all.
/// ============================================================================

/// How much attention one briefing line is asking for.
enum BriefingUrgency {
  /// Already gone: a date in the past.
  late,

  /// Coming up, and still avoidable.
  soon,

  /// A question nobody has answered. Not urgent today.
  open,

  /// Nothing wrong — the "all clear" line.
  clear,
}

/// Which pane answers a briefing line, so the reader is pointed at the fix
/// rather than left to hunt for it.
enum BriefingPane { rooms, parts, plans, timeline, vendors, todo }

const Map<BriefingPane, String> kBriefingPaneLabels = {
  BriefingPane.rooms: 'Rooms',
  BriefingPane.parts: 'Core Components',
  BriefingPane.plans: 'Plans',
  BriefingPane.timeline: 'Timeline',
  BriefingPane.vendors: 'Vendors',
  BriefingPane.todo: 'To do',
};

/// One thing worth knowing on the way in.
class BriefingLine {
  final BriefingUrgency urgency;

  /// The headline, written as the thing that is true rather than as a count:
  /// "3 parts are past their order date" reads as a fact, "3 late parts" reads
  /// as a label somebody has to interpret.
  final String message;

  /// The first few specifics, so the line can be acted on without opening
  /// anything. Empty when the message says it all.
  final List<String> detail;

  /// Where it gets fixed.
  final BriefingPane pane;

  const BriefingLine({
    required this.urgency,
    required this.message,
    required this.pane,
    this.detail = const [],
  });
}

/// One open job note, resolved for reading.
///
/// Carries the room's NAME rather than its id — the briefing is a thing to
/// read, and "room3" is not a room — and the two flags the list colours by.
class BriefingTodo {
  final String text;

  /// What it is filed under: a room's building code and number, a scope
  /// somebody typed, or '' for the job as a whole.
  final String scope;

  /// When it has to be done, null when it is simply on the list.
  final DateTime? due;

  /// Past its date. Never true for an item with no date — see
  /// [ProjectTodo.isOverdue].
  final bool late;

  /// Waiting on somebody else, so it is open work nobody here can act on.
  final bool blocked;

  const BriefingTodo({
    required this.text,
    required this.scope,
    required this.due,
    required this.late,
    required this.blocked,
  });
}

/// Where the job stands overall, above the list of things to deal with.
///
/// The list answers "what needs doing"; this answers "what IS this job" — how
/// big, what it costs, when it delivers and when the buying starts. Somebody
/// opening a project after three weeks away needs both, and the second one
/// first: a list of five warnings means something different on a nine-room
/// building due in March than on a one-room job with no date on it.
class BriefingOverview {
  /// Rooms counted, and rooms on the job — they differ when one is excluded
  /// or could not be read.
  final int roomsCosted;
  final int roomsTotal;

  final double grandTotal;
  final String currency;

  /// Parts on the master list, and how many of them nothing can schedule.
  final int parts;
  final int partsWithoutLeadTime;

  /// Bought and not yet arrived, and bought and arrived. The half of the job
  /// that is done — without which "3 parts are late" is a number nobody can
  /// weigh.
  final int partsOnOrder;
  final int partsReceived;

  /// The drawings the job is quoted against, and how many of them are not
  /// where the project says they are.
  ///
  /// A COUNT AND A BREAKAGE, like the rooms above. Which sheets a job came
  /// with is part of what the job IS - somebody picking it up after three
  /// weeks wants to know whether there is a plan set at all before they go
  /// looking for one - and a link that has quietly broken is worth saying
  /// before the day somebody needs the drawing.
  final int plans;
  final int plansMissing;

  /// The job's own delivery deadline, null when nobody has set one.
  final DateTime? deadline;

  /// The delivery phases and their dates, in the project's own order. Empty on
  /// a job that never split into them.
  final List<({String name, DateTime? deadline, int parts})> phases;

  /// The next order that has to go in, and the last date anything is needed —
  /// the two ends of the buying. Null when nothing can be dated.
  final DateTime? firstOrder;
  final DateTime? lastDelivery;

  /// The next few order dates with what is due on each, so the briefing can
  /// show the actual schedule rather than only a count of what is wrong.
  final List<({DateTime date, int parts, bool late})> nextOrders;

  /// The job list, as items rather than as a count.
  ///
  /// "4 job notes are still open" is a number to go and look at; the notes
  /// themselves are the thing somebody came back to the project to read, and
  /// half of them are one line long. Overdue first, then dated, then the rest
  /// — the same order the To do pane shows them in.
  final List<BriefingTodo> todos;

  /// Open items beyond the few listed, so the strip can say what it left out.
  final int moreTodos;

  const BriefingOverview({
    required this.roomsCosted,
    required this.roomsTotal,
    required this.grandTotal,
    required this.currency,
    required this.parts,
    required this.partsWithoutLeadTime,
    required this.partsOnOrder,
    required this.partsReceived,
    required this.plans,
    required this.plansMissing,
    required this.deadline,
    required this.phases,
    required this.firstOrder,
    required this.lastDelivery,
    required this.nextOrders,
    required this.todos,
    required this.moreTodos,
  });
}

/// How many order dates the briefing lists before it stops.
///
/// Four, because the point is "what is coming up", not the whole schedule —
/// the Timeline pane is the whole schedule, and a briefing that reproduces it
/// is one nobody reads to the end of.
const int _maxOrderDates = 4;

/// How many open notes the briefing lists before it stops.
///
/// Six, because this is a reminder of what is outstanding rather than the list
/// itself — the To do pane is the list, and a briefing that reproduces a job's
/// thirty notes is one nobody reads to the end of. What is left out is counted
/// so the strip never pretends to be complete.
const int _maxTodos = 6;

/// The whole briefing, in reading order.
class ProjectBriefing {
  final List<BriefingLine> lines;

  /// What this job is, above what is wrong with it.
  final BriefingOverview overview;

  /// The day it was worked out against.
  final DateTime asOf;

  const ProjectBriefing({
    required this.lines,
    required this.overview,
    required this.asOf,
  });

  List<BriefingLine> _at(BriefingUrgency u) =>
      [for (final l in lines) if (l.urgency == u) l];

  List<BriefingLine> get lateLines => _at(BriefingUrgency.late);
  List<BriefingLine> get soonLines => _at(BriefingUrgency.soon);
  List<BriefingLine> get openLines => _at(BriefingUrgency.open);

  /// True when there is nothing time-critical — no late lines and nothing due
  /// soon. Open questions do not count: a job always has some, and a briefing
  /// that appears every single time is one that gets dismissed unread.
  bool get isQuiet => lateLines.isEmpty && soonLines.isEmpty;

  /// True when there is nothing to say at all.
  bool get isEmpty => lines.isEmpty;
}

/// How many specifics a line names before it stops listing and starts counting.
///
/// Three, because the point of the detail is to make a line actionable without
/// opening anything, and a list of eleven is a list somebody has to read rather
/// than glance at — at which point they may as well open the pane.
const int _maxDetail = 3;

/// Names the first few of [all], then says how many more there are.
List<String> _some(Iterable<String> all) {
  final list = all.toList();
  if (list.length <= _maxDetail) return list;
  return [
    ...list.take(_maxDetail),
    'and ${list.length - _maxDetail} more',
  ];
}

/// Works out what somebody opening this project needs to know.
///
/// [asOf] is the day the dates are measured against; it defaults to today and
/// is passed explicitly only by tests, which need an answer that does not
/// change with the clock.
ProjectBriefing buildProjectBriefing({
  required ProjectEstimate estimate,
  DateTime? asOf,
}) {
  final now = dateOnly(asOf ?? DateTime.now());
  final project = estimate.project;
  final schedule = buildProjectSchedule(estimate: estimate, asOf: now);
  final lines = <BriefingLine>[];

  // --- 1. what is already late ---------------------------------------------

  final lateParts = schedule.lateLines;
  if (lateParts.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.late,
      message: lateParts.length == 1
          ? '1 part is past the date it had to be ordered on'
          : '${lateParts.length} parts are past the date they had to be '
              'ordered on',
      pane: BriefingPane.timeline,
      detail: _some([
        for (final p in lateParts)
          '${p.line.description} - order date was '
              '${formatScheduleDate(p.orderBy!)}'
              ' (${formatDayGap(p.daysUntilOrder ?? 0)})',
      ]),
    ));
  }

  // BOUGHT, AND STILL GOING TO BE LATE. Nothing on the ordering side can fix
  // this one — which is exactly why it has to be said out loud rather than
  // left to be discovered in the week the room needs the part.
  final arrivingLate = schedule.arrivingLateLines;
  if (arrivingLate.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.late,
      message: arrivingLate.length == 1
          ? '1 part is on order but the vendor is promising it after the day '
              'it is needed'
          : '${arrivingLate.length} parts are on order but the vendor is '
              'promising them after the day they are needed',
      pane: BriefingPane.timeline,
      detail: _some([
        for (final p in arrivingLate)
          '${p.line.description} - promised '
              '${formatScheduleDate(p.order!.expectedOn!)}, needed '
              '${formatScheduleDate(p.needBy!)}',
      ]),
    ));
  }

  final overdue = project.overdueTodos(now);
  if (overdue.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.late,
      message: overdue.length == 1
          ? '1 job note is past its date'
          : '${overdue.length} job notes are past their date',
      pane: BriefingPane.todo,
      detail: _some([
        for (final t in overdue)
          '${t.text} - due ${formatScheduleDate(t.due!)}'
              ' (${formatDayGap(t.daysUntilDue(now) ?? 0)})',
      ]),
    ));
  }

  // The deadline itself having gone is worth its own line: every order date on
  // the job is worked back from it, so they are all wrong until it is moved.
  final deadline = project.deliveryDeadline;
  if (deadline != null && deadline.isBefore(now)) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.late,
      message: 'The delivery deadline (${formatScheduleDate(deadline)}) has '
          'passed. Every order date on this job is worked back from it.',
      pane: BriefingPane.timeline,
    ));
  }

  // --- 2. what is about to be ----------------------------------------------

  final dueSoon = schedule.dueSoonLines;
  if (dueSoon.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.soon,
      message: dueSoon.length == 1
          ? '1 part has to be ordered within the next $kOrderDueSoonDays days'
          : '${dueSoon.length} parts have to be ordered within the next '
              '$kOrderDueSoonDays days',
      pane: BriefingPane.timeline,
      detail: _some([
        for (final p in dueSoon)
          '${p.line.description} - order by '
              '${formatScheduleDate(p.orderBy!)}'
              ' (${formatDayGap(p.daysUntilOrder ?? 0)})',
      ]),
    ));
  }

  final todosSoon = project.todosDueSoon(asOf: now);
  if (todosSoon.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.soon,
      message: todosSoon.length == 1
          ? '1 job note is due this week'
          : '${todosSoon.length} job notes are due this week',
      pane: BriefingPane.todo,
      detail: _some([
        for (final t in todosSoon)
          '${t.text} - ${formatDayGap(t.daysUntilDue(now) ?? 0)}',
      ]),
    ));
  }

  // --- 3. what nobody has answered -----------------------------------------

  final noLead = schedule.unknownLines;
  if (noLead.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.open,
      message: noLead.length == 1
          ? '1 part has no lead time, so it is not on the timeline'
          : '${noLead.length} parts have no lead time, so they are not on the '
              'timeline',
      pane: BriefingPane.parts,
      detail: _some([for (final p in noLead) p.line.description]),
    ));
  }

  if (project.deliveryDeadline == null && estimate.master.isNotEmpty) {
    lines.add(const BriefingLine(
      urgency: BriefingUrgency.open,
      message: 'No delivery deadline is set, so nothing can be scheduled.',
      pane: BriefingPane.timeline,
    ));
  }

  // The open notes are NOT counted into a line here. They are listed in full
  // in the overview above — see [BriefingOverview.todos] — and a line saying
  // "4 job notes are still open" directly over a list of those four notes is
  // the same fact twice. What survives as a line is the two that are about
  // TIME rather than about the work: past its date, and due this week.

  if (estimate.failedRooms > 0) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.open,
      message: estimate.failedRooms == 1
          ? '1 room could not be read, so the project total is short by '
              'whatever it costs'
          : '${estimate.failedRooms} rooms could not be read, so the project '
              'total is short by whatever they cost',
      pane: BriefingPane.rooms,
      detail: _some([
        for (final r in estimate.rooms)
          if (!r.ok) '${r.name} - ${r.room.error}',
      ]),
    ));
  }

  if (estimate.unpricedParts > 0) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.open,
      message: estimate.unpricedParts == 1
          ? '1 part has no price anywhere on the job'
          : '${estimate.unpricedParts} parts have no price anywhere on the job',
      pane: BriefingPane.parts,
      detail: _some([
        for (final l in estimate.master)
          if (l.unpriced) l.description,
      ]),
    ));
  }

  if (estimate.untaggedParts > 0) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.open,
      message: estimate.untaggedParts == 1
          ? '1 part is not tagged to a vendor, so it is on no quote request'
          : '${estimate.untaggedParts} parts are not tagged to a vendor, so '
              'they are on no quote request',
      pane: BriefingPane.vendors,
      detail: _some([
        for (final l in estimate.master)
          if (l.vendor == null) l.description,
      ]),
    ));
  }

  if (estimate.undrivenDevices > 0) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.open,
      message: '${estimate.undrivenDevices} device'
          '${estimate.undrivenDevices == 1 ? '' : 's'} on this job have no '
          'control module - quoted, and they will not commission as they '
          'stand',
      pane: BriefingPane.parts,
      detail: _some([
        for (final l in estimate.master)
          if (l.hasControlGap) '${l.description} ×${l.undrivenQty}',
      ]),
    ));
  }

  // Not a mistake, and not the app's decision — but nothing else was ever
  // going to raise it, because a spare is not on any drawing.
  if (estimate.spareUnits == 0 && estimate.partsWithoutSpares.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.open,
      message: 'Nothing on this job has a spare. '
          '${estimate.partsWithoutSpares.length} '
          'product${estimate.partsWithoutSpares.length == 1 ? '' : 's'} would '
          'be replaced out of the next budget rather than off the shelf.',
      pane: BriefingPane.parts,
    ));
  }

  if (estimate.mixedCurrency) {
    lines.add(const BriefingLine(
      urgency: BriefingUrgency.open,
      message: 'Rooms on this job are quoted in different currencies, and the '
          'totals add them as though they were the same one.',
      pane: BriefingPane.rooms,
    ));
  }

  // A DRAWING THAT IS NOT THERE ANY MORE. The plan list points at files rather
  // than copying them - see [ProjectPlan] for why - and the cost of that is a
  // link that breaks silently when somebody tidies a folder. Silently is the
  // problem: it is discovered on the day the drawing is wanted, which is never
  // a day with time in it.
  final missingPlans = missingProjectPlans(estimate);
  if (missingPlans.isNotEmpty) {
    lines.add(BriefingLine(
      urgency: BriefingUrgency.open,
      message: missingPlans.length == 1
          ? '1 building plan is not where the project says it is'
          : '${missingPlans.length} building plans are not where the project '
              'says they are',
      pane: BriefingPane.plans,
      detail: _some([
        for (final plan in missingPlans)
          '${plan.displayName} - ${plan.filePath}',
      ]),
    ));
  }

  if (lines.isEmpty) {
    lines.add(const BriefingLine(
      urgency: BriefingUrgency.clear,
      message: 'Nothing needs attention: every part is priced, tagged and '
          'scheduled, and the job list is clear.',
      pane: BriefingPane.rooms,
    ));
  }

  return ProjectBriefing(
    lines: lines,
    overview: _overviewOf(estimate, schedule, now),
    asOf: now,
  );
}

/// What the job IS, as opposed to what is wrong with it.
BriefingOverview _overviewOf(
  ProjectEstimate estimate,
  ProjectSchedule schedule,
  DateTime now,
) {
  final project = estimate.project;

  // The order dates that are still ahead, plus any that have gone — a date
  // that has passed is the most important one on the list, so it is not
  // filtered out for being in the past.
  final days = schedule.orderDays;
  final upcoming = [
    for (final d in days)
      (
        date: d.date,
        parts: d.parts.length,
        late: d.date.isBefore(now),
      ),
  ];

  // The job list, in the order the To do pane shows it: overdue first, then
  // whatever carries a date, then the undated ones oldest-first. Blocked ones
  // sink, being open work nobody here can act on today.
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};
  final open = [...project.openTodos]..sort((a, b) {
    final aLate = a.isOverdue(now);
    final bLate = b.isOverdue(now);
    if (aLate != bLate) return aLate ? -1 : 1;
    final aBlocked = a.state == ProjectTodoState.blocked;
    final bBlocked = b.state == ProjectTodoState.blocked;
    if (aBlocked != bBlocked) return aBlocked ? 1 : -1;
    final ad = a.due;
    final bd = b.due;
    if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
    if (ad == null && bd != null) return 1;
    if (ad != null && bd == null) return -1;
    return a.created.compareTo(b.created);
  });
  final shown = open.length > _maxTodos ? open.sublist(0, _maxTodos) : open;

  return BriefingOverview(
    roomsCosted: estimate.costedRooms.length,
    roomsTotal: estimate.rooms.length,
    grandTotal: estimate.grandTotal,
    currency: estimate.currency,
    parts: estimate.master.length,
    partsWithoutLeadTime: schedule.unknownCount,
    partsOnOrder: schedule.onOrderCount,
    partsReceived: schedule.receivedCount,
    plans: project.plans.length,
    plansMissing: missingProjectPlans(estimate).length,
    deadline: project.deliveryDeadline,
    phases: [
      for (final entry in schedule.byTrack(project))
        if (entry.track != null)
          (
            name: entry.track!.name,
            deadline: entry.track!.deadline ?? project.deliveryDeadline,
            parts: entry.parts.length,
          ),
    ],
    firstOrder: schedule.firstOrderDate,
    lastDelivery: schedule.lastNeedDate,
    nextOrders: upcoming.length > _maxOrderDates
        ? upcoming.sublist(0, _maxOrderDates)
        : upcoming,
    todos: [
      for (final t in shown)
        BriefingTodo(
          text: t.text,
          scope: t.roomId.isNotEmpty
              ? (roomNames[t.roomId] ?? t.roomId)
              : t.scopeLabel.trim(),
          due: t.due,
          late: t.isOverdue(now),
          blocked: t.state == ProjectTodoState.blocked,
        ),
    ],
    moreTodos: open.length - shown.length,
  );
}

// ---------------------------------------------------------------------------
//  THE BRIEFING AS TEXT
// ---------------------------------------------------------------------------

/// The whole briefing as plain text, for the clipboard.
///
/// WHY THIS EXISTS. The briefing answers "where does this job stand", and that
/// question is almost never asked by the person looking at the screen — it is
/// asked by a manager on email, a client on a call, or a colleague in a chat
/// window, and the answer has until now had to be retyped out of a dialog by
/// somebody reading it off. Retyped status is status that goes stale, loses the
/// dates, and quietly drops whichever line the typist judged unimportant.
///
/// PLAIN TEXT, not a table and not a spreadsheet. It is pasted into a message
/// body, so it has to survive a proportional font and a narrow window: no
/// column rules, no padding that only lines up in a monospaced font beyond the
/// one short label column, and nothing that reads as broken when a client's
/// mail app rewraps it.
///
/// IT SAYS THE SAME THINGS THE DIALOG DOES, in the same order, including the
/// pane that fixes each line. A copy that summarised harder than the screen
/// would be a second, quieter briefing — and the moment the two disagree the
/// written one is the one that gets believed, because it is the one in the
/// email.
String renderBriefingText(ProjectBriefing briefing, {required String title}) {
  final o = briefing.overview;
  final out = StringBuffer();

  out.writeln(title.trim().isEmpty ? 'Project' : title.trim());
  out.writeln('Where it stands on ${formatScheduleDate(briefing.asOf)}');
  out.writeln();

  // The label column is padded because these are facts read as pairs; nothing
  // else in the document is, so nothing else is aligned.
  void fact(String label, String value) =>
      out.writeln('${label.padRight(18)}$value');

  fact(
    'Rooms',
    o.roomsCosted == o.roomsTotal
        ? '${o.roomsCosted}'
        : '${o.roomsCosted} of ${o.roomsTotal} counted',
  );
  fact('Project total', formatMoney(o.grandTotal, o.currency));
  fact(
    'Core components',
    o.partsWithoutLeadTime == 0
        ? '${o.parts}'
        : '${o.parts} · ${o.partsWithoutLeadTime} with no lead time',
  );
  if (o.partsOnOrder > 0 || o.partsReceived > 0) {
    fact(
      'Bought',
      [
        if (o.partsOnOrder > 0) '${o.partsOnOrder} on order',
        if (o.partsReceived > 0) '${o.partsReceived} arrived',
      ].join(' · '),
    );
  }
  // Same fact, same place as the dialog's - see the note above about the two
  // never being allowed to disagree.
  if (o.plans > 0) {
    fact(
      'Plans',
      o.plansMissing == 0
          ? '${o.plans}'
          : '${o.plans} · ${o.plansMissing} not where the project says',
    );
  }
  fact(
    'Delivery',
    o.deadline == null
        ? 'no deadline set'
        : '${formatScheduleDate(o.deadline!)} · '
              '${formatDayGap(daysBetween(briefing.asOf, o.deadline!))}',
  );
  for (final phase in o.phases) {
    fact(
      phase.name,
      phase.deadline == null
          ? '${phase.parts} ${_parts(phase.parts)} - no date'
          : '${formatScheduleDate(phase.deadline!)} · ${phase.parts} '
                '${_parts(phase.parts)}',
    );
  }
  if (o.firstOrder != null) {
    fact(
      'Buying runs',
      '${formatScheduleDate(o.firstOrder!)}'
      '${o.lastDelivery == null ? '' : ' -> '
          '${formatScheduleDate(o.lastDelivery!)}'}',
    );
  }

  if (o.nextOrders.isNotEmpty) {
    out.writeln();
    out.writeln('ORDER BY');
    for (final day in o.nextOrders) {
      out.writeln(
        '  ${formatScheduleDate(day.date)} - ${day.parts} '
        '${_parts(day.parts)} · '
        '${formatDayGap(daysBetween(briefing.asOf, day.date))}',
      );
    }
  }

  if (o.todos.isNotEmpty) {
    out.writeln();
    out.writeln('STILL TO DO');
    for (final todo in o.todos) {
      final tail = [
        if (todo.scope.isNotEmpty) todo.scope,
        if (todo.due != null)
          todo.late
              ? 'due ${formatScheduleDate(todo.due!)} - '
                    '${formatDayGap(daysBetween(briefing.asOf, todo.due!))}'
              : 'due ${formatScheduleDate(todo.due!)}',
        if (todo.blocked) 'waiting on somebody',
      ].join(' · ');
      out.writeln('  - ${todo.text}${tail.isEmpty ? '' : '  ($tail)'}');
    }
    if (o.moreTodos > 0) out.writeln('  ... and ${o.moreTodos} more');
  }

  void block(String heading, List<BriefingLine> lines) {
    if (lines.isEmpty) return;
    out.writeln();
    out.writeln(heading.toUpperCase());
    for (final line in lines) {
      out.writeln('  ${line.message}');
      for (final d in line.detail) {
        out.writeln('      · $d');
      }
      // The pane that fixes it travels with the line, because a status mail
      // that says what is wrong and not where it is answered is a mail that
      // comes straight back as a question.
      if (line.urgency != BriefingUrgency.clear) {
        out.writeln('      Fixed on ${kBriefingPaneLabels[line.pane]}');
      }
    }
  }

  block('Already late', briefing.lateLines);
  block('Coming up', briefing.soonLines);
  block('Still open', briefing.openLines);
  final clear = [
    for (final l in briefing.lines)
      if (l.urgency == BriefingUrgency.clear) l,
  ];
  if (clear.isNotEmpty) {
    out.writeln();
    for (final l in clear) {
      out.writeln(l.message);
    }
  }

  return '${out.toString().trimRight()}\n';
}

/// 'part' or 'parts'. Its own function because the briefing says it eleven
/// times and a status mail with "1 parts" in it reads as machine output.
String _parts(int n) => n == 1 ? 'part' : 'parts';
