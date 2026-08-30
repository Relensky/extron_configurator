// ============================================================================
//  UNDO FOR A WHOLE DOCUMENT
// ============================================================================
//  The room's four drawing tabs have had undo for a long time, and they have
//  it the expensive way: every mutation that touches the canvas calls
//  `_pushAvUndo` with a label first. That works because those edits go through
//  a couple of dozen named methods on one class, and it gives the best undo in
//  the app — each step is named after the thing it did.
//
//  The rest of the app cannot be done that way. The room's config is mutated
//  in a hundred places across two dozen files; the job is mutated by seventy
//  methods. Instrumenting all of them means the one that gets forgotten is a
//  silent hole — an edit that Undo skips straight over, which is worse than no
//  Undo at all, because somebody pressed it and believed it.
//
//  SO THIS RECORDS STATES, NOT EDITS. The document is encoded after a change
//  and the encoding is kept. Nothing has to be instrumented, so nothing can be
//  missed: a field added next year is inside the document, and therefore
//  inside its history, without anybody remembering to do anything.
//
//  WHAT IT COSTS, AND WHY THAT IS PAID LATE. Encoding a document is milliseconds
//  and a person types faster than that, so the encode is DEFERRED — see
//  [UndoRecorder]. A burst of typing settles into one entry, which is also the
//  granularity somebody wants: Undo should take back the word, not the letter.
//
//  NAMING A STEP IS THE CALLER'S JOB, and there are two ways to do it. A
//  document that already keeps a log of who changed what — the job does —
//  takes the step's name straight off the last line of it, so Undo and the
//  History pane say the same words about the same change. A document with no
//  log — the room's config — gets its name by comparing the encoding before
//  the edit with the one after, and saying which block moved. Neither is as
//  good as a hand-written label, and both are better than "Undo".
// ============================================================================

// How many steps every history in this app keeps, in each direction.
//
// ONE NUMBER FOR ALL OF THEM. A Cancel that goes back six times on one tab and
// sixty on another is not a feature anybody can rely on, and the answer to
// "how far back does this go" has to be the same wherever it is asked.
const int kUndoDepth = 60;

/// One step: the state to go back to, and the name of the edit that left it.
typedef UndoStep = ({String label, String state});

/// A document's past and future, as encodings of the whole thing.
///
/// The state stored against a step is the one BEFORE the edit that named it, so
/// "Undo: Qty on Wall plate" and the state it restores are the same fact read
/// from the two sides. Getting this backwards is the bug that makes an Undo
/// button take back the wrong edit while naming the right one.
class DocumentHistory {
  DocumentHistory({this.depth = kUndoDepth});

  /// How many steps are kept each way. Older ones fall off the bottom.
  final int depth;

  final List<UndoStep> _past = [];
  final List<UndoStep> _future = [];

  /// The document as it was at the last recording, or '' before there has been
  /// one. Not itself a step: it is the state the two stacks are relative to.
  String _current = '';

  /// Whether a baseline has been taken. Recording without one would file the
  /// document's whole contents as the first undoable edit, so the first press
  /// of Undo emptied the job.
  bool _started = false;

  /// Whether a baseline has been taken — see [begin].
  ///
  /// Read by [UndoRecorder.pending], which must not report work waiting on a
  /// history that has nothing to compare against: before a baseline, every
  /// document differs from the empty string it starts at, and an Undo button
  /// would sit lit over a room nobody has opened.
  bool get started => _started;

  /// The document as the history currently believes it to be.
  ///
  /// Handed to the label callback so a document with no edit log of its own can
  /// work out what changed by comparing — see [UndoRecorder.label].
  String get current => _current;

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// What Undo would put back, for the button to say out loud.
  String get undoLabel => _past.isEmpty ? '' : _past.last.label;

  /// What Redo would put back.
  String get redoLabel => _future.isEmpty ? '' : _future.last.label;

