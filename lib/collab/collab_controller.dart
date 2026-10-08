import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'json_merge.dart';
import 'presence.dart';
import '../app_logger.dart';

/// ============================================================================
///  SEVERAL PEOPLE, ONE SHARED FOLDER
/// ============================================================================
///  The room, the job and the catalog can each be open on more than one
///  machine at once. This keeps track of three things per document:
///
///    * WHO ELSE has it open - their presence notes, see presence.dart - so the
///      banner can show their Windows sign-in names;
///    * WHETHER THE FILE MOVED under us - somebody else saved - so the banner
///      can say so and offer to merge their work in straight away;
///    * THE BASE - the document as it was on disk when this copy last read or
///      wrote it - which is what makes a three-way merge possible, on demand
///      or on Save, instead of the last person to save erasing the first.
/// ============================================================================

/// The documents that can be edited together.
enum CollabDocKind { room, project, catalog }

String collabDocNoun(CollabDocKind kind) => switch (kind) {
      CollabDocKind.room => 'room',
      CollabDocKind.project => 'project',
      CollabDocKind.catalog => 'catalog',
    };

/// How the controller reads and writes one document. Implemented by the app
/// state, which owns the documents.
abstract class CollabDocument {
  CollabDocKind get kind;

  /// The file presence notes are kept beside. '' when the document has no
  /// file yet - an unsaved room is nobody else's to be editing.
  String get filePath;

  /// Every file whose change means the document changed (a room is its
  /// config plus the sidecars beside it).
  List<String> get watchedFiles => [filePath];

  /// Whether the copy in memory has changes not yet on disk.
  bool get isDirty;

  /// The document as it is on disk now, decoded. Null when it cannot be read.
  Object? readDisk();

  /// The document as it is in memory, in the same shape as [readDisk].
  Object? current();

  /// Replaces the document in memory with [doc]. [clean] is true when [doc]
  /// is exactly what is on disk.
  void apply(Object? doc, {required bool clean});

  /// True for a document that settles its own merges (the catalog), which
  /// [pullFromDisk] then does instead of the generic JSON merge.
  bool get mergesItself => false;

  /// Brings the saved file's changes in by the document's own rules. Returns
  /// how many things were taken from the file.
  Future<int> pullFromDisk() async => 0;
}

/// Somebody else saved the document after this copy last read it.
class IncomingChange {
  /// Their name, when a presence note says who; '' when nobody can tell.
  final String by;
  final DateTime at;

  const IncomingChange({required this.by, required this.at});

  String get who => by.isEmpty ? 'Someone else' : by;
}

/// Something worth a snack bar: somebody arrived, or saved.
class CollabNotice {
  final CollabDocKind kind;
  final String message;
  const CollabNotice(this.kind, this.message);
}

class CollabDocState {
  String path = '';
  Object? baseline;

  /// This copy as it was right after it was opened or saved - what opening
  /// filled in is told apart from what the person typed. See [mergeJson3].
  Object? loaded;
  bool hasLoaded = false;
  String stamp = '';
  DateTime since = DateTime.now();
  DateTime? savedAt;
  List<EditorPresence> others = const [];
  IncomingChange? incoming;
  DateTime? lastAnnounced;
  bool lastAnnouncedDirty = false;
  String lastAnnouncedWhere = '';
}

/// The outcome of bringing another person's saved changes into memory.
class CollabMergeOutcome {
  /// False when there was nothing to merge (or the file could not be read).
  final bool merged;
  final int takenFromTheirs;
  final List<MergeConflict> conflicts;

  /// Their new rows given a new number so both people's were kept.
  final int renumbered;

  const CollabMergeOutcome({
    required this.merged,
    this.takenFromTheirs = 0,
    this.conflicts = const [],
    this.renumbered = 0,
  });

  static const none = CollabMergeOutcome(merged: false);
}

class CollabController extends ChangeNotifier {
  final CollabIdentity me;
  final Map<CollabDocKind, CollabDocument> _docs = {};
  final Map<CollabDocKind, CollabDocState> _state = {
    for (final k in CollabDocKind.values) k: CollabDocState(),
  };

