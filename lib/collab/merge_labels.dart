/// ============================================================================
///  NAMING THE PLACES TWO PEOPLE BOTH CHANGED
/// ============================================================================
///  The merge finds conflicts by path - `todos[id=todo7].text` - which means
///  nothing to the person choosing. Here each step is named the way the app
///  names it: the list as it is called on screen, the row by what it says,
///  the field in words.
/// ============================================================================
library;

import 'dart:convert';

/// What the lists and fields of the project and room files are called on
/// screen. Anything not here is turned from camelCase into words.
const Map<String, String> _kNames = {
  'todos': 'Job list',
  'procurement': 'Procurement log',
  'rooms': 'Rooms',
  'manualRooms': 'Line-item rooms',
  'vendors': 'Vendors',
  'rfqs': 'Quotes',
  'spares': 'Spares',
  'plans': 'Drawings',
  'purchaseOrders': 'Purchase orders',
  'deliveries': 'Deliveries',
  'responsibility': 'Responsibility matrix',
  'budgetLines': 'Budget',
  'installWindows': 'Install windows',
  'tracks': 'Schedule tracks',
  'partLeadTimes': 'Lead times',
  'partNeedBy': 'Needed-by dates',
  'partOrders': 'Orders',
  'partRfqs': 'Package tags',
  'procurementColumnLabels': 'Procurement column titles',
  'procurementCustomColumns': 'Procurement columns',
  'nodes': 'Drawing',
  'cables': 'Cables',
  'racks': 'Racks',
  'rackItems': 'Rack hardware',
  'cost': 'Cost',
  'config': 'Settings',
  'av': 'AV drawing',
  'SYSTEM_SETUP': 'System setup',
  'text': 'Text',
  'notes': 'Notes',
  'label': 'Name',
  'name': 'Name',
  'due': 'Due date',
  'state': 'Status',
  'qty': 'Quantity',
  'taxPercent': 'Tax rate',
  'taxOwn': 'Own tax rate',
  'taxBase': 'Base tax rate',
  'budget': 'Budget',
};

/// The fields a row is best known by, first choice first.
const List<String> _kRowNames = [
  'text',
  'label',
  'name',
  'title',
  'scope',
  'device',
  'description',
  'model',
  'item',
  'roomCode',
  'code',
];

/// [path] in words, with rows named from [doc] - the document as this copy
/// holds it. `todos[id=todo7].text` -> `Job list > "chase Extron" > Text`.
String describeMergePlace(String path, Object? doc) {
  if (path == '(whole document)') return 'The whole file';
  final parts = <String>[];
  Object? at = doc;
  var first = true;
  for (final step in _steps(path)) {
    final row = RegExp(r'^(.*)\[(\w+)=(.*)\]$').firstMatch(step);
    if (row == null) {
      // A map keyed by room id (roomSnapshots.room10) is named by the room.
      final room = first ? null : _roomName(doc, step);
      parts.add(room ?? _word(step));
      at = at is Map ? at[step] : null;
      first = false;
      continue;
    }
    first = false;
    if (row.group(1) == 'rooms' && row.group(2) == 'id') {
      final room = _roomName(doc, row.group(3)!);
      if (room != null) {
        parts
          ..add(_word('rooms'))
          ..add(room);
        final list = at is Map ? at['rooms'] : null;
        at = null;
        if (list is List) {
          for (final e in list) {
            if (e is Map && '${e['id']}' == row.group(3)) at = e;
          }
        }
        continue;
      }
    }
    final list = row.group(1)!;
    if (list.isNotEmpty) {
      parts.add(_word(list));
      at = at is Map ? at[list] : null;
    }
    final key = row.group(2)!;
    final id = row.group(3)!;
    Map? found;
    if (at is List) {
      for (final e in at) {
        if (e is Map && '${e[key]}' == id) found = e;
      }
    }
    parts.add(found == null ? id : _rowName(found, id));
    at = found;
  }
  return parts.join(' > ');
}

/// Splits on dots that are not inside a [key=value].
List<String> _steps(String path) {
  final out = <String>[];
  final b = StringBuffer();
  var depth = 0;
  for (final c in path.split('')) {
    if (c == '[') depth++;
    if (c == ']') depth--;
    if (c == '.' && depth == 0) {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(c);
    }
  }
  if (b.isNotEmpty) out.add(b.toString());
  return out;
}

