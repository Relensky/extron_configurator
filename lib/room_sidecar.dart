import 'dart:io';

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
  /// them, and how the canvas is colored. Keeps the historic file name, so
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

  /// Who changed what in this room, and when.
  ///
  /// Its own file for the same reason the estimate has one: it is written on
  /// every edit and read by nobody most of the time, and a log appended to the
  /// same file as the drawing would make every save of the drawing a rewrite
  /// of the log — which is exactly the file you do not want to lose to a
  /// half-finished write.
  history,
}

/// File suffix for each part: `<config base>_<suffix>.json`.
const Map<RoomSidecarPart, String> kRoomSidecarSuffix = {
  RoomSidecarPart.flow: 'av_flow',
  RoomSidecarPart.racks: 'racks',
  RoomSidecarPart.floorPlans: 'floor_plans',
  RoomSidecarPart.cabling: 'cabling',
  RoomSidecarPart.cost: 'cost',
  RoomSidecarPart.history: 'history',
};

/// What to call each part where a PERSON reads it: the job history, a message
/// about what was saved. The suffix above is the file name; this is the name.
const Map<RoomSidecarPart, String> kRoomSidecarFileLabels = {
  RoomSidecarPart.flow: 'AV flow',
  RoomSidecarPart.racks: 'Racks',
  RoomSidecarPart.floorPlans: 'Floor plans',
  RoomSidecarPart.cabling: 'Cabling',
  RoomSidecarPart.cost: 'Cost',
  RoomSidecarPart.history: 'History',
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
    'dismissedCables',
    'signalColors',
    'roomMode',
    // The backdrop belongs to the signal flow canvas, not to the floor plans:
    // it is whatever picture somebody wanted behind THIS drawing.
    'flowBackground',
  ],
  RoomSidecarPart.racks: ['racks', 'rackItems', 'rackSlots'],
  // The locations travel with the plans: a callout is a marker on a sheet
  // pointing at one of them, and a plan whose places had gone would be a sheet
  // of unlabeled dots.
  RoomSidecarPart.floorPlans: ['floorPlans', 'locations'],
  RoomSidecarPart.cabling: ['screenSwitches', 'cablingSchematic'],
  RoomSidecarPart.cost: ['cost'],
  RoomSidecarPart.history: ['roomHistory'],
};

/// Every key that belongs to some part.
Set<String> get kRoomSidecarOwnedKeys => {
  for (final keys in kRoomSidecarKeys.values) ...keys,
};

// ---------------------------------------------------------------------------
//  THE SAME PARTITION, USED FOR UNDO
// ---------------------------------------------------------------------------

/// Which tab's history an edit belongs to.
///
/// One per page that offers an Undo button. The estimate was absent for a long
/// time because nothing on the Cost tab recorded an entry — and a scope no edit
/// is ever filed under is a button that is always gray. It is here now, and
/// every method that touches [RoomCostSettings] files against it: a price typed
/// over a catalog figure, a fee, a line added by hand, a whole quote re-sorted.
/// Those are among the most retyped edits in the app and were the least
/// recoverable.
enum AvUndoScope { flow, racks, floorPlans, cabling, cost }

const Map<AvUndoScope, String> kAvUndoScopeLabels = {
  AvUndoScope.flow: 'AV Flow',
  AvUndoScope.racks: 'Racks',
  AvUndoScope.floorPlans: 'Floor Plan',
  AvUndoScope.cabling: 'Cabling',
  AvUndoScope.cost: 'Cost',
};

/// The part of the document each scope owns.
///
/// Deliberately the SAME division the room is written to disk with, rather
/// than a second opinion about what belongs with what. Two consequences worth
/// stating: a scope's keys are disjoint from every other scope's, so undoing
/// on one tab cannot disturb another; and the test that every written key
/// belongs to exactly one part keeps this honest too, so a field added later
/// cannot quietly fall outside every history.
const Map<AvUndoScope, RoomSidecarPart> kAvUndoScopePart = {
  AvUndoScope.flow: RoomSidecarPart.flow,
  AvUndoScope.racks: RoomSidecarPart.racks,
  AvUndoScope.floorPlans: RoomSidecarPart.floorPlans,
  AvUndoScope.cabling: RoomSidecarPart.cabling,
  AvUndoScope.cost: RoomSidecarPart.cost,
};

