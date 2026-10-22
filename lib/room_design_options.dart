import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'project_backups.dart' show backUpRoomDocument;
import 'room_sidecar.dart';
import 'safe_write.dart';

/// ============================================================================
///  DESIGN OPTIONS: OTHER BUILDS OF THE SAME ROOM
/// ============================================================================
///  "With the camera package" and "without it" are two designs of one room,
///  each with its own drawing, racks and quote. Each option is a whole copy
///  of the room's files, kept in `room_files\design_options\<id>`, and the
///  room's own files are always the chosen option. Choosing another option
///  files the room away under the one it was and copies the chosen one in,
///  so every tab, the project total and the next save all follow it.
///
///  The snapshot is laid out as a room of its own (`<id>\config.json` and
///  `<id>\room_files\<id>_cost.json`), so anything that can read a room can
///  price an option that is not chosen.
///
///  The history file is not copied: who changed what stays one log.
/// ============================================================================

/// The index of a room's options, in its room folder.
const String kDesignOptionsSuffix = 'design_options.json';

/// The folder under the room folder the options are kept in.
const String kDesignOptionsFolder = 'design_options';

/// The room parts each option has its own copy of.
const List<RoomSidecarPart> kDesignOptionParts = [
  RoomSidecarPart.flow,
  RoomSidecarPart.racks,
  RoomSidecarPart.floorPlans,
  RoomSidecarPart.cabling,
  RoomSidecarPart.cost,
];

/// One design of the room.
class RoomDesignOption {
  final String id;
  final String name;

  /// The room total when it was last filed away. 0 when not known yet.
  final double total;

  const RoomDesignOption({
    required this.id,
    required this.name,
    this.total = 0,
  });

  RoomDesignOption copyWith({String? name, double? total}) => RoomDesignOption(
    id: id,
    name: name ?? this.name,
    total: total ?? this.total,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (total != 0) 'total': total,
  };

  factory RoomDesignOption.fromJson(Map<String, dynamic> json) =>
      RoomDesignOption(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        total: (json['total'] as num?)?.toDouble() ?? 0,
      );
}

/// A room's options and which one its files are.
class RoomDesignOptions {
  /// The option the room's own files are.
  final String active;
  final List<RoomDesignOption> options;

  const RoomDesignOptions({this.active = '', this.options = const []});

  static const RoomDesignOptions none = RoomDesignOptions();

  /// True when the room has more than the one design.
  bool get hasChoices => options.length > 1;

  RoomDesignOption? byId(String id) =>
      options.where((o) => o.id == id).firstOrNull;

  RoomDesignOption? get activeOption => byId(active);

  RoomDesignOptions copyWith({
    String? active,
    List<RoomDesignOption>? options,
  }) => RoomDesignOptions(
    active: active ?? this.active,
    options: options ?? this.options,
  );

  Map<String, dynamic> toJson() => {
    'active': active,
    'options': [for (final o in options) o.toJson()],
  };

  factory RoomDesignOptions.fromJson(Map<String, dynamic> json) {
    final options = [
      for (final o in (json['options'] as List? ?? const []))
        if (o is Map) RoomDesignOption.fromJson(Map<String, dynamic>.from(o)),
    ].where((o) => o.id.isNotEmpty).toList();
    var active = json['active']?.toString() ?? '';
    if (!options.any((o) => o.id == active)) {
      active = options.isEmpty ? '' : options.first.id;
    }
    return RoomDesignOptions(active: active, options: options);
  }
}

/// Where [configPath]'s index of options is.
String designOptionsIndexPath(String configPath) =>
    roomFilePath(configPath, kDesignOptionsSuffix);

/// The folder option [id] of [configPath] is kept in.
String designOptionFolder(String configPath, String id) =>
    path.join(roomFolderPath(configPath), kDesignOptionsFolder, id);

/// The config of option [id], laid out as a room of its own.
String designOptionConfigPath(String configPath, String id) =>
    path.join(designOptionFolder(configPath, id), kRoomConfigFileName);

/// [configPath]'s options, or [RoomDesignOptions.none] when it has none.
RoomDesignOptions readDesignOptions(String configPath) {
  if (configPath.isEmpty) return RoomDesignOptions.none;
  try {
    final file = File(designOptionsIndexPath(configPath));
    if (!file.existsSync()) return RoomDesignOptions.none;
    final json = jsonDecode(file.readAsStringSync());
    if (json is! Map) return RoomDesignOptions.none;
    return RoomDesignOptions.fromJson(Map<String, dynamic>.from(json));
  } catch (_) {
    return RoomDesignOptions.none;
  }
}

/// The same, off the window's thread.
Future<RoomDesignOptions> readDesignOptionsAsync(String configPath) async {
  if (configPath.isEmpty) return RoomDesignOptions.none;
  try {
    final file = File(designOptionsIndexPath(configPath));
    if (!await file.exists()) return RoomDesignOptions.none;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return RoomDesignOptions.none;
    return RoomDesignOptions.fromJson(Map<String, dynamic>.from(json));
  } catch (_) {
    return RoomDesignOptions.none;
  }
}

void _writeIndex(String configPath, RoomDesignOptions options) {
  ensureRoomFolder(configPath);
  writeFileSafelySync(
    designOptionsIndexPath(configPath),
    const JsonEncoder.withIndent('  ').convert(options.toJson()),
  );
}

