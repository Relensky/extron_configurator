import 'app_state.dart';
import 'av_flow_model.dart';
import 'cabling_schematic.dart';
import 'control_gaps.dart';
import 'cost_estimate.dart';
import 'report_tools.dart';
import 'room_locations.dart';

/// ============================================================================
///  AV FLOW REPORTS
/// ============================================================================
///  Pure functions of the AV diagram, so the .xlsx, the .txt and the clipboard
///  copy all render the same content — and it can be checked without pumping
///  a widget. Same contract as reportSections() on the Schematic tab.
///
///  Sections:
///    * Cable schedule    — the pull sheet: what plugs into what, and WHERE
///                          each end of the run is in the room
///    * Pack list         — the equipment order, with rack heights and watts
///    * Rack inventory    — U positions per frame and face, plus how full and
///                          how hot each frame is
///    * Jack schedule     — which device landed on which numbered jack
///    * Locations         — what is where, and how many jacks and cable runs
///                          land at each place, grouped by ceiling / wall /
///                          floor / rack
///    * Line counts       — runs per location per signal type, and per cable
///                          label, which is the number that gets ordered
///    * Cable runs        — the runs pulled between two places in the room
///                          (screen and shade control among them), start,
///                          route and end
///    * Floor plan        — the callouts and what each one points at
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
    ...cablingSections(model),
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
  ...locationSections(model),
  _portUtilization(model),
  ...driverGapSections(provider, model),
];

/// The where-is-it half: the room's places, what lands at each of them, and
/// the counts somebody orders cable and back boxes against.
///
/// Its own group so the Floor Plan tab can export exactly these sheets without
/// dragging the whole cable schedule along, and so the room workbook can put
/// them on a tab of their own.
List<ReportSection> locationSections(AvFlowModel model) => [
  if (model.locations.isNotEmpty) _locationSummary(model),
  if (model.locations.isNotEmpty) _jackCountsByLocation(model),
  _lineCountsByLocation(model),
  ..._lineCountsByLabel(model),
  if (model.screenSwitches.isNotEmpty) _screenSwitchSchedule(model),
  ..._floorPlanCallouts(model),
];

