import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/undo_history.dart';

/// UNDO FOR THE JOB, WHICH HAD NONE.
///
/// The room's drawings have had it for years and the job had nothing: a vendor
/// split retyped across forty parts, a delivery removed by the wrong hand, a
/// price tier changed to see what it looked like — all of them one-way doors.
///
/// It records the DOCUMENT rather than each edit, because there are seventy
/// methods on the provider that change a job and the one that got forgotten
/// would be an edit Undo silently stepped over. So the things worth guarding
/// are the ones that recording states can get wrong: a step that puts back the
/// wrong edit, a log that gets rewritten along with the job, a redo branch that
/// survives being typed over, and one job's history reaching into another's.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_undo_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A job with one room on it, and a clean history.
  AppStateProvider job({String name = 'Bessey Hall'}) {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: name);
    return p;
  }

  /// Ends the current undo step, the way closing a dialog or changing tab
  /// does. Without it a run of edits in one go is one step — which is the
  /// intended behaviour, and not what most of these tests are about.
  void step(AppStateProvider p) => p.recordUndoPoint();

  group('a step goes back, and forward again', () {
    test('the last edit is undone and nothing else with it', () {
      final p = job();
      final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);
      p.setProjectField(stakeholder: 'Facilities');
      step(p);
      p.updateProjectDelivery(row.copyWith(qty: 12));

      expect(p.undoProject(), isNotEmpty);

      expect(p.project.deliveries.single.qty, 18, reason: 'the qty went back');
      expect(p.project.deliveries, hasLength(1),
          reason: 'the delivery itself did not');
      expect(p.project.stakeholder, 'Facilities',
          reason: 'and neither did the edit before it');
    });

    test('redo puts it back', () {
      final p = job();
      final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);
      p.updateProjectDelivery(row.copyWith(qty: 12));

      p.undoProject();
      expect(p.project.deliveries.single.qty, 18);

      expect(p.redoProject(), isNotEmpty);
      expect(p.project.deliveries.single.qty, 12);
    });

    test('a removal comes back whole, notes and all', () {
      final p = job();
      final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      p.addProjectDeliveryNote(row.id, 'Left in the corridor');
      step(p);

      p.removeProjectDelivery(row.id);
      expect(p.project.deliveries, isEmpty);

      p.undoProject();
      expect(p.project.deliveries.single.itemName, 'Wall plate');
      // THE WHOLE RECORD, not a re-added blank one. A delivery that came back
      // without the note somebody typed on it is a delivery that came back
      // wrong, and quietly.
      expect(p.project.deliveries.single.notes.single.text,
          'Left in the corridor');
    });

    test('nothing to undo is said rather than guessed at', () {
      final p = job();
      expect(p.undoProject(), '');
      expect(p.redoProject(), '');
      expect(p.canRedoProject, isFalse);
    });
  });

  group('the step is named after the edit', () {
    test('the label comes off the job\'s own log', () {
      final p = job();
      final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);
      // The summary is what the edit box passes — see
      // project_deliveries_view.dart. It is what the log line is made of, and
      // so what the Undo button ends up called.
      p.updateProjectDelivery(row.copyWith(qty: 12), summary: 'edited - qty');
      step(p);

      // The same words the History pane uses about the same change, because
      // they come from the same line. A button that invented its own name for
      // an edit would be a second vocabulary to learn.
      expect(p.projectUndoLabel, isNotEmpty);
      expect(p.projectUndoLabel.toLowerCase(), contains('wall plate'));

      final undone = p.undoProject();
      expect(p.projectRedoLabel, undone);
    });
  });

  group('the log is not the document', () {
    test('an undo keeps the record of what it undid, and adds to it', () {
      final p = job();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);
      final before = p.project.history.length;

      p.undoProject();

      // THE ONE THING THIS APP MUST NOT DO QUIETLY. Rolling the log back with
      // the job would make Undo the only feature that edits its own audit
      // trail — and the delivery would vanish with no line anywhere saying it
      // ever existed.
      expect(p.project.history.length, greaterThan(before));
      expect(
        p.project.history.where((h) => h.field == 'Undo'),
        isNotEmpty,
      );
    });

    test('a log line on its own is not an undoable step', () {
      final p = job();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);
      final depth = p.projectUndoDepth;

      // Publishing logs a line and changes nothing else about the job's
      // shape. It must not consume a step: sixty entries of "published" would
      // push the edit somebody wants back off the bottom of the history.
      p.recordUndoPoint();
      expect(p.projectUndoDepth, depth);
    });
  });

  group('the future ends when you type over it', () {
    test('an edit after an undo drops the redo', () {
      final p = job();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);
      p.setProjectField(stakeholder: 'Facilities');
      step(p);

      p.undoProject();
      expect(p.canRedoProject, isTrue);

      p.setProjectField(stakeholder: 'Estates');
      step(p);

      expect(p.canRedoProject, isFalse,
          reason: 'the branch that was undone has been typed over');
    });
  });

  group('one job\'s history does not reach into another', () {
    test('opening a job starts again', () async {
      final p = job();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);
      expect(p.projectUndoDepth, greaterThan(0));

      final file = path.join(dir.path, 'other.json');
      final other = job(name: 'Ayres Hall');
      await other.saveProject(to: file);

      expect(await p.openProject(file), '');

      // Undo on a job just opened must not be able to paste the last job into
      // it. There is nothing behind the file as it was read.
      expect(p.canUndoProject, isFalse);
      expect(p.projectUndoDepth, 0);
      expect(p.undoProject(), '');
    });

    test('closing a job takes its history with it', () {
      final p = job();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      step(p);

      p.closeProject();

      expect(p.canUndoProject, isFalse);
      expect(p.undoProject(), '');
      expect(p.project.deliveries, isEmpty);
    });
  });

  group('how far back it goes', () {
    test('sixty steps, and the same sixty everywhere', () {
      // The number the AV tabs have always used, now the number every history
      // in the app uses. "How far back does Undo go" has to have one answer.
      expect(kUndoDepth, 60);

      final p = job();
      for (var i = 0; i < kUndoDepth + 12; i++) {
        p.setProjectField(stakeholder: 'Round $i');
        step(p);
      }

      expect(p.projectUndoDepth, kUndoDepth);

      // All sixty are real: going back sixty times lands on the oldest state
      // still kept, and the sixty-first press has nothing to do.
      for (var i = 0; i < kUndoDepth; i++) {
        expect(p.undoProject(), isNotEmpty, reason: 'step ${i + 1} of 60');
      }
      expect(p.undoProject(), '');
      expect(p.project.stakeholder, 'Round 11',
          reason: 'the oldest state still held, twelve having fallen off');

      // And sixty forward again.
      for (var i = 0; i < kUndoDepth; i++) {
        expect(p.redoProject(), isNotEmpty, reason: 'forward ${i + 1} of 60');
      }
      expect(p.redoProject(), '');
      expect(p.project.stakeholder, 'Round ${kUndoDepth + 11}');
    });
  });

  group('typing settles into one step', () {
    test('a burst of edits with no pause is one entry, not eleven', () async {
      final p = job();
      // What a name typed into a field looks like from here: one call per
      // keystroke, no pause between them.
      for (final name in ['B', 'Be', 'Bes', 'Bess', 'Besse', 'Bessey']) {
        p.setProjectField(name: name);
      }
      step(p);

      expect(p.projectUndoDepth, 1,
          reason: 'one word typed is one thing to take back');
      p.undoProject();
      expect(p.project.name, 'Bessey Hall', reason: 'the whole word went back');
    });
  });
}
