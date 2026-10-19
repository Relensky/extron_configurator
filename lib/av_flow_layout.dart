import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'av_device_library.dart';
import 'av_flow_model.dart';

/// ============================================================================
///  TIDY LAYOUT
/// ============================================================================
///  Lays every box on the AV Flow out again so nothing overlaps, in the
///  order a signal reads: sources on the left, switching, then processing,
///  then the displays and projectors on the right.
///
///  A room with a dozen displays used to draw them as one column taller than
///  the screen. Past [kAvDestinationsPerColumn] they are drawn as a table on
///  the right instead - a few columns of a few rows - so the room still fits.
///
///  Within a column, boxes are put in the order that crosses the fewest
///  cables: each moves toward the boxes it is cabled to, and an order is only
///  kept when it really does cross fewer lines. Boxes with no cables, and a
///  drawing no reordering improves, keep the order they were in.
/// ============================================================================

/// More displays and projectors than this and they are laid out as a table.
const int kAvDestinationsPerColumn = 6;

/// Space between two boxes side by side in the destinations table.
const double kAvTableColumnGap = 120;

/// The columns the layout uses, left to right.
enum AvLayoutColumn { source, switching, processing, destination }

/// Which column [node] belongs in.
AvLayoutColumn avLayoutColumnFor(AvNode node, AvDeviceLibrary library) {
  final id = node.id;
  if (id.startsWith('AVSOURCE_INPUT_')) return AvLayoutColumn.source;
  if (id.startsWith('AVSOURCE_OUTPUT_') ||
      id.startsWith('PROJECTORDEVICE_') ||
      id.startsWith('SCREENDEVICE_')) {
    return AvLayoutColumn.destination;
  }
  if (id.startsWith('SWITCHERDEVICE_')) return AvLayoutColumn.switching;
  if (id.startsWith('DSPDEVICE_') || id.startsWith('RECORDERDEVICE_')) {
    return AvLayoutColumn.processing;
  }
  if (node.isJackField) return AvLayoutColumn.source;

  // Anything else by what the catalog calls it, then by its name.
  final category =
      (library.templateForModel(node.model)?.category ?? '').toLowerCase();
  final words = '$category ${node.model} ${node.label}'.toLowerCase();
  bool has(List<String> any) => any.any(words.contains);
  if (has(['display', 'projector', 'screen', 'monitor', ' tv', 'tv ',
      'receiver', ' rx'])) {
    return AvLayoutColumn.destination;
  }
  if (has(['switcher', 'matrix', 'scaler', 'presentation'])) {
    return AvLayoutColumn.switching;
  }
  if (has(['dsp', 'amplifier', 'amp ', 'recorder', 'audio', 'speaker'])) {
    return AvLayoutColumn.processing;
  }
  // A box with inputs and no outputs is where a signal ends.
  if (node.leftPorts.isNotEmpty && node.rightPorts.isEmpty) {
    return AvLayoutColumn.destination;
  }
  return AvLayoutColumn.source;
}

/// Where every box goes: id -> new top-left. Nothing overlaps. With
/// [cables], each column is ordered to cross as few of them as it can.
Map<String, Offset> tidyAvLayout(
  List<AvNode> nodes,
  AvDeviceLibrary library, {
  List<AvCable> cables = const [],
}) {
  final columns = {for (final c in AvLayoutColumn.values) c: <AvNode>[]};
  for (final n in nodes) {
    columns[avLayoutColumnFor(n, library)]!.add(n);
  }
  // The order they were in, top to bottom.
  for (final list in columns.values) {
    list.sort((a, b) {
      final y = a.pos.dy.compareTo(b.pos.dy);
      return y != 0 ? y : a.pos.dx.compareTo(b.pos.dx);
    });
  }
  if (cables.isNotEmpty) _uncross(columns, cables);
  return _place(columns);
}

