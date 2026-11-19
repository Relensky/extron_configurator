import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'team/team_chat.dart' show TeamChat;
import 'team/team_widgets.dart';

/// Floating buttons fade and shrink while the pointer is away, so they stay
/// out of the way of the page, and come back to full size on hover. The same
/// as the CTS Dashboard's.
class HoverFade extends StatefulWidget {
  final Widget child;

  /// The corner the buttons shrink toward.
  final Alignment anchor;

  /// Keep full size regardless - e.g. while the chat is open and its button
  /// is how you close it.
  final bool keepFull;

  const HoverFade({
    super.key,
    required this.child,
    required this.anchor,
    this.keepFull = false,
  });

  @override
  State<HoverFade> createState() => _HoverFadeState();
}

class _HoverFadeState extends State<HoverFade> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool full = _hovered || widget.keepFull;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: full ? 1.0 : 0.35,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 180),
          scale: full ? 1.0 : 0.75,
          alignment: widget.anchor,
          child: widget.child,
        ),
      ),
    );
  }
}

/// True when the team chat's button is in the top bar instead of hovering in
/// the corner - App Config's "Team chat in the top bar". Set by
/// [AppStateProvider.setTeamChatInTopBar]; the hover button and its list
/// padding watch it.
final ValueNotifier<bool> teamChatInTopBar = ValueNotifier(false);

/// [TEAM KIT]: the team chat's button, hovering in the bottom-right corner of
/// the page as it does in the CTS Dashboard. Slides left with a slid-out chat
/// so it is never under it, and stays full size while there is unread chat
/// or the chat is open.
class TeamChatHoverButton extends StatefulWidget {
  const TeamChatHoverButton({super.key});

  @override
  State<TeamChatHoverButton> createState() => _TeamChatHoverButtonState();
}

class _TeamChatHoverButtonState extends State<TeamChatHoverButton> {
  // The team starts after the window is first drawn, and can be switched on
  // or off in Settings, so the button checks for the chat until it is there
  // and keeps checking in case it goes.
  Timer? _watch;
  TeamChat? _seen;

