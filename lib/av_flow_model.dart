import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cabling_schematic.dart';
import 'room_locations.dart';

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
  SignalType.network: Color(0xFF78909C), // blue gray
  SignalType.ir: Color(0xFFFFEE58), // yellow
  SignalType.serial: Color(0xFFAB47BC), // purple
  SignalType.power: Color(0xFF616161), // gray
  SignalType.other: Color(0xFF90A4AE), // pale blue gray
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

// ---------------------------------------------------------------------------
//  CABLE FAMILIES
// ---------------------------------------------------------------------------

/// The AV signals that travel down STRUCTURED CABLE — the same Cat 5e/6 the
/// network runs on.
///
/// These are the runs a cabling drawing has to be explicit about, because on
/// the drawing they look exactly like the network runs beside them and get
/// pulled, terminated and tested by the same people. Calling all of them "AV
/// cabling" and naming the signal underneath is how a rough-in sheet stops a
/// DTP run being landed on a data switch.
const Set<SignalType> kAvCablingSignals = {
  SignalType.hdbaset,
  SignalType.dante,
};

/// What a run gets FILED under on a cabling sheet, as opposed to what signal
/// it carries.
enum CableFamily {
  /// DTP / HDBaseT and Dante — see [kAvCablingSignals].
  avCabling,

  /// The data runs back to the telecom room.
  network,

  /// Everything that is its own thing: HDMI, speaker level, USB.
  other,
}

const Map<CableFamily, String> kCableFamilyLabels = {
  CableFamily.avCabling: 'AV cabling',
  CableFamily.network: 'Network',
  CableFamily.other: 'Other cabling',
};

CableFamily cableFamilyFor(SignalType s) => kAvCablingSignals.contains(s)
    ? CableFamily.avCabling
    : s == SignalType.network
    ? CableFamily.network
    : CableFamily.other;

/// The heading a run of [s] is listed under: "AV cabling" for the structured
/// AV signals, the signal's own name for everything else.
///
/// Nothing calls [kSignalLabels] directly when it is naming a CABLE, so the
/// family name and the sub-heading below it can never drift apart.
String cableTypeLabel(SignalType s) {
  final family = cableFamilyFor(s);
  if (family == CableFamily.other) return kSignalLabels[s] ?? s.name;
  return kCableFamilyLabels[family]!;
}

/// The sub-heading under [cableTypeLabel] — which signal the family name
/// covers. Empty when the heading already names the signal, so a table never
/// prints "Network / Network".
String cableSignalSubLabel(SignalType s) {
  final label = kSignalLabels[s] ?? s.name;
  return label == cableTypeLabel(s) ? '' : label;
}

// ---------------------------------------------------------------------------
//  CABLE LENGTHS
// ---------------------------------------------------------------------------

/// The made-up lead lengths this shop stocks, in feet.
///
/// A closed list rather than a free number on purpose: a cable schedule is an
/// ORDER, and "17 ft" is not a thing anybody can put on one. Runs pulled to
/// length in conduit simply leave the length unset, which the counts report as
/// its own column rather than quietly rounding into the shortest lead.
const List<double> kCableLengthsFt = [1, 3, 6, 7, 15, 20, 25];

/// "6ft", or '' when the length was never set.
String formatCableLength(double feet) {
  if (feet <= 0) return '';
  return feet == feet.roundToDouble()
      ? '${feet.round()}ft'
      : '${feet.toStringAsFixed(1)}ft';
}

/// The color a signal type is drawn in, honouring the room's palette.
///
/// [kSignalColors] is only the factory default. A room can recolor any type
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

/// What a box on the canvas represents.
///
/// [jackField] and [patchPanel] both hold numbered jacks rather than a device's
/// connectors, so the report can say which device landed on which jack number.
/// They differ only in SHAPE, because the two things do not look alike on a
/// wall: a wall box is a small square plate with its jacks stacked down both
/// sides, and a patch panel is a rack-width strip with every outlet in one
/// horizontal row. Drawing the panel as a box was the single thing that made a
/// rack elevation and the flow diagram disagree about what the same part was.
enum AvNodeKind { device, jackField, patchPanel }

