import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/chat/chat_search.dart';
import 'package:extron_configurator/chat/project_chat.dart';
import 'package:extron_configurator/collab/presence.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('rcb_search_'));
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProjectChat person(String user) => ProjectChat(
      identity: CollabIdentity(user: user, machine: 'PC'))
    ..myName = (() => '$user name');

  test('every project on the share is found by name, and every chat by what '
      'was said', () async {
    final bss = path.join(root.path, 'Projects', 'Bessey', 'BSS_project.json');
    final hum = path.join(root.path, 'Projects', 'Holt', 'Holt_Hall_project.json');
    for (final f in [bss, hum]) {
      File(f)
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
    }
    // Not a project: skipped folders and other files.
    File(path.join(root.path, 'assets', 'x_project.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');

    final a = person('alice');
    await a.attachEveryone(root.path);
    await a.attach(bss);
    await a.post('Projector lamp is out in 103', to: kChatGeneral);
    await a.post('Who has the ladder?', to: kChatEveryone);
    a.dispose();

    ChatSearch.refresh();
    final all = await ChatSearch.search(root.path, '');
    expect(all.projects.map((p) => p.name), ['BSS', 'Holt Hall']);
    expect(all.messages, isEmpty);

    final holt = await ChatSearch.search(root.path, 'holthall');
    expect(holt.projects.single.path, hum);

    final lamp = await ChatSearch.search(root.path, 'LAMP');
    expect(lamp.messages.single.projectPath, bss);
    expect(lamp.messages.single.message.channel, kChatGeneral);

    final ladder = await ChatSearch.search(root.path, 'ladder');
    expect(ladder.messages.single.projectPath, '');
    expect(ladder.messages.single.message.channel, kChatEveryone);

    // By who wrote it, too.
    final byAlice = await ChatSearch.search(root.path, 'alice');
    expect(byAlice.messages, hasLength(2));
  });
}
