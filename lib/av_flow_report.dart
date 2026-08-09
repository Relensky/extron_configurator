import 'app_state.dart';
import 'av_flow_model.dart';
import 'report_tools.dart';

/// ============================================================================
///  AV FLOW REPORTS
/// ============================================================================
///  Pure functions of the AV diagram, so the .xlsx, the .txt and the clipboard
///  copy all render the same content — and it can be checked without pumping
///  a widget. Same contract as reportSections() on the Schematic tab.
///
///  Sections:
///    * Cable schedule    — the pull sheet: what plugs into what
///    * Pack list         — the equipment order, with rack heights
///    * Rack inventory    — U positions per frame and face
///    * Port utilization  — used/total per device, so spare switcher inputs
///                          and unfed DSP channels are visible at a glance
/// ============================================================================

List<ReportSection> avReportSections(
    AppStateProvider provider, AvFlowModel model) {
  return [
    _roomSummary(provider, model),
    _cableSchedule(model),
    _packList(model),
    if (model.racks.isNotEmpty) _rackInventory(model),
    _portUtilization(model),
  ];
}

/// Two-column header block: which room this schedule belongs to, and the
/// totals worth seeing before the tables.
ReportSection _roomSummary(AppStateProvider provider, AvFlowModel model) {
  final setup = provider.roomConfig['SYSTEM_SETUP'];
  String value(String key) =>
      (setup is Map ? setup[key]?.toString() : null) ?? '';

  final signalTotals = <SignalType, int>{};
  for (final c in model.cables) {
    signalTotals[c.signal] = (signalTotals[c.signal] ?? 0) + 1;
  }
  final byType = signalTotals.entries
      .map((e) => '${kSignalCodes[e.key] ?? e.key.name} ×${e.value}')
      .join(', ');

  return (
    title: 'Room',
    header: const ['Item', 'Value'],
    rows: [
      ['Room', value('gui_full_room_name')],
      ['Building', value('gve_bldg')],
      ['Room number', value('gve_room')],
      ['Devices on diagram', model.nodes.length],
      ['Cables', model.cables.length],
      if (byType.isNotEmpty) ['Cables by type', byType],
      ['Racks', model.racks.length],
    ],
  );
}

/// The pull sheet. Cables are listed in creation order, which is the order
/// their IDs were handed out, so C1..Cn read top to bottom.
ReportSection _cableSchedule(AvFlowModel model) {
  final byId = model.nodesById;

  String deviceName(String id) => byId[id]?.label ?? id;
  String portName(String nodeId, String portId) =>
      byId[nodeId]?.portById(portId)?.label ?? portId;

  return (
    title: 'Cable Schedule',
    header: [
      'Cable',
      'Signal',
      'From device',
      'From port',
      'To device',
      'To port',
      'Notes',
    ],
    rows: [
      for (final c in model.cables)
        [
          c.id,
          kSignalCodes[c.signal] ?? c.signal.name,
          deviceName(c.fromNodeId),
          portName(c.fromNodeId, c.fromPortId),
          deviceName(c.toNodeId),
          portName(c.toNodeId, c.toPortId),
          c.label,
        ],
    ],
  );
}

/// The equipment order. Devices of the same model collapse into one row with
/// a quantity, which is what a pack list is actually read for.
ReportSection _packList(AvFlowModel model) {
  // Key on model when there is one; devices with no model stay separate so a
  // pair of unnamed boxes doesn't silently merge.
  final grouped = <String, List<AvNode>>{};
  for (final node in model.nodes) {
    final key = node.model.trim().isEmpty
        ? 'device:${node.id}'
        : 'model:${node.model.trim().toLowerCase()}';
    grouped.putIfAbsent(key, () => []).add(node);
  }

  final rows = <List<dynamic>>[];
  for (final group in grouped.values) {
    final first = group.first;
    final notes = group
        .map((n) => n.note)
        .where((n) => n.trim().isNotEmpty)
        .toSet()
        .join('; ');
    rows.add([
      group.length == 1 ? first.label : group.map((n) => n.label).join(', '),
      first.model,
      group.length,
      first.rackUnits == 0 ? '' : '${first.rackUnits}U',
      first.fromConfig ? 'Room config' : 'Added manually',
      notes,
    ]);
  }

  return (
    title: 'Pack List',
    header: ['Device', 'Model', 'Qty', 'Rack U', 'Source', 'Notes'],
    rows: rows,
  );
}

/// Where each device sits, per frame and face, listed top of rack downward
/// the way an elevation is read.
ReportSection _rackInventory(AvFlowModel model) {
  final byId = model.nodesById;
  final rows = <List<dynamic>>[];

  for (final rack in model.racks) {
    for (final face in RackFace.values) {
      final entries = model.rackSlots.entries
          .where((e) => e.value.rackId == rack.id && e.value.face == face)
          .toList()
        ..sort((a, b) => b.value.startU.compareTo(a.value.startU));

      for (final entry in entries) {
        final node = byId[entry.key];
        final height = (node?.rackUnits ?? 1).clamp(1, 60);
        final startU = entry.value.startU;
        final endU = startU + height - 1;
        rows.add([
          rack.name,
          face == RackFace.front ? 'Front' : 'Rear',
          height == 1 ? 'U$startU' : 'U$startU-U$endU',
          node?.label ?? entry.key,
          node?.model ?? '',
        ]);
      }
    }
  }

  // Devices with a rack height that nobody has placed yet — the thing you
  // want to know before ordering rack rails.
  final unracked = model.nodes
      .where((n) => n.rackUnits > 0 && !model.rackSlots.containsKey(n.id))
      .toList();
  for (final n in unracked) {
    rows.add(['(not placed)', '', '${n.rackUnits}U', n.label, n.model]);
  }

  return (
    title: 'Rack Inventory',
    header: ['Rack', 'Face', 'Position', 'Device', 'Model'],
    rows: rows,
  );
}

/// Used/total connectors per device. Inputs and outputs are counted
/// separately because "8 of 10 inputs used" and "1 of 4 outputs used" are
/// different problems.
ReportSection _portUtilization(AvFlowModel model) {
  final usedPorts = <String, Set<String>>{};
  void mark(String nodeId, String portId) =>
      usedPorts.putIfAbsent(nodeId, () => {}).add(portId);
  for (final c in model.cables) {
    mark(c.fromNodeId, c.fromPortId);
    mark(c.toNodeId, c.toPortId);
  }

  final rows = <List<dynamic>>[];
  for (final node in model.nodes) {
    final used = usedPorts[node.id] ?? const <String>{};
    int inTotal = 0, inUsed = 0, outTotal = 0, outUsed = 0;
    for (final p in node.ports) {
      // Bidirectional connectors (Dante, network, USB-C) count on both sides,
      // since either role is what they are there for.
      if (p.direction != PortDirection.output) {
        inTotal++;
        if (used.contains(p.id)) inUsed++;
      }
      if (p.direction != PortDirection.input) {
        outTotal++;
        if (used.contains(p.id)) outUsed++;
      }
    }
    rows.add([
      node.label,
      node.model,
      inTotal == 0 ? '-' : '$inUsed / $inTotal',
      outTotal == 0 ? '-' : '$outUsed / $outTotal',
      node.ports.length - used.length,
    ]);
  }

  return (
    title: 'Port Utilization',
    header: ['Device', 'Model', 'Inputs used', 'Outputs used', 'Spare ports'],
    rows: rows,
  );
}
