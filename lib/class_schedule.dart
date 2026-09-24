import 'dart:io';

/// ============================================================================
///  WHEN IS THE ROOM FREE - install windows off the class schedule
/// ============================================================================
///  The Facilities export (FacilitiesLinkClassScheduleDaily.csv, the same file
///  the CTS-Dashboard reads) lists every class section: term, the room, the
///  days it meets, the start and end times, and the dates the section runs.
///  A classroom can only be worked on when nothing is meeting in it, so an
///  install is planned into the GAPS: the hours between classes on a teaching
///  day, and the whole days with nothing booked - weekends, breaks, the weeks
///  between terms.
///
///  The parsing is ported from the dashboard's `_parseScheduleCsvInBackground`
///  (term codes, `23-JAN-23` dates, 24-hour `HH:MM` times, online / TBA rows
///  dropped) so both apps read the export the same way.
/// ============================================================================

/// One class section that meets in a room.
class ScheduledClass {
  final String term;
  final String subject;
  final String number;
  final String title;
  final String building;
  final String room;

  /// Meeting days as the export writes them: `MWF`, `TR`. R is Thursday,
  /// S Saturday, U Sunday.
  final String days;

  /// Minutes after midnight.
  final int startMinutes;
  final int endMinutes;

  /// The first and last day the section meets.
  final DateTime startDate;
  final DateTime endDate;

  const ScheduledClass({
    required this.term,
    required this.subject,
    required this.number,
    required this.title,
    required this.building,
    required this.room,
    required this.days,
    required this.startMinutes,
    required this.endMinutes,
    required this.startDate,
    required this.endDate,
  });

  String get roomLabel => '$building $room';

  String get courseLabel =>
      [subject, number].where((s) => s.isNotEmpty).join(' ');

  /// Whether it meets on [day].
  bool meetsOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    if (d.isBefore(startDate) || d.isAfter(endDate)) return false;
    return days.contains(scheduleDayLetter(d));
  }
}

/// The export's day letter for a date: M T W R F S U.
String scheduleDayLetter(DateTime d) =>
    const ['M', 'T', 'W', 'R', 'F', 'S', 'U'][d.weekday - 1];

/// `BSS 103`, `bss-103` and `BSS103` are one room.
String scheduleRoomKey(String s) =>
    s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// CSU term codes: `2242` is Spring 2024 (2 = Spring, 6 = Summer, 8 = Fall,
/// 1 = Winter). Anything else is returned as it was.
String formatCsuTerm(String code) {
  final c = code.trim();
  if (c.length == 4 && c.startsWith('2')) {
    final year = 2000 + (int.tryParse(c.substring(1, 3)) ?? 0);
    final season = switch (c.substring(3)) {
      '1' => 'Winter',
      '2' => 'Spring',
      '6' => 'Summer',
      '8' => 'Fall',
      _ => '',
    };
    if (season.isNotEmpty) return '$season $year';
  }
  return c;
}

const _months = {
  'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
  'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
};

/// `23-JAN-23` or `24-JAN-2022`. Null for anything else.
DateTime? parseScheduleDate(String raw) {
  final parts = raw.trim().split('-');
  if (parts.length != 3) return null;
  final day = int.tryParse(parts[0]);
  final month = _months[parts[1].toUpperCase()];
  var year = int.tryParse(parts[2]);
  if (day == null || month == null || year == null) return null;
  if (year < 100) year += 2000;
  return DateTime(year, month, day);
}

/// `14:30` as minutes after midnight.
int? parseScheduleMinutes(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0].trim());
  final m = int.tryParse(parts[1].trim());
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// `14:30` -> `2:30 pm`.
String formatScheduleMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final suffix = h >= 12 ? 'pm' : 'am';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${m.toString().padLeft(2, '0')} $suffix';
}