  @override
  void initState() {
    super.initState();
    _seen = Team.chat;
    _watch = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!identical(Team.chat, _seen) && mounted) {
        setState(() => _seen = Team.chat);
      }
    });
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: teamChatInTopBar,
    builder: (context, inTopBar, _) => _button(context, inTopBar),
  );

  Widget _button(BuildContext context, bool inTopBar) {
    final chat = Team.chat;
    // Positioned even when off: a bare box in the page's Stack would size the
    // Stack to nothing.
    if (chat == null || inTopBar) {
      return const Positioned(right: 0, bottom: 0, child: SizedBox.shrink());
    }
    return ListenableBuilder(
      listenable: Listenable.merge([
        TeamChatPanel.rightCover,
        TeamChatPanel.dragCover,
        chat,
        TeamChatPanel.instance.showing,
        chatButtonTucked,
      ]),
      builder: (context, _) {
        final dragging = TeamChatPanel.dragCover.value;
        final cover = dragging ?? TeamChatPanel.rightCover.value;
        // Out of the way while the page scrolls down or sits at its end -
        // see [chatButtonTucked]. Never while the chat is open.
        final tucked =
            chatButtonTucked.value && !TeamChatPanel.instance.isOpen;
        return AnimatedPositioned(
          duration: dragging != null
              ? Duration.zero
              : const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          right: 20.0 + (cover > 0 ? cover : 0),
          bottom: 20,
          child: IgnorePointer(
            ignoring: tucked,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              offset: tucked ? const Offset(1.6, 0) : Offset.zero,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: tucked ? 0 : 1,
                child: HoverFade(
            anchor: Alignment.bottomRight,
            keepFull: chat.mentionCount > 0 ||
                chat.unreadCount > 0 ||
                TeamChatPanel.instance.isOpen,
            // The app's accent color; its count in the inverse.
            child: TeamChatFab(
              onPressed: () => TeamChatPanel.instance.toggle(context),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// True while the page under the chat button is being scrolled down or is at
/// its end - the button steps out of the way then, so whatever is in the
/// bottom-right corner can be read and pressed. Set by
/// [ChatButtonScrollWatch]; scrolling back up brings the button back.
final ValueNotifier<bool> chatButtonTucked = ValueNotifier(false);

/// Watches the page's vertical scrolling for [chatButtonTucked].
///
/// The padding in [ChatButtonClearance] only reaches a list that has no
/// padding of its own, and most pages set theirs - so on those the last row
/// could sit under the button with no way past it. Stepping the button aside
/// at the end works for every page, whatever it is built from.
class ChatButtonScrollWatch extends StatefulWidget {
  final Widget child;

  const ChatButtonScrollWatch({super.key, required this.child});

  @override
  State<ChatButtonScrollWatch> createState() => _ChatButtonScrollWatchState();
}

class _ChatButtonScrollWatchState extends State<ChatButtonScrollWatch> {
  @override
  void initState() {
    super.initState();
    // A new page starts with the button showing.
    chatButtonTucked.value = false;
  }

  bool _onScroll(ScrollNotification n) {
    final m = n.metrics;
    if (m.axis != Axis.vertical) return false;
    // A page barely taller than the screen - the start page on a phone - is
    // "at its end" before anyone scrolls, and hid the button the moment it
    // opened. Only a page with real scrolling to do tucks it.
    if (m.maxScrollExtent <= kChatButtonClearance) return false;
    // At the top it always shows.
    if (m.pixels <= 0) {
      chatButtonTucked.value = false;
      return false;
    }
    final atEnd = m.extentAfter < kChatButtonClearance;
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0;
      if (d > 0) {
        chatButtonTucked.value = true;
      } else if (d < 0 && !atEnd) {
        chatButtonTucked.value = false;
      }
    } else if (n is ScrollEndNotification && atEnd) {
      // Hidden after scrolling down until scrolling back up - the usual
      // touch-screen habit - and always at the end of the page.
      chatButtonTucked.value = true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      );
}

/// Room under the last row of a list for [TeamChatHoverButton]: its 56 px,
/// the 20 px it floats above the edge, and a little air.
const double kChatButtonClearance = 88;

/// Gives every page under it [kChatButtonClearance] of bottom padding while
/// the chat button is showing, so a list can be scrolled past its last row
/// and nothing is stuck under the button.
///
/// Through [MediaQuery] rather than page by page: a [ListView] or [GridView]
/// with no padding of its own pads its end by the MediaQuery's, so every
/// list in the app gets it, including the ones written after this.
class ChatButtonClearance extends StatefulWidget {
  final Widget child;

  const ChatButtonClearance({super.key, required this.child});

  @override
  State<ChatButtonClearance> createState() => _ChatButtonClearanceState();
}

class _ChatButtonClearanceState extends State<ChatButtonClearance> {
  // Watched the way the button watches it: the team starts after the first
  // frame and can be switched off in Settings.
  Timer? _watch;
  bool _on = Team.chat != null;

  @override
  void initState() {
    super.initState();
    _watch = Timer.periodic(const Duration(seconds: 1), (_) {
      final on = Team.chat != null;
      if (on != _on && mounted) setState(() => _on = on);
    });
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: teamChatInTopBar,
    // Same child either way, so the page keeps its state when it flips.
    child: widget.child,
    builder: (context, inTopBar, child) {
      if (!_on || inTopBar) return child!;
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(
          padding: media.padding.copyWith(
            bottom: media.padding.bottom + kChatButtonClearance,
          ),
        ),
        child: child!,
      );
    },
  );
}

/// Grows [child] toward [anchor] while the pointer is over it - your own
/// avatar in App Config (the corner one only has its tooltip).
class HoverGrow extends StatefulWidget {
  final Widget child;
  final double scale;
  final Alignment anchor;

  const HoverGrow({
    super.key,
    required this.child,
    this.scale = 1.6,
    this.anchor = Alignment.topRight,
  });

  @override
  State<HoverGrow> createState() => _HoverGrowState();
}

class _HoverGrowState extends State<HoverGrow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutBack,
          scale: _hovered ? widget.scale : 1.0,
          alignment: widget.anchor,
          child: widget.child,
        ),
      );
}
