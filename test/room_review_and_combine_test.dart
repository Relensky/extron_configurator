import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/collab/collab_controller.dart';
import 'package:extron_configurator/collab/collab_widgets.dart';
import 'package:extron_configurator/collab/combine_history.dart';
import 'package:extron_configurator/collab/json_merge.dart';
import 'package:extron_configurator/room_review.dart';
import 'package:extron_configurator/team/team_claims.dart';
import 'package:extron_configurator/team/team_presence.dart';

/// Room locks while someone else is working on it, review marks, per-change
/// approval when combining, and the combine history with its backup.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('room_review_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('approving changes one by one', () {
    test('a declined change keeps mine; the rest come in', () {
      final base = {'a': 1, 'b': 1, 'c': 1};
      final mine = {'a': 1, 'b': 1, 'c': 1};
      final theirs = {'a': 2, 'b': 2, 'c': 1};
      final preview = mergeJson3(base, mine, theirs);
      expect(preview.changes.map((c) => c.key), ['a', 'b']);

      final result = mergeJson3(base, mine, theirs, declined: {'b'});
      expect(result.merged, {'a': 2, 'b': 1, 'c': 1});
      expect(result.changes.map((c) => c.key), ['a']);
    });

    test('a row they added can be left out', () {
      final base = {
        'rows': [
          {'id': 'r1', 'name': 'one'},
        ],
      };
      final theirs = {
        'rows': [
          {'id': 'r1', 'name': 'one'},
          {'id': 'r2', 'name': 'two'},
        ],
      };
      final preview = mergeJson3(base, base, theirs);
      expect(preview.changes.single.key, 'rows[id=r2]');
      final result =
          mergeJson3(base, base, theirs, declined: {'rows[id=r2]'});
      expect((result.merged as Map)['rows'], hasLength(1));
    });

    test('appended log rows are approved one at a time', () {
      final base = {
        'log': ['a'],
      };
      final theirs = {
        'log': ['a', 'b', 'c', 'b'],
      };
      final preview = mergeJson3(base, base, theirs);
      expect(preview.changes.map((c) => c.key), ['log#1', 'log#2', 'log#3']);
      final result = mergeJson3(base, base, theirs, declined: {'log#2'});
      expect((result.merged as Map)['log'], ['a', 'b', 'b']);
    });

    test('the controller merges with declined changes left out', () async {
      final file = path.join(dir.path, 'bss103_config.json');
      File(file).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103', 'notes': 'a'},
      }));
      final p = AppStateProvider(autoLoadSettings: false);
      p.collab.enabled = true;
      await p.openConfigAtPath(file);
      await p.collab.tick();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final disk = jsonDecode(File(file).readAsStringSync()) as Map;
      (disk['SYSTEM_SETUP'] as Map)['notes'] = 'theirs';
      (disk['SYSTEM_SETUP'] as Map)['extra'] = 'added';
      File(file).writeAsStringSync(jsonEncode(disk));
      await p.collab.tick();

      // Nothing unsaved here, but a declined change still has to stay out.
      final keys = p.collab
          .previewMerge(CollabDocKind.room)!
          .changes
          .map((c) => c.key)
          .toList();
      final notesKey = keys.firstWhere((k) => k.endsWith('SYSTEM_SETUP.notes'));
      expect(keys.where((k) => k.endsWith('SYSTEM_SETUP.extra')), hasLength(1));
      await p.collab.mergeIncoming(
        CollabDocKind.room,
        declined: {notesKey},
      );
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup['notes'], 'a');
      expect(setup['extra'], 'added');
      p.dispose();
    });
  });

  testWidgets('the review dialog returns the changes left unticked',
      (tester) async {
    final preview = mergeJson3(
      {'a': 1, 'b': 1},
      {'a': 1, 'b': 1},
      {'a': 2, 'b': 2},
    );
    Set<String>? declined;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => declined = await showMergeReviewDialog(
            context,
            kind: CollabDocKind.room,
            who: 'jsmith',
            preview: preview,
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text('2 of 2 approved'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('collab_review_item_b')));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 approved'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('collab_review_confirm')));
    await tester.pumpAndSettle();
    expect(declined, {'b'});
  });

  group('combine history', () {
    CombineHistoryEntry entry(String id, DateTime at,
            {String room = '', String project = '', String campus = ''}) =>
        CombineHistoryEntry(
          id: id,
          at: at,
          user: 'dstanley',
          from: 'jsmith',
          room: room,
          project: project,
          campus: campus,
          items: const [
            CombineHistoryItem(place: 'Notes', path: 'notes', after: 'x'),
            CombineHistoryItem(
                place: 'Room', path: 'room', after: '104', approved: false),
          ],
        );

    test('each write keeps a backup that matches, and a timestamped copy',
        () async {
      final store = CombineHistoryStore(dir.path);
      expect(await store.append(entry('1', DateTime(2026, 10, 9, 9))), '');
      expect(await store.append(entry('2', DateTime(2026, 10, 9, 10))), '');

      final check = await store.check();
      expect(check.matches, isTrue);
      expect(check.mainCount, 2);
      expect(File(store.backupPath).readAsStringSync(),
          File(store.mainPath).readAsStringSync());
      expect(
        Directory(store.snapshotFolder)
            .listSync()
            .where((f) => path.basename(f.path).startsWith('combine_history_')),
        isNotEmpty,
      );
      final loaded = await store.load();
      expect(loaded.map((e) => e.id), ['1', '2']);
      expect(loaded.first.approvedCount, 1);
      expect(loaded.first.declinedCount, 1);
    });

    test('a log and backup that disagree are combined', () async {
      final store = CombineHistoryStore(dir.path);
      await store.append(entry('1', DateTime(2026, 10, 1)));
      // Someone else's write landed only in the backup.
      final backup = jsonDecode(File(store.backupPath).readAsStringSync())
          as Map<String, dynamic>;
      (backup['entries'] as List)
          .add(entry('2', DateTime(2026, 10, 2)).toJson());
      File(store.backupPath).writeAsStringSync(jsonEncode(backup));

      final before = await store.check();
      expect(before.matches, isFalse);
      expect(before.onlyInBackup, ['2']);
      expect((await store.load()).map((e) => e.id), ['1', '2']);

      expect(await store.repair(), '');
      final after = await store.check();
      expect(after.matches, isTrue);
      expect(after.mainCount, 2);
    });

    test('grouped per room, per project and per campus, newest first', () {
      final entries = [
        entry('1', DateTime(2026, 10, 1),
            room: 'BSS 101', project: 'Bessey', campus: 'Chico'),
        entry('2', DateTime(2026, 10, 3),
            room: 'BSS 103', project: 'Bessey', campus: 'Chico'),
        entry('3', DateTime(2026, 10, 2),
            room: 'ARTS 111', project: 'Arts', campus: 'Chico'),
        entry('4', DateTime(2026, 10, 4),
            room: 'BSS 101', project: 'Bessey', campus: 'Chico'),
      ];
      final rooms = groupCombineHistory(entries, CombineHistoryScope.room);
      expect(rooms.keys, ['BSS 101', 'BSS 103', 'ARTS 111']);
      expect(rooms['BSS 101']!.map((e) => e.id), ['4', '1']);
      final projects =
          groupCombineHistory(entries, CombineHistoryScope.project);
      expect(projects.keys, ['Bessey', 'Arts']);
      expect(projects['Bessey'], hasLength(3));
      final campus = groupCombineHistory(entries, CombineHistoryScope.campus);
      expect(campus['Chico'], hasLength(4));
    });

    test('a combine is recorded with its room and a backup of the file',
        () async {
      final file = path.join(dir.path, 'bss103_config.json');
      File(file).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
      }));
      final p = AppStateProvider(autoLoadSettings: false)
        ..combineHistoryFolderOverride = path.join(dir.path, 'history');
      await p.openConfigAtPath(file);

      final backup = await p.backupBeforeCombine(CollabDocKind.room);
      expect(File(backup).existsSync(), isTrue);
      expect(await p.recordCombine(
        kind: CollabDocKind.room,
        from: 'jsmith',
        backup: backup,
        items: const [
          CombineHistoryItem(place: 'Notes', path: 'notes', after: 'x'),
        ],
      ), '');
      final logged = await p.combineHistory!.load();
      expect(logged.single.room, p.teamRoomId);
      expect(logged.single.backup, backup);
      expect(logged.single.items.single.place, 'Notes');
      expect(p.roomHistory.last.field, 'Combined');
      p.dispose();
    });
  });

  group('room status', () {
    TeamClaims claimsAs(String user, String sub) => TeamClaims(
          identity: TeamIdentity(user: user, machine: 'pc'),
          watch: false,
          subfolder: sub,
        );

    test('ready for review and review complete replace each other',
        () async {
      final reviews = claimsAs('dstanley', 'room_reviews');
      final claims = claimsAs('dstanley', 'claims');
      await reviews.attach(dir.path);
      await claims.attach(dir.path);
      expect(Directory(path.join(dir.path, 'room_reviews')).existsSync(),
          isTrue);

      expect(await setRoomReady(reviews, 'BSS 103', on: true), '');
      var s = roomTeamStatus(claims, reviews, 'BSS 103');
      expect(s.ready?.who, 'dstanley');
      expect(s.reviewed, isNull);

      expect(await setRoomReviewed(reviews, 'BSS 103', on: true), '');
      s = roomTeamStatus(claims, reviews, 'BSS 103');
      expect(s.reviewed, isNotNull);
      expect(s.ready, isNull);

      expect(await setRoomReady(reviews, 'BSS 103', on: true), '');
      s = roomTeamStatus(claims, reviews, 'BSS 103');
      expect(s.ready, isNotNull);
      expect(s.reviewed, isNull);

      // Another copy reading the folder sees the same.
      final other = claimsAs('jsmith', 'room_reviews');
      await other.attach(dir.path);
      expect(other.on(kRoomReadyKind, 'BSS 103'), hasLength(1));
      // "Working on" is untouched by review marks.
      expect(claims.on('room', 'BSS 103'), isEmpty);
      reviews.dispose();
      claims.dispose();
      other.dispose();
    });

    test('a room someone else is working on cannot be saved over', () async {
      final file = path.join(dir.path, 'bss103_config.json');
      File(file).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
      }));
      final p = AppStateProvider(autoLoadSettings: false);
      await p.openConfigAtPath(file);
      await p.teamClaims.attach(dir.path);
      final room = p.teamRoomId;
      expect(room, isNotEmpty);

      // Someone else claims it.
      final jsmith = claimsAs('jsmith', 'claims');
      await jsmith.attach(dir.path);
      await jsmith.set(
          kind: 'room', id: room, label: room, who: 'jsmith', on: true);
      await p.teamClaims.refresh();

      expect(p.roomLockHolders.single.who, 'jsmith');
      final result = await p.saveRoomInPlace();
      expect(result, startsWith('Error'));
      expect(result, contains('locked'));

      // Taken off: the save goes through.
      await p.teamClaims.set(
          kind: 'room', id: room, label: room, who: 'jsmith', on: false);
      expect(p.roomLockHolders, isEmpty);
      expect(await p.saveRoomInPlace(), isNot(startsWith('Error')));

      // Claimed again, but this person is on it too: not locked for them.
      await jsmith.set(
          kind: 'room', id: room, label: room, who: 'jsmith', on: true);
      await p.teamClaims.refresh();
      expect(p.roomLockHolders, isNotEmpty);
      await p.teamClaims.set(
          kind: 'room',
          id: room,
          label: room,
          who: p.teamClaims.me.user,
          on: true);
      expect(p.roomLockHolders, isEmpty);

      jsmith.dispose();
      p.teamClaims.dispose();
      p.dispose();
    });
  });
}
