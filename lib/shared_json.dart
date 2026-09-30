import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'building_project.dart' show currentUserName;
import 'safe_write.dart';

// ============================================================================
//  FILES EVERYBODY SAVES TO
// ============================================================================
//  The catalog, costs, labor rates, vendors and the rest live in one shared
//  folder, and several people have them open at once. A save here must not
//  throw away what somebody else saved since this copy read the file, so it:
//
//    1. takes a short lock beside the file, so two saves never interleave;
//    2. reads what is on disk now and merges it with this copy, three ways,
//       against what this copy last read ([rememberSharedJson]);
//    3. stamps each list item with who added it and who last changed it;
//    4. writes the result and remembers it as the new baseline.
//
//  The caller re-reads the file when [SharedSave.tookTheirs] says the merge
//  brought in somebody else's work.
// ============================================================================

/// Stamp keys written on list items. Never compared as content.
const String kAddedBy = 'addedBy';
const String kAddedAt = 'addedAt';
const String kChangedBy = 'changedBy';
const String kChangedAt = 'changedAt';
const Set<String> kStampKeys = {kAddedBy, kAddedAt, kChangedBy, kChangedAt};

/// What each shared file looked like when this copy last read or wrote it.
final Map<String, Object?> _baselines = {};

String _key(String file) => path.normalize(path.absolute(file)).toLowerCase();

/// Records [doc] as what this copy last saw of [file].
void rememberSharedJson(String file, Object? doc) {
  if (file.isEmpty) return;
  _baselines[_key(file)] = _clone(doc);
}

/// The outcome of [saveSharedJson].
typedef SharedSave = ({
  /// What was written.
  Map<String, dynamic> doc,

  /// True when somebody else's changes were merged in, so the caller's copy
  /// in memory is now behind the file.
  bool tookTheirs,
});

/// Saves [mine] to [file] as described at the top of this file.
Future<SharedSave> saveSharedJson(
  String file,
  Map<String, dynamic> mine, {
  String? user,
  DateTime? now,
}) {
  return withFileLock(file, () async {
    final who = user ?? currentUserName();
    final at = (now ?? DateTime.now()).toIso8601String();
    final base = _baselines[_key(file)];

    Object? disk;
    try {
      final f = File(file);
      if (await f.exists()) disk = jsonDecode(await f.readAsString());
    } catch (e) {
      // Unreadable: saving over it beats refusing to save.
      AppLogger.logError('Could not re-read $file before saving', e);
    }

    final stamped = stampSharedItems(mine, base ?? disk, user: who, at: at);
    final merged = (base != null && disk != null && !_same(disk, base))
        ? mergeJson(base, stamped, disk)
        : stamped;
    final doc = merged is Map
        ? Map<String, dynamic>.from(merged)
        : Map<String, dynamic>.from(stamped);

    await File(file).parent.create(recursive: true);
    await writeFileSafely(file, const JsonEncoder.withIndent('  ').convert(doc));
    rememberSharedJson(file, doc);
    return (doc: doc, tookTheirs: !_same(doc, stamped));
  });
}

// ---------------------------------------------------------------------------
//  The lock
// ---------------------------------------------------------------------------

