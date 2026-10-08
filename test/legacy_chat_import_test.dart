import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:extron_configurator/legacy_chat_import.dart';

// The old <project>_chat folder, read for copying into the project's thread
// in the team chat: deletes and edits applied, rooms and tabs named.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('legacy_chat'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the folder sits beside the project file', () {
    expect(legacyChatFolderFor(path.join('X', 'ARTS_Refresh_project.json')),
        path.join('X', 'ARTS_Refresh_chat'));
  });

  test('messages come back as they last stood, oldest first', () async {
    final messages = Directory(path.join(dir.path, 'messages'))
      ..createSync(recursive: true);
    String line(Map<String, Object> m) => jsonEncode(m);
    File(path.join(messages.path, 'ann@PC1.jsonl')).writeAsStringSync([
      line({'id': 'a1', 'channel': 'general', 'user': 'ann', 'name': 'Ann',
          'at': '2026-09-01T10:00:00Z', 'text': 'kickoff'}),
      line({'id': 'a2', 'channel': 'room:R1', 'user': 'ann', 'room': 'ARTS 111',
          'at': '2026-09-02T10:00:00Z', 'text': 'projector here'}),
      line({'id': 'a3', 'channel': 'general', 'user': 'ann',
          'at': '2026-09-03T10:00:00Z', 'text': 'oops'}),
      line({'id': 'a4', 'channel': 'general', 'user': 'ann',
          'at': '2026-09-03T10:01:00Z', 'text': '', 'deletes': 'a3'}),
      line({'id': 'a5', 'channel': 'general', 'user': 'ann',
          'at': '2026-09-04T10:00:00Z', 'text': 'kickoff Monday', 'edits': 'a1'}),
      'not json',
    ].join('\n'));
    File(path.join(messages.path, 'bob@PC2.jsonl')).writeAsStringSync(line({
      'id': 'b1', 'channel': 'general', 'user': 'bob',
      'at': '2026-09-01T12:00:00Z', 'text': 'ok'}));

    final got = await readLegacyChat(dir.path);
    expect(got.map((m) => (m.id, m.user, m.text)), [
      ('a1', 'ann', 'kickoff Monday'),
      ('b1', 'bob', 'ok'),
      ('a2', 'ann', '[ARTS 111] projector here'),
    ]);
    expect(got.first.name, 'Ann');
  });

  test('no folder, nothing', () async {
    expect(await readLegacyChat(path.join(dir.path, 'missing')), isEmpty);
  });
}