  /// Off in tests and wherever the app is not the real one: no timers, no
  /// files written beside anybody's documents.
  bool enabled;

  Timer? _timer;
  bool _ticking = false;
  int _held = 0;
  final _notices = StreamController<CollabNotice>.broadcast();

  /// Who has already been announced on which file this session. A presence
  /// file that drops out for a moment and comes back is not news.
  final Set<String> _announced = {};

  /// Documents whose last check failed, so an outage is logged once.
  final Set<CollabDocKind> _failing = {};

  CollabController({CollabIdentity? identity, this.enabled = false})
      : me = identity ?? CollabIdentity.current();

  Stream<CollabNotice> get notices => _notices.stream;

  void register(CollabDocument doc) => _docs[doc.kind] = doc;

  CollabDocState stateOf(CollabDocKind kind) => _state[kind]!;

  /// The other people with [kind] open right now.
  List<EditorPresence> othersOn(CollabDocKind kind) =>
      enabled ? _state[kind]!.others : const [];

  IncomingChange? incomingOn(CollabDocKind kind) =>
      enabled ? _state[kind]!.incoming : null;

  /// Starts the heartbeat. Idempotent.
  void start({Duration every = const Duration(seconds: 2)}) {
    if (!enabled || _timer != null) return;
    _timer = Timer.periodic(every, (_) => tick());
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _nudge?.cancel();
    _nudge = null;
  }

  Timer? _nudge;

  /// Asks for a tick soon - after an edit, so a colleague sees "editing"
  /// without waiting for the next heartbeat. Repeated calls fold into one.
  void nudge() {
    if (!enabled || _timer == null || _nudge != null) return;
    _nudge = Timer(const Duration(milliseconds: 600), () {
      _nudge = null;
      tick();
    });
  }

  /// One pass: follow each document to its current file, refresh this copy's
  /// presence note, read everybody else's, and look for a save that was not
  /// ours. Public so a test can drive it without a timer.
  Future<void> tick({DateTime? now}) async {
    if (!enabled || _ticking || _held > 0) return;
    _ticking = true;
    var changed = false;
    try {
      final at = now ?? DateTime.now();
      for (final doc in _docs.values) {
        try {
          changed |= await _tickOne(doc, at);
          _failing.remove(doc.kind);
        } catch (e) {
          // The share dropped out. Logged once per outage, not every five
          // seconds for as long as it lasts; the next tick tries again.
          if (_failing.add(doc.kind)) {
            AppLogger.logError(
              'Could not check who else has the ${collabDocNoun(doc.kind)} '
              'open; will keep trying',
              e,
            );
          }
        }
      }
    } finally {
      _ticking = false;
    }
    if (changed) notifyListeners();
  }

