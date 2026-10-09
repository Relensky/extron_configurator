/// ============================================================================
///  SEQUENTIAL UNIT NAMES
/// ============================================================================
///  Several units on one estimate line - twelve SurgeX, two monitors - are
///  named "Base 1".."Base N", so each can be told apart on the floor plan,
///  the racks and the config. The base is the name typed on the estimate line
///  when there is one, else the name the units already share.
///
///  A unit given a name of its own ("Left PDU") is left alone and not counted.
///  Plain Dart, so the one-off project update in tool/ uses the same rules.
/// ============================================================================
library;

final RegExp _trailingNumber = RegExp(r'^(.*\S)\s+(\d+)$');

/// [label] is [base] or "[base] N".
bool isNamedFrom(String label, String base) {
  if (base.isEmpty) return false;
  if (label == base) return true;
  final m = _trailingNumber.firstMatch(label);
  return m != null && m.group(1) == base;
}

/// The number on the end of "[base] N", or null.
int? unitNumber(String label, String base) {
  final m = _trailingNumber.firstMatch(label);
  if (m == null || m.group(1) != base) return null;
  return int.tryParse(m.group(2)!);
}

/// The name most of [labels] go by, numbered or not, or null when there are
/// none. On a tie the longer name wins, so "USB-C HD 101" twice is
/// "USB-C HD 101", not "USB-C HD".
String? sharedUnitBase(Iterable<String> labels) {
  final list = [
    for (final l in labels)
      if (l.trim().isNotEmpty) l.trim(),
  ];
  final candidates = {
    for (final l in list) ...[l, ?_trailingNumber.firstMatch(l)?.group(1)],
  };
  String? best;
  var bestCount = 0;
  for (final base in candidates) {
    final count = list.where((l) => isNamedFrom(l, base)).length;
    if (count > bestCount ||
        (count == bestCount && best != null && base.length > best.length)) {
      best = base;
      bestCount = count;
    }
  }
  return best;
}

/// Unit id -> its new name, for the units on one line that need renaming.
///
/// [units] in drawing order. A unit with no number ahead of every numbered
/// one is the first of the series: the series is numbered again from 1, in
/// order. Otherwise the numbers already there are kept ("Screen 4",
/// "Screen 5" are config blocks 4 and 5), and a unit with no number, or one
/// sharing another's, goes on the end. Empty when fewer than two units go
/// by the base.
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

  final plain = <({String id, String label, int? number})>[];
  var head = false;
  for (final u in units) {
    final label = u.label.trim();
    final fromTyped = isNamedFrom(label, typed);
    if (!fromTyped && (shared == null || !isNamedFrom(label, shared))) continue;
    final number = unitNumber(label, fromTyped ? typed : shared!);
    if (number == null && plain.every((p) => p.number == null)) head = true;
    plain.add((id: u.id, label: u.label, number: number));
  }

  final out = <String, String>{};
  void name(({String id, String label, int? number}) u, String to) {
    if (u.label != to) out[u.id] = to;
  }

  if (plain.length < 2) return out;

  if (head) {
    // Numbered again from 1: the unnumbered head first, then the rest by
    // their numbers, then anything unnumbered behind them.
    final order = [...plain]
      ..sort((a, b) {
        int key(({String id, String label, int? number}) u) =>
            u.number ?? (plain.indexOf(u) < _firstNumbered(plain) ? 0 : 1 << 30);
        final byKey = key(a).compareTo(key(b));
        return byKey != 0 ? byKey : plain.indexOf(a).compareTo(plain.indexOf(b));
      });
    for (var i = 0; i < order.length; i++) {
      name(order[i], '$base ${i + 1}');
    }
    return out;
  }

  // Keep the numbers there; the unnumbered and the repeats go on the end.
  final taken = <int>{};
  final later = <({String id, String label, int? number})>[];
  for (final u in plain) {
    if (u.number != null && taken.add(u.number!)) {
      // Same number, and the line's name if that is new.
      name(u, '$base ${u.number}');
      continue;
    }
    later.add(u);
  }
  var next = taken.isEmpty ? 1 : taken.reduce((a, b) => a > b ? a : b) + 1;
  for (final u in later) {
    name(u, '$base ${next++}');
  }
  return out;
}

/// What [kept] goes back to when [removed] was the other unit of its series:
/// "Cam570 1" with "Cam570 2" taken off is "Cam570" again. Null when it
/// keeps its name - a 1 alone is a number that means nothing, but a
/// "Screen 4" is config block 4.
String? soleUnitName(String kept, String removed) {
  final m = _trailingNumber.firstMatch(kept.trim());
  if (m == null || m.group(2) != '1') return null;
  return isNamedFrom(removed.trim(), m.group(1)!) ? m.group(1) : null;
}

int _firstNumbered(List<({String id, String label, int? number})> plain) {
  final i = plain.indexWhere((u) => u.number != null);
  return i < 0 ? plain.length : i;
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
