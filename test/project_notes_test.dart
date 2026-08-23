import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_view.dart';

/// Notes on the job, and notes on one room.
///
/// The failure this guards is a note that is typed and then is not there — a
/// box wired to nothing, a room's note landing on the project, or either of
/// them lost on the way to the file. A note nobody can rely on is worse than
/// no notes field, because somebody will put the asbestos warning in it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('notes_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A job with two rooms on it, neither of which needs to exist on disk —
  /// the notes are on the project's own room list, not in the room files.
  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final stem in ['bss101', 'bss103']) {
      final file = '${dir.path}/${stem}_config.json';
      File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
      p.addRoomToProject(file);
    }
    return p;
  }

  Future<void> pumpNotes(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_notes')));
    await tester.pumpAndSettle();
  }

  testWidgets('the job gets a note, and it is the project that keeps it', (
    tester,
  ) async {
    final p = withProject();
    await pumpNotes(tester, p);

    // The editable inside the LiveTextField — enterText needs the TextField
    // itself, not the wrapper around it.
    final box = find.descendant(
      of: find.byKey(const ValueKey('project_notes_box')),
      matching: find.byType(TextField),
    );
    expect(box, findsOneWidget, reason: 'the job has a notes box');

    await tester.enterText(box, 'Stakeholder approved the 86in, not the 98in.');
    await tester.pump();

    expect(p.project.notes, 'Stakeholder approved the 86in, not the 98in.');
    // On the project, not smeared onto a room.
    expect(p.project.rooms.every((r) => r.notes.isEmpty), isTrue);
    expect(p.projectDirty, isTrue, reason: 'a typed note is unsaved work');
  });

  testWidgets('each room gets its own, and they do not cross', (tester) async {
    final p = withProject();
    await pumpNotes(tester, p);

    final first = p.project.rooms.first;
    final second = p.project.rooms.last;

    await tester.enterText(
      find.descendant(
        of: find.byKey(ValueKey('room_notes_box_${first.id}')),
        matching: find.byType(TextField),
      ),
      'Asbestos above the grid - no drilling until abatement.',
    );
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byKey(ValueKey('room_notes_box_${second.id}')),
        matching: find.byType(TextField),
      ),
      'Shares a wall with the studio - no fans on that side.',
    );
    await tester.pump();

    expect(
      p.project.roomById(first.id)!.notes,
      'Asbestos above the grid - no drilling until abatement.',
    );
    expect(
      p.project.roomById(second.id)!.notes,
      'Shares a wall with the studio - no fans on that side.',
    );
    // A room's note is meaningless anywhere else, so it must not have gone to
    // the job as well.
    expect(p.project.notes, isEmpty);
  });

  testWidgets('a room with no note is still offered one', (tester) async {
    final p = withProject();
    await pumpNotes(tester, p);
    for (final room in p.project.rooms) {
      expect(
        find.byKey(ValueKey('room_notes_box_${room.id}')),
        findsOneWidget,
        reason: 'every room on the job gets a box, empty or not',
      );
    }
  });

  testWidgets('a job with no rooms says so rather than showing nothing', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Empty');
    await pumpNotes(tester, p);

    expect(find.text('No rooms on this job yet.'), findsOneWidget);
    // The job's own note still works — it is the half that does not need
    // rooms, and it is where the contract note goes.
    expect(
      find.byKey(const ValueKey('project_notes_box')),
      findsOneWidget,
    );
  });

  test('both notes survive a save and a reload', () async {
    final project = BuildingProject(name: 'Bessey Hall');
    project.rooms.add(
      ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: 'bss101_config.json',
        notes: 'Asbestos above the grid.',
      ),
    );
    project.notes = 'Stakeholder approved the 86in.';

    final file = '${dir.path}/bessey_project.json';
    await project.save(file);
    final back = await BuildingProject.load(file);

    expect(back.notes, 'Stakeholder approved the 86in.');
    expect(back.rooms.single.notes, 'Asbestos above the grid.');
  });

  test('the workbook carries both without anybody copying them across', () {
    // The project's note is on the Summary and a room's is beside that room,
    // which is the whole reason these are worth typing rather than emailing.
    final project = BuildingProject(name: 'Bessey Hall');
    project.notes = 'Site access via the loading dock only.';
    expect(project.toJson()['notes'], 'Site access via the loading dock only.');
  });

  testWidgets('the Rooms pane carries the same note, and writes it through', (
    tester,
  ) async {
    final p = withProject();
    tester.view.physicalSize = const Size(1900, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();

    final room = p.project.rooms.first;
    final cell = find.descendant(
      of: find.byKey(ValueKey('room_row_notes_${room.id}')),
      matching: find.byType(TextField),
    );
    expect(cell, findsOneWidget, reason: 'the room list has a notes column');

    await tester.enterText(cell, 'Asbestos above the grid.');
    await tester.pump();
    expect(p.project.roomById(room.id)!.notes, 'Asbestos above the grid.');

    // ONE field in two places, not two fields that drift: what is typed on
    // the room list is what the Notes pane shows.
    await tester.tap(find.byKey(const ValueKey('project_pane_notes')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(ValueKey('room_notes_box_${room.id}')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      'Asbestos above the grid.',
    );
  });
}
