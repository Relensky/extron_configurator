import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import '../file_dialogs.dart';
import 'chat_link.dart';
import 'clipboard_image.dart';
import 'gif_search.dart';
import 'project_chat.dart';

/// The emoji offered first when reacting, and in the composer.
const List<String> kQuickReactions = ['👍', '❤️', '😂', '🎉', '😮', '👀'];

/// Every emoji the pickers offer.
const List<String> kChatEmoji = [
  '👍', '👎', '❤️', '😂', '🎉', '😮', '😢', '🙏', '✅', '❌', '👀', '🔥',
  '💯', '👏', '🙌', '🤔', '😅', '😎', '🚀', '⚠️', '📌', '💡', '🛠️', '☕',
];

/// The project chat: channels, the conversation, and a box to type in. The
/// same widget in the slide-out, the floating panel and the separate window.
class ChatView extends StatefulWidget {
  final ChatLink link;

  /// Whatever the container wants in the title bar - the floating panel's
  /// drag handle wraps it.
  final Widget Function(Widget title)? wrapHeader;

  /// Buttons the container adds to the title bar - fill the screen.
  final List<Widget> actions;

  /// Opens the search of every chat and project, from the search bar. Null
  /// where there is none (the separate window).
  final VoidCallback? onSearchAll;

  const ChatView({
    super.key,
    required this.link,
    this.wrapHeader,
    this.actions = const [],
    this.onSearchAll,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searching = false;
  bool _showPeople = false;
  String _error = '';

  /// A picture waiting to go with the next message: pasted, or picked.
  String _pending = '';

  /// The message being edited, and its box.
  String _editingId = '';
  final TextEditingController _edit = TextEditingController();

  /// The '@word' being typed, for the suggestion list.
  String? _mentionQuery;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTyping);
    _search.addListener(() => setState(() {}));
    widget.link.snapshot.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.link.snapshot.removeListener(_scrollToEnd);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _edit.dispose();
    super.dispose();
  }

  /// What the list last showed, so only a new message or another channel
  /// moves it - not every refresh while somebody is reading back.
  String _shownKey = '';