/// A small, quote-aware CSV reader - enough for the Facilities export, which
/// quotes every field and doubles embedded quotes.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
      continue;
    }
    switch (c) {
      case '"':
        quoted = true;
      case ',':
        row.add(field.toString());
        field.clear();
      case '\n':
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
      case '\r':
        break;
      default:
        field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// Every in-person class in the export, by room.
class ClassScheduleIndex {
  final Map<String, List<ScheduledClass>> _byRoom;

  /// The file it was read from.
  final String source;

  /// Terms in the file, newest last.
  final List<String> terms;

  ClassScheduleIndex._(this._byRoom, this.source, this.terms);

  static final empty = ClassScheduleIndex._(const {}, '', const []);

  bool get isEmpty => _byRoom.isEmpty;

  int get roomCount => _byRoom.length;

  /// The classes that meet in [room] (`BSS 103`, any spelling).
  List<ScheduledClass> classesIn(String room) =>
      _byRoom[scheduleRoomKey(room)] ?? const [];

  bool hasRoom(String room) => _byRoom.containsKey(scheduleRoomKey(room));

  static Future<ClassScheduleIndex> load(String file) async =>
      parse(await File(file).readAsString(), source: file);

  /// Reads the export. Online, TBA and unscheduled rows are dropped: they
  /// never occupy a room.
  static ClassScheduleIndex parse(String csv, {String source = ''}) {
    final rows = parseCsv(csv);
    if (rows.length <= 1) return ClassScheduleIndex._({}, source, const []);
    final header = [for (final h in rows.first) h.toLowerCase().trim()];
    int col(String name, [String? alt]) {
      final i = header.indexOf(name);
      return i != -1 || alt == null ? i : header.indexOf(alt);
    }

    final termI = col('term');
    final subjI = col('class_subject');
    final numI = col('class_number', 'catalog_number');
    final titleI = col('class_title');
    final startI = col('start_time1');
    final endI = col('end_time1');
    final daysI = col('days1');
    final bldgI = col('building');
    final roomI = col('room');
    final fromI = col('class_start_date');
    final toI = col('class_end_date');
    String at(List<String> r, int i) => i >= 0 && i < r.length ? r[i].trim() : '';

    final byRoom = <String, List<ScheduledClass>>{};
    final termCodes = <String>{};
    for (final r in rows.skip(1)) {
      final bldg = at(r, bldgI).toUpperCase();
      final room = at(r, roomI).toUpperCase();
      final days = at(r, daysI).toUpperCase();
      if (bldg.isEmpty || room.isEmpty || bldg == 'WWW' || room == 'ONLINE') {
        continue;
      }
      if (days.isEmpty || days == 'TBA') continue;
      final sm = parseScheduleMinutes(at(r, startI));
      final em = parseScheduleMinutes(at(r, endI));
      final from = parseScheduleDate(at(r, fromI));
      final to = parseScheduleDate(at(r, toI));
      if (sm == null || em == null || from == null || to == null) continue;
      if (em <= sm) continue;
      final code = at(r, termI);
      termCodes.add(code);
      final cls = ScheduledClass(
        term: formatCsuTerm(code),
        subject: at(r, subjI).replaceAll(' ', ''),
        number: at(r, numI).replaceAll(' ', ''),
        title: at(r, titleI),
        building: bldg,
        room: room,
        days: days,
        startMinutes: sm,
        endMinutes: em,
        startDate: from,
        endDate: to,
      );
      (byRoom[scheduleRoomKey('$bldg$room')] ??= []).add(cls);
    }
    final sortedCodes = termCodes.toList()..sort();
    return ClassScheduleIndex._(
      byRoom,
      source,
      [for (final c in sortedCodes) formatCsuTerm(c)],
    );
  }
}

/// One stretch of time a room is free.
class InstallGap {
  final DateTime day;
  final int startMinutes;
  final int endMinutes;

  /// True when nothing meets in the room all day.
  final bool wholeDay;

  const InstallGap({
    required this.day,
    required this.startMinutes,
    required this.endMinutes,
    this.wholeDay = false,
  });

  int get minutes => endMinutes - startMinutes;

  String get timeLabel => wholeDay
      ? 'All day'
      : '${formatScheduleMinutes(startMinutes)} - '
          '${formatScheduleMinutes(endMinutes)}';
}

/// The free stretches in a room between [from] and [to] (inclusive days),
/// inside the working day [dayStart]..[dayEnd] (minutes after midnight),
/// no shorter than [minMinutes].
///
/// A day with no classes at all is one whole-day window. [skipWeekends]
/// leaves Saturdays and Sundays out when they have no classes - most installs
/// are planned into weekdays, and a list with every weekend on it buries the
/// breaks between terms, which are the windows worth finding.
List<InstallGap> findInstallGaps(
  List<ScheduledClass> classes, {
  required DateTime from,
  required DateTime to,
  int dayStart = 7 * 60,
  int dayEnd = 22 * 60,
  int minMinutes = 120,
  bool skipWeekends = true,
}) {
  final gaps = <InstallGap>[];
  var day = DateTime(from.year, from.month, from.day);
  final last = DateTime(to.year, to.month, to.day);
  while (!day.isAfter(last)) {
    final busy = [
      for (final c in classes)
        if (c.meetsOn(day))
          (
            c.startMinutes.clamp(dayStart, dayEnd),
            c.endMinutes.clamp(dayStart, dayEnd),
          ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    final weekend = day.weekday >= DateTime.saturday;
    if (busy.isEmpty) {
      if (!(weekend && skipWeekends)) {
        gaps.add(InstallGap(
          day: day,
          startMinutes: dayStart,
          endMinutes: dayEnd,
          wholeDay: true,
        ));
      }
    } else {
      var cursor = dayStart;
      for (final (s, e) in busy) {
        if (s - cursor >= minMinutes) {
          gaps.add(InstallGap(day: day, startMinutes: cursor, endMinutes: s));
        }
        if (e > cursor) cursor = e;
      }
      if (dayEnd - cursor >= minMinutes) {
        gaps.add(InstallGap(day: day, startMinutes: cursor, endMinutes: dayEnd));
      }
    }
    day = DateTime(day.year, day.month, day.day + 1);
  }
  return gaps;
}
