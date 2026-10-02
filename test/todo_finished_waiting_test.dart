import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_history_view.dart';

/// Who finished what on the job list, and what a waiting note waits on.
void main() {
  group('finished tasks', () {
    BuildingProject job() {
      final p = BuildingProject(name: 'Job');
      p.addTodo('order cables');
      p.addTodo('ring the dean');
      p.addTodo('check ARTS');
      return p;
    }

    test('completing names who did it; reopening forgets', () {
      final p = job();
      p.setTodoState('todo1', ProjectTodoState.done, by: 'jsmith');
      expect(p.todos.first.completedBy, 'jsmith');
      p.setTodoState('todo1', ProjectTodoState.open, by: 'jsmith');
      expect(p.todos.first.completedBy, isEmpty);
    });

    test('deleted and cleared notes are kept, under who finished them', () {
      final p = job();
      p.setTodoState('todo1', ProjectTodoState.done, by: 'jsmith');
      p.setTodoState('todo2', ProjectTodoState.done, by: 'dstanley');
      p.removeTodo('todo3', by: 'jsmith');
      p.clearDoneTodos(by: 'dstanley');

      expect(p.todos, isEmpty);
      expect(p.todoArchive, hasLength(3));

      final done = finishedTasks(p);
      final byText = {for (final t in done) t.todo.text: t};
      expect(byText['order cables']!.by, 'jsmith', reason: 'who completed it');
      expect(byText['order cables']!.removedBy, 'dstanley');
      expect(byText['ring the dean']!.by, 'dstanley');
      expect(byText['check ARTS']!.completed, isFalse);
      expect(byText['check ARTS']!.by, 'jsmith', reason: 'who deleted it');

      // Kept in the file.
      final back = BuildingProject.fromJson(p.toJson());
      expect(back.todoArchive, hasLength(3));
      expect(
        finishedTasks(back).map((t) => t.by).toSet(),
        {'jsmith', 'dstanley'},
      );
    });

    testWidgets('the history has a tab for them, by person', (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final provider = AppStateProvider(autoLoadSettings: false)
        ..newProject(name: 'Job');
      provider.project.addTodo('order cables');
      provider.project.addTodo('ring the dean');
      provider.project.setTodoState(
        'todo1',
        ProjectTodoState.done,
        by: 'jsmith',
      );
      provider.project.removeTodo('todo2', by: 'dstanley');

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showHistoryDialog(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history_tab_finished')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('finished_todo1')), findsOneWidget);
      expect(find.byKey(const ValueKey('finished_todo2')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('finished_person_jsmith')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('finished_todo1')), findsOneWidget);
      expect(find.byKey(const ValueKey('finished_todo2')), findsNothing);
    });
  });

  group('waiting on', () {
    test('the note and its files are kept with the job note', () async {
      final dir = Directory.systemTemp.createTempSync('todo_wait_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final p = AppStateProvider(autoLoadSettings: false)
        ..newProject(name: 'Wait');
      final file = path.join(dir.path, 'Wait_project.json');
      expect(await p.saveProject(to: file), isEmpty);
      p.addProjectTodo('order displays');
      final id = p.project.todos.single.id;

      p.setProjectTodoWaitingNote(id, ' Extron to confirm lead time ');
      p.setProjectTodoState(id, ProjectTodoState.blocked);
      final quote = File(path.join(dir.path, 'quote.pdf'))
        ..writeAsStringSync('x');
      expect(
        await p.attachToProjectTodo(id, [quote.path], waiting: true),
        isEmpty,
      );

      final t = p.project.todos.single;
      expect(t.waitingNote, 'Extron to confirm lead time');
      expect(t.waitingAttachments, hasLength(1));
      expect(t.attachments, isEmpty, reason: 'kept apart from the note\'s own');

      final back = BuildingProject.fromJson(p.project.toJson()).todos.single;
      expect(back.waitingNote, t.waitingNote);
      expect(back.waitingAttachments, t.waitingAttachments);

      await p.removeProjectTodoAttachment(id, t.waitingAttachments.single);
      expect(p.project.todos.single.waitingAttachments, isEmpty);
    });
  });
}
