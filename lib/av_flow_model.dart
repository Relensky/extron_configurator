import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ============================================================================
///  AV SIGNAL FLOW — DATA MODEL
/// ============================================================================
///  The Schematic tab documents how devices talk to the PROCESSOR (control:
///  network / serial / SoE / relay). This model documents the other half of
///  the room: how video and audio actually get from source to destination.
///
///  The room config carries no AV data at all — a device block knows its
///  ip_address and com_type, not that it has four HDMI inputs — so the AV
///  diagram is built from three layers:
///
///    1. NODES seeded from the config's active device blocks (same dev_ count
///       logic the Devices and Schematic tabs use), plus nodes the user adds
///       by hand for gear the control config never sees (displays, wall
///       plates, speakers, patch panels).
///    2. PORTS resolved per node from [AvDeviceLibrary] — an av_devices.json
///       model lookup with family-generic fallbacks — and overridable per
///       node in the port editor.
///    3. CABLES drawn by the user, port to port, colored by signal type.
///
///  Everything here is pure data + geometry: no widgets, no provider. The
///  view (av_flow_view.dart) and the reports (av_flow_report.dart) both read
///  the same anchor math so a cable is painted exactly where its port is
///  drawn and hit-tested.
/// ============================================================================

// ---------------------------------------------------------------------------
//  SIGNAL TYPES
// ---------------------------------------------------------------------------

/// What travels down a cable. Drives the line color, the legend, and the
/// compatibility check when two ports are joined.
enum SignalType {
  // Video
  hdmi,
  hdbaset,
  displayPort,
  usbC,
  sdi,
  vga,
  // Audio
  analogAudio,
  digitalAudio,
  dante,
  micLine,
  speaker,
  // Support
  usbData,
  network,
  ir,
  serial,
  power,
  other,
}

/// Line color per signal type. Video runs cool (blues/violets), audio runs
/// warm (greens/ambers), support signals stay muted so they read as
/// infrastructure rather than program signal.
const Map<SignalType, Color> kSignalColors = {
  SignalType.hdmi: Color(0xFF42A5F5), // blue
  SignalType.hdbaset: Color(0xFF5C6BC0), // indigo
  SignalType.displayPort: Color(0xFF7E57C2), // deep purple
  SignalType.usbC: Color(0xFF26C6DA), // cyan
  SignalType.sdi: Color(0xFF29B6F6), // light blue
  SignalType.vga: Color(0xFF8D6E63), // brown (legacy)
  SignalType.analogAudio: Color(0xFF66BB6A), // green
  SignalType.digitalAudio: Color(0xFF26A69A), // teal
  SignalType.dante: Color(0xFF9CCC65), // light green
  SignalType.micLine: Color(0xFFFFA726), // orange
  SignalType.speaker: Color(0xFFEF5350), // red
  SignalType.usbData: Color(0xFFEC407A), // pink
  SignalType.network: Color(0xFF78909C), // blue grey
  SignalType.ir: Color(0xFFFFEE58), // yellow
  SignalType.serial: Color(0xFFAB47BC), // purple
  SignalType.power: Color(0xFF616161), // grey
  SignalType.other: Color(0xFF90A4AE), // pale blue grey
};

/// Legend text.
const Map<SignalType, String> kSignalLabels = {
  SignalType.hdmi: 'HDMI',
  SignalType.hdbaset: 'HDBaseT / DTP',
  SignalType.displayPort: 'DisplayPort',
  SignalType.usbC: 'USB-C (video)',
  SignalType.sdi: 'SDI',
  SignalType.vga: 'VGA / Analog video',
  SignalType.analogAudio: 'Analog audio',
  SignalType.digitalAudio: 'Digital audio (AES/SPDIF)',
  SignalType.dante: 'Dante / AES67',
  SignalType.micLine: 'Mic / Line',
  SignalType.speaker: 'Speaker level',
  SignalType.usbData: 'USB (data)',
  SignalType.network: 'Network',
  SignalType.ir: 'IR',
  SignalType.serial: 'Serial',
  SignalType.power: 'Power',
  SignalType.other: 'Other',
};

/// Short code used in the cable schedule so the column stays narrow.
const Map<SignalType, String> kSignalCodes = {
  SignalType.hdmi: 'HDMI',
  SignalType.hdbaset: 'HDBT',
  SignalType.displayPort: 'DP',
  SignalType.usbC: 'USBC',
  SignalType.sdi: 'SDI',
  SignalType.vga: 'VGA',
  SignalType.analogAudio: 'AAUD',
  SignalType.digitalAudio: 'DAUD',
  SignalType.dante: 'DANTE',
  SignalType.micLine: 'MIC',
  SignalType.speaker: 'SPKR',
  SignalType.usbData: 'USB',
  SignalType.network: 'NET',
  SignalType.ir: 'IR',
  SignalType.serial: 'SER',
  SignalType.power: 'PWR',
  SignalType.other: 'OTHER',
};

/// Signal types that carry a picture — used to group the legend and to decide
/// whether a mismatch is worth warning about (HDMI into DisplayPort is an
/// adapter; HDMI into a speaker terminal is a mistake).
const Set<SignalType> kVideoSignals = {
  SignalType.hdmi,
  SignalType.hdbaset,
  SignalType.displayPort,
  SignalType.usbC,
  SignalType.sdi,
  SignalType.vga,
};

const Set<SignalType> kAudioSignals = {
  SignalType.analogAudio,
  SignalType.digitalAudio,
  SignalType.dante,
  SignalType.micLine,
  SignalType.speaker,
};

/// The colour a signal type is drawn in, honouring the room's palette.
///
/// [kSignalColors] is only the factory default. A room can recolour any type
/// — see `avSignalColors` in app_state.dart — and when it does, EVERY cable,
/// port dot and legend entry of that type has to move together, or the key
/// stops describing the drawing. So nothing reads [kSignalColors] directly
/// except this function.
Color signalColor(SignalType s, [Map<SignalType, Color>? palette]) =>
    palette?[s] ?? kSignalColors[s] ?? kSignalColors[SignalType.other]!;

