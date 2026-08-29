import 'building_project.dart';
import 'project_estimate.dart';
import 'project_schedule.dart';

/// ============================================================================
///  THE ORDER DATES, AS CALENDAR REMINDERS
/// ============================================================================
///  The timeline says what has to be bought and when. It says it inside this
///  app, which is the one place the person who actually raises the purchase
///  order does not look — they live in Outlook, and a date that is not in
///  Outlook is a date that gets missed.
///
///  So the schedule exports as an ICS calendar: one all-day event per order
///  date, each carrying the parts due on it and an alarm a week before. Every
///  mail client and calendar on the planet imports it — Outlook, Gmail, Apple
///  Calendar — and once imported the reminders fire without this app being open.
///
///  ONE EVENT PER DATE, NOT PER PART. An order date is a trip to the purchasing
///  office; eleven parts sharing one date is one event with eleven lines in it,
///  not eleven appointments stacked on a Tuesday. That is also what makes the
///  file re-importable without turning somebody's calendar into a wall.
///
///  STABLE UIDS, so a re-export UPDATES the events already imported rather than
///  duplicating them. The uid is built from the project and the date, and the
///  sequence number rises with each export — which is exactly what a calendar
///  needs to recognise the second file as a revision of the first. Without it,
///  moving the deadline and re-exporting leaves the old dates sitting in the
///  calendar next to the new ones, which is worse than having neither.
///
///  ALL-DAY EVENTS, in local time with no timezone attached (VALUE=DATE). An
///  order-by date is a day, not an instant; giving it a clock time would make
///  it drift across midnight for anybody in another timezone and would put a
///  meaningless 9am block in somebody's day.
/// ============================================================================

/// How long before the order date the alarm goes off.
///
/// A week, because the alarm is not the deadline — it is the nudge to start
/// raising the order, which takes a few days to get quoted and approved. An
/// alarm on the day itself is an alarm that arrives too late to act on.
const int kReminderLeadDays = 7;

/// One line of an ICS file, folded to the 75-octet limit the spec sets.
///
/// Long lines are not a style question here: Outlook truncates or rejects a
/// file whose lines run over, and a part list in a description runs over
/// immediately. Continuation lines begin with a single space.
List<String> _fold(String line) {
  const limit = 73;
  if (line.length <= limit) return [line];
  final out = <String>[line.substring(0, limit)];
  var rest = line.substring(limit);
  while (rest.isNotEmpty) {
    final take = rest.length > limit - 1 ? limit - 1 : rest.length;
    out.add(' ${rest.substring(0, take)}');
    rest = rest.substring(take);
  }
  return out;
}

