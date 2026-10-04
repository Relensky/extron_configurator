import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_link.dart';
import 'project_chat.dart';

/// The project chat: channels, the conversation, and a box to type in. The
/// same widget in the slide-out, the floating panel and the separate window.
class ChatView extends StatefulWidget {
  final ChatLink link;

  /// Whatever the container wants in the title bar - the floating panel's
  /// drag handle wraps it.
  final Widget Function(Widget title)? wrapHeader;

  const ChatView({super.key, required this.link, this.wrapHeader});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  bool _showPeople = false;
  String _error = '';

  /// The '@word' being typed, for the suggestion list.
  String? _mentionQuery;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTyping);
    widget.link.snapshot.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.link.snapshot.removeListener(_scrollToEnd);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _onTyping() {
    final sel = _text.selection;
    final upTo = sel.isValid ? _text.text.substring(0, sel.baseOffset) : _text.text;
    final m = RegExp(r'@([A-Za-z0-9._-]*)$').firstMatch(upTo);
    final q = m?.group(1);
    if (q != _mentionQuery) setState(() => _mentionQuery = q);
  }

  void _insertMention(ChatPerson p) {
    final sel = _text.selection;
    final pos = sel.isValid ? sel.baseOffset : _text.text.length;
    final before = _text.text.substring(0, pos);
    final after = _text.text.substring(pos);
    final start = before.lastIndexOf('@');
    final next = '${before.substring(0, start)}@${p.login} ';
    _text.value = TextEditingValue(
      text: '$next$after',
      selection: TextSelection.collapsed(offset: next.length),
    );
    _focus.requestFocus();
  }

  Future<void> _send(ChatSnapshot snap) async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    final error = await widget.link.post(snap.channel, text);
    if (mounted) setState(() => _error = error);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatSnapshot?>(
      valueListenable: widget.link.snapshot,
      builder: (context, snap, _) {
        if (snap == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, snap),
            const Divider(height: 1),
            Expanded(
              child: !snap.attached
                  ? _notAttached(context)
                  : _showPeople
                      ? _people(context, snap)
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 150, child: _channels(context, snap)),
                            const VerticalDivider(width: 1),
                            Expanded(child: _conversation(context, snap)),
                          ],
                        ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, ChatSnapshot snap) {
    final theme = Theme.of(context);
    final title = Row(
      children: [
        const Icon(Icons.forum_outlined, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            snap.project.isEmpty ? 'Project chat' : 'Chat - ${snap.project}',
            style: theme.textTheme.titleSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final wrapped = widget.wrapHeader?.call(title) ?? title;
    IconButton mode(ChatMode m, IconData icon) => IconButton(
          key: ValueKey('chat_mode_${m.name}'),
          tooltip: m.label,
          visualDensity: VisualDensity.compact,
          isSelected: snap.mode == m && (m == ChatMode.window) == widget.link.inWindow,
          icon: Icon(icon, size: 18),
          onPressed: () => widget.link.setMode(m),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(child: wrapped),
          IconButton(
            key: const ValueKey('chat_people'),
            tooltip: 'Who has opened this job',
            visualDensity: VisualDensity.compact,
            isSelected: _showPeople,
            icon: const Icon(Icons.people_outline, size: 18),
            onPressed: () => setState(() => _showPeople = !_showPeople),
          ),
          mode(ChatMode.slideOut, Icons.view_sidebar_outlined),
          mode(ChatMode.floating, Icons.picture_in_picture_alt_outlined),
          mode(ChatMode.window, Icons.open_in_new),
          IconButton(
            key: const ValueKey('chat_close'),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: widget.link.close,
          ),
        ],
      ),
    );
  }

  Widget _notAttached(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'Open a saved project to chat about it. The conversation is kept '
            'in a folder beside the project file, so everybody who opens the '
            'job sees it.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );

  Widget _channels(BuildContext context, ChatSnapshot snap) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 2),
          child: Text(text,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        );
    Widget tile(ChatChannel c) {
      final here = c.id == snap.hereRoomChannel || c.id == snap.hereTabChannel;
      return ListTile(
        key: ValueKey('chat_channel_${c.id}'),
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.only(left: 10, right: 6),
        selected: c.id == snap.channel,
        title: Text(
          c.label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: c.unread > 0 ? FontWeight.bold : null,
            fontStyle: here ? FontStyle.italic : null,
          ),
        ),
        trailing: c.mentions > 0
            ? Badge(
                backgroundColor: theme.colorScheme.error,
                label: Text('@${c.mentions}'),
              )
            : c.unread > 0
                ? Badge(label: Text('${c.unread}'))
                : null,
        onTap: () => widget.link.select(c.id),
      );
    }

    final rooms = snap.channels.where((c) => c.kind == 'room').toList();
    final tabs = snap.channels.where((c) => c.kind == 'tab').toList();
    return ListView(
      children: [
        for (final c in snap.channels.where((c) => c.kind == 'general')) tile(c),
        if (rooms.isNotEmpty) ...[heading('ROOMS'), for (final c in rooms) tile(c)],
        if (tabs.isNotEmpty) ...[heading('TABS'), for (final c in tabs) tile(c)],
      ],
    );
  }

  Widget _conversation(BuildContext context, ChatSnapshot snap) {
    final theme = Theme.of(context);
    final shown = snap.messages.where((m) => m.channel == snap.channel).toList();
    final suggestions = _mentionQuery == null
        ? const <ChatPerson>[]
        : snap.people
            .where((p) =>
                p.login.toLowerCase() != snap.me.toLowerCase() &&
                (p.login.toLowerCase().startsWith(_mentionQuery!.toLowerCase()) ||
                    p.name.toLowerCase().contains(_mentionQuery!.toLowerCase())))
            .take(6)
            .toList();
    final label = snap.channels
        .firstWhere((c) => c.id == snap.channel,
            orElse: () => const ChatChannel(id: '', label: '', kind: ''))
        .label;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Nothing said about $label yet. Type @ to name somebody '
                      '- they get a notice of their own.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: shown.length,
                  itemBuilder: (context, i) => _MessageTile(
                    message: shown[i],
                    me: snap.me,
                    people: snap.people,
                    showDay: i == 0 || !_sameDay(shown[i].at, shown[i - 1].at),
                  ),
                ),
        ),
        if (suggestions.isNotEmpty)
          Material(
            elevation: 2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in suggestions)
                  ListTile(
                    key: ValueKey('chat_mention_${p.login}'),
                    dense: true,
                    leading: const Icon(Icons.alternate_email, size: 18),
                    title: Text(p.label),
                    onTap: () => _insertMention(p),
                  ),
              ],
            ),
          ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
            child: Text(_error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    // Enter sends; Shift+Enter is a new line.
                    const SingleActivator(LogicalKeyboardKey.enter): () {
                      if (suggestions.isNotEmpty) {
                        _insertMention(suggestions.first);
                      } else {
                        _send(snap);
                      }
                    },
                  },
                  child: TextField(
                    key: const ValueKey('chat_input'),
                    controller: _text,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 5,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Message $label - @ to name somebody',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                key: const ValueKey('chat_send'),
                tooltip: 'Send (Enter)',
                icon: const Icon(Icons.send, size: 18),
                onPressed: () => _send(snap),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _people(BuildContext context, ChatSnapshot snap) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Text(
            'Everybody who has opened this job, or is in its history. Type '
            '@ and their login to name them in a message.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final p in snap.people)
          ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              child: Text(_initials(p.name.isEmpty ? p.login : p.name)),
            ),
            title: Text(p.label),
            subtitle: Text([
              if (p.email.isNotEmpty) p.email,
              if (p.machine.isNotEmpty) p.machine,
              if (p.lastSeen != null) 'last opened ${_stamp(p.lastSeen!)}',
            ].join('  ·  ')),
          ),
      ],
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _initials(String s) {
  final parts = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return parts.take(2).map((w) => w[0].toUpperCase()).join();
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _time(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

String _day(DateTime at) {
  final now = DateTime.now();
  if (_sameDay(at, now)) return 'Today';
  if (_sameDay(at, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  return '${at.day} ${_months[at.month - 1]} ${at.year}';
}

String _stamp(DateTime at) => '${_day(at)} ${_time(at)}';

class _MessageTile extends StatelessWidget {
  final ChatMessage message;
  final String me;
  final List<ChatPerson> people;
  final bool showDay;

  const _MessageTile({
    required this.message,
    required this.me,
    required this.people,
    required this.showDay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final forMe = message.mentionsUser(me);
    final mine = message.user.toLowerCase() == me.toLowerCase();
    final where = [
      if (message.room.isNotEmpty) message.room,
      if (message.tab.isNotEmpty) message.tab,
    ].join(', ');

    // @logins drawn bold in the accent; the whole message bold when it is
    // for me.
    final names = {for (final p in people) p.login.toLowerCase(): p};
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in RegExp(r'@([A-Za-z0-9._-]+)').allMatches(message.text)) {
      final p = names[m.group(1)!.toLowerCase()];
      if (p == null) continue;
      spans.add(TextSpan(text: message.text.substring(last, m.start)));
      final isMe = p.login.toLowerCase() == me.toLowerCase();
      spans.add(TextSpan(
        text: '@${p.name.trim().isEmpty ? p.login : p.name.trim()}',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: isMe ? scheme.error : scheme.primary,
        ),
      ));
      last = m.end;
    }
    spans.add(TextSpan(text: message.text.substring(last)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showDay)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_day(message.at),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          decoration: BoxDecoration(
            color: forMe
                ? scheme.errorContainer.withValues(alpha: 0.6)
                : mine
                    ? scheme.primaryContainer.withValues(alpha: 0.35)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: forMe
                ? Border(left: BorderSide(color: scheme.error, width: 4))
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (forMe) ...[
                    Icon(Icons.alternate_email, size: 14, color: scheme.error),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      message.name.trim().isEmpty ||
                              message.name.trim().toLowerCase() ==
                                  message.user.toLowerCase()
                          ? message.user
                          : '${message.name.trim()} (${message.user})',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(_time(message.at),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (where.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text('· $where',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              SelectableText.rich(
                TextSpan(children: spans),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: forMe ? FontWeight.bold : null,
                  color: forMe ? scheme.onErrorContainer : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
