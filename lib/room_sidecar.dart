import 'package:path/path.dart' as path;

/// ============================================================================
///  THE ROOM'S DOCUMENT, ACROSS SEVERAL FILES
/// ============================================================================
///  Everything the app knows about a room that is not in the config itself —
///  the signal flow, the rack elevations, the floor plans, the low-voltage
///  cabling, the cost estimate — used to live in one `<config>_av_flow.json`.
///
///  One file was fine while it held one drawing. It is not fine now: a room
///  carries five separate documents that different people work on at different
///  times, and putting them in one file means a merge conflict in the cabling
///  is a merge conflict in the quote, a hand-edit to fix a floor plan risks the
///  rack elevation, and "send me the cost estimate" means sending all of it.
///
///  So the document is written in PARTS, one file each, named for what they
///  hold. Nothing about the in-memory shape changes: [split] takes the single
///  combined map the app already builds and files each top-level key under the
///  part that owns it, and [merge] puts them back. The app's reader and writer
///  never learn there is more than one file.
///
///  READING IS BACKWARD COMPATIBLE BY CONSTRUCTION. An older room has one file
///  holding every key and no companions; merging a lone combined document with
///  nothing to overlay yields exactly that document. Nothing has to detect a
///  version, and a room saved before this existed opens with no migration step.
/// ============================================================================

/// One file of the room's document.
enum RoomSidecarPart {
  /// The signal flow diagram — devices, their connectors, the cables between
  /// them, and how the canvas is coloured. Keeps the historic file name, so
  /// this is also the file an older room's whole document is found in.
  flow,

  /// Rack elevations: the frames, the plates and shelves in them, and what is
  /// racked where.
  racks,

  /// Floor plan sheets with their callouts, and the named places in the room
  /// the callouts point at.
  floorPlans,

  /// Low-voltage runs that are not signal flow — screen switches today, the
  /// cabling schematic next to them.
  cabling,

  /// The estimate: tax, fees, labor, quoted prices.
  cost,
}

/// File suffix for each part: `<config base>_<suffix>.json`.
const Map<RoomSidecarPart, String> kRoomSidecarSuffix = {
  RoomSidecarPart.flow: 'av_flow',
  RoomSidecarPart.racks: 'racks',
  RoomSidecarPart.floorPlans: 'floor_plans',
  RoomSidecarPart.cabling: 'cabling',
  RoomSidecarPart.cost: 'cost',
};

/// Which top-level keys of the combined document each part owns.
///
/// Every key the app writes must appear exactly once here or it would be
/// dropped on the next save — which is what [kRoomSidecarOwnedKeys] and the
/// test over it are for.
const Map<RoomSidecarPart, List<String>> kRoomSidecarKeys = {
  RoomSidecarPart.flow: [
    'nodes',
    'cables',
    'dismissedDevices',
    'signalColors',
    'roomMode',
  ],
  RoomSidecarPart.racks: ['racks', 'rackItems', 'rackSlots'],
  // The locations travel with the plans: a callout is a marker on a sheet
  // pointing at one of them, and a plan whose places had gone would be a sheet
  // of unlabelled dots.
  RoomSidecarPart.floorPlans: ['floorPlans', 'locations'],
  RoomSidecarPart.cabling: ['screenSwitches', 'cablingSchematic'],
  RoomSidecarPart.cost: ['cost'],
};

/// Every key that belongs to some part.
Set<String> get kRoomSidecarOwnedKeys => {
  for (final keys in kRoomSidecarKeys.values) ...keys,
};

const Map<RoomSidecarPart, String> _kReadme = {
  RoomSidecarPart.flow:
      'Signal flow for the Room Config Builder: the devices in this room with '
          'their connectors, the cables between them, and the colours the '
          'diagram is drawn in. The rest of the room is in the files beside '
          'this one.',
  RoomSidecarPart.racks:
      'Rack elevations: the frames in this room, the plates, shelves and '
          'drawers in them, and which rail each device and part sits on.',
  RoomSidecarPart.floorPlans:
      'Floor plan sheets for this room with their callouts, and the named '
          'places in the room those callouts point at.',
  RoomSidecarPart.cabling:
      'Low-voltage cabling that is not on the signal flow: screen and shade '
          'switches, and the runs between them.',
  RoomSidecarPart.cost:
      'This room\'s cost estimate: tax, fees, labor, quoted prices and the '
          'lines added by hand. The rates and base costs it draws on are '
          'shared files in the Root Folder, not here.',
};

/// `<dir>/<config base>_<suffix>.json` for [part], or '' with no config file.
String roomSidecarPath(String configPath, RoomSidecarPart part) {
  if (configPath.isEmpty) return '';
  return path.join(
    path.dirname(configPath),
    '${path.basenameWithoutExtension(configPath)}'
        '_${kRoomSidecarSuffix[part]}.json',
  );
}

/// Every part's path, for a caller that has to write or scan all of them.
Map<RoomSidecarPart, String> roomSidecarPaths(String configPath) => {
  for (final part in RoomSidecarPart.values)
    part: roomSidecarPath(configPath, part),
};

/// Files the combined document breaks into.
///
/// A key nobody owns stays with [RoomSidecarPart.flow] rather than being
/// dropped: an unrecognised key is far more likely to be something a later
/// build added than something safe to throw away, and the flow file is the one
/// a reader always looks at.
Map<RoomSidecarPart, Map<String, dynamic>> splitRoomSidecar(
  Map<String, dynamic> combined,
) {
  final owner = <String, RoomSidecarPart>{
    for (final entry in kRoomSidecarKeys.entries)
      for (final key in entry.value) key: entry.key,
  };

  final out = {
    for (final part in RoomSidecarPart.values)
      part: <String, dynamic>{'__readme': _kReadme[part]!},
  };

  combined.forEach((key, value) {
    if (key == '__readme') return;
    out[owner[key] ?? RoomSidecarPart.flow]![key] = value;
  });
  return out;
}

/// Puts the parts back into the one document the app reads.
///
/// [parts] may be missing entries — a room with no floor plans has no floor
/// plan file — and the flow part may be an OLD combined document holding every
/// key. Both work: the flow part goes down first and the companions overlay
/// it, so a companion always wins over a stale copy of the same key, and a
/// lone combined document comes back untouched.
Map<String, dynamic> mergeRoomSidecar(
  Map<RoomSidecarPart, Map<String, dynamic>?> parts,
) {
  final out = <String, dynamic>{};
  void take(Map<String, dynamic>? doc) {
    if (doc == null) return;
    doc.forEach((key, value) {
      if (key == '__readme') return;
      out[key] = value;
    });
  }

  take(parts[RoomSidecarPart.flow]);
  for (final part in RoomSidecarPart.values) {
    if (part == RoomSidecarPart.flow) continue;
    take(parts[part]);
  }
  return out;
}
