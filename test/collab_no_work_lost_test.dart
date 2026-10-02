import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/collab/collab_controller.dart';
import 'package:extron_configurator/collab/json_merge.dart';
import 'package:extron_configurator/collab/presence.dart';
import 'package:extron_configurator/project_budget.dart';

/// ============================================================================
///  TWO PEOPLE, ONE JOB, NOTHING LOST
/// ============================================================================
///  Alice and Bob open the same project and the same room on the share, both
///  work on them at once, and both save. Each save goes the way the app's Save
///  does - whatever the other saved meanwhile is combined in first, keeping
///  both wherever both can be kept - and at the end the file has everything
///  either of them did.
/// ============================================================================
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('collab_both_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Long enough for a save to move the file's time.
  Future<void> later() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  AppStateProvider person(String user) => AppStateProvider(
    autoLoadSettings: false,
    collabIdentity: CollabIdentity(user: user, machine: '$user-PC'),
  )..collab.enabled = true;

  /// The app's Save: combine what was saved since, then write. Text both
  /// changed keeps both; anything else the saver keeps theirs is reported.
  Future<List<MergeConflict>> saveProject(AppStateProvider p) async {
    await p.collab.tick();
    var conflicts = <MergeConflict>[];
    if (p.collab.previewMerge(CollabDocKind.project) != null) {
      final out = await p.collab.mergeIncoming(
        CollabDocKind.project,
        resolve: (c) => c.canKeepBoth ? MergeSide.both : MergeSide.mine,
      );
      conflicts = out.conflicts;
    }
    expect(await p.saveProject(), isEmpty);
    await later();
    return conflicts;
  }

  Future<void> saveRoom(AppStateProvider p) async {
    await p.collab.tick();
    if (p.collab.previewMerge(CollabDocKind.room) != null) {
      await p.collab.mergeIncoming(
        CollabDocKind.room,
        resolve: (c) => c.canKeepBoth ? MergeSide.both : MergeSide.mine,
      );
    }
    expect(await p.saveRoomInPlace(), isNot(startsWith('Error')));
    await later();
  }

  String writeRoom(String name) {
    final config = path.join(dir.path, name, 'config.json');
    Directory(path.dirname(config)).createSync(recursive: true);
    File(config).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    return config;
  }

  BuildingProject onDisk(String file) => BuildingProject.fromJson(
    jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>,
  );

  test('both people\'s work on the job is in the file at the end', () async {
    // The job as it stood when both opened it.
    final file = path.join(dir.path, 'Job_project.json');
    final setup = person('setup')..newProject(name: 'Bessey Hall');
    setup.addProjectTodo('existing note');
    setup.addProjectTodo('note to be deleted');
    setup.setProjectBudget(50000);
    expect(await setup.saveProject(to: file), isEmpty);
    await later();

    final alice = person('alice');
    final bob = person('bob');
    expect(await alice.openProject(file), isEmpty);
    expect(await bob.openProject(file), isEmpty);
    await alice.collab.tick();
    await bob.collab.tick();
    final existing = alice.project.todos.first.id;
    final doomed = alice.project.todos.last.id;

    // AT THE SAME TIME:
    // Alice adds a note, a room, a vendor and a budget line, rewords the
    // existing note, deletes the other one, and sets the budget.
    alice.addProjectTodo('alice: order the mounts');
    alice.addRoomToProject(writeRoom('ARTS_111'));
    alice.addProjectVendor(name: 'Alice Supply');
    alice.addBudgetLine(BudgetLine.create(item: 'Alice line', amount: 10));
    alice.addProjectDelivery(itemName: 'Wall plate', qty: 4);
    alice.setProjectTodoText(existing, 'existing note, reworded by alice');
    alice.removeProjectTodo(doomed);
    alice.setProjectBudget(60000);

    // Bob adds his own of each - numbered the same as Alice's - ticks the
    // existing note done, edits the note Alice is deleting, and sets the
    // budget too.
    bob.addProjectTodo('bob: ring the dean');
    bob.addRoomToProject(writeRoom('HOLT_170'));
    bob.addProjectVendor(name: 'Bob Supply');
    bob.addBudgetLine(BudgetLine.create(item: 'Bob line', amount: 20));
    bob.addProjectDelivery(itemName: 'Ceiling mic', qty: 2);
    bob.setProjectTodoState(existing, ProjectTodoState.done);
    bob.setProjectTodoText(doomed, 'bob still needs this note');
    bob.setProjectBudget(70000);

    // Alice saves first; Bob saves over the top of her save.
    expect(await saveProject(alice), isEmpty);
    final bobsConflicts = await saveProject(bob);
    // Then Alice picks up Bob's save and saves again.
    await saveProject(alice);

    final job = onDisk(file);
    final notes = {for (final t in job.todos) t.text: t};

    // Both new notes - though both were given the same number.
    expect(notes.keys, containsAll(['alice: order the mounts', 'bob: ring the dean']));
    // Different changes to one note: both kept.
    expect(notes['existing note, reworded by alice']?.state, ProjectTodoState.done);
    // Deleted by one, edited by the other: kept, with the edit.
    expect(notes.keys, contains('bob still needs this note'));
    // Both rooms, both vendors, both budget lines, both deliveries.
    expect(
      job.rooms.map((r) => path.basename(path.dirname(r.configPath))),
      containsAll(['ARTS_111', 'HOLT_170']),
    );
    expect(job.rooms.map((r) => r.id).toSet(), hasLength(job.rooms.length));
    expect(
      job.vendors.map((v) => v.name),
      containsAll(['Alice Supply', 'Bob Supply']),
    );
    expect(
      job.budgetLines.map((l) => l.item),
      containsAll(['Alice line', 'Bob line']),
    );
    expect(
      job.deliveries.map((d) => d.itemName),
      containsAll(['Wall plate', 'Ceiling mic']),
    );
    expect(job.todos.map((t) => t.id).toSet(), hasLength(job.todos.length),
        reason: 'no two notes share an id');

    // The one thing both set to different numbers was not decided silently:
    // it came to Bob as a choice.
    expect(bobsConflicts.map((c) => c.path), contains('budget'));

    // Both histories are on the job.
    final who = {for (final h in job.history) h.user};
    expect(who, containsAll(['alice', 'bob']));

    // And both copies now hold what the file holds.
    expect(alice.project.todos.length, job.todos.length);
    for (final p in [setup, alice, bob]) {
      p.dispose();
    }
  });

  test('both people\'s boxes on one room drawing are kept', () async {
    final config = writeRoom('BSS_103');
    final alice = person('alice');
    final bob = person('bob');
    for (final p in [alice, bob]) {
      expect(await p.openConfigAtPath(config), isTrue);
      p.loadAvFlowForCurrentConfig();
      await p.collab.tick();
    }

    AvNode box(String id, String model) => AvNode(
      id: id,
      label: model,
      model: model,
      pos: Offset.zero,
      ports: const [],
    );

    // Both add the first box on the drawing - so both call it AVNODE_1 - and
    // each changes a different field of the room.
    alice.addAvNode(box('AVNODE_1', 'Projector A'));
    alice.updateDeviceValue('SYSTEM_SETUP', 'gve_room', '103');
    bob.addAvNode(box('AVNODE_1', 'Camera B'));
    bob.updateDeviceValue('SYSTEM_SETUP', 'gve_bldg', 'BSS');

    await saveRoom(alice);
    await saveRoom(bob);

    final reread = person('reader');
    expect(await reread.openConfigAtPath(config), isTrue);
    reread.loadAvFlowForCurrentConfig();
    expect(
      reread.avNodes.map((n) => n.model),
      containsAll(['Projector A', 'Camera B']),
    );
    expect(reread.avNodes.map((n) => n.id).toSet(), hasLength(2));
    final setup = reread.roomConfig['SYSTEM_SETUP'] as Map;
    expect(setup['gve_room'], '103');
    expect(setup['gve_bldg'], 'BSS');
    for (final p in [alice, bob, reread]) {
      p.dispose();
    }
  });

  test('five people working at once lose none of it', () async {
    final file = path.join(dir.path, 'Five_project.json');
    final setup = person('setup')..newProject(name: 'Five');
    setup.addProjectTodo('the shared note');
    expect(await setup.saveProject(to: file), isEmpty);
    await later();

    final names = ['ann', 'ben', 'cat', 'dee', 'eve'];
    final people = [for (final n in names) person(n)];
    for (final p in people) {
      expect(await p.openProject(file), isEmpty);
      await p.collab.tick();
    }
    final shared = people.first.project.todos.single.id;

    // All five at once: three notes each, a vendor, a budget line, a room,
    // and each a different thing done to the shared note.
    for (final p in people) {
      final me = p.collab.me.user;
      for (var i = 1; i <= 3; i++) {
        p.addProjectTodo('$me note $i');
      }
      p.addProjectVendor(name: '$me Supply');
      p.addBudgetLine(BudgetLine.create(item: '$me line', amount: 1));
      p.addRoomToProject(writeRoom('ROOM_$me'));
    }
    people[0].setProjectTodoText(shared, 'the shared note, as ann put it');
    people[1].setProjectTodoState(shared, ProjectTodoState.blocked);
    people[2].setProjectTodoDue(shared, DateTime(2026, 11, 2));
    people[3].setProjectTodoWaitingNote(shared, 'the dean');

    // Saved one after another, in turn - each over the last one's.
    for (final p in people) {
      await saveProject(p);
    }
    // And everybody picks up the last save and saves again.
    for (final p in people) {
      await saveProject(p);
    }

    final job = onDisk(file);
    final texts = job.todos.map((t) => t.text).toSet();
    for (final n in names) {
      for (var i = 1; i <= 3; i++) {
        expect(texts, contains('$n note $i'));
      }
      expect(job.vendors.map((v) => v.name), contains('$n Supply'));
      expect(job.budgetLines.map((l) => l.item), contains('$n line'));
      expect(
        job.rooms.map((r) => path.basename(path.dirname(r.configPath))),
        contains('ROOM_$n'),
      );
    }
    expect(job.todos, hasLength(16), reason: '15 new and the shared one');
    expect(job.todos.map((t) => t.id).toSet(), hasLength(16));
    expect(job.rooms.map((r) => r.id).toSet(), hasLength(5));

    // Four people's different changes to one note, all on it.
    final note = job.todos.firstWhere((t) => t.id == shared);
    expect(note.text, 'the shared note, as ann put it');
    expect(note.state, ProjectTodoState.blocked);
    expect(note.due, DateTime(2026, 11, 2));
    expect(note.waitingNote, 'the dean');

    // Every copy ends up holding what the file holds.
    for (final p in people) {
      expect(p.project.todos.length, 16, reason: p.collab.me.user);
    }
    for (final p in [setup, ...people]) {
      p.dispose();
    }
  });
}
