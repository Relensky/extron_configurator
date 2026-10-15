import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'app_state.dart' show kSchematicIdf, kSchematicProcessor;
import 'schematic_view.dart';

/// ============================================================================
///  TIDY SCHEMATIC
/// ============================================================================
///  The control schematic is a hub: the processor in the middle, everything
///  it talks to around it. Tidy puts it back that way with nothing touching -
///  the processor (and the network IDF beside it) in the centre, the devices
///  evenly round a full circle, grouped by how they connect.
///
///  A circle of forty is a circle nobody can read, so past
///  [kSchematicRingMost] devices are laid out as a table under the hub
///  instead: even rows and columns.
/// ============================================================================

/// More devices than this and they go in a table rather than a circle.
const int kSchematicRingMost = 16;

/// Space between two boxes, around the circle and in the table.
const double kSchematicGap = 50;

/// Where each box goes: id -> new top-left.
Map<String, Offset> tidySchematic(List<SchematicNode> nodes) {
  final hub = nodes.where((n) => n.id == kSchematicProcessor).firstOrNull;
  final idf = nodes.where((n) => n.id == kSchematicIdf).firstOrNull;
  final ring = [
    for (final n in nodes)
      if (n != hub && n != idf) n,
  ]..sort((a, b) {
      // Like with like: the serial devices together, the network ones...
      final byConn = a.conn.index.compareTo(b.conn.index);
      if (byConn != 0) return byConn;
      if (a.related != b.related) return a.related ? 1 : -1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

  final out = <String, Offset>{};
  const w = kNodeWidth, h = kNodeHeight;

  if (ring.length <= kSchematicRingMost) {
    // Big enough round that neighbours do not touch: the circumference has
    // room for every box's diagonal plus a gap.
    final diagonal = math.sqrt(w * w + h * h);
    final radius = math.max(
      300.0,
      ring.length * (diagonal + kSchematicGap) / (2 * math.pi),
    );
    final centre = Offset(radius + w, radius + h);
    if (hub != null) out[hub.id] = centre - const Offset(w / 2, h / 2);
    if (idf != null) {
      out[idf.id] = centre - Offset(w / 2, h / 2 - h - kSchematicGap / 2);
    }
    for (final (i, n) in ring.indexed) {
      // From the top, clockwise.
      final angle = -math.pi / 2 + 2 * math.pi * i / math.max(1, ring.length);
      final at = centre +
          Offset(math.cos(angle) * radius, math.sin(angle) * radius);
      out[n.id] = at - const Offset(w / 2, h / 2);
    }
    return out;
  }

  // The table: the hub on top, centred over even rows and columns.
  final columns = math.sqrt(ring.length * 1.6).ceil();
  final tableWidth = columns * w + (columns - 1) * kSchematicGap;
  const left = 40.0, top = 40.0;
  if (hub != null) out[hub.id] = Offset(left + (tableWidth - w) / 2, top);
  if (idf != null) {
    out[idf.id] = Offset(left + (tableWidth - w) / 2 + w + kSchematicGap, top);
  }
  final firstRow = top + h + kSchematicGap * 2;
  for (final (i, n) in ring.indexed) {
    final row = i ~/ columns, col = i % columns;
    out[n.id] = Offset(
      left + col * (w + kSchematicGap),
      firstRow + row * (h + kSchematicGap),
    );
  }
  return out;
}
