import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'recent_files.dart' show RecentKind;
import 'team/team_chat.dart';
import 'team/team_widgets.dart';

/// ============================================================================
///  EVERY PROJECT, AND EVERY PROJECT'S THREAD
/// ============================================================================
///  The Root Folder is walked for project files (`*_project.json`) on a
///  background isolate - a file share answers slowly - and the list is kept
///  for a couple of minutes, so typing a search does not walk the share once
///  per key. Each project's chat is its thread in the team chat
///  (projectChannel, named by the project), so the messages searched are the
///  team chat's project threads - the same ones every CTS app sees.
/// ============================================================================

/// How deep under the Root Folder project files are looked for.
const kSearchDepth = 5;

/// One project found: its file, and its name as the project itself says.
typedef SearchProject = ({String path, String name});

/// A project's name from its file name, without `_project.json`.
String searchProjectName(String file) {
  final base = path.basename(file);
  const suffix = '_project.json';
  return base.toLowerCase().endsWith(suffix)
      ? base.substring(0, base.length - suffix.length).replaceAll('_', ' ')
      : path.basenameWithoutExtension(base);
}

/// [TEAM CHAT - PROJECTS]: the name a project's thread goes by - the
/// project's own name, else its file's.
String projectThreadName(String name, String file) =>
    name.trim().isNotEmpty ? name.trim() : searchProjectName(file);

/// Folders that never hold a project, skipped to keep the walk short.
const _skip = {'assets', 'devices', 'documentation', 'modules', 'build', 'chat'};

