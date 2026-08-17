import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'av_flow_model.dart';
import 'room_locations.dart';

/// ============================================================================
///  ROOM TYPE PRESETS
/// ============================================================================
///  A shop builds the same four or five rooms over and over. A basic classroom
///  has the same displays, the same wall plate, the same jack numbering scheme
///  and very nearly the same cable count every time; the differences are the
///  room number and which wall the screen is on.
///
///  Starting each of those from an empty canvas is how two rooms of the same
///  type end up with different jack prefixes, a different location vocabulary
///  and cable counts nobody can compare. So a room TYPE is a document: the
///  equipment, the locations, the jack fields with their numbering, the screen
///  runs and the racks, saved once and stamped out.
///
///  Presets live as files under `<root>/room_presets/`, one JSON file each, so
///  they can be shared on the same drive the catalog and the rate card already
///  live on. The four built-ins are written there on first use rather than
///  being compiled in and unreachable — a shop's "basic classroom" is not
///  ours, and the first thing anybody will want to do is change it.
///
///  Applying a preset never touches the room number, the building or the
///  control config. It brings the gear and the vocabulary; the room is still
///  the room.
/// ============================================================================

/// The folder presets live in, under the root folder.
const String kRoomPresetFolder = 'room_presets';

/// The extension that marks one.
const String kRoomPresetExtension = '.roompreset.json';

/// One saved room type.
///
/// Holds the same shapes the AV sidecar does, minus everything room-specific:
/// no cost overrides (a negotiated price belongs to a job), no floor plan (a
/// drawing belongs to a building), no room name.
class RoomPreset {
  /// Shown in the picker.
  final String name;

  /// A sentence about what this is for, shown under the name.
  final String description;

  /// True for the four this app ships. A shop's own presets are false, and
  /// only the built-ins are ever rewritten to disk on startup — so an edited
  /// copy of "Basic classroom" is never quietly reverted.
  final bool builtIn;

  final List<RoomLocation> locations;
  final List<AvNode> nodes;
  final List<AvCable> cables;
  final List<RackFrame> racks;
  final Map<String, RackSlot> rackSlots;
  final List<RackItem> rackItems;
  final List<ScreenSwitch> screenSwitches;

  /// The jack prefix these numbers were written with, so applying the preset
  /// into a room with a different number can renumber them.
  final String jackPrefix;

  const RoomPreset({
    required this.name,
    this.description = '',
    this.builtIn = false,
    this.locations = const [],
    this.nodes = const [],
    this.cables = const [],
    this.racks = const [],
    this.rackSlots = const {},
    this.rackItems = const [],
    this.screenSwitches = const [],
    this.jackPrefix = '',
  });

  /// How many jacks this room type lays in, for the picker's summary.
  int get jackCount =>
      nodes.where((n) => n.isJackField).fold(0, (sum, n) => sum + n.ports.length);

  int get deviceCount => nodes.where((n) => !n.isJackField).length;

  /// The file name this preset saves under.
  String get fileName =>
      '${name.trim().replaceAll(RegExp(r'[^\w\- ]+'), '_')}'
      '$kRoomPresetExtension';

  Map<String, dynamic> toJson() => {
    '__readme':
        'A room type for the Room Config Builder. Applying it puts this '
        'equipment, these locations and this jack numbering into a room; the '
        'room number, building and control config are left alone.',
    'name': name,
    if (description.isNotEmpty) 'description': description,
    if (builtIn) 'builtIn': true,
    if (jackPrefix.isNotEmpty) 'jackPrefix': jackPrefix,
    'locations': [for (final l in locations) l.toJson()],
    'nodes': [for (final n in nodes) n.toJson()],
    'cables': [for (final c in cables) c.toJson()],
    'racks': [for (final r in racks) r.toJson()],
    'rackItems': [for (final i in rackItems) i.toJson()],
    'rackSlots': rackSlots.map((id, s) => MapEntry(id, s.toJson())),
    'screenSwitches': [for (final s in screenSwitches) s.toJson()],
  };