  void _scrollToEnd() {
    final snap = widget.link.snapshot.value;
    if (snap == null) return;
    final last = snap.messages.where((m) => m.channel == snap.channel).lastOrNull;
    final key = '${snap.channel}|${last?.id ?? ''}';
    if (key == _shownKey) return;
    final sameChannel = _shownKey.startsWith('${snap.channel}|');
    _shownKey = key;
    // Reading back in the same channel: stay put unless it is your own post.
    final reading = sameChannel &&
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.position.pixels > 80 &&
        last?.user.toLowerCase() != snap.me.toLowerCase();
    if (reading) return;
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

  /// [text] put where the cursor is in the message box.
  void _insertText(String text) {
    final sel = _text.selection;
    final pos = sel.isValid ? sel.baseOffset : _text.text.length;
    final end = sel.isValid ? sel.extentOffset : pos;
    final next = _text.text.replaceRange(pos, end, text);
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: pos + text.length),
    );
    _focus.requestFocus();
  }

  /// Picks a picture to send with the next message.
  Future<void> _pickImage() async {
    final picked = await pickFilesCompat(
      dialogTitle: 'A picture to send',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'],
    );
    final file = picked?.files.singleOrNull?.path;
    if (file == null || !mounted) return;
    setState(() => _pending = file);
    _focus.requestFocus();
  }

  /// Ctrl+V: a screenshot or a copied picture on the clipboard waits to be
  /// sent. Text pastes as it always did.
  Future<void> _pasteImage() async {
    final file = await clipboardImageFile();
    if (file == null || !mounted) return;
    setState(() => _pending = file);
  }

  /// Picks a GIF and sends it straight away.
  Future<void> _pickGif(ChatSnapshot snap) async {
    final file = await pickGif(context, snap.gifKey);
    if (file == null || !mounted) return;
    final error = await widget.link.post(snap.channel, '', image: file);
    if (mounted) setState(() => _error = error);
  }

  /// A message that could not be sent goes back in the box, not nowhere.
  void _restoreIfFailed(String error, String text) {
    if (!mounted || error.isEmpty || text.isEmpty || _text.text.isNotEmpty) {
      return;
    }
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _confirmDelete(ChatMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this message?'),
        content: Text(
          m.text.isEmpty ? 'The picture is taken out of the chat for everyone.'
              : '"${m.text.length > 120 ? '${m.text.substring(0, 119)}…' : m.text}"'
                  '\n\nIt is taken out of the chat for everyone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const ValueKey('chat_delete_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final error = await widget.link.deleteMessage(m.id);
    if (mounted) setState(() => _error = error);
  }

  void _startEdit(ChatMessage m) {
    setState(() {
      _editingId = m.id;
      _edit.value = TextEditingValue(
        text: m.text,
        selection: TextSelection.collapsed(offset: m.text.length),
      );
    });
  }

  Future<void> _saveEdit(ChatMessage m) async {
    final text = _edit.text.trim();
    setState(() => _editingId = '');
    if (text == m.text.trim()) return;
    final error = await widget.link.editMessage(m.id, text);
    if (mounted) setState(() => _error = error);
  }

  Future<void> _react(ChatMessage m, String emoji) async {
    final error = await widget.link.react(m.id, emoji);
    if (mounted && error.isNotEmpty) setState(() => _error = error);
  }

  Future<void> _send(ChatSnapshot snap) async {
    final text = _text.text.trim();
    final image = _pending;
    if (text.isEmpty && image.isEmpty) return;
    _text.clear();
    setState(() => _pending = '');
    final error = await widget.link.post(
      snap.channel,
      text,
      image: image.isEmpty ? null : image,
    );
    if (mounted) {
      setState(() {
        _error = error;
        if (error.isNotEmpty && image.isNotEmpty) _pending = image;
      });
    }
    _restoreIfFailed(error, text);
    if (mounted) _focus.requestFocus();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) _search.clear();
    });
    if (_searching) _searchFocus.requestFocus();
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
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _searching
                  ? _searchBar(context, snap)
                  : const SizedBox(width: double.infinity),
            ),
            const Divider(height: 1),
            Expanded(
              child: !snap.attached
                  ? _notAttached(context)
                  : _showPeople
                      ? _people(context, snap)
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 160, child: _channels(context, snap)),
                            VerticalDivider(
                              width: 1,
                              color: Theme.of(context).colorScheme.outlineVariant,
                            ),
                            Expanded(child: _conversation(context, snap)),
                          ],
                        ),
            ),
          ],
        );
      },
    );
  }

  String _channelLabel(ChatSnapshot snap) => snap.channels
      .firstWhere((c) => c.id == snap.channel,
          orElse: () => const ChatChannel(id: '', label: '', kind: ''))
      .label;

  Widget _header(BuildContext context, ChatSnapshot snap) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.forum_outlined, size: 17, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                snap.project.isEmpty ? 'Chat' : snap.project,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
              if (_channelLabel(snap).isNotEmpty)
                Text(
                  '# ${_channelLabel(snap)}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
    final wrapped = widget.wrapHeader?.call(title) ?? title;
    Widget icon({
      required Key key,
      required String tip,
      required IconData data,
      required VoidCallback onPressed,
      bool selected = false,
    }) => IconButton(
      key: key,
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      isSelected: selected,
      icon: Icon(data, size: 19),
      onPressed: onPressed,
    );
    final current = widget.link.inWindow ? ChatMode.window : snap.mode;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(child: wrapped),
          icon(
            key: const ValueKey('chat_search_toggle'),
            tip: 'Search this conversation',
            data: Icons.search,
            selected: _searching,
            onPressed: _toggleSearch,
          ),
          icon(
            key: const ValueKey('chat_people'),
            tip: 'Who has opened this job',
            data: Icons.people_outline,
            selected: _showPeople,
            onPressed: () => setState(() => _showPeople = !_showPeople),
          ),
          ...widget.actions,
          PopupMenuButton<ChatMode>(
            key: const ValueKey('chat_layout'),
            tooltip: 'Where the chat sits',
            icon: const Icon(Icons.dashboard_customize_outlined, size: 19),
            onSelected: widget.link.setMode,
            itemBuilder: (_) => [
              for (final (m, data) in const [
                (ChatMode.slideOut, Icons.view_sidebar_outlined),
                (ChatMode.top, Icons.border_top),
                (ChatMode.bottom, Icons.border_bottom),
                (ChatMode.floating, Icons.picture_in_picture_alt_outlined),
                (ChatMode.window, Icons.open_in_new),
              ])
                PopupMenuItem(
                  key: ValueKey('chat_mode_${m.name}'),
                  value: m,
                  child: Row(
                    children: [
                      Icon(data, size: 18),
                      const SizedBox(width: 12),
                      Expanded(child: Text(m.label)),
                      if (m == current)
                        Icon(Icons.check, size: 16, color: scheme.primary),
                    ],
                  ),
                ),
            ],
          ),
          icon(
            key: const ValueKey('chat_close'),
            tip: 'Close',
            data: Icons.close,
            onPressed: widget.link.close,
          ),
        ],
      ),
    );
  }

  Widget _searchBar(BuildContext context, ChatSnapshot snap) {
    final scheme = Theme.of(context).colorScheme;
    final q = _search.text.trim().toLowerCase();
    final hits = q.isEmpty
        ? 0
        : snap.messages
            .where((m) => m.channel == snap.channel && _matches(m, q))
            .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _toggleSearch,
        },
        child: TextField(
          key: const ValueKey('chat_search_bar'),
          controller: _search,
          focusNode: _searchFocus,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            hintText: 'Search this conversation',
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (q.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '$hits found',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                if (widget.onSearchAll != null)
                  TextButton(
                    key: const ValueKey('chat_search'),
                    onPressed: widget.onSearchAll,
                    child: const Text('All chats'),
                  ),
                IconButton(
                  tooltip: 'Close the search',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: _toggleSearch,
                ),
              ],
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  bool _matches(ChatMessage m, String q) =>
      m.text.toLowerCase().contains(q) || m.who.toLowerCase().contains(q);

  Widget _notAttached(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'The shared chat is kept in the chat folder in the Root Folder, which '
            'cannot be reached right now. Open a saved project to chat about '
            'it - its conversation is kept beside the project file.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );

  Widget _channels(BuildContext context, ChatSnapshot snap) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 4),
          child: Text(text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.8,
              )),
        );
    Widget tile(ChatChannel c) {
      final here = c.id == snap.hereRoomChannel || c.id == snap.hereTabChannel;
      final selected = c.id == snap.channel;
      final bold = c.unread > 0 || selected;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: ValueKey('chat_channel_${c.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => widget.link.select(c.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Text('#',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c.label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: bold ? FontWeight.w700 : null,
                        fontStyle: here ? FontStyle.italic : null,
                        color: selected ? scheme.onSecondaryContainer : null,
                      ),
                    ),
                  ),
                  if (c.mentions > 0)
                    Badge(
                      backgroundColor: scheme.error,
                      label: Text('@${c.mentions}'),
                    )
                  else if (c.unread > 0)
                    Badge(label: Text('${c.unread}')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final rooms = snap.channels.where((c) => c.kind == 'room').toList();
    final tabs = snap.channels.where((c) => c.kind == 'tab').toList();
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      children: [
        for (final c in snap.channels.where((c) => c.kind == 'everyone'))
          tile(c),
        if (snap.channels.any((c) => c.kind == 'general'))
          heading('THIS PROJECT'),
        for (final c in snap.channels.where((c) => c.kind == 'general')) tile(c),
        if (rooms.isNotEmpty) ...[heading('ROOMS'), for (final c in rooms) tile(c)],
        if (tabs.isNotEmpty) ...[heading('TABS'), for (final c in tabs) tile(c)],
      ],
    );
  }

  Widget _conversation(BuildContext context, ChatSnapshot snap) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = _searching ? _search.text.trim().toLowerCase() : '';
    final all = snap.messages.where((m) => m.channel == snap.channel).toList();
    final shown = q.isEmpty ? all : all.where((m) => _matches(m, q)).toList();
    final suggestions = _mentionQuery == null
        ? const <ChatPerson>[]
        : snap.people
            .where((p) =>
                p.login.toLowerCase() != snap.me.toLowerCase() &&
                (p.login.toLowerCase().startsWith(_mentionQuery!.toLowerCase()) ||
                    p.name.toLowerCase().contains(_mentionQuery!.toLowerCase())))
            .take(6)
            .toList();
    final label = _channelLabel(snap);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          q.isEmpty ? Icons.chat_bubble_outline : Icons.search_off,
                          size: 36,
                          color: scheme.outline,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          q.isEmpty
                              ? 'Nothing said in #$label yet. Type @ to name '
                                    'somebody - they get a notice of their own.'
                              : 'Nothing here mentions "${_search.text.trim()}".',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final m = shown[i];
                    final prev = i == 0 ? null : shown[i - 1];
                    final newDay = prev == null || !_sameDay(m.at, prev.at);
                    // Close runs from one person read as one block.
                    final grouped = !newDay &&
                        q.isEmpty &&
                        prev.user.toLowerCase() == m.user.toLowerCase() &&
                        m.at.difference(prev.at).inMinutes < 5;
                    final mine = m.user.toLowerCase() == snap.me.toLowerCase();
                    return _MessageTile(
                      key: ValueKey('chat_message_${m.id}'),
                      message: m,
                      me: snap.me,
                      people: snap.people,
                      showDay: newDay,
                      grouped: grouped,
                      highlight: q,
                      avatar: snap.avatars[m.user] ?? '',
                      imageRoot: m.channel == kChatEveryone
                          ? snap.everyoneFolder
                          : snap.folder,
                      editing: _editingId == m.id,
                      editController: _edit,
                      onSaveEdit: () => _saveEdit(m),
                      onCancelEdit: () => setState(() => _editingId = ''),
                      onReact: (e) => _react(m, e),
                      onEdit: mine ? () => _startEdit(m) : null,
                      onDelete: mine ? () => _confirmDelete(m) : null,
                    );
                  },
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
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(_error,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          ),
        _composer(context, snap, suggestions, label),
      ],
    );
  }

  Widget _composer(
    BuildContext context,
    ChatSnapshot snap,
    List<ChatPerson> suggestions,
    String label,
  ) {
    final scheme = Theme.of(context).colorScheme;
    Widget tool(Key key, String tip, IconData icon, VoidCallback onPressed) =>
        IconButton(
          key: key,
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          onPressed: onPressed,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      key: const ValueKey('chat_pending_image'),
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(_pending),
                        height: 90,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox(
                          height: 40,
                          child: Text('(picture)'),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -8,
                      top: -8,
                      child: IconButton.filledTonal(
                        tooltip: 'Do not send the picture',
                        visualDensity: VisualDensity.compact,
                        iconSize: 14,
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _pending = ''),
                      ),
                    ),
                  ],
                ),
              ),
            CallbackShortcuts(
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
              child: Focus(
                // Ctrl+V still pastes text; a picture on the clipboard is
                // picked up beside it.
                onKeyEvent: (_, event) {
                  final keys = HardwareKeyboard.instance;
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.keyV &&
                      (keys.isControlPressed || keys.isMetaPressed)) {
                    _pasteImage();
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: const ValueKey('chat_input'),
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Message #$label',
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 4),
                tool(const ValueKey('chat_attach_image'), 'Add a picture',
                    Icons.add_photo_alternate_outlined, _pickImage),
                tool(const ValueKey('chat_gif'), 'Send a GIF',
                    Icons.gif_box_outlined, () => _pickGif(snap)),
                _EmojiButton(
                  key: const ValueKey('chat_emoji'),
                  tooltip: 'Add an emoji',
                  icon: Icons.emoji_emotions_outlined,
                  onPicked: _insertText,
                ),
                tool(const ValueKey('chat_mention'), 'Name somebody',
                    Icons.alternate_email, () => _insertText('@')),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: IconButton.filled(
                    key: const ValueKey('chat_send'),
                    tooltip: 'Send (Enter)',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    onPressed: () => _send(snap),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
            leading: _ChatAvatar(
              file: snap.avatars[p.login] ?? '',
              name: p.name.isEmpty ? p.login : p.name,
              radius: 15,
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

/// A button that opens a small grid of emoji and hands back the one picked.
class _EmojiButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final ValueChanged<String> onPicked;
  final double size;

  const _EmojiButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPicked,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: tooltip,
      icon: Icon(icon, size: size, color: scheme.onSurfaceVariant),
      padding: EdgeInsets.zero,
      onSelected: onPicked,
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 6 * 38,
            child: Wrap(
              children: [
                for (final e in kChatEmoji)
                  InkWell(
                    key: ValueKey('chat_emoji_$e'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => Navigator.of(context).pop(e),
                    child: SizedBox(
                      width: 38,
                      height: 36,
                      child: Center(
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageTile extends StatefulWidget {
  final ChatMessage message;
  final String me;
  final List<ChatPerson> people;
  final bool showDay;

  /// Another message by the same person moments before: no name line.
  final bool grouped;

  /// What the search bar is looking for, drawn highlighted. '' for nothing.
  final String highlight;

  /// The writer's picture on this computer, or ''.
  final String avatar;

  /// The chat folder a picture with the message is kept under.
  final String imageRoot;

  final bool editing;
  final TextEditingController editController;
  final VoidCallback onSaveEdit;
  final VoidCallback onCancelEdit;
  final ValueChanged<String> onReact;

  /// Offered on this person's own messages.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _MessageTile({
    super.key,
    required this.message,
    required this.me,
    required this.people,
    required this.showDay,
    required this.grouped,
    required this.highlight,
    this.avatar = '',
    this.imageRoot = '',
    required this.editing,
    required this.editController,
    required this.onSaveEdit,
    required this.onCancelEdit,
    required this.onReact,
    this.onEdit,
    this.onDelete,
  });

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  bool _hover = false;

  /// [text] with @names in the accent and [highlight] marked.
  List<InlineSpan> _spans(String text, ColorScheme scheme) {
    final names = {for (final p in widget.people) p.login.toLowerCase(): p};
    final out = <InlineSpan>[];
    void plain(String s) {
      final q = widget.highlight;
      if (q.isEmpty || s.isEmpty) {
        out.add(TextSpan(text: s));
        return;
      }
      final lower = s.toLowerCase();
      var at = 0;
      while (true) {
        final i = lower.indexOf(q, at);
        if (i < 0) break;
        out.add(TextSpan(text: s.substring(at, i)));
        out.add(TextSpan(
          text: s.substring(i, i + q.length),
          style: TextStyle(
            backgroundColor: scheme.tertiaryContainer,
            color: scheme.onTertiaryContainer,
          ),
        ));
        at = i + q.length;
      }
      out.add(TextSpan(text: s.substring(at)));
    }

    var last = 0;
    for (final m in RegExp(r'@([A-Za-z0-9._-]+)').allMatches(text)) {
      final p = names[m.group(1)!.toLowerCase()];
      if (p == null) continue;
      plain(text.substring(last, m.start));
      final isMe = p.login.toLowerCase() == widget.me.toLowerCase();
      out.add(TextSpan(
        text: '@${p.name.trim().isEmpty ? p.login : p.name.trim()}',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: isMe ? scheme.error : scheme.primary,
          backgroundColor: (isMe ? scheme.error : scheme.primary)
              .withValues(alpha: 0.08),
        ),
      ));
      last = m.end;
    }
    plain(text.substring(last));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final message = widget.message;
    final forMe = message.mentionsUser(widget.me);
    final where = [
      if (message.room.isNotEmpty) message.room,
      if (message.tab.isNotEmpty) message.tab,
    ].join(', ');
    final muted = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.grouped)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    message.who,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_time(message.at), style: muted),
                if (where.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('· $where',
                        overflow: TextOverflow.ellipsis, style: muted),
                  ),
                ],
              ],
            ),
          ),
        if (widget.editing)
          _EditBox(
            controller: widget.editController,
            onSave: widget.onSaveEdit,
            onCancel: widget.onCancelEdit,
          )
        else if (message.text.isNotEmpty)
          SelectableText.rich(
            TextSpan(children: [
              ..._spans(message.text, scheme),
              if (message.editedAt != null)
                TextSpan(
                  text: '  (edited)',
                  style: muted?.copyWith(fontStyle: FontStyle.italic),
                ),
            ]),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          )
        else if (message.editedAt != null)
          Text('(edited)', style: muted?.copyWith(fontStyle: FontStyle.italic)),
        if (message.image.isNotEmpty && widget.imageRoot.isNotEmpty)
          _ChatPicture(file: path.join(widget.imageRoot, message.image)),
        if (message.reactions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final r in message.reactions.entries)
                  _ReactionChip(
                    emoji: r.key,
                    who: r.value,
                    mine: r.value.any(
                        (u) => u.toLowerCase() == widget.me.toLowerCase()),
                    onTap: () => widget.onReact(r.key),
                  ),
              ],
            ),
          ),
      ],
    );

    final row = Container(
      margin: const EdgeInsets.symmetric(horizontal: 6),
      padding: EdgeInsets.fromLTRB(8, widget.grouped ? 2 : 8, 8, 4),
      decoration: BoxDecoration(
        color: forMe
            ? scheme.errorContainer.withValues(alpha: 0.35)
            : _hover
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                : null,
        borderRadius: BorderRadius.circular(8),
        border: forMe ? Border(left: BorderSide(color: scheme.error, width: 3)) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: widget.grouped
                ? (_hover
                    ? Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(_time(message.at),
                            style: muted?.copyWith(fontSize: 9)),
                      )
                    : null)
                : _ChatAvatar(file: widget.avatar, name: message.who, radius: 15),
          ),
          const SizedBox(width: 8),
          Expanded(child: body),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showDay)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: Row(
              children: [
                Expanded(child: Divider(color: scheme.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(_day(message.at), style: muted),
                ),
                Expanded(child: Divider(color: scheme.outlineVariant)),
              ],
            ),
          ),
        MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              row,
              if (_hover && !widget.editing)
                Positioned(
                  right: 14,
                  top: -12,
                  child: _HoverBar(
                    messageId: message.id,
                    onReact: widget.onReact,
                    onEdit: widget.onEdit,
                    onDelete: widget.onDelete,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The little toolbar over a message the pointer is on: quick reactions,
/// more emoji, and edit and delete on your own.
class _HoverBar extends StatelessWidget {
  final String messageId;
  final ValueChanged<String> onReact;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _HoverBar({
    required this.messageId,
    required this.onReact,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget action(String key, String tip, IconData icon, VoidCallback onTap) =>
        IconButton(
          key: ValueKey('${key}_$messageId'),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          icon: Icon(icon, color: scheme.onSurfaceVariant),
          onPressed: onTap,
        );
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in kQuickReactions.take(3))
              InkWell(
                key: ValueKey('chat_quick_${e}_$messageId'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => onReact(e),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  child: Text(e, style: const TextStyle(fontSize: 16)),
                ),
              ),
            _EmojiButton(
              key: ValueKey('chat_react_$messageId'),
              tooltip: 'Add a reaction',
              icon: Icons.add_reaction_outlined,
              size: 16,
              onPicked: onReact,
            ),
            if (onEdit != null)
              action('chat_edit', 'Edit this message', Icons.edit_outlined, onEdit!),
            if (onDelete != null)
              action('chat_delete', 'Delete this message', Icons.delete_outline,
                  onDelete!),
          ],
        ),
      ),
    );
  }
}

