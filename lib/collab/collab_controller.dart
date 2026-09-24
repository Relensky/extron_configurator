import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'json_merge.dart';
import 'presence.dart';

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
  String stamp = '';
  DateTime since = DateTime.now();
  DateTime? savedAt;
  List<EditorPresence> others = const [];
  IncomingChange? incoming;
  DateTime? lastAnnounced;
  bool lastAnnouncedDirty = false;
}

/// The outcome of bringing another person's saved changes into memory.
class CollabMergeOutcome {
  /// False when there was nothing to merge (or the file could not be read).
  final bool merged;
  final int takenFromTheirs;
  final List<MergeConflict> conflicts;

  const CollabMergeOutcome({
    required this.merged,
    this.takenFromTheirs = 0,
    this.conflicts = const [],
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
  void start({Duration every = const Duration(seconds: 5)}) {
    if (!enabled || _timer != null) return;
    _timer = Timer.periodic(every, (_) => tick());
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
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
        changed |= await _tickOne(doc, at);
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
    if (s.lastAnnounced == null ||
        dirty != s.lastAnnouncedDirty ||
        now.difference(s.lastAnnounced!) >= kPresenceHeartbeat) {
      await board.announce(_presence(s, now, dirty));
      s
        ..lastAnnounced = now
        ..lastAnnouncedDirty = dirty;
    }

    final others = await board.others(me, now: now);
    final arrived = others
        .where((o) => !s.others.any((p) => p.identity == o.identity))
        .toList();
    if (!_samePresence(others, s.others)) {
      s.others = others;
      changed = true;
    }
    for (final o in arrived) {
      _notices.add(CollabNotice(
        doc.kind,
        '${o.user} (${o.machine}) has opened this ${collabDocNoun(doc.kind)} '
        'too. Their saves will be merged with yours.',
      ));
    }

    // Did the file move without us moving it?
    final stamp = _stampOf(doc.watchedFiles);
    if (stamp != s.stamp) {
      s.stamp = stamp;
      final disk = doc.readDisk();
      if (disk != null && !jsonEquals(disk, s.baseline)) {
        if (jsonEquals(disk, doc.current())) {
          // Somebody saved exactly what we have - nothing to bring in.
          s.baseline = disk;
          s.incoming = null;
        } else {
          final by = _latestSaver(others, file);
          s.incoming = IncomingChange(by: by, at: now);
          _notices.add(CollabNotice(
            doc.kind,
            '${s.incoming!.who} saved changes to this '
            '${collabDocNoun(doc.kind)}.',
          ));
        }
        changed = true;
      }
    }
    return changed;
  }

  EditorPresence _presence(CollabDocState s, DateTime now, bool dirty) =>
      EditorPresence(
        user: me.user,
        machine: me.machine,
        since: s.since,
        heartbeat: now,
        unsaved: dirty,
        savedAt: s.savedAt,
      );

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
  }

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
    return mergeJson3(s.baseline, doc.current(), disk);
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
        ..incoming = null;
      notifyListeners();
      return const CollabMergeOutcome(merged: true);
    }

    final result = mergeJson3(s.baseline, doc.current(), disk, resolve: resolve);
    doc.apply(cloneJson(result.merged), clean: jsonEquals(result.merged, disk));
    s
      ..baseline = cloneJson(disk)
      ..stamp = _stampOf(doc.watchedFiles)
      ..incoming = null;
    notifyListeners();
    return CollabMergeOutcome(
      merged: true,
      takenFromTheirs: result.takenFromTheirs,
      conflicts: result.conflicts,
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
    stop();
    _notices.close();
    super.dispose();
  }

  // --- helpers -------------------------------------------------------------

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
          a[i].savedAt != b[i].savedAt) {
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
