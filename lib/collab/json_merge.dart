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

/// Which side's value a conflict is settled with. [both] keeps the two -
/// see [MergeConflict.canKeepBoth].
enum MergeSide { mine, theirs, both }

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

  /// True when nothing has to be thrown away: two pieces of text are kept
  /// one after the other, and a thing one side deleted and the other changed
  /// is kept with the change.
  ///
  /// TEXT MEANS WORDS. Two notes can sit one after the other; two room
  /// numbers or two model codes cannot - '103 / 104' is neither - so a value
  /// with no space in it is chosen between, never joined.
  bool get canKeepBoth =>
      (mine is String &&
          theirs is String &&
          ((mine as String).trim().contains(' ') ||
              (theirs as String).trim().contains(' '))) ||
      mine == null ||
      theirs == null;

  @override
  String toString() => 'MergeConflict($path: base=${describeJsonValue(base)}, '
      'mine=${describeJsonValue(mine)}, theirs=${describeJsonValue(theirs)})';
}

/// One change taken from the other person's copy: where, what this copy had
/// (null when it had nothing there - an addition), and what it becomes.
class MergeChange {
  final String path;
  final Object? before;
  final Object? after;
  const MergeChange(this.path, this.before, this.after);

  bool get added => before == null;
  bool get removed => after == null;
}

class JsonMergeResult {
  final Object? merged;
  final List<MergeConflict> conflicts;

  /// How many places took the other person's change without a conflict.
  final int takenFromTheirs;

  /// How many of their new rows were renumbered so both people's were kept.
  final int renumbered;

  /// Each change taken from theirs, for showing before it is applied.
  final List<MergeChange> changes;

  const JsonMergeResult(
    this.merged,
    this.conflicts,
    this.takenFromTheirs, [
    this.renumbered = 0,
    this.changes = const [],
  ]);

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

  /// This copy as it stood right after it was opened, when known. Opening
  /// fills in defaults the file did not have - a room number of '000' - and
  /// those are not this person's edits: where mine still matches it, their
  /// save wins without a question.
  Object? loaded = _unknown,
}) {
  // TWO NEW ROWS, ONE NUMBER. Ids are handed out from a counter, so two
  // people adding a note at once both make `todo7`. Merged as one row, one
  // note was lost. Their row is given the next free id first - along with
  // everything in their copy that pointed at it - so both are kept.
  final renames = <String, String>{};
  _findCollisions(base, mine, theirs, renames, _allStrings([base, mine, theirs]));
  final theirsKept = renames.isEmpty ? theirs : _renameAll(theirs, renames);
  final m = _Merger(resolve);
  final merged = m.merge(base, mine, theirsKept, '', loaded);
  return JsonMergeResult(
      merged, m.conflicts, m.taken, renames.length, m.changes);
}

/// "Not known" for [mergeJson3]'s loaded copy - distinct from a JSON null.
const Object _unknown = _Unknown();

class _Unknown {
  const _Unknown();
}

/// An id handed out from a counter: letters, then a number - `todo7`,
/// `proc12`, `room3`. Only these are renumbered on a collision; a row keyed
/// on a model or a name that both people added is the same thing, and its
/// fields merge.
final RegExp _counterId = RegExp(r'^([A-Za-z_]+)(\d+)$');

