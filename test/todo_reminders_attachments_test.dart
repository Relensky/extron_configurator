import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/todo_calendar.dart';

/// A job note sent out as a calendar reminder, and files kept with a note.
void main() {
  group('the reminder', () {
    final todo = ProjectTodo(
      id: 'todo3',
      text: 'Chase Extron, the DTP lead time',
      created: DateTime(2026, 9, 1),
      due: DateTime(2026, 10, 8),
    );

    test('is an all-day event on the date, with a reminder that morning', () {
      final ics = todoCalendarFile(
        todo: todo,
        date: DateTime(2026, 10, 8),
        projectName: '600k refresh',
        scope: 'THMA 116',
        now: DateTime.utc(2026, 10, 1, 12),
      );
      final lines = ics.split('\r\n');
      expect(lines.first, 'BEGIN:VCALENDAR');
      expect(lines, contains('DTSTART;VALUE=DATE:20261008'));
      expect(lines, contains('DTEND;VALUE=DATE:20261009'));
      expect(lines, contains('TRIGGER;RELATED=START:PT9H'));
      expect(lines, contains('UID:todo-todo3-20261008@room-config-builder'));
      // Commas escaped, the job named first.
      expect(
        ics,
        contains(r'SUMMARY:600k refresh: Chase Extron\, the DTP lead time'),
      );
      expect(ics, contains(r'About: THMA 116'));
      // No line longer than the format allows.
      expect(lines.every((l) => l.length <= 75), isTrue);
    });

    test('is written to a file that opens as a calendar', () async {
      final ics = todoCalendarFile(
        todo: todo,
        date: DateTime(2026, 10, 8),
        projectName: '',
      );
      final file = await writeTodoCalendarFile(ics, todo);
      addTearDown(() => File(file).parent.deleteSync(recursive: true));
      expect(path.extension(file), '.ics');
      expect(File(file).readAsStringSync(), ics);
    });
  });

  group('attachments', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('todo_attach_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('are copied beside the project and kept with the note', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..newProject(name: 'Attach');
      final projectFile = path.join(dir.path, 'Attach_project.json');
      expect(await p.saveProject(to: projectFile), isEmpty);
      p.addProjectTodo('photo of the wall');
      final id = p.project.todos.single.id;

      final source = File(path.join(dir.path, 'outside', 'wall.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      expect(await p.attachToProjectTodo(id, [source.path, source.path]), '');

      final kept = p.project.todos.single.attachments;
      expect(kept, hasLength(2), reason: 'same name twice gets a number');
      expect(path.isAbsolute(kept.first), isFalse, reason: 'travels with job');
      final copy = p.resolveTodoAttachment(kept.first);
      expect(copy, startsWith(path.join(dir.path, 'Attach_project_attachments')));
      expect(File(copy).readAsBytesSync(), [1, 2, 3]);
      expect(path.basename(p.resolveTodoAttachment(kept.last)), 'wall (2).png');

      // In the file.
      expect(await p.saveProject(), isEmpty);
      final back = BuildingProject.fromJson(
        jsonDecode(File(projectFile).readAsStringSync()) as Map<String, dynamic>,
      );
      expect(back.todos.single.attachments, kept);

      // Removed: off the note, the copy deleted, the original left.
      await p.removeProjectTodoAttachment(id, kept.first);
      expect(p.project.todos.single.attachments, [kept.last]);
      expect(File(copy).existsSync(), isFalse);
      expect(source.existsSync(), isTrue);
    });

    test('need the project saved first', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..newProject(name: 'Unsaved');
      p.addProjectTodo('note');
      final source = File(path.join(dir.path, 'a.pdf'))..writeAsStringSync('x');
      final problem = await p.attachToProjectTodo(
        p.project.todos.single.id,
        [source.path],
      );
      expect(problem, contains('Save the project first'));
      expect(p.project.todos.single.attachments, isEmpty);
    });
  });
}