/// The top-level document keys [scope]'s history covers.
List<String> avUndoScopeKeys(AvUndoScope scope) =>
    kRoomSidecarKeys[kAvUndoScopePart[scope]!]!;

const Map<RoomSidecarPart, String> _kReadme = {
  RoomSidecarPart.flow:
      'Signal flow for the Room Config Builder: the devices in this room with '
          'their connectors, the cables between them, and the colors the '
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
  RoomSidecarPart.history:
      'Who changed what in this room, and when, under whichever Windows login '
          'they were signed in as. A log, not an undo - nothing here puts '
          'anything back.',
};

// ---------------------------------------------------------------------------
//  THE ROOM'S FOLDER
// ---------------------------------------------------------------------------
//  Only the config sits in the folder the rooms, projects and campuses share.
//  Everything else a room writes - its parts, the control schematic, the save
//  and conversion backups, the change log, imported pictures - lives in a
//  folder beside it named for the config: `BSS103.json` -> `BSS103\`.
//
//  Older rooms have those files loose beside the config. [moveRoomFilesIntoFolder]
//  moves them in when the room is opened, and the readers fall back to the
//  loose copies for a room that has not been opened since.
//
//  The current layout is a folder per room, named for the room, holding the
//  processor's `config.json` and a `room_files` folder for everything else:
//  `ARTS_111\config.json`, `ARTS_111\room_files\ARTS_111_av_flow.json`. A
//  room in the older `ARTS_111_config.json` shape is moved into it on open -
//  see [migrateRoomToFolderLayout].

/// The name the processor reads its config under.
const String kRoomConfigFileName = 'config.json';

/// The folder beside a `config.json` that holds the rest of the room.
const String kRoomFilesFolder = 'room_files';

/// True when [configPath] is a `config.json` in its own room folder.
bool isFolderLayoutConfig(String configPath) =>
    configPath.isNotEmpty &&
    path.basename(configPath).toLowerCase() == kRoomConfigFileName;

/// Folders of the processor's own layout that sit between a room's folder and
/// its `config.json`: `SCI248\code\upload_to_root\config.json`. They name a
/// place on the processor, not the room.
const Set<String> kProcessorLayoutFolders = {'upload_to_root', 'code'};

/// The room's name on disk: the folder for a `config.json`, else the file
/// name - `ARTS_111\config.json` and `ARTS_111_config.json` -> `ARTS_111` and
/// `ARTS_111_config`.
///
/// PAST THE PROCESSOR'S FOLDERS. In the layout the processor is loaded from,
/// `rooms\SCI248\code\upload_to_root\config.json`, the folder the config is
/// in is `upload_to_root` - and every room's files were named
/// `upload_to_root_av_flow.json`, `upload_to_root_cost.json`... So `code`
/// and `upload_to_root` are stepped over, and the room is `SCI248`.
String roomStem(String configPath) {
  if (configPath.isEmpty) return '';
  if (isFolderLayoutConfig(configPath)) {
    var dir = path.dirname(configPath);
    var folder = path.basename(dir);
    while (kProcessorLayoutFolders.contains(folder.toLowerCase())) {
      final up = path.dirname(dir);
      final name = path.basename(up);
      if (up == dir || name.isEmpty || name == '.') break;
      dir = up;
      folder = name;
    }
    if (folder.isNotEmpty &&
        folder != '.' &&
        !kProcessorLayoutFolders.contains(folder.toLowerCase())) {
      return folder;
    }
    final own = path.basename(path.dirname(configPath));
    if (own.isNotEmpty && own != '.') return own;
  }
  return path.basenameWithoutExtension(configPath);
}

/// What [roomStem] said before it stepped over the processor's folders -
/// the folder the config is in - when that differs. The files a room wrote
/// then are named for it.
String _formerRoomStem(String configPath) {
  if (!isFolderLayoutConfig(configPath)) return '';
  final own = path.basename(path.dirname(configPath));
  return own == roomStem(configPath) ? '' : own;
}

/// Where [roomFilePath] was while rooms in the processor's layout were named
/// for `upload_to_root` - or '' when this room's name never differed.
String formerRoomFilePath(String configPath, String suffix) {
  final former = _formerRoomStem(configPath);
  if (former.isEmpty) return '';
  return path.join(roomFolderPath(configPath), '${former}_$suffix');
}

