import 'app_state.dart';
import 'av_flow_model.dart';

/// Tie in sequence: one side's connectors to the other's, in order. A side is
/// a set of boxes named in sequence ("Station 1" to "Station 12"), taking one
/// connector on each, or one box, taking a run of its numbered connectors
/// (a power strip's outlets, a switcher's inputs).

/// One side of a tie.
class TieSide {
  /// Stable id for a drop-down: 'group:station' or 'box:AVNODE_7'.
  final String key;
  final String label;

  /// In sequence order.
  final List<AvNode> boxes;

  const TieSide({required this.key, required this.label, required this.boxes});

  bool get isSingle => key.startsWith('box:');
}

/// [label] without the number it ends in: 'NAV Decoder Station 12' ->
/// 'NAV Decoder Station'.
String nameStem(String label) =>
    label.trim().replaceFirst(RegExp(r'\s*#?\s*\d+\s*$'), '').trim();

/// The number [label] ends in, or null.
int? nameNumber(String label) {
  final m = RegExp(r'(\d+)\s*$').firstMatch(label.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

int _bySequence(AvNode a, AvNode b) {
  final na = nameNumber(a.label), nb = nameNumber(b.label);
  if (na != null && nb != null && na != nb) return na - nb;
  return a.label.compareTo(b.label);
}

/// The sides on offer: every set of two or more boxes sharing a name stem,
/// then every single box.
List<TieSide> tieSides(AppStateProvider provider) {
  final groups = <String, List<AvNode>>{};
  for (final n in provider.avNodes) {
    if (nameNumber(n.label) == null) continue;
    final stem = nameStem(n.label);
    if (stem.isEmpty) continue;
    groups.putIfAbsent(stem.toLowerCase(), () => []).add(n);
  }
  final out = <TieSide>[
    for (final e in groups.entries)
      if (e.value.length > 1)
        TieSide(
          key: 'group:${e.key}',
          label: '${nameStem(e.value.first.label)} (${e.value.length})',
          boxes: [...e.value]..sort(_bySequence),
        ),
  ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  final singles = [...provider.avNodes]
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  for (final n in singles) {
    out.add(TieSide(key: 'box:${n.id}', label: n.label, boxes: [n]));
  }
  return out;
}

bool _canSend(AvPort p) => p.direction != PortDirection.input;
bool _canTake(AvPort p) => p.direction != PortDirection.output;

/// A connector choice on a side: one label on each box of a set, or a
/// family of numbered connectors on one box ('OUTLET' for OUTLET 1 to 8).
class TieConnector {
  final String key;
  final String label;
  final SignalType signal;
  const TieConnector(this.key, this.label, this.signal);
}

/// The family a numbered connector belongs to: 'OUTLET 3' -> 'OUTLET'.
String _family(AvPort p) =>
    basePortLabel(p.label).replaceFirst(RegExp(r'\s*\d+[A-Za-z]?\s*$'), '');

/// The connectors [side] could tie on, sending when [sending].
List<TieConnector> tieConnectors(TieSide side, {required bool sending}) {
  bool ok(AvPort p) => sending ? _canSend(p) : _canTake(p);
  if (side.isSingle) {
    final seen = <String, TieConnector>{};
    final counts = <String, int>{};
    for (final p in side.boxes.single.ports.where(ok)) {
      final fam = _family(p);
      final key = '${p.signal.name}|$fam';
      counts[key] = (counts[key] ?? 0) + 1;
      seen.putIfAbsent(key, () => TieConnector(key, fam, p.signal));
    }
    return [
      for (final e in seen.entries)
        TieConnector(
          e.key,
          '${e.value.label.isEmpty ? kSignalLabels[e.value.signal] : e.value.label}'
          '${counts[e.key]! > 1 ? ' (${counts[e.key]})' : ''}',
          e.value.signal,
        ),
    ];
  }
  // A set of boxes: the labels the first box has, by label.
  return [
    for (final p in side.boxes.first.ports.where(ok))
      TieConnector('${p.signal.name}|${basePortLabel(p.label)}',
          basePortLabel(p.label), p.signal),
  ];
}

/// The ports [connector] means on each box of [side], in sequence.
List<({AvNode node, AvPort port})> _sockets(
    TieSide side, TieConnector connector, bool sending) {
  bool ok(AvPort p) => sending ? _canSend(p) : _canTake(p);
  if (side.isSingle) {
    final box = side.boxes.single;
    final ports = box.ports
        .where((p) =>
            ok(p) && '${p.signal.name}|${_family(p)}' == connector.key)
        .toList();
    final indexed = [for (final (i, p) in ports.indexed) (i, p)]
      ..sort((a, b) {
        final na = nameNumber(basePortLabel(a.$2.label));
        final nb = nameNumber(basePortLabel(b.$2.label));
        if (na != null && nb != null && na != nb) return na - nb;
        return a.$1 - b.$1;
      });
    return [for (final e in indexed) (node: box, port: e.$2)];
  }
  return [
    for (final box in side.boxes)
      if (box.ports
              .where((p) =>
                  ok(p) &&
                  '${p.signal.name}|${basePortLabel(p.label)}' ==
                      connector.key)
              .firstOrNull
          case final port?)
        (node: box, port: port),
  ];
}

/// A single box's run of [connector], in number order.
List<AvPort> tieRunPorts(TieSide side, TieConnector connector,
        {required bool sending}) =>
    [for (final s in _sockets(side, connector, sending)) s.port];

/// One tie the dialog would draw, and what is on its connectors now.
class PlannedTie {
  final AvNode from;
  final AvPort fromPort;
  final AvNode to;
  final AvPort toPort;

  /// What the tie would take off: 'Station 3 (HDMI 1)'. Empty when both
  /// connectors are free or already joined to each other.
  final List<String> replaces;
  final bool alreadyTied;

  const PlannedTie({
    required this.from,
    required this.fromPort,
    required this.to,
    required this.toPort,
    this.replaces = const [],
    this.alreadyTied = false,
  });
}

/// The ties from [from]'s [fromConnector] to [to]'s [toConnector]. Two sets
/// pair by the number their names end in when [byNumber], otherwise in
/// order; a single box's run starts at its [fromStart]th / [toStart]th
/// connector (0-based).
List<PlannedTie> planTies(
  AppStateProvider provider, {
  required TieSide from,
  required TieConnector fromConnector,
  required TieSide to,
  required TieConnector toConnector,
  bool byNumber = true,
  int fromStart = 0,
  int toStart = 0,
}) {
  var a = _sockets(from, fromConnector, true);
  var b = _sockets(to, toConnector, false);
  if (from.isSingle) a = a.skip(fromStart).toList();
  if (to.isSingle) b = b.skip(toStart).toList();

  final pairs = <(({AvNode node, AvPort port}), ({AvNode node, AvPort port}))>[];
  if (!from.isSingle && !to.isSingle && byNumber) {
    final byNum = {
      for (final s in b) ?nameNumber(s.node.label): s,
    };
    for (final s in a) {
      final n = nameNumber(s.node.label);
      final match = n == null ? null : byNum[n];
      if (match != null) pairs.add((s, match));
    }
  } else {
    for (var i = 0; i < a.length && i < b.length; i++) {
      pairs.add((a[i], b[i]));
    }
  }

  String name(String node, String port) {
    final n = provider.avNodeById(node);
    return '${n?.label ?? node} (${n?.portById(port)?.label ?? port})';
  }

  final out = <PlannedTie>[];
  for (final (s, d) in pairs) {
    if (s.node.id == d.node.id) continue;
    var tied = false;
    final replaces = <String>[];
    for (final c in provider.avCables) {
      final joinsBoth = (c.fromNodeId == s.node.id &&
              c.fromPortId == s.port.id &&
              c.toNodeId == d.node.id &&
              c.toPortId == d.port.id) ||
          (c.toNodeId == s.node.id &&
              c.toPortId == s.port.id &&
              c.fromNodeId == d.node.id &&
              c.fromPortId == d.port.id);
      if (joinsBoth) {
        tied = true;
        continue;
      }
      for (final end in [s, d]) {
        if (c.fromNodeId == end.node.id && c.fromPortId == end.port.id) {
          replaces.add(name(c.toNodeId, c.toPortId));
        } else if (c.toNodeId == end.node.id && c.toPortId == end.port.id) {
          replaces.add(name(c.fromNodeId, c.fromPortId));
        }
      }
    }
    out.add(PlannedTie(
      from: s.node,
      fromPort: s.port,
      to: d.node,
      toPort: d.port,
      replaces: replaces,
      alreadyTied: tied,
    ));
  }
  return out;
}

/// Boxes a power lead could go to: anything with a power inlet.
List<({AvNode node, AvPort port})> poweredBoxes(AppStateProvider provider) {
  final out = <({AvNode node, AvPort port})>[];
  for (final n in provider.avNodes) {
    final inlet = n.ports
        .where((p) => p.signal == SignalType.power && _canTake(p))
        .firstOrNull;
    if (inlet != null) out.add((node: n, port: inlet));
  }
  out.sort((a, b) => _bySequence(a.node, b.node));
  return out;
}

/// Boxes with two or more power outlets: strips, PDUs, power controllers.
List<AvNode> powerStrips(AppStateProvider provider) => [
      for (final n in provider.avNodes)
        if (n.ports
                .where((p) => p.signal == SignalType.power && _canSend(p))
                .length >
            1)
          n,
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

/// [strip]'s outlets in number order.
List<AvPort> stripOutlets(AvNode strip) {
  final ports = [
    for (final (i, p) in strip.ports.indexed)
      if (p.signal == SignalType.power && _canSend(p)) (i, p),
  ]..sort((a, b) {
      final na = nameNumber(basePortLabel(a.$2.label));
      final nb = nameNumber(basePortLabel(b.$2.label));
      if (na != null && nb != null && na != nb) return na - nb;
      return a.$1 - b.$1;
    });
  return [for (final e in ports) e.$2];
}

/// The box on the far end of [outlet] of [strip], if any.
String? outletTarget(AppStateProvider provider, AvNode strip, AvPort outlet) {
  for (final c in provider.avCables) {
    if (c.fromNodeId == strip.id && c.fromPortId == outlet.id) {
      return c.toNodeId;
    }
    if (c.toNodeId == strip.id && c.toPortId == outlet.id) return c.fromNodeId;
  }
  return null;
}