/// How many pairs of [cables] cross, drawn straight between their
/// connectors with the boxes at [at].
int avLayoutCrossings(
  Map<String, AvNode> byId,
  Map<String, Offset> at,
  List<AvCable> cables,
) {
  final segs = <(Offset, Offset, AvCable)>[];
  for (final c in cables) {
    final from = byId[c.fromNodeId], to = byId[c.toNodeId];
    if (from == null || to == null || from.id == to.id) continue;
    segs.add((
      (at[from.id] ?? from.pos) + from.localAnchorOf(c.fromPortId),
      (at[to.id] ?? to.pos) + to.localAnchorOf(c.toPortId),
      c,
    ));
  }
  double turn(Offset a, Offset b, Offset c) =>
      (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  var n = 0;
  for (var i = 0; i < segs.length; i++) {
    for (var j = i + 1; j < segs.length; j++) {
      final (a, b, ca) = segs[i];
      final (c, d, cb) = segs[j];
      // Two runs off the same connector meet there; that is not a crossing.
      if ((ca.fromNodeId == cb.fromNodeId && ca.fromPortId == cb.fromPortId) ||
          (ca.toNodeId == cb.toNodeId && ca.toPortId == cb.toPortId)) {
        continue;
      }
      final d1 = turn(c, d, a), d2 = turn(c, d, b);
      final d3 = turn(a, b, c), d4 = turn(a, b, d);
      if (d1 * d2 < 0 && d3 * d4 < 0) n++;
    }
  }
  return n;
}

/// Reorders each column so its boxes sit level with what they are cabled to,
/// a sweep at a time, and keeps the order that crossed the fewest cables.
void _uncross(
  Map<AvLayoutColumn, List<AvNode>> columns,
  List<AvCable> cables,
) {
  final byId = {
    for (final list in columns.values)
      for (final n in list) n.id: n,
  };
  final runs = [
    for (final c in cables)
      if (byId.containsKey(c.fromNodeId) &&
          byId.containsKey(c.toNodeId) &&
          c.fromNodeId != c.toNodeId)
        c,
  ];
  if (runs.isEmpty) return;

  Map<AvLayoutColumn, List<AvNode>> copy() => {
    for (final e in columns.entries) e.key: [...e.value],
  };
  var best = copy();
  var fewest = avLayoutCrossings(byId, _place(columns), runs);

  // A couple of dozen sweeps settles any room this app draws.
  for (var sweep = 0; sweep < 24 && fewest > 0; sweep++) {
    final order = sweep.isEven
        ? AvLayoutColumn.values
        : AvLayoutColumn.values.reversed;
    for (final column in order) {
      final list = columns[column]!;
      if (list.length < 2) continue;
      final at = _place(columns);
      // Where each box's top would sit to put its connectors level with the
      // other ends of its runs, on average. Boxes with none stay put.
      final want = <String, double>{};
      for (final n in list) {
        var sum = 0.0, count = 0;
        for (final c in runs) {
          final String other, otherPort, ownPort;
          if (c.fromNodeId == n.id) {
            (other, otherPort, ownPort) = (c.toNodeId, c.toPortId, c.fromPortId);
          } else if (c.toNodeId == n.id) {
            (other, otherPort, ownPort) =
                (c.fromNodeId, c.fromPortId, c.toPortId);
          } else {
            continue;
          }
          final o = byId[other]!;
          sum += at[other]!.dy +
              o.localAnchorOf(otherPort).dy -
              n.localAnchorOf(ownPort).dy;
          count++;
        }
        want[n.id] = count == 0 ? at[n.id]!.dy : sum / count;
      }
      // Stable, so ties keep the order they had.
      final indexed = list.indexed.toList()
        ..sort((a, b) {
          final w = want[a.$2.id]!.compareTo(want[b.$2.id]!);
          return w != 0 ? w : a.$1.compareTo(b.$1);
        });
      list
        ..clear()
        ..addAll(indexed.map((e) => e.$2));
    }
    final now = avLayoutCrossings(byId, _place(columns), runs);
    if (now < fewest) {
      fewest = now;
      best = copy();
    }
  }
  for (final e in best.entries) {
    columns[e.key] = e.value;
  }
}

/// The columns laid out in their current order.
Map<String, Offset> _place(Map<AvLayoutColumn, List<AvNode>> columns) {
  final out = <String, Offset>{};
  var x = kAvAutoOriginX;

  // Each of the first three columns as a stack, as wide as its widest box.
  for (final column in [
    AvLayoutColumn.source,
    AvLayoutColumn.switching,
    AvLayoutColumn.processing,
  ]) {
    final list = columns[column]!;
    if (list.isEmpty) continue;
    var y = kAvAutoOriginY;
    var widest = 0.0;
    for (final n in list) {
      out[n.id] = Offset(x, y);
      y += n.height + kAvAutoRowGap;
      widest = math.max(widest, n.width);
    }
    // Room between columns for the runs - see [kAvAutoColumnPitch].
    x += math.max(kAvAutoColumnPitch, widest + 200);
  }

  // The displays: one stack, or a table once there are many.
  final dest = columns[AvLayoutColumn.destination]!;
  if (dest.isNotEmpty) {
    final tableColumns = dest.length <= kAvDestinationsPerColumn
        ? 1
        : math.min(
            (dest.length / kAvDestinationsPerColumn).ceil(),
            math.sqrt(dest.length).ceil(),
          );
    final rows = (dest.length / tableColumns).ceil();
    final widest = dest.fold<double>(0, (w, n) => math.max(w, n.width));
    var y = kAvAutoOriginY;
    for (var r = 0; r < rows; r++) {
      final row = [
        for (var c = 0; c < tableColumns; c++)
          if (r * tableColumns + c < dest.length) dest[r * tableColumns + c],
      ];
      var tallest = 0.0;
      for (final (c, n) in row.indexed) {
        out[n.id] = Offset(x + c * (widest + kAvTableColumnGap), y);
        tallest = math.max(tallest, n.height);
      }
      y += tallest + kAvAutoRowGap;
    }
  }
  return out;
}