/// Copies the room's files into option [id]'s folder. A part the room does
/// not have is taken out of the option too, so the copy is the room.
void _fileRoomAway(String configPath, String id) {
  final optionConfig = designOptionConfigPath(configPath, id);
  Directory(roomFolderPath(optionConfig)).createSync(recursive: true);
  writeFileSafelySync(optionConfig, File(configPath).readAsStringSync());
  for (final part in kDesignOptionParts) {
    final suffix = '${kRoomSidecarSuffix[part]}.json';
    final source = readableRoomFilePath(configPath, suffix);
    final kept = roomFilePath(optionConfig, suffix);
    if (source.isNotEmpty) {
      writeFileSafelySync(kept, File(source).readAsStringSync());
    } else if (File(kept).existsSync()) {
      File(kept).deleteSync();
    }
  }
}

/// Copies option [id]'s files over the room's. A part the option does not
/// have is taken out of the room - it was filed away with the option the
/// room was, and backed up, first.
void _bringOptionIn(String configPath, String id) {
  final optionConfig = designOptionConfigPath(configPath, id);
  writeFileSafelySync(configPath, File(optionConfig).readAsStringSync());
  ensureRoomFolder(configPath);
  for (final part in kDesignOptionParts) {
    final suffix = '${kRoomSidecarSuffix[part]}.json';
    final kept = File(roomFilePath(optionConfig, suffix));
    final live = roomFilePath(configPath, suffix);
    if (kept.existsSync()) {
      writeFileSafelySync(live, kept.readAsStringSync());
    } else if (File(live).existsSync()) {
      File(live).deleteSync();
    }
  }
}

/// A new id no option of [options] has.
String _newId(RoomDesignOptions options) {
  var n = options.options.length + 1;
  while (options.byId('option_$n') != null) {
    n++;
  }
  return 'option_$n';
}

/// Starts a new option named [name] as a copy of the room as it is on disk,
/// and makes it the chosen one. A room with no options first files itself
/// as [firstName], so the design it was stays one press away. [total] is the
/// room total now, kept with both.
///
/// The room must be saved first: this copies its files.
RoomDesignOptions createDesignOption(
  String configPath, {
  required String name,
  String firstName = 'Base design',
  double total = 0,
}) {
  var options = readDesignOptions(configPath);
  if (options.options.isEmpty) {
    const id = 'option_1';
    _fileRoomAway(configPath, id);
    options = RoomDesignOptions(
      active: id,
      options: [RoomDesignOption(id: id, name: firstName, total: total)],
    );
  } else {
    _fileRoomAway(configPath, options.active);
    options = _withTotal(options, options.active, total);
  }
  final id = _newId(options);
  _fileRoomAway(configPath, id);
  options = options.copyWith(
    active: id,
    options: [
      ...options.options,
      RoomDesignOption(id: id, name: name, total: total),
    ],
  );
  _writeIndex(configPath, options);
  return options;
}

RoomDesignOptions _withTotal(RoomDesignOptions o, String id, double total) =>
    o.copyWith(options: [
      for (final x in o.options) x.id == id ? x.copyWith(total: total) : x,
    ]);

/// Makes option [id] the room's design: the room is backed up, filed away
/// under the option it was (with [total], its room total now), and [id]'s
/// files are copied over it. Returns the options, or null when [id] is not
/// one of them.
///
/// The room must be saved first: its files are what is filed away.
RoomDesignOptions? chooseDesignOption(
  String configPath,
  String id, {
  double total = 0,
}) {
  var options = readDesignOptions(configPath);
  if (options.byId(id) == null) return null;
  if (options.active == id) return options;
  if (!File(designOptionConfigPath(configPath, id)).existsSync()) return null;
  backUpRoomDocument(configPath);
  if (options.active.isNotEmpty) {
    _fileRoomAway(configPath, options.active);
    options = _withTotal(options, options.active, total);
  }
  _bringOptionIn(configPath, id);
  options = options.copyWith(active: id);
  _writeIndex(configPath, options);
  return options;
}

/// Renames option [id].
RoomDesignOptions renameDesignOption(
  String configPath,
  String id,
  String name,
) {
  final options = readDesignOptions(configPath);
  final updated = options.copyWith(options: [
    for (final o in options.options)
      o.id == id ? o.copyWith(name: name.trim()) : o,
  ]);
  _writeIndex(configPath, updated);
  return updated;
}

/// Takes option [id] off the room. Not the chosen one: that is the room.
/// Its files are moved into `design_options\removed`, not deleted.
RoomDesignOptions removeDesignOption(String configPath, String id) {
  final options = readDesignOptions(configPath);
  if (id == options.active || options.byId(id) == null) return options;
  final folder = Directory(designOptionFolder(configPath, id));
  if (folder.existsSync()) {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final removed = path.join(
      roomFolderPath(configPath),
      kDesignOptionsFolder,
      'removed',
    );
    Directory(removed).createSync(recursive: true);
    folder.renameSync(path.join(removed, '${id}_$stamp'));
  }
  final updated = options.copyWith(options: [
    for (final o in options.options)
      if (o.id != id) o,
  ]);
  _writeIndex(configPath, updated);
  return updated;
}