  /// How far back it can currently go — what the tooltip counts.
  int get depthBehind => _past.length;
  int get depthAhead => _future.length;

  /// Starts again from [state], with no past and no future.
  ///
  /// Called when the document is REPLACED rather than edited: a job opened, a
  /// room closed, a new campus started. Carrying the old document's history
  /// across would let Undo paste the last job into this one.
  void begin(String state) {
    _current = state;
    _past.clear();
    _future.clear();
    _started = true;
  }

  /// Throws the history away without taking a new baseline — for a document
  /// that is no longer open at all.
  void end() {
    _current = '';
    _past.clear();
    _future.clear();
    _started = false;
  }

  /// Files [state] as where the document is now, with [label] naming the edit
  /// that brought it here. Returns whether anything was actually recorded.
  ///
  /// An unchanged document records nothing. That matters more than it sounds:
  /// this is called from the place every rebuild goes through, and a redraw is
  /// not an edit — a history that grew by one on every repaint would be sixty
  /// entries of nothing by the time somebody pressed Undo.
  bool record(String label, String state) {
    if (!_started) {
      begin(state);
      return false;
    }
    if (state == _current) return false;
    _past.add((label: label, state: _current));
    if (_past.length > depth) _past.removeAt(0);
    _current = state;
    // A NEW EDIT ENDS THE FUTURE. Anything undone and then typed over is gone,
    // which is what every undo in every program does, and what people expect
    // even when they could not say so.
    _future.clear();
    return true;
  }

  /// The state to go back to, or null when there is nothing behind.
  ///
  /// The caller restores it and is expected to have done so: the history moves
  /// its cursor here and does not check afterwards.
  String? undo() {
    if (_past.isEmpty) return null;
    final step = _past.removeLast();
    _future.add((label: step.label, state: _current));
    if (_future.length > depth) _future.removeAt(0);
    _current = step.state;
    return step.state;
  }

  /// The state to go forward to, or null when there is nothing ahead.
  String? redo() {
    if (_future.isEmpty) return null;
    final step = _future.removeLast();
    _past.add((label: step.label, state: _current));
    if (_past.length > depth) _past.removeAt(0);
    _current = step.state;
    return step.state;
  }

  /// Puts the cursor on [state] without filing a step — after a save, a
  /// reload, or a restore this history did not ask for.
  void settle(String state) {
    if (!_started) {
      begin(state);
      return;
    }
    _current = state;
  }
}

/// Encodes a document as it is edited, no more often than it has to.
///
/// WHY NOT ON EVERY CHANGE. This hangs off the one call every mutation in the
/// app already makes to be visible on screen, which is also the call made per
/// keystroke while somebody types a room name. Encoding the job on each of
/// those was the whole objection to recording states.
///
/// SO IT FILES AT MOST ONCE EVERY [settle], BY THE CLOCK, WITH NO TIMER. A
/// change inside that window is remembered as "there is something to file" — a
/// bool — and folded into the next recording, which is also the granularity
/// somebody wants: Undo should take back the word, not the letter.
///
/// THE ABSENCE OF A TIMER IS DELIBERATE, not an accident of style. A timer
/// would have to be cancelled by whoever disposes of the app state, and the
/// one that was not is a test that hangs and a process that will not exit. A
/// clock reading owns nothing and needs no cleanup.
///
/// WHAT THE TRADE COSTS. The tail of a burst — what was typed after the last
/// filing — is not filed until something else happens. That is why every
/// reader (Undo, Redo, a save, an explicit undo point) calls [flush] first: a
/// history asked about mid-burst answers about the document as it is, not as
/// it was a third of a second ago.
class UndoRecorder {
  UndoRecorder({
    required this.history,
    required this.snapshot,
    required this.label,
    this.onRecorded,
    this.settle = const Duration(milliseconds: 350),
  });

  final DocumentHistory history;

  /// The document, encoded. Called when a step is filed, not when one is made.
  final String Function() snapshot;

