import 'dart:io';

import 'package:extron_configurator/team/chat_format.dart';
import 'package:extron_configurator/team/team_chat.dart';
import 'package:extron_configurator/team/team_claims.dart';
import 'package:extron_configurator/team/team_claims_widgets.dart';
import 'package:extron_configurator/team/team_host.dart';
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
    // Each change a row: who, what they did, and the item.
    final list = find.byKey(const ValueKey('working_on_history_list'));
    expect(find.descendant(of: list, matching: find.text('Alice put you on ')),
        findsOneWidget);
    expect(
        find.descendant(
            of: list, matching: find.text('You took yourself off ')),
        findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('ARTS 209')),
        findsNWidgets(2));

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

  testWidgets('the team chart is a compact table with the activity under the '
      'name; the list has every tag as a link; History folded by day',
      (tester) async {
    final a = TeamClaims(
        identity: const TeamIdentity(user: 'alice', machine: 'pc1'),
        myName: () => 'Alice',
        watch: false);
    await tester.runAsync(() async {
      await a.attach(dir.path);
      await a.set(
          kind: 'room', id: 'ARTS 209', label: 'ARTS 209', who: 'alice',
          whoName: 'Alice', on: true);
      await a.set(
          kind: 'ticket', id: '7', label: 'Ticket #7', who: 'carol',
          whoName: 'Carol', on: true);
      await a.refresh();
    });
    Team.claims = a;
    final opened = <String>[];
    TeamHost.openClaim = (kind, id, label) => opened.add('$kind|$id');
    TeamHost.canOpenClaim = (kind) => kind == 'room';
    addTearDown(() {
      Team.claims = null;
      TeamHost.openClaim = null;
      TeamHost.canOpenClaim = null;
    });

    final now = DateTime.now();
    final alice = TeamPresence(
        user: 'alice', machine: 'pc1', since: now, heartbeat: now,
        activity: 'Composing a notification email');
    final dan = TeamPresence(
        user: 'dan', machine: 'pc4', since: now, heartbeat: now,
        app: 'configurator');
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var closed = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: Column(children: [
      TeamPresenceChart(meUser: 'alice', people: [
        [alice],
        [dan],
      ]),
      TeamWorkingOnList(beforeOpen: () => closed++),
    ])))));
    expect(tester.takeException(), isNull);
    // A table, a column for each of the three apps.
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('CTS Dashboard'), findsOneWidget);
    expect(find.text('Room Config Builder'), findsOneWidget);
    expect(find.text('Instructor Contact'), findsOneWidget);
    // The activity is under Alice's name; her tags are not in the chart.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('team_person_alice')),
            matching:
                find.byKey(const ValueKey('team_person_activity_alice'))),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(Table), matching: find.text('ARTS 209')),
        findsNothing);
    // Everyone's tags are in the list, under 'Working on'.
    expect(find.text('Working on'), findsOneWidget);
    expect(find.text('ARTS 209'), findsOneWidget);
    expect(find.text('Ticket #7'), findsOneWidget);
    // A room is a link (this app opens rooms); a ticket is plain text here.
    final room = a.current.firstWhere((c) => c.kind == 'room');
    final ticket = a.current.firstWhere((c) => c.kind == 'ticket');
    expect(find.byKey(ValueKey('working_on_link_${ticket.key}')), findsNothing);
    await tester.tap(find.byKey(ValueKey('working_on_link_${room.key}')));
    await tester.pump();
    expect(opened, ['room|ARTS 209']);
    expect(closed, 1);
    // History is folded until clicked, then opens below, by day.
    expect(find.byKey(const ValueKey('working_on_history_list')), findsNothing);
    expect(find.text('Your tag history'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('working_on_history')));
    await tester.pump();
    expect(find.byKey(const ValueKey('working_on_history_list')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('working_on_history_list')),
            matching: find.text('Today')),
        findsOneWidget);
    expect(find.text('You put yourself on '), findsOneWidget);
    expect(find.text('ARTS 209'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    a.dispose();
  });

  testWidgets('on a phone the team is a list: each person, then their apps',
      (tester) async {
    final now = DateTime.now();
    final people = [
      [
        TeamPresence(user: 'alice', machine: 'pc1', since: now,
            heartbeat: now, app: 'dashboard', tab: 'Schedule', room: 'BSS 103'),
        TeamPresence(user: 'alice', machine: 'ipad', since: now,
            heartbeat: now, app: 'configurator', tab: 'Walls'),
      ],
      [
        TeamPresence(user: 'dan', machine: 'pc4', since: now,
            heartbeat: now, app: 'configurator', tab: 'Rooms'),
      ],
    ];
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: TeamPresenceChart(
                    meUser: 'alice', people: people, onMessage: (_) {})))));
    await tester.pump();
    expect(find.byKey(const ValueKey('team_presence_list')), findsOneWidget);
    // The page names read in full, wider than a table column left them.
    expect(find.text('Schedule'), findsOneWidget);
    expect(tester.getSize(find.text('Schedule')).width, greaterThan(50));
    expect(tester.getSize(find.byKey(const ValueKey('team_person_dan'))).width,
        greaterThan(300));
    expect(tester.takeException(), isNull);
  });
}
