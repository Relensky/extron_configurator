import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'team/team_chat.dart';
import 'team/team_host.dart';

/// ============================================================================
///  THE OLD PROJECT CHAT, COPIED INTO THE TEAM CHAT
/// ============================================================================
///  Before 0.5.83 each project kept its own chat in a folder beside the
///  project file, and the Root Folder had an Everyone chat of its own:
///
///      <project folder>/<project>_chat/messages/<login>@<machine>.jsonl
///      <Root Folder>/chat/messages/<login>@<machine>.jsonl
///
///  The project chat is now a thread in the team chat (projectChannel), seen
///  in every CTS app. The first time a project opens, its old messages are
///  copied into that thread, and the old Everyone chat into this app's own
///  conversation - under their writers and times, each with a stable id, so
///  opening the project again (or on another PC) adds nothing twice. The old
///  folders are only read, never changed: they stay as they were.
/// ============================================================================

/// The folder a project's old chat was kept in.
String legacyChatFolderFor(String projectPath) {
  var stem = path.basename(projectPath);
  const suffix = '_project.json';
  if (stem.toLowerCase().endsWith(suffix)) {
    stem = stem.substring(0, stem.length - suffix.length);
  } else {
    stem = path.basenameWithoutExtension(stem);
  }
  return path.join(path.dirname(projectPath), '${stem}_chat');
}

/// The messages in an old chat folder, deletes and edits applied, oldest
/// first. A message in a room's or a tab's channel says which, in front.
/// Never throws: an unreadable folder or line is skipped.
Future<List<ImportedMessage>> readLegacyChat(String folder) async {
  final dir = Directory(path.join(folder, 'messages'));
  final raw = <Map>[];
  try {
    if (!await dir.exists()) return const [];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.toLowerCase().endsWith('.jsonl')) continue;
      try {
        for (final line in await f.readAsLines()) {
          if (line.trim().isEmpty) continue;
          try {
            final j = jsonDecode(line);
            if (j is Map) raw.add(j);
          } catch (_) {}
        }
      } catch (_) {}
    }
  } catch (_) {
    return const [];
  }

  String str(Map j, String k) => j[k]?.toString() ?? '';
  final deleted = <String>{};
  final edits = <String, (DateTime, String)>{};
  for (final j in raw) {
    final at = DateTime.tryParse(str(j, 'at'));
    if (str(j, 'deletes').isNotEmpty) {
      deleted.add('${str(j, 'user').toLowerCase()}|${str(j, 'deletes')}');
    }
    final target = str(j, 'edits');
    if (target.isNotEmpty && at != null) {
      final key = '${str(j, 'user').toLowerCase()}|$target';
      final had = edits[key];
      if (had == null || at.isAfter(had.$1)) edits[key] = (at, str(j, 'text'));
    }
  }

  final out = <ImportedMessage>[];
  for (final j in raw) {
    if (str(j, 'deletes').isNotEmpty ||
        str(j, 'edits').isNotEmpty ||
        str(j, 'reacts').isNotEmpty) {
      continue;
    }
    final at = DateTime.tryParse(str(j, 'at'));
    final id = str(j, 'id');
    final user = str(j, 'user');
    if (at == null || id.isEmpty) continue;
    final key = '${user.toLowerCase()}|$id';
    if (deleted.contains(key)) continue;
    var text = edits[key]?.$2 ?? str(j, 'text');
    if (text.trim().isEmpty && str(j, 'image').isNotEmpty) {
      text = '(a picture, kept in the old project chat folder)';
    }
    if (text.trim().isEmpty) continue;
    // Room and tab channels became one thread: say which it was.
    final channel = str(j, 'channel');
    final where = channel.startsWith('room:')
        ? str(j, 'room')
        : channel.startsWith('tab:')
            ? str(j, 'tab')
            : '';
    if (where.isNotEmpty) text = '[$where] $text';
    out.add((
      id: id,
      user: user,
      name: str(j, 'name'),
      at: at.toLocal(),
      text: text,
      room: str(j, 'room'),
    ));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// Copies the old chat of the project at [projectPath] into its thread.
/// Returns how many messages were new to the team chat.
Future<int> importLegacyProjectChat(
  TeamChat chat, {
  required String projectPath,
  required String projectName,
}) async {
  if (projectPath.isEmpty || projectName.trim().isEmpty) return 0;
  final items = await readLegacyChat(legacyChatFolderFor(projectPath));
  if (items.isEmpty) return 0;
  return chat.importMessages(projectChannel(projectName), items);
}

/// Copies the old Everyone chat (the Root Folder's `chat` folder) into this
/// app's own conversation in the team chat.
Future<int> importLegacyEveryoneChat(TeamChat chat, String rootFolder) async {
  if (rootFolder.trim().isEmpty) return 0;
  final items = await readLegacyChat(path.join(rootFolder, 'chat'));
  if (items.isEmpty) return 0;
  return chat.importMessages(appChannel(TeamHost.appId), items);
}
