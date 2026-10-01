import 'building_project.dart';
import 'class_schedule.dart';
import 'install_windows.dart';
import 'project_schedule.dart' show formatScheduleDate;
import 'report_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE CLASS SCHEDULE TAB
/// ============================================================================
///  Written when the job has install windows on its timeline. Three parts:
///
///    * the windows as a Gantt chart - a row per room, a column per day;
///    * each room's week in half-hour slots, classes beside the windows;
///    * the classes themselves, for the terms the windows fall in.
///
///  Colored cells rather than a chart object, so it reads the same in Excel,
///  in Google Sheets and in the plain-text copy.
/// ============================================================================

/// The tab's name.
const String kClassScheduleSheet = 'Class Schedule';

/// An install window's cell.
const _installFill = 'C8E6C9';
const _installInk = '1B5E20';

/// A class meeting's cell.
const _classFill = 'BBDEFB';
const _classInk = '0D47A1';

/// A day with classes and no window.
const _busyFill = 'E0E0E0';
const _busyInk = '424242';

/// Longest run of days drawn day by day. A job spread wider than this draws
/// only the days that have a window, or the chart is hundreds of columns.
const int _maxGanttDays = 92;

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

XlsxTint _install(String text) =>
    XlsxTint(text: text, fillHex: _installFill, inkHex: _installInk);

XlsxTint _class(String text) =>
    XlsxTint(text: text, fillHex: _classFill, inkHex: _classInk);

XlsxTint _busy(String text) =>
    XlsxTint(text: text, fillHex: _busyFill, inkHex: _busyInk);

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// `8a-12:30p`, short enough for a day column.
String _shortTime(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12${m == 0 ? '' : ':${m.toString().padLeft(2, '0')}'}'
      '${h >= 12 ? 'p' : 'a'}';
}

String _windowText(InstallWindow w) => w.wholeDay
    ? 'All day'
    : '${_shortTime(w.startMinutes)}-${_shortTime(w.endMinutes)}';