SignalType signalFromName(String? name) {
  if (name == null) return SignalType.other;
  final key = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  for (final s in SignalType.values) {
    if (s.name.toLowerCase() == key) return s;
  }
  // Friendlier spellings people actually write in av_devices.json.
  const aliases = {
    'dtp': SignalType.hdbaset,
    'hdbt': SignalType.hdbaset,
    'dp': SignalType.displayPort,
    'usbcvideo': SignalType.usbC,
    'audio': SignalType.analogAudio,
    'analog': SignalType.analogAudio,
    'line': SignalType.analogAudio,
    'aes': SignalType.digitalAudio,
    'spdif': SignalType.digitalAudio,
    'aes67': SignalType.dante,
    'mic': SignalType.micLine,
    'micline': SignalType.micLine,
    'usb': SignalType.usbData,
    'lan': SignalType.network,
    'ethernet': SignalType.network,
    'rs232': SignalType.serial,
  };
  return aliases[key] ?? SignalType.other;
}

// ---------------------------------------------------------------------------
//  PORTS
// ---------------------------------------------------------------------------

/// What a box on the canvas represents. Only [jackField] behaves differently:
/// its "ports" are numbered jacks in a wall box, floor box or patch panel, so
/// the report can say which device landed on which jack number.
enum AvNodeKind { device, jackField }

AvNodeKind nodeKindFromName(String? name) =>
    name?.trim().toLowerCase() == 'jackfield'
    ? AvNodeKind.jackField
    : AvNodeKind.device;

/// Where a device gets its mains from. Recorded per device so the power
/// report can separate "on the APC, outlet 3" from "straight into the wall"
/// from "PoE off the switch" — the three answers an installer needs.
enum PowerSource { unspecified, controller, wall, poe, none }

const Map<PowerSource, String> kPowerSourceLabels = {
  PowerSource.unspecified: 'Not recorded',
  PowerSource.controller: 'Power controller outlet',
  PowerSource.wall: 'Wall / building outlet',
  PowerSource.poe: 'PoE',
  PowerSource.none: 'No mains needed',
};

PowerSource powerSourceFromName(String? name) {
  switch (name?.trim().toLowerCase()) {
    case 'controller':
      return PowerSource.controller;
    case 'wall':
      return PowerSource.wall;
    case 'poe':
      return PowerSource.poe;
    case 'none':
      return PowerSource.none;
    default:
      return PowerSource.unspecified;
  }
}

enum PortDirection { input, output, bidirectional }

/// Which edge of the node box a port sits on. Inputs default to the left and
/// outputs to the right so signal reads left-to-right across the page.
enum PortSide { left, right, top, bottom }

PortDirection directionFromName(String? name) {
  switch (name?.trim().toLowerCase()) {
    case 'out':
    case 'output':
      return PortDirection.output;
    case 'bidi':
    case 'both':
    case 'bidirectional':
      return PortDirection.bidirectional;
    default:
      return PortDirection.input;
  }
}

PortSide sideFromName(String? name, PortDirection direction) {
  switch (name?.trim().toLowerCase()) {
    case 'left':
      return PortSide.left;
    case 'right':
      return PortSide.right;
    case 'top':
      return PortSide.top;
    case 'bottom':
      return PortSide.bottom;
  }
  return direction == PortDirection.output ? PortSide.right : PortSide.left;
}

/// One connector on a device.
class AvPort {
  /// Stable within its device ('in_hdmi_1'). Cables reference this, so
  /// renaming a port's [label] never breaks existing cabling.
  final String id;
  final String label;
  final SignalType signal;
  final PortDirection direction;
  final PortSide side;

  const AvPort({
    required this.id,
    required this.label,
    required this.signal,
    required this.direction,
    required this.side,
  });

  bool get isOutput => direction == PortDirection.output;
  bool get isInput => direction == PortDirection.input;

  AvPort copyWith({
    String? id,
    String? label,
    SignalType? signal,
    PortDirection? direction,
    PortSide? side,
  }) => AvPort(
    id: id ?? this.id,
    label: label ?? this.label,
    signal: signal ?? this.signal,
    direction: direction ?? this.direction,
    side: side ?? this.side,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'signal': signal.name,
    'direction': direction.name,
    'side': side.name,
  };

  factory AvPort.fromJson(Map<String, dynamic> json) {
    final direction = directionFromName(json['direction']?.toString());
    return AvPort(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString() ?? json['id']?.toString() ?? '',
      signal: signalFromName(json['signal']?.toString()),
      direction: direction,
      side: sideFromName(json['side']?.toString(), direction),
    );
  }
}

/// The outcome of checking whether two ports may be cabled together.
enum PortMatch {
  /// Same signal type, output into input — draw it.
  ok,

  /// Output into input but the signal types differ. Real rooms are full of
  /// adapters, so this is a confirm, not a refusal.
  signalMismatch,

  /// Two outputs, two inputs, the same port twice, or the same device twice.
  invalid,
}

/// Whether [from] may feed [to]. Bidirectional ports (USB-C, Dante, network)
/// satisfy either role.
PortMatch checkPortMatch(
  AvNode fromNode,
  AvPort from,
  AvNode toNode,
  AvPort to,
) {
  if (fromNode.id == toNode.id && from.id == to.id) return PortMatch.invalid;
  final fromCanSource = from.direction != PortDirection.input;
  final toCanSink = to.direction != PortDirection.output;
  if (!fromCanSource || !toCanSink) return PortMatch.invalid;
  if (from.signal == to.signal) return PortMatch.ok;
  return PortMatch.signalMismatch;
}

// ---------------------------------------------------------------------------
//  NODES
// ---------------------------------------------------------------------------

/// Box geometry. Unlike the control schematic's fixed kNodeWidth/kNodeHeight,
/// an AV node grows with its port count and label lengths.
const double kAvNodeMinWidth = 190;
const double kAvNodeMaxWidth = 300;
const double kAvNodeHeaderHeight = 42;
const double kAvPortRowHeight = 22;
const double kAvNodeMinBodyHeight = 20;
const double kAvNodePadBottom = 10;