/// The cabling drawing, as tables.
///
/// The drawing on the Cabling tab is what the trades are handed; this is the
/// same thing in a form somebody can price, order and check off. It is built
/// from exactly the same call the tab makes, so the sheet and the picture can
/// never disagree about how many cables run where.
///
/// Two columns earn their place beyond the obvious ones:
///
///   * WHERE THE FIGURE CAME FROM says whether each count was read off the
///     signal flow or typed over it. A schedule that hides which of its
///     numbers were overridden is a schedule nobody can audit.
///   * The totals table adds the runs up per cable type, which is the number a
///     purchase order is actually written against.
///
/// Empty sections drop out, so a room with no cabling drawing grows no tables.
List<ReportSection> cablingSections(AvFlowModel model) {
  final drawing = buildCablingSchematic(
    model: model,
    locations: model.locations,
    overrides: model.cablingEdits,
  );
  // The counts come off the signal flow rather than the drawing, so a room
  // that is cabled but not yet drawn still has a sheet somebody can order
  // from. Nothing at all in either and the tables stay away entirely.
  if (drawing.boxes.isEmpty && model.cables.isEmpty) return const [];

  String nameOf(String id) => drawing.boxById(id)?.label ?? id;

  final runs = [...drawing.bundles]..sort((a, b) {
    final byFrom = nameOf(a.fromBoxId).toLowerCase().compareTo(
      nameOf(b.fromBoxId).toLowerCase(),
    );
    return byFrom != 0
        ? byFrom
        : nameOf(a.toBoxId).toLowerCase().compareTo(
            nameOf(b.toBoxId).toLowerCase(),
          );
  });

  // Per cable type, which is the line a purchase order is written against —
  // grouped under the family heading the drawing labels those runs with, so
  // "AV cabling" totals once and then says what is in it.
  final byType = <String, ({double runs, Set<String> signals})>{};
  for (final r in runs) {
    final type = r.cableType.trim().isEmpty ? '(unspecified)' : r.cableType;
    final existing = byType[type];
    byType[type] = (
      runs: (existing?.runs ?? 0) + r.count,
      signals: {
        ...?existing?.signals,
        if (r.signalSubLabel.isNotEmpty) r.signalSubLabel,
      },
    );
  }

  final sections = <ReportSection>[
    cableCountSection(model),
    (
      title: 'Cabling Runs',
      header: [
        'From',
        'To',
        'Cables',
        'Cable type',
        'Signal',
        'Where the figure came from',
      ],
      rows: [
        for (final r in runs)
          [
            nameOf(r.fromBoxId),
            nameOf(r.toBoxId),
            r.count,
            r.cableType,
            r.signalSubLabel,
            if (!r.isDerived)
              'Added on the drawing'
            else if (drawing.overridden.contains(r.id))
              'Counted, then typed over'
            else
              'Counted off the signal flow',
          ],
      ],
    ),
    (
      title: 'Cable Totals by Type',
      header: ['Cable type', 'Signal', 'Runs'],
      rows: [
        for (final e in (byType.entries.toList()
              ..sort((a, b) => a.key.toLowerCase().compareTo(
                    b.key.toLowerCase(),
                  ))))
          [
            e.key,
            (e.value.signals.toList()..sort()).join('\n'),
            e.value.runs,
          ],
      ],
    ),
    (
      title: 'Cabling Drawing - Boxes',
      header: ['Box', 'Kind', 'Runs on it', 'Notes'],
      rows: [
        for (final b in drawing.boxes)
          [
            b.label,
            kCablingBoxKindLabels[b.kind] ?? b.kind.name,
            drawing.bundles
                .where((r) => r.fromBoxId == b.id || r.toBoxId == b.id)
                .fold<double>(0, (sum, r) => sum + r.count),
            // The scope notes down the side of the sheet are content, not
            // decoration — they say whose contract each part of the job is.
            b.body.replaceAll('\n', ' · '),
          ],
      ],
    ),
  ];

  return sections.where((s) => s.rows.isNotEmpty).toList();
}

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
      .join('\n');

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
      if (model.locations.isNotEmpty) ['Locations', model.locations.length],
      // A count of what has NOT been located, up front rather than buried:
      // every per-location figure below is short by exactly this much, and
      // that is worth knowing before reading them.
      if (model.locations.isNotEmpty &&
          model.nodes.any((n) => n.locationId.isEmpty))
        [
          'Devices with no location',
          '${model.nodes.where((n) => n.locationId.isEmpty).length} - the '
              'per-location counts below leave these out',
        ],
      if (model.screenSwitches.isNotEmpty)
        ['Cable runs', model.screenSwitches.length],
      if (model.floorPlans.isNotEmpty)
        [
          'Floor plans',
          '${model.floorPlans.length} '
              '(${model.floorPlans.fold(0, (n, p) => n + p.callouts.length)} '
              'callouts)',
        ],
    ],
  );
}

/// The pull sheet. Cables are listed in creation order, which is the order
/// their IDs were handed out, so C1..Cn read top to bottom.
///
/// Every run names its SOURCE and its DESTINATION — the device and port at
/// each end, and the place in the room each end is. The two ends of a run are
/// what somebody pulling cable needs before anything else, and a schedule that
/// only says "switcher to display" leaves them to work out whether that is six
/// feet inside a rack or a hundred through a ceiling.
ReportSection _cableSchedule(AvFlowModel model) {
  final byId = model.nodesById;

  String deviceName(String id) => byId[id]?.label ?? id;
  String portName(String nodeId, String portId) =>
      byId[nodeId]?.portById(portId)?.label ?? portId;

  return (
    title: 'Cable Schedule',
    header: [
      'Cable',
      'Label',
      // What it is FILED as, then what it carries: a DTP run and a Dante run
      // are both AV cabling to whoever pulls them, and different things to
      // whoever lands them.
      'Cable type',
      'Signal',
      'Length',
      'Source device',
      'Source port',
      'Source location',
      'Destination device',
      'Destination port',
      'Destination location',
    ],
    rows: [
      for (final c in model.cables)
        [
          c.id,
          c.label,
          cableTypeLabel(c.signal),
          kSignalCodes[c.signal] ?? c.signal.name,
          formatCableLength(c.lengthFt),
          deviceName(c.fromNodeId),
          portName(c.fromNodeId, c.fromPortId),
          model.locationNameOf(c.fromNodeId),
          deviceName(c.toNodeId),
          portName(c.toNodeId, c.toPortId),
          model.locationNameOf(c.toNodeId),
        ],
    ],
  );
}

