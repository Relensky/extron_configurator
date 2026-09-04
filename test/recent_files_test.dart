import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/recent_files.dart';

/// ============================================================================
///  THE FILES THIS APP HAS OPENED OR WRITTEN
/// ============================================================================
///  A room, a job and a campus are all .json in the same folders, so the work
///  of getting back to one is not opening it - it is finding it again. The
///  list is what removes that, and what these hold is the three promises that
///  make it worth trusting:
///
///    - TEN OF EACH, SEPARATELY. The kinds do not share a budget, so a week of
///      room edits cannot push every project off the list.
///    - ONE LINE PER DOCUMENT. Two spellings of one path are one file, or the
///      list spends its ten lines on five documents.
///    - IT IS A POINTER. Nothing about the document is cached, and a file that
///      is not there any more is reported rather than dropped.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_recent'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A real file on disk, so [RecentFile.stillThere] has something to answer.
  String file(String stem) {
    final f = path.join(dir.path, '$stem.json');
    File(f).writeAsStringSync('{}');
    return f;
  }

  group('the list itself', () {
    test('the most recently opened is the top line', () {
      final recents = RecentFiles();
      recents.remember(RecentKind.room, file('a'), name: 'Room A');
      recents.remember(RecentKind.room, file('b'), name: 'Room B');

      expect(recents[RecentKind.room].map((e) => e.label), ['Room B', 'Room A']);
    });

    test('opening one again moves it up rather than adding a line', () {
      final recents = RecentFiles();
      final a = file('a');
      recents.remember(RecentKind.room, a, name: 'Room A');
      recents.remember(RecentKind.room, file('b'), name: 'Room B');
      recents.remember(RecentKind.room, a, name: 'Room A');

      expect(recents[RecentKind.room], hasLength(2));
      expect(recents[RecentKind.room].first.label, 'Room A');
    });

    test('two spellings of one path are one document', () {
      // The same file, written the way Windows and the way a relative walk
      // would each hand it over. A list that took both would spend two of its
      // ten lines saying the same thing.
      final recents = RecentFiles();
      final a = file('bss103');
      recents.remember(RecentKind.room, a);
      recents.remember(
        RecentKind.room,
        path.join(dir.path, '.', 'bss103.json'),
      );

      expect(recents[RecentKind.room], hasLength(1));
    });

    test('it keeps ten of a kind and drops the eleventh from the bottom', () {
      final recents = RecentFiles();
      for (int i = 0; i < kRecentFilesPerKind + 4; i++) {
        recents.remember(RecentKind.room, file('room$i'), name: 'Room $i');
      }

      final list = recents[RecentKind.room];
      expect(list, hasLength(kRecentFilesPerKind));
      expect(list.first.label, 'Room 13');
      // The four oldest are the four that went, not four from anywhere else.
      expect(list.last.label, 'Room 4');
    });

    test('the three kinds do not share the ten', () {
      // A WEEK OF ROOM EDITS MUST NOT COST SOMEBODY THEIR JOBS. One list of
      // ten would do exactly that, which is the whole reason for three.
      final recents = RecentFiles();
      for (int i = 0; i < 20; i++) {
        recents.remember(RecentKind.room, file('room$i'));
      }
      recents.remember(RecentKind.project, file('bessey_project'),
          name: 'Bessey Hall');
      recents.remember(RecentKind.campus, file('chico_campus'),
          name: 'Chico campus');
      for (int i = 20; i < 40; i++) {
        recents.remember(RecentKind.room, file('room$i'));
      }

      expect(recents[RecentKind.room], hasLength(kRecentFilesPerKind));
      expect(recents[RecentKind.project].single.label, 'Bessey Hall');
      expect(recents[RecentKind.campus].single.label, 'Chico campus');
    });

    test('a blank path is not a document', () {
      final recents = RecentFiles();
      expect(recents.remember(RecentKind.project, '   '), isFalse);
      expect(recents.isEmpty, isTrue);
    });

    test('re-opening the top line again changes nothing worth saving', () {
      // The return value is what decides whether app_config.json is rewritten
      // and the menu repainted. Switching between the same two rooms all
      // afternoon should not be a write per switch.
      final recents = RecentFiles();
      final a = file('a');
      expect(recents.remember(RecentKind.room, a, name: 'Room A'), isTrue);
      expect(recents.remember(RecentKind.room, a, name: 'Room A'), isFalse);
      // A rename is a change, though - the list shows the name.
      expect(recents.remember(RecentKind.room, a, name: 'Room A2'), isTrue);
    });

    test('a later open with no name keeps the name it had', () {
      final recents = RecentFiles();
      final a = file('a');
      recents.remember(RecentKind.room, a, name: 'Behavioral Science 103');
      recents.remember(RecentKind.room, a);

      expect(recents[RecentKind.room].single.label, 'Behavioral Science 103');
    });

    test('forget takes one line, clear takes a list', () {
      final recents = RecentFiles();
      final a = file('a');
      recents.remember(RecentKind.room, a);
      recents.remember(RecentKind.project, file('p'));

      expect(recents.forget(RecentKind.room, a), isTrue);
      expect(recents.forget(RecentKind.room, a), isFalse);
      expect(recents[RecentKind.room], isEmpty);
      // The projects are untouched: clearing one kind is not clearing three.
      expect(recents[RecentKind.project], hasLength(1));

      expect(recents.clear(), isTrue);
      expect(recents.isEmpty, isTrue);
      expect(recents.clear(), isFalse);
    });
  });

  group('what a line says', () {
    test('a document with no name of its own falls back to its file name', () {
      final entry = RecentFile(
        file: path.join(dir.path, 'bss103.json'),
        name: '',
        touchedAt: DateTime(2026, 9, 4),
      );
      expect(entry.label, 'bss103');
      expect(entry.folder, dir.path);
    });

    test('a file that is not there any more says so rather than vanishing', () {
      // A SLOW SHARE MUST NOT EMPTY A HISTORY. The check is made when the list
      // is drawn, never when it is written, so a folder that comes back is a
      // list that comes back with it.
      final recents = RecentFiles();
      final a = file('a');
      recents.remember(RecentKind.room, a, name: 'Room A');
      expect(recents[RecentKind.room].single.stillThere, isTrue);

      File(a).deleteSync();
      expect(recents[RecentKind.room], hasLength(1));
      expect(recents[RecentKind.room].single.stillThere, isFalse);
    });
  });

  group('across a restart', () {
    test('it round-trips through app_config.json', () {
      final recents = RecentFiles();
      recents.remember(RecentKind.room, file('a'), name: 'Room A');
      recents.remember(RecentKind.project, file('p'), name: 'Bessey Hall');
      recents.remember(RecentKind.campus, file('c'), name: 'Chico campus');

      final back = RecentFiles.fromJson(recents.toJson());
      expect(back[RecentKind.room].single.label, 'Room A');
      expect(back[RecentKind.project].single.label, 'Bessey Hall');
      expect(back[RecentKind.campus].single.label, 'Chico campus');
      expect(
        back[RecentKind.room].single.touchedAt.millisecondsSinceEpoch,
        recents[RecentKind.room].single.touchedAt.millisecondsSinceEpoch,
      );
    });

    test('nothing it holds is a fact about the document', () {
      // A POINTER, NOT A COPY. The moment this cached a room count or a total
      // it would be a second answer that could disagree with the file.
      final recents = RecentFiles();
      recents.remember(RecentKind.project, file('p'), name: 'Bessey Hall');
      final row = (recents.toJson()['project'] as List).single as Map;
      expect(row.keys.toSet(), {'file', 'name', 'touchedAt'});
    });

    test('a hand-edited file that is nonsense costs the list, not the app', () {
      // app_config.json is documented as hand-editable, so every shape of
      // rubbish has to come back as an empty list rather than an exception.
      expect(RecentFiles.fromJson(null).isEmpty, isTrue);
      expect(RecentFiles.fromJson('recent').isEmpty, isTrue);
      expect(RecentFiles.fromJson({'room': 'not a list'}).isEmpty, isTrue);
      expect(
        RecentFiles.fromJson({
          'room': [
            'not a row',
            {'name': 'no file'},
            {'file': '  '},
            {'file': 'C:/jobs/a.json', 'name': 'Room A', 'touchedAt': 'soon'},
          ],
        })[RecentKind.room],
        hasLength(1),
      );
    });

    test('a file listed twice by hand still gets one line', () {
      final back = RecentFiles.fromJson({
        'project': [
          {'file': 'C:/jobs/bessey.json', 'name': 'Bessey Hall'},
          {'file': 'C:/JOBS/bessey.json', 'name': 'Bessey Hall again'},
        ],
      });
      expect(back[RecentKind.project], hasLength(Platform.isWindows ? 1 : 2));
    });

    test('a file that has grown past ten by hand is trimmed on the way in', () {
      final back = RecentFiles.fromJson({
        'room': [
          for (int i = 0; i < 40; i++) {'file': 'C:/jobs/room$i.json'},
        ],
      });
      expect(back[RecentKind.room], hasLength(kRecentFilesPerKind));
      expect(back[RecentKind.room].first.file, 'C:/jobs/room0.json');
    });
  });
}