AvNodeKind nodeKindFromName(String? name) {
  switch (name?.trim().toLowerCase()) {
    case 'jackfield':
      return AvNodeKind.jackField;
    case 'patchpanel':
      return AvNodeKind.patchPanel;
    default:
      return AvNodeKind.device;
  }
}

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

/// How a CATALOG entry takes power — the fact about the model, as opposed to
/// [PowerSource], which is where this room happens to plug it in.
///
/// Every device gets a power inlet unless it is genuinely passive (a speaker,
/// a cable, a blanking plate), because a device with no recorded inlet is a
/// device the rack load quietly forgets. [PowerInput.poe] is the toggle for
/// gear fed off the network switch instead of a mains outlet: it still has a
/// power inlet on the drawing, it just doesn't land on the room's circuit.
enum PowerInput { mains, poe, none }

const Map<PowerInput, String> kPowerInputLabels = {
  PowerInput.mains: 'Mains (AC)',
  PowerInput.poe: 'PoE',
  PowerInput.none: 'None (passive)',
};

PowerInput powerInputFromName(String? name) {
  switch (name?.trim().toLowerCase()) {
    case 'poe':
      return PowerInput.poe;
    case 'none':
      return PowerInput.none;
    default:
      return PowerInput.mains;
  }
}

/// The room-level power source a catalog entry implies. Mains stays
/// [PowerSource.unspecified] on purpose: the model can't know whether this
/// room puts it on the controller or straight into the wall.
PowerSource powerSourceForInput(PowerInput input) => switch (input) {
  PowerInput.poe => PowerSource.poe,
  PowerInput.none => PowerSource.none,
  PowerInput.mains => PowerSource.unspecified,
};

/// The id every power inlet uses, so adding one twice is impossible and the
/// toggle can always find the one already there.
const String kPowerPortId = 'in_power';

/// Watts to BTU/hr. Electrical power becomes heat essentially one for one, so
/// the conversion is just the unit change — 1 W = 3.412 BTU/hr.
const double kWattsToBtu = 3.412;

/// A device's power inlet, on the bottom edge so it stays clear of the signal
/// columns down either side.
AvPort powerInletPort(PowerInput input) => AvPort(
  id: kPowerPortId,
  label: input == PowerInput.poe ? 'POWER (PoE)' : 'POWER',
  signal: SignalType.power,
  direction: PortDirection.input,
  side: PortSide.bottom,
);