/// How many runs of each kind there are, and in what lengths.
///
/// This is the sheet an order is written from, so it is arranged the way an
/// order is: the AV cabling together, the network together, everything else
/// after, each family totalled and then broken down by the signal it actually
/// carries and the lead length it is being bought in. A run with no length set
/// is counted in a column of its own rather than folded into the shortest
/// lead, because "we haven't decided" and "one foot" are different answers.
ReportSection cableCountSection(AvFlowModel model) {
  final byId = model.nodesById;
  final runs = model.cables
      .where((c) => AvFlowModel.cableIsResolvable(c, byId))
      .toList();

  /// length -> count, for one bucket of runs.
  Map<double, int> lengths(Iterable<AvCable> cables) {
    final out = <double, int>{};
    for (final c in cables) {
      final ft = c.lengthFt <= 0 ? 0.0 : c.lengthFt;
      out[ft] = (out[ft] ?? 0) + 1;
    }
    return out;
  }

  // Only the lengths in use get a column, plus every stock length that has
  // anything in it — a table with seven empty columns is a table nobody reads.
  final used = <double>{
    for (final c in runs)
      if (c.lengthFt > 0) c.lengthFt,
  }.toList()..sort();
  final anyUnset = runs.any((c) => c.lengthFt <= 0);

  List<dynamic> lengthCells(Map<double, int> counts) => [
    for (final ft in used) counts[ft] ?? '',
    if (anyUnset) counts[0] ?? '',
  ];

  final rows = <List<dynamic>>[];
  for (final family in CableFamily.values) {
    final here = runs.where((c) => cableFamilyFor(c.signal) == family).toList();
    if (here.isEmpty) continue;

    rows.add([
      '- ${kCableFamilyLabels[family]} -',
      '',
      here.length,
      ...lengthCells(lengths(here)),
    ]);

    // One row per signal under the family heading. Ordered by the enum so the
    // same room lists its types in the same order every time.
    for (final signal in SignalType.values) {
      final ofType = here.where((c) => c.signal == signal).toList();
      if (ofType.isEmpty) continue;
      rows.add([
        cableTypeLabel(signal),
        kSignalLabels[signal] ?? signal.name,
        ofType.length,
        ...lengthCells(lengths(ofType)),
      ]);
    }
  }

  if (rows.isNotEmpty) {
    rows.add([
      'All cabling',
      '',
      runs.length,
      ...lengthCells(lengths(runs)),
    ]);
  }

  return (
    title: 'Cable Counts by Type and Length',
    header: [
      'Cable type',
      'Signal',
      'Runs',
      for (final ft in used) formatCableLength(ft),
      if (anyUnset) 'No length set',
    ],
    rows: rows,
  );
}

