import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'dart:ui';

import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';

/// The job's own to-do list: the notes that are about the WORK rather than
/// about the building.
///
/// The failure this guards is a list that quietly loses something — a note
/// that comes back from a save without its state, a re-opened item still
/// claiming it was finished in March, or two notes sharing an id so that
/// ticking one ticks the other.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('todo_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a note is added, and blank text adds nothing', () {
    final project = BuildingProject();
    final id = project.addTodo('  chase Extron on the DTP lead time  ');

    expect(id, isNotEmpty);
    expect(project.todos, hasLength(1));
    // Trimmed on the way in — trailing space is not part of the note.
    expect(project.todos.single.text, 'chase Extron on the DTP lead time');
    expect(project.todos.single.state, ProjectTodoState.open);

    expect(project.addTodo('   '), isEmpty);
    expect(project.todos, hasLength(1));
  });

  test('every note gets its own id', () {
    final project = BuildingProject();
    final ids = {
      for (var i = 0; i < 5; i++) project.addTodo('note $i'),
    };
    expect(ids, hasLength(5));
  });

  test('ticking one stamps the date; re-opening clears it', () {
    final project = BuildingProject();
    final id = project.addTodo('move the second display');

    project.setTodoState(id, ProjectTodoState.done, when: DateTime(2026, 3, 4));
    expect(project.todos.single.isDone, isTrue);
    expect(project.todos.single.completed, DateTime(2026, 3, 4));

    // A note that says it was finished in March and is sitting in the open
    // column is a note that gets read wrong.
    project.setTodoState(id, ProjectTodoState.open);
    expect(project.todos.single.isDone, isFalse);
    expect(project.todos.single.completed, isNull);
  });

  test('blocked is still open work', () {
    final project = BuildingProject();
    final id = project.addTodo('waiting on the room list');
    project.setTodoState(id, ProjectTodoState.blocked);

    expect(project.todos.single.isOpen, isTrue);
    expect(project.openTodos, hasLength(1));
    // ...but not something anybody can pick up today.
    expect(project.actionableTodos, isEmpty);
  });

  test('ticking a note does not delete it; clearing done does', () {
    final project = BuildingProject();
    final keep = project.addTodo('still to do');
    final gone = project.addTodo('finished');
    project.setTodoState(gone, ProjectTodoState.done);

    expect(project.todos, hasLength(2));
    expect(project.openTodos, hasLength(1));

    expect(project.clearDoneTodos(), 1);
    expect(project.todos.single.id, keep);
    // Nothing left to clear.
    expect(project.clearDoneTodos(), 0);
  });

  test('text and room can be corrected in place', () {
    final project = BuildingProject();
    final id = project.addTodo('chek 214 scope');

    project.setTodoText(id, 'check whether 214 is still in scope');
    expect(project.todos.single.text, 'check whether 214 is still in scope');

    // Blank is ignored rather than blanking the note.
    project.setTodoText(id, '   ');
    expect(project.todos.single.text, 'check whether 214 is still in scope');

    project.setTodoRoom(id, 'room3');
    expect(project.todos.single.roomId, 'room3');
    project.setTodoRoom(id, '');
    expect(project.todos.single.roomId, '');
  });

  test('an unknown id changes nothing', () {
    final project = BuildingProject();
    project.addTodo('a note');
    project.setTodoState('nope', ProjectTodoState.done);
    project.setTodoText('nope', 'rewritten');
    project.removeTodo('nope');

    expect(project.todos, hasLength(1));
    expect(project.todos.single.text, 'a note');
    expect(project.todos.single.isOpen, isTrue);
  });

  group('it survives a save and a reload', () {
    test('the list round-trips with its states and dates', () async {
      final project = BuildingProject(name: 'Bessey Hall');
      final open = project.addTodo(
        'client wants the second display moved',
        created: DateTime(2026, 3, 1),
      );
      final blocked = project.addTodo('chase Extron', roomId: 'room2');
      final done = project.addTodo('confirm the rack location');
      project.setTodoState(blocked, ProjectTodoState.blocked);
      project.setTodoState(
        done,
        ProjectTodoState.done,
        when: DateTime(2026, 3, 4),
      );

      final file = '${dir.path}/bessey_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      expect(back.todos, hasLength(3));
      final byId = {for (final t in back.todos) t.id: t};
      expect(byId[open]!.text, 'client wants the second display moved');
      expect(byId[open]!.created, DateTime(2026, 3, 1));
      expect(byId[blocked]!.state, ProjectTodoState.blocked);
      expect(byId[blocked]!.roomId, 'room2');
      expect(byId[done]!.completed, DateTime(2026, 3, 4));
    });

    test('ids stay unique after a reload', () async {
      final project = BuildingProject();
      project.addTodo('one');
      project.addTodo('two');

      final file = '${dir.path}/p_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      // A reused id would make two notes the same note, and ticking one would
      // tick the other.
      final fresh = back.addTodo('three');
      expect(back.todos.map((t) => t.id).toSet(), hasLength(3));
      expect(fresh, isNot(anyOf(['todo1', 'todo2'])));
    });

    test('a hand-edited file missing a state or date still reads', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'vendors': <dynamic>[],
        'todos': [
          {'id': 'todo1', 'text': 'a note with nothing else on it'},
          // An unreadable state surfaces the note rather than burying it.
          {'id': 'todo2', 'text': 'bad state', 'state': 'nonsense'},
          // Nothing to show for an empty one.
          {'id': 'todo3', 'text': '   '},
        ],
      });

      expect(back.todos, hasLength(2));
      expect(back.todos.every((t) => t.state == ProjectTodoState.open), isTrue);
      expect(back.todos.first.created, isNotNull);
    });

    test('a project with only a note on it is not empty', () {
      final project = BuildingProject();
      project.addTodo('one thing');
      // isEmpty drives the "nothing to save" path, and a note somebody typed
      // is work that must not be thrown away.
      expect(project.isEmpty, isFalse);
    });

    test('clone carries the list and does not share it', () {
      final project = BuildingProject();
      final id = project.addTodo('a note');
      final copy = project.clone();

      copy.setTodoState(id, ProjectTodoState.done);
      copy.addTodo('another');

      expect(project.todos, hasLength(1));
      expect(project.todos.single.isOpen, isTrue);
      expect(copy.todos, hasLength(2));
    });
  });

  group('deadlines on notes', () {
    test('a note with no date is never late', () {
      final project = BuildingProject();
      final id = project.addTodo('someday');
      expect(project.todos.single.isOverdue(DateTime(2030, 1, 1)), isFalse);
      expect(project.overdueTodos(DateTime(2030, 1, 1)), isEmpty);
      expect(project.todos.single.daysUntilDue(), isNull);

      project.setTodoDue(id, DateTime(2026, 3, 1));
      expect(project.todos.single.isOverdue(DateTime(2026, 3, 2)), isTrue);
    });

    test('a note due today is not yet late', () {
      final project = BuildingProject();
      project.addTodo('call the client', due: DateTime(2026, 3, 4));
      // Due today means due today, not overdue.
      expect(project.overdueTodos(DateTime(2026, 3, 4)), isEmpty);
      expect(project.overdueTodos(DateTime(2026, 3, 5)), hasLength(1));
    });

    test('a finished note is never late, however late it was', () {
      final project = BuildingProject();
      final id = project.addTodo('was due ages ago', due: DateTime(2026, 1, 1));
      expect(project.overdueTodos(DateTime(2026, 6, 1)), hasLength(1));

      project.setTodoState(id, ProjectTodoState.done);
      // The list is not there to keep score.
      expect(project.overdueTodos(DateTime(2026, 6, 1)), isEmpty);
    });

    test('due soon is the week ahead, and excludes what has gone', () {
      final project = BuildingProject();
      project.addTodo('this week', due: DateTime(2026, 3, 8));
      project.addTodo('next month', due: DateTime(2026, 4, 8));
      project.addTodo('gone', due: DateTime(2026, 3, 1));
      project.addTodo('no date at all');

      final soon = project.todosDueSoon(asOf: DateTime(2026, 3, 4));
      expect(soon, hasLength(1));
      expect(soon.single.text, 'this week');
    });

    test('a date is cleared back to no date', () {
      final project = BuildingProject();
      final id = project.addTodo('a note', due: DateTime(2026, 3, 1));
      expect(project.todos.single.due, DateTime(2026, 3, 1));

      project.setTodoDue(id, null);
      expect(project.todos.single.due, isNull);
      expect(project.todos.single.isOverdue(DateTime(2030, 1, 1)), isFalse);
    });

    test('a due date keeps only the day, and round-trips', () async {
      final project = BuildingProject();
      final id = project.addTodo('a note');
      project.setTodoDue(id, DateTime(2026, 3, 1, 16, 20));
      expect(project.todos.single.due, DateTime(2026, 3, 1));

      final file = '${dir.path}/due_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);
      expect(back.todos.single.due, DateTime(2026, 3, 1));
    });

    test('clone carries the due date', () {
      final project = BuildingProject();
      final id = project.addTodo('a note', due: DateTime(2026, 3, 1));
      final copy = project.clone();
      copy.setTodoDue(id, DateTime(2026, 4, 1));

      expect(project.todos.single.due, DateTime(2026, 3, 1));
      expect(copy.todos.single.due, DateTime(2026, 4, 1));
    });
  });

  group('what a room is called on the list', () {
    LoadedRoom loaded({String bldg = 'BSS', String number = '103'}) =>
        LoadedRoom(
          configPath: '/rooms/BSS_103_config.json',
          title: 'Behavioral And Social Science 103',
          model: const AvFlowModel(
            nodes: [],
            cables: [],
            racks: [],
            rackSlots: {},
            canvasSize: Size(900, 560),
            roomTitle: '',
            unplaced: [],
          ),
          settings: RoomCostSettings(),
          config: {
            'SYSTEM_SETUP': {
              if (bldg.isNotEmpty) 'gve_bldg': bldg,
              if (number.isNotEmpty) 'gve_room': number,
            },
          },
        );

    ProjectRoomCost cost(LoadedRoom room, {String label = ''}) =>
        ProjectRoomCost(
          ref: ProjectRoomRef(
            id: 'room1',
            configPath: room.configPath,
            label: label,
          ),
          room: room,
        );

    test('it is the building code and number, not the file', () {
      // "BSS_103_config" is how the room is STORED. "BSS 103" is what is on
      // the door, and what a note filed against the room has to say.
      expect(loaded().roomCode, 'BSS 103');
      expect(cost(loaded()).codeName, 'BSS 103');
    });

    test('a code with no number, and a number with no code, still read', () {
      expect(loaded(number: '').roomCode, 'BSS');
      expect(loaded(bldg: '').roomCode, '103');
    });

    test('a room that says neither falls back rather than going blank', () {
      final bare = loaded(bldg: '', number: '');
      expect(bare.roomCode, isEmpty);
      // The full name off the config, which is better than the file name and
      // is what the rest of the app already shows.
      expect(cost(bare).codeName, 'Behavioral And Social Science 103');
    });

    test('a room that could not be read still gets a name', () {
      final broken = LoadedRoom(
        configPath: '/rooms/gone_config.json',
        title: '',
        model: const AvFlowModel(
            nodes: [],
            cables: [],
            racks: [],
            rackSlots: {},
            canvasSize: Size(900, 560),
            roomTitle: '',
            unplaced: [],
          ),
        settings: RoomCostSettings(),
        error: 'no such file',
      );
      expect(broken.roomCode, isEmpty);
    });
  });
}
