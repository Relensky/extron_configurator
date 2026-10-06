import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';
import 'cost_estimate.dart' show RoomCostSettings, trimNumber;
import 'online_roundtrip.dart' show OnlineChange;
import 'project_estimate.dart';
import 'project_workbook.dart'
    show kRoomRowIdColumn, projectRoomTabNames, roomLineSections;
import 'room_sidecar.dart' show RoomSidecarPart;
import 'safe_write.dart';

/// ============================================================================
///  A ROOM'S QUANTITIES, BACK FROM ITS TAB
/// ============================================================================
///  Each room has a tab in the published copy, and the count on each line is
///  the one figure people change there: a projector the room is not getting,
///  a second display after all. Every other figure in the Sheet reads the
///  room's Qty cells - All Items, Parts by Room, Core Components and the
///  totals - so a count changed on a room's tab is already right everywhere
///  in the Sheet. This brings it back into the room's estimate on a pull.
///
///  WHAT COMES BACK. A changed Qty, a Qty cleared or set to 0, and a line
///  deleted from the tab. Each row carries its estimate line in the Row id
///  column; a row is matched by that and nothing else.
///
///  WHAT IT DOES TO THE ROOM, by the kind of line:
///   * a line added to the estimate by hand: its quantity changes, and at 0
///     or deleted the line comes off;
///   * a device counted off the drawing: the quantity becomes a typed one,
///     exactly as if it had been typed on the Cost tab; at 0 the line stays
///     at 0, because the device is still on the drawing;
///   * rack hardware placed in a frame and cable counted off the runs: not
///     changed - their count is the drawing. Those edits stay listed in the
///     history, to be made in the app.
/// ============================================================================

/// The column the count is read from.
const String _kQtyColumn = 'Qty';

/// The change kind a room line edit is listed under.
const String kRoomLineKind = 'room line';

/// One line whose count changed on its room's tab.
class RoomLineEdit {
  final String roomId;
  final String roomName;

  /// The room's config, absolute.
  final String configPath;

  /// The tab it was read from.
  final String tab;
  final String lineKey;
  final String description;

  /// What the estimate says, and what the tab says. Both include spares.
  final double from;
  final double to;

  /// Spares bought on the line, which a count typed on the tab includes.
  final double spares;

  /// True when the row was deleted from the tab.
  final bool removed;

  /// True for a device counted off the drawing; false for a line added by
  /// hand.
  final bool drawn;

  /// What the drawing counts, for a drawn line.
  final double onDrawing;

  const RoomLineEdit({
    required this.roomId,
    required this.roomName,
    required this.configPath,
    required this.tab,
    required this.lineKey,
    required this.description,
    required this.from,
    required this.to,
    this.spares = 0,
    this.removed = false,
    required this.drawn,
    this.onDrawing = 0,
  });

  /// How many the room buys, before spares.
  double get toBeforeSpares => (to - spares) < 0 ? 0 : to - spares;

  /// True when the line comes off the estimate rather than changing count.
  bool get takesLineOff => !drawn && (removed || toBeforeSpares <= 0);

  String get what {
    if (removed) {
      return drawn
          ? 'row deleted - quantity ${trimNumber(from)} -> 0 (still on the '
                'drawing)'
          : 'row deleted - line removed (was ${trimNumber(from)})';
    }
    if (takesLineOff) {
      return 'quantity ${trimNumber(from)} -> 0 - line removed';
    }
    return 'quantity ${trimNumber(from)} -> ${trimNumber(to)}';
  }

  OnlineChange get change => (
    kind: kRoomLineKind,
    id: '$roomId|$lineKey',
    name: '$roomName: $description',
    what: what,
  );
}

/// What the room tabs said.
typedef RoomEditsRead = ({
  List<RoomLineEdit> edits,

  /// Tab and row id of every row this accounts for, so the list of edits it
  /// cannot bring in does not repeat them.
  Set<(String, String)> handled,

  /// Rows that could not be read, in words somebody can act on.
  List<String> problems,
});

/// True for a line key the drawing counts - see [groupDevices].
bool _isDrawnKey(String key) =>
    key.startsWith('model:') ||
    key.startsWith('device:') ||
    key.startsWith('nocost:');

/// True when [settings] has a line added by hand under [key].
bool _isAddedItem(RoomCostSettings settings, String key) => [
  ...settings.items,
  ...settings.extraEquipment,
  ...settings.extraHardware,
  ...settings.extraCables,
].any((i) => i.id == key);

/// Each line row on a room's tab: row id -> what its Qty cell says. Null when
/// the tab has no Row id column - a copy published before rooms could be read
/// back, which says nothing about what was deleted.
Map<String, String>? _readRoomTab(List<List<String>> grid) {
  Map<String, int>? cols;
  Map<String, String>? out;
  for (final row in grid) {
    if (row.any((c) => c.trim() == kRoomRowIdColumn) &&
        row.any((c) => c.trim() == _kQtyColumn)) {
      cols = {for (var i = 0; i < row.length; i++) row[i].trim(): i};
      out ??= {};
      continue;
    }
    if (cols == null) continue;
    if (row.every((c) => c.trim().isEmpty)) {
      cols = null;
      continue;
    }
    String cell(String name) {
      final c = cols![name];
      return c == null || c >= row.length ? '' : row[c].trim();
    }

    final id = cell(kRoomRowIdColumn);
    if (id.isEmpty) continue;
    out![id] = cell(_kQtyColumn);
  }
  return out;
}