/// What is where: one row per location, with the counts that get ordered
/// against it.
///
/// The zone column is the grouping the request asked for — ceiling, wall,
/// rack — and it is on every row rather than only in the section title,
/// because a spreadsheet gets sorted and filtered and a heading does not
/// survive that.
ReportSection _locationSummary(AvFlowModel model) {
  final rows = <List<dynamic>>[];

  // Zone order rather than insertion order: a rough-in drawing is read one
  // surface at a time, and all the ceiling work belongs together.
  final ordered = [
    for (final zone in RoomZone.values)
      ...model.locations.where((l) => l.zone == zone),
  ];

  for (final location in ordered) {
    final here = model.nodes.where((n) => n.locationId == location.id).toList();
    final jacks = here
        .where((n) => n.isJackField)
        .fold(0, (sum, n) => sum + n.ports.length);
    final devices = here.where((n) => !n.isJackField).length;
    final runs = model.cables
        .where(
          (c) =>
              model.nodesById[c.fromNodeId]?.locationId == location.id ||
              model.nodesById[c.toNodeId]?.locationId == location.id,
        )
        .length;

    rows.add([
      location.callout,
      location.name,
      kRoomZoneLabels[location.zone] ?? location.zone.name,
      devices,
      here.where((n) => n.isJackField).length,
      jacks,
      runs,
      // WHICH sheets, not just "yes". A set with a Level 1, a Level 2 and a
      // reflected ceiling plan is read one sheet at a time, and "the projector
      // box is on the RCP" is the answer somebody is actually looking for.
      [
        for (final p in model.floorPlans)
          if (p.hasMarker(location.id)) p.name,
      ].join('\n'),
      location.note,
    ]);
  }

  // Anything nobody has placed. Counted rather than dropped: a room where
  // half the gear has no location is a room whose per-location counts are
  // half the story, and saying so is the only honest way to print them.
  final unplaced = model.nodes.where((n) => n.locationId.isEmpty).toList();
  if (unplaced.isNotEmpty) {
    rows.add([
      '',
      '(no location recorded)',
      '',
      unplaced.where((n) => !n.isJackField).length,
      unplaced.where((n) => n.isJackField).length,
      unplaced
          .where((n) => n.isJackField)
          .fold(0, (sum, n) => sum + n.ports.length),
      '',
      '',
      'These are not counted under any location above',
    ]);
  }

  return (
    title: 'Locations',
    header: [
      'Callout',
      'Location',
      'Zone',
      'Devices',
      'Jack fields',
      'Jacks',
      'Cable ends',
      'On sheets',
      'Notes',
    ],
    rows: rows,
  );
}

/// Jacks per location, split by what they carry.
///
/// This is the sheet that sizes the back boxes and the conduit: "four network
/// and two AV in the front floor box" is an order; "six jacks somewhere" is
/// not. Grouped under the zone so all the wall plates read together.
ReportSection _jackCountsByLocation(AvFlowModel model) {
  final rows = <List<dynamic>>[];

  for (final zone in RoomZone.values) {
    final inZone = model.locations.where((l) => l.zone == zone).toList();
    if (inZone.isEmpty) continue;

    int zoneTotal = 0;
    final zoneRows = <List<dynamic>>[];

    for (final location in inZone) {
      final fields = model.nodes.where(
        (n) => n.isJackField && n.locationId == location.id,
      );
      // Per signal type, because a jack field can mix them and "12 jacks" is
      // not something anybody can buy a plate for.
      final byType = <SignalType, int>{};
      int used = 0;
      for (final field in fields) {
        for (final jack in field.ports) {
          byType[jack.signal] = (byType[jack.signal] ?? 0) + 1;
          final patched = model.cables.any(
            (c) =>
                (c.fromNodeId == field.id && c.fromPortId == jack.id) ||
                (c.toNodeId == field.id && c.toPortId == jack.id),
          );
          if (patched) used++;
        }
      }
      if (byType.isEmpty) continue;

      final total = byType.values.fold(0, (a, b) => a + b);
      zoneTotal += total;
      zoneRows.add([
        location.displayName,
        byType.entries
            .map((e) => '${kSignalCodes[e.key] ?? e.key.name} ×${e.value}')
            .join('\n'),
        total,
        used,
        total - used,
      ]);
    }

    if (zoneRows.isEmpty) continue;
    rows.add(['- ${kRoomZoneLabels[zone] ?? zone.name} -', '', zoneTotal, '', '']);
    rows.addAll(zoneRows);
  }

  return (
    title: 'Jack Counts by Location',
    header: ['Location', 'By signal', 'Jacks', 'Patched', 'Spare'],
    rows: rows,
  );
}

