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
/// no cost overrides (a negotiated price belongs to a job) and no room name.
///
/// A DRAWING still belongs to a building and is still not here. What is here
/// is the SHEET — blank paper with the room's own locations already placed on
/// it, so the layout can be walked and marked up before anybody has the
/// architect's PDF. Import one later and the markers are already where this
/// room type puts them.
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

  /// Sheets this room type lays out on, with its locations already placed.
  ///
  /// The marker keys are the preset's own location ids ('LOC_1'); applying it
  /// remaps them onto whatever ids the room ends up giving those locations.
  final List<FloorPlan> floorPlans;

  /// The jack prefix these numbers were written with, so applying the preset
  /// into a room with a different number can renumber them.
  final String jackPrefix;

  /// SYSTEM_SETUP values this room TYPE decides, written into the config when
  /// the preset is applied.
  ///
  /// The switcher input and output numbers are the ones the preset's own
  /// cabling lands on — a preset that draws the PC into HDMI IN 3 and says
  /// nothing about `input_pc` has left the reader to read the numbers off the
  /// drawing and type them in, which is the second pass this whole file exists
  /// to remove. The source layout (`gui_inputs` / `gui_tab_type`) and the
  /// routing mode belong here for the same reason: how many source buttons a
  /// hyflex room has is a fact about hyflex rooms.
  ///
  /// Still NOT here, and still deliberately: IP addresses, GVE ids, the room
  /// number, and anything a specific building decides. Those are the room.
  ///
  /// A key mapped to '' is a statement, not an omission — "this room type has
  /// no assisted-listening feed" — and is written as a blank, because the
  /// template config carries a demonstration room's number in every one of
  /// these fields and a number nobody chose is worse than an empty box.
  final Map<String, String> systemSetup;

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
    this.floorPlans = const [],
    this.jackPrefix = '',
    this.systemSetup = const {},
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
    if (systemSetup.isNotEmpty) 'systemSetup': systemSetup,
    'locations': [for (final l in locations) l.toJson()],
    'nodes': [for (final n in nodes) n.toJson()],
    'cables': [for (final c in cables) c.toJson()],
    'racks': [for (final r in racks) r.toJson()],
    'rackItems': [for (final i in rackItems) i.toJson()],
    'rackSlots': rackSlots.map((id, s) => MapEntry(id, s.toJson())),
    'screenSwitches': [for (final s in screenSwitches) s.toJson()],
    if (floorPlans.isNotEmpty)
      'floorPlans': [for (final f in floorPlans) f.toJson()],
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
    // Everything in SYSTEM_SETUP is written as a string by the rest of the
    // app, so a preset file that spells a number as a JSON number still comes
    // back as the '3' the config wants rather than as an int the field
    // editors would refuse to show.
    final settings = <String, String>{};
    final rawSettings = json['systemSetup'];
    if (rawSettings is Map) {
      rawSettings.forEach((key, value) {
        settings[key.toString()] = value?.toString() ?? '';
      });
    }
    return RoomPreset(
      name: json['name']?.toString() ?? 'Room type',
      description: json['description']?.toString() ?? '',
      builtIn: json['builtIn'] == true,
      jackPrefix: json['jackPrefix']?.toString() ?? '',
      systemSetup: settings,
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
      floorPlans: [
        for (final f in (json['floorPlans'] as List? ?? []))
          if (f is Map)
            FloorPlan.fromJson(Map<String, dynamic>.from(f)),
      ],
      screenSwitches: [
        for (final s in (json['screenSwitches'] as List? ?? []))
          if (s is Map) ScreenSwitch.fromJson(Map<String, dynamic>.from(s)),
      ],
    );
  }
}

/// The `gui_*` settings a room TYPE decides, as opposed to the ones a
/// particular room does.
///
/// An allow-list rather than a prefix match, because the `gui_` namespace also
/// holds `gui_full_room_name` — the room's own name, which is exactly what a
/// preset must never carry — and the camera preset labels, which name one
/// room's whiteboards.
const Set<String> kPresetGuiKeys = {
  'gui_inputs',
  'gui_tab_type',
  'gui_routing_mode',
  'gui_routing_available',
  'gui_capture_source_available',
  'gui_mic_mix',
  'gui_usb_or_vga',
};

