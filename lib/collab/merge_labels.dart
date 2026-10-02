/// ============================================================================
///  NAMING THE PLACES TWO PEOPLE BOTH CHANGED
/// ============================================================================
///  The merge finds conflicts by path - `todos[id=todo7].text` - which means
///  nothing to the person choosing. Here each step is named the way the app
///  names it: the list as it is called on screen, the row by what it says,
///  the field in words.
/// ============================================================================
library;

/// What the lists and fields of the project and room files are called on
/// screen. Anything not here is turned from camelCase into words.
const Map<String, String> _kNames = {
  'todos': 'Job list',
  'procurement': 'Procurement log',
  'rooms': 'Rooms',
  'manualRooms': 'Line-item rooms',
  'vendors': 'Vendors',
  'rfqs': 'Packages',
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
];

/// [path] in words, with rows named from [doc] - the document as this copy
/// holds it. `todos[id=todo7].text` -> `Job list > "chase Extron" > Text`.
String describeMergePlace(String path, Object? doc) {
  if (path == '(whole document)') return 'The whole file';
  final parts = <String>[];
  Object? at = doc;
  for (final step in _steps(path)) {
    final row = RegExp(r'^(.*)\[(\w+)=(.*)\]$').firstMatch(step);
    if (row == null) {
      parts.add(_word(step));
      at = at is Map ? at[step] : null;
      continue;
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
  return fallback;
}

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