  Future<bool> _tickOne(CollabDocument doc, DateTime now) async {
    final s = _state[doc.kind]!;
    var changed = false;
    final file = doc.filePath;

    // A different file than last time: the old one is no longer ours to be
    // present on, and the new one's base is whatever is on disk now.
    if (!_samePath(file, s.path)) {
      if (s.path.isNotEmpty) await PresenceBoard(s.path).withdraw(me);
      s
        ..path = file
        ..since = now
        ..savedAt = null
        ..others = const []
        ..incoming = null
        ..lastAnnounced = null;
      _captureBaseline(doc);
      changed = true;
    }
    if (file.isEmpty) return changed;

    final board = PresenceBoard(file);
    final dirty = doc.isDirty;
    final where = _whereKey();
    if (s.lastAnnounced == null ||
        dirty != s.lastAnnouncedDirty ||
        where != s.lastAnnouncedWhere ||
        now.difference(s.lastAnnounced!) >= kPresenceHeartbeat) {
      await board.announce(_presence(s, now, dirty));
      s
        ..lastAnnounced = now
        ..lastAnnouncedDirty = dirty
        ..lastAnnouncedWhere = where;
    }

    final others = await board.others(me, now: now);
    // Every copy of the app opens the catalog at launch, so having it open
    // says nothing. It is only news once they have edits to it.
    final catalog = doc.kind == CollabDocKind.catalog;
    final arrived = catalog
        ? others.where((o) => o.unsaved).toList()
        : others
            .where((o) => !s.others.any((p) => p.identity == o.identity))
            .toList();
    if (!_samePresence(others, s.others)) {
      s.others = others;
      changed = true;
    }
    for (final o in arrived) {
      final key = '${doc.kind.name}|${o.user.toLowerCase()}@'
          '${o.machine.toLowerCase()}|${file.toLowerCase()}';
      if (!_announced.add(key)) continue;
      _notices.add(CollabNotice(
        doc.kind,
        catalog
            ? '${o.user} (${o.machine}) is editing the catalog too. Their '
                'saves will be merged with yours.'
            : '${o.user} (${o.machine}) has opened this '
                '${collabDocNoun(doc.kind)} too. Their saves will be merged '
                'with yours.',
      ));
    }

    // Did the file move without us moving it?
    final stamp = await _stampOfAsync(doc.watchedFiles);
    if (stamp != s.stamp) {
      s.stamp = stamp;
      final disk = doc.readDisk();
      if (disk != null && !jsonEquals(disk, s.baseline)) {
        // Nothing of theirs that this copy lacks: what they changed is what
        // we changed too (or only what we changed differs). Said nothing -
        // the notice used to go up, and the merge it offered then said
        // "Nothing of theirs is new to this copy".
        final nothingNew = !doc.mergesItself &&
            s.baseline != null &&
            () {
              final preview = _merge3(s, doc, disk);
              return preview.changes.isEmpty && preview.conflicts.isEmpty;
            }();
        if (jsonEquals(disk, doc.current()) || nothingNew) {
          // Somebody saved exactly what we have - nothing to bring in.
          s.baseline = disk;
          s.incoming = null;
        } else {
          final by = _latestSaver(others, file);
          // Said once when changes start waiting; their next saves - an
          // autosave every few minutes - only update the merge chip.
          final news = s.incoming == null;
          s.incoming = IncomingChange(by: by, at: now);
          if (news) {
            _notices.add(CollabNotice(
              doc.kind,
              '${s.incoming!.who} saved changes to this '
              '${collabDocNoun(doc.kind)}. The merge button at the top brings '
              'them in.',
            ));
          }
        }
        changed = true;
      }
    }
    return changed;
  }

  /// Which room file this copy has open and which tab it is on, for the
  /// presence note - set by the app. Null says nothing about either.
  ({String room, String tab}) Function()? whereAmI;

  String _whereKey() {
    final w = whereAmI?.call();
    return w == null ? '' : '${w.room}|${w.tab}';
  }

  EditorPresence _presence(CollabDocState s, DateTime now, bool dirty) {
    final w = whereAmI?.call();
    return EditorPresence(
      user: me.user,
      machine: me.machine,
      since: s.since,
      heartbeat: now,
      unsaved: dirty,
      savedAt: s.savedAt,
      room: w?.room ?? '',
      tab: w?.tab ?? '',
    );
  }

  /// Runs [body] - a save - with the watcher paused, so this copy's own
  /// write is never mistaken for somebody else's.
  Future<T> hold<T>(Future<T> Function() body) async {
    _held++;
    try {
      return await body();
    } finally {
      _held--;
    }
  }

  // --- the merge queue -----------------------------------------------------
  //
  //  ONE AT A TIME. A Merge pressed on the room and the project, and a save
  //  merging before it writes, used to run together - each reading the file,
  //  merging and rebuilding the screen at once, with the watcher still ticking
  //  under them. Queued, each finishes before the next starts, with the
  //  watcher paused for the lot.

  Future<void> _queueTail = Future.value();
  int _queued = 0;

  /// What a job in the queue sees as the current zone value, so a job that
  /// queues more work runs it straight away instead of waiting on itself.
  static final Object _inQueue = Object();

  /// Merges and saves waiting or running. The screen shows a busy chip while
  /// this is above nothing.
  int get queued => _queued;

