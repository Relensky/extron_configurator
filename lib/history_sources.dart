import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

import 'app_state.dart';
import 'building_project.dart';
import 'campus_file.dart';
import 'room_sidecar.dart';

/// ============================================================================
///  EVERYBODY'S CHANGES, NOT ONLY THE OPEN FILE'S
/// ============================================================================
///  The open job and the open room keep their logs in memory. Every other
///  room on the job - and, for a job on a campus, every other job there and
///  its rooms - keeps its own log on disk, written by whoever worked on it.
///  These read those logs, so History shows what other people changed in
///  rooms and jobs nobody here has open.
/// ============================================================================

/// One change read off disk, with where it was made and the file it is in.
typedef OutsideEdit = ({
  ProjectEdit edit,
  String project,
  String room,
  String file,
});

/// What a room is called when only its config path is known: the folder it
/// is in, or the file's own name for a loose config.
String roomNameForConfig(String configPath, {String label = ''}) {
  if (label.trim().isNotEmpty) return label.trim();
  final stem = roomStem(configPath);
  if (stem.isNotEmpty) return stem;
  return path.basenameWithoutExtension(configPath);
}

Future<Object?> _readJson(String file) async {
  try {
    final f = File(file);
    if (!await f.exists()) return null;
    return jsonDecode(await f.readAsString());
  } catch (_) {
    return null;
  }
}

/// A room's log off disk: its history file, else the AV flow file an older
/// room kept it in. Empty when there is none.
Future<({List<ProjectEdit> edits, String file})> readRoomLogFromDisk(
  String configPath,
) async {
  for (final file in [
    readableRoomSidecarPath(configPath, RoomSidecarPart.history),
    readableRoomSidecarPath(configPath, RoomSidecarPart.flow),
    readableRoomFilePath(configPath, 'avflow.json'),
  ]) {
    if (file.isEmpty) continue;
    final doc = await _readJson(file);
    final list = doc is Map ? doc['roomHistory'] : null;
    if (list is! List || list.isEmpty) continue;
    return (
      edits: [
        for (final h in list)
          if (h is Map) ProjectEdit.fromJson(Map<String, dynamic>.from(h)),
      ],
      file: file,
    );
  }
  return (edits: const <ProjectEdit>[], file: '');
}

/// Every other room on the open job, from each room's own log.
Future<List<OutsideEdit>> readOtherRoomEdits(AppStateProvider p) async {
  if (!p.hasOpenProject) return const [];
  final openId = p.openProjectRoom?.id;
  final project = p.projectDisplayName;
  // Names worked out here, where the job is; the files read and decoded on
  // a background isolate, so a job of forty rooms on a share does not hold
  // up the window.
  final rooms = [
    for (final ref in p.project.rooms)
      if (ref.id != openId)
        (
          config:
              BuildingProject.resolvePath(ref.configPath, p.currentProjectPath),
          name: p.projectRoomLogName(ref.id),
          label: ref.label,
        ),
  ]..removeWhere((r) => r.config.isEmpty);
  return Isolate.run(() async {
    final out = <OutsideEdit>[];
    for (final r in rooms) {
      final log = await readRoomLogFromDisk(r.config);
      for (final e in log.edits) {
        out.add((
          edit: e,
          project: project,
          room: r.name.isEmpty
              ? roomNameForConfig(r.config, label: r.label)
              : r.name,
          file: log.file,
        ));
      }
    }
    return out;
  });
}

/// Every other job on the open job's campus: each job's own log and each of
/// its rooms' logs. Empty when the job is on no campus.
Future<List<OutsideEdit>> readCampusEdits(AppStateProvider p) async {
  if (!p.hasOpenProject || p.currentProjectPath.isEmpty) return const [];
  final campusPath = p.project.resolvedCampusFile(p.currentProjectPath);
  if (campusPath.isEmpty) return const [];
  final current = p.currentProjectPath;
  // Every job on the campus and all their rooms: on a background isolate.
  return Isolate.run(() => _readCampusEdits(campusPath, current));
}

Future<List<OutsideEdit>> _readCampusEdits(
  String campusPath,
  String currentProjectPath,
) async {
  if (!await File(campusPath).exists()) return const [];
  final CampusFile campus;
  try {
    campus = await CampusFile.load(campusPath);
  } catch (_) {
    return const [];
  }
  final here = path.normalize(currentProjectPath).toLowerCase();
  final out = <OutsideEdit>[];
  for (final projectPath in campus.projects) {
    if (path.normalize(projectPath).toLowerCase() == here) continue;
    final doc = await _readJson(projectPath);
    if (doc is! Map) continue;
    final name = '${doc['name'] ?? ''}'.trim().isNotEmpty
        ? '${doc['name']}'.trim()
        : path.basenameWithoutExtension(projectPath);
    for (final h in (doc['history'] as List? ?? const [])) {
      if (h is! Map) continue;
      out.add((
        edit: ProjectEdit.fromJson(Map<String, dynamic>.from(h)),
        project: name,
        room: '',
        file: projectPath,
      ));
    }
    for (final r in (doc['rooms'] as List? ?? const [])) {
      if (r is! Map) continue;
      final config = BuildingProject.resolvePath(
          '${r['configPath'] ?? ''}', projectPath);
      if (config.isEmpty) continue;
      final log = await readRoomLogFromDisk(config);
      final room = roomNameForConfig(config, label: '${r['label'] ?? ''}');
      for (final e in log.edits) {
        out.add((edit: e, project: name, room: room, file: log.file));
      }
    }
  }
  return out;
}
