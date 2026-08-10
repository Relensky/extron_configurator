import 'app_state.dart';
import 'av_flow_model.dart';
import 'cost_estimate.dart';
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
///    * Pack list         — the equipment order, with rack heights and watts
///    * Rack inventory    — U positions per frame and face, plus how full and
///                          how hot each frame is
///    * Jack schedule     — which device landed on which numbered jack
///    * Power             — where each device's mains comes from, what the
///                          room draws, and what that is in amps and BTU/hr
///    * Port utilization  — used/total per device, so spare switcher inputs
///                          and unfed DSP channels are visible at a glance
///
///  [avReportSections] is the whole stack, for the AV tab's own single-sheet
///  report. The three grouped getters below it are what the multi-sheet room
///  workbook deals each sheet from — same functions, so a figure can never
///  differ between the two exports.
/// ============================================================================

List<ReportSection> avReportSections(
  AppStateProvider provider,
  AvFlowModel model,
) {
  return [
    ...avFlowSections(provider, model),
    ...rackSections(model),
    ...powerSections(model),
  ];
}

/// The signal-path half: what is in the room and how it is cabled.
List<ReportSection> avFlowSections(
  AppStateProvider provider,
  AvFlowModel model,
) => [
  _roomSummary(provider, model),
  _cableSchedule(model),
  _packList(provider, model),
  if (model.nodes.any((n) => n.isJackField)) _jackSchedule(model),
  _portUtilization(model),
  ..._driverGap(provider, model),
];

/// The rack elevation half: how full each frame is and what sits where.
List<ReportSection> rackSections(AvFlowModel model) => [
  if (model.racks.isNotEmpty) _rackSummary(model),
  if (model.racks.isNotEmpty || model.nodes.any((n) => n.rackUnits > 0))
    _rackInventory(model),
];

/// The power half: the estimate, then the device-by-device detail.
List<ReportSection> powerSections(AvFlowModel model) => [
  _powerSummary(model),
  _powerSchedule(model),
];

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
      if (model.rackItems.isNotEmpty)
        ['Rack hardware', model.rackItems.length],
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
/// a quantity, which is what a pack list is actually read for. The grouping is
/// [groupDevices] — shared with the cost estimate, so the quantity you order
/// and the quantity you are quoted for are the same number by construction.
ReportSection _packList(AppStateProvider provider, AvFlowModel model) {
  final rows = <List<dynamic>>[];
  for (final group in groupDevices(model)) {
    final first = group.first;
    // Connector counts come straight off the device, so the sheet says what
    // the box has to have — not just what this room happened to use. The
    // power inlet is not a signal connector and stays out of the count.
    final ins = first.ports
        .where((p) => p.direction != PortDirection.output && !p.isPowerInlet)
        .length;
    final outs = first.ports
        .where((p) => p.direction != PortDirection.input)
        .length;
    final module = provider.moduleForModel(first.model);
    rows.add([
      group.label,
      first.model,
      // The ordering code off the catalog entry, next to the model it belongs
      // to: the pack list is what a purchase order gets typed from.
      provider.avDeviceLibrary.templateForModel(first.model)?.partNumber ?? '',
      group.qty,
      first.rackUnits == 0 ? '' : '${first.rackUnits}U',
      '$ins / $outs',
      first.powerWatts <= 0 ? '' : first.powerWatts,
      first.effectiveBtu <= 0 ? '' : first.effectiveBtu.round(),
      module.isEmpty ? 'none' : module,
      // The pack list keeps a device the estimate leaves out: it is in the
      // room and it has to be found, wired and racked whoever paid for it.
      // Saying so here is what stops the two sheets looking like they
      // disagree about the same box.
      [
        first.fromConfig ? 'Room config' : 'Added manually',
        if (first.excludeFromCost) 'not quoted',
      ].join(' · '),
      group.notes,
    ]);
  }

  return (
    title: 'Pack List',
    header: [
      'Device',
      'Model',
      'Part number',
      'Qty',
      'Rack U',
      'In / Out',
      'Watts ea.',
      'BTU/hr ea.',
      'Control module',
      'Source',
      'Notes',
    ],
    rows: rows,
  );
}