/// The SYSTEM_SETUP keys worth saving into a preset, pulled out of a live
/// room's block.
///
/// Every `input_*` and `output_*` (the switcher I/O map, which is decided by
/// how the room type is wired) plus [kPresetGuiKeys]. Everything else — the
/// addresses, the GVE ids, the room number, the hardware counts the prefill
/// works out for itself — is left where it is.
Map<String, String> presetSystemSetupFrom(Map<dynamic, dynamic> setup) {
  final out = <String, String>{};
  setup.forEach((rawKey, value) {
    final key = rawKey.toString();
    final wanted =
        key.startsWith('input_') ||
        key.startsWith('output_') ||
        kPresetGuiKeys.contains(key);
    if (!wanted) return;
    out[key] = value?.toString() ?? '';
  });
  return out;
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

/// Room types that shipped under a longer name, and what they are called now.
///
/// Keyed by the OLD name. A folder written by an earlier version has files
/// called "Hyflex classroom.roompreset.json"; leaving them there beside the
/// new "Hyflex.roompreset.json" would put the same room type in the picker
/// twice, and deleting them would throw away whatever a shop had changed. So
/// the old file is renamed and its `name` rewritten, which keeps the edits and
/// leaves one entry.
const Map<String, String> kRenamedBuiltInPresets = {
  'Hyflex classroom': 'Hyflex',
  'Huddle space': 'Huddle',
  'Active learning space': 'Active learning',
};

/// Puts the four shipped room types in the folder if they are not there yet.
///
/// Only writes what is MISSING. A shop that has edited "Basic classroom" keeps
/// its version — the whole point of shipping these as files is that the first
/// thing anybody does is change them — and one deleted on purpose comes back,
/// which is the trade that keeps this from needing a settings page.
///
/// Presets that have been renamed since are migrated rather than duplicated —
/// see [kRenamedBuiltInPresets].
int ensureBuiltInRoomPresets(String rootFolder) {
  int written = 0;
  try {
    final dir = roomPresetDirectory(rootFolder);
    for (final preset in builtInRoomPresets()) {
      final file = File(path.join(dir.path, preset.fileName));
      if (file.existsSync()) continue;
      if (_migrateRenamedPreset(dir, preset)) continue;
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

/// Renames the file [preset] used to ship under, if it is still there.
///
/// Returns true when a file was migrated, which tells the caller not to write
/// the shipped copy over the top of somebody's edited one.
///
/// The `name` inside the file is rewritten along with the file name, because
/// the name in the JSON is what the picker shows — migrating one without the
/// other gives an entry that reads "Hyflex classroom" out of a file called
/// Hyflex. Anything else in the file is left exactly as it was found.
bool _migrateRenamedPreset(Directory dir, RoomPreset preset) {
  String? oldName;
  kRenamedBuiltInPresets.forEach((was, now) {
    if (now == preset.name) oldName = was;
  });
  if (oldName == null) return false;

  final legacy = File(
    path.join(dir.path, RoomPreset(name: oldName!).fileName),
  );
  if (!legacy.existsSync()) return false;

  try {
    final doc = jsonDecode(legacy.readAsStringSync());
    if (doc is! Map) return false;
    final updated = Map<String, dynamic>.from(doc);
    updated['name'] = preset.name;
    File(path.join(dir.path, preset.fileName)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(updated),
    );
    legacy.deleteSync();
    AppLogger.logInfo(
      'Renamed the "$oldName" room preset to "${preset.name}".',
    );
    return true;
  } catch (e, stack) {
    // A file that cannot be read is left alone rather than deleted, and the
    // shipped copy is written beside it. Two entries in the picker is a
    // nuisance; losing a shop's edited preset is not.
    AppLogger.logError(
      'Could not rename the "$oldName" room preset — leaving it as it is',
      e,
      stack,
    );
    return false;
  }
}

// ---------------------------------------------------------------------------
//  THE FOUR SHIPPED ROOM TYPES
// ---------------------------------------------------------------------------

/// The jack prefix a preset's numbered boxes are written with, replaced with
/// the room's own number when the preset is applied — see `applyRoomPreset`.
///
/// None of the four shipped types carries a jack field any more: these rooms
/// are drawn device-to-device, and a plate is a thing a particular building
/// asks for rather than part of the room type. The constant stays because a
/// preset SAVED from a room that does have plates still needs a prefix to be
/// renumbered from, and that is the case the renumbering exists for.
const String kPresetJackPrefix = 'RM';

/// The four room types this app ships.
///
/// Each one is drawn from a build that actually exists, but it is named for
/// the TYPE and never for the room: "Hyflex", not the room the drawing was
/// taken off. A preset called after a specific room reads as a record of that
/// room — somebody opens it expecting that room's numbering and that room's
/// gear, and a preset is neither. It is the shape every room of this kind
/// starts from.
///
/// They do name manufacturers and models, which the earlier generic versions
/// deliberately did not, and that was the mistake: a preset with a nameless
/// "Switcher" in it saves nobody the decision that actually costs time, and
/// every one of these rooms gets built again next summer with the same box in
/// it. The model is also what makes the rest of the app work — the catalog
/// knows its connectors and its price, and the module library knows which
/// python driver claims it, so a preset that names the model comes out the far
/// end as a costed drawing and a set of control blocks.
///
/// What is deliberately NOT here: IP addresses, GVE ids and room numbers.
/// Those are the room, and the room is still the room. Switcher input and
/// output numbers ARE here now — see [RoomPreset.systemSetup] — because they
/// are decided by the wiring the preset itself draws.
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

/// The doc cam's and the DSP's USB sockets, which is what the room hands to
/// whichever machine is driving the call.
const String _docCamUsbOut = 'port_1786645719293090';
const String _dmpUsbOut = 'port_1786645739822174';

/// The DMP 64 Plus C AT's expansion-bus socket, which only ever meets the
/// matrix's own — see [expansionBusFor].
const String _dmpExpIn = 'port_1786645606221064';

/// The room PC's USB socket, and the AV Bridge 2x1's USB output.
const String _pcUsbIn = 'port_1786645419251345';
const String _avBridgeUsbOut = 'port_1786645836574383';

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
//  1. BASIC CLASSROOM
// ---------------------------------------------------------------------------

/// The room most of the campus is made of: one projector, one switcher, a
/// lectern PC and a doc cam, and a DTP pair carrying the lectern's laptop feed
/// out and the projector feed back.
///
/// The projector is the one box in this room that gets chosen per job, so it
/// is the current standard (an Epson PowerLite L630U) rather than whatever is
/// on the wall of any particular room — starting from what goes in on a
/// replacement is the point of a preset.
/// A blank sheet with this room type's locations already on it.
///
/// No image: it is paper. The point is to have something to walk the room
/// against before the architect's PDF turns up — and when one does turn up,
/// the markers are already where this room type puts them, so importing it is
/// a background change rather than a re-survey.
///
/// The coordinates are a plan-view arrangement of a generic room on a
/// 1200x900 sheet, not a measurement: the front wall along the top, the
/// lectern below it, the rack to one side, seating in the middle. Drag them
/// onto the real thing when there is a real thing.
FloorPlan _blankSheet(Map<String, Offset> markers) => FloorPlan(
  id: '',
  name: 'Room layout',
  markers: markers,
);

/// Where each location sits on that generic sheet.
const Offset _planFrontWall = Offset(600, 120);
const Offset _planLectern = Offset(420, 300);
const Offset _planCeiling = Offset(600, 470);
const Offset _planRack = Offset(180, 320);
const Offset _planStudentTable = Offset(600, 620);
const Offset _planRearWall = Offset(600, 800);

RoomPreset _basicClassroom() {
  final nodes = [
    _device(
      'AVNODE_1',
      'Instructor PC',
      _lectern.id,
      [
        _p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        // Where the room's picture comes back INTO the PC, so a call running
        // on it can share what is on the screens — see AVNODE_8.
        _p(_pcUsbIn, 'USB', SignalType.usbData, PortDirection.input),
      ],
      pos: const Offset(40, 60),
      model: 'PC',
    ),
    // The doc cam is a source and nothing else: no config block, no module,
    // no line on the control schematic. It is on the drawing because a lead
    // runs from it, and on the estimate because somebody buys it — exactly
    // what input_pc and input_hdmi are.
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
      'Laptop at the lectern',
      _lectern.id,
      [_p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output)],
      pos: const Offset(40, 420),
      model: 'HDMI Laptop',
      power: PowerInput.none,
    ),
    // Every camera in every one of these rooms is at the far end of the room
    // from the rack, so every one of them crosses it on twisted pair. The
    // camera's own socket is HDMI, so that means a transmitter beside it.
    //
    // Named for the position rather than "camera": familyForNode reads an
    // unmodelled box's label as words, and that word would make each of these
    // a CAMERADEVICE block with a driver slot of its own.
    _device(
      'AVNODE_9',
      'DTP transmitter — instructor',
      _frontWall.id,
      [
        _p('hdmi', 'HDMI', SignalType.hdmi, PortDirection.input),
        _p(_dtpTxOut, 'DTP', SignalType.hdbaset, PortDirection.output),
      ],
      pos: const Offset(400, 620),
      model: 'DTP HDMI 4K 230 Tx',
    ),
    // Output 2's HDMI connector goes here rather than to a second screen: the
    // interface turns the room's program feed into a USB camera the PC's own
    // conferencing software picks up. There is no driver for it — it is a
    // converter, and nothing about it is worth a control line.
    _device(
      'AVNODE_8',
      'AverMedia USB Interface',
      _lectern.id,
      [
        _p('in_hdmi_1', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        _p('out_usb_1', 'USB OUT', SignalType.usbData, PortDirection.output),
      ],
      pos: const Offset(1120, 240),
      model: 'AverMedia USB Interface',
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
      'Switcher - DTP CrossPoint 82 4K IPCP SA',
      _rackLocation.id,
      [
        _p('hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('hdmi_2', 'HDMI 2', SignalType.hdmi, PortDirection.input),
        _p('hdmi_3', 'HDMI 3', SignalType.hdmi, PortDirection.input),
        // Inputs 7 and 8 on this box, whatever the connector is printed with.
        _p('dtp_in_1', 'DTP IN 1', SignalType.hdbaset, PortDirection.input),
        _p('dtp_in_2', 'DTP IN 2', SignalType.hdbaset, PortDirection.input),
        // Output 1 goes to the projector over twisted pair; output 2's HDMI
        // connector is the loop-thru the USB interface takes.
        _p('dtp_out_1', 'DTP OUT 1', SignalType.hdbaset, PortDirection.output),
        _p('hdmi_002a', 'HDMI 002A', SignalType.hdmi, PortDirection.output),
        _p('audio_1_2', 'AUDIO 1', SignalType.analogAudio,
            PortDirection.output),
        // The SA build has the amplifier in it: the ceiling speakers land on
        // its own output, so this room has no separate amplifier.
        _p('sa_out_8_4', 'SA OUT 8\u03A9/4\u03A9', SignalType.speaker,
            PortDirection.output),
        _p('lan', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(760, 240),
      rackUnits: 2,
      model: 'DTP CrossPoint 82 4K IPCP SA',
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
      'Camera - TR211',
      _frontWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(400, 60),
      model: 'TR211',
    ),
    _device(
      'AVNODE_7',
      'Speakers - SM 28',
      _ceiling.id,
      [_p('in_spk_1', 'SPEAKER IN', SignalType.speaker, PortDirection.input)],
      pos: const Offset(1120, 420),
      // 8 ohm rather than the 70V SM 28T: the IN1608 SA is the stereo-amplifier
      // build, and its amp drives these directly.
      model: 'SM 28 Black',
      power: PowerInput.none,
    ),
  ];

  return RoomPreset(
    name: 'Basic classroom',
    description:
        'A single projector room. One screen on the front wall fed over DTP '
        'from an Extron DTP CrossPoint 82 4K IPCP SA, an instructor PC, a doc '
        'cam, a lectern laptop feed and a TR211 camera, on a pair of SM 28s. '
        'The loop-thru output goes through an AverMedia USB interface so the '
        'PC can share the room. One 12U rack.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    // Read off the cabling below. The IN1608's scaled output goes out of both
    // the HDMI and the DTP connector, so the projector and the program audio
    // are both output 1.
    //
    // gui_inputs / gui_tab_type are deliberately absent: this room's sources
    // are PC, HDMI and a doc cam, and every three- and four-source layout the
    // schema offers adds a USB, VGA or wireless input this room does not have.
    // Picking the nearest one would put a dead button on the panel, so the
    // choice is left to whoever builds the room.
    systemSetup: const {
      'input_pc': '1',
      'input_doc_cam': '2',
      // DTP IN 2 — input 8 on an 8x2, the camera's pair from the rear wall.
      'input_inst_cam': '8',
      // DTP IN 1 is input 7 on an 8x2 CrossPoint — six HDMI, then the two
      // twisted-pair inputs — whatever the connector itself is printed with.
      'input_hdmi': '7',
      'input_aud_cam': '',
      'input_wireless': '',
      'input_usb': '',
      'input_pc_extended': '',
      // Output 1's DTP connector — the projector is on twisted pair, and on
      // an 8x2 CrossPoint each output carries both an HDMI socket and a DTP
      // one. A bare '1' is the HDMI socket of that output; the B says which.
      'output_proj_1': '1B',
      'output_audio': '1',
      'output_monitor_1': '',
      // Output 2's HDMI connector, into the USB interface. It is a capture
      // feed in everything but name: what leaves the room on a call.
      'output_cc': '2',
      'output_cc2': '',
      'output_audio_ald': '',
      'gui_routing_mode': 'Normal',
      'gui_routing_available': 'No',
      'gui_capture_source_available': 'No',
    },
    locations: const [_lectern, _frontWall, _ceiling, _rackLocation],
    nodes: nodes,
    cables: [
      _cable('C1', 'AVNODE_1', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_1',
          SignalType.hdmi, label: 'AV-01'),
      _cable('C2', 'AVNODE_2', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_2',
          SignalType.hdmi, label: 'AV-02'),
      // The laptop plugs straight into the transmitter at the lectern — there
      // is no plate between them any more.
      _cable('C3', 'AVNODE_3', 'out_1', 'AVNODE_5', 'hdmi', SignalType.hdmi,
          label: 'AV-03'),
      _cable('C4', 'AVNODE_5', _dtpTxOut, 'SWITCHERDEVICE_1', 'dtp_in_1',
          SignalType.hdbaset, label: 'AV-04'),
      _cable('C5', 'CAMERADEVICE_1', 'out_hdmi_1', 'AVNODE_9', 'hdmi',
          SignalType.hdmi, label: 'AV-05'),
      _cable('C5B', 'AVNODE_9', _dtpTxOut, 'SWITCHERDEVICE_1', 'dtp_in_2',
          SignalType.hdbaset, label: 'AV-05B'),
      // Straight into the projector's own HDBaseT socket: no receiver, no box
      // on the wall behind the screen, one pair from the rack.
      _cable('C7', 'SWITCHERDEVICE_1', 'dtp_out_1', 'PROJECTORDEVICE_1',
          'in_hdbt_1', SignalType.hdbaset, label: 'AV-07'),
      _cable('C8', 'SWITCHERDEVICE_1', 'sa_out_8_4', 'AVNODE_7', 'in_spk_1',
          SignalType.speaker, label: 'SPK-01'),
      // The loop-thru, and what it is for: out of the switcher, through the
      // converter, into the PC as a camera.
      _cable('C9', 'SWITCHERDEVICE_1', 'hdmi_002a', 'AVNODE_8', 'in_hdmi_1',
          SignalType.hdmi, label: 'AV-08'),
      _cable('C10', 'AVNODE_8', 'out_usb_1', 'AVNODE_1', _pcUsbIn,
          SignalType.usbData, label: 'USB-01'),
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
    floorPlans: [
      _blankSheet(const {
        'LOC_1': _planLectern,
        'LOC_2': _planFrontWall,
        'LOC_3': _planCeiling,
        'LOC_4': _planRack,
      }),
    ],
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
//  2. HYFLEX
// ---------------------------------------------------------------------------

/// A classroom that also has to work for the people who are not in it.
///
/// The current standard build for that: a DTP CrossPoint 84 doing the routing,
/// a DMP 64 doing the audio, two AVer cameras, an AV Bridge making the USB
/// capture feed and an Inogeni Toggle handing that feed to whichever computer
/// is running the call. Everything that is not the projector lives in one
/// credenza rack, on an APC the panel can power-cycle.
RoomPreset _hyflexClassroom() {
  final nodes = [
    _device(
      'AVNODE_1',
      'Instructor PC',
      _lectern.id,
      [
        _p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        // What the Toggle hands it: the room's microphones, the doc cam and
        // the AV Bridge's picture of the room, as one set of USB peripherals.
        _p(_pcUsbIn, 'USB', SignalType.usbData, PortDirection.input),
      ],
      pos: const Offset(40, 60),
      model: 'PC',
    ),
    _device(
      'AVNODE_2',
      'Document camera',
      _lectern.id,
      [
        _p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p(_docCamUsbOut, 'USB OUT', SignalType.usbData,
            PortDirection.output),
      ],
      pos: const Offset(40, 240),
      model: 'Document Camera',
    ),
    _device(
      'AVNODE_3',
      'Laptop at the lectern',
      _lectern.id,
      [
        _p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        // Where the room hands over its camera and microphone: the Toggle's
        // device port lands here, so a laptop can run the call on the room's
        // own gear. It was a jack on the lectern plate until the plates came
        // out; the run itself is the same run.
        _p('in_usb_1', 'USB', SignalType.usbData, PortDirection.input),
      ],
      pos: const Offset(40, 420),
      model: 'HDMI Laptop',
      power: PowerInput.none,
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
      'Camera 1 - Instructor TR211',
      _rearWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 980),
      model: 'TR211',
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
        // Where the two cameras' pairs land.
        _p('dtp_in_1', 'DTP IN 7', SignalType.hdbaset, PortDirection.input),
        _p('dtp_in_2', 'DTP IN 8', SignalType.hdbaset, PortDirection.input),
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
        _p(_dmpUsbOut, 'USB OUT', SignalType.usbData, PortDirection.output),
      ],
      pos: const Offset(960, 700),
      rackUnits: 1,
      model: 'DMP 64 Plus C AT',
    ),
    _device(
      'AVNODE_9',
      'DTP transmitter — instructor',
      _rearWall.id,
      [
        _p('hdmi', 'HDMI', SignalType.hdmi, PortDirection.input),
        _p(_dtpTxOut, 'DTP', SignalType.hdbaset, PortDirection.output),
      ],
      pos: const Offset(960, 60),
      model: 'DTP HDMI 4K 230 Tx',
    ),
    _device(
      'AVNODE_10',
      'DTP transmitter — audience',
      _frontWall.id,
      [
        _p('hdmi', 'HDMI', SignalType.hdmi, PortDirection.input),
        _p(_dtpTxOut, 'DTP', SignalType.hdbaset, PortDirection.output),
      ],
      pos: const Offset(960, 300),
      model: 'DTP HDMI 4K 230 Tx',
    ),

    _device(
      'RECORDERDEVICE_1',
      'Recorder - AV Bridge 2x1',
      _rackLocation.id,
      [
        _p('in_hdmi_1', 'HDMI IN 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdmi_2', 'HDMI IN 2', SignalType.hdmi, PortDirection.input),
        _p('in_aud_1', 'AUDIO IN', SignalType.analogAudio, PortDirection.input),
        _p(_avBridgeUsbOut, 'USB OUT', SignalType.usbData,
            PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(960, 940),
      rackUnits: 1,
      model: 'AV Bridge 2x1',
    ),
    _device(
      'USBDEVICE_1',
      'USB Switcher - Toggle',
      _rackLocation.id,
      [
        _p('in_usb_1', 'USB DEVICE 1', SignalType.usbData,
            PortDirection.input),
        _p('in_usb_2', 'USB DEVICE 2', SignalType.usbData,
            PortDirection.input),
        _p('in_usb_3', 'USB DEVICE 3', SignalType.usbData,
            PortDirection.input),
        _p('out_usb_1', 'USB HOST 1', SignalType.usbData,
            PortDirection.output),
        _p('out_usb_2', 'USB HOST 2', SignalType.usbData,
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
    name: 'Hyflex',
    description:
        'DTP CrossPoint 84 and a DMP 64 in the rack, an Epson PowerLite '
        'L630U, instructor and audience cameras, a ceiling mic array, an AV '
        'Bridge 2x1 capture feed through an Inogeni Toggle, a VIA GO2 and a '
        'networked DaLite screen controller — all on an APC AP7900B.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    // Read off the cabling below. The projector hangs off DTP OUT 3B, which
    // the processor reads as output 3 — the letter is kept because that is
    // what is printed on the connector somebody has to plug into.
    systemSetup: const {
      'input_pc': '1',
      'input_hdmi': '2',
      'input_wireless': '3',
      'input_doc_cam': '4',
      'input_inst_cam': '5',
      'input_aud_cam': '6',
      'input_usb': '',
      'input_pc_extended': '',
      'output_cc': '1',
      'output_monitor_1': '2',
      'output_proj_1': '3B',
      'output_audio': '1',
      'output_cc2': '',
      'output_audio_ald': '',
      // PC, HDMI, doc cam and the VIA — the four things with a source button.
      'gui_inputs': '4',
      'gui_tab_type': 'DOC_WL',
      'gui_routing_mode': 'Normal',
      'gui_capture_source_available': 'Yes',
      'gui_mic_mix': 'Ceiling',
      // The DaLite controller is on the network, so the processor talks to it
      // rather than closing a pair of relays at it.
      'dev_screen_control': 'Network',
    },
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
      _cable('C2', 'AVNODE_3', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_2',
          SignalType.hdmi, label: 'AV-02'),
      _cable('C3', 'WIRELESSDEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_3', SignalType.hdmi, label: 'AV-03'),
      _cable('C4', 'AVNODE_2', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_4',
          SignalType.hdmi, label: 'AV-04'),
      // Both cameras cross the room on twisted pair, each with its own
      // transmitter beside it.
      _cable('C5', 'CAMERADEVICE_1', 'out_hdmi_1', 'AVNODE_9', 'hdmi',
          SignalType.hdmi, label: 'AV-05'),
      _cable('C5B', 'AVNODE_9', _dtpTxOut, 'SWITCHERDEVICE_1', 'dtp_in_1',
          SignalType.hdbaset, label: 'AV-05B'),
      _cable('C6', 'CAMERADEVICE_2', 'out_hdmi_1', 'AVNODE_10', 'hdmi',
          SignalType.hdmi, label: 'AV-06'),
      _cable('C6B', 'AVNODE_10', _dtpTxOut, 'SWITCHERDEVICE_1', 'dtp_in_2',
          SignalType.hdbaset, label: 'AV-06B'),
      _cable('C7', 'SWITCHERDEVICE_1', 'dtp_out_003b', 'PROJECTORDEVICE_1',
          'in_hdbt_1', SignalType.hdbaset, label: 'AV-07'),
      _cable('C8', 'SWITCHERDEVICE_1', 'hdmi_002', 'AVNODE_6', 'in_hdmi_1',
          SignalType.hdmi, label: 'AV-08'),
      // The capture path: program video out to the AV Bridge, its USB into the
      // Toggle, and the Toggle's device port back out to the lectern so a
      // laptop can take the room's camera and mic for its own call.
      _cable('C9', 'SWITCHERDEVICE_1', 'hdmi_001', 'RECORDERDEVICE_1',
          'in_hdmi_1', SignalType.hdmi, label: 'AV-09'),
      // What the room hands to whichever machine is driving the call, in the
      // order the Toggle's DEVICE ports are wired in every build: the DSP's
      // microphone mix, the AV Bridge's picture of the room, then the doc
      // cam. HOST 1 is the room PC, and the Toggle picks which machine has
      // them.
      _cable('C10', 'DSPDEVICE_1', _dmpUsbOut, 'USBDEVICE_1', 'in_usb_1',
          SignalType.usbData, label: 'USB-01'),
      _cable('C10B', 'RECORDERDEVICE_1', _avBridgeUsbOut, 'USBDEVICE_1',
          'in_usb_2', SignalType.usbData, label: 'USB-02'),
      _cable('C10C', 'AVNODE_2', _docCamUsbOut, 'USBDEVICE_1', 'in_usb_3',
          SignalType.usbData, label: 'USB-03'),
      _cable('C11', 'USBDEVICE_1', 'out_usb_1', 'AVNODE_1', _pcUsbIn,
          SignalType.usbData, label: 'USB-04'),
      _cable('C11B', 'USBDEVICE_1', 'out_usb_2', 'AVNODE_3', 'in_usb_1',
          SignalType.usbData, label: 'USB-05'),
      // Audio: the ceiling mics land on the DSP, the DSP's program feed goes
      // back to the switcher's amplifier, and the amp drives the ceiling.
      _cable('C12', 'AVNODE_5', 'out_mic_1', 'DSPDEVICE_1', 'mic_line_1',
          SignalType.micLine, label: 'AUD-01'),
      _cable('C13', 'SWITCHERDEVICE_1', 'audio_001', 'DSPDEVICE_1', 'acp',
          SignalType.analogAudio, label: 'AUD-02'),
      _cable('C14', 'DSPDEVICE_1', 'audio_2', 'RECORDERDEVICE_1', 'in_aud_1',
          SignalType.analogAudio, label: 'AUD-03'),
      _cable('C15', 'SWITCHERDEVICE_1', 'ma_out_70v', 'AVNODE_7', 'in_spk_1',
          SignalType.speaker, label: 'SPK-01'),
      _cable('C16', 'SWITCHERDEVICE_1', 'dmp_exp', 'DSPDEVICE_1', 'audio_1',
          SignalType.network, label: 'NET-01'),
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
      'SWITCHERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 3),
      'DSPDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 5),
      'RECORDERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 6),
      'POWERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 1),
    },
    floorPlans: [
      _blankSheet(const {
        'LOC_1': _planLectern,
        'LOC_2': _planFrontWall,
        'LOC_3': _planCeiling,
        'LOC_4': _planRack,
        'LOC_6': _planRearWall,
      }),
    ],
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
//  3. HUDDLE
// ---------------------------------------------------------------------------

/// A small meeting room with no rack and no matrix.
///
/// The display is driven by an IPCP Pro 255Q xi rather than by a room processor
/// with a page of source buttons: there is one display, one PC and one way to
/// join a call, so what the control system has to do is turn the screen on and
/// off and put the right thing on it. The Neat Bar runs the meeting itself,
/// which is why there is no camera, no DSP and no capture card in this room —
/// the bar IS all three, and nothing in the rack list switches its audio.
///
/// The wireless feed reaches the display end over a DTP pair rather than a
/// plate: everything but the bar and the screen lives in the credenza, and one
/// twisted pair is what crosses the room.
RoomPreset _huddleSpace() => RoomPreset(
  name: 'Huddle',
  description:
      'A small meeting room: a Neat Bar under the display running the call, a '
      'PC micro, a VIA GO2 over a DTP pair, and an IPCP Pro 255Q xi with a '
      'TouchLink panel driving the display, on a two-outlet SurgeX PDU. '
      'No rack.',
  builtIn: true,
  jackPrefix: kPresetJackPrefix,
  // There is no matrix in this room — the wireless comes in over DTP, the bar
  // and the PC go to the display's two HDMI inputs, and the processor's whole
  // job is the display's RS-232. So every switcher I/O number is blank on
  // purpose, and output_proj_1 is the documented 'None': there is no switcher
  // output to send a video mute to.
  systemSetup: const {
    'input_pc': '',
    'input_hdmi': '',
    'input_wireless': '',
    'input_doc_cam': '',
    'input_usb': '',
    'input_inst_cam': '',
    'input_aud_cam': '',
    'input_pc_extended': '',
    'output_proj_1': 'None',
    'output_audio': '',
    'output_audio_ald': '',
    'output_monitor_1': '',
    'output_cc': '',
    'output_cc2': '',
    'gui_routing_mode': 'Normal',
    'gui_routing_available': 'No',
    'gui_capture_source_available': 'No',
  },
  locations: const [_credenza, _frontWall, _ceiling],
  nodes: [
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
      'Wireless - VIA GO2',
      _credenza.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 540),
      model: 'VIA GO2',
    ),
    _device(
      'AVNODE_1',
      'Credenza DTP transmitter',
      _credenza.id,
      [
        _p('hdmi', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        _p('audio', 'AUDIO IN', SignalType.analogAudio, PortDirection.input),
        _p(_dtpTxOut, 'DTP OUT', SignalType.hdbaset, PortDirection.output),
      ],
      pos: const Offset(40, 780),
      model: 'DTP HDMI 4K 230 Tx',
    ),
    _device(
      'AVNODE_6',
      // NOT "display-end": familyForNode reads the words in a label, and a
      // receiver with "Display" in its name gets claimed by the projector /
      // display family and turned into a second PROJECTORDEVICE block.
      'Room-end DTP receiver',
      _frontWall.id,
      [
        _p(_dtpRxIn, 'DTP IN', SignalType.hdbaset, PortDirection.input),
        _p('hdmi', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('audio', 'AUDIO OUT', SignalType.analogAudio, PortDirection.output),
      ],
      pos: const Offset(440, 60),
      model: 'DTP HDMI 4K 230 Rx',
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
      'Display 1',
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
      'Control processor - IPCP Pro 255Q xi',
      _credenza.id,
      [
        _p('lan', 'LAN', SignalType.network, PortDirection.bidirectional),
        // The catalog's own ids, so re-picking the model later does not
        // orphan the lead to the display. The 255Q has proper COM ports where
        // the PCS1 had one combined IR/serial socket.
        _p('com1', 'COM1', SignalType.serial, PortDirection.output),
      ],
      pos: const Offset(440, 600),
      model: 'IPCP Pro 255Q xi',
      power: PowerInput.poe,
    ),
    _device(
      'AVNODE_9',
      'Power - SurgeX DisplayPak+',
      _credenza.id,
      [
        _p('out_pwr_1', 'OUTLET 1', SignalType.power, PortDirection.output),
        _p('out_pwr_2', 'OUTLET 2', SignalType.power, PortDirection.output),
      ],
      pos: const Offset(840, 840),
      model: 'SX-DPP-102',
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
    // The wireless feed crosses the room on one twisted pair: VIA into the
    // transmitter in the credenza, receiver at the display end into the bar.
    _cable('C1', 'WIRELESSDEVICE_1', 'out_hdmi_1', 'AVNODE_1', 'hdmi',
        SignalType.hdmi, label: 'AV-01'),
    _cable('C2', 'AVNODE_1', _dtpTxOut, 'AVNODE_6', _dtpRxIn,
        SignalType.hdbaset, label: 'AV-02'),
    _cable('C3', 'AVNODE_6', 'hdmi', 'AVNODE_3', 'in_hdmi_1', SignalType.hdmi,
        label: 'AV-03'),
    _cable('C4', 'AVNODE_3', 'out_hdmi_1', 'PROJECTORDEVICE_1', 'in_hdmi_1',
        SignalType.hdmi, label: 'AV-04'),
    _cable('C5', 'AVNODE_2', 'out_hdmi_1', 'PROJECTORDEVICE_1', 'in_hdmi_2',
        SignalType.hdmi, label: 'AV-05'),
    // The whole control system: one serial lead to the display. The panel and
    // the bar take their PoE drops from the building switch, which this room
    // does not own and this preset therefore does not draw.
    _cable('C6', 'AVNODE_4', 'com1', 'PROJECTORDEVICE_1', 'in_ctrl_1',
        SignalType.serial, label: 'CTL-01'),
    // Mains. Two outlets is the whole PDU: the display on one, the processor
    // and the bar sharing the other through the credenza's own strip. There
    // is nothing to switch remotely — it conditions the power and that is
    // all — so it is a box on the drawing and a line on the estimate, and
    // nothing on the control side.
    _cable('C7', 'AVNODE_9', 'out_pwr_1', 'PROJECTORDEVICE_1', 'in_power',
        SignalType.power, label: 'PWR-01'),
    _cable('C8', 'AVNODE_9', 'out_pwr_2', 'AVNODE_3', 'in_power',
        SignalType.power, label: 'PWR-02'),
  ],
);

// ---------------------------------------------------------------------------
//  4. ACTIVE LEARNING
// ---------------------------------------------------------------------------

/// An active sharing room with seven displays, every one of them fed from the
/// room's own matrix.
///
/// This used to be a NAV room: each station was an encoder input and a decoder
/// output on a NAVigator, and the panels hung off an AV LAN. It is now built
/// the way the rest of the estate is — a DTP CrossPoint 108 with a twisted
/// pair to every screen — which costs the room its AV-over-IP flexibility and
/// buys back a room where every box has a driver and every run is a cable
/// somebody can trace.
///
/// HOW A SCREEN IS FED depends on which kind of output it comes off, and the
/// matrix has both kinds:
///
///   * a DTP output is twisted pair already, so it runs straight to a receiver
///     behind the panel — or straight into a projector, which has an HDBaseT
///     socket of its own and needs no box at all;
///   * an HDMI output is not, so it goes into a transmitter in the rack first
///     and comes out of a receiver at the far end.
///
/// That is the whole rule, and it is why this preset carries five
/// transmitters and seven receivers: they are real boxes, in real rack units,
/// at real money, and a drawing that ran HDMI two hundred feet to a student
/// table would be quoting a room that cannot be built.
RoomPreset _activeLearningSpace() {
  const stations = 7;

  /// Stations 1 and 2 come off the matrix's two spare DTP outputs. The other
  /// five come off HDMI outputs and need a transmitter each.
  const stationsOnDtp = 2;

  final nodes = <AvNode>[
    _device(
      'AVNODE_1',
      'Instructor PC',
      _lectern.id,
      [
        _p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p(_pcUsbIn, 'USB', SignalType.usbData, PortDirection.input),
      ],
      pos: const Offset(40, 60),
      model: 'PC',
    ),
    // A source and nothing else — no config block, no driver, no line on the
    // control schematic. It is on the drawing because a lead runs from it and
    // on the estimate because somebody buys it, exactly like input_pc.
    _device(
      'AVNODE_2',
      'Document camera',
      _lectern.id,
      [
        _p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p(_docCamUsbOut, 'USB OUT', SignalType.usbData,
            PortDirection.output),
      ],
      pos: const Offset(40, 240),
      model: 'Document Camera',
    ),
    _device(
      'AVNODE_3',
      'Laptop at the lectern',
      _lectern.id,
      [
        _p('out_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        // Where the room hands over its camera and microphone: the Toggle's
        // output lands here, so a call on the instructor's own laptop uses
        // the room rather than the lid camera.
        _p('in_usb_1', 'USB', SignalType.usbData, PortDirection.input),
      ],
      pos: const Offset(40, 420),
      model: 'HDMI Laptop',
      power: PowerInput.none,
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
      pos: const Offset(40, 620),
      model: 'VIA GO',
    ),
    _device(
      'CAMERADEVICE_1',
      'Camera 1 - Instructor TR211',
      _rearWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('out_usb_1', 'USB', SignalType.usbData, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 820),
      model: 'TR211',
    ),
    _device(
      'CAMERADEVICE_2',
      'Camera 2 - Audience Cam570',
      _frontWall.id,
      [
        _p('out_hdmi_1', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        _p('out_usb_1', 'USB', SignalType.usbData, PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(40, 1020),
      model: 'Cam570',
    ),
    _device(
      'AVNODE_5',
      'Ceiling mic array',
      _ceiling.id,
      [_p('out_mic_1', 'MIC OUT', SignalType.micLine, PortDirection.output)],
      pos: const Offset(40, 1220),
    ),
    // --- the rack --------------------------------------------------------
    _device(
      'SWITCHERDEVICE_1',
      'Switcher - DTP CrossPoint 108 4K IPCP MA 70',
      _rackLocation.id,
      [
        _p('hdmi_001', 'HDMI 001', SignalType.hdmi, PortDirection.input),
        _p('hdmi_002', 'HDMI 002', SignalType.hdmi, PortDirection.input),
        _p('hdmi_003', 'HDMI 003', SignalType.hdmi, PortDirection.input),
        _p('hdmi_004', 'HDMI 004', SignalType.hdmi, PortDirection.input),
        _p('hdmi_005', 'HDMI 005', SignalType.hdmi, PortDirection.input),
        _p('hdmi_006', 'HDMI 006', SignalType.hdmi, PortDirection.input),
        // Where the two cameras' pairs land.
        _p('dtp_in_007', 'DTP IN 007', SignalType.hdbaset,
            PortDirection.input),
        _p('dtp_in_008', 'DTP IN 008', SignalType.hdbaset,
            PortDirection.input),
        // Capture out, then the five HDMI outputs the student panels come off.
        _p('hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.output),
        _p('hdmi_2', 'HDMI 2', SignalType.hdmi, PortDirection.output),
        _p('hdmi_3', 'HDMI 3', SignalType.hdmi, PortDirection.output),
        _p('hdmi_4', 'HDMI 4', SignalType.hdmi, PortDirection.output),
        _p('hdmi_5', 'HDMI 5', SignalType.hdmi, PortDirection.output),
        _p('hdmi_6', 'HDMI 6', SignalType.hdmi, PortDirection.output),
        // Twisted pair already: the two projectors and the two student panels
        // near enough to reach.
        _p('dtp_out_1', 'DTP OUT 1', SignalType.hdbaset, PortDirection.output),
        _p('dtp_out_2', 'DTP OUT 2', SignalType.hdbaset, PortDirection.output),
        _p('dtp_out_3', 'DTP OUT 3', SignalType.hdbaset, PortDirection.output),
        _p('dtp_out_4', 'DTP OUT 4', SignalType.hdbaset, PortDirection.output),
        _p('audio_1_2', 'AUDIO 1', SignalType.analogAudio,
            PortDirection.output),
        _p('dmp_exp', 'DMP EXP', SignalType.network, PortDirection.output),
        _p('lan', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(500, 240),
      rackUnits: 3,
      model: 'DTP CrossPoint 108 4K IPCP MA 70',
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
        _p(_dmpExpIn, 'DMP EXP', SignalType.dante, PortDirection.input),
        _p(_dmpUsbOut, 'USB OUT', SignalType.usbData, PortDirection.output),
      ],
      pos: const Offset(500, 900),
      rackUnits: 1,
      model: 'DMP 64 Plus C AT',
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
        _p(_avBridgeUsbOut, 'USB OUT', SignalType.usbData,
            PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(500, 1120),
      rackUnits: 1,
      model: 'AV Bridge 2x1',
    ),
    _device(
      'USBDEVICE_1',
      'USB Switcher - Toggle',
      _rackLocation.id,
      [
        _p('in_usb_1', 'USB DEVICE 1', SignalType.usbData,
            PortDirection.input),
        _p('in_usb_2', 'USB DEVICE 2', SignalType.usbData,
            PortDirection.input),
        _p('in_usb_3', 'USB DEVICE 3', SignalType.usbData,
            PortDirection.input),
        _p('out_usb_1', 'USB HOST 1', SignalType.usbData,
            PortDirection.output),
        _p('out_usb_2', 'USB HOST 2', SignalType.usbData,
            PortDirection.output),
        _p('in_ctrl_1', 'RS-232', SignalType.serial, PortDirection.input),
      ],
      pos: const Offset(500, 1340),
      model: 'Toggle',
    ),
    _device(
      'POWERDEVICE_1',
      'Power Controller - APC AP7921B',
      _rackLocation.id,
      [
        for (int i = 1; i <= 8; i++)
          _p('out_pwr_$i', 'OUTLET $i', SignalType.power,
              PortDirection.output),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(500, 1560),
      rackUnits: 1,
      model: 'AP7921B',
    ),
    // The control drops. Not an AV LAN any more — no streams cross it — but
    // every panel, camera and box in this room is reached over the network,
    // so the switch is still a real purchase and a real rack unit.
    _device(
      'AVNODE_6',
      // NOT "network switch": familyForNode reads an unmodelled box's label
      // as words, and the screen family's own label is "Screens
      // (Relays/Network)", so the word network files this under Screens.
      'Control LAN switch',
      _rackLocation.id,
      [
        _p('uplink', 'UPLINK', SignalType.network, PortDirection.input),
        for (int i = 1; i <= stations; i++)
          _p('lan_$i', 'PORT $i', SignalType.network, PortDirection.output),
      ],
      pos: const Offset(500, 1780),
      rackUnits: 1,
    ),
    // --- the extenders ---------------------------------------------------
    // The cameras first: both are at the far end of the room from the rack,
    // and both have an HDMI socket and nothing else, so both cross it on
    // twisted pair with a transmitter beside them.
    _device(
      'AVNODE_11',
      'DTP transmitter — instructor',
      _rearWall.id,
      [
        _p('hdmi', 'HDMI', SignalType.hdmi, PortDirection.input),
        _p(_dtpTxOut, 'DTP', SignalType.hdbaset, PortDirection.output),
      ],
      pos: const Offset(960, 1560),
      model: 'DTP HDMI 4K 230 Tx',
    ),
    _device(
      'AVNODE_12',
      'DTP transmitter — audience',
      _frontWall.id,
      [
        _p('hdmi', 'HDMI', SignalType.hdmi, PortDirection.input),
        _p(_dtpTxOut, 'DTP', SignalType.hdbaset, PortDirection.output),
      ],
      pos: const Offset(960, 1760),
      model: 'DTP HDMI 4K 230 Tx',
    ),
    // One transmitter per HDMI output that has to cross the room.
    for (int i = stationsOnDtp + 1; i <= stations; i++)
      _device(
        'AVNODE_${20 + i}',
        // Numbered for the student table it feeds. NOT "station $i": an
        // unmodelled box is filed by the words in its label, and the word
        // station would make each of these a STATIONDEVICE block.
        'DTP transmitter $i',
        _rackLocation.id,
        [
          _p('hdmi', 'HDMI', SignalType.hdmi, PortDirection.input),
          _p(_dtpTxOut, 'DTP', SignalType.hdbaset, PortDirection.output),
        ],
        pos: Offset(960, 60 + (i - stationsOnDtp - 1) * 200),
        model: 'DTP HDMI 4K 230 Tx',
      ),
    // And one receiver behind every panel, however the pair got there.
    for (int i = 1; i <= stations; i++)
      _device(
        'AVNODE_${30 + i}',
        'DTP receiver $i',
        _studentTable.id,
        [
          _p(_dtpRxIn, 'DTP IN', SignalType.hdbaset, PortDirection.input),
          _p('hdmi', 'HDMI OUT', SignalType.hdmi, PortDirection.output),
        ],
        pos: Offset(1420, 60 + (i - 1) * 200),
        model: 'DTP HDMI 4K 230 Rx',
      ),
    // --- the front of the room -------------------------------------------
    _device(
      'PROJECTORDEVICE_1',
      'Projector 1 - PowerLite L630U',
      _frontWall.id,
      [
        _p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        _p('in_hdbt_1', 'HDBaseT', SignalType.hdbaset, PortDirection.input),
        _p('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
      pos: const Offset(1880, 60),
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
      pos: const Offset(1880, 300),
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
      pos: const Offset(1880, 540),
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
      pos: const Offset(1880, 780),
      model: 'Controller',
    ),
    // Off the AV Bridge's loop-through rather than a matrix output: the
    // instructor's monitor should show what is going out on the call, and
    // that is exactly what the capture box is passing on. It also leaves a
    // matrix output free for a student panel, which is the scarce thing here.
    _device(
      'AVNODE_7',
      'Confidence monitor',
      _lectern.id,
      [_p('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input)],
      pos: const Offset(1880, 1020),
    ),
    _device(
      'AVNODE_8',
      'Ceiling speakers',
      _ceiling.id,
      [_p('in_spk_1', 'SPEAKER IN', SignalType.speaker, PortDirection.input)],
      pos: const Offset(1880, 1240),
      power: PowerInput.none,
    ),
    // One student station: a Newline panel the student plugs into directly.
    // STATIONDEVICE_n is the config block the share page drives.
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
        pos: Offset(2340, 60 + (i - 1) * 200),
        model: 'TT-7523Q',
      ),
  ];

  return RoomPreset(
    name: 'Active learning',
    description:
        'An active sharing room with seven displays, each on its own twisted '
        'pair from a DTP CrossPoint 108, two Epson projectors, two DaLite '
        'screens, a DMP 64 and an AV Bridge 2x1. Every box in it has a '
        'driver.',
    builtIn: true,
    jackPrefix: kPresetJackPrefix,
    // Read off the cabling below. The station feeds have no SYSTEM_SETUP key
    // of their own — the schema has input_station_n but no output for one —
    // so which matrix output a panel is on is stated by the drawing and the
    // cable schedule rather than here.
    systemSetup: const {
      'input_pc': '1',
      'input_hdmi': '2',
      'input_wireless': '3',
      'input_doc_cam': '4',
      // DTP IN 007 and 008: both cameras come in on twisted pair.
      'input_inst_cam': '7',
      'input_aud_cam': '8',
      'input_usb': '',
      'input_pc_extended': '',
      // Outputs 5 and 6 of a CrossPoint 108 carry both connectors, and it is
      // the DTP one — the B — that runs to each projector's own HDBaseT
      // socket. (Outputs 1-4 are HDMI only, 7 and 8 DTP only.)
      'output_proj_1': '5B',
      'output_proj_2': '6B',
      // The capture feed, off output 1's HDMI connector into the AV Bridge.
      'output_cc': '1',
      'output_cc2': '',
      // The confidence monitor hangs off the AV Bridge's loop-through, not
      // off the matrix, so there is no output for the processor to route.
      'output_monitor_1': '',
      'output_audio': '1',
      'output_audio_ald': '',
      'gui_inputs': '4',
      'gui_tab_type': 'DOC_WL',
      'gui_routing_mode': 'Normal',
      // Nine screens that can show different things, and a capture feed the
      // instructor picks a source for — both routing pages earn their place.
      'gui_routing_available': 'Yes',
      'gui_capture_source_available': 'Yes',
      'gui_mic_mix': 'Ceiling',
      // Both screen controllers are on the network.
      'dev_screen_control': 'Network',
    },
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
      // --- sources in ----------------------------------------------------
      _cable('C1', 'AVNODE_1', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_001',
          SignalType.hdmi, label: 'AV-01'),
      _cable('C2', 'AVNODE_3', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_002',
          SignalType.hdmi, label: 'AV-02'),
      _cable('C3', 'WIRELESSDEVICE_1', 'out_hdmi_1', 'SWITCHERDEVICE_1',
          'hdmi_003', SignalType.hdmi, label: 'AV-03'),
      _cable('C4', 'AVNODE_2', 'out_1', 'SWITCHERDEVICE_1', 'hdmi_004',
          SignalType.hdmi, label: 'AV-04'),
      _cable('C5', 'CAMERADEVICE_1', 'out_hdmi_1', 'AVNODE_11', 'hdmi',
          SignalType.hdmi, label: 'AV-05'),
      _cable('C5B', 'AVNODE_11', _dtpTxOut, 'SWITCHERDEVICE_1', 'dtp_in_007',
          SignalType.hdbaset, label: 'AV-05B'),
      _cable('C6', 'CAMERADEVICE_2', 'out_hdmi_1', 'AVNODE_12', 'hdmi',
          SignalType.hdmi, label: 'AV-06'),
      _cable('C6B', 'AVNODE_12', _dtpTxOut, 'SWITCHERDEVICE_1', 'dtp_in_008',
          SignalType.hdbaset, label: 'AV-06B'),
      // --- the two projectors: DTP straight into HDBaseT -----------------
      _cable('C7', 'SWITCHERDEVICE_1', 'dtp_out_1', 'PROJECTORDEVICE_1',
          'in_hdbt_1', SignalType.hdbaset, label: 'AV-07'),
      _cable('C8', 'SWITCHERDEVICE_1', 'dtp_out_2', 'PROJECTORDEVICE_2',
          'in_hdbt_1', SignalType.hdbaset, label: 'AV-08'),
      // --- capture, and the monitor off its loop-through -----------------
      _cable('C9', 'SWITCHERDEVICE_1', 'hdmi_1', 'RECORDERDEVICE_1',
          'in_hdmi_1', SignalType.hdmi, label: 'AV-09'),
      _cable('C10', 'RECORDERDEVICE_1', 'out_hdmi_1', 'AVNODE_7', 'in_hdmi_1',
          SignalType.hdmi, label: 'AV-10'),
      // --- USB: the room's camera and mic, into the lectern laptop -------
      _cable('C11', 'DSPDEVICE_1', _dmpUsbOut, 'USBDEVICE_1', 'in_usb_1',
          SignalType.usbData, label: 'USB-01'),
      _cable('C11B', 'RECORDERDEVICE_1', _avBridgeUsbOut, 'USBDEVICE_1',
          'in_usb_2', SignalType.usbData, label: 'USB-02'),
      _cable('C12', 'AVNODE_2', _docCamUsbOut, 'USBDEVICE_1', 'in_usb_3',
          SignalType.usbData, label: 'USB-03'),
      _cable('C13', 'USBDEVICE_1', 'out_usb_1', 'AVNODE_1', _pcUsbIn,
          SignalType.usbData, label: 'USB-04'),
      _cable('C13B', 'USBDEVICE_1', 'out_usb_2', 'AVNODE_3', 'in_usb_1',
          SignalType.usbData, label: 'USB-05'),
      // --- audio ---------------------------------------------------------
      _cable('C14', 'AVNODE_5', 'out_mic_1', 'DSPDEVICE_1', 'mic_line_1',
          SignalType.micLine, label: 'AUD-01'),
      _cable('C15', 'SWITCHERDEVICE_1', 'audio_1_2', 'DSPDEVICE_1', 'acp',
          SignalType.analogAudio, label: 'AUD-02'),
      _cable('C16', 'DSPDEVICE_1', 'audio_1', 'AVNODE_8', 'in_spk_1',
          SignalType.speaker, label: 'SPK-01'),
      _cable('C17', 'DSPDEVICE_1', 'audio_2', 'RECORDERDEVICE_1', 'in_aud_1',
          SignalType.analogAudio, label: 'AUD-03'),
      // The matrix and the DSP on the expansion bus, which is the one link
      // that only ever goes between those two sockets.
      _cable('C18', 'SWITCHERDEVICE_1', 'dmp_exp', 'DSPDEVICE_1', _dmpExpIn,
          SignalType.network, label: 'AUD-04'),
      // --- the student panels --------------------------------------------
      // Stations 1 and 2 are on the spare DTP outputs: one pair each, straight
      // to the receiver behind the panel.
      for (int i = 1; i <= stationsOnDtp; i++) ...[
        _cable('CD$i', 'SWITCHERDEVICE_1', 'dtp_out_${i + 2}',
            'AVNODE_${30 + i}', _dtpRxIn, SignalType.hdbaset,
            label: 'AV-${(10 + i).toString().padLeft(2, '0')}'),
        _cable('CR$i', 'AVNODE_${30 + i}', 'hdmi', 'STATIONDEVICE_$i',
            'in_hdmi_1', SignalType.hdmi,
            label: 'AV-${(20 + i).toString().padLeft(2, '0')}'),
      ],
      // The rest come off HDMI outputs, so each one is a transmitter in the
      // rack, a pair across the room, and a receiver behind the panel.
      for (int i = stationsOnDtp + 1; i <= stations; i++) ...[
        _cable('CT$i', 'SWITCHERDEVICE_1', 'hdmi_${i - stationsOnDtp + 1}',
            'AVNODE_${20 + i}', 'hdmi', SignalType.hdmi,
            label: 'AV-${(10 + i).toString().padLeft(2, '0')}'),
        _cable('CD$i', 'AVNODE_${20 + i}', _dtpTxOut, 'AVNODE_${30 + i}',
            _dtpRxIn, SignalType.hdbaset,
            label: 'AV-${(20 + i).toString().padLeft(2, '0')}'),
        _cable('CR$i', 'AVNODE_${30 + i}', 'hdmi', 'STATIONDEVICE_$i',
            'in_hdmi_1', SignalType.hdmi,
            label: 'AV-${(30 + i).toString().padLeft(2, '0')}'),
      ],
      // --- control drops --------------------------------------------------
      _cable('CN0', 'SWITCHERDEVICE_1', 'lan', 'AVNODE_6', 'uplink',
          SignalType.network, label: 'NET-01'),
      for (int i = 1; i <= stations; i++)
        _cable('CN$i', 'AVNODE_6', 'lan_$i', 'STATIONDEVICE_$i', 'lan_1',
            SignalType.network,
            label: 'NET-${(i + 1).toString().padLeft(2, '0')}'),
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
      'DSPDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 6),
      'RECORDERDEVICE_1': RackSlot(rackId: 'RACK_1', startU: 7),
      'AVNODE_6': RackSlot(rackId: 'RACK_1', startU: 9),
    },
    floorPlans: [
      _blankSheet(const {
        'LOC_1': _planLectern,
        'LOC_2': _planFrontWall,
        'LOC_3': _planCeiling,
        'LOC_4': _planRack,
        'LOC_5': _planStudentTable,
        'LOC_6': _planRearWall,
      }),
    ],
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