  /// Runs [job] after everything queued before it, with the watcher paused.
  Future<T> enqueue<T>(Future<T> Function() job) {
    if (identical(Zone.current[_inQueue], this)) return job();
    _queued++;
    notifyListeners();
    final run = _queueTail.then(
      (_) => runZoned(() => hold(job), zoneValues: {_inQueue: this}),
    );
    _queueTail = run.then<void>((_) {}, onError: (_) {});
    return run.whenComplete(() {
      _queued--;
      if (!_disposed) notifyListeners();
    });
  }

  bool _disposed = false;

  /// Records the file as it is now as the base of the next merge. Called
  /// after every load and every save of [kind].
  void noteInSync(CollabDocKind kind, {bool saved = false}) {
    if (!enabled) return;
    final doc = _docs[kind];
    if (doc == null) return;
    final s = _state[kind]!;
    if (!_samePath(doc.filePath, s.path)) {
      // The tick will follow it to the new file; the base is taken there.
      return;
    }
    _captureBaseline(doc);
    s.incoming = null;
    if (saved) {
      s.savedAt = DateTime.now();
      _writeLastSave(doc.filePath);
      // Straight away rather than on the next heartbeat, so a colleague's
      // copy can say whose save it was.
      unawaited(PresenceBoard(doc.filePath)
          .announce(_presence(s, DateTime.now(), doc.isDirty)));
    }
    notifyListeners();
  }

  void _captureBaseline(CollabDocument doc) {
    final s = _state[doc.kind]!;
    s.stamp = _stampOf(doc.watchedFiles);
    s.baseline = doc.filePath.isEmpty ? null : cloneJson(doc.readDisk());
    s.loaded = cloneJson(doc.current());
    s.hasLoaded = true;
  }

  JsonMergeResult _merge3(
    CollabDocState s,
    CollabDocument doc,
    Object? disk, {
    MergeSide Function(MergeConflict)? resolve,
  }) => s.hasLoaded
      ? mergeJson3(s.baseline, doc.current(), disk,
          resolve: resolve, loaded: s.loaded)
      : mergeJson3(s.baseline, doc.current(), disk, resolve: resolve);

  /// The document as this copy holds it, for naming things in a conflict.
  Object? currentOf(CollabDocKind kind) => _docs[kind]?.current();

  /// What merging the file on disk into memory would do, without doing it.
  /// Null when the file is exactly the base (nobody else saved).
  JsonMergeResult? previewMerge(CollabDocKind kind) {
    final doc = _docs[kind];
    if (!enabled || doc == null || doc.filePath.isEmpty) return null;
    if (doc.mergesItself) return null;
    final disk = doc.readDisk();
    final s = _state[kind]!;
    if (disk == null || s.baseline == null || jsonEquals(disk, s.baseline)) {
      return null;
    }
    return _merge3(s, doc, disk);
  }

  /// Brings the saved file's changes into memory.
  ///
  /// A copy with nothing unsaved simply takes the file. One with its own
  /// edits is merged three ways against the base; [resolve] settles anything
  /// both sides changed (default: keep mine).
  Future<CollabMergeOutcome> mergeIncoming(
    CollabDocKind kind, {
    MergeSide Function(MergeConflict)? resolve,
  }) async {
    final doc = _docs[kind];
    if (doc == null || doc.filePath.isEmpty) return CollabMergeOutcome.none;
    final s = _state[kind]!;
    if (doc.mergesItself) {
      final taken = await doc.pullFromDisk();
      s
        ..baseline = cloneJson(doc.readDisk())
        ..stamp = _stampOf(doc.watchedFiles)
        ..incoming = null;
      notifyListeners();
      return CollabMergeOutcome(merged: true, takenFromTheirs: taken);
    }
    final disk = doc.readDisk();
    if (disk == null) return CollabMergeOutcome.none;

    if (!doc.isDirty || s.baseline == null) {
      doc.apply(cloneJson(disk), clean: true);
      s
        ..baseline = cloneJson(disk)
        ..stamp = _stampOf(doc.watchedFiles)
        ..incoming = null
        ..loaded = cloneJson(doc.current())
        ..hasLoaded = true;
      notifyListeners();
      return const CollabMergeOutcome(merged: true);
    }

    final result = _merge3(s, doc, disk, resolve: resolve);
    doc.apply(cloneJson(result.merged), clean: jsonEquals(result.merged, disk));
    s
      ..baseline = cloneJson(disk)
      ..stamp = _stampOf(doc.watchedFiles)
      ..incoming = null
      // What is in memory now is part this person's and part the file's, so
      // "untouched since opening" can no longer be read off it.
      ..hasLoaded = false
      ..loaded = null;
    notifyListeners();
    return CollabMergeOutcome(
      merged: true,
      takenFromTheirs: result.takenFromTheirs,
      conflicts: result.conflicts,
      renumbered: result.renumbered,
    );
  }