/// Radius of the round port handle drawn on the node edge.
const double kAvPortHandleRadius = 5.5;

/// One piece of equipment on the AV canvas.
class AvNode {
  /// Config section key ('SWITCHERDEVICE_1') for seeded devices, or
  /// `AVNODE_<n>` for anything the user added by hand.
  final String id;
  final String label;
  final String model;

  /// Top-left on the canvas.
  final Offset pos;
  final List<AvPort> ports;

  /// True when this node mirrors a config device block. Seeded nodes vanish
  /// when the device is removed from the config; manual nodes never do.
  final bool fromConfig;

  /// Rack height; 0 means "not rack mounted" and keeps it out of the racks.
  final int rackUnits;

  /// Device or numbered jack field (wall box / floor box / patch panel).
  final AvNodeKind kind;

  /// Where this device's mains comes from.
  final PowerSource powerSource;

  /// Free-text note carried into the pack list.
  final String note;

  const AvNode({
    required this.id,
    required this.label,
    required this.model,
    required this.pos,
    required this.ports,
    this.fromConfig = false,
    this.rackUnits = 0,
    this.kind = AvNodeKind.device,
    this.powerSource = PowerSource.unspecified,
    this.note = '',
  });

  bool get isJackField => kind == AvNodeKind.jackField;

  AvNode copyWith({
    String? label,
    String? model,
    Offset? pos,
    List<AvPort>? ports,
    bool? fromConfig,
    int? rackUnits,
    AvNodeKind? kind,
    PowerSource? powerSource,
    String? note,
  }) => AvNode(
    id: id,
    label: label ?? this.label,
    model: model ?? this.model,
    pos: pos ?? this.pos,
    ports: ports ?? this.ports,
    fromConfig: fromConfig ?? this.fromConfig,
    rackUnits: rackUnits ?? this.rackUnits,
    kind: kind ?? this.kind,
    powerSource: powerSource ?? this.powerSource,
    note: note ?? this.note,
  );

  List<AvPort> get leftPorts =>
      ports.where((p) => p.side == PortSide.left).toList();
  List<AvPort> get rightPorts =>
      ports.where((p) => p.side == PortSide.right).toList();
  List<AvPort> get topPorts =>
      ports.where((p) => p.side == PortSide.top).toList();
  List<AvPort> get bottomPorts =>
      ports.where((p) => p.side == PortSide.bottom).toList();

  AvPort? portById(String portId) {
    for (final p in ports) {
      if (p.id == portId) return p;
    }
    return null;
  }

  /// Width driven by the longest label that has to fit inside the box: the
  /// title, and the widest left+right port label pair sharing a row.
  double get width {
    // ~6.2px per character at the 11px port font, ~7px at the 13px title.
    double w = 24 + label.length * 7.0;
    final left = leftPorts, right = rightPorts;
    for (int i = 0; i < math.max(left.length, right.length); i++) {
      final l = i < left.length ? left[i].label.length : 0;
      final r = i < right.length ? right[i].label.length : 0;
      w = math.max(w, 34 + (l + r) * 6.2);
    }
    if (model.isNotEmpty) w = math.max(w, 24 + model.length * 6.0);
    return w.clamp(kAvNodeMinWidth, kAvNodeMaxWidth);
  }

  double get height {
    final rows = math.max(leftPorts.length, rightPorts.length);
    final body = math.max(kAvNodeMinBodyHeight, rows * kAvPortRowHeight);
    // Top/bottom ports ride the edges and need a little breathing room.
    final edgePad =
        (topPorts.isEmpty ? 0.0 : 6.0) + (bottomPorts.isEmpty ? 0.0 : 6.0);
    return kAvNodeHeaderHeight + body + kAvNodePadBottom + edgePad;
  }

  Size get size => Size(width, height);

  Rect get rect => pos & size;

  Offset get center => pos + Offset(width / 2, height / 2);

  /// Where a port's handle sits, in canvas coordinates. This is THE source of
  /// truth: the node widget positions its handles with the same math (via
  /// [localAnchorOf]) so painted cables land on the drawn dots.
  Offset anchorOf(String portId) => pos + localAnchorOf(portId);

  /// Port handle position relative to the node's top-left.
  Offset localAnchorOf(String portId) {
    final w = width;
    for (final (list, side) in [
      (leftPorts, PortSide.left),
      (rightPorts, PortSide.right),
      (topPorts, PortSide.top),
      (bottomPorts, PortSide.bottom),
    ]) {
      final index = list.indexWhere((p) => p.id == portId);
      if (index < 0) continue;
      switch (side) {
        case PortSide.left:
          return Offset(0, _rowCenterY(index));
        case PortSide.right:
          return Offset(w, _rowCenterY(index));
        case PortSide.top:
          return Offset(_edgeX(index, list.length, w), 0);
        case PortSide.bottom:
          return Offset(_edgeX(index, list.length, w), height);
      }
    }
    // Unknown port: fall back to the box center so nothing paints off-screen.
    return Offset(w / 2, height / 2);
  }

  /// Direction a cable should leave/enter this port, so routes exit outward
  /// instead of cutting back across the box.
  Offset normalOf(String portId) {
    final port = portById(portId);
    switch (port?.side) {
      case PortSide.left:
        return const Offset(-1, 0);
      case PortSide.top:
        return const Offset(0, -1);
      case PortSide.bottom:
        return const Offset(0, 1);
      default:
        return const Offset(1, 0);
    }
  }

  double _rowCenterY(int index) =>
      kAvNodeHeaderHeight +
      (topPorts.isEmpty ? 0.0 : 6.0) +
      index * kAvPortRowHeight +
      kAvPortRowHeight / 2;

