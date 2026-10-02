import 'dart:io';

import 'package:extron_configurator/changelog.dart';
import 'package:extron_configurator/online_pull_history.dart';
import 'package:extron_configurator/online_roundtrip.dart';
import 'package:flutter_test/flutter_test.dart';

/// Edits pulled in from the online copy are listed in a file beside the
/// project - see online_pull_history.dart.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pull_history_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  const List<OnlineChange> changes = [
    (kind: 'delivery', id: 'd1', name: 'Projector', what: 'Qty 6 -> 8'),
    (kind: 'purchase order', id: '', name: 'PO-1182', what: 'added'),
  ];

  test('a pull is appended beside the project, change by change', () async {
    final project = '${dir.path}${Platform.pathSeparator}job_project.json';

    await recordOnlinePull(
      projectFile: project,
      project: 'Bessey Hall',
      source: 'Google Sheet https://docs.google.com/spreadsheets/d/abc',
      changes: changes,
      at: DateTime(2026, 10, 2, 14, 31, 7),
    );
    await recordOnlinePull(
      projectFile: project,
      project: 'Bessey Hall',
      source: r'C:\sync\Bessey Hall.xlsx',
      changes: [changes.first],
      at: DateTime(2026, 10, 3, 9),
    );

    final text = File(onlinePullHistoryPath(project)).readAsStringSync();
    expect(onlinePullHistoryPath(project), endsWith('.online_history.txt'));
    expect(text, contains('=== 2026-10-02 14:31:07 | Bessey Hall | '));
    expect(text, contains('| v$kAppVersionShort ==='));
    expect(
      text,
      contains('Source: Google Sheet https://docs.google.com/spreadsheets/d/abc'),
    );
    expect(text, contains('2 changes brought in'));
    expect(text, contains('  delivery "Projector": Qty 6 -> 8'));
    expect(text, contains('  purchase order "PO-1182": added'));
    // The second pull is added to the first, not written over it.
    expect(text, contains('=== 2026-10-03 09:00:00 | Bessey Hall | '));
    expect(text, contains('1 change brought in'));
    expect(text, contains(r'Source: C:\sync\Bessey Hall.xlsx'));
  });

  test('nothing is written for an empty pull or an unsaved project', () async {
    final project = '${dir.path}${Platform.pathSeparator}job_project.json';
    await recordOnlinePull(
      projectFile: project,
      project: 'Job',
      source: 's',
      changes: const [],
    );
    await recordOnlinePull(
      projectFile: '',
      project: 'Job',
      source: 's',
      changes: changes,
    );
    expect(File(onlinePullHistoryPath(project)).existsSync(), isFalse);
    expect(dir.listSync(), isEmpty);
  });
}