String _rowName(Map row, String fallback) {
  for (final k in _kRowNames) {
    final v = row[k];
    if (v is String && v.trim().isNotEmpty) {
      final t = v.trim().split('\n').first;
      return '"${t.length > 40 ? '${t.substring(0, 39)}…' : t}"';
    }
  }
  // A job's room is known by the folder its config is in: BSS_103, not room10.
  final config = row['configPath'];
  if (config is String && config.trim().isNotEmpty) {
    final parts = config.replaceAll(r'\', '/').split('/')
      ..removeWhere((p) => p.isEmpty);
    if (parts.length >= 2) return '"${parts[parts.length - 2]}"';
    return '"${parts.last}"';
  }
  return fallback;
}

/// A job's room by its label and id - `"BSS 103" (room10)` - or null when
/// [id] is not a room on [doc]. No label falls back to the config's folder.
String? _roomName(Object? doc, String id) {
  final rooms = doc is Map ? doc['rooms'] : null;
  if (rooms is! List) return null;
  for (final r in rooms) {
    if (r is! Map || '${r['id']}' != id) continue;
    final label = '${r['label'] ?? ''}'.trim();
    final name = label.isNotEmpty ? '"$label"' : _rowName(r, '');
    return name.isEmpty ? id : '$name ($id)';
  }
  return null;
}

/// A field's key in words: `partNumber` -> `Part number`.
String describeMergeField(String key) => _word(key);

String _word(String key) {
  final known = _kNames[key];
  if (known != null) return known;
  final spaced = key
      .replaceAllMapped(RegExp(r'(?<=[a-z0-9])([A-Z])'), (m) => ' ${m[1]}')
      .replaceAll('_', ' ')
      .trim();
  if (spaced.isEmpty) return key;
  return spaced[0].toUpperCase() + spaced.substring(1).toLowerCase();
}

/// True for a place that holds a tax rate - a job's, or a room's own rate,
/// whether it has one, and the base rate it was saved at.
bool isTaxMergePath(String path) =>
    const {'taxPercent', 'taxOwn', 'taxBase'}.contains(path.split('.').last);

/// True for the room totals a job keeps for itself (see
/// BuildingProject.roomSnapshots). Each copy re-prices them at its own
/// catalog prices, so a difference there is no reason to ask anybody to
/// combine.
bool isBookkeepingMergePath(String path) {
  final top = path.split(RegExp(r'[.\[]')).first;
  return top == 'roomSnapshots' || top == 'roomsCheckedAt';
}

/// A tax rate as a person reads it: '9.25%', or what having none means.
String describeTaxRate(Object? v) {
  if (v is num) {
    final text = v == v.roundToDouble()
        ? v.toInt().toString()
        : v.toString();
    return '$text%';
  }
  if (v is bool) return v ? 'its own rate' : 'the base rate';
  return 'not set';
}

/// One side's value as a person reads it: a deleted thing says so, a row
/// says what it is, text is shown as typed.
String describeMergeValue(Object? v) {
  if (v == null) return 'deleted';
  if (v is Map) return _rowName(v, 'an entry');
  if (v is List) return '${v.length} item${v.length == 1 ? '' : 's'}';
  if (v is String) {
    if (v.trim().isEmpty) return '(blank)';
    return v.length > 120 ? '${v.substring(0, 119)}…' : v;
  }
  return '$v';
}

/// What one change did, line by line: each row added, removed or changed and
/// each field's value before and after - never just "500 items, now 501".
String describeMergeChange(Object? before, Object? after) {
  if (before == null) return 'added: ${describeMergeValue(after)}';
  if (after == null) return 'removed (was ${describeMergeValue(before)})';
  final lines = <String>[];
  _diff(before, after, '', lines);
  if (lines.isEmpty) {
    return 'was ${describeMergeValue(before)}, now '
        '${describeMergeValue(after)}';
  }
  return lines.join('\n');
}

String _json(Object? v) {
  try {
    return jsonEncode(v);
  } catch (_) {
    return '$v';
  }
}

void _diff(Object? a, Object? b, String at, List<String> out) {
  if (_json(a) == _json(b)) return;
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      final name = '$at${_word('$k')}';
      if (!a.containsKey(k)) {
        out.add('$name: added ${describeMergeValue(b[k])}');
      } else if (!b.containsKey(k)) {
        out.add('$name: removed (was ${describeMergeValue(a[k])})');
      } else {
        _diff(a[k], b[k], '$name > ', out);
      }
    }
    return;
  }
  if (a is List && b is List) {
    _diffList(a, b, at, out);
    return;
  }
  final where = at.isEmpty ? '' : '${at.substring(0, at.length - 3)}: ';
  out.add('$where${describeMergeValue(a)} -> ${describeMergeValue(b)}');
}

/// Rows with an id are matched by it; anything else by value.
void _diffList(List a, List b, String at, List<String> out) {
  String? idOf(Object? v) => v is Map && v['id'] != null ? '${v['id']}' : null;
  if (a.isNotEmpty &&
      b.isNotEmpty &&
      [...a, ...b].every((v) => idOf(v) != null)) {
    final before = {for (final v in a) idOf(v)!: v as Map};
    final after = {for (final v in b) idOf(v)!: v as Map};
    for (final id in {...before.keys, ...after.keys}) {
      final row = after[id] ?? before[id]!;
      final name = _rowName(row, id);
      if (!before.containsKey(id)) {
        out.add('${at}added $name');
      } else if (!after.containsKey(id)) {
        out.add('${at}removed $name');
      } else {
        _diff(before[id], after[id], '$at$name > ', out);
      }
    }
    final kept = [for (final v in b) idOf(v)!]
      ..removeWhere((id) => !before.containsKey(id));
    final was = [for (final v in a) idOf(v)!]
      ..removeWhere((id) => !after.containsKey(id));
    if (_json(kept) != _json(was)) out.add('${at}reordered');
    return;
  }
  // What is left of [a] once each of [b] has taken its match is removed.
  final removed = [...a];
  final removedJson = [for (final v in a) _json(v)];
  final added = <Object?>[];
  for (final v in b) {
    final i = removedJson.indexOf(_json(v));
    if (i < 0) {
      added.add(v);
    } else {
      removed.removeAt(i);
      removedJson.removeAt(i);
    }
  }
  for (final v in added) {
    out.add('${at}added ${describeMergeValue(v)}');
  }
  for (final v in removed) {
    out.add('${at}removed ${describeMergeValue(v)}');
  }
  if (added.isEmpty && removed.isEmpty) out.add('${at}reordered');
}