/// Renames the room's files from the stem an older build named them for
/// (`upload_to_root_cost.json`) to the room's (`SCI248_cost.json`). A file
/// already under the new name wins and the old one is left. Returns the new
/// names. Called when a room is opened.
List<String> renameRoomFilesToStem(String configPath) {
  final old = _formerRoomStem(configPath);
  if (old.isEmpty) return const [];
  final folder = Directory(roomFolderPath(configPath));
  if (!folder.existsSync()) return const [];
  final stem = roomStem(configPath);
  final prefix = '${old.toLowerCase()}_';
  final companions = {for (final s in kRoomCompanionSuffixes) s.toLowerCase()};
  final renamed = <String>[];
  for (final entity in folder.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final name = path.basename(entity.path);
    final lower = name.toLowerCase();
    if (!lower.startsWith(prefix) ||
        !companions.contains(lower.substring(prefix.length))) {
      continue;
    }
    final target = '${stem}_${name.substring(prefix.length)}';
    try {
      if (_moveEntity(entity, path.join(folder.path, target))) {
        renamed.add(target);
      }
    } catch (_) {
      // Left under its old name; the readers still find it there.
    }
  }
  return renamed;
}

/// The file name to show for a room: `ARTS_111\config.json` for a
/// `config.json`, since every room has one, else the file name.
String roomConfigDisplayName(String configPath) {
  if (!isFolderLayoutConfig(configPath)) return path.basename(configPath);
  final folder = path.basename(path.dirname(configPath));
  if (folder.isEmpty || folder == '.') return path.basename(configPath);
  return path.join(folder, path.basename(configPath));
}

/// `<dir>\<name>\config.json` - where a room called [name] is saved in [dir].
String roomConfigPathIn(String dir, String name) =>
    path.join(dir, name, kRoomConfigFileName);

/// The folder-layout path for a room saved as [chosen]: a picked
/// `ARTS_111_config.json` becomes `ARTS_111\config.json` beside it, or the
/// `config.json` of the `ARTS_111` folder it was picked inside. A path that
/// already is a `config.json` is returned as it is.
String folderLayoutPathFor(String chosen) {
  if (chosen.isEmpty || isFolderLayoutConfig(chosen)) return chosen;
  final dir = path.dirname(chosen);
  final name = folderNameForLegacyRoom(chosen);
  if (path.basename(dir).toLowerCase() == name.toLowerCase()) {
    return path.join(dir, kRoomConfigFileName);
  }
  return roomConfigPathIn(dir, name);
}

/// `ARTS_111_config.json` -> `ARTS_111`: the file name without the
/// `_config` every saved room carries.
String folderNameForLegacyRoom(String configPath) {
  final stem = path.basenameWithoutExtension(configPath);
  final trimmed =
      stem.replaceAll(RegExp(r'[_\- ]?config$', caseSensitive: false), '');
  return trimmed.isEmpty ? stem : trimmed;
}

/// The folder a room's companion files live in, or '' with no config file:
/// `<room folder>\room_files` for a `config.json`, `<dir>\<config base>` for
/// an older room.
String roomFolderPath(String configPath) {
  if (configPath.isEmpty) return '';
  if (isFolderLayoutConfig(configPath)) {
    return path.join(path.dirname(configPath), kRoomFilesFolder);
  }
  return path.join(
    path.dirname(configPath),
    path.basenameWithoutExtension(configPath),
  );
}

/// Creates the room's folder when it is missing. Called before any write.
void ensureRoomFolder(String configPath) {
  final folder = roomFolderPath(configPath);
  if (folder.isEmpty) return;
  final dir = Directory(folder);
  if (!dir.existsSync()) dir.createSync(recursive: true);
}

/// `<room folder>/<config base>_<suffix>` - [suffix] carries its extension.
String roomFilePath(String configPath, String suffix) {
  if (configPath.isEmpty) return '';
  return path.join(
    roomFolderPath(configPath),
    '${roomStem(configPath)}_$suffix',
  );
}

/// Where [roomFilePath] was before rooms had folders: beside the config.
String legacyRoomFilePath(String configPath, String suffix) {
  if (configPath.isEmpty) return '';
  return path.join(
    path.dirname(configPath),
    '${roomStem(configPath)}_$suffix',
  );
}

