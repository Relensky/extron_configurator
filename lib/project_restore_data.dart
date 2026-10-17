import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'building_project.dart';
import 'xlsx_reader.dart';
import 'xlsx_writer.dart';

/// The whole project inside its workbook and Google Sheet: a hidden tab
/// holding the project file and every room's files, so either copy is enough
/// to put the job back if the files are lost.

/// The hidden tab's name.
const String kProjectDataSheet = 'Project data';

/// Characters per cell: under Excel's 32,767 and the Sheet's 50,000.
const int kProjectDataChunk = 20000;

/// One file of the job, by its path relative to the project file.
typedef ProjectDataFile = ({String path, String text});

/// How many files are read from the share at once.
const int _readsAtOnce = 8;

/// The project file and each room's config and room_files, as text. Read
/// without blocking, a few at a time: a job is hundreds of small files on a
/// share, and reading them one after another on the window's own thread froze
/// the app on every save. A file that cannot be read is left out rather than
/// stopping the export.
Future<List<ProjectDataFile>> gatherProjectRestoreFiles(
  BuildingProject project,
  String projectPath,
) async {
  final out = <ProjectDataFile>[
    (
      path: projectPath.isEmpty
          ? '${project.name.isEmpty ? 'project' : project.name}'
              '$kProjectFileSuffix'
          : path.basename(projectPath),
      text: jsonEncode(_steady(project.toJson())),
    ),
  ];
  if (projectPath.isEmpty) return out;
  final root = path.dirname(projectPath);

  // Every file first, then the reads - both without blocking.
  final wanted = <String>[];
  final seen = <String>{};
  void want(String file) {
    final rel = path.relative(file, from: root);
    if (rel.startsWith('..') || !seen.add(rel.toLowerCase())) return;
    wanted.add(file);
  }

  Future<void> listRoom(ProjectRoomRef room) async {
    final config = BuildingProject.resolvePath(room.configPath, projectPath);
    if (config.isEmpty || !await File(config).exists()) return;
    want(config);
    final sidecars = Directory(path.join(path.dirname(config), 'room_files'));
    try {
      await for (final f in sidecars.list()) {
        if (f is! File) continue;
        final name = path.basename(f.path).toLowerCase();
        // Backups of backups are not the room.
        if (!name.endsWith('.json') || name.contains('previous')) continue;
        want(f.path);
      }
    } catch (_) {}
  }

  await _inBatches(project.rooms, listRoom);
  final texts = <String, String>{};
  await _inBatches(wanted, (String file) async {
    try {
      texts[file] = await File(file).readAsString();
    } catch (_) {}
  });
  for (final file in wanted) {
    final text = texts[file];
    if (text != null) {
      out.add((path: path.relative(file, from: root), text: text));
    }
  }
  return out;
}

Future<void> _inBatches<T>(List<T> items, Future<void> Function(T) work) async {
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      await work(items[next++]);
    }
  }

  await Future.wait([for (var i = 0; i < _readsAtOnce; i++) worker()]);
}

/// [json] without the stamps every publish moves, so a publish that changed
/// nothing else rewrites nothing in the tab.
Map<String, dynamic> _steady(Map<String, dynamic> json) => {
      for (final e in json.entries)
        if (!const {'onlinePublishedAt', 'onlineFileStamp', 'onlineSheetStamp'}
            .contains(e.key))
          e.key: e.value,
    };

/// The hidden tab's rows for [files]: each gzipped, base64'd and split into
/// cells.
List<List<String>> _packRows(List<ProjectDataFile> files) {
  final rows = <List<String>>[];
  for (final f in files) {
    final packed = base64.encode(gzip.encode(utf8.encode(f.text)));
    final parts = (packed.length / kProjectDataChunk).ceil().clamp(1, 1 << 20);
    for (var i = 0; i < parts; i++) {
      final end = ((i + 1) * kProjectDataChunk).clamp(0, packed.length);
      rows.add([
        f.path,
        '${i + 1}',
        '$parts',
        packed.substring(i * kProjectDataChunk, end),
      ]);
    }
  }
  return rows;
}

/// [_packRows] on a worker, handed nothing but the files - see
/// project_backups.dart on why it is top-level.
Future<List<List<String>>> _packRowsAsync(List<ProjectDataFile> files) =>
    Isolate.run(() => _packRows(files));

/// The hidden tab holding [files]. See [projectDataSheetFor] for the one the
/// app builds: off the window's thread.
XlsxSheet projectDataSheet(List<ProjectDataFile> files) =>
    _sheetFromRows(_packRows(files));

