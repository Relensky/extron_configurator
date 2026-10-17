import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'building_project.dart';

/// Keeping a project file from being lost: a copy beside it on every save,
/// a copy of your own on every open and save, and a refusal to save a blank
/// job over a real one.

/// How many copies are kept beside a project, and in each person's own.
const int kProjectBackupsBeside = 20;
const int kProjectBackupsPerUser = 60;

/// True when [a] and [b] name the same file on Windows: case and slashes
/// aside.
bool samePath(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  String norm(String p) =>
      path.windows.normalize(p.replaceAll('/', r'\')).toLowerCase();
  return norm(a) == norm(b);
}

/// Why [job] must not be saved over [target], or ''. A job with no name and
/// no rooms over a file that has rooms is the empty project left behind by a
/// close - never something somebody meant to save.
String blankProjectOverJob(BuildingProject job, String target) {
  if (job.rooms.isNotEmpty || job.name.trim().isNotEmpty) return '';
  final rooms = projectFileRoomCount(target);
  if (rooms == null || rooms == 0) return '';
  return 'This is an empty project, and ${path.basename(target)} holds '
      '$rooms room${rooms == 1 ? '' : 's'}, so it was not saved over it.';
}

/// How many rooms the project file at [file] lists, or null when it is not
/// there or cannot be read.
int? projectFileRoomCount(String file) {
  try {
    final f = File(file);
    if (!f.existsSync()) return null;
    final json = jsonDecode(f.readAsStringSync());
    if (json is! Map) return null;
    final rooms = json['rooms'];
    return rooms is List ? rooms.length : 0;
  } catch (_) {
    return null;
  }
}

String _stamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// Copies [file] into [folder] as `<name>_<stamp>.json`, keeping the newest
/// [keep] of that name. Returns the copy, or null. Never throws: a backup
/// that fails must not cost somebody their save.
String? _copyInto(String file, String folder, int keep, {DateTime? at}) {
  try {
    final source = File(file);
    if (!source.existsSync()) return null;
    Directory(folder).createSync(recursive: true);
    final stem = path.basenameWithoutExtension(file);
    final copy = path.join(folder, '${stem}_${_stamp(at ?? DateTime.now())}.json');
    source.copySync(copy);
    final mine = Directory(folder)
        .listSync()
        .whereType<File>()
        .where((f) =>
            path.basename(f.path).startsWith('${stem}_') &&
            f.path.toLowerCase().endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in mine.skip(keep)) {
      old.deleteSync();
    }
    return copy;
  } catch (e, stack) {
    AppLogger.logError('A backup of $file could not be made', e, stack);
    return null;
  }
}

/// Before a save: the file as it is now, into `project_backups` beside it.
String? backUpProjectFile(String file, {DateTime? at}) => _copyInto(
    file,
    path.join(path.dirname(file), 'project_backups'),
    kProjectBackupsBeside,
    at: at);

/// Your own copy of [file], in your own app data, on every open and save.
/// It is kept apart from the recovery copies, which are cleared on save.
/// Only a file that lists rooms is kept, so an empty one never pushes the
/// good copies out.
String? backUpProjectForUser(String file, String userDir, {DateTime? at}) {
  final rooms = projectFileRoomCount(file);
  if (rooms == null || rooms == 0) return null;
  final key = path
      .basenameWithoutExtension(file)
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return _copyInto(file, path.join(userDir, key), kProjectBackupsPerUser,
      at: at);
}

// ---------------------------------------------------------------------------
//  ROOMS AND CAMPUSES
// ---------------------------------------------------------------------------

/// How many copies of a room are kept beside it, and in each person's own.
const int kRoomBackupsBeside = 10;
const int kRoomBackupsPerUser = 30;

/// How many copies of a campus are kept beside it.
const int kCampusBackupsBeside = 20;

/// True when the room config at [file] has anything in it worth keeping.
bool roomFileHasContent(String file) {
  try {
    final f = File(file);
    if (!f.existsSync()) return false;
    final json = jsonDecode(f.readAsStringSync());
    return json is Map && json['SYSTEM_SETUP'] is Map;
  } catch (_) {
    return false;
  }
}

/// Copies a whole room - its config and the drawing, cost and rack files in
/// room_files - into a dated folder under [into], keeping the newest [keep].
String? _copyRoomInto(String configPath, String into, int keep, DateTime? at) {
  try {
    if (!roomFileHasContent(configPath)) return null;
    final folder = path.join(into, _stamp(at ?? DateTime.now()));
    Directory(folder).createSync(recursive: true);
    File(configPath).copySync(path.join(folder, path.basename(configPath)));
    final sidecars = Directory(
        path.join(path.dirname(configPath), _roomFilesFolder));
    if (sidecars.existsSync()) {
      for (final f in sidecars.listSync().whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.json')) continue;
        f.copySync(path.join(folder, path.basename(f.path)));
      }
    }
    final dated = Directory(into).listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in dated.skip(keep)) {
      old.deleteSync(recursive: true);
    }
    return folder;
  } catch (e, stack) {
    AppLogger.logError('A backup of the room at $configPath could not be made',
        e, stack);
    return null;
  }
}

const String _roomFilesFolder = 'room_files';

/// Before a room save: the room as it is now, into room_files\backups.
String? backUpRoomDocument(String configPath, {DateTime? at}) => _copyRoomInto(
    configPath,
    path.join(path.dirname(configPath), _roomFilesFolder, 'backups'),
    kRoomBackupsBeside,
    at);

/// Your own copy of a room, in your own app data, on every open and save.
String? backUpRoomForUser(String configPath, String userDir, {DateTime? at}) {
  final room = '${path.basename(path.dirname(configPath))}_'
      '${path.basenameWithoutExtension(configPath)}';
  final key = room.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return _copyRoomInto(
      configPath, path.join(userDir, key), kRoomBackupsPerUser, at);
}

/// Before a campus save: the campus as it is now, into campus_backups.
String? backUpCampusFile(String file, {DateTime? at}) => _copyInto(
    file,
    path.join(path.dirname(file), 'campus_backups'),
    kCampusBackupsBeside,
    at: at);

/// Your own copy of a campus, in your own app data.
String? backUpCampusForUser(String file, String userDir, {DateTime? at}) {
  final key = path
      .basenameWithoutExtension(file)
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return _copyInto(file, path.join(userDir, key), kProjectBackupsPerUser,
      at: at);
}

// ---------------------------------------------------------------------------
//  OFF THE WINDOW'S THREAD
// ---------------------------------------------------------------------------
//  Top-level so each worker is handed nothing but paths: a closure made
//  inside a save carries that save's whole context, futures included, and
//  those cannot be sent to another isolate.

Future<String?> backUpProjectFileAsync(String file) =>
    Isolate.run(() => backUpProjectFile(file));

Future<String?> backUpRoomDocumentAsync(String configPath) =>
    Isolate.run(() => backUpRoomDocument(configPath));

Future<String?> backUpProjectForUserAsync(String file, String userDir) =>
    Isolate.run(() => backUpProjectForUser(file, userDir));

Future<String?> backUpRoomForUserAsync(String configPath, String userDir) =>
    Isolate.run(() => backUpRoomForUser(configPath, userDir));

Future<String?> backUpCampusForUserAsync(String file, String userDir) =>
    Isolate.run(() => backUpCampusForUser(file, userDir));