/// [roomFilePath] when it exists, else the loose copy beside the config when
/// that exists, else ''. For readers that must not move anything.
String readableRoomFilePath(String configPath, String suffix) {
  final current = roomFilePath(configPath, suffix);
  if (current.isNotEmpty && File(current).existsSync()) return current;
  // Still under the name an older build gave it (`upload_to_root_...`) - a
  // file that could not be renamed, or one written since by a copy of the
  // app that has not been updated.
  final old = formerRoomFilePath(configPath, suffix);
  if (old.isNotEmpty && File(old).existsSync()) return old;
  final legacy = legacyRoomFilePath(configPath, suffix);
  if (legacy.isNotEmpty && File(legacy).existsSync()) return legacy;
  return '';
}

/// True when [dir] is a room's folder: a config of the same name sits beside
/// it, or it is the `room_files` beside a `config.json`. Folder scans for
/// rooms skip these - the backups in them look like rooms.
bool isRoomFolder(String dir) {
  final normal = path.normalize(dir);
  if (File('$normal.json').existsSync()) return true;
  return path.basename(normal).toLowerCase() == kRoomFilesFolder &&
      File(path.join(path.dirname(normal), kRoomConfigFileName)).existsSync();
}

/// Every companion a room names after its config, suffix and extension.
/// Pictures and the `_old_config.json` backup are named otherwise and moved
/// by their own callers.
List<String> get kRoomCompanionSuffixes => [
  for (final part in RoomSidecarPart.values) '${kRoomSidecarSuffix[part]}.json',
  // Pre-rename flow and schematic files.
  'avflow.json',
  'schematic.json',
  'control_schematic.json',
  'previous.json',
  'backup_log.txt',
];

/// Moves [file] into [folder] unless a file of that name is already there.
/// Returns true when it moved.
bool moveIntoRoomFolder(String file, String folder) {
  final f = File(file);
  if (!f.existsSync()) return false;
  final target = path.join(folder, path.basename(file));
  if (File(target).existsSync()) return false;
  Directory(folder).createSync(recursive: true);
  try {
    f.renameSync(target);
  } on FileSystemException {
    // Locked against a rename (a sync client): copy, then drop the original.
    f.copySync(target);
    try {
      f.deleteSync();
    } catch (_) {}
  }
  return true;
}

/// Moves an older room's loose companions from beside [configPath] into its
/// folder. A file already in the folder wins and the loose one is left alone.
/// Returns the names moved.
List<String> moveRoomFilesIntoFolder(String configPath) {
  if (configPath.isEmpty) return const [];
  final folder = roomFolderPath(configPath);
  final moved = <String>[];
  for (final suffix in kRoomCompanionSuffixes) {
    final loose = legacyRoomFilePath(configPath, suffix);
    try {
      if (moveIntoRoomFolder(loose, folder)) moved.add(path.basename(loose));
    } catch (_) {
      // Left where it is; the readers still find it there.
    }
  }
  return moved;
}

/// Pictures a room imported are named for it; these are the ones an older
/// build left loose beside the config.
const Set<String> _kRoomPictureExtensions = {
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.pdf', //
};

/// Moves [entity] to [target] unless something is already there. Returns
/// true when it moved.
bool _moveEntity(FileSystemEntity entity, String target) {
  if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
    return false;
  }
  try {
    entity.renameSync(target);
  } on FileSystemException {
    if (entity is! File) return false;
    // Locked against a rename (a sync client): copy, then drop the original.
    entity.copySync(target);
    try {
      entity.deleteSync();
    } catch (_) {}
  }
  return true;
}

/// Moves everything in [from] into [to], renaming the room's own parts from
/// [oldStem] to [newStem]. Pictures keep their names - the plans name them.
/// Anything that would land on an existing file is left where it is.
void _moveRoomFolderContents(
  Directory from,
  String to,
  String oldStem,
  String newStem,
) {
  if (!from.existsSync()) return;
  final prefix = '${oldStem.toLowerCase()}_';
  final companions = {for (final s in kRoomCompanionSuffixes) s.toLowerCase()};
  for (final entity in from.listSync(followLinks: false)) {
    // The destination itself when the old folder is the new room's folder.
    if (path.equals(entity.path, to)) continue;
    var name = path.basename(entity.path);
    final lower = name.toLowerCase();
    if (lower == kRoomConfigFileName) continue;
    if (lower.startsWith(prefix) &&
        companions.contains(lower.substring(prefix.length))) {
      name = '${newStem}_${name.substring(prefix.length)}';
    }
    try {
      _moveEntity(entity, path.join(to, name));
    } catch (_) {
      // Left behind; the room still opens without it.
    }
  }
}

