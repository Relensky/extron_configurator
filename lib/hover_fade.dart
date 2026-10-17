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
  Widget build(BuildContext context) {
    final chat = Team.chat;
    // Positioned even when off: a bare box in the page's Stack would size the
    // Stack to nothing.
    if (chat == null) {
      return const Positioned(right: 0, bottom: 0, child: SizedBox.shrink());
    }
    return ListenableBuilder(
      listenable: Listenable.merge([
        TeamChatPanel.rightCover,
        TeamChatPanel.dragCover,
        chat,
        TeamChatPanel.instance.showing,
      ]),
      builder: (context, _) {
        final dragging = TeamChatPanel.dragCover.value;
        final cover = dragging ?? TeamChatPanel.rightCover.value;
        return AnimatedPositioned(
          duration: dragging != null
              ? Duration.zero
              : const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          right: 20.0 + (cover > 0 ? cover : 0),
          bottom: 20,
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
        );
      },
    );
  }
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
  Widget build(BuildContext context) {
    if (!_on) return widget.child;
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(
          bottom: media.padding.bottom + kChatButtonClearance,
        ),
      ),
      child: widget.child,
    );
  }
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
