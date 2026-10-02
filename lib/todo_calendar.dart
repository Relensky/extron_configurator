import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'building_project.dart';

/// ============================================================================
///  A JOB NOTE AS A CALENDAR REMINDER
/// ============================================================================
///  A standard .ics event: all day on the note's date, with a reminder at
///  9:00 that morning. Opened, it goes into Outlook (or whatever opens
///  calendar files); attached to an email, it goes to anybody.
/// ============================================================================

/// The note as an .ics calendar file.
String todoCalendarFile({
  required ProjectTodo todo,
  required DateTime date,
  required String projectName,
  String scope = '',
  DateTime? now,
}) {
  String day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
  final stamp = (now ?? DateTime.now()).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final dtStamp =
      '${day(stamp)}T${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}Z';
  final start = DateTime(date.year, date.month, date.day);
  final end = start.add(const Duration(days: 1));
  final job = projectName.trim();
  final summary = job.isEmpty ? todo.text.trim() : '$job: ${todo.text.trim()}';
  final description = [
    todo.text.trim(),
    if (scope.trim().isNotEmpty) 'About: ${scope.trim()}',
    if (job.isNotEmpty) 'Project: $job',
  ].join('\n');

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Room Config Builder//Job list//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    // Stable per note and date, so opening it again updates the same event.
    'UID:todo-${todo.id}-${day(start)}@room-config-builder',
    'DTSTAMP:$dtStamp',
    'DTSTART;VALUE=DATE:${day(start)}',
    'DTEND;VALUE=DATE:${day(end)}',
    _fold('SUMMARY:${_escape(summary)}'),
    _fold('DESCRIPTION:${_escape(description)}'),
    'TRANSP:TRANSPARENT',
    'BEGIN:VALARM',
    'ACTION:DISPLAY',
    _fold('DESCRIPTION:${_escape(summary)}'),
    'TRIGGER;RELATED=START:PT9H',
    'END:VALARM',
    'END:VEVENT',
    'END:VCALENDAR',
    '',
  ].join('\r\n');
}

/// Text as an .ics value: backslash, semicolon, comma and line breaks escaped.
String _escape(String text) => text
    .replaceAll(r'\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll('\r\n', r'\n')
    .replaceAll('\n', r'\n');

/// Long lines folded at 73 characters, as the format asks.
String _fold(String line) {
  if (line.length <= 73) return line;
  final out = StringBuffer(line.substring(0, 73));
  for (var i = 73; i < line.length; i += 72) {
    final endAt = i + 72 < line.length ? i + 72 : line.length;
    out.write('\r\n ${line.substring(i, endAt)}');
  }
  return out.toString();
}

/// Writes the reminder to a temporary .ics file and returns its path.
Future<String> writeTodoCalendarFile(String ics, ProjectTodo todo) async {
  final folder = await Directory.systemTemp.createTemp('job_reminder_');
  final words = todo.text
      .trim()
      .replaceAll(RegExp(r'[^\w\- ]+'), '')
      .split(RegExp(r'\s+'))
      .take(6)
      .join('_');
  final file = File(
    path.join(folder.path, '${words.isEmpty ? 'reminder' : words}.ics'),
  );
  await file.writeAsString(ics);
  return file.path;
}

/// Opens a new Outlook message with [icsPath] attached. Returns null when
/// Outlook took it, else a message to show.
Future<String?> emailCalendarFile(String icsPath) async {
  if (!Platform.isWindows) return 'Email invites need Outlook on Windows.';
  try {
    // `start` finds Outlook through the App Paths registry, wherever it is
    // installed; /a opens a new message with the file attached.
    final result = await Process.run(
      'cmd',
      ['/c', 'start', '', 'outlook.exe', '/a', icsPath],
    );
    if (result.exitCode != 0) {
      return 'Outlook could not be started (${result.stderr}).';
    }
    AppLogger.logInfo('Opened an email with the reminder $icsPath attached.');
    return null;
  } catch (e) {
    AppLogger.logError('Could not start Outlook for a reminder', e);
    return 'Outlook could not be started.';
  }
}
