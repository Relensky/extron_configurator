import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// ============================================================================
///  WHAT A ROOM TAG LINKS TO
/// ============================================================================
///  A "working on" tag keeps the file it was made on, so the CTS Dashboard and
///  everyone's team page can open it. A file on this PC (C:\..., a drive only
///  this PC maps) opens nowhere else, so a tag made on one links to the
///  shared copy of the room in the Projects folder instead, or to nothing,
///  with a note saying why.
/// ============================================================================

/// Where a tag points, and what to tell the person making it.
typedef TeamTagTarget = ({String file, String project, String note});

/// Drive letter ('S:') to the share it maps to ('\\server\share').
Map<String, String> _mapped = const {};
bool _mappedRead = false;

/// Reads this PC's mapped drives once (`net use`). Never throws.
Future<void> loadMappedDrives() async {
  if (_mappedRead) return;
  _mappedRead = true;
  try {
    final r = await Process.run('net', ['use'], runInShell: true);
    _mapped = parseNetUse('${r.stdout}');
  } catch (_) {}
}

/// `net use` output to drive letter -> share.
Map<String, String> parseNetUse(String text) {
  final out = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final m = RegExp(r'\b([A-Za-z]:)\s+(\\\\\S[^\r\n]*?)\s{2,}').firstMatch('$line  ');
    if (m != null) out[m.group(1)!.toUpperCase()] = m.group(2)!.trim();
  }
  return out;
}

/// [file] as everyone can reach it: a UNC path as it is, a mapped drive as
/// its share; '' for a file only this PC has.
String sharedPathOf(String file, {Map<String, String>? mapped}) {
  final f = file.trim();
  if (f.isEmpty) return '';
  if (f.startsWith(r'\\')) return f;
  final m = RegExp(r'^([A-Za-z]:)[\\/]?(.*)$').firstMatch(f);
  if (m == null) return '';
  final share = (mapped ?? _mapped)[m.group(1)!.toUpperCase()];
  if (share == null) return '';
  final rest = m.group(2)!;
  return rest.isEmpty ? share : '$share\\$rest';
}

/// Where a tag on [roomId] should link: the open project or room when
/// everyone can reach it, else [sharedCopy] (the room's config in the
/// Projects folder, '' when there is none) with a note, else nothing.
TeamTagTarget teamTagTargetOf({
  required String roomId,
  required String projectPath,
  required String projectName,
  required String configPath,
  required String sharedCopy,
  Map<String, String>? mapped,
}) {
  final project = sharedPathOf(projectPath, mapped: mapped);
  if (project.isNotEmpty) return (file: project, project: projectName, note: '');
  // A job kept on this PC can still hold a room on the share.
  final config = sharedPathOf(configPath, mapped: mapped);
  if (config.isNotEmpty) return (file: config, project: '', note: '');
  final what = projectPath.trim().isNotEmpty ? 'project' : 'room';
  if (sharedCopy.isNotEmpty) {
    return (
      file: sharedCopy,
      project: '',
      note: 'This $what is open from a copy on this $_here. A tag links to the '
          'shared $roomId instead:\n$sharedCopy',
    );
  }
  return (
    file: '',
    project: '',
    note: 'This $what is open from a copy on this $_here and $roomId has no '
        'shared copy in the Projects folder, so a tag will not link to it '
        'for anyone else. It still marks $roomId as being worked on for '
        'everyone, and they cannot save it until you are taken off.',
  );
}

/// The config of [roomId] in [projectsFolder]: `<project>\<ROOM_ID>\config.json`
/// or the processor's `<room>\code\upload_to_root\config.json`, checked with
/// [idFor]. '' when there is none. Never throws.
Future<String> findSharedRoomConfig(
  String projectsFolder,
  String roomId,
  String Function(Map<String, dynamic> config) idFor,
) async {
  final want = roomId.trim().toLowerCase();
  if (projectsFolder.trim().isEmpty || want.isEmpty) return '';
  final names = {
    roomId.trim().replaceAll(' ', '_'),
    roomId.trim().replaceAll(' ', ''),
  };
  try {
    final root = Directory(projectsFolder);
    if (!await root.exists()) return '';
    final projects = [
      root.path,
      await for (final e in root.list())
        if (e is Directory) e.path,
    ];
    for (final p in projects) {
      for (final n in names) {
        for (final f in [
          path.join(p, n, 'config.json'),
          path.join(p, n, 'code', 'upload_to_root', 'config.json'),
        ]) {
          final file = File(f);
          if (!await file.exists()) continue;
          try {
            final doc = jsonDecode(await file.readAsString());
            if (doc is Map<String, dynamic> &&
                idFor(doc).trim().toLowerCase() == want) {
              return f;
            }
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
  return '';
}

/// What this machine is called in the notes above.
String get _here => Platform.isIOS || Platform.isAndroid ? 'device' : 'PC';
