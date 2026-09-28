import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/recent_files.dart';

/// Forgetting the recent files that have gone, and keeping the rest.
void main() {
  test('only the moved or deleted files are forgotten', () {
    final dir = Directory.systemTemp.createTempSync('recent_missing_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final kept = File(path.join(dir.path, 'ARTS_111_config.json'))
      ..writeAsStringSync('{}');
    final gone = path.join(dir.path, 'ARTS_112_config.json');
    final job = File(path.join(dir.path, 'Refresh_project.json'))
      ..writeAsStringSync('{}');

    final recents = RecentFiles()
      ..remember(RecentKind.room, kept.path)
      ..remember(RecentKind.room, gone)
      ..remember(RecentKind.project, job.path);
    expect(recents.missingCount, 1);

    expect(recents.forgetMissing(), 1);
    expect(recents.missingCount, 0);
    expect(recents[RecentKind.room].map((e) => e.file), [kept.path]);
    expect(recents[RecentKind.project].map((e) => e.file), [job.path]);
    // Nothing more to forget.
    expect(recents.forgetMissing(), 0);
  });
}