  static double _edgeX(int index, int count, double w) =>
      w * (index + 1) / (count + 1);

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'model': model,
    'x': pos.dx,
    'y': pos.dy,
    'fromConfig': fromConfig,
    'rackUnits': rackUnits,
    if (kind != AvNodeKind.device) 'kind': kind.name,
    if (powerSource != PowerSource.unspecified) 'power': powerSource.name,
    if (note.isNotEmpty) 'note': note,
    'ports': ports.map((p) => p.toJson()).toList(),
  };

  factory AvNode.fromJson(Map<String, dynamic> json) => AvNode(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    pos: Offset(
      (json['x'] as num?)?.toDouble() ?? 0,
      (json['y'] as num?)?.toDouble() ?? 0,
    ),
    fromConfig: json['fromConfig'] == true,
    rackUnits: (json['rackUnits'] as num?)?.toInt() ?? 0,
    kind: nodeKindFromName(json['kind']?.toString()),
    powerSource: powerSourceFromName(json['power']?.toString()),
    note: json['note']?.toString() ?? '',
    ports: [
      for (final p in (json['ports'] as List? ?? []))
        if (p is Map) AvPort.fromJson(Map<String, dynamic>.from(p)),
    ],
  );
}

// ---------------------------------------------------------------------------
//  CABLES
// ---------------------------------------------------------------------------

/// One cable run between two ports.
class AvCable {
  final String id;
  final String fromNodeId;
  final String fromPortId;
  final String toNodeId;
  final String toPortId;

  /// Defaults to the source port's signal; overridable so a run through an
  /// adapter can be labeled for what it physically is.
  final SignalType signal;

  /// Cable ID / note shown on the line and in the schedule.
  final String label;

  /// Manual route overrides. Empty means "use the automatic route".
  final List<Offset> waypoints;

  /// Paints this one run in a colour of its own instead of the signal type's.
  /// Null — the normal case — means "follow the signal type", so a later
  /// change to the palette still reaches it.
  final Color? colorOverride;

  const AvCable({
    required this.id,
    required this.fromNodeId,
    required this.fromPortId,
    required this.toNodeId,
    required this.toPortId,
    required this.signal,
    this.label = '',
    this.waypoints = const [],
    this.colorOverride,
  });

  /// [clearColorOverride] exists because passing null to [colorOverride]
  /// cannot be told apart from "leave it alone" in a copyWith.
  AvCable copyWith({
    SignalType? signal,
    String? label,
    List<Offset>? waypoints,
    Color? colorOverride,
    bool clearColorOverride = false,
  }) => AvCable(
    id: id,
    fromNodeId: fromNodeId,
    fromPortId: fromPortId,
    toNodeId: toNodeId,
    toPortId: toPortId,
    signal: signal ?? this.signal,
    label: label ?? this.label,
    waypoints: waypoints ?? this.waypoints,
    colorOverride: clearColorOverride
        ? null
        : (colorOverride ?? this.colorOverride),
  );

  /// The colour this run is actually drawn in: its own override if it has
  /// one, otherwise whatever the room's palette says its signal type is.
  Color colorFor([Map<SignalType, Color>? palette]) =>
      colorOverride ?? signalColor(signal, palette);

  /// True when this run is drawn in something other than its signal colour —
  /// the legend calls those out so it doesn't quietly lie about the diagram.
  bool get hasCustomColor => colorOverride != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromNode': fromNodeId,
    'fromPort': fromPortId,
    'toNode': toNodeId,
    'toPort': toPortId,
    'signal': signal.name,
    if (label.isNotEmpty) 'label': label,
    if (colorOverride != null)
      'color': (colorOverride!.toARGB32() & 0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0'),
    if (waypoints.isNotEmpty)
      'waypoints': [
        for (final w in waypoints) {'x': w.dx, 'y': w.dy},
      ],
  };

  factory AvCable.fromJson(Map<String, dynamic> json) {
    final rawColor = json['color']?.toString();
    final parsed = rawColor == null ? null : int.tryParse(rawColor, radix: 16);
    return AvCable(
      id: json['id']?.toString() ?? '',
      fromNodeId: json['fromNode']?.toString() ?? '',
      fromPortId: json['fromPort']?.toString() ?? '',
      toNodeId: json['toNode']?.toString() ?? '',
      toPortId: json['toPort']?.toString() ?? '',
      signal: signalFromName(json['signal']?.toString()),
      label: json['label']?.toString() ?? '',
      colorOverride: parsed == null ? null : Color(0xFF000000 | parsed),
      waypoints: [
        for (final w in (json['waypoints'] as List? ?? []))
          if (w is Map)
            Offset(
              (w['x'] as num?)?.toDouble() ?? 0,
              (w['y'] as num?)?.toDouble() ?? 0,
            ),
      ],
    );
  }
}

/// Colours offered when recolouring a single run. The signal palette first —
/// so "make this one look like Dante" is one click — then a few neutrals that
/// aren't spoken for.
const List<Color> kCableSwatches = [
  Color(0xFF42A5F5),
  Color(0xFF5C6BC0),
  Color(0xFF7E57C2),
  Color(0xFF26C6DA),
  Color(0xFF66BB6A),
  Color(0xFF26A69A),
  Color(0xFF9CCC65),
  Color(0xFFFFA726),
  Color(0xFFEF5350),
  Color(0xFFEC407A),
  Color(0xFF78909C),
  Color(0xFFFFEE58),
  Color(0xFFAB47BC),
  Color(0xFF8D6E63),
  Color(0xFF616161),
  Color(0xFFECEFF1),
];

// ---------------------------------------------------------------------------
//  RACKS
// ---------------------------------------------------------------------------

enum RackFace { front, rear }

/// What kind of frame this is. Purely descriptive — it doesn't change the
/// geometry, it just tells whoever reads the elevation where the thing lives.
/// The list is a starting point; [RackFrame.kindLabel] carries free text so a
/// room can call it whatever it actually is.
const List<String> kRackKinds = [
  'Free-standing rack',
  'Wall-mounted rack',
  'Lectern built-in rack',
  'Credenza / cabinet rack',
  'Under-table rack',
  'Equipment room rack',
];