/// Runs [action] holding `<file>.lock`. A lock older than [stale] was left by
/// a copy that died mid-save and is taken over. After [wait] the save goes
/// ahead anyway: a save that never happens is worse than one that races.
Future<T> withFileLock<T>(
  String file,
  Future<T> Function() action, {
  Duration wait = const Duration(seconds: 15),
  Duration stale = const Duration(seconds: 30),
}) async {
  final lock = File('$file.lock');
  final deadline = DateTime.now().add(wait);
  var held = false;
  while (true) {
    try {
      await lock.parent.create(recursive: true);
      lock.createSync(exclusive: true);
      lock.writeAsStringSync('${currentUserName()} pid $pid '
          '${DateTime.now().toIso8601String()}');
      held = true;
      break;
    } on FileSystemException {
      try {
        final age = DateTime.now().difference(lock.lastModifiedSync());
        if (age > stale) {
          lock.deleteSync();
          continue;
        }
      } catch (_) {
        // Gone between the two calls: try again straight away.
        continue;
      }
      if (DateTime.now().isAfter(deadline)) {
        AppLogger.logError(
          'Saved $file without its lock: ${lock.path} was still held after '
          '${wait.inSeconds}s.',
        );
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  try {
    return await action();
  } finally {
    if (held) {
      try {
        lock.deleteSync();
      } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------------------
//  Who added and changed what
// ---------------------------------------------------------------------------

/// [doc] with each item of its top-level lists stamped against [prior]:
/// a new item gets added-by, a changed one changed-by, and an unchanged one
/// keeps the stamps it had (which a model class that does not know them
/// would otherwise drop).
Map<String, dynamic> stampSharedItems(
  Map<String, dynamic> doc,
  Object? prior, {
  required String user,
  required String at,
}) {
  final before = prior is Map ? prior : const {};
  return {
    for (final e in doc.entries)
      e.key: e.value is List && _identifiable(e.value as List)
          ? _stampList(
              e.value as List,
              before[e.key] is List ? before[e.key] as List : const [],
              user,
              at,
            )
          : e.value,
  };
}

List _stampList(List items, List prior, String user, String at) {
  final byId = {
    for (final p in prior)
      if (p is Map && _idOf(p) != null) _idOf(p)!: p,
  };
  return [
    for (final item in items)
      if (item is Map && _idOf(item) != null)
        _stampItem(Map<String, dynamic>.from(item), byId[_idOf(item)], user, at)
      else
        item,
  ];
}

Map<String, dynamic> _stampItem(
  Map<String, dynamic> item,
  Map? was,
  String user,
  String at,
) {
  if (was == null) {
    item.putIfAbsent(kAddedBy, () => user);
    item.putIfAbsent(kAddedAt, () => at);
    return item;
  }
  for (final k in [kAddedBy, kAddedAt]) {
    if (was[k] != null) item[k] = was[k];
  }
  if (_same(_content(item), _content(was))) {
    for (final k in [kChangedBy, kChangedAt]) {
      if (was[k] != null) {
        item[k] = was[k];
      } else {
        item.remove(k);
      }
    }
  } else {
    item[kChangedBy] = user;
    item[kChangedAt] = at;
  }
  return item;
}

Map _content(Map item) => {
  for (final e in item.entries)
    if (!kStampKeys.contains(e.key)) e.key: e.value,
};

// ---------------------------------------------------------------------------
//  The merge
// ---------------------------------------------------------------------------

/// Stands for "not there" on one side of a merge.
const Object _absent = Object();

/// Three-way merge of JSON values. Where only one side changed, that side
/// wins; where both changed a map, it is merged key by key; lists of items
/// with ids are merged item by item. Where both changed the same value, this
/// save ([mine]) wins, and an edit wins over a deletion.
Object? mergeJson(Object? base, Object? mine, Object? theirs) {
  final out = _merge(base, mine, theirs);
  return identical(out, _absent) ? null : out;
}

Object? _merge(Object? base, Object? mine, Object? theirs) {
  if (_same(mine, theirs)) return mine;
  if (_same(mine, base)) return theirs;
  if (_same(theirs, base)) return mine;
  if (identical(mine, _absent)) return theirs;
  if (identical(theirs, _absent)) return mine;

  if (mine is Map && theirs is Map) {
    final b = base is Map ? base : const {};
    final out = <String, dynamic>{};
    for (final k in {...mine.keys, ...theirs.keys}) {
      final v = _merge(
        b.containsKey(k) ? b[k] : _absent,
        mine.containsKey(k) ? mine[k] : _absent,
        theirs.containsKey(k) ? theirs[k] : _absent,
      );
      if (!identical(v, _absent)) out[k.toString()] = v;
    }
    return out;
  }

  if (mine is List &&
      theirs is List &&
      _identifiable(mine) &&
      _identifiable(theirs)) {
    final b = base is List && _identifiable(base) ? base : const [];
    Map<String, Object?> index(List l) => {for (final x in l) _idOf(x as Map)!: x};
    final bi = index(b), mi = index(mine), ti = index(theirs);
    final order = [
      ...mi.keys,
      // Theirs that this copy never had, after mine.
      for (final id in ti.keys)
        if (!mi.containsKey(id)) id,
    ];
    return [
      for (final id in order)
        if (!identical(
          _merge(bi[id] ?? _absent, mi[id] ?? _absent, ti[id] ?? _absent),
          _absent,
        ))
          _merge(bi[id] ?? _absent, mi[id] ?? _absent, ti[id] ?? _absent),
    ];
  }

  return mine;
}

/// The fields an item is known by, first match wins.
const List<String> _idKeys = ['id', 'model', 'category', 'key', 'name'];

String? _idOf(Map item) {
  for (final k in _idKeys) {
    final v = item[k];
    if (v is String && v.trim().isNotEmpty) return '$k:${v.trim().toLowerCase()}';
  }
  return null;
}

/// True when every item is a map with a distinct id.
bool _identifiable(List items) {
  if (items.isEmpty) return true;
  final seen = <String>{};
  for (final x in items) {
    if (x is! Map) return false;
    final id = _idOf(x);
    if (id == null || !seen.add(id)) return false;
  }
  return true;
}

bool _same(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (identical(a, _absent) || identical(b, _absent)) return false;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_same(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

Object? _clone(Object? doc) => doc == null ? null : jsonDecode(jsonEncode(doc));