/// Devices no Python driver claims.
///
/// The catalog covers everything you can buy; the module library covers what
/// the control system can actually drive. A device in the first and not the
/// second is not necessarily wrong — a passive speaker never had a driver —
/// but it IS the list somebody needs before commissioning, because every
/// entry on it is a box the processor cannot touch. Empty sections drop out,
/// so a fully driven room never grows this table.
List<ReportSection> _driverGap(AppStateProvider provider, AvFlowModel model) {
  final rows = <List<dynamic>>[];
  for (final group in groupDevices(model)) {
    final node = group.first;
    if (node.isJackField) continue;
    if (node.model.trim().isEmpty) {
      rows.add([group.label, '(no model set)', group.qty, 'Model not recorded']);
      continue;
    }
    if (provider.moduleForModel(node.model).isNotEmpty) continue;
    rows.add([
      group.label,
      node.model,
      group.qty,
      'No Python module claims this model',
    ]);
  }
  if (rows.isEmpty) return const [];
  return [
    (
      title: 'Devices Without a Control Module',
      header: ['Device', 'Model', 'Qty', 'Note'],
      rows: rows,
    ),
  ];
}

/// How full and how hot each frame is: the two questions asked before
/// anything else gets added to a rack.
ReportSection _rackSummary(AvFlowModel model) {
  final byId = model.nodesById;
  final itemById = {for (final i in model.rackItems) i.id: i};
  final rows = <List<dynamic>>[];

  for (final rack in model.racks) {
    int usedU = 0;
    double watts = 0;
    double btu = 0;
    int devices = 0;
    int unmetered = 0;
    for (final entry in model.rackSlots.entries) {
      if (entry.value.rackId != rack.id) continue;
      final node = byId[entry.key];
      if (node == null) {
        // Rack hardware: it takes up rails and draws nothing, which is
        // exactly what a blanking plate is for.
        final item = itemById[entry.key];
        if (item != null) usedU += item.rackUnits <= 0 ? 1 : item.rackUnits;
        continue;
      }
      devices++;
      watts += node.powerWatts;
      btu += node.effectiveBtu;
      if (node.effectiveBtu <= 0 && node.powerSource != PowerSource.none) {
        unmetered++;
      }
      // A shared rail is one U of rack space however many boxes are on it,
      // so a device on a split row only claims its fraction.
      usedU += (node.rackUnits <= 0 ? 1 : node.rackUnits);
    }
    rows.add([
      rack.name,
      rack.kind,
      '${rack.heightU}U',
      devices,
      '$usedU of ${rack.heightU}U',
      watts <= 0 ? '' : watts.round(),
      btu <= 0 ? '' : btu.round(),
      // What somebody sizing the cabinet fan or the closet's mini-split
      // actually asks for.
      btu <= 0 ? '' : (btu / 12000).toStringAsFixed(2),
      unmetered == 0 ? '' : '$unmetered not recorded',
    ]);
  }

  return (
    title: 'Rack Summary',
    header: [
      'Rack',
      'Type',
      'Height',
      'Devices',
      'Space used',
      'Watts',
      'Cooling (BTU/hr)',
      'Cooling (tons)',
      'Missing figures',
    ],
    rows: rows,
  );
}

