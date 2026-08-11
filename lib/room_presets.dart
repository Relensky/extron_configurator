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
/// They are deliberately generic: no manufacturer, no model numbers, no
/// prices. A preset that named a specific projector would be wrong the week
/// after the next price list, and picking the model is the one decision that
/// genuinely differs room to room. What they DO carry is the part that is the
/// same every time and the slowest to re-enter: the locations, the jack fields
/// with their numbering, the screen run, and which boxes feed which.
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

AvNode _device(
  String id,
  String label,
  String locationId,
  List<AvPort> ports, {
  Offset pos = Offset.zero,
  int rackUnits = 0,
  String model = '',
}) => AvNode(
  id: id,
  label: label,
  model: model,
  pos: pos,
  ports: [...ports, powerInletPort(PowerInput.mains)],
  rackUnits: rackUnits,
  locationId: locationId,
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

const _lectern = RoomLocation(
  id: 'LOC_1',
  name: 'Instructor station',
  zone: RoomZone.lectern,
  callout: 'A',
);
const _floorBox = RoomLocation(
  id: 'LOC_2',
  name: 'Front floor box',
  zone: RoomZone.floor,
  callout: 'B',
);
const _frontWall = RoomLocation(
  id: 'LOC_3',
  name: 'Front wall',
  zone: RoomZone.wall,
  callout: 'C',
);
const _ceiling = RoomLocation(
  id: 'LOC_4',
  name: 'Ceiling',
  zone: RoomZone.ceiling,
  callout: 'D',
);
const _rackLocation = RoomLocation(
  id: 'LOC_5',
  name: 'Equipment rack',
  zone: RoomZone.rack,
  callout: 'E',
);
const _table = RoomLocation(
  id: 'LOC_6',
  name: 'Table',
  zone: RoomZone.table,
  callout: 'F',
);

/// One display, one wall plate, a lectern PC and a screen. The room most of a
/// campus is made of.
RoomPreset _basicClassroom() {
  final nodes = [
    _device(
      'AVNODE_1',
      'Instructor PC',
      _lectern.id,
      [_p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 60),
    ),
    _jackField(
      'AVNODE_2',
      'Lectern wall plate',
      _lectern.id,
      const [
        (suffix: '01', signal: SignalType.hdmi),
        (suffix: '02', signal: SignalType.network),
        (suffix: '03', signal: SignalType.network),
      ],
      pos: const Offset(40, 260),
    ),
    _device(
      'AVNODE_3',
      'Switcher',
      _rackLocation.id,
      [
        _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdmi_2', 'HDMI 2', SignalType.hdmi, PortDirection.input),
        _p('out_hdbt_1', 'HDBT OUT', SignalType.hdbaset, PortDirection.output),
        _p('out_audio_1', 'AUDIO OUT', SignalType.analogAudio,
            PortDirection.output),
      ],
      pos: const Offset(400, 60),
      rackUnits: 1,
    ),
    _device(
      'AVNODE_4',
      'Projector',
      _frontWall.id,
      [_p('in_hdbt_1', 'HDBT IN', SignalType.hdbaset, PortDirection.input)],
      pos: const Offset(760, 60),
    ),
    _device(
      'AVNODE_5',
      'Ceiling speakers',
      _ceiling.id,
      [_p('in_spk_1', 'SPEAKER IN', SignalType.speaker, PortDirection.input)],
      pos: const Offset(760, 260),
    ),
  ];

  return RoomPreset(
    name: 'Basic classroom',
    description:
        'One projector or display, a lectern plate, an instructor PC and a '
        'motorized screen. Three jacks at the lectern, one rack.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    locations: const [_lectern, _frontWall, _ceiling, _rackLocation],
    nodes: nodes,
    cables: [
      _cable('C1', 'AVNODE_1', 'out_hdmi_1', 'AVNODE_2', 'jack_1',
          SignalType.hdmi, label: 'AV-01'),
      _cable('C2', 'AVNODE_2', 'jack_1', 'AVNODE_3', 'in_hdmi_1',
          SignalType.hdmi, label: 'AV-02'),
      _cable('C3', 'AVNODE_3', 'out_hdbt_1', 'AVNODE_4', 'in_hdbt_1',
          SignalType.hdbaset, label: 'AV-03'),
      _cable('C4', 'AVNODE_3', 'out_audio_1', 'AVNODE_5', 'in_spk_1',
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
      'AVNODE_3': RackSlot(rackId: 'RACK_1', startU: 3),
    },
    screenSwitches: const [
      ScreenSwitch(
        id: 'SCRSW_1',
        label: 'Front screen',
        startLocationId: 'LOC_1',
        startNote: 'Switch at the instructor station',
        endLocationId: 'LOC_3',
        endNote: 'Screen motor above the board',
        cableType: '18/2 plenum',
      ),
    ],
  );
}

/// A classroom that also has to work for people who aren't in it: a camera, a
/// ceiling mic array, a DSP and a codec PC, all of which have to be somewhere.
RoomPreset _hyflexClassroom() {
  final base = _basicClassroom();
  final nodes = <AvNode>[
    ...base.nodes,
    _device(
      'AVNODE_6',
      'Instructor camera',
      _frontWall.id,
      [
        _p('out_usb_1', 'USB', SignalType.usbData, PortDirection.output),
        _p('io_lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 460),
    ),
    _device(
      'AVNODE_7',
      'Ceiling mic array',
      _ceiling.id,
      [
        _p('out_dante_1', 'DANTE', SignalType.dante,
            PortDirection.bidirectional),
      ],
      pos: const Offset(40, 660),
    ),
    _device(
      'AVNODE_8',
      'DSP',
      _rackLocation.id,
      [
        _p('in_dante_1', 'DANTE', SignalType.dante,
            PortDirection.bidirectional),
        _p('out_audio_1', 'AMP OUT', SignalType.analogAudio,
            PortDirection.output),
      ],
      pos: const Offset(400, 460),
      rackUnits: 1,
    ),
    _jackField(
      'AVNODE_9',
      'Front floor box',
      _floorBox.id,
      const [
        (suffix: '11', signal: SignalType.network),
        (suffix: '12', signal: SignalType.network),
        (suffix: '13', signal: SignalType.hdmi),
        (suffix: '14', signal: SignalType.usbData),
      ],
      pos: const Offset(400, 660),
    ),
  ];

  return RoomPreset(
    name: 'Hyflex classroom',
    description:
        'A basic classroom plus the remote-teaching side: instructor camera, '
        'ceiling mic array, DSP and a floor box with four jacks.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    locations: const [
      _lectern,
      _floorBox,
      _frontWall,
      _ceiling,
      _rackLocation,
    ],
    nodes: nodes,
    cables: [
      ...base.cables,
      _cable('C5', 'AVNODE_6', 'out_usb_1', 'AVNODE_9', 'jack_4',
          SignalType.usbData, label: 'USB-01'),
      _cable('C6', 'AVNODE_7', 'out_dante_1', 'AVNODE_8', 'in_dante_1',
          SignalType.dante, label: 'NET-01'),
      _cable('C7', 'AVNODE_8', 'out_audio_1', 'AVNODE_5', 'in_spk_1',
          SignalType.analogAudio, label: 'SPK-02'),
    ],
    racks: const [
      RackFrame(
        id: 'RACK_1',
        name: 'Equipment rack',
        heightU: 18,
        kind: 'Credenza / cabinet rack',
      ),
    ],
    rackSlots: const {
      'AVNODE_3': RackSlot(rackId: 'RACK_1', startU: 3),
      'AVNODE_8': RackSlot(rackId: 'RACK_1', startU: 5),
    },
    screenSwitches: base.screenSwitches,
  );
}

/// A small meeting room: one display, one all-in-one bar, a table plate.
RoomPreset _huddleSpace() => RoomPreset(
  name: 'Huddle space',
  description:
      'A small meeting room: one display, a video bar under it and a table '
      'plate with two jacks. No rack.',
  builtIn: true,
  jackPrefix: kPresetJackPrefix,
  locations: const [_table, _frontWall, _ceiling],
  nodes: [
    _jackField(
      'AVNODE_1',
      'Table plate',
      _table.id,
      const [
        (suffix: '01', signal: SignalType.hdmi),
        (suffix: '02', signal: SignalType.network),
      ],
      pos: const Offset(40, 60),
    ),
    _device(
      'AVNODE_2',
      'Video bar',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('io_lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(400, 60),
    ),
    _device(
      'AVNODE_3',
      'Display',
      _frontWall.id,
      [_p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input)],
      pos: const Offset(760, 60),
    ),
  ],
  cables: [
    _cable('C1', 'AVNODE_1', 'jack_1', 'AVNODE_2', 'in_hdmi_1',
        SignalType.hdmi, label: 'AV-01'),
    _cable('C2', 'AVNODE_2', 'out_hdmi_1', 'AVNODE_3', 'in_hdmi_1',
        SignalType.hdmi, label: 'AV-02'),
  ],
);

/// A flat-floor room with pods: several displays, several table plates, and
/// the switching to get any source to any of them.
RoomPreset _activeLearningSpace() {
  const pods = 4;
  final nodes = <AvNode>[
    _device(
      'AVNODE_1',
      'Matrix switcher',
      _rackLocation.id,
      [
        for (int i = 1; i <= pods; i++)
          _p('in_hdbt_$i', 'HDBT IN $i', SignalType.hdbaset,
              PortDirection.input),
        for (int i = 1; i <= pods; i++)
          _p('out_hdbt_$i', 'HDBT OUT $i', SignalType.hdbaset,
              PortDirection.output),
      ],
      pos: const Offset(400, 60),
      rackUnits: 2,
    ),
    _device(
      'AVNODE_2',
      'Instructor display',
      _frontWall.id,
      [_p('in_hdbt_1', 'HDBT IN', SignalType.hdbaset, PortDirection.input)],
      pos: const Offset(760, 60),
    ),
    for (int i = 1; i <= pods; i++)
      _jackField(
        'AVNODE_${10 + i}',
        'Pod $i table plate',
        _table.id,
        [
          (suffix: '${(i * 10) + 1}', signal: SignalType.hdmi),
          (suffix: '${(i * 10) + 2}', signal: SignalType.network),
          (suffix: '${(i * 10) + 3}', signal: SignalType.network),
        ],
        pos: Offset(40, 60 + (i - 1) * 220),
      ),
    for (int i = 1; i <= pods; i++)
      _device(
        'AVNODE_${20 + i}',
        'Pod $i display',
        _frontWall.id,
        [_p('in_hdbt_1', 'HDBT IN', SignalType.hdbaset, PortDirection.input)],
        pos: Offset(1120, 60 + (i - 1) * 220),
      ),
  ];

  return RoomPreset(
    name: 'Active learning space',
    description:
        'A flat-floor room with four pods: a matrix switcher, a display and a '
        'three-jack plate per pod, and an instructor display. Twelve pod '
        'jacks before the lectern is counted.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    locations: const [
      _lectern,
      _table,
      _frontWall,
      _ceiling,
      _rackLocation,
    ],
    nodes: nodes,
    cables: [
      _cable('C1', 'AVNODE_1', 'out_hdbt_1', 'AVNODE_2', 'in_hdbt_1',
          SignalType.hdbaset, label: 'AV-01'),
      for (int i = 1; i <= pods; i++)
        _cable('C${1 + i}', 'AVNODE_${10 + i}', 'jack_1', 'AVNODE_1',
            'in_hdbt_$i', SignalType.hdbaset, label: 'AV-${10 + i}'),
      for (int i = 1; i <= pods; i++)
        _cable('C${5 + i}', 'AVNODE_1', 'out_hdbt_$i', 'AVNODE_${20 + i}',
            'in_hdbt_1', SignalType.hdbaset, label: 'AV-${20 + i}'),
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
      'AVNODE_1': RackSlot(rackId: 'RACK_1', startU: 3),
    },
  );
}