/// How many devices share one rail position, and which slice this one is.
///
/// A rail is divided into [columns] equal slices and this device sits in
/// slice [column]. Alone on a U that's 1 slice of 1 — the whole width. Drop a
/// second box on the same U and both become halves; a third makes thirds.
/// That is how a shelf of small gear actually gets recorded: a Revolabs
/// receiver, a DTP receiver and a micro PC all on the same 2U.
class RackColumn {
  final int column;
  final int columns;

  const RackColumn({this.column = 0, this.columns = 1});

  static const RackColumn full = RackColumn();

  /// Fraction of the rail this slice starts at and ends at, used for the
  /// overlap test — fractions compare correctly even when two neighbouring
  /// rows are split a different number of ways.
  double get start => column / columns;
  double get end => (column + 1) / columns;

  bool overlaps(RackColumn other) => start < other.end && other.start < end;

  RackColumn copyWith({int? column, int? columns}) => RackColumn(
    column: column ?? this.column,
    columns: columns ?? this.columns,
  );

  /// How this reads in a report: "1 of 3 (left)" is noise, "1/3" is not.
  String get label => columns <= 1 ? 'Full' : '${column + 1}/$columns';
}

/// Most rails are split at most this many ways; beyond it the labels stop
/// being readable and it stops being a rack elevation.
const int kMaxRackColumns = 4;

/// A rack frame on the elevation page.
class RackFrame {
  final String id;
  final String name;
  final int heightU;

  /// What sort of frame it is — "Lectern built-in rack", "Wall-mounted rack",
  /// and so on. Free text, so a room isn't limited to [kRackKinds]. This used
  /// to be baked into the height presets ("12U wall"), which was wrong: a 12U
  /// frame is just as likely to be under a lectern.
  final String kind;

  /// Left edge on the elevation page; frames sit side by side.
  final double x;

  const RackFrame({
    required this.id,
    required this.name,
    required this.heightU,
    this.kind = '',
    this.x = 0,
  });

  RackFrame copyWith({String? name, int? heightU, String? kind, double? x}) =>
      RackFrame(
        id: id,
        name: name ?? this.name,
        heightU: heightU ?? this.heightU,
        kind: kind ?? this.kind,
        x: x ?? this.x,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'heightU': heightU,
    if (kind.isNotEmpty) 'kind': kind,
    'x': x,
  };

  factory RackFrame.fromJson(Map<String, dynamic> json) => RackFrame(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Rack',
    heightU: (json['heightU'] as num?)?.toInt() ?? 42,
    kind: json['kind']?.toString() ?? '',
    x: (json['x'] as num?)?.toDouble() ?? 0,
  );
}

/// Rack presets offered when adding a frame.
/// Common heights offered as one-click shortcuts. Heights only — where the
/// frame lives is [RackFrame.kind], not something to infer from its size.
const List<int> kRackHeightPresets = [42, 24, 18, 12, 8, 6, 4, 2];

/// Where one device sits in a rack. Keyed by node id in the state map, so a
/// device can only be in one place — which is the physical truth.
class RackSlot {
  final String rackId;

  /// 1-based U of the device's BOTTOM rail, counting up from the floor, which
  /// is how rack elevations are actually numbered.
  final int startU;
  final RackFace face;

  /// Which slice of the rail this device takes; the whole width by default.
  final RackColumn slice;

  const RackSlot({
    required this.rackId,
    required this.startU,
    this.face = RackFace.front,
    this.slice = RackColumn.full,
  });

  RackSlot copyWith({
    String? rackId,
    int? startU,
    RackFace? face,
    RackColumn? slice,
  }) => RackSlot(
    rackId: rackId ?? this.rackId,
    startU: startU ?? this.startU,
    face: face ?? this.face,
    slice: slice ?? this.slice,
  );

  Map<String, dynamic> toJson() => {
    'rack': rackId,
    'startU': startU,
    'face': face.name,
    if (slice.columns > 1) 'column': slice.column,
    if (slice.columns > 1) 'columns': slice.columns,
  };

  factory RackSlot.fromJson(Map<String, dynamic> json) {
    // 'half' is the older two-slice format (left/right). Read it so diagrams
    // saved before rails could be split any number of ways still open.
    final legacyHalf = json['half']?.toString().trim().toLowerCase();
    final RackColumn slice;
    if (json['columns'] != null) {
      final columns = ((json['columns'] as num?)?.toInt() ?? 1).clamp(
        1,
        kMaxRackColumns,
      );
      final column = ((json['column'] as num?)?.toInt() ?? 0).clamp(
        0,
        columns - 1,
      );
      slice = RackColumn(column: column, columns: columns);
    } else if (legacyHalf == 'left') {
      slice = const RackColumn(column: 0, columns: 2);
    } else if (legacyHalf == 'right') {
      slice = const RackColumn(column: 1, columns: 2);
    } else {
      slice = RackColumn.full;
    }

    return RackSlot(
      rackId: json['rack']?.toString() ?? '',
      startU: (json['startU'] as num?)?.toInt() ?? 1,
      face: json['face']?.toString() == 'rear' ? RackFace.rear : RackFace.front,
      slice: slice,
    );
  }
}

// ---------------------------------------------------------------------------
//  CABLE ROUTING
// ---------------------------------------------------------------------------

