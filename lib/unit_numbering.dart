/// ============================================================================
///  SEQUENTIAL UNIT NAMES
/// ============================================================================
///  Several units on one estimate line - twelve SurgeX, two monitors - are
///  named "<base> 1".."<base> N", so each can be told apart on the floor plan,
///  the racks and the config. The base is the name typed on the estimate line
///  when there is one, else the name the units already share.
///
///  A unit given a name of its own ("Left PDU") is left alone and not counted.
///  Plain Dart, so the one-off project update in tool/ uses the same rules.
/// ============================================================================
library;

final RegExp _trailingNumber = RegExp(r'^(.*\S)\s+(\d+)$');

/// [label] is [base] or "[base] <n>".
bool isNamedFrom(String label, String base) {
  if (base.isEmpty) return false;
  if (label == base) return true;
  final m = _trailingNumber.firstMatch(label);
  return m != null && m.group(1) == base;
}

/// The number on the end of "[base] <n>", or null.
int? unitNumber(String label, String base) {
  final m = _trailingNumber.firstMatch(label);
  if (m == null || m.group(1) != base) return null;
  return int.tryParse(m.group(2)!);
}

/// The name every one of [labels] goes by, numbered or not, or null when
/// they don't share one. "USB-C HD 101" twice is "USB-C HD 101", not
/// "USB-C HD": the full name is tried before the one without its number.
String? sharedUnitBase(Iterable<String> labels) {
  final list = [for (final l in labels) l.trim()];
  if (list.isEmpty || list.first.isEmpty) return null;
  final first = list.first;
  final candidates = [
    first,
    ?_trailingNumber.firstMatch(first)?.group(1),
  ];
  for (final base in candidates) {
    if (list.every((l) => isNamedFrom(l, base))) return base;
  }
  return null;
}

/// Unit id -> its new name, for the units on one line that need renaming.
///
/// [units] in drawing order. Units already numbered keep their order; the
/// rest follow in drawing order. Empty when fewer than two units go by the
/// base, since "Display 1" alone is a number that means nothing.
Map<String, String> sequentialUnitNames(
  List<({String id, String label})> units, {
  String lineName = '',
}) {
  final typed = lineName.trim();
  final others = [
    for (final u in units)
      if (!isNamedFrom(u.label.trim(), typed)) u.label.trim(),
  ];
  final shared = others.isEmpty ? null : sharedUnitBase(others);
  final base = typed.isNotEmpty ? typed : shared;
  if (base == null) return const {};

  final plain = <({String id, String label, int order, int number})>[];
  for (var i = 0; i < units.length; i++) {
    final label = units[i].label.trim();
    final fromTyped = isNamedFrom(label, typed);
    if (!fromTyped && (shared == null || !isNamedFrom(label, shared))) continue;
    final number = unitNumber(label, fromTyped ? typed : shared!);
    plain.add((
      id: units[i].id,
      label: units[i].label,
      order: i,
      number: number ?? 1 << 30,
    ));
  }
  if (plain.length < 2) return const {};
  plain.sort((a, b) {
    final byNumber = a.number.compareTo(b.number);
    return byNumber != 0 ? byNumber : a.order.compareTo(b.order);
  });

  final out = <String, String>{};
  for (var i = 0; i < plain.length; i++) {
    final name = '$base ${i + 1}';
    if (plain[i].label != name) out[plain[i].id] = name;
  }
  return out;
}

/// Of [units], the one to take off first when the count comes down: the
/// highest-numbered, else the last drawn. Null when [units] is empty.
String? lastNumberedUnit(
  List<({String id, String label})> units, {
  String lineName = '',
}) {
  if (units.isEmpty) return null;
  final typed = lineName.trim();
  final base = typed.isNotEmpty
      ? typed
      : sharedUnitBase([for (final u in units) u.label]) ?? '';
  var best = units.last;
  var bestNumber = -1;
  for (final u in units) {
    final n = unitNumber(u.label.trim(), base) ?? -1;
    if (n > bestNumber) {
      best = u;
      bestNumber = n;
    }
  }
  return best.id;
}
