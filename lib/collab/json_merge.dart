import 'dart:convert';

/// ============================================================================
///  THREE-WAY MERGE OF TWO PEOPLE'S EDITS TO ONE JSON DOCUMENT
/// ============================================================================
///  Every document this app writes is JSON, which is what makes a shared
///  folder workable at all: two people opened the same file (the BASE), each
///  changed their own copy (MINE and THEIRS), and the question on save is
///  which of the differences to keep. A difference only one side made is kept
///  without asking. The same key changed two different ways is a [MergeConflict]
///  and the caller decides - by default MINE wins, because the person pressing
///  Save is the one looking at the screen.
///
///  Lists of objects are matched on an identity key ('id', 'model', ...) so
///  two people adding rows to one list both keep their rows, and a row one of
///  them deleted stays deleted unless the other one edited it meanwhile.
/// ============================================================================

/// Which side's value a conflict is settled with.
enum MergeSide { mine, theirs }

/// One place both people changed, differently.
class MergeConflict {
  /// Where in the document, as a readable path: `rooms[id=r3].name`.
  final String path;
  final Object? base;
  final Object? mine;
  final Object? theirs;

  const MergeConflict({
    required this.path,
    required this.base,
    required this.mine,
    required this.theirs,
  });

  @override
  String toString() => 'MergeConflict($path: base=${describeJsonValue(base)}, '
      'mine=${describeJsonValue(mine)}, theirs=${describeJsonValue(theirs)})';
}

class JsonMergeResult {
  final Object? merged;
  final List<MergeConflict> conflicts;

  /// How many places took the other person's change without a conflict.
  final int takenFromTheirs;

  const JsonMergeResult(this.merged, this.conflicts, this.takenFromTheirs);

  bool get clean => conflicts.isEmpty;
}

/// Identity keys a list of objects is matched on, in order of preference.
const kMergeIdentityKeys = [
  'id',
  'uid',
  'key',
  'model',
  'configPath',
  'path',
  'name',
];

/// Merges [mine] and [theirs], both edited from [base].
///
/// [resolve] settles each conflict; without it MINE wins. It is called once
/// per conflict, with the conflict's path, so a dialog's answers can be fed
/// back in by path.
JsonMergeResult mergeJson3(
  Object? base,
  Object? mine,
  Object? theirs, {
  MergeSide Function(MergeConflict conflict)? resolve,
}) {
  final m = _Merger(resolve);
  final merged = m.merge(base, mine, theirs, '');
  return JsonMergeResult(merged, m.conflicts, m.taken);
}

/// True when two decoded JSON values are the same document.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if (!jsonEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// A short, human reading of a value for a conflict dialog.
String describeJsonValue(Object? v, {int max = 80}) {
  if (v == null) return '(none)';
  final text = v is String ? v : jsonEncode(v);
  if (text.isEmpty) return '(blank)';
  return text.length > max ? '${text.substring(0, max - 1)}…' : text;
}

/// The sentinel for "this key or row is absent", distinct from a JSON null.
const Object _absent = _Absent();

class _Absent {
  const _Absent();
}

class _Merger {
  final MergeSide Function(MergeConflict)? resolve;
  final conflicts = <MergeConflict>[];
  int taken = 0;

  _Merger(this.resolve);

  Object? _out(Object? v) => identical(v, _absent) ? null : v;

  Object? merge(Object? base, Object? mine, Object? theirs, String at) {
    if (jsonEquals(mine, theirs)) return mine;
    if (jsonEquals(base, mine)) {
      taken++;
      return theirs;
    }
    if (jsonEquals(base, theirs)) return mine;

    // An id counter both sides moved on: the higher one, so neither side's
    // new ids are handed out again.
    if (mine is int && theirs is int && at.toLowerCase().endsWith('counter')) {
      return mine > theirs ? mine : theirs;
    }

    // Both changed it. Structures can still be merged part by part.
    if (mine is Map && theirs is Map && (base is Map || _isAbsent(base))) {
      return _mergeMaps(base is Map ? base : const {}, mine, theirs, at);
    }
    if (mine is List && theirs is List && (base is List || _isAbsent(base))) {
      final merged = _mergeLists(base is List ? base : const [], mine, theirs, at);
      if (merged != null) return merged;
    }
    return _conflict(at, base, mine, theirs);
  }

  bool _isAbsent(Object? v) => identical(v, _absent) || v == null;

  Object? _conflict(String at, Object? base, Object? mine, Object? theirs) {
    final c = MergeConflict(
      path: at.isEmpty ? '(whole document)' : at,
      base: _out(base),
      mine: _out(mine),
      theirs: _out(theirs),
    );
    conflicts.add(c);
    final side = resolve?.call(c) ?? MergeSide.mine;
    return side == MergeSide.mine ? mine : theirs;
  }