/// Builds the polyline for [cable] between two nodes.
///
/// Manual waypoints win outright. Otherwise the route is orthogonal: it steps
/// out of the source port along its normal, runs down a vertical lane, and
/// steps into the destination port along its normal. [lane] shifts that
/// vertical leg so cables sharing a corridor don't stack on one line.
///
/// When the quick shapes all cut through something, a real pathfinder takes
/// over ([latticeRoute]), so a run cannot end up drawn behind a device.
List<Offset> routeCable({
  required AvNode fromNode,
  required AvNode toNode,
  required AvCable cable,
  double lane = 0,
  List<Rect> obstacles = const [],
}) {
  final start = fromNode.anchorOf(cable.fromPortId);
  final end = toNode.anchorOf(cable.toPortId);

  // Hand-placed bends say where the run should GO; they don't licence it to
  // cut through a device on the way. Each leg between consecutive bends is
  // kept exactly as drawn when it's clear, and routed around when it isn't,
  // so the shape the user asked for survives without the line crossing a box.
  if (cable.waypoints.isNotEmpty) {
    final guide = [start, ...cable.waypoints, end];
    if (obstacles.isEmpty) return guide;

    final out = <Offset>[guide.first];
    for (int i = 0; i < guide.length - 1; i++) {
      final p = guide[i], q = guide[i + 1];
      if (!_segmentBlocked(p, q, obstacles)) {
        out.add(q);
        continue;
      }
      final detour = latticeRoute(p, q, obstacles);
      if (detour == null) {
        out.add(q); // nowhere to go; the straight leg is the best on offer
        continue;
      }
      out.addAll(detour.skip(1));
    }
    return _mergeCollinear(out);
  }

  const stub = 18.0;
  final sN = fromNode.normalOf(cable.fromPortId);
  final eN = toNode.normalOf(cable.toPortId);
  final a = start + Offset(sN.dx * stub, sN.dy * stub);
  final b = end + Offset(eN.dx * stub, eN.dy * stub);

  List<Offset> full(List<Offset> middle) => [start, ...middle, end];

  // Check the WHOLE run, stubs included. The stub leaves its port straight
  // out of the box face, but a neighbour parked right against that face can
  // still be in the way — checking only the middle is how runs kept ending
  // up drawn across a device.
  bool clear(List<Offset> middle) => !polylineHitsAny(full(middle), obstacles);

  // --- the quick shapes, tried nearest-to-ideal first --------------------
  final candidates = <List<Offset>>[];

  if (sN.dy == 0 && eN.dy == 0) {
    if ((a.dy - b.dy).abs() < 1) candidates.add([a, b]);
    final ideal = (a.dx + b.dx) / 2 + lane;
    for (final shift in _kDetourShifts) {
      final midX = ideal + shift;
      candidates.add([a, Offset(midX, a.dy), Offset(midX, b.dy), b]);
    }
    final band = _clearBand(obstacles, a, b, horizontal: true);
    if (band != null) {
      candidates.add([a, Offset(a.dx, band), Offset(b.dx, band), b]);
    }
  } else if (sN.dx == 0 && eN.dx == 0) {
    if ((a.dx - b.dx).abs() < 1) candidates.add([a, b]);
    final ideal = (a.dy + b.dy) / 2 + lane;
    for (final shift in _kDetourShifts) {
      final midY = ideal + shift;
      candidates.add([a, Offset(a.dx, midY), Offset(b.dx, midY), b]);
    }
    final band = _clearBand(obstacles, a, b, horizontal: false);
    if (band != null) {
      candidates.add([a, Offset(band, a.dy), Offset(band, b.dy), b]);
    }
  } else {
    candidates
        .add([a, sN.dy == 0 ? Offset(b.dx, a.dy) : Offset(a.dx, b.dy), b]);
    candidates
        .add([a, sN.dy == 0 ? Offset(a.dx, b.dy) : Offset(b.dx, a.dy), b]);
  }

  for (final middle in candidates) {
    if (clear(middle)) return full(middle);
  }

  // --- nothing simple fits: find an actual way through -------------------
  // First keeping the tidy stubs, since a run that leaves its port squarely
  // reads far better than one that sets off at the first opportunity.
  final viaStubs = latticeRoute(a, b, obstacles);
  if (viaStubs != null && clear(viaStubs)) return full(viaStubs);

  // The stub itself is fouled by something parked against the port, so let
  // the search start at the port instead of 18px out from it.
  final direct = latticeRoute(start, end, obstacles);
  if (direct != null && !polylineHitsAny(direct, obstacles)) return direct;

  // Genuinely nowhere to go (a port walled in on every side). Draw the
  // straight run rather than nothing, so the connection is still visible.
  return full([a, b]);
}

/// How far sideways the router will slide a leg looking for a clear line,
/// nearest first so a diagram that doesn't need detours never gets one.
const List<double> _kDetourShifts = [
  0, 30, -30, 60, -60, 100, -100, 150, -150, 210, -210,
];

/// A coordinate just outside every obstacle between [a] and [b] — the lane a
/// cable can take to get over or under (or left or right of) the whole
/// obstruction in one go. Returns the nearer of the two sides.
double? _clearBand(
  List<Rect> obstacles,
  Offset a,
  Offset b, {
  required bool horizontal,
}) {
  if (obstacles.isEmpty) return null;
  const margin = 26.0;

  double lo = double.infinity, hi = -double.infinity;
  for (final r in obstacles) {
    lo = math.min(lo, horizontal ? r.top : r.left);
    hi = math.max(hi, horizontal ? r.bottom : r.right);
  }
  if (lo == double.infinity) return null;

  final over = lo - margin;
  final under = hi + margin;
  final from = horizontal ? a.dy : a.dx;
  final to = horizontal ? b.dy : b.dx;
  final mid = (from + to) / 2;
  return (mid - over).abs() <= (mid - under).abs() ? over : under;
}

// ---------------------------------------------------------------------------
//  GUARANTEED ORTHOGONAL ROUTING
// ---------------------------------------------------------------------------

/// Clearance kept between a route and the boxes it passes.
const double _kLatticeMargin = 14.0;

/// Ceilings on the search, so a very busy page can never stall a repaint.
const int _kMaxLatticeNodes = 22000;
const int _kMaxExpansions = 60000;