/// Reads every room's tab in [sheets] against what the last publish wrote,
/// [published], and returns the counts somebody changed.
///
/// AGAINST THE PUBLISH, NOT THE ROOM. A row is an edit only when its Qty
/// differs from what the publish put there, or when the publish put the row
/// there and it has gone. Compared with the room instead, any copy older than
/// the room read as somebody typing the old figure back: the synced .xlsx,
/// still saying 3 after the Sheet's 0 had been brought in, put the 3 back -
/// and a line added since the publish read as deleted from the tab.
RoomEditsRead readRoomEdits(
  Map<String, List<List<String>>> sheets,
  ProjectEstimate estimate, {
  required Map<String, List<List<String>>> published,
}) {
  final edits = <RoomLineEdit>[];
  final handled = <(String, String)>{};
  final problems = <String>[];
  final tabs = projectRoomTabNames(estimate);
  double? count(String text) => text.isEmpty
      ? 0.0
      : double.tryParse(text.replaceAll(',', ''));
  for (final room in estimate.rooms) {
    final tab = tabs[room.ref.id];
    final grid = tab == null ? null : sheets[tab];
    final before = tab == null ? null : published[tab];
    final e = room.estimate;
    if (tab == null || grid == null || before == null || e == null) continue;
    final rows = _readRoomTab(grid);
    final was = _readRoomTab(before);
    // A tab published before rooms carried a Row id says nothing either way.
    if (rows == null || was == null) continue;
    final settings = room.room.settings;
    for (final (_, _, lines) in roomLineSections(e)) {
      for (final line in lines) {
        final wasText = was[line.key];
        // Not on the tab when it was published: nothing to compare.
        if (wasText == null) continue;
        final text = rows[line.key];
        final removed = text == null;
        if (!removed && count(text) == count(wasText)) continue;
        double to;
        if (removed) {
          to = 0;
        } else {
          final parsed = count(text);
          if (parsed == null || parsed < 0) {
            problems.add(
              '${room.name}: the quantity for ${line.description} reads '
              '"$text", which is not a count - left as it was.',
            );
            continue;
          }
          to = parsed;
        }
        final drawn = _isDrawnKey(line.key);
        final supported = drawn || _isAddedItem(settings, line.key);
        // The drawing's count: listed with the other edits, not applied.
        if (!supported) continue;
        handled.add((tab, line.key));
        // Already what the tab says - brought in by an earlier pull.
        if ((to - line.qty).abs() < 1e-9 && !(removed && !drawn)) continue;
        edits.add(RoomLineEdit(
          roomId: room.ref.id,
          roomName: room.name,
          configPath: room.room.configPath,
          tab: tab,
          lineKey: line.key,
          description: line.description,
          from: line.qty,
          to: to,
          spares: line.spareQty,
          removed: removed,
          drawn: drawn,
          onDrawing: line.onDiagram ?? (line.qty - line.spareQty),
        ));
      }
    }
  }
  return (edits: edits, handled: handled, problems: problems);
}

/// Puts [edits] into one room's cost file, which is not the room open in the
/// app. Edits the file as the JSON it is and writes the rest back as found.
/// Returns how many lines it changed; 0 and a log line when the file could
/// not be read or written.
Future<int> applyRoomEditsToFile(
  String configPath,
  List<RoomLineEdit> edits,
) async {
  if (edits.isEmpty) return 0;
  for (final file in [
    ...roomPartCandidates(configPath, RoomSidecarPart.cost),
    ...roomFlowCandidates(configPath),
  ]) {
    try {
      final f = File(file);
      if (!await f.exists()) continue;
      final doc = jsonDecode(await f.readAsString());
      if (doc is! Map || doc['cost'] is! Map) continue;
      final cost = Map<String, dynamic>.from(doc['cost'] as Map);
      final changed = applyRoomEditsToCostJson(cost, edits);
      if (changed == 0) return 0;
      final out = Map<String, dynamic>.from(doc)..['cost'] = cost;
      await writeFileSafely(
        file,
        const JsonEncoder.withIndent('    ').convert(out),
      );
      return changed;
    } catch (e) {
      AppLogger.logError('Room quantities from the Sheet: $file', e);
      return 0;
    }
  }
  AppLogger.logInfo(
    'Room quantities from the Sheet: no cost file found for $configPath.',
  );
  return 0;
}

/// [edits] applied to a room's `cost` block as JSON. Returns how many lines
/// changed.
int applyRoomEditsToCostJson(
  Map<String, dynamic> cost,
  List<RoomLineEdit> edits,
) {
  var changed = 0;
  for (final edit in edits) {
    if (edit.drawn) {
      final overrides = Map<String, dynamic>.from(
        cost['qtyOverrides'] as Map? ?? const {},
      );
      final qty = edit.toBeforeSpares;
      if ((qty - edit.onDrawing).abs() < 1e-9) {
        overrides.remove(edit.lineKey);
      } else {
        overrides[edit.lineKey] = qty;
      }
      if (overrides.isEmpty) {
        cost.remove('qtyOverrides');
      } else {
        cost['qtyOverrides'] = overrides;
      }
      changed++;
      continue;
    }
    for (final list in const [
      'items',
      'extraEquipment',
      'extraHardware',
      'extraCables',
    ]) {
      final items = cost[list];
      if (items is! List) continue;
      final at = items.indexWhere(
        (i) => i is Map && i['id']?.toString() == edit.lineKey,
      );
      if (at < 0) continue;
      if (edit.takesLineOff) {
        items.removeAt(at);
      } else {
        items[at] = Map<String, dynamic>.from(items[at] as Map)
          ..['qty'] = edit.toBeforeSpares;
      }
      changed++;
      break;
    }
  }
  return changed;
}
