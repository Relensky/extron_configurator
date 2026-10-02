import 'dart:io';

import 'app_logger.dart';
import 'changelog.dart';
import 'online_roundtrip.dart';
import 'online_sheet_merge.dart';

/// ============================================================================
///  WHAT CAME BACK FROM THE ONLINE COPY, KEPT IN A FILE
/// ============================================================================
///  Edits pulled in from the published workbook or the live Google Sheet are
///  shown before they are applied, and each one lands in the job's own history
///  - but that history lives inside the project file, among every other edit,
///  and the list that was on screen is gone the moment the box closes.
///
///  So each pull that is applied is also appended, as plain text, to a file
///  beside the project (`<project file>.online_history.txt`): when, who, where
///  it came from, and every change exactly as the review listed it.
///
///    === 2026-10-02 14:31:07 | Bessey Hall | jsmith on PC-9 | v0.5.50 ===
///    Source: Google Sheet https://docs.google.com/spreadsheets/d/...
///    2 changes brought in
///      delivery "Projector": Qty 6 -> 8
///      purchase order "PO-1182": added
/// ============================================================================

/// The history file kept beside [projectFile].
String onlinePullHistoryPath(String projectFile) =>
    '$projectFile.online_history.txt';

/// One pull, as it is written to the file.
String formatOnlinePull({
  required DateTime at,
  required String project,
  required String who,
  required String source,
  required List<OnlineChange> changes,
}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final when = '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  final applied = appliedChanges(changes);
  final listed = listedOnlyChanges(changes);
  final buffer = StringBuffer()
    ..writeln('=== $when | $project | $who | v$kAppVersionShort ===')
    ..writeln('Source: $source')
    ..writeln([
      if (applied.isNotEmpty || listed.isEmpty)
        '${applied.length} change${applied.length == 1 ? '' : 's'} brought in',
      if (listed.isNotEmpty)
        '${listed.length} edit${listed.length == 1 ? '' : 's'} in other tabs '
            'listed only - NOT brought in, make '
            '${listed.length == 1 ? 'it' : 'them'} in the app',
    ].join('; '));
  for (final c in [...applied, ...listed]) {
    final name = c.name.trim().isEmpty ? '' : ' "${c.name.trim()}"';
    buffer.writeln('  ${c.kind}$name: ${c.what}');
  }
  buffer.writeln();
  return buffer.toString().replaceAll('\n', '\r\n');
}

/// Appends a pull to the history beside [projectFile]. Never throws: a
/// history that cannot be written must not undo an import that worked.
Future<void> recordOnlinePull({
  required String projectFile,
  required String project,
  required String source,
  required List<OnlineChange> changes,
  DateTime? at,
}) async {
  if (changes.isEmpty) return;
  if (projectFile.trim().isEmpty) {
    // A job that has never been saved has nowhere to keep a file beside.
    AppLogger.logInfo(
      'Online copy: ${changes.length} change(s) brought in from $source; no '
      'history file, because the project has not been saved yet.',
    );
    return;
  }
  final env = Platform.environment;
  final user = env['USERNAME'] ?? env['USER'] ?? 'unknown';
  final machine = env['COMPUTERNAME'] ?? env['HOSTNAME'] ?? '';
  final file = onlinePullHistoryPath(projectFile);
  try {
    await File(file).writeAsString(
      formatOnlinePull(
        at: at ?? DateTime.now(),
        project: project,
        who: machine.isEmpty ? user : '$user on $machine',
        source: source,
        changes: changes,
      ),
      mode: FileMode.append,
      flush: true,
    );
    AppLogger.logInfo(
      'Online copy: ${changes.length} change(s) brought in from $source, '
      'listed in $file.',
    );
  } catch (e) {
    AppLogger.logError('The online copy history $file could not be written', e);
  }
}