/// Cable runs landing at each location, per signal type — "AV lines on the
/// floor box, network lines on the floor box", which is the count the request
/// asked for and the one a rough-in estimate is built from.
///
/// A run is counted at BOTH its ends when they are in different places,
/// because both ends are a termination somebody has to make. A run with both
/// ends in the same location counts once there rather than twice, since it
/// never leaves the box.
ReportSection _lineCountsByLocation(AvFlowModel model) {
  final byId = model.nodesById;
  // location id (or '' for unplaced) -> signal -> count
  final counts = <String, Map<SignalType, int>>{};

  void bump(String locationId, SignalType signal) {
    counts.putIfAbsent(locationId, () => {});
    counts[locationId]![signal] = (counts[locationId]![signal] ?? 0) + 1;
  }

  for (final c in model.cables) {
    final from = byId[c.fromNodeId]?.locationId ?? kNoLocationId;
    final to = byId[c.toNodeId]?.locationId ?? kNoLocationId;
    bump(from, c.signal);
    if (to != from) bump(to, c.signal);
  }

  final rows = <List<dynamic>>[];
  final ordered = [
    for (final zone in RoomZone.values)
      ...model.locations.where((l) => l.zone == zone),
  ];

  for (final location in ordered) {
    final here = counts[location.id];
    if (here == null || here.isEmpty) continue;
    final total = here.values.fold(0, (a, b) => a + b);
    rows.add([
      location.displayName,
      kRoomZoneCodes[location.zone] ?? '-',
      total,
      for (final signal in _reportedSignals(model)) here[signal] ?? '',
    ]);
  }

  final unplaced = counts[kNoLocationId];
  if (unplaced != null && unplaced.isNotEmpty) {
    rows.add([
      '(no location recorded)',
      '',
      unplaced.values.fold(0, (a, b) => a + b),
      for (final signal in _reportedSignals(model)) unplaced[signal] ?? '',
    ]);
  }

  return (
    title: 'Line Counts by Location',
    header: [
      'Location',
      'Zone',
      'Total ends',
      for (final s in _reportedSignals(model)) kSignalCodes[s] ?? s.name,
    ],
    rows: rows,
  );
}

/// The signal types actually present, in enum order, so the count table has a
/// column per type in use and none for the fifteen that aren't.
List<SignalType> _reportedSignals(AvFlowModel model) {
  final used = {for (final c in model.cables) c.signal};
  return SignalType.values.where(used.contains).toList();
}

/// How many runs carry each label.
///
/// Cable labels are how a job is actually counted at the far end — a spool of
/// "AV-" runs and a spool of "NET-" runs are two orders — so the labels are
/// grouped by their non-numeric stem ('AV-01', 'AV-02' → 'AV-') as well as
/// listed in full. Runs with no label at all are counted and named, because an
/// unlabeled run is one nobody can find again.
List<ReportSection> _lineCountsByLabel(AvFlowModel model) {
  if (model.cables.isEmpty) return const [];

  final byStem = <String, List<AvCable>>{};
  int unlabeled = 0;
  for (final c in model.cables) {
    final label = c.label.trim();
    if (label.isEmpty) {
      unlabeled++;
      continue;
    }
    byStem.putIfAbsent(cableLabelStem(label), () => []).add(c);
  }

  if (byStem.isEmpty && unlabeled == 0) return const [];

  final stems = byStem.keys.toList()..sort();
  final rows = <List<dynamic>>[
    for (final stem in stems)
      [
        stem,
        byStem[stem]!.length,
        // Which signal types travel under this label — a stem carrying two is
        // usually a labeling slip worth seeing.
        {
          for (final c in byStem[stem]!) kSignalCodes[c.signal] ?? c.signal.name,
        }.join('\n'),
        (byStem[stem]!.map((c) => c.label).toList()..sort()).join('\n'),
      ],
    if (unlabeled > 0)
      [
        '(no label)',
        unlabeled,
        '',
        'These runs have no cable ID - they cannot be found from this sheet',
      ],
  ];

  return [
    (
      title: 'Line Counts by Label',
      header: ['Label group', 'Runs', 'Signal types', 'Labels'],
      rows: rows,
    ),
  ];
}