/// The Class Schedule tab's sections, or none when the job has no install
/// windows. [schedule] may be empty - the windows are still charted.
List<ReportSection> classScheduleSections(
  BuildingProject project,
  ClassScheduleIndex schedule,
) {
  final windows = [...project.installWindows]
    ..sort((a, b) => a.start.compareTo(b.start));
  if (windows.isEmpty) return const [];

  // Rooms in the order their first window comes.
  final byRoom = <String, List<InstallWindow>>{};
  for (final w in windows) {
    (byRoom[w.roomId] ??= []).add(w);
  }
  String code(String roomId) => byRoom[roomId]!.first.roomCode;

  // The classes that meet while each room's windows are open.
  List<ScheduledClass> classesFor(String roomId) {
    final list = byRoom[roomId]!;
    final first = _dayOf(list.first.day);
    final last = _dayOf(list.last.day);
    return [
      for (final c in schedule.classesIn(code(roomId)))
        if (!c.endDate.isBefore(first) && !c.startDate.isAfter(last)) c,
    ]..sort((a, b) {
        final byDate = a.startDate.compareTo(b.startDate);
        return byDate != 0 ? byDate : a.startMinutes.compareTo(b.startMinutes);
      });
  }

  final sections = <ReportSection>[];

  // --- the windows by date -------------------------------------------------
  final first = _dayOf(windows.first.day);
  final last = _dayOf(windows.last.day);
  final span = last.difference(first).inDays + 1;
  final everyDay = span <= _maxGanttDays;
  final days = everyDay
      ? [for (var i = 0; i < span; i++) DateTime(first.year, first.month, first.day + i)]
      : {for (final w in windows) _dayOf(w.day)}.toList();

  sections.add((
    title: everyDay
        ? 'Maintenance windows by date'
        : 'Maintenance windows by date (days with a window only)',
    header: [
      'Room',
      for (final d in days) '${_weekdays[d.weekday - 1]} ${d.month}/${d.day}',
    ],
    rows: [
      for (final roomId in byRoom.keys)
        () {
          final classes = classesFor(roomId);
          return <dynamic>[
            byRoom[roomId]!.first.roomLabel,
            for (final d in days)
              () {
                final here = [
                  for (final w in byRoom[roomId]!)
                    if (_dayOf(w.day) == d) w,
                ];
                if (here.isNotEmpty) {
                  return _install(here.map(_windowText).join(', '));
                }
                if (classes.any((c) => c.meetsOn(d))) return _busy('');
                return '';
              }(),
          ];
        }(),
    ],
  ));
  sections.add((
    title: 'Key',
    header: const ['', ''],
    rows: [
      [_install('8a-12p'), 'Maintenance window, with its hours'],
      [_class('ART 101'), 'Class meeting'],
      [_busy(''), 'Classes that day, no window'],
    ],
  ));

  // --- each room's week ----------------------------------------------------
  for (final roomId in byRoom.keys) {
    final classes = classesFor(roomId);
    final timed = [
      for (final w in byRoom[roomId]!)
        if (!w.wholeDay) w,
    ];
    if (classes.isEmpty && timed.isEmpty) continue;

    // 7 am to 10 pm, stretched to anything outside it, in half hours.
    var from = 7 * 60;
    var to = 22 * 60;
    for (final c in classes) {
      if (c.startMinutes < from) from = c.startMinutes;
      if (c.endMinutes > to) to = c.endMinutes;
    }
    for (final w in timed) {
      if (w.startMinutes < from) from = w.startMinutes;
      if (w.endMinutes > to) to = w.endMinutes;
    }
    from = from ~/ 30 * 30;
    to = (to + 29) ~/ 30 * 30;
    final slots = [for (var m = from; m < to; m += 30) m];

    final letters = ['M', 'T', 'W', 'R', 'F'];
    for (final extra in ['S', 'U']) {
      if (classes.any((c) => c.days.contains(extra)) ||
          timed.any((w) => scheduleDayLetter(w.day) == extra)) {
        letters.add(extra);
      }
    }
    const names = {
      'M': 'Mon',
      'T': 'Tue',
      'W': 'Wed',
      'R': 'Thu',
      'F': 'Fri',
      'S': 'Sat',
      'U': 'Sun',
    };

    sections.add((
      title: '${code(roomId)} - the week',
      header: [
        'Day',
        for (final m in slots) _shortTime(m),
      ],
      rows: [
        for (final letter in letters)
          <dynamic>[
            names[letter],
            for (final m in slots)
              () {
                // Classes first: a window is only ever put in a gap.
                for (final c in classes) {
                  if (!c.days.contains(letter)) continue;
                  if (m + 30 <= c.startMinutes || m >= c.endMinutes) continue;
                  final starts = m <= c.startMinutes;
                  return _class(starts ? c.courseLabel : '');
                }
                for (final w in timed) {
                  if (scheduleDayLetter(w.day) != letter) continue;
                  if (m + 30 <= w.startMinutes || m >= w.endMinutes) continue;
                  final starts = m <= w.startMinutes;
                  return _install(
                    starts ? 'Maint. ${w.day.month}/${w.day.day}' : '',
                  );
                }
                return '';
              }(),
          ],
      ],
    ));
  }

  // --- the classes ---------------------------------------------------------
  final classRows = <List<dynamic>>[
    for (final roomId in byRoom.keys)
      for (final c in classesFor(roomId))
        [
          code(roomId),
          c.courseLabel,
          c.title,
          c.days,
          '${formatScheduleMinutes(c.startMinutes)} - '
              '${formatScheduleMinutes(c.endMinutes)}',
          '${formatScheduleDate(c.startDate)} - '
              '${formatScheduleDate(c.endDate)}',
          formatCsuTerm(c.term),
        ],
  ];
  sections.add((
    title: 'Classes in these rooms',
    header: const ['Room', 'Course', 'Title', 'Days', 'Time', 'Dates', 'Term'],
    rows: classRows.isNotEmpty
        ? classRows
        : [
            [
              schedule.isEmpty
                  ? 'The class schedule could not be read, so no classes are '
                      'shown.'
                  : 'No classes meet in these rooms while their windows are '
                      'open.',
            ],
          ],
  ));

  return sections;
}
