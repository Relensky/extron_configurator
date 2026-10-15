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
///  Within a column the boxes keep the order they were in, top to bottom, so
///  a tidy does not shuffle what somebody arranged.
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

/// Where every box goes: id -> new top-left. Nothing overlaps.
Map<String, Offset> tidyAvLayout(
  List<AvNode> nodes,
  AvDeviceLibrary library,
) {
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