  /// Forgets a pending "somebody saved" without merging. The next save still
  /// merges, because the base is left where it was.
  void dismissIncoming(CollabDocKind kind) {
    _state[kind]!.incoming = null;
    notifyListeners();
  }

  /// Takes this copy's presence notes down - on close.
  Future<void> withdrawAll() async {
    for (final s in _state.values) {
      if (s.path.isNotEmpty) await PresenceBoard(s.path).withdraw(me);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _notices.close();
    super.dispose();
  }

  // --- helpers -------------------------------------------------------------

  /// [_stampOf] without blocking the screen on a slow share.
  static Future<String> _stampOfAsync(List<String> files) async {
    final stats = await Future.wait([
      for (final f in files)
        if (f.isNotEmpty)
          File(f).stat().then<FileStat?>((st) => st, onError: (_) => null),
    ]);
    final b = StringBuffer();
    for (final st in stats) {
      if (st == null) {
        b.write('?|');
      } else if (st.type == FileSystemEntityType.notFound) {
        b.write('-|');
      } else {
        b.write('${st.modified.microsecondsSinceEpoch}:${st.size}|');
      }
    }
    return b.toString();
  }

  static String _stampOf(List<String> files) {
    final b = StringBuffer();
    for (final f in files) {
      if (f.isEmpty) continue;
      try {
        final st = File(f).statSync();
        if (st.type == FileSystemEntityType.notFound) {
          b.write('-|');
        } else {
          b.write('${st.modified.microsecondsSinceEpoch}:${st.size}|');
        }
      } catch (_) {
        b.write('?|');
      }
    }
    return b.toString();
  }

  static bool _samePath(String a, String b) {
    if (a.isEmpty || b.isEmpty) return a == b;
    final l = path.normalize(a).replaceAll('\\', '/');
    final r = path.normalize(b).replaceAll('\\', '/');
    return Platform.isWindows ? l.toLowerCase() == r.toLowerCase() : l == r;
  }

  static bool _samePresence(List<EditorPresence> a, List<EditorPresence> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].identity != b[i].identity ||
          a[i].unsaved != b[i].unsaved ||
          a[i].savedAt != b[i].savedAt ||
          a[i].room != b[i].room ||
          a[i].tab != b[i].tab) {
        return false;
      }
    }
    return true;
  }

  static String _lastSaveFile(String documentPath) =>
      path.join(PresenceBoard(documentPath).folder, '_last_save.json');

  void _writeLastSave(String documentPath) {
    try {
      final f = File(_lastSaveFile(documentPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'user': me.user,
        'machine': me.machine,
        'at': DateTime.now().toUtc().toIso8601String(),
      }));
    } catch (_) {}
  }

  /// Who most likely wrote the file: the last-save note beside it, else the
  /// present editor with the latest save.
  String _latestSaver(List<EditorPresence> others, String documentPath) {
    try {
      final f = File(_lastSaveFile(documentPath));
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map) {
          final who = CollabIdentity(
            user: '${j['user'] ?? ''}',
            machine: '${j['machine'] ?? ''}',
          );
          if (who != me && who.user.isNotEmpty) return who.user;
        }
      }
    } catch (_) {}
    EditorPresence? best;
    for (final o in others) {
      if (o.savedAt == null) continue;
      if (best == null || o.savedAt!.isAfter(best.savedAt!)) best = o;
    }
    return best?.user ?? '';
  }
}