/// The non-numeric stem of a cable label: 'AV-01' → 'AV-', 'NET12' → 'NET'.
/// A label that is nothing but digits groups under itself, since there is no
/// stem to take.
String cableLabelStem(String label) {
  final trimmed = label.trim();
  final match = RegExp(r'^(.*?)(\d+)\s*$').firstMatch(trimmed);
  if (match == null) return trimmed;
  final stem = match.group(1)!;
  return stem.isEmpty ? trimmed : stem;
}

/// The cable runs drawn between the places in the room: what each one is for,
/// where it starts and where it ends.
///
/// These began as the low-voltage control runs — a screen switch on the wall
/// and the motor above the whiteboard — and neither end is a device on the
/// signal flow, so without this sheet such a run is one nobody drew, nobody
/// costed and nobody pulled. The sheet is called Cable Runs because that is
/// what it is used for: any run somebody has to pull between two places,
/// whatever it drives.
ReportSection _screenSwitchSchedule(AvFlowModel model) {
  String place(String locationId, String note) {
    final name = locationId.isEmpty
        ? ''
        : (model.locationById(locationId)?.displayName ?? '');
    if (name.isNotEmpty) return name;
    return note;
  }

  return (
    title: 'Cable Runs',
    header: [
      'Run',
      'Cable #',
      'Cables',
      'Start (switch)',
      'Routed through',
      'End (motor / screen)',
      'Cable',
      'Run (ft)',
      'Notes',
    ],
    rows: [
      for (final s in model.screenSwitches)
        [
          // What it controls IS the name of the run — 'Front screen' is what
          // it is called on the drawing and what somebody asks about. The
          // internal id (SCRSW_1) named nothing anybody could look up, and
          // printing both put the same run in two columns.
          s.label.trim().isEmpty ? s.id : s.label,
          s.cableNumber,
          // How many this run is. Six Cat 6 to a floor box is one run of six,
          // and a schedule that prints it as one is a schedule somebody
          // orders one cable against.
          s.cableCount <= 1 ? 1 : s.cableCount,
          place(s.startLocationId, s.startNote),
          // One route point per line: this is the list somebody counts back
          // boxes off, and a comma-separated string in one cell is a list
          // nobody counts twice the same way. Each says how many carry on
          // from it when that differs from the run.
          [
            for (int i = 0; i < s.viaLocationIds.length; i++)
              '${model.locationById(s.viaLocationIds[i])?.displayName ?? '(location removed)'}'
                  '${s.countForLeg(i + 1) == s.countForLeg(0) ? '' : ' — ${s.countForLeg(i + 1)} on'}',
          ].join('\n'),
          place(s.endLocationId, s.endNote),
          s.cableType,
          s.runFeet <= 0 ? '' : s.runFeet,
          s.note,
        ],
    ],
  );
}

/// The floor plan's callouts and what each one refers to.
///
/// This is the cross-reference the drawing set is read by: the plan says "see
/// 3", and this table says 3 is the equipment rack, described on the Racks tab
/// of the workbook. Resolving the target NAME here rather than making somebody
/// type it on the plan is what stops the two drifting apart when a rack is
/// renamed.
List<ReportSection> _floorPlanCallouts(AvFlowModel model) {
  final rows = <List<dynamic>>[];
  for (final plan in model.floorPlans) {
    for (final c in plan.callouts) {
      rows.add([
        c.tag,
        plan.name,
        kCalloutTargetLabels[c.target] ?? c.target.name,
        _calloutTargetName(model, c),
        c.workbookSheet,
        c.workbookRef,
        c.note,
      ]);
    }
  }
  if (rows.isEmpty) return const [];
  return [
    (
      title: 'Floor Plan Callouts',
      header: [
        'Callout',
        'Plan',
        'Refers to',
        'Name',
        'Workbook sheet',
        'Reference',
        'Notes',
      ],
      rows: rows,
    ),
  ];
}

