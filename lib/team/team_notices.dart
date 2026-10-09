import 'dart:io';

import 'package:flutter/material.dart';

import 'chat_format.dart';
import 'team_chat.dart';
import 'team_host.dart';
import 'team_widgets.dart';

// ============================================================================
// [TEAM KIT - NOTICES]: what a new message looks like when the chat is shut,
// and the chat's icon - the same in every app.
//
//   showTeamMessageNotice  a floating card: the writer's picture, name and
//                          app, where it was posted, two lines of it, Reply
//   TeamUnreadIcon         the chat icon: a bubble, a count that pulses while
//                          there is something unread, a red @ for a mention
// ============================================================================

/// Where [m] was posted, for a notice: '' for this app's own conversation,
/// ' in All CTS apps' / ' in <another app>', ' (direct)', ' in <group>',
/// ' about <room / topic>'.
String teamWhereText(TeamChat chat, TeamMessage m) =>
    m.channel == appChannel(TeamHost.appId)
        ? ''
        : m.channel == kChatAllApps || appOfChannel(m.channel) != null
            ? ' in ${chat.labelOf(m.channel)}'
            : m.channel.startsWith('dm:')
                ? ' (direct)'
                : m.channel.startsWith('group:')
                    ? ' in ${chat.labelOf(m.channel)}'
                    : ' about ${chat.labelOf(m.channel)}';

/// Shows [m] as a floating card over the app. [onReply] opens the chat on
/// its thread.
void showTeamMessageNotice(
  BuildContext context,
  TeamChat chat,
  TeamMessage m, {
  required VoidCallback onReply,
  Duration duration = const Duration(seconds: 7),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final forMe = chat.isForMe(m);
  final words = m.text.isNotEmpty
      ? ChatFormat.plain(m.text)
      : (m.attachments.isNotEmpty ? 'Sent a picture' : '');
  final where = teamWhereText(chat, m).trim();
  final accent = forMe ? scheme.error : scheme.primary;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      key: const ValueKey('team_message_notice'),
      behavior: SnackBarBehavior.floating,
      width: 480,
      duration: duration,
      elevation: 8,
      padding: EdgeInsets.zero,
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: accent.withValues(alpha: 0.6), width: 1.5),
      ),
      content: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(clipBehavior: Clip.none, children: [
              TeamAvatar(m.user, size: 36),
              if (forMe)
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: CircleAvatar(
                    radius: 9,
                    backgroundColor: scheme.error,
                    child: Icon(
                        m.channel.startsWith('dm:')
                            ? Icons.mail
                            : Icons.alternate_email,
                        size: 11,
                        color: scheme.onError),
                  ),
                ),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(m.who,
                          style: theme.textTheme.titleSmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700)),
                      TeamAppTag(m.app),
                      if (where.isNotEmpty)
                        Text(where,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(words,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurface)),
                  const SizedBox(height: 6),
                  FilledButton.tonalIcon(
                    key: const ValueKey('team_message_reply'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      messenger.hideCurrentSnackBar();
                      onReply();
                    },
                    icon: const Icon(Icons.reply, size: 16),
                    label: const Text('Reply'),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 18, color: scheme.onSurfaceVariant),
              onPressed: messenger.hideCurrentSnackBar,
            ),
          ],
        ),
      ),
    ));
  TeamHost.log('[TEAM] notice: ${m.who}${teamWhereText(chat, m)}');
}

/// The chat's icon: a bubble; with unread messages a filled bubble and a
/// count that pulses gently; with a mention a red @ and its count.
class TeamUnreadIcon extends StatefulWidget {
  const TeamUnreadIcon({
    super.key,
    required this.unread,
    required this.mentions,
    this.open = false,
    this.color,
    this.size = 24,
  });

  final int unread;
  final int mentions;

  /// The chat is showing: a close icon instead.
  final bool open;
  final Color? color;
  final double size;

  @override
  State<TeamUnreadIcon> createState() => _TeamUnreadIconState();
}