/// [ports] with exactly the power inlet [input] calls for: one added when it
/// is missing, relabeled when the toggle moves, removed when the device is
/// passive. Everything else keeps its order.
List<AvPort> withPowerInlet(List<AvPort> ports, PowerInput input) {
  final others = ports
      .where(
        (p) =>
            p.id != kPowerPortId &&
            !(p.signal == SignalType.power && p.isInput),
      )
      .toList();
  if (input == PowerInput.none) return others;
  return [...others, powerInletPort(input)];
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

  /// The device's mains (or PoE) inlet rather than a signal connector. Kept
  /// out of the in/out counts and the connector-utilization report, where
  /// counting it would overstate every device by one input.
  bool get isPowerInlet =>
      signal == SignalType.power && direction != PortDirection.output;

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

/// Horizontal spacing between the outlets of a patch panel. Wide enough for a
/// six-digit jack number underneath the dot without the numbers colliding.
const double kAvPatchJackPitch = 46;

/// A panel keeps growing sideways rather than wrapping — that is what the part
/// looks like — but not forever; past this the jacks compress instead.
const double kAvPatchPanelMaxWidth = 1600;

/// Header aside, a panel is one strip: room for the jack numbers and the row
/// of outlets along the bottom edge.
const double kAvPatchPanelBodyHeight = 34;

/// Below this much room per outlet the jack numbers stop being drawn: a
/// 48-port panel compressed to fit is a row of dots, and printing six-digit
/// numbers under them at 12px apart produces a smear rather than a label. The
/// numbers are still on every outlet's tooltip.
const double kAvPatchLabelMinPitch = 26;

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

  /// Estimated draw in watts, seeded from the device catalog and overridable
  /// here — the same box can sit on a different power supply room to room.
  /// 0 means "not recorded", which the power report counts rather than
  /// totalling as zero.
  final double powerWatts;

  /// Heat output in BTU/hr. 0 means "derive it from [powerWatts]", which is
  /// right for almost everything — a box turns its input power into heat. It
  /// is a separate field because it isn't always: an amplifier's rated draw
  /// goes partly out of the speaker terminals as sound, and a manufacturer
  /// who publishes a BTU figure should be believed over the arithmetic.
  final double btuPerHour;

  /// Device or numbered jack field (wall box / floor box / patch panel).
  final AvNodeKind kind;

  /// Where this device's mains comes from.
  final PowerSource powerSource;

  /// Free-text note carried into the pack list.
  final String note;

  /// Keep this device off the cost estimate.
  ///
  /// Not everything on the diagram is being bought. A display the room already
  /// has, a codec the customer is supplying, the building's network switch, a
  /// box somebody else's contract covers — all of them have to be DRAWN,
  /// because the signal goes through them and the cable schedule and the rack
  /// elevation are wrong without them, and none of them belongs on the quote.
  ///
  /// Deleting them from the canvas to keep the total honest was the only way
  /// to do this before, and it costs the drawing the very connections it
  /// exists to record. The estimate leaves these out and says how many it left
  /// out, so a total that reads low reads low for a stated reason.
  ///
  /// They still count everywhere else — power, heat, rack space and the pack
  /// list are facts about the room, not about the invoice.
  final bool excludeFromCost;

  /// Which of the room's [RoomLocation]s this box physically sits in, or ''
  /// when nobody has said.
  ///
  /// An id rather than a name so renaming "Front floor box" to "FB-1" moves
  /// every device, every jack count and every cable endpoint with it, instead
  /// of stranding the ones typed before the rename under the old spelling —
  /// which is exactly what makes a per-location count untrustworthy.
  final String locationId;

  const AvNode({
    required this.id,
    required this.label,
    required this.model,
    required this.pos,
    required this.ports,
    this.fromConfig = false,
    this.rackUnits = 0,
    this.powerWatts = 0,
    this.btuPerHour = 0,
    this.kind = AvNodeKind.device,
    this.powerSource = PowerSource.unspecified,
    this.note = '',
    this.excludeFromCost = false,
    this.locationId = kNoLocationId,
  });

  /// Numbered jacks rather than a device's connectors — a wall box OR a patch
  /// panel. The jack schedule and the connector-utilization report both key off
  /// this, and a panel is exactly as much a jack field as a wall plate is.
  bool get isJackField =>
      kind == AvNodeKind.jackField || kind == AvNodeKind.patchPanel;

  /// Drawn as a rack-width strip with its outlets in one horizontal row.
  bool get isPatchPanel => kind == AvNodeKind.patchPanel;

  /// Heat this device puts into the room: its own BTU figure when somebody
  /// recorded one, otherwise the watts converted. 0 when neither is known —
  /// which the reports count rather than adding in as "runs cold".
  double get effectiveBtu =>
      btuPerHour > 0 ? btuPerHour : powerWatts * kWattsToBtu;

  /// The same device under a different id.
  ///
  /// [copyWith] deliberately cannot change the id — it is the node's identity
  /// — but adding a node has to re-key one whose id is taken. That rebuild
  /// lives HERE, next to the fields, rather than in the provider: twice now a
  /// new field (watts, then BTU) was added to the class and silently dropped
  /// by a field-by-field rebuild somewhere else in the app.
  AvNode withId(String newId) => AvNode(
    id: newId,
    label: label,
    model: model,
    pos: pos,
    ports: ports,
    fromConfig: fromConfig,
    rackUnits: rackUnits,
    powerWatts: powerWatts,
    btuPerHour: btuPerHour,
    kind: kind,
    powerSource: powerSource,
    note: note,
    excludeFromCost: excludeFromCost,
    locationId: locationId,
  );

  AvNode copyWith({
    String? label,
    String? model,
    Offset? pos,
    List<AvPort>? ports,
    bool? fromConfig,
    int? rackUnits,
    double? powerWatts,
    double? btuPerHour,
    AvNodeKind? kind,
    PowerSource? powerSource,
    String? note,
    bool? excludeFromCost,
    String? locationId,
  }) => AvNode(
    id: id,
    label: label ?? this.label,
    model: model ?? this.model,
    pos: pos ?? this.pos,
    ports: ports ?? this.ports,
    fromConfig: fromConfig ?? this.fromConfig,
    rackUnits: rackUnits ?? this.rackUnits,
    powerWatts: powerWatts ?? this.powerWatts,
    btuPerHour: btuPerHour ?? this.btuPerHour,
    kind: kind ?? this.kind,
    powerSource: powerSource ?? this.powerSource,
    note: note ?? this.note,
    excludeFromCost: excludeFromCost ?? this.excludeFromCost,
    locationId: locationId ?? this.locationId,
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
    // A panel is as wide as its outlet row needs and no taller than a strip;
    // the general clamp would squash twenty-four jacks into 300px.
    if (isPatchPanel) {
      final w = kAvPatchJackPitch * (ports.length + 1);
      return math.max(kAvNodeMinWidth, math.min(w, kAvPatchPanelMaxWidth));
    }
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
    // Header, one strip of room for the jack numbers, and the outlet row.
    if (isPatchPanel) return kAvNodeHeaderHeight + kAvPatchPanelBodyHeight;
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
    if (powerWatts > 0) 'powerWatts': powerWatts,
    if (btuPerHour > 0) 'btuPerHour': btuPerHour,
    if (kind != AvNodeKind.device) 'kind': kind.name,
    if (powerSource != PowerSource.unspecified) 'power': powerSource.name,
    if (note.isNotEmpty) 'note': note,
    if (excludeFromCost) 'excludeFromCost': true,
    if (locationId.isNotEmpty) 'location': locationId,
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
    powerWatts: (json['powerWatts'] as num?)?.toDouble() ?? 0,
    btuPerHour: (json['btuPerHour'] as num?)?.toDouble() ?? 0,
    kind: nodeKindFromName(json['kind']?.toString()),
    powerSource: powerSourceFromName(json['power']?.toString()),
    note: json['note']?.toString() ?? '',
    excludeFromCost: json['excludeFromCost'] == true,
    locationId: json['location']?.toString() ?? kNoLocationId,
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

  /// How long the lead is, in feet — one of [kCableLengthsFt], or 0 when
  /// nobody has said. Zero rather than null so a room saved before lengths
  /// existed reads back as "not set" rather than as a one-foot patch lead.
  final double lengthFt;

  /// Manual route overrides. Empty means "use the automatic route".
  final List<Offset> waypoints;

  /// Paints this one run in a color of its own instead of the signal type's.
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
    this.lengthFt = 0,
    this.waypoints = const [],
    this.colorOverride,
  });

  /// [clearColorOverride] exists because passing null to [colorOverride]
  /// cannot be told apart from "leave it alone" in a copyWith.
  AvCable copyWith({
    SignalType? signal,
    String? label,
    double? lengthFt,
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
    lengthFt: lengthFt ?? this.lengthFt,
    waypoints: waypoints ?? this.waypoints,
    colorOverride: clearColorOverride
        ? null
        : (colorOverride ?? this.colorOverride),
  );

  /// The color this run is actually drawn in: its own override if it has
  /// one, otherwise whatever the room's palette says its signal type is.
  Color colorFor([Map<SignalType, Color>? palette]) =>
      colorOverride ?? signalColor(signal, palette);

  /// True when this run is drawn in something other than its signal color —
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
    if (lengthFt > 0) 'lengthFt': lengthFt,
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
      lengthFt: (json['lengthFt'] as num?)?.toDouble() ?? 0,
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

/// Colors offered when recoloring a single run. The signal palette first —
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
//  THE CANVAS BACKDROP
// ---------------------------------------------------------------------------

/// A picture laid behind the signal flow.
///
/// This used to be the room's floor plan, and only ever the floor plan. That
/// was the wrong picture in almost every case: a signal flow is laid out by
/// signal, not by geometry, so a plan behind it lines up with nothing, and the
/// drawings people actually wanted behind it — a title block, a riser sketch,
/// a marked-up screenshot of the last revision — were unreachable. So the
/// backdrop is now any image, chosen here and belonging to this canvas.
///
/// The file is referenced by NAME and copied in beside the config, on exactly
/// the same terms as a floor plan sheet: a room folder is the unit that gets
/// zipped and mailed, and an image referenced off somebody's desktop is a
/// broken picture the moment it leaves this machine.
class DiagramBackground {
  /// File name relative to the config's folder, or an absolute path. Empty
  /// means there is no backdrop, which is the default.
  final String imageFile;

  /// Natural pixel size, recorded on import so the canvas can lay out before
  /// the bytes have been decoded.
  final Size imageSize;

  /// 1 is opaque. The default is faint enough that the diagram still reads
  /// over it — a backdrop is there to be referred to, not looked at.
  final double opacity;

  /// How much of the canvas width the picture is drawn across, as a fraction.
  /// 1 fills it; less leaves it at the top-left as a reference panel.
  final double scale;

  const DiagramBackground({
    this.imageFile = '',
    this.imageSize = const Size(1200, 900),
    this.opacity = 0.35,
    this.scale = 1.0,
  });

  bool get hasImage => imageFile.trim().isNotEmpty;

  DiagramBackground copyWith({
    String? imageFile,
    Size? imageSize,
    double? opacity,
    double? scale,
  }) => DiagramBackground(
    imageFile: imageFile ?? this.imageFile,
    imageSize: imageSize ?? this.imageSize,
    opacity: opacity ?? this.opacity,
    scale: scale ?? this.scale,
  );

  Map<String, dynamic> toJson() => {
    if (imageFile.isNotEmpty) 'image': imageFile,
    'width': imageSize.width,
    'height': imageSize.height,
    'opacity': opacity,
    'scale': scale,
  };

  factory DiagramBackground.fromJson(Map<String, dynamic> json) =>
      DiagramBackground(
        imageFile: json['image']?.toString() ?? '',
        imageSize: Size(
          (json['width'] as num?)?.toDouble() ?? 1200,
          (json['height'] as num?)?.toDouble() ?? 900,
        ),
        opacity: ((json['opacity'] as num?)?.toDouble() ?? 0.35)
            .clamp(0.05, 1.0),
        scale: ((json['scale'] as num?)?.toDouble() ?? 1.0).clamp(0.1, 3.0),
      );
}

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
  /// overlap test — fractions compare correctly even when two neighboring
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
//  RACK HARDWARE
// ---------------------------------------------------------------------------

/// The categories a piece of rack hardware falls into. Free text underneath —
/// [RackItem.category] is a String — but these are the ones with a button in
/// the rack editor, and the ones the estimate groups by.
const List<String> kRackItemCategories = [
  'Vent plate',
  'Blank plate',
  'Plate',
  'Shelf',
  'Clamping shelf',
  'Drawer',
  'Cable management',
  'Rack hardware',
];

/// Kinds offered for a rack occupant that is a BOX rather than a rack part —
/// the Cisco switch, the owner-furnished appliance, the mini PC on the shelf.
/// Free text underneath, like [kRackItemCategories]; what matters is that none
/// of these is in that list, because a category outside it is what puts the
/// item on the Equipment section of the estimate instead of Rack hardware.
const List<String> kRackDeviceCategories = [
  'Network switch',
  'Computer',
  'Appliance',
  'Amplifier',
  'Power',
  'Other equipment',
];

/// True when [category] describes a rack PART (a plate, a shelf, a lacing bar)
/// rather than a box. An empty category counts as a part: everything written
/// before there was anything else to be was a plate or a shelf.
bool isRackHardwareCategory(String category) {
  final name = category.trim();
  return name.isEmpty || kRackItemCategories.contains(name);
}

/// A vent plate, blank plate, shelf or drawer sitting in a rack.
///
/// Not an [AvNode]: none of these carry signal, and putting them on the signal
/// flow canvas would fill it with boxes nothing is ever cabled to. They occupy
/// rack units exactly as a device does — they share [RackSlot] and the same
/// placement rules — and they carry a price, so what the rack actually costs
/// includes the twelve blanks nobody remembers to quote.
///
/// [catalogModel] points back at the catalog entry it was taken from, so a
/// price revised on the parts list re-costs every rack that uses it. The local
/// copies of the height and price are what the rack was BUILT with and still
/// stand when the entry is gone.
class RackItem {
  /// `RACKITEM_<n>`, and the key it is stored under in the rack slot map.
  final String id;

  /// Catalog model this came from ('' for a one-off typed in by hand).
  final String catalogModel;

  final String label;
  final String category;
  final String partNumber;
  final int rackUnits;

  /// Unit price at the time it was placed; the catalog's price wins when the
  /// entry is still there — see `rackItemUnitPrice` in cost_estimate.dart.
  final double price;

  final String notes;

  const RackItem({
    required this.id,
    this.catalogModel = '',
    required this.label,
    this.category = '',
    this.partNumber = '',
    this.rackUnits = 1,
    this.price = 0,
    this.notes = '',
  });

  /// The same item under a different id — the rack editor's "add another".
  RackItem withId(String newId) => RackItem(
    id: newId,
    catalogModel: catalogModel,
    label: label,
    category: category,
    partNumber: partNumber,
    rackUnits: rackUnits,
    price: price,
    notes: notes,
  );

  RackItem copyWith({
    String? catalogModel,
    String? label,
    String? category,
    String? partNumber,
    int? rackUnits,
    double? price,
    String? notes,
  }) => RackItem(
    id: id,
    catalogModel: catalogModel ?? this.catalogModel,
    label: label ?? this.label,
    category: category ?? this.category,
    partNumber: partNumber ?? this.partNumber,
    rackUnits: rackUnits ?? this.rackUnits,
    price: price ?? this.price,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (catalogModel.isNotEmpty) 'catalogModel': catalogModel,
    'label': label,
    if (category.isNotEmpty) 'category': category,
    if (partNumber.isNotEmpty) 'partNumber': partNumber,
    'rackUnits': rackUnits,
    if (price > 0) 'price': price,
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory RackItem.fromJson(Map<String, dynamic> json) => RackItem(
    id: json['id']?.toString() ?? '',
    catalogModel: json['catalogModel']?.toString() ?? '',
    label: json['label']?.toString() ?? 'Rack item',
    category: json['category']?.toString() ?? '',
    partNumber: json['partNumber']?.toString() ?? '',
    rackUnits: (json['rackUnits'] as num?)?.toInt() ?? 1,
    price: (json['price'] as num?)?.toDouble() ?? 0,
    notes: json['notes']?.toString() ?? '',
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

  // Hand-placed bends say where the run should GO; they don't license it to
  // cut through a device on the way. Each leg between consecutive bends is
  // kept exactly as drawn when it's clear, and routed around when it isn't,
  // so the shape the user asked for survives without the line crossing a box.
  if (cable.waypoints.isNotEmpty) {
    return routeThrough([start, ...cable.waypoints, end], obstacles);
  }

  const stub = 18.0;
  final sN = fromNode.normalOf(cable.fromPortId);
  final eN = toNode.normalOf(cable.toPortId);
  final a = start + Offset(sN.dx * stub, sN.dy * stub);
  final b = end + Offset(eN.dx * stub, eN.dy * stub);

  List<Offset> full(List<Offset> middle) => [start, ...middle, end];

  // Check the WHOLE run, stubs included. The stub leaves its port straight
  // out of the box face, but a neighbor parked right against that face can
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

/// The line through [guide] — two ends with any hand-placed bends between
/// them — kept exactly as drawn where it is clear, and routed around what is
/// in the way where it is not.
///
/// Hand-placed bends say where the run should GO; they do not license it to
/// cut through a device on the way. Each leg is checked on its own, so the
/// shape somebody asked for survives without the line crossing a box.
///
/// Shared by the signal flow, the cabling drawing and the floor plan: all
/// three let a run be steered by hand, and a bend that behaved differently
/// depending on which sheet it was dragged on would be three features.
List<Offset> routeThrough(List<Offset> guide, List<Rect> obstacles) {
  if (guide.length < 2) return guide;
  if (obstacles.isEmpty) return _mergeCollinear(guide);

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

/// Where a new bend belongs in [waypoints]: the leg of the guide line
/// ([start], the bends, [end]) that [at] sits nearest to.
///
/// Worked out against the GUIDE rather than the drawn path, whose detours
/// round obstacles carry points nobody placed — insert against those and the
/// new bend lands in the wrong slot as soon as a leg has been re-routed.
int bendInsertIndex(
  Offset start,
  List<Offset> waypoints,
  Offset end,
  Offset at,
) {
  final guide = [start, ...waypoints, end];
  double best = double.infinity;
  int index = waypoints.length;
  for (int i = 0; i < guide.length - 1; i++) {
    final d = distanceToSegmentPoint(at, guide[i], guide[i + 1]);
    if (d < best) {
      best = d;
      index = i;
    }
  }
  return index.clamp(0, waypoints.length);
}

/// Distance from [p] to the segment [a]-[b].
double distanceToSegmentPoint(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
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

  /// Vent plates, blanks, shelves and drawers in those racks. Keyed into
  /// [rackSlots] by their own ids, alongside the devices.
  final List<RackItem> rackItems;

  final Size canvasSize;
  final String roomTitle;

  /// Config devices that exist but haven't been placed on the canvas yet —
  /// the palette lists these.
  final List<AvUnplacedDevice> unplaced;

  /// Where things are in the room, in the order the user arranged them.
  final List<RoomLocation> locations;

  /// Screen / shade control runs, which have two ends and no signal.
  final List<ScreenSwitch> screenSwitches;

  /// Floor plans with their callouts.
  final List<FloorPlan> floorPlans;

  /// What was moved, renamed or typed on the cabling drawing. The drawing
  /// itself is derived from [cables] and [locations] every time it is built,
  /// so only the edits travel — see cabling_schematic.dart.
  ///
  /// Nullable so this class can keep its const constructor: the overrides hold
  /// mutable maps and cannot be a const default. Read it through [cablingEdits].
  final CablingOverrides? cabling;

  /// The edits, or an empty set when a room has none.
  CablingOverrides get cablingEdits => cabling ?? CablingOverrides();

  const AvFlowModel({
    required this.nodes,
    required this.cables,
    required this.racks,
    required this.rackSlots,
    required this.canvasSize,
    required this.roomTitle,
    required this.unplaced,
    this.rackItems = const [],
    this.locations = const [],
    this.screenSwitches = const [],
    this.floorPlans = const [],
    this.cabling,
  });

  Map<String, AvNode> get nodesById => {for (final n in nodes) n.id: n};

  Map<String, RoomLocation> get locationsById => {
    for (final l in locations) l.id: l,
  };

  RoomLocation? locationById(String id) {
    for (final l in locations) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// What a report prints in a location column for whatever is at [nodeId]:
  /// the location's display name, or a blank when nobody said where it is.
  ///
  /// Blank rather than "unknown" on purpose — a column of "unknown" reads as
  /// an error in the export, where an empty cell reads as a question nobody
  /// has answered yet, which is what it is.
  String locationNameOf(String nodeId) {
    final id = nodesById[nodeId]?.locationId ?? kNoLocationId;
    if (id.isEmpty) return '';
    return locationById(id)?.displayName ?? '';
  }

  /// The zone whatever is at [nodeId] sits in.
  RoomZone zoneOf(String nodeId) {
    final id = nodesById[nodeId]?.locationId ?? kNoLocationId;
    if (id.isEmpty) return RoomZone.unspecified;
    return locationById(id)?.zone ?? RoomZone.unspecified;
  }

  AvNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Signal types the legend can honestly speak for: those with at least one
  /// run actually drawn in the type's own color. A run the user recolored
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

// ---------------------------------------------------------------------------
//  JACK NUMBERING
// ---------------------------------------------------------------------------

/// Where one jack label is already in use.
typedef JackUse = ({String nodeId, String nodeLabel, String portId});

/// Every jack label already spoken for in [nodes], keyed by the normalized
/// label, with the box each one is on.
///
/// Jack numbers are the room's addressing scheme: an installer at the wall
/// plate finds "111004" on the report and expects exactly one thing at the
/// other end of it. Two boxes numbered the same is not a cosmetic problem —
/// it is a patch that gets made to the wrong jack, found at commissioning.
///
/// Only jack fields and patch panels count. A device's HDMI 1 is not a jack
/// number, and every switcher in the room having one is not a clash.
Map<String, List<JackUse>> jackLabelIndex(Iterable<AvNode> nodes) {
  final index = <String, List<JackUse>>{};
  for (final node in nodes) {
    if (!node.isJackField) continue;
    for (final port in node.ports) {
      final key = normalizeJackLabel(port.label);
      if (key.isEmpty) continue;
      index
          .putIfAbsent(key, () => [])
          .add((nodeId: node.id, nodeLabel: node.label, portId: port.id));
    }
  }
  return index;
}

/// The form two jack labels are compared in.
///
/// Case and separators are dropped because "AV-01", "av 01" and "AV01" are one
/// jack written three ways, and a duplicate check that misses those is a check
/// nobody can rely on. Leading zeros are KEPT: 01 and 1 are genuinely different
/// labels in a scheme that pads, and silently merging them would refuse a
/// legitimate number.
String normalizeJackLabel(String label) =>
    label.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_./]'), '');

/// The labels in [candidates] that are already used somewhere in [nodes],
/// ignoring anything on [exceptNodeId] — which is what an EDIT of an existing
/// box needs, since its own current numbers must not read as clashes with
/// themselves.
///
/// Also catches duplicates WITHIN [candidates]: a badly chosen prefix and
/// start number can collide a new box with itself before it ever reaches the
/// canvas.
List<({String label, String usedBy})> duplicateJackLabels(
  Iterable<String> candidates,
  Iterable<AvNode> nodes, {
  String exceptNodeId = '',
}) {
  final index = jackLabelIndex(nodes);
  final clashes = <({String label, String usedBy})>[];
  final seen = <String, String>{};

  for (final label in candidates) {
    final key = normalizeJackLabel(label);
    if (key.isEmpty) continue;

    if (seen.containsKey(key)) {
      clashes.add((label: label, usedBy: 'twice in this box'));
      continue;
    }
    seen[key] = label;

    final uses = (index[key] ?? const <JackUse>[])
        .where((u) => u.nodeId != exceptNodeId)
        .toList();
    if (uses.isNotEmpty) {
      clashes.add((
        label: label,
        usedBy: uses.map((u) => u.nodeLabel).toSet().join(', '),
      ));
    }
  }
  return clashes;
}

/// The first number at or after [start] that gives [count] consecutive jack
/// labels none of which clash, or null when there isn't one within a sane
/// search.
///
/// This is what makes the duplicate check usable rather than merely correct:
/// being told "111001 is taken" and left to guess is worse than being offered
/// the next free block outright.
int? nextFreeJackStart({
  required String prefix,
  required int start,
  required int count,
  required int width,
  required Iterable<AvNode> nodes,
  String exceptNodeId = '',
}) {
  final index = jackLabelIndex(nodes);
  bool free(int first) {
    for (int i = 0; i < count; i++) {
      final label = '$prefix${'${first + i}'.padLeft(width, '0')}';
      final uses = (index[normalizeJackLabel(label)] ?? const <JackUse>[])
          .where((u) => u.nodeId != exceptNodeId);
      if (uses.isNotEmpty) return false;
    }
    return true;
  }

  // Far enough to step over any plausible existing numbering, and bounded so a
  // pathological prefix can't spin the UI.
  for (int first = start; first < start + 2000; first++) {
    if (free(first)) return first;
  }
  return null;
}

/// A config device that has ports available but isn't on the canvas yet.
class AvUnplacedDevice {
  final String key; // config section key
  final String label;
  final String model;

  /// True when this device was taken OFF the canvas by hand. It still belongs
  /// to the room, so the palette keeps listing it — marked, so it is obvious
  /// why the automatic seed leaves it alone — rather than hiding it and
  /// leaving no way back short of editing the sidecar.
  final bool dismissed;

  const AvUnplacedDevice({
    required this.key,
    required this.label,
    required this.model,
    this.dismissed = false,
  });
}
