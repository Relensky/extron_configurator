import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/project_setup_dialog.dart';

/// ============================================================================
///  SETTING A JOB UP ON THE DAY IT STARTS
/// ============================================================================
///  A new project used to arrive empty: no name, no rooms, no deadline and no
///  list. Every one of those gets filled in eventually, and "eventually" is the
///  failure — the schedule, the spares check and the reminders all read facts
///  nobody was ever asked for.
///
///  Two halves are worth guarding. The FOLDER SCAN, because a room added twice
///  doubles its cost on the quote and a room missed is money nobody counted;
///  and the fact that EVERY route to a new project goes through the same setup,
///  because a screen that only appears when you start the job from one of three
///  buttons is a screen nobody relies on.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_setup'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(String relative) {
    final file = File(path.join(dir.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '101'},
    }));
    return file.path;
  }

  group('finding the rooms in a folder', () {
    test('both spellings of a room config are found', () {
      // Loose in one folder, and a folder per room. The two ways a share is
      // laid out, and a scan that only understood one of them would silently
      // find nothing on half the jobs in the shop.
      final loose = writeRoom('BSS_101_config.json');
      final nested = writeRoom(path.join('BSS_102', 'config.json'));

      final found = findRoomConfigs(dir.path);
      expect(found, containsAll([loose, nested]));
      expect(found, hasLength(2));
    });

    test('the files that live beside a room are not rooms', () {
      writeRoom('BSS_101_config.json');
      for (final beside in [
        'BSS_101_config_av_flow.json',
        'BSS_101_config_cost.json',
        'bessey_project.json',
        'app_config.json',
      ]) {
        File(path.join(dir.path, beside)).writeAsStringSync('{}');
      }

      final found = findRoomConfigs(dir.path);
      expect(found, hasLength(1));
      expect(path.basename(found.single), 'BSS_101_config.json');
    });

    test('it stops before the backups', () {
      // Two folders down is the building/room layout. Three is where old
      // revisions and backup copies live, and a room added twice doubles its
      // cost on the quote.
      writeRoom(path.join('BSS_101', 'config.json'));
      writeRoom(path.join('BSS_101', 'old', 'config.json'));

      final found = findRoomConfigs(dir.path);
      expect(found, hasLength(1));
      expect(found.single, contains('BSS_101'));
      expect(found.single, isNot(contains('old')));
    });

    test('a folder that is not there is not an error', () {
      expect(findRoomConfigs(path.join(dir.path, 'nowhere')), isEmpty);
    });
  });

  group('what the setup puts on the job', () {
    test('every answer lands, and the message says what happened', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject();
      final room = writeRoom('BSS_101_config.json');

      final message = applyProjectSetup(p, (
        name: 'Bessey refresh',
        building: 'BSS',
        jobNumber: 'J-4412',
        stakeholder: 'Facilities',
        roomPaths: [room],
        deadline: DateTime(2026, 9, 14),
        spareTargetPercent: 10,
        todos: const ['Ring the vendors'],
      ));

      expect(p.project.name, 'Bessey refresh');
      expect(p.project.building, 'BSS');
      expect(p.project.jobNumber, 'J-4412');
      expect(p.project.stakeholder, 'Facilities');
      expect(p.project.rooms, hasLength(1));
      expect(p.project.deliveryDeadline, DateTime(2026, 9, 14));
      expect(p.project.spareTargetPercent, 10);
      expect(p.project.todos.single.text, 'Ring the vendors');
      expect(message, contains('1 room added'));
    });

    test('an empty answer changes nothing it was not given', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Already named');

      applyProjectSetup(p, (
        name: 'Already named',
        building: '',
        jobNumber: '',
        stakeholder: '',
        roomPaths: const [],
        deadline: null,
        spareTargetPercent: 0,
        todos: const [],
      ));

      expect(p.project.deliveryDeadline, isNull);
      expect(p.project.spareTargetPercent, 0);
      expect(p.project.todos, isEmpty);
      expect(p.project.rooms, isEmpty);
    });

    test('the same room twice is refused, and said so', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject();
      final room = writeRoom('BSS_101_config.json');

      // A room listed twice doubles its cost in the building total and doubles
      // every one of its parts on the master list — a wrong number that looks
      // entirely plausible.
      final message = applyProjectSetup(p, (
        name: '',
        building: '',
        jobNumber: '',
        stakeholder: '',
        roomPaths: [room, room],
        deadline: null,
        spareTargetPercent: 0,
        todos: const [],
      ));

      expect(p.project.rooms, hasLength(1));
      expect(message, contains('1 room added'));
      expect(message.toLowerCase(), contains('already'));
    });
  });

  group('the setup screen', () {
    Future<NewProjectSetup?> run(
      WidgetTester tester,
      Future<void> Function(WidgetTester) act,
    ) async {
      NewProjectSetup? answer;
      var opened = false;
      // The form is a tall one — five sections and a room list — and the
      // default test window is 800x600, which puts its own buttons off the
      // bottom of the world.
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  opened = true;
                  answer = await showProjectSetupDialog(
                    context,
                    building: 'BSS',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      await act(tester);
      return answer;
    }

    testWidgets('it comes back with what was typed', (tester) async {
      final answer = await run(tester, (t) async {
        await t.enterText(
          find.byKey(const ValueKey('setup_name')),
          'Bessey refresh',
        );
        await t.enterText(
          find.byKey(const ValueKey('setup_spare_target')),
          '10',
        );
        await t.enterText(
          find.byKey(const ValueKey('setup_todo_text')),
          'Ring the dean',
        );
        await t.tap(find.byKey(const ValueKey('setup_todo_add')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('setup_confirm')));
        await t.pumpAndSettle();
      });

      expect(answer, isNotNull);
      expect(answer!.name, 'Bessey refresh');
      // The building comes pre-filled from the room that was open — the
      // commonest new project is the building you are already standing in.
      expect(answer.building, 'BSS');
      expect(answer.spareTargetPercent, 10);
      // The starters are on by default, and the typed one is last.
      expect(answer.todos, hasLength(kStarterProjectTodos.length + 1));
      expect(answer.todos.last, 'Ring the dean');
    });

    testWidgets('a starter note can be taken off the list', (tester) async {
      final answer = await run(tester, (t) async {
        await t.tap(find.byKey(const ValueKey('setup_todo_0')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('setup_confirm')));
        await t.pumpAndSettle();
      });

      expect(answer!.todos, hasLength(kStarterProjectTodos.length - 1));
      expect(answer.todos, isNot(contains(kStarterProjectTodos.first)));
    });

    testWidgets('backing out comes back with nothing', (tester) async {
      final answer = await run(tester, (t) async {
        await t.tap(find.byKey(const ValueKey('setup_skip')));
        await t.pumpAndSettle();
      });
      expect(answer, isNull);
    });
  });

  testWidgets('starting a job from the toolbar asks how it is set up',
      (tester) async {
    // EVERY route to a new project goes through startNewProject, so this is
    // the one that has to be checked: a setup screen that only appeared on one
    // of three buttons is a screen nobody could rely on.
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();

    final wasOn = p.selectedTabIndex;
    await tester.tap(find.byKey(const ValueKey('new_project')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('project_setup_dialog')), findsOneWidget);
    // NOTHING HAS BEEN STARTED YET. The questions come before the job, so a
    // session that is in room mode is still in room mode while they are on
    // screen — and stays there if the answer is no.
    expect(p.hasOpenProject, isFalse);
    expect(p.selectedTabIndex, wasOn);

    await tester.tap(find.byKey(const ValueKey('setup_skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project_setup_dialog')), findsNothing);
    expect(p.hasOpenProject, isFalse,
        reason: 'backing out of the questions must not start a job');
    expect(p.selectedTabIndex, wasOn);
    expect(find.byKey(const ValueKey('banner_project')), findsNothing);
  });

  testWidgets('confirming the questions is what starts the job',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('new_project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('setup_name')),
      'Bessey refresh',
    );
    await tester.tap(find.byKey(const ValueKey('setup_confirm')));
    await tester.pumpAndSettle();

    expect(p.hasOpenProject, isTrue);
    expect(p.project.name, 'Bessey refresh');
    expect(p.selectedTabIndex, AppTab.project.index);
    expect(find.byKey(const ValueKey('banner_project')), findsOneWidget);

    // The snack bar that follows keeps its timer outside the widget tree (see
    // showTimedSnackBar), so it has to be allowed to expire before the tree
    // goes away.
    await tester.pumpAndSettle(const Duration(seconds: 8));
  });
}
