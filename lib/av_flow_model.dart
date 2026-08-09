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
  }) =>
      AvPort(
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
    this.note = '',
  });

  AvNode copyWith({
    String? label,
    String? model,
    Offset? pos,
    List<AvPort>? ports,
    bool? fromConfig,
    int? rackUnits,
    String? note,
  }) =>
      AvNode(
        id: id,
        label: label ?? this.label,
        model: model ?? this.model,
        pos: pos ?? this.pos,
        ports: ports ?? this.ports,
        fromConfig: fromConfig ?? this.fromConfig,
        rackUnits: rackUnits ?? this.rackUnits,
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
    final edgePad = (topPorts.isEmpty ? 0.0 : 6.0) +
        (bottomPorts.isEmpty ? 0.0 : 6.0);
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

  const AvCable({
    required this.id,
    required this.fromNodeId,
    required this.fromPortId,
    required this.toNodeId,
    required this.toPortId,
    required this.signal,
    this.label = '',
    this.waypoints = const [],
  });

  AvCable copyWith({
    SignalType? signal,
    String? label,
    List<Offset>? waypoints,
  }) =>
      AvCable(
        id: id,
        fromNodeId: fromNodeId,
        fromPortId: fromPortId,
        toNodeId: toNodeId,
        toPortId: toPortId,
        signal: signal ?? this.signal,
        label: label ?? this.label,
        waypoints: waypoints ?? this.waypoints,
      );

  Color get color => kSignalColors[signal] ?? kSignalColors[SignalType.other]!;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromNode': fromNodeId,
        'fromPort': fromPortId,
        'toNode': toNodeId,
        'toPort': toPortId,
        'signal': signal.name,
        if (label.isNotEmpty) 'label': label,
        if (waypoints.isNotEmpty)
          'waypoints': [
            for (final w in waypoints) {'x': w.dx, 'y': w.dy}
          ],
      };

  factory AvCable.fromJson(Map<String, dynamic> json) => AvCable(
        id: json['id']?.toString() ?? '',
        fromNodeId: json['fromNode']?.toString() ?? '',
        fromPortId: json['fromPort']?.toString() ?? '',
        toNodeId: json['toNode']?.toString() ?? '',
        toPortId: json['toPort']?.toString() ?? '',
        signal: signalFromName(json['signal']?.toString()),
        label: json['label']?.toString() ?? '',
        waypoints: [
          for (final w in (json['waypoints'] as List? ?? []))
            if (w is Map)
              Offset((w['x'] as num?)?.toDouble() ?? 0,
                  (w['y'] as num?)?.toDouble() ?? 0),
        ],
      );
}

// ---------------------------------------------------------------------------
//  RACKS
// ---------------------------------------------------------------------------

enum RackFace { front, rear }

/// A rack frame on the elevation page.
class RackFrame {
  final String id;
  final String name;
  final int heightU;

  /// Left edge on the elevation page; frames sit side by side.
  final double x;

  const RackFrame({
    required this.id,
    required this.name,
    required this.heightU,
    this.x = 0,
  });

  RackFrame copyWith({String? name, int? heightU, double? x}) => RackFrame(
        id: id,
        name: name ?? this.name,
        heightU: heightU ?? this.heightU,
        x: x ?? this.x,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'heightU': heightU, 'x': x};

  factory RackFrame.fromJson(Map<String, dynamic> json) => RackFrame(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? 'Rack',
        heightU: (json['heightU'] as num?)?.toInt() ?? 42,
        x: (json['x'] as num?)?.toDouble() ?? 0,
      );
}

/// Rack presets offered when adding a frame.
const Map<String, int> kRackPresets = {
  '42U floor': 42,
  '24U floor': 24,
  '12U wall': 12,
  '8U wall': 8,
  '4U wall': 4,
};

/// Where one device sits in a rack. Keyed by node id in the state map, so a
/// device can only be in one place — which is the physical truth.
class RackSlot {
  final String rackId;

  /// 1-based U of the device's BOTTOM rail, counting up from the floor, which
  /// is how rack elevations are actually numbered.
  final int startU;
  final RackFace face;

  const RackSlot({
    required this.rackId,
    required this.startU,
    this.face = RackFace.front,
  });

  RackSlot copyWith({String? rackId, int? startU, RackFace? face}) => RackSlot(
        rackId: rackId ?? this.rackId,
        startU: startU ?? this.startU,
        face: face ?? this.face,
      );

  Map<String, dynamic> toJson() =>
      {'rack': rackId, 'startU': startU, 'face': face.name};

  factory RackSlot.fromJson(Map<String, dynamic> json) => RackSlot(
        rackId: json['rack']?.toString() ?? '',
        startU: (json['startU'] as num?)?.toInt() ?? 1,
        face: json['face']?.toString() == 'rear' ? RackFace.rear : RackFace.front,
      );
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
/// Full A* obstacle avoidance (what EasySchematic does) is deliberately not
/// attempted here — lane offsets plus manual waypoints handle the real cases
/// without the complexity, and the user can always drag a waypoint.
List<Offset> routeCable({
  required AvNode fromNode,
  required AvNode toNode,
  required AvCable cable,
  double lane = 0,
}) {
  final start = fromNode.anchorOf(cable.fromPortId);
  final end = toNode.anchorOf(cable.toPortId);

  if (cable.waypoints.isNotEmpty) {
    return [start, ...cable.waypoints, end];
  }

  const stub = 18.0;
  final sN = fromNode.normalOf(cable.fromPortId);
  final eN = toNode.normalOf(cable.toPortId);
  final a = start + Offset(sN.dx * stub, sN.dy * stub);
  final b = end + Offset(eN.dx * stub, eN.dy * stub);

  // Both stubs horizontal (the common case: output right -> input left).
  if (sN.dy == 0 && eN.dy == 0) {
    if ((a.dy - b.dy).abs() < 1) return [start, a, b, end];
    final midX = (a.dx + b.dx) / 2 + lane;
    return [start, a, Offset(midX, a.dy), Offset(midX, b.dy), b, end];
  }
  // Both stubs vertical.
  if (sN.dx == 0 && eN.dx == 0) {
    if ((a.dx - b.dx).abs() < 1) return [start, a, b, end];
    final midY = (a.dy + b.dy) / 2 + lane;
    return [start, a, Offset(a.dx, midY), Offset(b.dx, midY), b, end];
  }
  // Mixed: turn once at the corner that keeps both stubs straight.
  final corner =
      sN.dy == 0 ? Offset(b.dx, a.dy) : Offset(a.dx, b.dy);
  return [start, a, corner, b, end];
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

  /// Signal types actually present on the canvas — the legend only lists
  /// what is drawn, so it stays short.
  List<SignalType> get usedSignals {
    final used = <SignalType>{for (final c in cables) c.signal};
    return SignalType.values.where(used.contains).toList();
  }

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