/// One emoji under a message, with how many used it. Tap to add or take
/// back yours.
class _ReactionChip extends StatelessWidget {
  final String emoji;
  final List<String> who;
  final bool mine;
  final VoidCallback onTap;

  const _ReactionChip({
    required this.emoji,
    required this.who,
    required this.mine,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: who.join(', '),
      child: Material(
        color: mine
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        shape: StadiumBorder(
          side: BorderSide(color: mine ? scheme.primary : scheme.outlineVariant),
        ),
        child: InkWell(
          key: ValueKey('chat_reaction_$emoji'),
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 4),
                Text(
                  '${who.length}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: mine ? scheme.onPrimaryContainer : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A message being rewritten in place. Enter saves; Esc puts it back.
class _EditBox extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  const _EditBox({
    required this.controller,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): onSave,
            const SingleActivator(LogicalKeyboardKey.escape): onCancel,
          },
          child: TextField(
            key: const ValueKey('chat_edit_input'),
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text('Enter to save · Esc to cancel', style: theme.textTheme.labelSmall),
            const Spacer(),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('chat_edit_save'),
              onPressed: onSave,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

/// A person's picture, or their initials when they have none.
class _ChatAvatar extends StatelessWidget {
  final String file;
  final String name;
  final double radius;

  const _ChatAvatar({required this.file, required this.name, this.radius = 11});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final picture = file.isNotEmpty && File(file).existsSync();
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.secondaryContainer,
      foregroundImage: picture ? FileImage(File(file)) : null,
      child: Text(
        _initials(name),
        style: TextStyle(
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w600,
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// A picture sent with a message: a thumbnail that opens full size. A GIF
/// plays.
class _ChatPicture extends StatelessWidget {
  final String file;

  const _ChatPicture({required this.file});

  @override
  Widget build(BuildContext context) {
    final image = File(file);
    if (!image.existsSync()) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('(picture not found: ${path.basename(file)})',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: Stack(
              children: [
                InteractiveViewer(
                  maxScale: 6,
                  child: Image.file(image, fit: BoxFit.contain),
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: IconButton.filledTonal(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 340),
            child: Image.file(image, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}