/// Deletes [dir] when nothing is left in it.
void _deleteIfEmpty(Directory dir) {
  try {
    if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
  } catch (_) {}
}

/// Letters and digits only, for matching `ARTS111` to `ARTS_111`.
String _looseKey(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Moves a room saved as `<dir>\ARTS_111_config.json` into the folder layout:
/// the config becomes `<dir>\ARTS_111\config.json`, and its old folder, loose
/// companions, pictures and conversion backup go into `ARTS_111\room_files`,
/// the parts renamed for the new stem.
///
/// Returns the new config path, or '' when nothing moved: the room is already
/// in the layout, or a `config.json` is already where it would go.
String migrateRoomToFolderLayout(String configPath) {
  if (configPath.isEmpty || isFolderLayoutConfig(configPath)) return '';
  final config = File(configPath);
  if (!config.existsSync()) return '';
  final dir = path.dirname(configPath);
  final oldStem = path.basenameWithoutExtension(configPath);
  final newStem = folderNameForLegacyRoom(configPath);
  final target = roomConfigPathIn(dir, newStem);
  if (File(target).existsSync()) return '';

  // Loose companions join the old folder first, so they move with the rest.
  moveRoomFilesIntoFolder(configPath);
  final oldFolder = Directory(roomFolderPath(configPath));
  final newFolder = roomFolderPath(target);
  Directory(newFolder).createSync(recursive: true);
  _moveRoomFolderContents(oldFolder, newFolder, oldStem, newStem);

  // Pictures and the conversion backup an older build left beside the config.
  final prefix = '${oldStem.toLowerCase()}_';
  final roomKey = _looseKey(newStem);
  for (final entity in Directory(dir).listSync(followLinks: false)) {
    if (entity is! File) continue;
    final lower = path.basename(entity.path).toLowerCase();
    final picture = lower.startsWith(prefix) &&
        _kRoomPictureExtensions.contains(path.extension(lower));
    final backup = lower.endsWith('_old_config.json') &&
        _looseKey(lower.substring(
                0, lower.length - '_old_config.json'.length)) ==
            roomKey;
    if (!picture && !backup) continue;
    try {
      _moveEntity(entity, path.join(newFolder, path.basename(entity.path)));
    } catch (_) {}
  }

  if (!_moveEntity(config, target)) return '';
  if (!path.equals(oldFolder.path, path.dirname(target))) {
    _deleteIfEmpty(oldFolder);
  }
  return target;
}

/// Moves the `config\` folder an older build made beside a `config.json` into
/// `room_files`, its `config_` parts renamed for the room. Returns true when
/// anything was there to move.
bool moveOldConfigFolderIntoRoomFiles(String configPath) {
  if (!isFolderLayoutConfig(configPath)) return false;
  final old = Directory(path.join(
    path.dirname(configPath),
    path.basenameWithoutExtension(configPath),
  ));
  if (!old.existsSync()) return false;
  final to = roomFolderPath(configPath);
  Directory(to).createSync(recursive: true);
  _moveRoomFolderContents(
    old,
    to,
    path.basenameWithoutExtension(configPath),
    roomStem(configPath),
  );
  _deleteIfEmpty(old);
  return true;
}

/// `<room folder>/<config base>_<suffix>.json` for [part], or '' with no
/// config file.
String roomSidecarPath(String configPath, RoomSidecarPart part) =>
    roomFilePath(configPath, '${kRoomSidecarSuffix[part]}.json');

/// Where [part] was written before rooms had folders.
String legacyRoomSidecarPath(String configPath, RoomSidecarPart part) =>
    legacyRoomFilePath(configPath, '${kRoomSidecarSuffix[part]}.json');

/// The file to READ [part] from: in the folder, else beside the config, else ''.
String readableRoomSidecarPath(String configPath, RoomSidecarPart part) =>
    readableRoomFilePath(configPath, '${kRoomSidecarSuffix[part]}.json');

/// Every part's path, for a caller that has to write or scan all of them.
Map<RoomSidecarPart, String> roomSidecarPaths(String configPath) => {
  for (final part in RoomSidecarPart.values)
    part: roomSidecarPath(configPath, part),
};

/// Files the combined document breaks into.
///
/// A key nobody owns stays with [RoomSidecarPart.flow] rather than being
/// dropped: an unrecognized key is far more likely to be something a later
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