/// An orthogonal path from [a] to [b] that touches none of [obstacles], or
/// null when there genuinely isn't one.
///
/// A* over the lattice formed by the obstacle edges: every useful turning
/// point in an orthogonal layout lies on a line just outside some box, so
/// searching only those coordinates finds a route when one exists without
/// paying for a fine pixel grid. This is the backstop behind the quick shapes
/// in [routeCable] — those handle the common cases, this one guarantees the
/// result is never drawn through a device.
List<Offset>? latticeRoute(Offset a, Offset b, List<Rect> allObstacles) {
  // A box that swallows one of the stub points can't be respected — there
  // would be no way out of it — so it is dropped for this run rather than
  // making the whole search fail and fall back to a straight line.
  bool swallows(Rect r, Offset p) =>
      p.dx > r.left && p.dx < r.right && p.dy > r.top && p.dy < r.bottom;
  final obstacles = [
    for (final r in allObstacles)
      if (!swallows(r, a) && !swallows(r, b)) r,
  ];
  if (obstacles.isEmpty) return [a, b];

  // Candidate turning coordinates: the two endpoints, plus a channel just
  // outside every box on all four sides.
  final xs = <double>{a.dx, b.dx};
  final ys = <double>{a.dy, b.dy};
  for (final r in obstacles) {
    xs.add(r.left - _kLatticeMargin);
    xs.add(r.right + _kLatticeMargin);
    ys.add(r.top - _kLatticeMargin);
    ys.add(r.bottom + _kLatticeMargin);
  }

  final xList = xs.toList()..sort();
  final yList = ys.toList()..sort();
  final nx = xList.length, ny = yList.length;
  if (nx * ny > _kMaxLatticeNodes) return null;

  int nearest(List<double> values, double v) {
    int best = 0;
    double bestGap = double.infinity;
    for (int i = 0; i < values.length; i++) {
      final gap = (values[i] - v).abs();
      if (gap < bestGap) {
        bestGap = gap;
        best = i;
      }
    }
    return best;
  }

  final startI = nearest(xList, a.dx);
  final startJ = nearest(yList, a.dy);
  final goalI = nearest(xList, b.dx);
  final goalJ = nearest(yList, b.dy);

  // State carries the direction it arrived from, so turns can be charged for
  // and the result comes out with as few bends as the geometry allows.
  // 0 = start (no direction yet), 1 = horizontal, 2 = vertical.
  int key(int i, int j, int dir) => (i * ny + j) * 3 + dir;

  final gScore = <int, double>{};
  final cameFrom = <int, int>{};
  final open = _MinHeap();

  double heuristic(int i, int j) =>
      (xList[i] - xList[goalI]).abs() + (yList[j] - yList[goalJ]).abs();

  final startKey = key(startI, startJ, 0);
  gScore[startKey] = 0;
  open.push(startKey, heuristic(startI, startJ));

  const turnPenalty = 30.0;
  int expansions = 0;
  int? goalKey;

  while (!open.isEmpty) {
    final current = open.pop();
    final ci = current ~/ 3 ~/ ny;
    final cj = (current ~/ 3) % ny;
    final cdir = current % 3;

    if (ci == goalI && cj == goalJ) {
      goalKey = current;
      break;
    }
    if (++expansions > _kMaxExpansions) return null;

    final g = gScore[current]!;
    for (int step = 0; step < 4; step++) {
      final ni = ci + (step == 0 ? 1 : (step == 1 ? -1 : 0));
      final nj = cj + (step == 2 ? 1 : (step == 3 ? -1 : 0));
      if (ni < 0 || ni >= nx || nj < 0 || nj >= ny) continue;

      final from = Offset(xList[ci], yList[cj]);
      final to = Offset(xList[ni], yList[nj]);
      if (_segmentBlocked(from, to, obstacles)) continue;

      final ndir = step < 2 ? 1 : 2;
      final cost =
          (to - from).distance + (cdir != 0 && cdir != ndir ? turnPenalty : 0);
      final nKey = key(ni, nj, ndir);
      final tentative = g + cost;
      if (tentative < (gScore[nKey] ?? double.infinity)) {
        gScore[nKey] = tentative;
        cameFrom[nKey] = current;
        open.push(nKey, tentative + heuristic(ni, nj));
      }
    }
  }

  if (goalKey == null) return null;

  final points = <Offset>[];
  int? cursor = goalKey;
  while (cursor != null) {
    final i = cursor ~/ 3 ~/ ny;
    final j = (cursor ~/ 3) % ny;
    points.add(Offset(xList[i], yList[j]));
    cursor = cameFrom[cursor];
  }
  final route = points.reversed.toList();

  // The lattice snapped the ends to the nearest coordinate; put the real stub
  // points back so the run meets its ports exactly.
  route.first = a;
  route.last = b;
  return _mergeCollinear(route);
}

/// Drops points sitting in the middle of a straight run, so the painter
/// doesn't round a corner that isn't there.
List<Offset> _mergeCollinear(List<Offset> points) {
  if (points.length < 3) return points;
  final out = <Offset>[points.first];
  for (int i = 1; i < points.length - 1; i++) {
    final prev = out.last, here = points[i], next = points[i + 1];
    final straight =
        ((prev.dx - here.dx).abs() < 0.01 &&
                (here.dx - next.dx).abs() < 0.01) ||
            ((prev.dy - here.dy).abs() < 0.01 &&
                (here.dy - next.dy).abs() < 0.01);
    if (!straight) out.add(here);
  }
  out.add(points.last);
  return out;
}

bool _segmentBlocked(Offset p, Offset q, List<Rect> obstacles) {
  for (final r in obstacles) {
    if (segmentHitsRect(p, q, r)) return true;
  }
  return false;
}