/// Finds rows both sides added under the same counter id with different
/// contents, and picks a new id for theirs in [renames].
void _findCollisions(
  Object? base,
  Object? mine,
  Object? theirs,
  Map<String, String> renames,
  Set<String> taken,
) {
  if (mine is Map && theirs is Map) {
    for (final k in mine.keys) {
      if (!theirs.containsKey(k)) continue;
      _findCollisions(
        base is Map ? base[k] : null,
        mine[k],
        theirs[k],
        renames,
        taken,
      );
    }
    return;
  }
  if (mine is! List || theirs is! List) return;
  final baseList = base is List ? base : const [];
  bool rows(List l) => l.every((e) => e is Map && e['id'] is String);
  if (!rows(mine) || !rows(theirs) || !rows(baseList)) return;
  final baseIds = {for (final e in baseList) (e as Map)['id'] as String};
  final mineById = {for (final e in mine) (e as Map)['id'] as String: e};
  for (final e in theirs) {
    final row = e as Map;
    final id = row['id'] as String;
    final ours = mineById[id];
    if (ours == null) continue;
    if (baseIds.contains(id)) {
      // The same row, edited: look inside it for lists of its own.
      final b = baseList.firstWhere((x) => (x as Map)['id'] == id);
      _findCollisions(b, ours, row, renames, taken);
      continue;
    }
    if (jsonEquals(ours, row)) continue;
    final m = _counterId.firstMatch(id);
    if (m == null || renames.containsKey(id)) continue;
    var n = int.parse(m.group(2)!);
    String next;
    do {
      next = '${m.group(1)}${++n}';
    } while (taken.contains(next));
    taken.add(next);
    renames[id] = next;
  }
}

/// Every string in [docs], keys and values - what a new id must not be.
Set<String> _allStrings(List<Object?> docs) {
  final out = <String>{};
  void walk(Object? v) {
    if (v is String) {
      out.add(v);
    } else if (v is Map) {
      for (final e in v.entries) {
        out.add('${e.key}');
        walk(e.value);
      }
    } else if (v is List) {
      v.forEach(walk);
    }
  }

  docs.forEach(walk);
  return out;
}