  /// What to call the edit that has just happened, given the document before
  /// it and after it.
  ///
  /// Read at the moment of recording rather than at the moment of the edit. A
  /// document that keeps its own log of who changed what names the step off
  /// that; one that does not works it out by comparing the two encodings, which
  /// is why both are handed over.
  final String Function(String before, String after) label;

  /// Called with the step's name when one is actually filed, and not when a
  /// notification turns out to have changed nothing.
  ///
  /// WHAT THIS IS FOR. A document recorded here is one of several a room is
  /// made of, and a room-wide Undo has to walk all of them in the order the
  /// edits happened. The other histories file synchronously and can note their
  /// own place in that order; this one files LATE, on a settle, so the only
  /// moment it can be pinned to the timeline is the moment it lands. That is
  /// here. See [AppStateProvider.undoRoom].
  final void Function(String label)? onRecorded;

  /// The shortest a step can be. Edits closer together than this are one step.
  final Duration settle;

  /// When the last step was filed — what [settle] is measured from.
  DateTime? _filedAt;

  /// Something has notified since then.
  bool _dirty = false;

  /// The document as of the last notification, once something has asked. Held
  /// so that answering "is there anything to undo" and then filing it do not
  /// encode the document twice.
  String? _seen;

  /// Whether [_seen] differs from what is filed — null until asked.
  bool? _changed;

  /// True while a restore is being applied, so the notification the restore
  /// itself causes is not filed as a new edit — which would make Undo
  /// unrepeatable, each press recording the state the last one put back.
  bool restoring = false;

  /// There is a real, unfiled change waiting.
  ///
  /// WHAT LETS AN UNDO BUTTON BE HONEST. It has to light the instant somebody
  /// edits rather than at the next filing, or the button lags every change —
  /// but it must not light for a notification that changed nothing, because a
  /// tab switch and a selection notify too, and an Undo that is lit and does
  /// nothing when pressed is the exact failure people report as "the button
  /// does not work".
  ///
  /// SO IT CHECKS, AND REMEMBERS THE CHECK. The encoding is kept and reused by
  /// the filing that follows, so asking costs one encode per notification
  /// rather than two — and nothing at all while the document sits still.
  bool get pending {
    if (!_dirty || restoring || !history.started) return false;
    final known = _changed;
    if (known != null) return known;
    final now = snapshot();
    _seen = now;
    return _changed = now != history.current;
  }

  /// Called from the app's change notification. Cheap: a bool and a clock
  /// reading, and an encoding only when the window has passed.
  void touch() {
    if (restoring) return;
    _dirty = true;
    // The document has moved on, so whatever was worked out about it has not.
    _seen = null;
    _changed = null;
    final since = _filedAt;
    if (since == null) {
      // Nothing filed yet in this document's life. Start the window here
      // rather than filing immediately, so the first burst coalesces like
      // every later one.
      _filedAt = DateTime.now();
      return;
    }
    if (DateTime.now().difference(since) >= settle) _fileNow();
  }

  /// Files whatever has changed, now. Called before anything reads the history.
  void flush() {
    if (!_dirty || restoring) return;
    _fileNow();
  }

  void _fileNow() {
    _filedAt = DateTime.now();
    _dirty = false;
    final before = history.current;
    // Reuse the encoding [pending] already paid for, when it is still the
    // current one — nothing can have changed since without notifying.
    final after = _seen ?? snapshot();
    _seen = null;
    _changed = null;
    final name = label(before, after);
    if (history.record(name, after)) onRecorded?.call(name);
  }

  /// Forgets what has changed without filing it — the document it was about is
  /// being replaced.
  void cancel() {
    _dirty = false;
    _seen = null;
    _changed = null;
    _filedAt = null;
  }

  /// Restores [state] through [apply], keeping the recorder out of its own way.
  void applying(void Function() apply) {
    cancel();
    restoring = true;
    try {
      apply();
    } finally {
      restoring = false;
    }
  }
}