/// Text as ICS wants it: backslashes, commas, semicolons and newlines escaped.
String _escape(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll(',', r'\,')
    .replaceAll(';', r'\;')
    .replaceAll('\n', r'\n');

/// A date as ICS's `yyyymmdd`, for an all-day event.
String _icsDate(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}'
    '${when.month.toString().padLeft(2, '0')}'
    '${when.day.toString().padLeft(2, '0')}';

/// A UTC timestamp as `yyyymmddThhmmssZ`, for DTSTAMP.
String _icsStamp(DateTime when) {
  final u = when.toUtc();
  return '${_icsDate(u)}T'
      '${u.hour.toString().padLeft(2, '0')}'
      '${u.minute.toString().padLeft(2, '0')}'
      '${u.second.toString().padLeft(2, '0')}Z';
}

/// Only the characters that are safe in a uid, so a project called
/// "Bessey Hall — AV" cannot produce a file a calendar refuses.
String _uidSlug(String text) {
  final buffer = StringBuffer();
  for (final unit in text.toLowerCase().codeUnits) {
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLetter = unit >= 0x61 && unit <= 0x7a;
    buffer.write(isDigit || isLetter ? String.fromCharCode(unit) : '-');
  }
  final slug = buffer.toString().replaceAll(RegExp('-+'), '-');
  return slug.replaceAll(RegExp(r'^-|-$'), '');
}

/// What one exported calendar came to.
class ReminderExport {
  /// The file's contents.
  final String ics;

  /// How many order dates it carries.
  final int events;

  /// Parts that could not be given a date, and why — reported rather than
  /// silently left out, because a calendar that quietly omits the eleven parts
  /// nobody has a lead time for reads as a complete schedule.
  final List<String> skipped;

  const ReminderExport({
    required this.ics,
    required this.events,
    required this.skipped,
  });

  bool get isEmpty => events == 0;
}

/// Builds the calendar for [estimate]'s order dates.
///
/// [sequence] rises on every export of the same project — pass the project's
/// export count — so a calendar treats the new file as a revision of the events
/// it already has rather than as a second set.
///
/// [trackId] limits the export to one delivery phase; '' exports the lot. A
/// purchasing office running the infrastructure order and the tech order as two
/// jobs wants two calendars, not one with both in it.
ReminderExport buildOrderReminders({
  required ProjectEstimate estimate,
  DateTime? asOf,
  DateTime? now,
  int sequence = 0,
  String trackId = '',
}) {
  final project = estimate.project;
  final schedule = buildProjectSchedule(estimate: estimate, asOf: asOf);
  final stamp = _icsStamp(now ?? DateTime.now());
  final jobName = project.name.trim().isEmpty
      ? 'Room Config Builder project'
      : project.name.trim();
  final slug = _uidSlug('$jobName-${project.projectNumber}');

  final chosen = trackId.isEmpty
      ? schedule.lines
      : schedule.linesForTrack(trackId);
  final days = ProjectSchedule.orderDaysOf(chosen);

  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Room Config Builder//Order schedule//EN',
    'CALSCALE:GREGORIAN',
    // PUBLISH rather than REQUEST: this is a file somebody imports, not an
    // invitation to a meeting. REQUEST makes Outlook ask who is attending.
    'METHOD:PUBLISH',
    'X-WR-CALNAME:${_escape('$jobName — order dates')}',
  ];

  for (final day in days) {
    final date = day.date;
    final parts = day.parts;
    final total = parts.fold(0.0, (sum, p) => sum + p.line.qty);

    // What the reminder actually has to say, in the body: what to order, how
    // many, from whom, and what it holds up if it slips.
    final body = StringBuffer()
      ..write('Order these so they arrive in time for $jobName.')
      ..write('\n\n');
    for (final p in parts) {
      body.write('• ${p.line.qty.toStringAsFixed(0)} × ${p.line.description}');
      if (p.line.vendor != null) body.write('  -  ${p.line.vendor!.name}');
      body.write('  (lead ${formatLeadTime(p.leadDays)}');
      if (p.needBy != null) {
        body.write(', on site by ${formatScheduleDate(p.needBy!)}');
      }
      body.write(')\n');
    }
    if (parts.first.track != null) {
      body.write('\nPhase: ${parts.first.track!.name}');
    }
    if (project.projectNumber.trim().isNotEmpty) {
      body.write('\nProject number: ${project.projectNumber.trim()}');
    }

    lines.addAll([
      'BEGIN:VEVENT',
      // Stable across exports, so a re-export revises rather than duplicates.
      'UID:order-${_icsDate(date)}-$slug@room-config-builder',
      'DTSTAMP:$stamp',
      'SEQUENCE:$sequence',
      // All-day: DTEND is exclusive, so it is the following day.
      'DTSTART;VALUE=DATE:${_icsDate(date)}',
      'DTEND;VALUE=DATE:${_icsDate(addDays(date, 1))}',
      ..._fold(
        'SUMMARY:${_escape('Order for $jobName — '
            '${parts.length} part${parts.length == 1 ? '' : 's'} '
            '(${total.toStringAsFixed(0)} units)')}',
      ),
      ..._fold('DESCRIPTION:${_escape(body.toString())}'),
      'CATEGORIES:AV,Purchasing',
      // Busy-free: an order date is not time out of somebody's day.
      'TRANSP:TRANSPARENT',
      'BEGIN:VALARM',
      'ACTION:DISPLAY',
      'TRIGGER:-P${kReminderLeadDays}D',
      ..._fold(
        'DESCRIPTION:${_escape('$jobName — raise the order for '
            '${parts.length} part${parts.length == 1 ? '' : 's'} '
            'in $kReminderLeadDays days')}',
      ),
      'END:VALARM',
      'END:VEVENT',
    ]);
  }

  final skipped = [
    for (final l in chosen)
      // Already bought: nothing to remind anybody to do, and a calendar entry
      // for an order that went out last week is exactly the noise that makes
      // people stop importing these.
      if (l.orderBy == null && !l.isBought)
        '${l.line.description} - '
            '${l.status == OrderStatus.noDeadline ? 'no delivery date' : 'no lead time recorded'}',
  ];

  lines.add('END:VCALENDAR');

  // CRLF, which the spec requires and Outlook enforces.
  return ReminderExport(
    ics: '${lines.join('\r\n')}\r\n',
    events: days.length,
    skipped: skipped,
  );
}

/// The file name a calendar export is offered under.
String reminderFileStem(BuildingProject project, {String trackName = ''}) {
  final base = project.name.trim().isEmpty
      ? 'project'
      : _uidSlug(project.name.trim());
  final phase = trackName.trim().isEmpty ? '' : '_${_uidSlug(trackName)}';
  return '${base.isEmpty ? 'project' : base}${phase}_order_dates';
}
