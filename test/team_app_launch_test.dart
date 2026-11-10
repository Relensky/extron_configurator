import 'dart:io';

import 'package:extron_configurator/team/team_app_launch.dart';
import 'package:extron_configurator/team/team_claims.dart';
import 'package:extron_configurator/team/team_claims_widgets.dart';
import 'package:extron_configurator/team/team_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// [TEAM KIT - APPS / APP REQUESTS / PROJECTS]: the other CTS apps from the
// team page, requests handed between them, and project tags as links.
void main() {
  late Directory dir;
  late String appWas;
  final opened = <String>[];
  setUp(() {
    dir = Directory.systemTemp.createTempSync('app_requests_');
    TeamAppLaunch.folderOverride = dir.path;
    appWas = TeamHost.appId;
    opened.clear();
    TeamAppLaunch.debugOpen = (app, r) async {
      opened.add(r == null ? app : '$app ${r.action} ${r.args}');
      return true;
    };
  });
  tearDown(() {
    TeamAppLaunch.folderOverride = null;
    TeamAppLaunch.debugOpen = null;
    TeamHost.onAppRequest = null;
    TeamHost.openClaim = null;
    TeamHost.canOpenClaim = null;
    TeamHost.appId = appWas;
    dir.deleteSync(recursive: true);
  });

  test('a request survives the command line and the JSON', () {
    final r = TeamAppRequest.create(
        'openProject', {'file': r'\\server\share\Job "A".json', 'room': 'BSS 110'});
    final args = ['--from-dashboard', 'xyz', ...r.commandLine];
    final back = TeamAppRequest.fromArgs(args)!;
    expect(back.action, 'openProject');
    expect(back.args, {'file': r'\\server\share\Job "A".json', 'room': 'BSS 110'});
    expect(back.id, r.id);
    expect(back.from, TeamHost.appId);
    expect(back.stale, isFalse);
    expect(TeamAppRequest.fromArgs(const ['--request']), isNull);
    expect(TeamAppRequest.decode('not base64!'), isNull);
    final old = TeamAppRequest(
        action: 'openRoom',
        id: 'x',
        at: DateTime.now().subtract(const Duration(minutes: 5)));
    expect(old.stale, isTrue);
  });

  test('a running copy takes the request handed to it, once', () async {
    final r = TeamAppRequest.create('openRoom', {'room': 'PAC 144'});
    expect(await TeamAppLaunch.deliver('dashboard', r), isTrue);
    expect(TeamAppLaunch.requestFile('dashboard').existsSync(), isTrue);
    final taken = TeamAppLaunch.take('dashboard')!;
    expect(taken.id, r.id);
    expect(taken.args['room'], 'PAC 144');
    expect(TeamAppLaunch.take('dashboard'), isNull);
    expect(await TeamAppLaunch.delivered('dashboard', r.id), isTrue);

    // Nobody takes it: given back, and the file is gone.
    final r2 = TeamAppRequest.create('openRoom', {'room': 'X 1'});
    await TeamAppLaunch.deliver('dashboard', r2);
    expect(
        await TeamAppLaunch.delivered('dashboard', r2.id,
            wait: const Duration(milliseconds: 300)),
        isFalse);
    expect(TeamAppLaunch.requestFile('dashboard').existsSync(), isFalse);
  });

  test('the request an app starts with, and one for itself, run here', () async {
    final got = <String>[];
    TeamHost.onAppRequest = (action, args) => got.add('$action ${args['room']}');
    TeamAppLaunch.listen(
        startupArgs: TeamAppRequest.create('openRoom', {'room': 'BSS 110'})
            .commandLine);
    TeamHost.appId = 'dashboard';
    await teamOpenInApp(null, 'dashboard',
        action: 'openRoom', args: {'room': 'ARTS 209'});
    expect(got, ['openRoom BSS 110', 'openRoom ARTS 209']);
    expect(opened, isEmpty);
    // Another app goes through TeamAppLaunch.open.
    await teamOpenInApp(null, 'instructor',
        action: 'notifyRoom', args: {'room': 'BSS 110'});
    expect(opened, ['instructor notifyRoom {room: BSS 110}']);
  });

  testWidgets('the team page links each other app, not this one',
      (tester) async {
    TeamHost.appId = 'configurator';
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TeamAppLinks())));
    expect(find.byKey(const ValueKey('team_app_link_configurator')),
        findsNothing);
    expect(find.byKey(const ValueKey('team_app_link_dashboard')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('team_app_link_instructor')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('team_app_link_instructor')));
    await tester.pump();
    expect(opened, ['instructor']);
  });

  testWidgets('a room tag made on a project links to the project file',
      (tester) async {
    TeamHost.appId = 'dashboard';
    final claimsOpened = <String>[];
    TeamHost.openClaim = (kind, id, label) => claimsOpened.add('$kind|$id');
    TeamHost.canOpenClaim = (kind) => kind == 'room';
    final room = TeamClaim(
      kind: 'room',
      id: 'BSS 110',
      label: 'BSS 110 (room configuration)',
      who: 'alice',
      whoName: 'Alice',
      by: 'alice',
      byName: 'Alice',
      at: DateTime.now(),
      on: true,
      app: 'configurator',
      file: r'\\server\Projects\BSS Refresh.json',
      project: 'BSS Refresh',
    );
    // Kept through the team folder's file.
    final back = TeamClaim.fromJson(room.toJson())!;
    expect(back.file, room.file);
    expect(back.project, 'BSS Refresh');
    expect(TeamClaim.fromJson({...room.toJson()}..remove('file'))!.file, '');

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: TeamClaimLink(room)))));
    expect(find.text('BSS Refresh'), findsOneWidget);
    // A Builder tag's room opens in the Builder, on the file it was made on...
    await tester.tap(find.byKey(ValueKey('working_on_link_${room.key}')));
    await tester.pump();
    expect(opened, [
      'configurator openRoom {room: BSS 110, '
          'file: \\\\server\\Projects\\BSS Refresh.json}'
    ]);
    // ...the button beside it opens the Room Hub here...
    await tester
        .tap(find.byKey(ValueKey('working_on_room_hub_link_${room.key}')));
    await tester.pump();
    expect(claimsOpened, ['room|BSS 110']);
    // ...and the project opens its file in the Room Config Builder.
    opened.clear();
    await tester
        .tap(find.byKey(ValueKey('working_on_project_link_${room.key}')));
    await tester.pump();
    expect(opened, [
      'configurator openProject {file: \\\\server\\Projects\\BSS Refresh.json}'
    ]);

    // In the Builder the room tag is a request to itself (which opens the
    // project and the room in it - openTeamRoomRequest).
    TeamHost.appId = 'configurator';
    final got = <String>[];
    TeamHost.onAppRequest = (action, args) => got.add('$action $args');
    teamOpenClaim(room);
    expect(got, [
      'openRoom {room: BSS 110, file: \\\\server\\Projects\\BSS Refresh.json}'
    ]);
  });

  testWidgets('older Builder room tags, with no file, open by room name',
      (tester) async {
    TeamHost.appId = 'dashboard';
    final claimsOpened = <String>[];
    TeamHost.openClaim = (kind, id, label) => claimsOpened.add('$kind|$id');
    TeamHost.canOpenClaim = (kind) => kind == 'room';
    TeamClaim tag(String app) => TeamClaim(
          kind: 'room',
          id: 'HOLT 175',
          label: 'HOLT 175 (room configuration)',
          who: 'alice',
          whoName: 'Alice',
          by: 'alice',
          byName: 'Alice',
          at: DateTime.now(),
          on: true,
          app: app,
        );
    final builder = tag('configurator');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: TeamClaimLink(builder)))));
    expect(find.byKey(ValueKey('working_on_project_link_${builder.key}')),
        findsNothing);
    await tester.tap(find.byKey(ValueKey('working_on_link_${builder.key}')));
    await tester.pump();
    expect(opened, ['configurator openRoom {room: HOLT 175}']);

    // A dashboard tag still opens the Room Hub, with no extra button.
    final dash = tag('dashboard');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: TeamClaimLink(dash)))));
    expect(find.byKey(ValueKey('working_on_room_hub_link_${dash.key}')),
        findsNothing);
    await tester.tap(find.byKey(ValueKey('working_on_link_${dash.key}')));
    await tester.pump();
    expect(claimsOpened, ['room|HOLT 175']);

    // In the Builder every room tag also has the Room Hub button.
    TeamHost.appId = 'configurator';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: TeamClaimLink(dash)))));
    opened.clear();
    await tester
        .tap(find.byKey(ValueKey('working_on_room_hub_link_${dash.key}')));
    await tester.pump();
    expect(opened, ['dashboard openRoom {room: HOLT 175}']);
  });
}