String _calloutTargetName(AvFlowModel model, FloorPlanCallout c) {
  switch (c.target) {
    case CalloutTarget.rack:
      for (final r in model.racks) {
        if (r.id == c.targetId) return r.name;
      }
      return c.targetId.isEmpty ? '' : '(rack no longer in this room)';
    case CalloutTarget.device:
      return model.nodesById[c.targetId]?.label ??
          (c.targetId.isEmpty ? '' : '(device no longer on the diagram)');
    case CalloutTarget.location:
      return model.locationById(c.targetId)?.displayName ??
          (c.targetId.isEmpty ? '' : '(location removed)');
    case CalloutTarget.sheet:
    case CalloutTarget.note:
      return '';
  }
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
      // One name per line: this is a list somebody ticks off against what
      // is in the crate, and four names run together in one cell is a list
      // nobody can tick. (The estimate PAGE keeps them comma-joined, where a
      // four-line cell would push the row apart.)
      group.nodes.map((n) => n.label).join('\n'),
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
      // Where the units of this line go. A group can straddle places — four
      // identical ceiling mics in two rows — so the distinct locations are
      // listed rather than the first one, which would quietly send them all
      // to one end of the room.
      {
        for (final n in group.nodes)
          if (n.locationId.isNotEmpty) model.locationNameOf(n.id),
      }.where((s) => s.isNotEmpty).join('\n'),
      // The pack list keeps a device the estimate leaves out: it is in the
      // room and it has to be found, wired and racked whoever paid for it.
      // Saying so here is what stops the two sheets looking like they
      // disagree about the same box.
      [
        first.fromConfig ? 'Room config' : 'Added manually',
        if (first.excludeFromCost) 'not quoted',
      ].join(' · '),
      group.nodes
          .map((n) => n.note)
          .where((n) => n.trim().isNotEmpty)
          .toSet()
          .join('\n'),
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
      'Location',
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
///
/// Public because it belongs on more than the AV report: a COST-ONLY estimate
/// is a document somebody signs off, and a room quoted without anybody noticing
/// that three of its devices have no driver is a room that arrives on site and
/// cannot be commissioned. Every cost export appends this for that reason.
List<ReportSection> driverGapSections(
  AppStateProvider provider,
  AvFlowModel model,
) {
  final gaps = controlGapsForRoom(
    config: provider.roomConfig,
    model: model,
    deviceCountMap: provider.uiSchema.deviceCountMap,
    library: provider.avDeviceLibrary,
    moduleForModel: provider.moduleForModel,
  );
  if (gaps.isEmpty) return const [];
  return [
    (
      title: 'Devices Without a Control Module',
      header: const ['Device', 'Model', 'Qty', 'From', 'Note'],
      rows: [
        for (final gap in gaps)
          [
            gap.device,
            gap.model.isEmpty ? '(no model set)' : gap.model,
            gap.qty,
            gap.sourceLabel,
            gap.note,
          ],
      ],
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
        '$unmetered - the total above is short by whatever they draw',
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
      rows.add([rack.name, '', '', '', '- ${rack.kind} -', '']);
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
          model.locationNameOf(field.id),
          jack.label,
          kSignalCodes[jack.signal] ?? jack.signal.name,
          '(spare)',
          '',
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
          model.locationNameOf(field.id),
          jack.label,
          kSignalCodes[c.signal] ?? c.signal.name,
          byId[farNode]?.label ?? farNode,
          byId[farNode]?.portById(farPort)?.label ?? farPort,
          // Where the far end lands — the second half of "where does this
          // jack go", which is the whole question the sheet is read for.
          model.locationNameOf(farNode),
          c.id,
        ]);
      }
    }
  }

  return (
    title: 'Jack Schedule',
    header: [
      'Wall box / panel',
      'Location',
      'Jack',
      'Signal',
      'Connected device',
      'Device port',
      'Device location',
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
