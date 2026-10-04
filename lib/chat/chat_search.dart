import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

import 'project_chat.dart';

/// ============================================================================
///  SEARCHING EVERY CHAT AND EVERY PROJECT
/// ============================================================================
///  The Root Folder is walked for project files (`*_project.json`); beside
///  each one its chat folder, if it has one, is read, and so is the shared
///  Everyone chat in `<root>\chat`. All of it on a background isolate: a file
///  share answers slowly, and the window must not wait on it.
///
///  The list of projects is kept for a couple of minutes, so typing a search
///  does not walk the share once per key.
/// ============================================================================

/// How deep under the Root Folder project files are looked for.
const kSearchDepth = 5;

/// One project found.
typedef SearchProject = ({String path, String name});

/// One message found: which project ('' for Everyone) and the message.
typedef SearchMessage = ({String projectPath, String projectName, ChatMessage message});

typedef SearchResults = ({
  List<SearchProject> projects,
  List<SearchMessage> messages,
  int scanned,
});

/// A project's name as people say it: the file name without `_project.json`.
String searchProjectName(String file) {
  final base = path.basename(file);
  const suffix = '_project.json';
  return base.toLowerCase().endsWith(suffix)
      ? base.substring(0, base.length - suffix.length).replaceAll('_', ' ')
      : path.basenameWithoutExtension(base);
}

/// Folders that never hold a project, skipped to keep the walk short.
const _skip = {'assets', 'devices', 'documentation', 'modules', 'build', 'chat'};

/// Every project file under [root], to [kSearchDepth].
List<String> findProjectFiles(String root) {
  final out = <String>[];
  void walk(Directory dir, int depth) {
    List<FileSystemEntity> items;
    try {
      items = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in items) {
      final name = path.basename(e.path);
      if (e is File && name.toLowerCase().endsWith('_project.json')) {
        out.add(e.path);
      } else if (e is Directory && depth < kSearchDepth) {
        final lower = name.toLowerCase();
        if (lower.startsWith('.') ||
            _skip.contains(lower) ||
            lower.endsWith('_chat')) {
          continue;
        }
        walk(e, depth + 1);
      }
    }
  }

  if (root.isNotEmpty && Directory(root).existsSync()) walk(Directory(root), 0);
  out.sort((a, b) => searchProjectName(a)
      .toLowerCase()
      .compareTo(searchProjectName(b).toLowerCase()));
  return out;
}

/// Every message in one chat folder.
List<ChatMessage> readChatFolder(String folder) {
  final out = <ChatMessage>[];
  final dir = Directory(path.join(folder, 'messages'));
  if (!dir.existsSync()) return out;
  try {
    for (final f in dir.listSync()) {
      if (f is! File || !f.path.endsWith('.jsonl')) continue;
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final m = ChatMessage.fromJson(jsonDecode(line));
          if (m != null) out.add(m);
        } catch (_) {}
      }
    }
  } catch (_) {}
  return withoutDeleted(out);
}

/// What a search compares: lower case, spaces gone, so "bss103" finds
/// "BSS 103".
String _fold(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

bool _hit(String text, String query) => _fold(text).contains(_fold(query));

SearchResults _search(
  String root,
  List<String> projects,
  String query,
  int limit,
) {
  final q = query.trim();
  final found = <SearchProject>[
    for (final p in projects)
      if (q.isEmpty || _hit(searchProjectName(p), q) || _hit(p, q))
        (path: p, name: searchProjectName(p)),
  ];
  final messages = <SearchMessage>[];
  if (q.isNotEmpty) {
    void take(String projectPath, String projectName, List<ChatMessage> all) {
      for (final m in all) {
        if (_hit(m.text, q) || _hit(m.who, q) || _hit(m.user, q) ||
            _hit(m.room, q)) {
          messages.add(
              (projectPath: projectPath, projectName: projectName, message: m));
        }
      }
    }

    if (root.isNotEmpty) {
      take('', 'Everyone', [
        for (final m in readChatFolder(everyoneChatFolder(root)))
          m.withChannel(kChatEveryone),
      ]);
    }
    for (final p in projects) {
      take(p, searchProjectName(p), readChatFolder(chatFolderFor(p)));
    }
    messages.sort((a, b) => b.message.at.compareTo(a.message.at));
  }
  return (
    projects: found,
    messages: messages.length > limit ? messages.sublist(0, limit) : messages,
    scanned: projects.length,
  );
}

class ChatSearch {
  ChatSearch._();

  static List<String>? _projects;
  static String _projectsRoot = '';
  static DateTime _projectsAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Forgets the list of projects, so the next search walks the share again.
  static void refresh() => _projects = null;

  /// Searches every chat and project under [root]. [extra] are project files
  /// to include wherever they are - the one open, recent ones.
  static Future<SearchResults> search(
    String root,
    String query, {
    List<String> extra = const [],
    int limit = 300,
  }) async {
    if (_projects == null ||
        _projectsRoot != root ||
        DateTime.now().difference(_projectsAt) > const Duration(minutes: 2)) {
      _projects = await Isolate.run(() => findProjectFiles(root));
      _projectsRoot = root;
      _projectsAt = DateTime.now();
    }
    final seen = <String>{};
    final all = <String>[
      for (final p in [..._projects!, ...extra])
        if (p.isNotEmpty && seen.add(path.normalize(p).toLowerCase())) p,
    ];
    return Isolate.run(() => _search(root, all, query, limit));
  }
}
