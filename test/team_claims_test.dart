import 'dart:io';

import 'package:extron_configurator/team/chat_format.dart';
import 'package:extron_configurator/team/team_chat.dart';
import 'package:extron_configurator/team/team_claims.dart';
import 'package:extron_configurator/team/team_claims_widgets.dart';
import 'package:extron_configurator/team/team_presence.dart';
import 'package:extron_configurator/team/team_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// [TEAM KIT - WORKING ON]: tags shared through the team folder, two people.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('claims_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a tag by one person is seen by another, and the newest wins',
      () async {
    final a = TeamClaims(
        identity: const TeamIdentity(user: 'alice', machine: 'pc1'),
        myName: () => 'Alice',
        watch: false);
    final b = TeamClaims(
        identity: const TeamIdentity(user: 'bob', machine: 'pc2'),
        myName: () => 'Bob',
        watch: false);
    await a.attach(dir.path);
    await b.attach(dir.path);

    final tagged = <TeamClaim>[];
    b.onTaggedByOthers = tagged.add;

    // Alice takes the ticket and tags Bob on it too.
    expect(await a.set(
        kind: 'ticket', id: '123', label: 'Ticket #123', who: 'alice', on: true), '');
    expect(await a.set(
        kind: 'ticket', id: '123', label: 'Ticket #123', who: 'bob',
        whoName: 'Bob', on: true), '');
    await b.refresh();
    expect(b.on('ticket', '123').map((c) => c.who), ['alice', 'bob']);
    expect(tagged.map((c) => c.by), ['alice']);

    // Bob takes himself off: his later line beats Alice's.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.set(kind: 'ticket', id: '123', label: 'Ticket #123', who: 'bob', on: false);
    await a.refresh();
    expect(a.on('ticket', '123').map((c) => c.who), ['alice']);
    expect(a.forPerson('alice').single.id, '123');
    a.dispose();
    b.dispose();
  });

  testWidgets('the team page lists everyone\'s tags and clears mine',
      (tester) async {
    final a = TeamClaims(
        identity: const TeamIdentity(user: 'alice', machine: 'pc1'),
        myName: () => 'Alice',
        watch: false);
    final b = TeamClaims(
        identity: const TeamIdentity(user: 'bob', machine: 'pc2'),
        myName: () => 'Bob',
        watch: false);
    await tester.runAsync(() async {
      await a.attach(dir.path);
      await b.attach(dir.path);
      await a.set(
          kind: 'room', id: 'ARTS 209', label: 'ARTS 209', who: 'alice',
          whoName: 'Alice', on: true);
      await a.set(
          kind: 'ticket', id: '123', label: 'Ticket #123', who: 'bob',
          whoName: 'Bob', on: true);
      await b.set(
          kind: 'room', id: 'OCNL 101', label: 'OCNL 101', who: 'bob',
          whoName: 'Bob', on: true);
      await a.refresh();
    });
    Team.claims = a;
    addTearDown(() => Team.claims = null);

    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: TeamWorkingOnList()))));
    expect(find.text('Alice (you)'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Ticket #123'), findsOneWidget);
    expect(find.text('OCNL 101'), findsOneWidget);
    expect(find.byType(TeamAppTag), findsNWidgets(3));
    // An x on every tag - Bob's own asks first.
    expect(find.byIcon(Icons.close), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('working_on_clear_mine')));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('working_on_clear_mine_yes')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(a.current.map((c) => c.id), ['OCNL 101']);
    expect(find.text('ARTS 209'), findsNothing);
    expect(find.byKey(const ValueKey('working_on_clear_mine')), findsNothing);
    a.dispose();
    b.dispose();
  });

  testWidgets('a tag someone else put on me I can clear; anyone else\'s asks '
      'first, messages them, and is in their history', (tester) async {
    final chatDir = Directory.systemTemp.createTempSync('claims_chat_');
    addTearDown(() => chatDir.deleteSync(recursive: true));
    const aliceId = TeamIdentity(user: 'alice', machine: 'pc1');
    const bobId = TeamIdentity(user: 'bob', machine: 'pc2');
    final a = TeamClaims(identity: aliceId, myName: () => 'Alice', watch: false);
    final b = TeamClaims(identity: bobId, myName: () => 'Bob', watch: false);
    late TeamChat bobChat;
    await tester.runAsync(() async {
      await a.attach(dir.path);
      await b.attach(dir.path);
      // Alice tags Bob on a room, and herself on a ticket.
      await a.set(
          kind: 'room', id: 'ARTS 209', label: 'ARTS 209', who: 'bob',
          whoName: 'Bob', on: true);
      await a.set(
          kind: 'ticket', id: '9', label: 'Ticket #9', who: 'alice',
          whoName: 'Alice', on: true);
      await b.refresh();
      bobChat = TeamChat(identity: bobId);
      await bobChat.attach(chatDir.path);
    });
    Team.claims = b;
    Team.chat = bobChat;
    addTearDown(() {
      Team.claims = null;
      Team.chat = null;
    });

    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: TeamWorkingOnList()))));
    final roomKey = b.on('room', 'ARTS 209').single.key;
    final ticketKey = b.on('ticket', '9').single.key;

    // Bob's own tag, though Alice placed it: off straight away.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey('working_on_clear_$roomKey')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(b.on('room', 'ARTS 209'), isEmpty);

    // Alice's: a warning first.
    await tester.tap(find.byKey(ValueKey('working_on_clear_$ticketKey')));
    await tester.pump();
    expect(find.byKey(ValueKey('working_on_confirm_$ticketKey')), findsOneWidget);
    expect(b.on('ticket', '9'), hasLength(1));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey('working_on_confirm_yes_$ticketKey')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(b.on('ticket', '9'), isEmpty);
    // Alice was told, in a direct message from Bob.
    expect(
        bobChat.messages.where((m) =>
            m.channel == dmChannel('bob', 'alice') &&
            m.text.contains('took you off **Ticket #9**')),
        hasLength(1));

    // And it is in Alice's history: who took her off what.
    await tester.runAsync(() => a.refresh());
    final hers = a.historyFor();
    expect(hers.first.on, isFalse);
    expect(hers.first.by, 'bob');
    expect(hers.first.id, '9');
    // Bob's history shows Alice putting him on the room, and him leaving it.
    expect(b.historyFor().map((c) => (c.by, c.on)),
        [('bob', false), ('alice', true)]);
    await tester.tap(find.byKey(const ValueKey('working_on_history')));
    await tester.pump();
    expect(find.text('Alice tagged you on ARTS 209'), findsOneWidget);
    expect(find.text('You took yourself off ARTS 209'), findsOneWidget);

    await tester.runAsync(() async => bobChat.dispose());
    a.dispose();
    b.dispose();
  });

  testWidgets('hidden style codes stay hidden before they are closed',
      (tester) async {
    final spans = ChatFormat.spans('**',
        base: const TextStyle(fontSize: 14),
        scheme: const ColorScheme.light(),
        showMarkers: true,
        hideMarkers: true);
    final styles = [
      for (final s in spans)
        if (s is TextSpan && (s.text ?? '').isNotEmpty) s.style,
    ];
    expect(styles, isNotEmpty);
    expect(styles.every((s) => s?.color == Colors.transparent), isTrue);

    final shown = ChatFormat.spans('[color=re',
        base: const TextStyle(fontSize: 14),
        scheme: const ColorScheme.light(),
        showMarkers: true,
        hideMarkers: true);
    expect(
        shown.whereType<TextSpan>().every((s) =>
            (s.text ?? '').isEmpty || s.style?.color == Colors.transparent),
        isTrue);
  });
}