/// What the room draws, and what that means for the circuit it lands on.
///
/// Watts come off each device ([AvNode.powerWatts], seeded from the catalog),
/// so this is an estimate built from the equipment list rather than a
/// measurement — the last row says how many devices have no figure at all,
/// because a total that quietly treats unknowns as zero is worse than no
/// total.
ReportSection _powerSummary(AvFlowModel model) {
  double total = 0;
  double btu = 0;
  int unmetered = 0;
  final bySource = <PowerSource, double>{};
  final unmeteredBySource = <PowerSource, int>{};

  for (final node in model.nodes) {
    if (node.isJackField) continue;
    btu += node.effectiveBtu;
    if (node.powerWatts <= 0) {
      // A device that is not plugged into anything is not a gap in the
      // estimate — it genuinely draws nothing.
      if (node.powerSource != PowerSource.none) unmetered++;
      unmeteredBySource[node.powerSource] =
          (unmeteredBySource[node.powerSource] ?? 0) + 1;
      continue;
    }
    total += node.powerWatts;
    bySource[node.powerSource] = (bySource[node.powerSource] ?? 0) +
        node.powerWatts;
  }

  // Mains-fed gear is what sizes the circuit; PoE comes off the switch's
  // budget and "no mains needed" is nothing at all.
  final mains = (bySource[PowerSource.controller] ?? 0) +
      (bySource[PowerSource.wall] ?? 0) +
      (bySource[PowerSource.unspecified] ?? 0);

  final rows = <List<dynamic>>[
    ['Estimated total draw (W)', total.round()],
    ['Mains-fed draw (W)', mains.round()],
    ['Estimated current @ 120 V (A)', (mains / 120).toStringAsFixed(1)],
    ['Estimated current @ 208 V (A)', (mains / 208).toStringAsFixed(1)],
    // Heat comes off each device's own BTU figure where there is one and its
    // watts where there isn't — an amplifier's published heat output is well
    // below its rated draw, so the arithmetic is a fallback, not the truth.
    ['Heat load (BTU/hr)', btu.round()],
    ['Cooling required (tons)', (btu / 12000).toStringAsFixed(2)],
    for (final source in PowerSource.values)
      if ((bySource[source] ?? 0) > 0 || (unmeteredBySource[source] ?? 0) > 0)
        [
          '${kPowerSourceLabels[source] ?? source.name} (W)',
          '${(bySource[source] ?? 0).round()}'
              '${(unmeteredBySource[source] ?? 0) > 0 ? ' + ${unmeteredBySource[source]} not recorded' : ''}',
        ],
    if (unmetered > 0)
      [
        'Devices with no power figure',
        '$unmetered — the total above is short by whatever they draw',
      ],
  ];

  return (title: 'Power Estimate', header: ['Item', 'Value'], rows: rows);
}

