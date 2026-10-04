import 'dart:async';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'chat_link.dart';
import 'chat_search_view.dart';
import 'chat_view.dart';
import 'project_chat.dart';

/// Opens the chat the way this person likes it, on [channel] when given.
void openProjectChat(AppStateProvider provider, {String? channel}) {
  if (channel != null) provider.chat.selectChannel(channel);
  provider.chat.mode = provider.chatMode;
  if (provider.chatMode == ChatMode.window) {
    ChatWindowHost.instance.open(provider);
  } else {
    provider.chat.setOpen(true);
  }
}

/// The chat's icon: a speech bubble with a count, or an @ in the warning
/// color when somebody has named you.
class ChatBadgeIcon extends StatelessWidget {
  final ProjectChat chat;
  final double size;

  const ChatBadgeIcon({super.key, required this.chat, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mentions = chat.mentionCount;
    final unread = chat.unreadCount;
    if (mentions > 0) {
      return Badge(
        key: const ValueKey('chat_badge_mention'),
        backgroundColor: scheme.error,
        label: Text('$mentions'),
        child: Icon(Icons.alternate_email, size: size, color: scheme.error),
      );
    }
    return Badge(
      key: const ValueKey('chat_badge'),
      isLabelVisible: unread > 0,
      label: Text('$unread'),
      child: Icon(
        unread > 0 ? Icons.mark_chat_unread_outlined : Icons.forum_outlined,
        size: size,
      ),
    );
  }
}

/// The chat on the top bar.
class ChatToolbarButton extends StatelessWidget {
  const ChatToolbarButton({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    return ListenableBuilder(
      listenable: provider.chat,
      builder: (context, _) => IconButton(
        key: const ValueKey('chat_button'),
        tooltip: provider.chat.mentionCount > 0
            ? 'Project chat - somebody has named you'
            : 'Project chat',
        icon: ChatBadgeIcon(chat: provider.chat),
        onPressed: () => provider.chat.open && provider.chatMode != ChatMode.window
            ? provider.chat.setOpen(false)
            : openProjectChat(provider),
      ),
    );
  }
}

/// The notices on screen, newest last. Filled by [ProjectChatLayer], shown by
/// [ChatCorner].
final ValueNotifier<List<ChatMessage>> chatNotices = ValueNotifier(const []);

/// Lays the chat over [child]: the slide-out, the floating panel, the hover
/// button in the lower left, and the notices that pop up as messages arrive.
class ProjectChatLayer extends StatefulWidget {
  final Widget child;

  const ProjectChatLayer({super.key, required this.child});

  @override
  State<ProjectChatLayer> createState() => _ProjectChatLayerState();
}

class _ProjectChatLayerState extends State<ProjectChatLayer> {
  LocalChatLink? _link;
  /// Where the floating panel sits. A drag changes only this, so the chat
  /// inside is moved as it stands rather than rebuilt on every tick.
  final ValueNotifier<Offset?> _floatAt = ValueNotifier(null);
  final Map<String, Timer> _noticeTimers = {};

  /// The slide-out's width, dragged from its left edge. Only the panel's
  /// frame follows a drag; the chat inside is not rebuilt.
  final ValueNotifier<double> _slideWidth = ValueNotifier(_panelWidth);
  bool _resizing = false;

  /// The slide-out filling the screen: the chat in one half, the search of
  /// every chat and project in the other.
  bool _full = false;

  static const double _panelWidth = 440;
  static const Size _floatSize = Size(560, 600);

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppStateProvider>();
    _link = LocalChatLink(provider);
    provider.chat.onIncoming = _incoming;
  }

  @override
  void dispose() {
    for (final t in _noticeTimers.values) {
      t.cancel();
    }
    _link?.dispose();
    _floatAt.dispose();
    _slideWidth.dispose();
    super.dispose();
  }

  void _incoming(ChatMessage m) {
    if (!mounted) return;
    final provider = context.read<AppStateProvider>();
    final chat = provider.chat;
    final forMe = m.mentionsUser(chat.me.user);
    final showing = chat.open && chat.shownChannel == m.channel;
    if (showing) return;
    // A question, or my name: the chat comes up by itself.
    if (provider.chatPopUp && !chat.open && (forMe || m.text.contains('?'))) {
      openProjectChat(provider, channel: m.channel);
      return;
    }
    final next = [...chatNotices.value, m];
    while (next.length > 3) {
      _noticeTimers.remove(next.removeAt(0).id)?.cancel();
    }
    chatNotices.value = next;
    _noticeTimers[m.id] = Timer(Duration(seconds: forMe ? 30 : 10), () {
      _noticeTimers.remove(m.id);
      dismissChatNotice(m);
    });
  }

  Widget _fullButton() => IconButton(
        key: const ValueKey('chat_fill_screen'),
        tooltip: _full
            ? 'Back to the side'
            : 'Fill the screen, with the search in the other half',
        visualDensity: VisualDensity.compact,
        icon: Icon(_full ? Icons.close_fullscreen : Icons.open_in_full,
            size: 18),
        onPressed: () => setState(() => _full = !_full),
      );

  Widget _searchButton() => IconButton(
        key: const ValueKey('chat_search'),
        tooltip: 'Search every chat and project',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.manage_search, size: 18),
        onPressed: () => showChatSearch(context),
      );

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    // The separate window draws in the app's colors.
    final host = ChatWindowHost.instance;
    final dark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary.toARGB32();
    if (host.dark != dark || host.accent != accent) {
      host
        ..dark = dark
        ..accent = accent;
      host.pushTheme();
    }