XlsxSheet _sheetFromRows(List<List<String>> packed) => XlsxSheet(
      name: kProjectDataSheet,
      rows: [
        [
          'Room Config Builder: the whole project, for putting it back if its '
              'files are lost. Do not edit this tab. Restore from it with '
              'File, Open, Restore Project from Workbook.',
        ],
        ['File', 'Part', 'Of', 'Data'],
        ...packed,
      ],
      rowStyles: const {1: XlsxRowStyle.header},
      columnWidths: const {0: 40, 1: 6, 2: 6, 3: 30},
      hidden: true,
    );

/// The hidden tab for [project], read and packed without blocking the
/// window: the files read a few at a time, the packing on a worker. Null when
/// it could not be made - the workbook still goes, without it.
Future<XlsxSheet?> projectDataSheetFor(
  BuildingProject project,
  String projectPath,
) async {
  try {
    final files = await gatherProjectRestoreFiles(project, projectPath);
    final rows = await _packRowsAsync(files);
    return _sheetFromRows(rows);
  } catch (e, stack) {
    AppLogger.logError('The project could not be packed into its workbook',
        e, stack);
    return null;
  }
}

/// The files a [kProjectDataSheet] tab holds, by path, or empty when the
/// tab is missing or damaged.
Map<String, String> filesFromProjectData(List<List<String>> rows) {
  final parts = <String, Map<int, String>>{};
  final counts = <String, int>{};
  for (final r in rows) {
    if (r.length < 4) continue;
    final part = int.tryParse(r[1].split('.').first);
    final of = int.tryParse(r[2].split('.').first);
    if (part == null || of == null || r[0].trim().isEmpty) continue;
    parts.putIfAbsent(r[0], () => {})[part] = r[3];
    counts[r[0]] = of;
  }
  final out = <String, String>{};
  for (final e in parts.entries) {
    final of = counts[e.key]!;
    if (e.value.length != of) continue;
    try {
      final packed = [for (var i = 1; i <= of; i++) e.value[i]!].join();
      out[e.key] = utf8.decode(gzip.decode(base64.decode(packed)));
    } catch (_) {}
  }
  return out;
}

/// What restoring did.
typedef ProjectRestoreResult = ({
  String projectFile,
  List<String> written,
  List<String> kept,
  String error,
});

/// Puts the job in workbook [bytes] back into [folder]: the project file
/// always (the one there now is copied aside first), and each room file only
/// where it is missing, unless [replaceRooms].
ProjectRestoreResult restoreProjectFromWorkbook(
  Uint8List bytes,
  String folder, {
  bool replaceRooms = false,
}) {
  ProjectRestoreResult fail(String why) =>
      (projectFile: '', written: const [], kept: const [], error: why);
  Map<String, List<List<String>>> grids;
  try {
    grids = readXlsxSheets(bytes);
  } catch (e) {
    return fail('The workbook could not be read: $e');
  }
  final tab = grids[kProjectDataSheet];
  if (tab == null) {
    return fail('This workbook has no $kProjectDataSheet tab. Only workbooks '
        'saved by version 0.5.142 or later carry the whole project.');
  }
  final files = filesFromProjectData(tab);
  final projectName = files.keys
      .where((k) => !k.contains(RegExp(r'[\\/]')) &&
          k.toLowerCase().endsWith(kProjectFileSuffix))
      .firstOrNull;
  if (projectName == null) return fail('The project file is not in the tab.');

  final written = <String>[];
  final kept = <String>[];
  try {
    for (final e in files.entries) {
      final target = path.join(folder, e.key);
      final isProject = e.key == projectName;
      final exists = File(target).existsSync();
      if (exists && !isProject && !replaceRooms) {
        kept.add(e.key);
        continue;
      }
      if (exists) {
        final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
        final aside = path.join(path.dirname(target), 'restore_backups',
            '${path.basenameWithoutExtension(target)}_$stamp.json');
        Directory(path.dirname(aside)).createSync(recursive: true);
        File(target).copySync(aside);
      }
      Directory(path.dirname(target)).createSync(recursive: true);
      File(target).writeAsStringSync(e.value);
      written.add(e.key);
    }
  } catch (e, stack) {
    AppLogger.logError('Restoring the project into $folder stopped', e, stack);
    return (
      projectFile: path.join(folder, projectName),
      written: written,
      kept: kept,
      error: 'Restoring stopped: $e',
    );
  }
  AppLogger.logInfo('Restored ${path.join(folder, projectName)} from a '
      'workbook: ${written.length} file(s) written, ${kept.length} kept.');
  return (
    projectFile: path.join(folder, projectName),
    written: written,
    kept: kept,
    error: '',
  );
}
