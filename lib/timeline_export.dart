import 'building_project.dart';
import 'project_schedule.dart';
import 'report_tools.dart';
import 'xlsx_writer.dart' show XlsxSheet;

/// ============================================================================
///  THE TIMELINE AS A DOCUMENT
/// ============================================================================
///  Every date on the job in one list - order dates, phases, the deadline,
///  packages, install days - and every note on the job list, dated or not.
///  The same rows make the spreadsheet, the text list and the picture.
/// ============================================================================

/// One line of the exported timeline. [date] is null for a job-list note
/// with no date on it.
typedef TimelineEntry = ({
  DateTime? date,
  String what,
  String item,
  String detail,
  String status,
});

/// Where a note has got to, as the timeline says it.
String todoTimelineStatus(ProjectTodo t, DateTime asOf) => switch (t.state) {
  ProjectTodoState.open => t.isOverdue(asOf) ? 'Past its date' : 'To do',
  ProjectTodoState.blocked =>
    t.waitingNote.trim().isEmpty
        ? 'Waiting on'
        : 'Waiting on: ${t.waitingNote.trim()}',
  ProjectTodoState.done => [
    'Done',
    if (t.completed != null) formatIsoDate(t.completed!),
    if (t.completedBy.isNotEmpty) 'by ${t.completedBy}',
  ].join(' '),
};

/// The columns, in order.
const List<String> kTimelineColumns = [
  'Date',
  'What',
  'Item',
  'Details',
  'Status',
];

/// Every entry on the job's timeline, dated ones in date order and the
/// job-list notes with no date after them. [roomNames] names the rooms a note
/// is filed under, by room id.
List<TimelineEntry> timelineEntries(
  ProjectSchedule schedule,
  BuildingProject project, {
  Map<String, String> roomNames = const {},
}) {
  final out = <TimelineEntry>[];

  // Order dates, one row per part.
  for (final l in schedule.lines) {
    if (l.orderBy == null) continue;
    final name = l.line.description.trim().isNotEmpty
        ? l.line.description.trim()
        : l.line.model.trim();
    out.add((
      date: l.orderBy,
      what: 'Order by',
      item: name,
      detail: [
        'Qty ${_qty(l.line.qty)}',
        if (l.needBy != null) 'needed ${formatIsoDate(l.needBy!)}',
        if (l.track != null) l.trackName,
      ].join(', '),
      status: kOrderStatusLabels[l.status] ?? '',
    ));
  }

  if (schedule.deadline != null) {
    out.add((
      date: schedule.deadline,
      what: 'Deadline',
      item: 'Delivery deadline',
      detail: '',
      status: '',
    ));
  }

  for (final t in project.tracks) {
    if (t.deadline != null) {
      out.add((
        date: t.deadline,
        what: 'Phase',
        item: t.name,
        detail: 'On site',
        status: t.completion == null ? '' : 'Finished',
      ));
    }
    if (t.completion != null) {
      out.add((
        date: t.completion,
        what: 'Phase',
        item: t.name,
        detail: 'Finished',
        status: 'Finished',
      ));
    }
  }

  for (final rfq in project.rfqs) {
    final sent = [
      for (final b in rfq.bids)
        if (b.sentOn != null) b.sentOn!,
    ];
    final quoted = [
      for (final b in rfq.bids)
        if (b.quotedOn != null) b.quotedOn!,
    ];
    if (sent.isNotEmpty) {
      out.add((
        date: sent.reduce((a, b) => a.isBefore(b) ? a : b),
        what: 'Package',
        item: rfq.name,
        detail: 'Sent to ${rfq.bids.where((b) => b.isSent).length}',
        status: '',
      ));
    }
    if (quoted.isNotEmpty) {
      out.add((
        date: quoted.reduce((a, b) => a.isAfter(b) ? a : b),
        what: 'Package',
        item: rfq.name,
        detail: 'Last quote in',
        status: '',
      ));
    }
    if (rfq.awardedOn != null) {
      out.add((
        date: rfq.awardedOn,
        what: 'Package',
        item: rfq.name,
        detail: 'Awarded',
        status: 'Awarded',
      ));
    }
  }

  for (final w in project.installWindows) {
    out.add((
      date: w.day,
      what: 'Install day',
      item: w.roomCode,
      detail: '',
      status: '',
    ));
  }

  // EVERY NOTE ON THE JOB LIST, dated or not, done or not.
  for (final t in project.todos) {
    final about = t.roomId.isNotEmpty
        ? (roomNames[t.roomId] ?? '')
        : t.scopeLabel.trim();
    out.add((
      date: t.due,
      what: 'To do',
      item: t.text.trim(),
      detail: about,
      status: todoTimelineStatus(t, schedule.asOf),
    ));
  }

  out.sort((a, b) {
    final ad = a.date, bd = b.date;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  });
  return out;
}

String _qty(double q) =>
    q == q.roundToDouble() ? q.toInt().toString() : q.toString();

/// The entries as report sections: the dates, then the notes with none.
List<ReportSection> timelineSections(List<TimelineEntry> entries) {
  List<dynamic> row(TimelineEntry e) => [
    e.date == null ? '' : formatIsoDate(e.date!),
    e.what,
    e.item,
    e.detail,
    e.status,
  ];
  final dated = [for (final e in entries) if (e.date != null) e];
  final undated = [for (final e in entries) if (e.date == null) e];
  return [
    if (dated.isNotEmpty)
      (title: 'Dates', header: kTimelineColumns, rows: [for (final e in dated) row(e)]),
    if (undated.isNotEmpty)
      (
        title: 'Job list - no date',
        header: kTimelineColumns,
        rows: [for (final e in undated) row(e)],
      ),
  ];
}

/// The timeline's title for [projectName].
String timelineTitle(String projectName) =>
    projectName.trim().isEmpty ? 'Timeline' : '${projectName.trim()} - Timeline';

/// The timeline as a spreadsheet tab.
XlsxSheet timelineSheet(
  String projectName,
  List<TimelineEntry> entries, {
  DateTime? generated,
}) => buildStackedReportSheet(
  sheetName: 'Timeline',
  title: timelineTitle(projectName),
  sections: timelineSections(entries),
  generated: generated,
);

/// The timeline as a plain list, for the clipboard or a .txt file.
String timelineText(
  String projectName,
  List<TimelineEntry> entries, {
  DateTime? generated,
}) => renderTextReport(
  timelineTitle(projectName),
  timelineSections(entries),
  generated: generated,
);