  factory RoomPreset.fromJson(Map<String, dynamic> json) {
    final slots = <String, RackSlot>{};
    final raw = json['rackSlots'];
    if (raw is Map) {
      raw.forEach((id, value) {
        if (value is Map) {
          slots[id.toString()] = RackSlot.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    return RoomPreset(
      name: json['name']?.toString() ?? 'Room type',
      description: json['description']?.toString() ?? '',
      builtIn: json['builtIn'] == true,
      jackPrefix: json['jackPrefix']?.toString() ?? '',
      locations: [
        for (final l in (json['locations'] as List? ?? []))
          if (l is Map) RoomLocation.fromJson(Map<String, dynamic>.from(l)),
      ],
      nodes: [
        for (final n in (json['nodes'] as List? ?? []))
          if (n is Map) AvNode.fromJson(Map<String, dynamic>.from(n)),
      ],
      cables: [
        for (final c in (json['cables'] as List? ?? []))
          if (c is Map) AvCable.fromJson(Map<String, dynamic>.from(c)),
      ],
      racks: [
        for (final r in (json['racks'] as List? ?? []))
          if (r is Map) RackFrame.fromJson(Map<String, dynamic>.from(r)),
      ],
      rackItems: [
        for (final i in (json['rackItems'] as List? ?? []))
          if (i is Map) RackItem.fromJson(Map<String, dynamic>.from(i)),
      ],
      rackSlots: slots,
      screenSwitches: [
        for (final s in (json['screenSwitches'] as List? ?? []))
          if (s is Map) ScreenSwitch.fromJson(Map<String, dynamic>.from(s)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  READING AND WRITING THE FOLDER
// ---------------------------------------------------------------------------

/// The preset folder under [rootFolder], created if it isn't there.
Directory roomPresetDirectory(String rootFolder) {
  final dir = Directory(path.join(rootFolder, kRoomPresetFolder));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Every preset in the folder, built-ins first and then alphabetically.
///
/// A file that will not parse is logged and skipped rather than taking the
/// whole list down: one bad preset must not make the other four unreachable.
List<RoomPreset> loadRoomPresets(String rootFolder) {
  final out = <RoomPreset>[];
  try {
    final dir = roomPresetDirectory(rootFolder);
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith(kRoomPresetExtension)) continue;
      try {
        final doc = jsonDecode(entity.readAsStringSync());
        if (doc is! Map) continue;
        out.add(RoomPreset.fromJson(Map<String, dynamic>.from(doc)));
      } catch (e) {
        AppLogger.logError('Could not read the preset ${entity.path}', e);
      }
    }
  } catch (e) {
    AppLogger.logError('Could not read the room preset folder', e);
  }
  out.sort((a, b) {
    if (a.builtIn != b.builtIn) return a.builtIn ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

/// Writes [preset] into the folder. Returns the path, or '' on failure.
String saveRoomPreset(String rootFolder, RoomPreset preset) {
  try {
    final file = File(
      path.join(roomPresetDirectory(rootFolder).path, preset.fileName),
    );
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(preset.toJson()),
    );
    AppLogger.logInfo('Room preset saved as ${file.path}');
    return file.path;
  } catch (e, stack) {
    AppLogger.logError('Could not save the room preset', e, stack);
    return '';
  }
}

/// Puts the four shipped room types in the folder if they are not there yet.
///
/// Only writes what is MISSING. A shop that has edited "Basic classroom" keeps
/// its version — the whole point of shipping these as files is that the first
/// thing anybody does is change them — and one deleted on purpose comes back,
/// which is the trade that keeps this from needing a settings page.
int ensureBuiltInRoomPresets(String rootFolder) {
  int written = 0;
  try {
    final dir = roomPresetDirectory(rootFolder);
    for (final preset in builtInRoomPresets()) {
      final file = File(path.join(dir.path, preset.fileName));
      if (file.existsSync()) continue;
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(preset.toJson()),
      );
      written++;
    }
    if (written > 0) {
      AppLogger.logInfo(
        'Wrote $written built-in room preset(s) into ${dir.path}.',
      );
    }
  } catch (e, stack) {
    AppLogger.logError('Could not write the built-in room presets', e, stack);
  }
  return written;
}

// ---------------------------------------------------------------------------
//  THE FOUR SHIPPED ROOM TYPES
// ---------------------------------------------------------------------------

/// The jack prefix the built-ins are numbered with. Replaced with the room's
/// own number when a preset is applied — see `applyRoomPreset`.
const String kPresetJackPrefix = 'RM';

/// The four room types this app ships.
///
/// Each one is a REAL ROOM rather than an idea of one: the basic classroom is
/// AJH 125A with an Epson in place of its Panasonic, the hyflex classroom is
/// BSS 239, the active learning space is BSS 122, and the huddle space is the
/// small-room build. They name manufacturers and models, which the earlier
/// generic versions deliberately did not, and that was the mistake: a preset
/// with a nameless "Switcher" in it saves nobody the decision that actually
/// costs time, and every one of these rooms gets built again next summer with
/// the same box in it. The model is also what makes the rest of the app work —
/// the catalog knows its connectors and its price, and the module library
/// knows which python driver claims it, so a preset that names the model comes
/// out the far end as a costed drawing and a set of control blocks.
///
/// What is deliberately NOT here: IP addresses, GVE ids, room numbers and
/// switcher input numbers. Those are the room, and the room is still the room.
List<RoomPreset> builtInRoomPresets() => [
  _basicClassroom(),
  _hyflexClassroom(),
  _huddleSpace(),
  _activeLearningSpace(),
];

/// Builder helpers, kept local so the four presets below read as descriptions
/// of rooms rather than as constructor calls.

AvPort _p(String id, String label, SignalType s, PortDirection d,
    [PortSide? side]) =>
    AvPort(
      id: id,
      label: label,
      signal: s,
      direction: d,
      side: side ?? (d == PortDirection.output ? PortSide.right : PortSide.left),
    );

/// One drawn device.
///
/// [ports] are the connectors the room actually uses, spelled with the port
/// IDS THE CATALOG USES for that model — so a device dropped from a preset and
/// one dropped from the catalog are the same device, and re-picking the model
/// later does not orphan every cable on it. A model's full connector panel is
/// in the catalog; what a preset carries is the subset the room is wired on.
AvNode _device(
  String id,
  String label,
  String locationId,
  List<AvPort> ports, {
  Offset pos = Offset.zero,
  int rackUnits = 0,
  String model = '',
  PowerInput power = PowerInput.mains,
}) => AvNode(
  id: id,
  label: label,
  model: model,
  pos: pos,
  // withPowerInlet rather than a bare append: several of these port lists
  // come straight off the catalog and already carry the inlet, and a device
  // drawn with two power connectors is a device somebody has to fix.
  ports: withPowerInlet(ports, power),
  rackUnits: rackUnits,
  locationId: locationId,
  powerSource: power == PowerInput.none
      ? PowerSource.none
      : (power == PowerInput.poe ? PowerSource.poe : PowerSource.unspecified),
);

AvNode _jackField(
  String id,
  String label,
  String locationId,
  List<({String suffix, SignalType signal})> jacks, {
  Offset pos = Offset.zero,
}) => AvNode(
  id: id,
  label: label,
  model: '${jacks.length}-jack field',
  pos: pos,
  kind: AvNodeKind.jackField,
  powerSource: PowerSource.none,
  locationId: locationId,
  ports: [
    for (int i = 0; i < jacks.length; i++)
      AvPort(
        id: 'jack_${i + 1}',
        label: '$kPresetJackPrefix${jacks[i].suffix}',
        signal: jacks[i].signal,
        direction: PortDirection.bidirectional,
        side: i.isEven ? PortSide.left : PortSide.right,
      ),
  ],
);

AvCable _cable(
  String id,
  String from,
  String fromPort,
  String to,
  String toPort,
  SignalType signal, {
  String label = '',
}) => AvCable(
  id: id,
  fromNodeId: from,
  fromPortId: fromPort,
  toNodeId: to,
  toPortId: toPort,
  signal: signal,
  label: label,
);

// ---------------------------------------------------------------------------
//  PORT IDS THAT ARE NOT WORTH READING TWICE
// ---------------------------------------------------------------------------
//  Most catalog port ids say what they are (`in_hdbt_1`, `out_usb_1`). A
//  handful were generated when the model was first drawn and are a run of
//  digits, so they get a name here rather than being pasted into a cable list
//  where nobody can check them.

/// IN1608 SA — HDMI IN 5 and the first DTP (HDBaseT) input.
const String _in1608Hdmi5 = 'port_1786393528064191';
const String _in1608DtpIn = 'port_1786393608561286';

/// DTP HDMI 4K 230 transmitter output / receiver input.
const String _dtpTxOut = 'port_1786393062452313';
const String _dtpRxIn = 'port_1786393825139452';

// ---------------------------------------------------------------------------
//  THE PLACES THINGS LIVE
// ---------------------------------------------------------------------------
//  Shared across the presets so applying two of them to one room does not
//  produce "Ceiling" twice — applyRoomPreset matches an existing location by
//  NAME, and these are the names the rest of the app's reports already use.

const _lectern = RoomLocation(
  id: 'LOC_1',
  name: 'Instructor station',
  zone: RoomZone.lectern,
  callout: 'A',
);
const _frontWall = RoomLocation(
  id: 'LOC_2',
  name: 'Front wall',
  zone: RoomZone.wall,
  callout: 'B',
);
const _ceiling = RoomLocation(
  id: 'LOC_3',
  name: 'Ceiling',
  zone: RoomZone.ceiling,
  callout: 'C',
);
const _rackLocation = RoomLocation(
  id: 'LOC_4',
  name: 'Equipment rack',
  zone: RoomZone.rack,
  callout: 'D',
);
const _studentTable = RoomLocation(
  id: 'LOC_5',
  name: 'Student table',
  zone: RoomZone.table,
  callout: 'E',
);
const _rearWall = RoomLocation(
  id: 'LOC_6',
  name: 'Rear wall',
  zone: RoomZone.wall,
  callout: 'F',
);
const _credenza = RoomLocation(
  id: 'LOC_7',
  name: 'Credenza',
  zone: RoomZone.credenza,
  callout: 'G',
);

// ---------------------------------------------------------------------------
//  1. BASIC CLASSROOM  —  AJH 125A, with an Epson on the wall
// ---------------------------------------------------------------------------

/// The room most of the campus is made of: one projector, one switcher, a
/// lectern PC and a doc cam, and a DTP pair carrying the lectern's laptop feed
/// out and the projector feed back.
///
/// AJH 125A itself runs a Panasonic PT-FW430U. The Epson PowerLite L630U is
/// here instead because that is what goes in when one of these is replaced —
/// the projector is the one box in this room that is chosen per job, and
/// starting from the current standard rather than the installed one is the
/// point of a preset.
RoomPreset _basicClassroom() {
  final nodes = [
    _device(
      'AVNODE_1',
      'Instructor PC',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 60),
      model: 'PC',
    ),
    _device(
      'AVNODE_2',
      'Document camera',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 240),
      model: 'Document Camera',
    ),
    _device(
      'AVNODE_3',
      'Laptop at the lectern plate',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 420),
      model: 'HDMI Laptop',
      power: PowerInput.none,
    ),
    _jackField(
      'AVNODE_4',
      'Lectern wall plate',
      _lectern.id,
      const [
        (suffix: '01', signal: SignalType.hdmi),
        (suffix: '02', signal: SignalType.network),
        (suffix: '03', signal: SignalType.network),
      ],
      pos: const Offset(40, 600),
    ),
    _device(
      'AVNODE_5',
      'Lectern DTP transmitter',
      _lectern.id,
      [
        _p('hdmi', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        _p('audio', 'AUDIO IN', SignalType.analogAudio, PortDirection.input),
        _p(_dtpTxOut, 'DTP OUT', SignalType.hdbaset, PortDirection.output),
      ],
      pos: const Offset(400, 420),
      model: 'DTP HDMI 4K 230 Tx',
    ),
    _device(
      'SWITCHERDEVICE_1',
      'Switcher - IN1608 SA',
      _rackLocation.id,
      [
        _p('in_hdmi_3', 'HDMI IN 3', SignalType.hdmi, PortDirection.input),
        _p('in_hdmi_4', 'HDMI IN 4', SignalType.hdmi, PortDirection.input),
        _p(_in1608Hdmi5, 'HDMI IN 5', SignalType.hdmi, PortDirection.input),
        _p(_in1608DtpIn, 'DTP IN 7', SignalType.hdbaset, PortDirection.input),
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('out_dtp_1', 'DTP OUT', SignalType.hdbaset, PortDirection.output),
        _p('out_aud_1', 'AUDIO OUT', SignalType.analogAudio,
            PortDirection.output),
        // The SA is the stereo-amplifier build: the ceiling speakers land on
        // its own amp output, so this room has no separate amplifier.
        _p('sa_out', 'SPEAKER OUT', SignalType.speaker,
            PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(760, 240),
      rackUnits: 1,
      model: 'IN1608 SA',
    ),
    _device(
      'AVNODE_6',
      'Room-end DTP receiver',
      _frontWall.id,
      [
        _p(_dtpRxIn, 'DTP IN', SignalType.hdbaset, PortDirection.input),
        _p('hdmi', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('audio', 'AUDIO OUT', SignalType.analogAudio, PortDirection.output),
      ],
      pos: const Offset(1120, 60),
      model: 'DTP HDMI 4K 230 Rx',
    ),
    _device(
      'PROJECTORDEVICE_1',
      'Projector - PowerLite L630U',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdbt_1', 'HDBaseT', SignalType.hdbaset, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        _p('in_ctrl_1', 'RS-232', SignalType.serial, PortDirection.input),
      ],
      pos: const Offset(1480, 60),
      model: 'PowerLite L630U',
    ),
    _device(
      'CAMERADEVICE_1',
      'Camera - TR311',
      _frontWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(400, 60),
      model: 'TR311',
    ),
    _device(
      'AVNODE_7',
      'Ceiling speakers',
      _ceiling.id,
      [_p('in_spk_1', 'SPEAKER IN', SignalType.speaker, PortDirection.input)],
      pos: const Offset(1120, 420),
      power: PowerInput.none,
    ),
  ];

  return RoomPreset(
    name: 'Basic classroom',
    description:
        'AJH 125A: an Epson PowerLite L630U on the front wall fed over DTP '
        'from an Extron IN1608 SA, an instructor PC, a doc cam, a lectern '
        'laptop plate and a TR311 camera. Three jacks at the lectern, one 12U '
        'rack.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    locations: const [_lectern, _frontWall, _ceiling, _rackLocation],
    nodes: nodes,
    cables: [
      _cable('C1', 'AVNODE_1', 'out_1', 'SWITCHERDEVICE_1', 'in_hdmi_3',
          SignalType.hdmi, label: 'AV-01'),
      _cable('C2', 'AVNODE_2', 'out_1', 'SWITCHERDEVICE_1', 'in_hdmi_4',
          SignalType.hdmi, label: 'AV-02'),
      _cable('C3', 'AVNODE_3', 'out_1', 'AVNODE_4', 'jack_1', SignalType.hdmi,
          label: 'AV-03'),
      _cable('C4', 'AVNODE_4', 'jack_1', 'AVNODE_5', 'hdmi', SignalType.hdmi,
          label: 'AV-04'),
      _cable('C5', 'AVNODE_5', _dtpTxOut, 'SWITCHERDEVICE_1', _in1608DtpIn,
          SignalType.hdbaset, label: 'AV-05'),
      _cable('C6', 'CAMERADEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          _in1608Hdmi5, SignalType.hdmi, label: 'AV-06'),
      _cable('C7', 'SWITCHERDEVICE_1', 'out_dtp_1', 'AVNODE_6', _dtpRxIn,
          SignalType.hdbaset, label: 'AV-07'),
      _cable('C8', 'AVNODE_6', 'hdmi', 'PROJECTORDEVICE_1', 'in_hdmi_1',
          SignalType.hdmi, label: 'AV-08'),
      _cable('C9', 'SWITCHERDEVICE_1', 'sa_out', 'AVNODE_7', 'in_spk_1',
          SignalType.speaker, label: 'SPK-01'),
    ],
    racks: const [
      RackFrame(
        id: 'RACK_1',
        name: 'Lectern rack',
        heightU: 12,
        kind: 'Lectern built-in rack',
      ),
    ],
    rackSlots: const {
      'SWITCHERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 3),
    },
    screenSwitches: const [
      ScreenSwitch(
        id: 'SCRSW_1',
        label: 'Front screen',
        startLocationId: 'LOC_1',
        startNote: 'Switch at the instructor station',
        endLocationId: 'LOC_2',
        endNote: 'Screen motor above the board',
        cableType: '18/2 plenum',
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
//  2. HYFLEX CLASSROOM  —  BSS 239
// ---------------------------------------------------------------------------

/// A classroom that also has to work for the people who are not in it.
///
/// BSS 239 is the current standard build for that: a DTP CrossPoint 84 doing
/// the routing, a DMP 64 doing the audio, two AVer cameras, an AV Bridge
/// making the USB capture feed and an Inogeni Toggle handing that feed to
/// whichever computer is running the call. Everything that is not the projector
/// lives in one credenza rack, on an APC the panel can power-cycle.
RoomPreset _hyflexClassroom() {
  final nodes = [
    _device(
      'AVNODE_1',
      'Instructor PC',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 60),
      model: 'PC',
    ),
    _device(
      'AVNODE_2',
      'Document camera',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 240),
      model: 'Document Camera',
    ),
    _device(
      'AVNODE_3',
      'Laptop at the lectern plate',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 420),
      model: 'HDMI Laptop',
      power: PowerInput.none,
    ),
    _jackField(
      'AVNODE_4',
      'Lectern wall plate',
      _lectern.id,
      const [
        (suffix: '01', signal: SignalType.hdmi),
        (suffix: '02', signal: SignalType.usbData),
        (suffix: '03', signal: SignalType.network),
        (suffix: '04', signal: SignalType.network),
      ],
      pos: const Offset(40, 600),
    ),
    _device(
      'WIRELESSDEVICE_1',
      'Wireless - VIA GO2',
      _rackLocation.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('out_aud_1', 'AUDIO OUT', SignalType.analogAudio,
            PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 800),
      model: 'VIA GO2',
    ),
    _device(
      'CAMERADEVICE_1',
      'Camera 1 - Instructor TR311HWV2',
      _rearWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 980),
      model: 'TR311HWV2',
    ),
    _device(
      'CAMERADEVICE_2',
      'Camera 2 - Audience Cam570',
      _frontWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 1160),
      model: 'Cam570',
    ),
    _device(
      'AVNODE_5',
      'Ceiling mic array',
      _ceiling.id,
      [
        _p('out_mic_1', 'MIC OUT', SignalType.micLine, PortDirection.output),
      ],
      pos: const Offset(40, 1340),
    ),
    _device(
      'SWITCHERDEVICE_1',
      'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
      _rackLocation.id,
      [
        _p('hdmi_1', 'HDMI IN 1', SignalType.hdmi, PortDirection.input),
        _p('hdmi_2', 'HDMI IN 2', SignalType.hdmi, PortDirection.input),
        _p('hdmi_3', 'HDMI IN 3', SignalType.hdmi, PortDirection.input),
        _p('hdmi_4', 'HDMI IN 4', SignalType.hdmi, PortDirection.input),
        _p('hdmi_5', 'HDMI IN 5', SignalType.hdmi, PortDirection.input),
        _p('hdmi_6', 'HDMI IN 6', SignalType.hdmi, PortDirection.input),
        _p('hdmi_001', 'HDMI OUT 1', SignalType.hdmi, PortDirection.output),
        _p('hdmi_002', 'HDMI OUT 2', SignalType.hdmi, PortDirection.output),
        _p('dtp_out_003b', 'DTP OUT 3B', SignalType.hdbaset,
            PortDirection.output),
        _p('audio_001', 'AUDIO OUT 1', SignalType.analogAudio,
            PortDirection.output),
        _p('ma_out_70v', '70V AMP OUT', SignalType.speaker,
            PortDirection.output),
        _p('dmp_exp', 'DMP EXPANSION', SignalType.network,
            PortDirection.output),
        _p('lan', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(500, 240),
      rackUnits: 2,
      model: 'DTP CrossPoint 84 4K IPCP MA 70',
    ),
    _device(
      'DSPDEVICE_1',
      'DSP - DMP 64 Plus C AT',
      _rackLocation.id,
      [
        _p('mic_line_1', 'MIC/LINE 1', SignalType.micLine, PortDirection.input),
        _p('acp', 'ACP IN', SignalType.analogAudio, PortDirection.input),
        _p('audio_1', 'AUDIO OUT 1', SignalType.analogAudio,
            PortDirection.output),
        _p('audio_2', 'AUDIO OUT 2', SignalType.analogAudio,
            PortDirection.output),
      ],
      pos: const Offset(960, 700),
      rackUnits: 1,
      model: 'DMP 64 Plus C AT',
    ),
    _device(
      'RECORDERDEVICE_1',
      'Recorder - AV Bridge',
      _rackLocation.id,
      [
        _p('in_hdmi_1', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        _p('in_aud_1', 'AUDIO IN', SignalType.analogAudio, PortDirection.input),
        _p('out_usb_1', 'USB OUT', SignalType.usbData, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(960, 940),
      rackUnits: 1,
      model: 'AV Bridge',
    ),
    _device(
      'USBDEVICE_1',
      'USB Switcher - Toggle',
      _rackLocation.id,
      [
        _p('in_usb_1', 'USB HOST 1', SignalType.usbData, PortDirection.input),
        _p('in_usb_2', 'USB HOST 2', SignalType.usbData, PortDirection.input),
        _p('out_usb_1', 'USB DEVICE 1', SignalType.usbData,
            PortDirection.output),
        _p('in_ctrl_1', 'RS-232', SignalType.serial, PortDirection.input),
      ],
      pos: const Offset(960, 1180),
      model: 'Toggle',
    ),
    _device(
      'POWERDEVICE_1',
      'Power Controller - APC AP7900B',
      _rackLocation.id,
      [
        _p('out_pwr_1', 'OUTLET 1', SignalType.power, PortDirection.output),
        _p('out_pwr_2', 'OUTLET 2', SignalType.power, PortDirection.output),
        _p('out_pwr_3', 'OUTLET 3', SignalType.power, PortDirection.output),
        _p('out_pwr_4', 'OUTLET 4', SignalType.power, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(960, 1420),
      rackUnits: 1,
      model: 'AP7900B',
    ),
    _device(
      'PROJECTORDEVICE_1',
      'Projector - PowerLite L630U',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdbt_1', 'HDBaseT', SignalType.hdbaset, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        _p('in_ctrl_1', 'RS-232', SignalType.serial, PortDirection.input),
      ],
      pos: const Offset(1420, 60),
      model: 'PowerLite L630U',
    ),
    _device(
      'SCREENDEVICE_1',
      'Screen - DaLite Controller',
      _frontWall.id,
      [
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        _p('out_motor_1', 'SCREEN MOTOR', SignalType.other,
            PortDirection.output),
      ],
      pos: const Offset(1420, 300),
      model: 'Controller',
    ),
    _device(
      'AVNODE_6',
      'Confidence monitor',
      _lectern.id,
      [_p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input)],
      pos: const Offset(1420, 540),
    ),
    _device(
      'AVNODE_7',
      'Ceiling speakers',
      _ceiling.id,
      [_p('in_spk_1', 'SPEAKER IN', SignalType.speaker, PortDirection.input)],
      pos: const Offset(1420, 760),
      power: PowerInput.none,
    ),
  ];

  return RoomPreset(
    name: 'Hyflex classroom',
    description:
        'BSS 239: DTP CrossPoint 84 and a DMP 64 in a credenza rack, an Epson '
        'PowerLite L630U, instructor and audience cameras, a ceiling mic '
        'array, an AV Bridge capture feed through an Inogeni Toggle, a VIA GO2 '
        'and a networked DaLite screen controller — all on an APC AP7900B.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    locations: const [
      _lectern,
      _frontWall,
      _rearWall,
      _ceiling,
      _rackLocation,
    ],
    nodes: nodes,
    cables: [
      _cable('C1', 'AVNODE_1', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_1',
          SignalType.hdmi, label: 'AV-01'),
      _cable('C2', 'AVNODE_3', 'out_1', 'AVNODE_4', 'jack_1', SignalType.hdmi,
          label: 'AV-02'),
      _cable('C3', 'AVNODE_4', 'jack_1', 'SWITCHERDEVICE_1', 'hdmi_2',
          SignalType.hdmi, label: 'AV-03'),
      _cable('C4', 'WIRELESSDEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_3', SignalType.hdmi, label: 'AV-04'),
      _cable('C5', 'AVNODE_2', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_4',
          SignalType.hdmi, label: 'AV-05'),
      _cable('C6', 'CAMERADEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_5', SignalType.hdmi, label: 'AV-06'),
      _cable('C7', 'CAMERADEVICE_2', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_6', SignalType.hdmi, label: 'AV-07'),
      _cable('C8', 'SWITCHERDEVICE_1', 'dtp_out_003b', 'PROJECTORDEVICE_1',
          'in_hdbt_1', SignalType.hdbaset, label: 'AV-08'),
      _cable('C9', 'SWITCHERDEVICE_1', 'hdmi_002', 'AVNODE_6', 'in_hdmi_1',
          SignalType.hdmi, label: 'AV-09'),
      // The capture path: program video out to the AV Bridge, its USB into the
      // Toggle, and the Toggle's device port back out to the lectern plate so
      // a laptop can take the room's camera and mic for its own call.
      _cable('C10', 'SWITCHERDEVICE_1', 'hdmi_001', 'RECORDERDEVICE_1',
          'in_hdmi_1', SignalType.hdmi, label: 'AV-10'),
      _cable('C11', 'RECORDERDEVICE_1', 'out_usb_1', 'USBDEVICE_1', 'in_usb_1',
          SignalType.usbData, label: 'USB-01'),
      _cable('C12', 'USBDEVICE_1', 'out_usb_1', 'AVNODE_4', 'jack_2',
          SignalType.usbData, label: 'USB-02'),
      // Audio: the ceiling mics land on the DSP, the DSP's program feed goes
      // back to the switcher's amplifier, and the amp drives the ceiling.
      _cable('C13', 'AVNODE_5', 'out_mic_1', 'DSPDEVICE_1', 'mic_line_1',
          SignalType.micLine, label: 'AUD-01'),
      _cable('C14', 'SWITCHERDEVICE_1', 'audio_001', 'DSPDEVICE_1', 'acp',
          SignalType.analogAudio, label: 'AUD-02'),
      _cable('C15', 'DSPDEVICE_1', 'audio_2', 'RECORDERDEVICE_1', 'in_aud_1',
          SignalType.analogAudio, label: 'AUD-03'),
      _cable('C16', 'SWITCHERDEVICE_1', 'ma_out_70v', 'AVNODE_7', 'in_spk_1',
          SignalType.speaker, label: 'SPK-01'),
      _cable('C17', 'SWITCHERDEVICE_1', 'dmp_exp', 'DSPDEVICE_1', 'audio_1',
          SignalType.network, label: 'NET-01'),
    ],
    racks: const [
      RackFrame(
        id: 'RACK_1',
        name: 'Credenza rack',
        heightU: 18,
        kind: 'Credenza / cabinet rack',
      ),
    ],
    rackSlots: const {
      'SWITCHERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 3),
      'DSPDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 5),
      'RECORDERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 6),
      'POWERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 1),
    },
    screenSwitches: const [
      ScreenSwitch(
        id: 'SCRSW_1',
        label: 'Front screen',
        startLocationId: 'LOC_4',
        startNote: 'Screen controller in the rack',
        endLocationId: 'LOC_2',
        endNote: 'Screen motor above the board',
        cableType: '18/2 plenum',
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
//  3. HUDDLE SPACE
// ---------------------------------------------------------------------------

/// A small meeting room with no rack and no matrix.
///
/// The display is driven by an IPL Pro S1 xi rather than by a room processor
/// with a page of source buttons: there is one display, one PC and one way to
/// join a call, so what the control system has to do is turn the screen on and
/// off and put the right thing on it. The Neat Bar runs the meeting itself,
/// which is why there is no camera, no DSP and no capture card in this room —
/// the bar IS all three, and nothing in the rack list switches its audio.
RoomPreset _huddleSpace() => RoomPreset(
  name: 'Huddle space',
  description:
      'A small meeting room: a Neat Bar under the display running the call, a '
      'PC micro, a VIA GO3 for wireless, a table plate, and an IPL Pro S1 xi '
      'with a TouchLink panel driving the display. No rack.',
  builtIn: true,
  jackPrefix: kPresetJackPrefix,
  locations: const [_credenza, _frontWall, _ceiling],
  nodes: [
    _jackField(
      'AVNODE_1',
      'Table plate',
      _credenza.id,
      const [
        (suffix: '01', signal: SignalType.hdmi),
        (suffix: '02', signal: SignalType.network),
        (suffix: '03', signal: SignalType.network),
      ],
      pos: const Offset(40, 60),
    ),
    _device(
      'AVNODE_2',
      'Room PC',
      _credenza.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('out_dp_1', 'DISPLAYPORT OUT', SignalType.displayPort,
            PortDirection.output),
        _p('in_usb_1', 'USB', SignalType.usbData, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 300),
      model: 'PC Micro',
    ),
    _device(
      'WIRELESSDEVICE_1',
      'Wireless - VIA GO3',
      _credenza.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 540),
      model: 'VIA GO3',
    ),
    _device(
      'AVNODE_3',
      'Neat Bar',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_poe', 'LAN PoE', SignalType.network,
            PortDirection.bidirectional),
      ],
      pos: const Offset(440, 300),
      model: 'Neat Bar',
      power: PowerInput.poe,
    ),
    _device(
      'PROJECTORDEVICE_1',
      'Display',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdmi_2', 'HDMI 2', SignalType.hdmi, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        _p('in_ctrl_1', 'RS-232', SignalType.serial, PortDirection.input),
      ],
      pos: const Offset(840, 60),
    ),
    _device(
      'AVNODE_4',
      'Control processor - IPL Pro S1 xi',
      _credenza.id,
      [
        _p('lan_poe', 'LAN/ POE', SignalType.network,
            PortDirection.bidirectional),
        _p('com', 'COM', SignalType.serial, PortDirection.output),
      ],
      pos: const Offset(440, 600),
      model: 'IPL Pro S1 xi',
      power: PowerInput.poe,
    ),
    _device(
      'AVNODE_5',
      'Touch panel - TLP Pro 525M',
      _credenza.id,
      [
        _p('lan_poe', 'LAN PoE', SignalType.network,
            PortDirection.bidirectional),
        _p('usb', 'USB', SignalType.usbData, PortDirection.input),
      ],
      pos: const Offset(440, 840),
      model: 'TLP Pro 525M Black',
      power: PowerInput.poe,
    ),
  ],
  cables: [
    _cable('C1', 'AVNODE_1', 'jack_1', 'AVNODE_3', 'in_hdmi_1', SignalType.hdmi,
        label: 'AV-01'),
    _cable('C2', 'AVNODE_3', 'out_hdmi_1', 'PROJECTORDEVICE_1', 'in_hdmi_1',
        SignalType.hdmi, label: 'AV-02'),
    _cable('C3', 'AVNODE_2', 'out_hdmi_1', 'PROJECTORDEVICE_1', 'in_hdmi_2',
        SignalType.hdmi, label: 'AV-03'),
    _cable('C4', 'WIRELESSDEVICE_1', 'out_hdmi_1', 'AVNODE_1', 'jack_1',
        SignalType.hdmi, label: 'AV-04'),
    // The whole control system: one serial lead to the display, and a panel
    // that reaches the processor over the same PoE drop everything else uses.
    _cable('C5', 'AVNODE_4', 'com', 'PROJECTORDEVICE_1', 'in_ctrl_1',
        SignalType.serial, label: 'CTL-01'),
    _cable('C6', 'AVNODE_5', 'lan_poe', 'AVNODE_1', 'jack_2',
        SignalType.network, label: 'NET-01'),
    _cable('C7', 'AVNODE_3', 'lan_poe', 'AVNODE_1', 'jack_3',
        SignalType.network, label: 'NET-02'),
  ],
);

// ---------------------------------------------------------------------------
//  4. ACTIVE LEARNING SPACE  —  BSS 122
// ---------------------------------------------------------------------------

/// A flat-floor room with seven student stations, run over AV-over-IP.
///
/// BSS 122 is the NAV share room the ControlScript template's NavShareManager
/// was written for: each station is a Newline panel on the AV LAN, an encoder
/// input and a decoder output on the NAVigator, and the instructor can Share
/// one station to every screen, Preview it on the confidence monitor, or take
/// its USB and drive it from the front of the room.
///
/// The encoder/decoder pairs themselves are NOT drawn. They are configuration
/// on the NAVigator rather than boxes with a control block, and drawing
/// fourteen of them would bury the seven things this room is actually about.
/// What IS drawn is the AV LAN they all hang off, because that switch is a
/// real purchase and a real rack space.
RoomPreset _activeLearningSpace() {
  const stations = 7;

  final nodes = <AvNode>[
    _device(
      'AVNODE_1',
      'Instructor PC',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 60),
      model: 'PC',
    ),
    _device(
      'AVNODE_2',
      'Document camera',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 240),
      model: 'Document Camera',
    ),
    _device(
      'AVNODE_3',
      'Laptop at the lectern plate',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 420),
      model: 'HDMI Laptop',
      power: PowerInput.none,
    ),
    _jackField(
      'AVNODE_4',
      'Lectern wall plate',
      _lectern.id,
      const [
        (suffix: '01', signal: SignalType.hdmi),
        (suffix: '02', signal: SignalType.usbData),
        (suffix: '03', signal: SignalType.network),
        (suffix: '04', signal: SignalType.network),
      ],
      pos: const Offset(40, 600),
    ),
    _device(
      'WIRELESSDEVICE_1',
      'Wireless - VIA GO',
      _rackLocation.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('out_aud_1', 'AUDIO OUT', SignalType.analogAudio,
            PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 800),
      model: 'VIA GO',
    ),
    _device(
      'CAMERADEVICE_1',
      'Camera 1 - Instructor TR311HWV2',
      _rearWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 980),
      model: 'TR311HWV2',
    ),
    _device(
      'CAMERADEVICE_2',
      'Camera 2 - Audience PTZ330',
      _frontWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('out_usb_1', 'USB', SignalType.usbData, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 1160),
      model: 'PTZ330',
    ),
    _device(
      'AVNODE_5',
      'Ceiling mic array',
      _ceiling.id,
      [_p('out_mic_1', 'MIC OUT', SignalType.micLine, PortDirection.output)],
      pos: const Offset(40, 1340),
    ),
    _device(
      'SWITCHERDEVICE_1',
      'Switcher 1 - DTP CrossPoint 84 4K',
      _rackLocation.id,
      [
        _p('hdmi_001', 'HDMI IN 1', SignalType.hdmi, PortDirection.input),
        _p('hdmi_002', 'HDMI IN 2', SignalType.hdmi, PortDirection.input),
        _p('hdmi_003', 'HDMI IN 3', SignalType.hdmi, PortDirection.input),
        _p('hdmi_004', 'HDMI IN 4', SignalType.hdmi, PortDirection.input),
        _p('hdmi_005', 'HDMI IN 5', SignalType.hdmi, PortDirection.input),
        _p('hdmi_006', 'HDMI IN 6', SignalType.hdmi, PortDirection.input),
        _p('hdmi_1', 'HDMI OUT 1', SignalType.hdmi, PortDirection.output),
        _p('hdmi_2', 'HDMI OUT 2', SignalType.hdmi, PortDirection.output),
        _p('dtp_out_1', 'DTP OUT 3B', SignalType.hdbaset,
            PortDirection.output),
        _p('dtp_out_2', 'DTP OUT 4B', SignalType.hdbaset,
            PortDirection.output),
        _p('audio_1_2', 'AUDIO OUT 1', SignalType.analogAudio,
            PortDirection.output),
        _p('dmp_exp', 'DMP EXPANSION', SignalType.network,
            PortDirection.output),
        _p('lan', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(500, 240),
      rackUnits: 2,
      model: 'DTP CrossPoint 84 4K',
    ),
    _device(
      'SWITCHERDEVICE_2',
      'Switcher 2 - IN1804',
      _rackLocation.id,
      [
        _p('hdmi_002', 'HDMI IN 2', SignalType.hdmi, PortDirection.input),
        _p('hdmi_003', 'HDMI IN 3', SignalType.hdmi, PortDirection.input),
        _p('hdmi_cec_1a', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(500, 900),
      rackUnits: 1,
      model: 'IN1804',
    ),
    _device(
      'SWITCHERDEVICE_3',
      'Switcher 3 - SW4 HD 4K PLUS',
      _rackLocation.id,
      [
        _p('hdmi_1', 'HDMI IN 1', SignalType.hdmi, PortDirection.input),
        _p('hdmi_2', 'HDMI IN 2', SignalType.hdmi, PortDirection.input),
        _p('hdmi', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('rs_232', 'RS-232', SignalType.serial, PortDirection.bidirectional),
      ],
      pos: const Offset(500, 1140),
      rackUnits: 1,
      model: 'SW4 HD 4K PLUS',
    ),
    _device(
      'DSPDEVICE_1',
      'DSP - DMP 64 Plus C AT',
      _rackLocation.id,
      [
        _p('mic_line_1', 'MIC/LINE 1', SignalType.micLine, PortDirection.input),
        _p('acp', 'ACP IN', SignalType.analogAudio, PortDirection.input),
        _p('audio_1', 'AUDIO OUT 1', SignalType.analogAudio,
            PortDirection.output),
        _p('audio_2', 'AUDIO OUT 2', SignalType.analogAudio,
            PortDirection.output),
      ],
      pos: const Offset(960, 700),
      rackUnits: 1,
      model: 'DMP 64 Plus C AT',
    ),
    _device(
      'MEDIAPORTDEVICE_1',
      'MediaPort - MediaPort 200',
      _rackLocation.id,
      [
        _p('hdmi', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        _p('audio', 'AUDIO IN', SignalType.analogAudio, PortDirection.input),
        _p('usb', 'USB OUT', SignalType.usbData, PortDirection.output),
      ],
      pos: const Offset(960, 940),
      rackUnits: 1,
      model: 'MediaPort 200',
    ),
    _device(
      'RECORDERDEVICE_1',
      'Recorder - AV Bridge 2x1',
      _rackLocation.id,
      [
        _p('in_hdmi_1', 'HDMI IN 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdmi_2', 'HDMI IN 2', SignalType.hdmi, PortDirection.input),
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('in_aud_1', 'AUDIO IN', SignalType.analogAudio, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(960, 1180),
      rackUnits: 1,
      model: 'AV Bridge 2x1',
    ),
    _device(
      'USBDEVICE_1',
      'USB Switcher - Toggle',
      _rackLocation.id,
      [
        _p('in_usb_1', 'USB HOST 1', SignalType.usbData, PortDirection.input),
        _p('in_usb_2', 'USB HOST 2', SignalType.usbData, PortDirection.input),
        _p('out_usb_1', 'USB DEVICE 1', SignalType.usbData,
            PortDirection.output),
        _p('in_ctrl_1', 'RS-232', SignalType.serial, PortDirection.input),
      ],
      pos: const Offset(960, 1420),
      model: 'Toggle',
    ),
    _device(
      'POWERDEVICE_1',
      'Power Controller - APC AP7921B',
      _rackLocation.id,
      [
        _p('out_pwr_1', 'OUTLET 1', SignalType.power, PortDirection.output),
        _p('out_pwr_2', 'OUTLET 2', SignalType.power, PortDirection.output),
        _p('out_pwr_3', 'OUTLET 3', SignalType.power, PortDirection.output),
        _p('out_pwr_4', 'OUTLET 4', SignalType.power, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(960, 1660),
      rackUnits: 1,
      model: 'AP7921B',
    ),
    // The AV-over-IP half of the room.
    _device(
      'NAVDEVICE_1',
      'NAVigator - Stream Manager',
      _rackLocation.id,
      [
        _p('nav', 'AV LAN', SignalType.network, PortDirection.output),
        _p('oob', 'OOB LAN', SignalType.network, PortDirection.output),
      ],
      pos: const Offset(1420, 700),
      model: 'NAVigator',
    ),
    _device(
      'AVNODE_6',
      'AV LAN switch',
      _rackLocation.id,
      [
        _p('uplink', 'UPLINK', SignalType.network, PortDirection.input),
        for (int i = 1; i <= stations; i++)
          _p('lan_$i', 'PORT $i', SignalType.network, PortDirection.output),
      ],
      pos: const Offset(1420, 940),
      rackUnits: 1,
    ),
    _device(
      'PROJECTORDEVICE_1',
      'Projector 1 - PowerLite L630U',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdbt_1', 'HDBaseT', SignalType.hdbaset, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(1420, 60),
      model: 'PowerLite L630U',
    ),
    _device(
      'PROJECTORDEVICE_2',
      'Projector 2 - PowerLite L630U',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdbt_1', 'HDBaseT', SignalType.hdbaset, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(1420, 300),
      model: 'PowerLite L630U',
    ),
    _device(
      'SCREENDEVICE_1',
      'Screen 1 - DaLite Controller',
      _frontWall.id,
      [
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        _p('out_motor_1', 'SCREEN MOTOR', SignalType.other,
            PortDirection.output),
      ],
      pos: const Offset(1880, 60),
      model: 'Controller',
    ),
    _device(
      'SCREENDEVICE_2',
      'Screen 2 - DaLite Controller',
      _frontWall.id,
      [
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        _p('out_motor_1', 'SCREEN MOTOR', SignalType.other,
            PortDirection.output),
      ],
      pos: const Offset(1880, 300),
      model: 'Controller',
    ),
    _device(
      'AVNODE_7',
      'Confidence monitor',
      _lectern.id,
      [_p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input)],
      pos: const Offset(1880, 540),
    ),
    _device(
      'AVNODE_8',
      'Ceiling speakers',
      _ceiling.id,
      [_p('in_spk_1', 'SPEAKER IN', SignalType.speaker, PortDirection.input)],
      pos: const Offset(1880, 760),
      power: PowerInput.none,
    ),
    // One student station: a Newline panel and the plate the student's laptop
    // lands on. STATIONDEVICE_n is the config block the share page drives.
    for (int i = 1; i <= stations; i++)
      _jackField(
        'AVNODE_${10 + i}',
        'Station $i table plate',
        _studentTable.id,
        [
          (suffix: '${(i * 10) + 1}', signal: SignalType.hdmi),
          (suffix: '${(i * 10) + 2}', signal: SignalType.network),
          (suffix: '${(i * 10) + 3}', signal: SignalType.network),
        ],
        pos: Offset(2340, 60 + (i - 1) * 240),
      ),
    for (int i = 1; i <= stations; i++)
      _device(
        'STATIONDEVICE_$i',
        'Station $i Display - TT-7523Q',
        _studentTable.id,
        [
          _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
          _p('in_hdmi_2', 'HDMI 2', SignalType.hdmi, PortDirection.input),
          _p('out_usb_touch', 'USB TOUCH', SignalType.usbData,
              PortDirection.output),
          _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
          _p('in_ctrl_1', 'RS-232', SignalType.serial, PortDirection.input),
        ],
        pos: Offset(2800, 60 + (i - 1) * 240),
        model: 'TT-7523Q',
      ),
  ];

  return RoomPreset(
    name: 'Active learning space',
    description:
        'BSS 122: a NAV share room. Seven Newline student stations on the AV '
        'LAN behind a NAVigator, two Epson projectors, two DaLite screens, a '
        'DTP CrossPoint 84 with an IN1804 and an SW4 behind it, a DMP 64, a '
        'MediaPort 200 and an AV Bridge 2x1. Twenty-one station jacks before '
        'the lectern is counted.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    locations: const [
      _lectern,
      _studentTable,
      _frontWall,
      _rearWall,
      _ceiling,
      _rackLocation,
    ],
    nodes: nodes,
    cables: [
      _cable('C1', 'AVNODE_1', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_001',
          SignalType.hdmi, label: 'AV-01'),
      _cable('C2', 'AVNODE_3', 'out_1', 'AVNODE_4', 'jack_1', SignalType.hdmi,
          label: 'AV-02'),
      _cable('C3', 'AVNODE_4', 'jack_1', 'SWITCHERDEVICE_1', 'hdmi_002',
          SignalType.hdmi, label: 'AV-03'),
      _cable('C4', 'WIRELESSDEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_003', SignalType.hdmi, label: 'AV-04'),
      _cable('C5', 'AVNODE_2', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_004',
          SignalType.hdmi, label: 'AV-05'),
      _cable('C6', 'CAMERADEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_005', SignalType.hdmi, label: 'AV-06'),
      _cable('C7', 'CAMERADEVICE_2', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_006', SignalType.hdmi, label: 'AV-07'),
      _cable('C8', 'SWITCHERDEVICE_1', 'dtp_out_1', 'PROJECTORDEVICE_1',
          'in_hdbt_1', SignalType.hdbaset, label: 'AV-08'),
      _cable('C9', 'SWITCHERDEVICE_1', 'dtp_out_2', 'PROJECTORDEVICE_2',
          'in_hdbt_1', SignalType.hdbaset, label: 'AV-09'),
      _cable('C10', 'SWITCHERDEVICE_1', 'hdmi_2', 'AVNODE_7', 'in_hdmi_1',
          SignalType.hdmi, label: 'AV-10'),
      // Capture: switcher 1 to the AV Bridge, switcher 2 picking which camera
      // the MediaPort sends, switcher 3 doing the same for the conference feed.
      _cable('C11', 'SWITCHERDEVICE_1', 'hdmi_1', 'RECORDERDEVICE_1',
          'in_hdmi_1', SignalType.hdmi, label: 'AV-11'),
      _cable('C12', 'CAMERADEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_2',
          'hdmi_002', SignalType.hdmi, label: 'AV-12'),
      _cable('C13', 'CAMERADEVICE_2', 'out_hdmi_1', 'SWITCHERDEVICE_2',
          'hdmi_003', SignalType.hdmi, label: 'AV-13'),
      _cable('C14', 'SWITCHERDEVICE_2', 'hdmi_cec_1a', 'MEDIAPORTDEVICE_1',
          'hdmi', SignalType.hdmi, label: 'AV-14'),
      _cable('C15', 'SWITCHERDEVICE_1', 'hdmi_1', 'SWITCHERDEVICE_3', 'hdmi_1',
          SignalType.hdmi, label: 'AV-15'),
      _cable('C16', 'MEDIAPORTDEVICE_1', 'usb', 'USBDEVICE_1', 'in_usb_1',
          SignalType.usbData, label: 'USB-01'),
      _cable('C17', 'USBDEVICE_1', 'out_usb_1', 'AVNODE_4', 'jack_2',
          SignalType.usbData, label: 'USB-02'),
      // Audio.
      _cable('C18', 'AVNODE_5', 'out_mic_1', 'DSPDEVICE_1', 'mic_line_1',
          SignalType.micLine, label: 'AUD-01'),
      _cable('C19', 'SWITCHERDEVICE_1', 'audio_1_2', 'DSPDEVICE_1', 'acp',
          SignalType.analogAudio, label: 'AUD-02'),
      _cable('C20', 'DSPDEVICE_1', 'audio_1', 'AVNODE_8', 'in_spk_1',
          SignalType.speaker, label: 'SPK-01'),
      _cable('C21', 'DSPDEVICE_1', 'audio_2', 'MEDIAPORTDEVICE_1', 'audio',
          SignalType.analogAudio, label: 'AUD-03'),
      // The AV LAN: the NAVigator's stream port feeds the switch, and every
      // station display hangs off it. The encoder/decoder at each station sits
      // on the same drop — see the note above the preset.
      _cable('C22', 'NAVDEVICE_1', 'nav', 'AVNODE_6', 'uplink',
          SignalType.network, label: 'NET-01'),
      for (int i = 1; i <= stations; i++)
        _cable('C${22 + i}', 'AVNODE_6', 'lan_$i', 'STATIONDEVICE_$i', 'lan_1',
            SignalType.network, label: 'NET-${(i + 1).toString().padLeft(2, '0')}'),
      // Each station's own plate into its own panel.
      for (int i = 1; i <= stations; i++)
        _cable('C${29 + i}', 'AVNODE_${10 + i}', 'jack_1', 'STATIONDEVICE_$i',
            'in_hdmi_1', SignalType.hdmi,
            label: 'AV-${(20 + i).toString()}'),
    ],
    racks: const [
      RackFrame(
        id: 'RACK_1',
        name: 'Equipment rack',
        heightU: 24,
        kind: 'Free-standing rack',
      ),
    ],
    rackSlots: const {
      'POWERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 1),
      'SWITCHERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 3),
      'SWITCHERDEVICE_2': RackSlot(rackId: 'RACK_1', startU: 5),
      'SWITCHERDEVICE_3': RackSlot(rackId: 'RACK_1', startU: 6),
      'DSPDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 7),
      'MEDIAPORTDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 8),
      'RECORDERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 9),
      'AVNODE_6': RackSlot(rackId: 'RACK_1', startU: 11),
    },
    screenSwitches: const [
      ScreenSwitch(
        id: 'SCRSW_1',
        label: 'Front screen 1',
        startLocationId: 'LOC_4',
        startNote: 'Screen controller in the rack',
        endLocationId: 'LOC_2',
        endNote: 'Screen motor above the board',
        cableType: '18/2 plenum',
      ),
      ScreenSwitch(
        id: 'SCRSW_2',
        label: 'Front screen 2',
        startLocationId: 'LOC_4',
        startNote: 'Screen controller in the rack',
        endLocationId: 'LOC_2',
        endNote: 'Screen motor above the board',
        cableType: '18/2 plenum',
      ),
    ],
  );
}