  Map<String, dynamic> _mergeMaps(Map base, Map mine, Map theirs, String at) {
    final out = <String, dynamic>{};
    // Mine's key order first, then any key only they added - so a merged file
    // reads in the order the person saving it is used to.
    final keys = <Object?>[
      ...mine.keys,
      for (final k in theirs.keys)
        if (!mine.containsKey(k)) k,
    ];
    for (final k in keys) {
      final b = base.containsKey(k) ? base[k] : _absent;
      final m = mine.containsKey(k) ? mine[k] : _absent;
      final t = theirs.containsKey(k) ? theirs[k] : _absent;
      final v = merge(b, m, t, at.isEmpty ? '$k' : '$at.$k');
      if (!identical(v, _absent)) out['$k'] = v;
    }
    return out;
  }

  /// Merges two lists of objects row by row, or two lists of plain values as
  /// sets. Null when the lists have no usable identity - the caller then
  /// treats the whole list as one value.
  List? _mergeLists(List base, List mine, List theirs, String at) {
    final all = [...base, ...mine, ...theirs];
    if (all.isEmpty) return mine;

    if (all.every((e) => e is Map)) {
      final key = _identityKey(base, mine, theirs);
      if (key != null) return _mergeKeyed(key, base, mine, theirs, at);
      return _mergeAppendOnly(base, mine, theirs);
    }

    if (all.every((e) => e is String || e is num || e is bool)) {
      // A set: tags, dismissed ids, picked options. Only a set if nobody's
      // copy repeats a value - otherwise order and count mean something.
      bool unique(List l) => l.toSet().length == l.length;
      if (!unique(base) || !unique(mine) || !unique(theirs)) {
        return _mergeAppendOnly(base, mine, theirs);
      }
      final baseSet = base.toSet();
      final theirSet = theirs.toSet();
      final removedByThem = baseSet.difference(theirSet);
      final out = [
        for (final v in mine)
          if (!removedByThem.contains(v)) v,
        for (final v in theirs)
          if (!baseSet.contains(v) && !mine.contains(v)) v,
      ];
      if (!jsonEquals(out, mine)) taken++;
      return out;
    }
    return null;
  }

  /// A log both sides only appended to - a history, a list of notes - keeps
  /// both sides' new entries, theirs after mine. Null for anything else.
  List? _mergeAppendOnly(List base, List mine, List theirs) {
    bool startsWithBase(List l) {
      if (l.length < base.length) return false;
      for (var i = 0; i < base.length; i++) {
        if (!jsonEquals(l[i], base[i])) return false;
      }
      return true;
    }

    if (!startsWithBase(mine) || !startsWithBase(theirs)) return null;
    taken++;
    return [
      ...mine,
      ...theirs.sublist(base.length),
    ];
  }

  String? _identityKey(List base, List mine, List theirs) {
    for (final key in kMergeIdentityKeys) {
      bool ok(List l) {
        final seen = <String>{};
        for (final e in l) {
          final v = (e as Map)[key];
          if (v == null || '$v'.isEmpty) return false;
          if (!seen.add('$v')) return false;
        }
        return true;
      }

      if (ok(base) && ok(mine) && ok(theirs)) return key;
    }
    return null;
  }

  List _mergeKeyed(String key, List base, List mine, List theirs, String at) {
    Map<String, Map> index(List l) => {
          for (final e in l) '${(e as Map)[key]}': e,
        };
    final b = index(base);
    final m = index(mine);
    final t = index(theirs);

    final out = <Object?>[];
    void put(String id) {
      final v = merge(
        b[id] ?? _absent,
        m[id] ?? _absent,
        t[id] ?? _absent,
        '$at[$key=$id]',
      );
      if (!identical(v, _absent)) out.add(v);
    }

    // Mine's order, with each row they added slotted in after the row it
    // followed in their copy.
    final theirsAdded = <String, List<String>>{};
    String? prev;
    final leading = <String>[];
    for (final e in theirs) {
      final id = '${(e as Map)[key]}';
      if (!m.containsKey(id) && !b.containsKey(id)) {
        if (prev == null) {
          leading.add(id);
        } else {
          (theirsAdded[prev] ??= []).add(id);
        }
      } else {
        prev = id;
      }
    }
    leading.forEach(put);
    final placed = <String>{...leading};
    for (final e in mine) {
      final id = '${(e as Map)[key]}';
      put(id);
      placed.add(id);
      for (final added in theirsAdded[id] ?? const <String>[]) {
        put(added);
        placed.add(added);
      }
    }
    // Rows in theirs whose anchor is not in mine, and rows only in base (so
    // [merge] can decide a delete-versus-edit).
    for (final e in [...theirs, ...base]) {
      final id = '${(e as Map)[key]}';
      if (placed.add(id)) put(id);
    }
    return out;
  }
}

/// Deep-copies a decoded JSON value, normalizing maps to `Map<String, dynamic>`.
Object? cloneJson(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) '${e.key}': cloneJson(e.value),
    };
  }
  if (v is List) return [for (final e in v) cloneJson(e)];
  return v;
}