/// [doc] with every key and value exactly equal to an old id given its new
/// one - the row itself and anything that points at it (a note's room, a
/// part's package).
Object? _renameAll(Object? doc, Map<String, String> renames) {
  if (doc is String) return renames[doc] ?? doc;
  if (doc is Map) {
    return <String, dynamic>{
      for (final e in doc.entries)
        (renames['${e.key}'] ?? '${e.key}'): _renameAll(e.value, renames),
    };
  }
  if (doc is List) return [for (final e in doc) _renameAll(e, renames)];
  return doc;
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
  final changes = <MergeChange>[];
  int taken = 0;

  void _took(String at, Object? before, Object? after) {
    taken++;
    changes.add(MergeChange(
        at.isEmpty ? '(whole document)' : at, _out(before), _out(after)));
  }

  _Merger(this.resolve);

  Object? _out(Object? v) => identical(v, _absent) ? null : v;

  Object? merge(
    Object? base,
    Object? mine,
    Object? theirs,
    String at, [
    Object? loaded = _unknown,
  ]) {
    if (jsonEquals(mine, theirs)) return mine;
    if (jsonEquals(base, mine)) {
      _took(at, mine, theirs);
      return theirs;
    }
    if (jsonEquals(base, theirs)) return mine;
    // Untouched since it was opened: what opening filled in is not an edit,
    // so their save is taken over it.
    if (!identical(loaded, _unknown) &&
        !identical(theirs, _absent) &&
        jsonEquals(mine, loaded)) {
      _took(at, mine, theirs);
      return theirs;
    }

    // An id counter both sides moved on: the higher one, so neither side's
    // new ids are handed out again.
    if (mine is int && theirs is int && at.toLowerCase().endsWith('counter')) {
      return mine > theirs ? mine : theirs;
    }

    // Both changed it. Structures can still be merged part by part.
    if (mine is Map && theirs is Map && (base is Map || _isAbsent(base))) {
      return _mergeMaps(
        base is Map ? base : const {},
        mine,
        theirs,
        at,
        loaded,
      );
    }
    if (mine is List && theirs is List && (base is List || _isAbsent(base))) {
      final merged = _mergeLists(
        base is List ? base : const [],
        mine,
        theirs,
        at,
        loaded,
      );
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
    return switch (side) {
      MergeSide.mine => mine,
      MergeSide.theirs => theirs,
      MergeSide.both => _keepBoth(mine, theirs),
    };
  }

  /// Both sides' value: the one that was not deleted, or two texts together -
  /// on separate lines when either is long or already runs to several.
  Object? _keepBoth(Object? mine, Object? theirs) {
    if (_isAbsent(mine)) return theirs;
    if (_isAbsent(theirs)) return mine;
    if (mine is String && theirs is String) {
      if (mine.trim().isEmpty) return theirs;
      if (theirs.trim().isEmpty) return mine;
      final long = mine.contains('\n') ||
          theirs.contains('\n') ||
          mine.length + theirs.length > 80;
      return long ? '$mine\n$theirs' : '$mine / $theirs';
    }
    return theirs;
  }

  Map<String, dynamic> _mergeMaps(
    Map base,
    Map mine,
    Map theirs,
    String at, [
    Object? loaded = _unknown,
  ]) {
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
      final l = loaded is Map
          ? (loaded.containsKey(k) ? loaded[k] : _absent)
          : _unknown;
      final v = merge(b, m, t, at.isEmpty ? '$k' : '$at.$k', l);
      if (!identical(v, _absent)) out['$k'] = v;
    }
    return out;
  }

  /// Merges two lists of objects row by row, or two lists of plain values as
  /// sets. Null when the lists have no usable identity - the caller then
  /// treats the whole list as one value.
  List? _mergeLists(
    List base,
    List mine,
    List theirs,
    String at, [
    Object? loaded = _unknown,
  ]) {
    final all = [...base, ...mine, ...theirs];
    if (all.isEmpty) return mine;

    if (all.every((e) => e is Map)) {
      final key = _identityKey(base, mine, theirs);
      if (key != null) {
        return _mergeKeyed(key, base, mine, theirs, at, loaded);
      }
      return _mergeAppendOnly(base, mine, theirs, at);
    }

    if (all.every((e) => e is String || e is num || e is bool)) {
      // A set: tags, dismissed ids, picked options. Only a set if nobody's
      // copy repeats a value - otherwise order and count mean something.
      bool unique(List l) => l.toSet().length == l.length;
      if (!unique(base) || !unique(mine) || !unique(theirs)) {
        return _mergeAppendOnly(base, mine, theirs, at);
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
      if (!jsonEquals(out, mine)) _took(at, mine, out);
      return out;
    }
    return null;
  }

  /// A log both sides only appended to - a history, a list of notes - keeps
  /// both sides' new entries, theirs after mine. Null for anything else.
  List? _mergeAppendOnly(List base, List mine, List theirs, [String at = '']) {
    bool startsWithBase(List l) {
      if (l.length < base.length) return false;
      for (var i = 0; i < base.length; i++) {
        if (!jsonEquals(l[i], base[i])) return false;
      }
      return true;
    }

    if (!startsWithBase(mine) || !startsWithBase(theirs)) return null;
    final out = [
      ...mine,
      ...theirs.sublist(base.length),
    ];
    taken++;
    for (final row in theirs.sublist(base.length)) {
      changes.add(MergeChange(at.isEmpty ? '(whole document)' : at, null, row));
    }
    return out;
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

  List _mergeKeyed(
    String key,
    List base,
    List mine,
    List theirs,
    String at, [
    Object? loaded = _unknown,
  ]) {
    Map<String, Map> index(List l) => {
          for (final e in l) '${(e as Map)[key]}': e,
        };
    final b = index(base);
    final m = index(mine);
    final t = index(theirs);
    final l = loaded is List && loaded.every((e) => e is Map)
        ? index(loaded)
        : null;

    final out = <Object?>[];
    void put(String id) {
      final v = merge(
        b[id] ?? _absent,
        m[id] ?? _absent,
        t[id] ?? _absent,
        '$at[$key=$id]',
        l == null ? _unknown : (l[id] ?? _absent),
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
