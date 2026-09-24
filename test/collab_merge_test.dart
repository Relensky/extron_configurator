import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/collab/collab_controller.dart';
import 'package:extron_configurator/collab/json_merge.dart';
import 'package:extron_configurator/collab/presence.dart';

/// ============================================================================
///  TWO PEOPLE, ONE FILE
/// ============================================================================
///  The three-way merge behind Save and the banner's Merge button, the
///  presence notes that put a colleague's Windows name on the banner, and the
///  watcher that notices their save.
/// ============================================================================
void main() {
  group('mergeJson3', () {
    test('changes to different keys are both kept', () {
      final r = mergeJson3(
        {'a': 1, 'b': 1},
        {'a': 2, 'b': 1},
        {'a': 1, 'b': 3},
      );
      expect(r.clean, isTrue);
      expect(r.merged, {'a': 2, 'b': 3});
      expect(r.takenFromTheirs, 1);
    });

    test('the same key changed two ways is a conflict, mine by default', () {
      final r = mergeJson3({'price': 1}, {'price': 2}, {'price': 3});
      expect(r.conflicts, hasLength(1));
      expect(r.conflicts.single.path, 'price');
      expect(r.merged, {'price': 2});
    });

    test('a resolver can take theirs', () {
      final r = mergeJson3(
        {'price': 1},
        {'price': 2},
        {'price': 3},
        resolve: (_) => MergeSide.theirs,
      );
      expect(r.merged, {'price': 3});
    });

    test('rows added by both people to one list are all kept', () {
      final base = {
        'rooms': [
          {'id': 'r1', 'name': 'A'},
        ],
      };
      final mine = {
        'rooms': [
          {'id': 'r1', 'name': 'A'},
          {'id': 'r2', 'name': 'Mine'},
        ],
      };
      final theirs = {
        'rooms': [
          {'id': 'r1', 'name': 'A renamed'},
          {'id': 'r3', 'name': 'Theirs'},
        ],
      };
      final r = mergeJson3(base, mine, theirs);
      expect(r.clean, isTrue);
      final rooms = (r.merged as Map)['rooms'] as List;
      expect(rooms.map((e) => e['id']), ['r1', 'r3', 'r2']);
      expect(rooms.first['name'], 'A renamed');
    });

    test('a row one side deleted and the other left alone stays deleted', () {
      final r = mergeJson3(
        {
          'l': [
            {'id': 'a'},
            {'id': 'b'},
          ],
        },
        {
          'l': [
            {'id': 'a'},
          ],
        },
        {
          'l': [
            {'id': 'a'},
            {'id': 'b'},
          ],
        },
      );
      expect(((r.merged as Map)['l'] as List).map((e) => e['id']), ['a']);
      expect(r.clean, isTrue);
    });

    test('a row deleted by me but edited by them is a conflict', () {
      final r = mergeJson3(
        {
          'l': [
            {'id': 'a', 'v': 1},
          ],
        },
        {'l': <Object>[]},
        {
          'l': [
            {'id': 'a', 'v': 2},
          ],
        },
      );
      expect(r.conflicts, hasLength(1));
      expect(r.conflicts.single.path, 'l[id=a]');
    });

    test('an append-only log keeps both sides entries', () {
      final r = mergeJson3(
        {
          'history': [
            {'what': 'x'},
          ],
        },
        {
          'history': [
            {'what': 'x'},
            {'what': 'mine'},
          ],
        },
        {
          'history': [
            {'what': 'x'},
            {'what': 'theirs'},
          ],
        },
      );
      expect(r.clean, isTrue);
      expect(
        ((r.merged as Map)['history'] as List).map((e) => e['what']),
        ['x', 'mine', 'theirs'],
      );
    });

    test('a list of plain values merges as a set', () {
      final r = mergeJson3(
        {
          'tags': ['a', 'b'],
        },
        {
          'tags': ['a', 'b', 'c'],
        },
        {
          'tags': ['b', 'd'],
        },
      );
      expect(r.clean, isTrue);
      expect((r.merged as Map)['tags'], ['b', 'c', 'd']);
    });

    test('id counters take the higher value instead of conflicting', () {
      final r = mergeJson3(
        {'roomCounter': 3},
        {'roomCounter': 5},
        {'roomCounter': 4},
      );
      expect(r.clean, isTrue);
      expect(r.merged, {'roomCounter': 5});
    });
  });

  group('presence', () {
    late Directory dir;
    late String doc;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('collab_presence');
      doc = path.join(dir.path, 'room.json');
      await File(doc).writeAsString('{}');
    });
    tearDown(() => dir.delete(recursive: true));

    test('each person sees the other, never themselves', () async {
      const jane = CollabIdentity(user: 'jsmith', machine: 'PC-1');
      const bob = CollabIdentity(user: 'bjones', machine: 'PC-2');
      final board = PresenceBoard(doc);
      final now = DateTime.now();
      await board.announce(EditorPresence(
        user: jane.user,
        machine: jane.machine,
        since: now,
        heartbeat: now,
      ));
      await board.announce(EditorPresence(
        user: bob.user,
        machine: bob.machine,
        since: now,
        heartbeat: now,
        unsaved: true,
      ));
      final seenByJane = await board.others(jane, now: now);
      expect(seenByJane.map((p) => p.user), ['bjones']);
      expect(seenByJane.single.unsaved, isTrue);
      expect((await board.others(bob, now: now)).map((p) => p.user), ['jsmith']);
    });

    test('a note that stopped being refreshed is not shown', () async {
      const me = CollabIdentity(user: 'me', machine: 'M');
      final board = PresenceBoard(doc);
      final old = DateTime.now().subtract(const Duration(minutes: 5));
      await board.announce(EditorPresence(
        user: 'ghost',
        machine: 'X',
        since: old,
        heartbeat: old,
      ));
      expect(await board.others(me), isEmpty);
    });

    test('withdrawing tidies the folder away', () async {
      const me = CollabIdentity(user: 'me', machine: 'M');
      final board = PresenceBoard(doc);
      final now = DateTime.now();
      await board.announce(EditorPresence(
        user: me.user,
        machine: me.machine,
        since: now,
        heartbeat: now,
      ));
      expect(Directory(board.folder).existsSync(), isTrue);
      await board.withdraw(me);
      expect(
        Directory(path.join(dir.path, kPresenceFolderName)).existsSync(),
        isFalse,
      );
    });
  });

  group('CollabController', () {
    late Directory dir;
    late String file;
    late _MapDoc doc;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('collab_controller');
      file = path.join(dir.path, 'project.json');
      await File(file).writeAsString(jsonEncode({'name': 'Job', 'n': 1}));
      doc = _MapDoc(file);
    });
    tearDown(() => dir.delete(recursive: true));

    CollabController controllerFor(String user) => CollabController(
          identity: CollabIdentity(user: user, machine: 'PC'),
          enabled: true,
        )..register(doc);

    test('shows the other editor, and notices their save', () async {
      final me = controllerFor('me');
      await me.tick();
      expect(me.othersOn(CollabDocKind.project), isEmpty);

      // A colleague opens the same file...
      final them = CollabController(
        identity: const CollabIdentity(user: 'jsmith', machine: 'PC-9'),
        enabled: true,
      )..register(_MapDoc(file));
      await them.tick();
      await me.tick();
      expect(me.othersOn(CollabDocKind.project).map((p) => p.user),
          ['jsmith']);

      // ...and saves a change.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await File(file).writeAsString(jsonEncode({'name': 'Job', 'n': 2}));
      await me.tick();
      expect(me.incomingOn(CollabDocKind.project), isNotNull);

      // Nothing unsaved here, so merging simply takes their file.
      final outcome = await me.mergeIncoming(CollabDocKind.project);
      expect(outcome.merged, isTrue);
      expect(doc.memory['n'], 2);
      expect(me.incomingOn(CollabDocKind.project), isNull);
      me.dispose();
      them.dispose();
    });

    test('unsaved work of mine is merged with their save, not replaced',
        () async {
      final me = controllerFor('me');
      await me.tick();
      doc.memory['name'] = 'Job - renamed by me';
      doc.dirty = true;

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await File(file).writeAsString(jsonEncode({'name': 'Job', 'n': 7}));

      final preview = me.previewMerge(CollabDocKind.project);
      expect(preview, isNotNull);
      expect(preview!.clean, isTrue);

      await me.mergeIncoming(CollabDocKind.project);
      expect(doc.memory, {'name': 'Job - renamed by me', 'n': 7});
      me.dispose();
    });

    test('our own save is not reported as somebody else\'s', () async {
      final me = controllerFor('me');
      await me.tick();
      doc.memory['n'] = 3;
      await me.hold(() async {
        await File(file).writeAsString(jsonEncode(doc.memory));
      });
      me.noteInSync(CollabDocKind.project, saved: true);
      await me.tick();
      expect(me.incomingOn(CollabDocKind.project), isNull);
      me.dispose();
    });
  });
}

/// A document that is just a map in memory and a JSON file on disk.
class _MapDoc extends CollabDocument {
  final String file;
  Map<String, dynamic> memory;
  bool dirty = false;

  _MapDoc(this.file)
      : memory = Map<String, dynamic>.from(
          jsonDecode(File(file).readAsStringSync()) as Map,
        );

  @override
  CollabDocKind get kind => CollabDocKind.project;

  @override
  String get filePath => file;

  @override
  bool get isDirty => dirty;

  @override
  Object? readDisk() => jsonDecode(File(file).readAsStringSync());

  @override
  Object? current() => memory;

  @override
  void apply(Object? doc, {required bool clean}) {
    memory = Map<String, dynamic>.from(doc as Map);
    dirty = !clean;
  }
}