/// The project's own name: the first "name" in the file, which is the
/// project's (BuildingProject.toJson writes it near the top). Only the
/// start of the file is read.
String _nameIn(String file) {
  try {
    final raf = File(file).openSync();
    try {
      final head = String.fromCharCodes(raf.readSync(4096));
      final m = RegExp(r'"name"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(head);
      return m == null ? '' : m[1]!.replaceAll(r'\"', '"');
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return '';
  }
}

/// Every project under [root], to [kSearchDepth], with [extra] files added.
List<SearchProject> findProjects(String root, List<String> extra) {
  final files = <String>[];
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
        files.add(e.path);
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
  final seen = <String>{};
  final out = <SearchProject>[
    for (final f in [...files, ...extra])
      if (f.isNotEmpty &&
          File(f).existsSync() &&
          seen.add(path.normalize(f).toLowerCase()))
        (path: f, name: projectThreadName(_nameIn(f), f)),
  ];
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// What a search compares: lower case, spaces gone, so "bss103" finds
/// "BSS 103".
String _fold(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

bool _hit(String text, String query) => _fold(text).contains(_fold(query));

class ProjectSearch {
  ProjectSearch._();

  static List<SearchProject>? _projects;
  static String _key = '';
  static DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  /// Forgets the list of projects, so the next search walks the share again.
  static void refresh() => _projects = null;

  /// Every project under [root] (and [extra]), kept a couple of minutes.
  static Future<List<SearchProject>> projects(String root,
      {List<String> extra = const []}) async {
    final key = '$root|${extra.join('|')}';
    if (_projects == null ||
        _key != key ||
        DateTime.now().difference(_at) > const Duration(minutes: 2)) {
      _projects = await Isolate.run(() => findProjects(root, extra));
      _key = key;
      _at = DateTime.now();
    }
    return _projects!;
  }

  /// The names of the projects last found - for the team chat's "+", so a
  /// thread can be started for any project.
  static Iterable<String> get knownNames =>
      (_projects ?? const <SearchProject>[]).map((p) => p.name);
}

/// Opens a project the way the File menu does - asking about unsaved work
/// first. Set by the main window.
Future<void> Function(String file)? projectSearchOpenProject;

/// Every project, and every project's thread, in a dialog. [context] is the
/// main window's, where the team chat opens.
Future<void> showProjectSearch(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const ValueKey('chat_search_dialog'),
        insetPadding: const EdgeInsets.all(40),
        child: SizedBox(
          width: 820,
          height: 640,
          child: ProjectSearchPane(
            onDone: () => Navigator.of(ctx).pop(),
            openChat: (id) {
              final chat = Team.chat;
              if (chat == null || !chat.attached) return;
              chat.selectChannel(id, reopen: true);
              if (context.mounted) TeamChatPanel.instance.open(context);
            },
          ),
        ),
      ),
    );

/// Every project on the share - click to open it, or its Chat button for
/// its thread - and, when searching, the messages in every project thread.
class ProjectSearchPane extends StatefulWidget {
  /// Called after a result was opened - closes a dialog.
  final VoidCallback? onDone;

  /// Opens the team chat on a thread.
  final void Function(String channel) openChat;

  const ProjectSearchPane({super.key, this.onDone, required this.openChat});

  @override
  State<ProjectSearchPane> createState() => _ProjectSearchPaneState();
}

class _ProjectSearchPaneState extends State<ProjectSearchPane> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<SearchProject>? _projects;
  bool _busy = false;
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load({bool fresh = false}) async {
    final provider = context.read<AppStateProvider>();
    if (fresh) ProjectSearch.refresh();
    final run = ++_run;
    setState(() => _busy = true);
    final found = await ProjectSearch.projects(
      provider.effectiveRootFolder,
      extra: [
        provider.currentProjectPath,
        for (final r in provider.recentFiles[RecentKind.project]) r.file,
      ],
    );
    if (!mounted || run != _run) return;
    setState(() {
      _projects = found;
      _busy = false;
    });
  }

  bool _isOpen(AppStateProvider provider, String file) =>
      file.isNotEmpty &&
      provider.currentProjectPath.isNotEmpty &&
      path.equals(path.normalize(file).toLowerCase(),
          path.normalize(provider.currentProjectPath).toLowerCase());

  Future<void> _openProject(String file) async {
    final provider = context.read<AppStateProvider>();
    if (!_isOpen(provider, file)) await projectSearchOpenProject?.call(file);
    widget.onDone?.call();
  }

  void _openThread(String channel) {
    widget.onDone?.call();
    widget.openChat(channel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final all = _projects;
    final q = _query.text.trim();
    final chat = Team.chat;
    final chatOn = chat != null && chat.attached;
    final projects = all == null
        ? const <SearchProject>[]
        : [
            for (final p in all)
              if (q.isEmpty || _hit(p.name, q) || _hit(p.path, q)) p,
          ];
    final messages = !chatOn || q.isEmpty
        ? const <TeamMessage>[]
        : [
            for (final m in chat.messages.reversed)
              if (m.channel.startsWith('project:') &&
                  (_hit(m.text, q) ||
                      _hit(m.who, q) ||
                      _hit(m.user, q) ||
                      _hit(chat.labelOf(m.channel), q)))
                m,
          ].take(300).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('chat_search_field'),
                  controller: _query,
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: chatOn
                        ? 'Search every project and project chat'
                        : 'Search every project',
                    border: const OutlineInputBorder(),
                    suffixIcon: _busy
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 200),
                        () => setState(() {}));
                  },
                ),
              ),
              IconButton(
                tooltip: 'Look for new projects on the share',
                icon: const Icon(Icons.refresh),
                onPressed: () => _load(fresh: true),
              ),
              if (widget.onDone != null)
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: widget.onDone,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: all == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  key: const ValueKey('chat_search_results'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _heading(context,
                        'PROJECTS (${projects.length} of ${all.length})'),
                    if (projects.isEmpty)
                      _none(context, 'No project names match.'),
                    for (final p in projects.take(q.isEmpty ? 100 : 300))
                      ListTile(
                        key: ValueKey('chat_search_project_${p.path}'),
                        dense: true,
                        leading: const Icon(Icons.domain, size: 20),
                        title: _marked(p.name, q, theme),
                        subtitle: Text(p.path,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: muted)),
                        trailing: chatOn ? _chatButton(chat, p) : null,
                        onTap: () => _openProject(p.path),
                      ),
                    if (q.isNotEmpty && chatOn) ...[
                      const SizedBox(height: 8),
                      _heading(context, 'MESSAGES (${messages.length})'),
                      if (messages.isEmpty)
                        _none(context, 'No project chat says that.'),
                      for (final m in messages)
                        ListTile(
                          key: ValueKey('chat_search_message_${m.id}'),
                          dense: true,
                          leading: const Icon(Icons.forum_outlined, size: 20),
                          title: _marked(m.text, q, theme),
                          subtitle: Text(
                            '${chat.labelOf(m.channel)} · ${m.who} · '
                            '${_when(m.at)}',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: muted),
                          ),
                          onTap: () => _openThread(m.channel),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  /// The project's thread: how many messages, and a click to open it.
  Widget _chatButton(TeamChat chat, SearchProject p) {
    final id = projectChannel(p.name);
    final n = chat.countIn(id);
    return TextButton.icon(
      key: ValueKey('chat_search_thread_${p.path}'),
      icon: Icon(n > 0 ? Icons.forum_outlined : Icons.add_comment_outlined,
          size: 18),
      label: Text(n > 0 ? 'Chat ($n)' : 'Chat'),
      onPressed: () => _openThread(id),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _none(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );

  static String _when(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')} '
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  /// [text] with the first place [q] appears drawn bold in the accent.
  static Widget _marked(String text, String q, ThemeData theme) {
    final i = q.isEmpty ? -1 : text.toLowerCase().indexOf(q.toLowerCase());
    if (i < 0) return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text.substring(0, i)),
        TextSpan(
          text: text.substring(i, i + q.length),
          style: TextStyle(
              fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
        ),
        TextSpan(text: text.substring(i + q.length)),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