class _TeamUnreadIconState extends State<TeamUnreadIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));

  bool get _active =>
      !widget.open && (widget.unread > 0 || widget.mentions > 0);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant TeamUnreadIcon old) {
    super.didUpdateWidget(old);
    _sync();
  }

  int _seenUnread = 0;
  int _seenMentions = 0;

  /// The count pulses a few times when it appears or goes up, then holds
  /// still. It used to pulse for as long as anything was unread - an app
  /// left open overnight with one unread message drew 60 frames a second
  /// all night for it.
  void _sync() {
    final bool more = widget.unread > _seenUnread ||
        widget.mentions > _seenMentions;
    _seenUnread = widget.unread;
    _seenMentions = widget.mentions;
    if (_active) {
      if (more) {
        // 6 half-swings: out and back three times, ending at rest.
        _pulse.repeat(reverse: true, count: 6).then((_) {
          if (mounted) _pulse.value = 0;
        });
      }
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mention = widget.mentions > 0;
    final icon = widget.open
        ? Icons.close
        : mention
            ? Icons.alternate_email
            : widget.unread > 0
                ? Icons.mark_unread_chat_alt
                : Icons.chat_bubble_outline;
    final count = mention ? widget.mentions : widget.unread;
    final pill = mention ? scheme.error : const Color(0xFFFFB300);
    final onPill = mention ? scheme.onError : Colors.black;
    return SizedBox(
      width: widget.size + 12,
      height: widget.size + 8,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Icon(icon, size: widget.size, color: widget.color),
          if (_active)
            Positioned(
              right: -2,
              top: -4,
              child: ScaleTransition(
                scale: Tween(begin: 1.0, end: 1.18).animate(
                    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: pill,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                          color: pill.withValues(alpha: 0.5),
                          blurRadius: 6,
                          spreadRadius: 1),
                    ],
                  ),
                  child: Text(
                    count > 99 ? '99+' : (mention ? '@$count' : '$count'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: onPill,
                        fontSize: 10.5,
                        height: 1.2,
                        fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// [TEAM KIT - NOTICES]: shows [showTeamMessageNotice] for messages that are
/// for this person (a mention, a direct or group message) or about the room
/// on screen ([hereRoom]), while the chat is not showing their thread. Wrap
/// the page in it, under the Scaffold. An app that handles
/// [TeamChat.onIncoming] itself (the dashboard) does not need it.
class TeamNoticeListener extends StatefulWidget {
  const TeamNoticeListener({super.key, required this.child, this.hereRoom});

  final Widget child;
  final String Function()? hereRoom;

  @override
  State<TeamNoticeListener> createState() => _TeamNoticeListenerState();
}

class _TeamNoticeListenerState extends State<TeamNoticeListener> {
  TeamChat? _hooked;

  @override
  void initState() {
    super.initState();
    _hook();
  }

  /// The chat may start after the page does: looked for again until it is
  /// there.
  void _hook() {
    if (!mounted) return;
    final chat = Team.chat;
    if (chat == null) {
      // Never under a test: the chat does not start there, and a waiting
      // timer fails the test.
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        Future<void>.delayed(const Duration(seconds: 2), _hook);
      }
      return;
    }
    if (identical(chat, _hooked)) return;
    _hooked = chat;
    chat.onIncoming = _onMessage;
  }

  void _onMessage(TeamMessage m) {
    final chat = _hooked;
    if (!mounted || chat == null) return;
    final here = widget.hereRoom?.call() ?? '';
    final forMe = chat.isForMe(m);
    final aboutHere = here.isNotEmpty && m.channel == roomChannel(here);
    if (!forMe && !aboutHere) return;
    if (TeamChatPanel.instance.isOpen && chat.channel == m.channel) return;
    showTeamMessageNotice(context, chat, m,
        onReply: () =>
            TeamChatPanel.instance.open(context, channel: m.channel));
  }

  @override
  void dispose() {
    if (_hooked?.onIncoming == _onMessage) _hooked?.onIncoming = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
