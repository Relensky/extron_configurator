import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../recent_files.dart' show RecentKind;
import 'chat_layer.dart';
import 'chat_search.dart';
import 'project_chat.dart';

/// Opens a project the way the File menu does - asking about unsaved work
/// first. Set by the main window.
Future<void> Function(String file)? chatSearchOpenProject;

/// Search every chat and every project, in a dialog.
Future<void> showChatSearch(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const ValueKey('chat_search_dialog'),
        insetPadding: const EdgeInsets.all(40),
        child: SizedBox(
          width: 820,
          height: 640,
          child: ChatSearchPane(onDone: () => Navigator.of(ctx).pop()),
        ),
      ),
    );

/// Searches every chat - Everyone and every project's - and every project on
/// the share. Clicking a project opens it; clicking a message opens the chat
/// on its channel, opening its project first when it is not the one open.
class ChatSearchPane extends StatefulWidget {
  /// Called after a result was opened - closes a dialog.
  final VoidCallback? onDone;

  const ChatSearchPane({super.key, this.onDone});

  @override
  State<ChatSearchPane> createState() => _ChatSearchPaneState();
}

class _ChatSearchPaneState extends State<ChatSearchPane> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  SearchResults? _results;
  bool _busy = false;
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search({bool fresh = false}) async {
    final provider = context.read<AppStateProvider>();
    if (fresh) ChatSearch.refresh();
    final run = ++_run;
    setState(() => _busy = true);
    final results = await ChatSearch.search(
      provider.effectiveRootFolder,
      _query.text,
      extra: [
        provider.currentProjectPath,
        for (final r in provider.recentFiles[RecentKind.project]) r.file,
      ],
    );
    if (!mounted || run != _run) return;
    setState(() {
      _results = results;
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
    if (!_isOpen(provider, file)) await chatSearchOpenProject?.call(file);
    widget.onDone?.call();
  }

  Future<void> _openMessage(SearchMessage hit) async {
    final provider = context.read<AppStateProvider>();
    if (hit.projectPath.isNotEmpty && !_isOpen(provider, hit.projectPath)) {
      await chatSearchOpenProject?.call(hit.projectPath);
      if (!_isOpen(provider, hit.projectPath)) return; // backed out
    }
    widget.onDone?.call();
    openProjectChat(provider, channel: hit.message.channel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final r = _results;
    final q = _query.text.trim();
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
                    hintText: 'Search every chat and project',
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
                  onChanged: _changed,
                  onSubmitted: (_) => _search(),
                ),
              ),
              IconButton(
                tooltip: 'Look for new projects on the share',
                icon: const Icon(Icons.refresh),
                onPressed: () => _search(fresh: true),
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
          child: r == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  key: const ValueKey('chat_search_results'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _heading(context,
                        'PROJECTS (${r.projects.length} of ${r.scanned})'),
                    if (r.projects.isEmpty)
                      _none(context, 'No project names match.'),
                    for (final p in r.projects.take(q.isEmpty ? 50 : 200))
                      ListTile(
                        key: ValueKey('chat_search_project_${p.path}'),
                        dense: true,
                        leading: const Icon(Icons.domain, size: 20),
                        title: _marked(p.name, q, theme),
                        subtitle: Text(p.path,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: muted)),
                        onTap: () => _openProject(p.path),
                      ),
                    if (q.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _heading(context, 'MESSAGES (${r.messages.length})'),
                      if (r.messages.isEmpty)
                        _none(context, 'No message says that.'),
                      for (final hit in r.messages)
                        ListTile(
                          key: ValueKey('chat_search_message_${hit.message.id}'),
                          dense: true,
                          leading: Icon(
                            hit.projectPath.isEmpty
                                ? Icons.public
                                : Icons.forum_outlined,
                            size: 20,
                          ),
                          title: _marked(hit.message.text, q, theme),
                          subtitle: Text(
                            '${hit.projectName} · ${_channel(hit.message)} · '
                            '${hit.message.who} · ${_when(hit.message.at)}',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: muted),
                          ),
                          onTap: () => _openMessage(hit),
                        ),
                    ],
                  ],
                ),
        ),
      ],
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

  static String _channel(ChatMessage m) {
    if (m.channel == kChatEveryone) return 'Everyone';
    if (m.channel == kChatGeneral) return 'General';
    if (m.channel.startsWith('room:')) return 'a room';
    if (m.channel.startsWith('tab:')) {
      return m.tab.isEmpty ? 'a tab' : m.tab;
    }
    return m.channel;
  }

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
