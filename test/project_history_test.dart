import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_history_view.dart';

/// Who changed what, and when.
///
/// The failure this guards is a history that cannot answer the question it
/// exists for: an entry that names a merge key instead of a part, one that
/// loses its meaning the moment the item is renamed, a log that records every
/// keystroke, or one that grows until the project file is slow to open.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('history_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  const screenKey = 'equipment|desc:~projection screen';
  String itemKey(String k) => AppStateProvider.projectPartItemKey(k);

  AppStateProvider job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    return p;
  }

  group('what gets recorded', () {
    test('a lead time records the value, the part and the login', () {
      final p = job();
      p.setProjectPartLeadTime(
        screenKey,
        42,
        partName: 'Projection screen 120in',
      );

      final entry = p.project.historyFor(itemKey(screenKey)).single;
      expect(entry.field, 'Lead time');
      expect(entry.summary, contains('42'));
      // The part as somebody reads it, not the merge key it is filed under.
      expect(entry.itemName, 'Projection screen 120in');
      expect(entry.itemKind, 'part');
      // The Windows login. Blank on a machine whose environment says nothing,
      // which is honest rather than a user called 'unknown'.
      expect(entry.user, currentUserName());
    });

    test('an order records the PO and the date', () {
      final p = job();
      p.setProjectPartOrder(
        screenKey,
        PartOrder(poNumber: 'PO-1234', orderedOn: DateTime(2026, 3, 4)),
        partName: 'Projection screen',
      );

      final entry = p.project.historyFor(itemKey(screenKey)).single;
      expect(entry.field, 'Order');
      expect(entry.summary, contains('PO-1234'));
      expect(entry.summary, contains('2026-03-04'));
    });

    test('editing the PO text alone does not log a second time', () {
      final p = job();
      p.setProjectPartOrder(
        screenKey,
        PartOrder(orderedOn: DateTime(2026, 3, 4)),
        partName: 'Screen',
      );
      // The paperwork catching up is not a new decision — and a log that
      // recorded every keystroke of a PO number would be unreadable.
      p.setProjectPartOrder(
        screenKey,
        PartOrder(orderedOn: DateTime(2026, 3, 4), poNumber: 'PO-1'),
        partName: 'Screen',
      );
      p.setProjectPartOrder(
        screenKey,
        PartOrder(orderedOn: DateTime(2026, 3, 4), poNumber: 'PO-12'),
        partName: 'Screen',
      );

      expect(p.project.historyFor(itemKey(screenKey)), hasLength(1));
    });

    test('arriving IS a new decision and gets its own line', () {
      final p = job();
      p.setProjectPartOrder(
        screenKey,
        PartOrder(orderedOn: DateTime(2026, 3, 4)),
        partName: 'Screen',
      );
      p.setProjectPartOrder(
        screenKey,
        PartOrder(
          orderedOn: DateTime(2026, 3, 4),
          receivedOn: DateTime(2026, 4, 1),
        ),
        partName: 'Screen',
      );

      final entries = p.project.historyFor(itemKey(screenKey));
      expect(entries, hasLength(2));
      // Newest first.
      expect(entries.first.summary, contains('arrived'));
      expect(entries.last.summary, contains('ordered'));
    });

    test('setting the same value again records nothing', () {
      final p = job();
      p.setProjectPartLeadTime(screenKey, 42, partName: 'Screen');
      p.setProjectPartLeadTime(screenKey, 42, partName: 'Screen');
      expect(p.project.historyFor(itemKey(screenKey)), hasLength(1));
    });

    test('the job list, phases and rooms are logged too', () {
      final p = job();
      p.addProjectTodo('chase Extron');
      final todoId = p.project.todos.single.id;
      p.setProjectTodoState(todoId, ProjectTodoState.done);

      final todo = p.project.historyFor('todo:$todoId');
      expect(todo, hasLength(2));
      expect(todo.first.summary, 'marked done');
      expect(todo.last.summary, 'added');
      expect(todo.first.itemName, 'chase Extron');

      final track = p.addProjectTrack('Infrastructure');
      p.setProjectTrackDeadline(track.id, DateTime(2026, 4, 1));
      final phase = p.project.historyFor('track:${track.id}');
      expect(phase, hasLength(2));
      expect(phase.first.field, 'Phase deadline');
    });

    test('a removal is named before the thing goes', () {
      final p = job();
      p.addProjectTodo('something');
      final id = p.project.todos.single.id;
      p.removeProjectTodo(id);

      // The entry that records a removal has to say WHAT was removed, which
      // means naming it before it is gone.
      final entry = p.project.historyFor('todo:$id').first;
      expect(entry.summary, 'removed');
      expect(entry.itemName, 'something');
    });

    test('the deadline and the job notes land on the project itself', () {
      final p = job();
      p.setProjectDeadline(DateTime(2026, 6, 1));
      p.setProjectField(notes: 'Site access via the loading dock.');

      final entries = p.project.historyFor('project');
      expect(entries, hasLength(2));
      expect(entries.first.field, 'Notes');
      expect(entries.last.field, 'Delivery deadline');
      expect(entries.last.summary, contains('2026-06-01'));
    });

    test('a note typed twice with the same text logs once', () {
      final p = job();
      p.setProjectField(notes: 'same');
      p.setProjectField(notes: 'same');
      expect(p.project.historyFor('project'), hasLength(1));
    });
  });

  group('a room is named the way the work order names it', () {
    /// A room config with the code on the door in it, on disk.
    String writeRoom(
      String stem, {
      String bldg = 'BSS',
      String number = '103',
    }) {
      final configPath = path.join(dir.path, '${stem}_config.json');
      File(configPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Behavioral And Social Science 103',
          if (bldg.isNotEmpty) 'gve_bldg': bldg,
          if (number.isNotEmpty) 'gve_room': number,
        },
      }));
      return configPath;
    }

    test('saving a room records the room code and the file', () async {
      final p = job();
      final file = writeRoom('bss103');
      p.addRoomToProject(file);
      await p.openConfigAtPath(file);

      await p.saveCurrentConfigToFile();

      final saved = p.project.history.where((e) => e.field == 'Saved');
      expect(saved, hasLength(1));
      // 'BSS_103_config' is how the room is STORED. This is what is on the
      // door, followed by which of its files was written.
      expect(saved.single.itemName, 'BSS 103 - Config');
      expect(saved.single.summary, startsWith('to disk'));
    });

    test('the sidecars written with it are named too', () async {
      final p = job();
      final file = writeRoom('bss103');
      p.addRoomToProject(file);
      await p.openConfigAtPath(file);
      // A room with a diagram writes its AV flow beside the config.
      p.addAvNode(const AvNode(
        id: 'd1',
        label: 'Lectern TX',
        model: 'DTP2 T 211',
        pos: Offset.zero,
        ports: [],
      ));

      await p.saveCurrentConfigToFile();

      final saved = p.project.history.lastWhere((e) => e.field == 'Saved');
      // One entry per SAVE, not one per file: six rows per press would bury
      // every decision on the job under the act of pressing Save.
      expect(p.project.history.where((e) => e.field == 'Saved'), hasLength(1));
      expect(saved.summary, contains('AV flow'));
    });

    test('a room nobody has read yet falls back to its file', () {
      // Neither open nor priced, so there is no config in memory to read a
      // code out of. A file stem is a poor name and it is still better than
      // an entry with no subject at all.
      final p = job();
      p.addRoomToProject(writeRoom('mystery'));
      final id = p.project.rooms.first.id;
      expect(p.projectRoomLogName(id), 'mystery_config');
      expect(p.projectRoomLogName(id, file: 'Config'),
          'mystery_config - Config');
    });

    test('a room saved outside the open job is not logged onto it', () async {
      final p = job();
      final file = writeRoom('elsewhere');
      // Never added to the project.
      await p.openConfigAtPath(file);

      await p.saveCurrentConfigToFile();

      expect(p.project.history.where((e) => e.field == 'Saved'), isEmpty);
    });

    test('adding and removing a room name it the same way', () async {
      final p = job();
      final file = writeRoom('bss103');
      p.addRoomToProject(file);
      await p.openConfigAtPath(file);
      // The code is read off whatever is in memory, so it is available from
      // the moment the room is open rather than only after a price.
      final id = p.project.rooms.first.id;
      expect(p.projectRoomLogName(id), 'BSS 103');
      expect(p.projectRoomLogName(id, file: 'Cost'), 'BSS 103 - Cost');

      p.removeRoomFromProject(id);
      final removed = p.project.history.last;
      expect(removed.itemName, 'BSS 103');
      expect(removed.summary, contains('removed from the job'));
    });
  });

  group('the log itself', () {
    test('it reads newest first and knows who has touched the job', () {
      final project = BuildingProject();
      project.logEdit(
        itemKey: 'part:a',
        field: 'Lead time',
        summary: 'set to 10 days',
        user: 'alice',
        at: DateTime(2026, 3, 1, 9),
      );
      project.logEdit(
        itemKey: 'part:a',
        field: 'Order',
        summary: 'ordered',
        user: 'BOB',
        at: DateTime(2026, 3, 2, 9),
      );
      project.logEdit(
        itemKey: 'part:b',
        field: 'Order',
        summary: 'ordered',
        user: 'bob',
        at: DateTime(2026, 3, 3, 9),
      );

      expect(project.recentHistory.first.itemKey, 'part:b');
      expect(project.historyFor('part:a'), hasLength(2));
      expect(project.historyFor('part:a').first.field, 'Order');
      // One person, however they capitalized their login.
      expect(project.historyUsers, ['alice', 'BOB']);
    });

    test('it stops growing rather than swelling the file forever', () {
      final project = BuildingProject();
      for (var i = 0; i < kMaxProjectHistory + 40; i++) {
        project.logEdit(
          itemKey: 'part:a',
          field: 'Lead time',
          summary: 'set to $i days',
          at: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
      expect(project.history, hasLength(kMaxProjectHistory));
      // The OLDEST go: a job's recent history is the part anybody asks about.
      expect(project.history.first.summary, 'set to 40 days');
      expect(project.recentHistory.first.summary, contains('539'));
    });

    test('a log of changes to nothing is still an empty project', () {
      final project = BuildingProject();
      project.logEdit(itemKey: 'project', field: 'Notes', summary: 'written');
      // Otherwise a job built up and emptied again would refuse to be treated
      // as blank, and the "nothing to save" path would stop working.
      expect(project.isEmpty, isTrue);
    });
  });

  group('it survives a save and a reload', () {
    test('entries round-trip with their time and their user', () async {
      final project = BuildingProject(name: 'Bessey Hall');
      project.logEdit(
        itemKey: 'part:a',
        itemName: 'Projection screen',
        field: 'Lead time',
        summary: 'set to 42 days',
        user: 'dstanley',
        at: DateTime(2026, 3, 4, 14, 32),
      );

      final file = '${dir.path}/h_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      final entry = back.history.single;
      expect(entry.itemName, 'Projection screen');
      expect(entry.user, 'dstanley');
      // The TIME survives, unlike every other date in this file — two edits
      // in one afternoon are two edits.
      expect(entry.at, DateTime(2026, 3, 4, 14, 32));
    });

    test('an over-long log from an older build is trimmed on the way in', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'vendors': <dynamic>[],
        'history': [
          for (var i = 0; i < kMaxProjectHistory + 25; i++)
            {
              'itemKey': 'part:a',
              'field': 'Lead time',
              'summary': 'set to $i days',
              'at': DateTime(2026, 1, 1).add(Duration(minutes: i))
                  .toIso8601String(),
            },
        ],
      });
      expect(back.history, hasLength(kMaxProjectHistory));
    });

    test('an entry with an unreadable time is kept, not dropped', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'vendors': <dynamic>[],
        'history': [
          {'itemKey': 'part:a', 'field': 'Order', 'summary': 'ordered'},
        ],
      });
      // Something happened; losing the record because the stamp is unreadable
      // is worse than showing it at the bottom of the list.
      expect(back.history, hasLength(1));
      expect(back.history.single.at.millisecondsSinceEpoch, 0);
    });

    test('clone carries the log and does not share it', () {
      final project = BuildingProject();
      project.logEdit(itemKey: 'part:a', field: 'Order', summary: 'ordered');
      final copy = project.clone();
      copy.logEdit(itemKey: 'part:b', field: 'Order', summary: 'ordered');

      expect(project.history, hasLength(1));
      expect(copy.history, hasLength(2));
    });
  });

  group('how it reads', () {
    test('the two days people think in are named', () {
      final now = DateTime(2026, 8, 23, 10);
      expect(formatEditDay(now, now: now), 'Today');
      expect(
        formatEditDay(DateTime(2026, 8, 22, 18), now: now),
        'Yesterday',
      );
      expect(formatEditDay(DateTime(2026, 3, 4), now: now), '4 Mar 2026');
    });

    test('the time is 24 hour and zero padded', () {
      expect(formatEditTime(DateTime(2026, 3, 4, 9, 5)), '09:05');
      expect(formatEditTime(DateTime(2026, 3, 4, 14, 32)), '14:32');
    });
  });

  group('typing is one decision, not forty', () {
    test('a note typed character by character is ONE entry', () {
      final p = job();
      // What a LiveTextField does: writes through on every keystroke.
      for (final text in ['A', 'As', 'Asb', 'Asbe', 'Asbestos']) {
        p.setProjectField(notes: text);
      }
      final entries = p.project.historyFor('project');
      expect(entries, hasLength(1));
      expect(entries.single.field, 'Notes');
    });

    test('a room note behaves the same way', () {
      final p = job();
      final file = '${dir.path}/bss101_config.json';
      File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
      p.addRoomToProject(file);
      final roomId = p.project.rooms.single.id;

      for (final text in ['No', 'No d', 'No drilling']) {
        p.updateProjectRoom(roomId, notes: text);
      }
      // One "added to the job" plus one "Notes written" — not one per key.
      final entries = p.project.historyFor('room:$roomId');
      expect(entries.where((e) => e.field == 'Notes'), hasLength(1));
    });

    test('coming back later is a separate decision', () {
      final project = BuildingProject();
      project.logEdit(
        itemKey: 'project',
        field: 'Notes',
        summary: 'written',
        user: 'alice',
        at: DateTime(2026, 3, 4, 9, 0),
        coalesce: true,
      );
      project.logEdit(
        itemKey: 'project',
        field: 'Notes',
        summary: 'written',
        user: 'alice',
        at: DateTime(2026, 3, 4, 9, 1),
        coalesce: true,
      );
      expect(project.history, hasLength(1));

      // After lunch, rewriting the note is the separate decision it is.
      project.logEdit(
        itemKey: 'project',
        field: 'Notes',
        summary: 'written',
        user: 'alice',
        at: DateTime(2026, 3, 4, 13, 0),
        coalesce: true,
      );
      expect(project.history, hasLength(2));
    });

    test('a different person editing never merges into somebody else', () {
      final project = BuildingProject();
      project.logEdit(
        itemKey: 'project',
        field: 'Notes',
        summary: 'written',
        user: 'alice',
        at: DateTime(2026, 3, 4, 9, 0),
        coalesce: true,
      );
      project.logEdit(
        itemKey: 'project',
        field: 'Notes',
        summary: 'written',
        user: 'bob',
        at: DateTime(2026, 3, 4, 9, 1),
        coalesce: true,
      );
      // Attributing Bob's edit to Alice would be the one thing a history
      // must never do.
      expect(project.history, hasLength(2));
      expect(project.history.last.user, 'bob');
    });

    test('discrete changes never coalesce, however fast', () {
      final p = job();
      p.addProjectTodo('a note');
      final id = p.project.todos.single.id;
      p.setProjectTodoState(id, ProjectTodoState.done);
      p.setProjectTodoState(id, ProjectTodoState.open);

      // Done then undone in the same minute is still two decisions.
      expect(p.project.historyFor('todo:$id'), hasLength(3));
    });
  });
}