/// True when the segment [p]->[q] passes through the INTERIOR of [r].
///
/// Exact (Liang-Barsky clipping) rather than sampled: a sampled test can step
/// straight over a thin sliver of a box and call a blocked run clear, which
/// is exactly how cables ended up drawn behind devices.
///
/// Touching an edge is allowed — routes are meant to run along the channel
/// just outside a box — so only a genuine crossing of the inside counts.
bool segmentHitsRect(Offset p, Offset q, Rect r) {
  if (r.width <= 0 || r.height <= 0) return false;

  const eps = 0.01;
  final inner = Rect.fromLTRB(
    r.left + eps,
    r.top + eps,
    r.right - eps,
    r.bottom - eps,
  );
  if (inner.width <= 0 || inner.height <= 0) return false;

  double t0 = 0, t1 = 1;
  final dx = q.dx - p.dx, dy = q.dy - p.dy;

  for (int edge = 0; edge < 4; edge++) {
    final double pp, qq;
    switch (edge) {
      case 0:
        pp = -dx;
        qq = p.dx - inner.left;
      case 1:
        pp = dx;
        qq = inner.right - p.dx;
      case 2:
        pp = -dy;
        qq = p.dy - inner.top;
      default:
        pp = dy;
        qq = inner.bottom - p.dy;
    }
    if (pp == 0) {
      if (qq < 0) return false; // parallel to this edge and outside it
      continue;
    }
    final t = qq / pp;
    if (pp < 0) {
      if (t > t1) return false;
      if (t > t0) t0 = t;
    } else {
      if (t < t0) return false;
      if (t < t1) t1 = t;
    }
  }
  return t0 < t1;
}

/// True when any leg of [route] crosses a box. Exact, so "clear" means clear.
bool polylineHitsAny(List<Offset> route, List<Rect> obstacles) {
  if (obstacles.isEmpty) return false;
  for (int i = 0; i < route.length - 1; i++) {
    if (_segmentBlocked(route[i], route[i + 1], obstacles)) return true;
  }
  return false;
}

/// Minimal binary heap — Dart has no priority queue in the core library and
/// the routing search wants one.
class _MinHeap {
  final List<int> _items = [];
  final List<double> _priorities = [];

  bool get isEmpty => _items.isEmpty;

  void push(int item, double priority) {
    _items.add(item);
    _priorities.add(priority);
    int i = _items.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_priorities[parent] <= _priorities[i]) break;
      _swap(i, parent);
      i = parent;
    }
  }

  int pop() {
    final top = _items.first;
    final lastItem = _items.removeLast();
    final lastPriority = _priorities.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = lastItem;
      _priorities[0] = lastPriority;
      int i = 0;
      while (true) {
        final l = i * 2 + 1, r = i * 2 + 2;
        int smallest = i;
        if (l < _items.length && _priorities[l] < _priorities[smallest]) {
          smallest = l;
        }
        if (r < _items.length && _priorities[r] < _priorities[smallest]) {
          smallest = r;
        }
        if (smallest == i) break;
        _swap(i, smallest);
        i = smallest;
      }
    }
    return top;
  }

  void _swap(int i, int j) {
    final item = _items[i];
    _items[i] = _items[j];
    _items[j] = item;
    final priority = _priorities[i];
    _priorities[i] = _priorities[j];
    _priorities[j] = priority;
  }
}

/// Assigns each cable a lane offset so runs sharing the same corridor are
/// drawn a few pixels apart instead of on top of each other. Cables are
/// grouped by the rounded midpoint of their vertical leg; within a group they
/// fan out symmetrically around the ideal route.
Map<String, double> assignCableLanes(
  List<AvCable> cables,
  Map<String, AvNode> nodesById,
) {
  const laneStep = 14.0;
  final groups = <int, List<String>>{};
  for (final c in cables) {
    final from = nodesById[c.fromNodeId];
    final to = nodesById[c.toNodeId];
    if (from == null || to == null || c.waypoints.isNotEmpty) continue;
    final a = from.anchorOf(c.fromPortId);
    final b = to.anchorOf(c.toPortId);
    final key = (((a.dx + b.dx) / 2) / 40).round();
    groups.putIfAbsent(key, () => []).add(c.id);
  }

  final lanes = <String, double>{};
  for (final ids in groups.values) {
    // Stable order: whatever order the cables were created in.
    for (int i = 0; i < ids.length; i++) {
      lanes[ids[i]] = (i - (ids.length - 1) / 2) * laneStep;
    }
  }
  return lanes;
}

// ---------------------------------------------------------------------------
//  THE RESOLVED DIAGRAM
// ---------------------------------------------------------------------------

/// Everything the view and the reports need for one render pass.
class AvFlowModel {
  final List<AvNode> nodes;
  final List<AvCable> cables;
  final List<RackFrame> racks;
  final Map<String, RackSlot> rackSlots;
  final Size canvasSize;
  final String roomTitle;

  /// Config devices that exist but haven't been placed on the canvas yet —
  /// the palette lists these.
  final List<AvUnplacedDevice> unplaced;

  const AvFlowModel({
    required this.nodes,
    required this.cables,
    required this.racks,
    required this.rackSlots,
    required this.canvasSize,
    required this.roomTitle,
    required this.unplaced,
  });

  Map<String, AvNode> get nodesById => {for (final n in nodes) n.id: n};

  AvNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Signal types the legend can honestly speak for: those with at least one
  /// run actually drawn in the type's own colour. A run the user recoloured
  /// by hand is not evidence that "HDMI is blue" on this page.
  List<SignalType> get usedSignals {
    final used = <SignalType>{
      for (final c in cables)
        if (!c.hasCustomColor) c.signal,
    };
    return SignalType.values.where(used.contains).toList();
  }

  /// True when at least one run is drawn off-palette, so the legend can say
  /// so instead of quietly under-describing the page.
  bool get hasCustomCableColors => cables.any((c) => c.hasCustomColor);

  /// Cables that reference a node or port that no longer exists. The view
  /// drops these from the canvas; the edit panel reports them so a user can
  /// see why a run vanished after a device swap.
  static bool cableIsResolvable(AvCable c, Map<String, AvNode> byId) =>
      byId[c.fromNodeId]?.portById(c.fromPortId) != null &&
      byId[c.toNodeId]?.portById(c.toPortId) != null;
}

/// A config device that has ports available but isn't on the canvas yet.
class AvUnplacedDevice {
  final String key; // config section key
  final String label;
  final String model;

  const AvUnplacedDevice({
    required this.key,
    required this.label,
    required this.model,
  });
}