/// Where each device sits, per frame and face, listed top of rack downward
/// the way an elevation is read.
ReportSection _rackInventory(AvFlowModel model) {
  final byId = model.nodesById;
  final itemById = {for (final i in model.rackItems) i.id: i};
  final rows = <List<dynamic>>[];

  for (final rack in model.racks) {
    if (rack.kind.isNotEmpty) {
      rows.add([rack.name, '', '', '', '— ${rack.kind} —', '']);
    }
    for (final face in RackFace.values) {
      final entries =
          model.rackSlots.entries
              .where((e) => e.value.rackId == rack.id && e.value.face == face)
              .toList()
            ..sort((a, b) => b.value.startU.compareTo(a.value.startU));

      for (final entry in entries) {
        final node = byId[entry.key];
        final item = node == null ? itemById[entry.key] : null;
        final height = (node?.rackUnits ?? item?.rackUnits ?? 1).clamp(1, 60);
        final startU = entry.value.startU;
        final endU = startU + height - 1;
        final slice = entry.value.slice;
        rows.add([
          rack.name,
          face == RackFace.front ? 'Front' : 'Rear',
          height == 1 ? 'U$startU' : 'U$startU-U$endU',
          // Which slice of the rail — the thing you need when three boxes
          // share one shelf.
          slice.label,
          node?.label ?? item?.label ?? entry.key,
          // Hardware shows its kind where a device shows its model: reading
          // "Blank plate" down that column is what makes an elevation
          // check out against the rack in front of you.
          node?.model ?? item?.category ?? '',
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
    rows.add(['(not placed)', '', '${n.rackUnits}U', '', n.label, n.model]);
  }
  // Hardware bought but not placed. It is still on the estimate, so leaving
  // it off this sheet would make the order and the elevation disagree.
  for (final i in model.rackItems) {
    if (model.rackSlots.containsKey(i.id)) continue;
    rows.add(['(not placed)', '', '${i.rackUnits}U', '', i.label, i.category]);
  }

  return (
    title: 'Rack Inventory',
    header: ['Rack', 'Face', 'Position', 'Slice', 'Item', 'Model / kind'],
    rows: rows,
  );
}

/// Which device is on which numbered jack of each wall box, floor box or
/// patch panel — the sheet you read standing at the wall plate with a tester.
ReportSection _jackSchedule(AvFlowModel model) {
  final byId = model.nodesById;
  final rows = <List<dynamic>>[];

  for (final field in model.nodes.where((n) => n.isJackField)) {
    for (final jack in field.ports) {
      // A jack can be patched at either end of a run, so look both ways.
      final uses = model.cables.where(
        (c) =>
            (c.fromNodeId == field.id && c.fromPortId == jack.id) ||
            (c.toNodeId == field.id && c.toPortId == jack.id),
      );

      if (uses.isEmpty) {
        rows.add([
          field.label,
          jack.label,
          kSignalCodes[jack.signal] ?? jack.signal.name,
          '(spare)',
          '',
          '',
        ]);
        continue;
      }
      for (final c in uses) {
        final farNode = c.fromNodeId == field.id ? c.toNodeId : c.fromNodeId;
        final farPort = c.fromNodeId == field.id ? c.toPortId : c.fromPortId;
        rows.add([
          field.label,
          jack.label,
          kSignalCodes[c.signal] ?? c.signal.name,
          byId[farNode]?.label ?? farNode,
          byId[farNode]?.portById(farPort)?.label ?? farPort,
          c.id,
        ]);
      }
    }
  }

  return (
    title: 'Jack Schedule',
    header: [
      'Wall box / panel',
      'Jack',
      'Signal',
      'Connected device',
      'Device port',
      'Cable',
    ],
    rows: rows,
  );
}

/// Where every device's mains comes from, and — when it is on a controller —
/// which outlet, resolved from the power cable actually drawn.
ReportSection _powerSchedule(AvFlowModel model) {
  final byId = model.nodesById;
  final rows = <List<dynamic>>[];

  for (final node in model.nodes) {
    if (node.isJackField) continue;

    // A power-signal cable landing on this device names its outlet.
    String feed = '';
    String outlet = '';
    for (final c in model.cables) {
      if (c.signal != SignalType.power) continue;
      final incoming = c.toNodeId == node.id;
      final outgoing = c.fromNodeId == node.id;
      if (!incoming && !outgoing) continue;
      final sourceId = incoming ? c.fromNodeId : c.toNodeId;
      final sourcePort = incoming ? c.fromPortId : c.toPortId;
      if (sourceId == node.id) continue;
      feed = byId[sourceId]?.label ?? sourceId;
      outlet = byId[sourceId]?.portById(sourcePort)?.label ?? sourcePort;
      break;
    }

    rows.add([
      node.label,
      node.model,
      kPowerSourceLabels[node.powerSource] ?? node.powerSource.name,
      node.powerWatts <= 0 ? '' : node.powerWatts,
      node.effectiveBtu <= 0 ? '' : node.effectiveBtu.round(),
      feed,
      outlet,
    ]);
  }

  return (
    title: 'Power Schedule',
    header: [
      'Device',
      'Model',
      'Source',
      'Watts',
      'BTU/hr',
      'Fed from',
      'Outlet',
    ],
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
      // The power inlet is not a signal connector; counting it would report
      // every device as having one more input than it can be patched with.
      if (p.isPowerInlet) continue;
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