    return ListenableBuilder(
      listenable: provider.chat,
      builder: (context, _) {
        final chat = provider.chat;
        final mode = provider.chatMode;
        final media = MediaQuery.of(context);
        final top = media.padding.top + kToolbarHeight;
        final slide = chat.open && mode == ChatMode.slideOut;
        final float = chat.open && mode == ChatMode.floating;
        final home = Offset(
          (media.size.width - _floatSize.width - 24).clamp(0, double.infinity),
          top + 24,
        );
        return Stack(
          children: [
            widget.child,
            // THE SLIDE-OUT, from the right under the title bar: widened
            // from its left edge, or filling the screen beside the search.
            if (slide && _full && _link != null)
              Positioned(
                top: top,
                left: 0,
                right: 0,
                bottom: 0,
                child: Material(
                  key: const ValueKey('chat_slide_out'),
                  elevation: 12,
                  color: theme.colorScheme.surface,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ChatView(
                          link: _link!,
                          actions: [_fullButton()],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      const Expanded(
                        child: ChatSearchPane(
                          key: ValueKey('chat_full_search'),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ValueListenableBuilder<double>(
                valueListenable: _slideWidth,
                child: RepaintBoundary(
                  child: Material(
                    key: const ValueKey('chat_slide_out'),
                    elevation: 12,
                    color: theme.colorScheme.surface,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: slide && _link != null
                              ? ChatView(
                                  link: _link!,
                                  actions: [_searchButton(), _fullButton()],
                                )
                              : const SizedBox.shrink(),
                        ),
                        // The edge to drag.
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: 8,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.resizeLeftRight,
                            child: GestureDetector(
                              key: const ValueKey('chat_slide_resize'),
                              behavior: HitTestBehavior.opaque,
                              dragStartBehavior: DragStartBehavior.down,
                              onHorizontalDragStart: (_) =>
                                  setState(() => _resizing = true),
                              onHorizontalDragUpdate: (d) =>
                                  _slideWidth.value = (_slideWidth.value -
                                          d.delta.dx)
                                      .clamp(320.0, media.size.width * 0.9),
                              onHorizontalDragEnd: (_) =>
                                  setState(() => _resizing = false),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                builder: (context, width, child) => AnimatedPositioned(
                  // Slides in and out; follows the pointer exactly while it
                  // is being widened.
                  duration: _resizing
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  top: top,
                  bottom: 0,
                  right: slide ? 0 : -width - 16,
                  width: width,
                  child: child!,
                ),
              ),
            // THE FLOATING PANEL, dragged by its title.
            if (float && _link != null)
              ValueListenableBuilder<Offset?>(
                valueListenable: _floatAt,
                child: RepaintBoundary(
                  child: Material(
                    key: const ValueKey('chat_floating'),
                    elevation: 16,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    color: theme.colorScheme.surface,
                    child: ChatView(
                      link: _link!,
                      wrapHeader: (title) => MouseRegion(
                        cursor: SystemMouseCursors.move,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          dragStartBehavior: DragStartBehavior.down,
                          onPanUpdate: (d) {
                            final next = (_floatAt.value ?? home) + d.delta;
                            _floatAt.value = Offset(
                              next.dx.clamp(
                                  0, media.size.width - _floatSize.width / 3),
                              next.dy.clamp(0, media.size.height - 48),
                            );
                          },
                          child: title,
                        ),
                      ),
                    ),
                  ),
                ),
                builder: (context, at, child) => Positioned(
                  left: (at ?? home).dx,
                  top: (at ?? home).dy,
                  width: _floatSize.width,
                  height: _floatSize.height,
                  child: child!,
                ),
              ),
          ],
        );
      },
    );
  }
}

void dismissChatNotice(ChatMessage m) {
  chatNotices.value = [
    for (final n in chatNotices.value)
      if (n.id != m.id) n,
  ];
}

/// The lower-left corner of the page: the notices of new messages. The chat
/// itself opens from its button on the title bar.
class ChatCorner extends StatefulWidget {
  const ChatCorner({super.key});

  @override
  State<ChatCorner> createState() => _ChatCornerState();
}

class _ChatCornerState extends State<ChatCorner> {
  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    return ListenableBuilder(
      listenable: Listenable.merge([provider.chat, chatNotices]),
      builder: (context, _) {
        final chat = provider.chat;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in chatNotices.value)
              SizedBox(
                width: 340,
                child: _Notice(
                  key: ValueKey('chat_notice_${m.id}'),
                  message: m,
                  forMe: m.mentionsUser(chat.me.user),
                  onOpen: () {
                    dismissChatNotice(m);
                    openProjectChat(provider, channel: m.channel);
                  },
                  onDismiss: () => dismissChatNotice(m),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  final ChatMessage message;
  final bool forMe;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const _Notice({
    super.key,
    required this.message,
    required this.forMe,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 8,
      color: forMe ? scheme.errorContainer : null,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(forMe ? Icons.alternate_email : Icons.chat_bubble_outline,
                  size: 20, color: forMe ? scheme.error : scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      forMe
                          ? '${message.who} named you'
                          : '${message.who} wrote',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: forMe ? FontWeight.w600 : null),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, size: 16),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
