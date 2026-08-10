import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'cost_estimate.dart';

/// ============================================================================
///  DEVICE RECHECK
/// ============================================================================
///  Finds the three ways a device ends up missing from the rack builder, all
///  of which look identical from the outside — you added the box, and it isn't
///  there.
///
///    1. STALE SPECS. A node copies its rack height, watts and BTU off the
///       catalog WHEN IT IS CREATED. Fill the rack height in afterwards — which
///       is the normal order, because you draw the room before you have the
///       part numbers — and the copy on the diagram stays at 0, and 0 means
///       "not rack mounted", so the rack builder never offers it.
///
///    2. QUOTED BUT NEVER DRAWN. A line added on the Cost tab is a price, not a
///       device. If the model behind it is 2U of rack-mount gear then it IS
///       going in a frame, and the rack builder has no way to know it exists.
///
///    3. RACKED INTO A FRAME THAT IS GONE. A rack slot pointing at a deleted
///       rack, or at a device that has since been removed, hides its occupant
///       twice over: the elevation cannot draw it, and the "to place" list
///       skips it because the slot map says it is already somewhere.
///
///  All of it is reported before anything is changed. A recheck that silently
///  rewrote figures would be worse than the problem: a rack height typed by
///  hand because this room's shelf is deeper than the catalog assumes is a
///  decision, and quietly reverting it to the catalog's number is how a rack
///  elevation stops matching the room.
/// ============================================================================

/// One device whose figures disagree with the catalog entry for its model.
class DeviceSpecChange {
  final AvNode before;

  /// The same node with the catalog's figures in it — ready for updateAvNode.
  final AvNode after;

  /// Human-readable, one per field: 'Rack height 0U → 2U'.
  final List<String> fields;

  const DeviceSpecChange({
    required this.before,
    required this.after,
    required this.fields,
  });

  String get label => before.label;
  String get model => before.model;
}

/// Which list on the estimate a quoted-but-undrawn line came off.
enum QuotedKind { equipment, hardware }

/// A cost line whose catalog model is rack-mount gear, sitting on the estimate
/// with nothing on the diagram or in a frame to match it.
class QuotedNotPlaced {
  final CostLineItem item;
  final AvDeviceTemplate template;
  final QuotedKind kind;

  const QuotedNotPlaced({
    required this.item,
    required this.template,
    required this.kind,
  });

  int get rackUnits => template.rackUnits;

  String get label => item.description.trim().isEmpty
      ? template.model
      : item.description.trim();

  /// How many of them the estimate is buying; at least one.
  int get qty => item.qty < 1 ? 1 : item.qty.round();
}

/// A rack slot nothing can draw: its frame is gone, or its occupant is.
class OrphanedPlacement {
  final String occupantId;
  final String label;

  /// Why it cannot be drawn, for the dialog's row.
  final String reason;

  const OrphanedPlacement({
    required this.occupantId,
    required this.label,
    required this.reason,
  });
}

class DeviceRecheck {
  final List<DeviceSpecChange> specChanges;
  final List<QuotedNotPlaced> quoted;
  final List<OrphanedPlacement> orphans;

  /// Devices with a rack height that are sitting in a frame, drawn, fine —
  /// counted so a clean recheck can say what it looked at instead of just
  /// "nothing to do".
  final int rackableDevices;

  const DeviceRecheck({
    required this.specChanges,
    required this.quoted,
    required this.orphans,
    required this.rackableDevices,
  });

  bool get isClean =>
      specChanges.isEmpty && quoted.isEmpty && orphans.isEmpty;

  int get findings => specChanges.length + quoted.length + orphans.length;
}

/// Compares what the room says against what the catalog says. Pure: it changes
/// nothing, and every result carries the replacement rather than applying it.
DeviceRecheck recheckDevices({
  required List<AvNode> nodes,
  required AvDeviceLibrary library,
  required RoomCostSettings cost,
  required List<RackFrame> racks,
  required Map<String, RackSlot> slots,
  required List<RackItem> rackItems,
}) {
  final specChanges = <DeviceSpecChange>[];

  for (final node in nodes) {
    // A wall box's height comes from how many jacks are on it, not from a
    // catalog entry, and its "model" is often the plate rather than a part.
    if (node.isJackField) continue;
    // templateForModel rather than resolve(): a family fallback is a generic
    // guess for a device nobody has chosen a model for, and rewriting a room's
    // figures from a guess is exactly what this must not do.
    final template = library.templateForModel(node.model);
    if (template == null) continue;

    final fields = <String>[];
    var after = node;

    // Only ever pulls a figure the catalog actually HAS. A blank in the
    // catalog means "nobody filled this in", not "this device draws nothing",
    // so it must never overwrite a number somebody measured on site.
    if (template.rackUnits > 0 && template.rackUnits != node.rackUnits) {
      fields.add('Rack height ${node.rackUnits}U → ${template.rackUnits}U');
      after = after.copyWith(rackUnits: template.rackUnits);
    }
    if (template.powerWatts > 0 && template.powerWatts != node.powerWatts) {
      fields.add(
        'Power ${trimNumber(node.powerWatts)} W → '
        '${trimNumber(template.powerWatts)} W',
      );
      after = after.copyWith(powerWatts: template.powerWatts);
    }
    if (template.btuPerHour > 0 && template.btuPerHour != node.btuPerHour) {
      fields.add(
        'Heat ${trimNumber(node.btuPerHour)} → '
        '${trimNumber(template.btuPerHour)} BTU/hr',
      );
      after = after.copyWith(btuPerHour: template.btuPerHour);
    }

    if (fields.isNotEmpty) {
      specChanges.add(
        DeviceSpecChange(before: node, after: after, fields: fields),
      );
    }
  }

  // --- quoted on the Cost tab, never drawn --------------------------------
  final quoted = <QuotedNotPlaced>[];
  void scan(List<CostLineItem> items, QuotedKind kind) {
    for (final item in items) {
      if (item.catalogModel.trim().isEmpty) continue;
      final template = library.templateForModel(item.catalogModel);
      // Only rack-mount gear: a display or a ceiling mic is quoted here and
      // belongs nowhere near a frame, and listing it would make the recheck
      // noise rather than a finding.
      if (template == null || template.rackUnits <= 0) continue;
      quoted.add(
        QuotedNotPlaced(item: item, template: template, kind: kind),
      );
    }
  }

  scan(cost.extraEquipment, QuotedKind.equipment);
  scan(cost.extraHardware, QuotedKind.hardware);

  // --- placements nothing can draw ----------------------------------------
  final orphans = <OrphanedPlacement>[];
  final rackIds = {for (final r in racks) r.id};
  final nodesById = {for (final n in nodes) n.id: n};
  final itemsById = {for (final i in rackItems) i.id: i};

  slots.forEach((occupantId, slot) {
    final label =
        nodesById[occupantId]?.label ?? itemsById[occupantId]?.label ?? '';
    if (label.isEmpty) {
      orphans.add(
        OrphanedPlacement(
          occupantId: occupantId,
          label: occupantId,
          reason: 'Nothing in the room has this id any more',
        ),
      );
    } else if (!rackIds.contains(slot.rackId)) {
      orphans.add(
        OrphanedPlacement(
          occupantId: occupantId,
          label: label,
          reason: 'Racked into a frame that has been deleted',
        ),
      );
    }
  });

  return DeviceRecheck(
    specChanges: specChanges,
    quoted: quoted,
    orphans: orphans,
    rackableDevices: nodes.where((n) => n.rackUnits > 0).length,
  );
}
