import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/undo_history.dart';

/// THE PRIMITIVE EVERY HISTORY IN THE APP IS BUILT ON.
///
/// The job, the room's config and the campus all keep their past as encodings
/// of the whole document rather than as a list of edits — see the head of
/// undo_history.dart for why. That makes this class small and makes its two
/// invariants worth stating on their own, away from any document:
///
///   * the state filed against a step is the one BEFORE the edit that named
///     it, so a button that says "Undo: Qty" restores the state without the
///     qty change. Getting this backwards gives an Undo that names the right
///     edit and takes back the wrong one, which is the worst of both;
///   * a document that encodes the same way has not changed, and files
///     nothing. This is fed from the call every rebuild goes through, so a
///     history that counted redraws would be sixty entries of nothing by the
///     time anybody pressed the button.
void main() {
  group('a step is the state before the edit that named it', () {
    test('undo restores the state the named edit was made from', () {
      final h = DocumentHistory()..begin('a');
      h.record('typed b', 'b');
      h.record('typed c', 'c');

      expect(h.undoLabel, 'typed c');
      expect(h.undo(), 'b', reason: 'the state "typed c" was made from');
      expect(h.undoLabel, 'typed b');
      expect(h.undo(), 'a');
      expect(h.canUndo, isFalse);
      expect(h.undo(), isNull);
    });

    test('redo names the same edit from the other side', () {
      final h = DocumentHistory()..begin('a');
      h.record('typed b', 'b');

      h.undo();
      expect(h.redoLabel, 'typed b',
          reason: 'Undo: typed b and Redo: typed b are one edit, two sides');
      expect(h.redo(), 'b');
      expect(h.canRedo, isFalse);
      expect(h.redo(), isNull);
    });
  });

  group('what is not an edit', () {
    test('a document that encodes the same files nothing', () {
      final h = DocumentHistory()..begin('a');

      expect(h.record('a redraw', 'a'), isFalse);
      expect(h.canUndo, isFalse);
      expect(h.depthBehind, 0);
    });

    test('the first recording is a baseline, not a step', () {
      // Without this the whole document is the first undoable edit, and the
      // first press of Undo empties the job.
      final h = DocumentHistory();
      expect(h.record('anything', 'a'), isFalse);
      expect(h.canUndo, isFalse);
      expect(h.undo(), isNull);
    });
  });

  group('the future ends when it is typed over', () {
    test('a new edit after an undo drops what was ahead', () {
      final h = DocumentHistory()..begin('a');
      h.record('b', 'b');
      h.record('c', 'c');
      h.undo();
      expect(h.canRedo, isTrue);

      h.record('d', 'd');

      expect(h.canRedo, isFalse);
      expect(h.undo(), 'b', reason: 'and the new branch is what goes back');
    });
  });

  group('how far back it goes', () {
    test('the oldest steps fall off the bottom, and the count holds', () {
      final h = DocumentHistory()..begin('s0');
      for (var i = 1; i <= kUndoDepth + 20; i++) {
        h.record('step $i', 's$i');
      }

      expect(h.depthBehind, kUndoDepth);
      var back = 0;
      while (h.canUndo) {
        h.undo();
        back++;
      }
      expect(back, kUndoDepth);
      expect(h.depthAhead, kUndoDepth, reason: 'and all sixty are ahead now');
    });

    test('a shallower history can be asked for, and is honored', () {
      final h = DocumentHistory(depth: 3)..begin('s0');
      for (var i = 1; i <= 10; i++) {
        h.record('step $i', 's$i');
      }
      expect(h.depthBehind, 3);
    });
  });

  group('a document that is replaced, not edited', () {
    test('begin throws both directions away', () {
      final h = DocumentHistory()..begin('a');
      h.record('b', 'b');
      h.undo();
      expect(h.canUndo || h.canRedo, isTrue);

      h.begin('somewhere else entirely');

      // The hazard: an Undo that pastes the last document over this one.
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
      expect(h.current, 'somewhere else entirely');
    });

    test('settle moves the cursor without filing a step', () {
      final h = DocumentHistory()..begin('a');
      h.record('b', 'b');

      h.settle('c');

      expect(h.depthBehind, 1, reason: 'no new step');
      expect(h.undo(), 'a', reason: 'and the step it had still works');
    });
  });

  group('the recorder decides when, not whether', () {
    /// A recorder over a document held in a box, so a test can move it.
    ({DocumentHistory history, UndoRecorder recorder, List<String> doc}) rig({
      Duration settle = const Duration(milliseconds: 350),
    }) {
      final doc = <String>['a'];
      final history = DocumentHistory();
      final recorder = UndoRecorder(
        history: history,
        snapshot: () => doc.single,
        label: (before, after) => '$before to $after',
        settle: settle,
      );
      history.begin(doc.single);
      return (history: history, recorder: recorder, doc: doc);
    }

    test('a burst inside the window is one step', () {
      final r = rig();
      for (final v in ['b', 'c', 'd']) {
        r.doc[0] = v;
        r.recorder.touch();
      }
      r.recorder.flush();

      expect(r.history.depthBehind, 1, reason: 'one thing to take back');
      expect(r.history.undo(), 'a');
    });

    test('nothing is lost by not having waited', () {
      // The tail of a burst is not filed until something asks. Every reader
      // flushes first, which is what makes the delay an optimization rather
      // than a source of truth.
      final r = rig();
      r.doc[0] = 'b';
      r.recorder.touch();

      expect(r.history.canUndo, isFalse, reason: 'not filed yet');
      expect(r.recorder.pending, isTrue, reason: 'but the button knows');

      r.recorder.flush();
      expect(r.history.canUndo, isTrue);
      expect(r.history.undo(), 'a');
    });

    test('a restore is not an edit', () {
      // The bug this stops: the notification a restore causes is filed as a
      // new step, so the second press of Undo puts back what the first one
      // just restored and the button becomes unrepeatable.
      final r = rig();
      r.doc[0] = 'b';
      r.recorder.touch();
      r.recorder.flush();
      expect(r.history.depthBehind, 1);

      r.recorder.applying(() {
        r.doc[0] = 'a';
        r.recorder.touch();
      });

      expect(r.recorder.pending, isFalse);
      r.recorder.flush();
      expect(r.history.depthBehind, 1, reason: 'still just the one edit');
    });

    test('a notification that changed nothing does not light the button', () {
      // THE FAILURE PEOPLE REPORT AS "the button does not work": an Undo lit
      // for a tab switch or a selection, which notifies like everything else,
      // and then does nothing when pressed. Being lit has to mean there is
      // something behind it.
      final r = rig();
      r.recorder.touch();

      expect(r.recorder.pending, isFalse, reason: 'the document did not move');

      r.doc[0] = 'b';
      r.recorder.touch();
      expect(r.recorder.pending, isTrue, reason: 'and now it did');
    });

    test('the check is not paid for twice', () {
      // Asking whether there is anything to undo encodes the document; the
      // filing that follows reuses that encoding rather than making a second
      // one. Counted, because this runs on every rebuild of a toolbar.
      var encodes = 0;
      final doc = <String>['a'];
      final history = DocumentHistory();
      final recorder = UndoRecorder(
        history: history,
        snapshot: () {
          encodes++;
          return doc.single;
        },
        label: (before, after) => 'edit',
      );
      history.begin(doc.single);

      doc[0] = 'b';
      recorder.touch();
      expect(recorder.pending, isTrue);
      expect(recorder.pending, isTrue, reason: 'asked twice, one answer');
      final afterAsking = encodes;

      recorder.flush();
      expect(encodes, afterAsking, reason: 'the filing reused the encoding');
      expect(history.depthBehind, 1);
    });

    test('cancel forgets what was pending without filing it', () {
      final r = rig();
      r.doc[0] = 'b';
      r.recorder.touch();
      r.recorder.cancel();
      r.recorder.flush();

      expect(r.history.canUndo, isFalse);
    });

    test('a window that has passed files on the next change', () {
      // settle: zero, so every touch is its own step - which is the same rule
      // read at the other end of the dial.
      final r = rig(settle: Duration.zero);
      r.doc[0] = 'b';
      r.recorder.touch();
      r.doc[0] = 'c';
      r.recorder.touch();

      expect(r.history.depthBehind, greaterThanOrEqualTo(1));
      r.recorder.flush();
      expect(r.history.undoLabel, isNotEmpty);
    });
  });
}
