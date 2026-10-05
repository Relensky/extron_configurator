import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:extron_configurator/chat/project_chat.dart';
import 'package:extron_configurator/collab/presence.dart';

void main() {
  late Directory dir;
  late String project;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rcb_chat_');
    project = path.join(dir.path, 'BSS_project.json');
    await File(project).writeAsString('{}');
  });

  tearDown(() async {
    // Read marks are written without waiting; let the last one land.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await dir.delete(recursive: true);
  });

  ProjectChat person(String user, String machine) =>
      ProjectChat(identity: CollabIdentity(user: user, machine: machine))
        ..myName = (() => '$user name');

  test('the chat folder sits beside the project, named for it', () {
    expect(chatFolderFor(project), path.join(dir.path, 'BSS_chat'));
  });

  test('two people see each other\'s messages and mentions', () async {
    final a = person('alice', 'PC1');
    final b = person('bob', 'PC2');
    await a.attach(project);
    await b.attach(project);
    // Each has announced, so each can name the other.
    await a.poll(initial: true);
    expect(a.people.map((p) => p.login), containsAll(['alice', 'bob']));

    final incoming = <ChatMessage>[];
    b.onIncoming = incoming.add;
    expect(await a.post('Is the projector right, @bob?'), '');
    await b.poll();

    expect(b.messages.single.text, 'Is the projector right, @bob?');
    expect(b.messages.single.mentions, ['bob']);
    expect(incoming, hasLength(1));
    expect(b.unreadCount, 1);
    expect(b.mentionCount, 1);

    b.setOpen(true);
    expect(b.unreadCount, 0);
    expect(b.mentionCount, 0);
    // Your own messages are never unread.
    expect(a.unreadCount, 0);

    a.dispose();
    b.dispose();
  });

  test('read marks carry to the next session', () async {
    final a = person('alice', 'PC1');
    final b = person('bob', 'PC2');
    await a.attach(project);
    await b.attach(project);
    await a.post('hello');
    await b.poll();
    b.setOpen(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    b.dispose();

    final again = person('bob', 'PC2');
    await again.attach(project);
    expect(again.messages, hasLength(1));
    expect(again.unreadCount, 0);
    a.dispose();
    again.dispose();
  });

  test('a channel per room, plus General', () async {
    final a = person('alice', 'PC1')
      ..rooms = (() => {'r1': 'BSS 103', 'r2': 'BSS 101'});
    await a.attach(project);
    expect(a.channels.map((c) => c.label), ['General', 'BSS 101', 'BSS 103']);
    await a.post('cable run?', to: 'room:r1');
    expect(a.messages.single.channel, 'room:r1');
    a.dispose();
  });

  test('Everyone is shared through the root folder, project or not', () async {
    final root = path.join(dir.path, 'share');
    final a = person('alice', 'PC1');
    final b = person('bob', 'PC2');
    await a.attachEveryone(root);
    await b.attachEveryone(root);
    expect(a.channels.map((c) => c.id), [kChatEveryone]);
    expect(a.shownChannel, kChatEveryone);

    expect(await a.post('Anyone have a spare HDMI plate, @bob?'), '');
    await b.poll();
    expect(b.messages.single.channel, kChatEveryone);
    expect(b.mentionCount, 1);
    expect(Directory(everyoneChatFolder(root)).existsSync(), isTrue);

    // A project alongside: its channels join, and its file never carries
    // the shared channel's messages.
    await b.attach(project);
    expect(b.channels.first.id, kChatEveryone);
    expect(b.channels.map((c) => c.id), contains(kChatGeneral));
    await b.post('project only', to: kChatGeneral);
    final projectFiles =
        Directory(path.join(chatFolderFor(project), 'messages')).listSync();
    final written = projectFiles
        .whereType<File>()
        .map((f) => f.readAsStringSync())
        .join();
    expect(written, contains('project only'));
    expect(written, isNot(contains('HDMI')));
    a.dispose();
    b.dispose();
  });

  test('a message deleted by its author goes from every copy, and nobody '
      'else can delete it', () async {
    final a = person('alice', 'PC1');
    final b = person('bob', 'PC2');
    await a.attach(project);
    await b.attach(project);
    await a.post('wrong room, ignore', to: kChatGeneral);
    await b.poll();
    final id = b.messages.single.id;

    expect(await b.deleteMessage(id), isNotEmpty);
    expect(b.messages, hasLength(1));

    expect(await a.deleteMessage(id), '');
    expect(a.messages, isEmpty);
    await b.poll();
    expect(b.messages, isEmpty);

    // A copy opened afterwards never shows it either.
    final c = person('carol', 'PC3');
    await c.attach(project);
    expect(c.messages, isEmpty);
    a.dispose();
    b.dispose();
    c.dispose();
  });

  test('a picture is copied into the chat folder and travels with the '
      'message', () async {
    final picture = File(path.join(dir.path, 'rack.png'))
      ..writeAsBytesSync([1, 2, 3]);
    final a = person('alice', 'PC1');
    final b = person('bob', 'PC2');
    await a.attach(project);
    await b.attach(project);
    expect(await a.post('', to: kChatGeneral, image: picture.path), '');
    await b.poll();
    final m = b.messages.single;
    expect(m.text, '');
    expect(m.image, startsWith('images/'));
    expect(File(path.join(chatFolderFor(project), m.image)).readAsBytesSync(),
        [1, 2, 3]);
    a.dispose();
    b.dispose();
  });

  test('a snapshot survives the trip to the chat window', () async {
    final a = person('alice', 'PC1');
    await a.attach(project);
    await a.post('hi @alice');
    final back = ChatSnapshot.fromJson(a.snapshot().toJson());
    expect(back.me, 'alice');
    expect(back.messages.single.text, 'hi @alice');
    expect(back.channels.first.id, kChatGeneral);
    a.dispose();
  });

  test('opening another job mid-read still loads it, quietly', () async {
    final other = path.join(dir.path, 'LIB_project.json');
    await File(other).writeAsString('{}');
    final a = person('alice', 'PC1');
    await a.attach(other);
    await a.post('old news', to: kChatGeneral);
    a.dispose();

    final b = person('bob', 'PC2');
    await b.attach(project);
    final incoming = <ChatMessage>[];
    b.onIncoming = incoming.add;
    // A timed read fires while the other job is still opening.
    final opening = b.attach(other);
    final timed = b.poll();
    await opening;
    await timed;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(b.messages.map((m) => m.text), ['old news']);
    expect(incoming, isEmpty, reason: 'history is not news');
    expect(b.people.map((p) => p.login), contains('alice'));
    b.dispose();
  });
}
