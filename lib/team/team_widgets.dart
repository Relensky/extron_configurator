import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'chat_format.dart';
import 'team_clipboard_image.dart';
import 'team_emoji_data.dart';
import 'team_floating_panel.dart';
import 'team_fx.dart';
import 'team_notices.dart';
import 'team_host.dart';
import 'gif_search.dart';
import 'team_chat.dart';
import 'team_claims.dart';
import 'team_presence.dart';

// ============================================================================
// [TEAM]: the screens for who is on what, and chat.
//
// [Team] holds the two controllers for whatever is on screen. The dashboard
// sets them once at start-up (main window only); everything here reads them
// from there, so a dialog opened from anywhere can say who else has it open
// without being handed the app state.
// ============================================================================

class Team {
  Team._();

  static TeamPresenceBoard? presence;
  static TeamChat? chat;

  /// [TEAM KIT - WORKING ON]: who is on which ticket / room.
  static TeamClaims? claims;

  /// Takes the Room Hub to [room] (set by the dashboard).
  static void Function(String room)? openRoom;

  /// Every room the dashboard knows, so a chat search can start a thread
  /// for a room that has none yet (set by the dashboard).
  static Iterable<String> Function()? knownRooms;

  /// [TEAM CHAT - PROJECTS]: the project open on screen ('' for none), so
  /// the chat offers its thread (set by the Room Config Builder).
  static String Function()? currentProject;

  /// Every project the host knows, so the chat's + can start a thread for
  /// one that has none yet (set by the Room Config Builder).
  static Iterable<String> Function()? knownProjects;
}

/// Short "x ago".
String teamAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String _clock(DateTime t) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  return '${t.month}/${t.day} $hm';
}

/// The initials drawn for a login, as the configurator draws them:
/// `jsmith` -> `JS`, `Jane.Smith` -> `JS`.
String teamInitials(String user) {
  final parts =
      user.split(RegExp(r'[\s._\\-]+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final p = parts.first;
    return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
  }
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// A steady color per person - the configurator's palette and hash, so the
/// same colleague is the same color in both apps.
Color teamColorFor(String user) {
  const palette = [
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFF6A1B9A),
    Color(0xFFC62828),
    Color(0xFF00838F),
    Color(0xFFEF6C00),
    Color(0xFF4E342E),
    Color(0xFFAD1457),
  ];
  var h = 0;
  for (final c in user.toLowerCase().codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

/// People's pictures: `<login>.png` / `.jpg` in the avatars folder
/// (team_config.json's avatarsFolder - the configurator's `assets\avatars`
/// works - or the team folder's `avatars`). The folder is listed in the
/// background now and then; drawing never touches the share.
class TeamAvatars extends ChangeNotifier {
  TeamAvatars._();
  static final TeamAvatars instance = TeamAvatars._();

  String _folder = '';
  Map<String, String> _files = const {};
  DateTime _listed = DateTime.fromMillisecondsSinceEpoch(0);
  bool _listing = false;

  String get folder => _folder;

  void setFolder(String folder) {
    if (folder == _folder) return;
    _folder = folder;
    _files = const {};
    _listed = DateTime.fromMillisecondsSinceEpoch(0);
    _list();
  }

  static String stemOf(String user) =>
      user.trim().toLowerCase().replaceAll(RegExp(r'[^\w\-.]+'), '_');

  /// Lists the folder again now - after your own picture changed.
  Future<void> refresh() async {
    while (_listing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _list();
  }

  /// The picture for [user], or null for initials.
  String? fileFor(String user) {
    if (DateTime.now().difference(_listed) > const Duration(minutes: 2)) {
      _list();
    }
    return _files[stemOf(user)];
  }

  Future<void> _list() async {
    if (_listing || _folder.isEmpty) return;
    _listing = true;
    _listed = DateTime.now();
    try {
      final found = <String, String>{};
      final dir = Directory(_folder);
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final name = e.uri.pathSegments.last.toLowerCase();
          final dot = name.lastIndexOf('.');
          if (dot <= 0) continue;
          final ext = name.substring(dot);
          if (ext != '.png' && ext != '.jpg' && ext != '.jpeg') continue;
          found[name.substring(0, dot)] = e.path;
        }
      }
      if (found.length != _files.length ||
          found.entries.any((e) => _files[e.key] != e.value)) {
        _files = found;
        notifyListeners();
      }
    } catch (_) {
      // The share is away; initials until it is back.
    } finally {
      _listing = false;
    }
  }
}

/// Somebody's avatar: their picture when there is one, else their initials
/// in their color.
class TeamAvatar extends StatelessWidget {
  final String login;
  final double size;
  const TeamAvatar(this.login, {super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final color = teamColorFor(login);
    return ListenableBuilder(
      listenable: TeamAvatars.instance,
      builder: (context, _) {
        final file = TeamAvatars.instance.fileFor(login);
        if (file != null) {
          return CircleAvatar(
            key: ValueKey('team_avatar_picture_$login'),
            radius: size / 2,
            backgroundColor: color,
            backgroundImage: FileImage(File(file)),
            onBackgroundImageError: (error, stack) {},
          );
        }
        return CircleAvatar(
          radius: size / 2,
          backgroundColor: color,
          child: Text(
            teamInitials(login),
            style: TextStyle(
                fontSize: size * 0.42,
                color: Colors.white,
                fontWeight: FontWeight.bold),
          ),
        );
      },
    );
  }
}

// --- top bar ---------------------------------------------------------------

/// [TEAM KIT - OPTIONAL]: the settings switch for the team features, the
/// same words in every app. [onChanged] runs after the setting is saved -
/// the app re-runs its startTeam, which joins the folder or leaves it.
class TeamFeaturesSwitch extends StatefulWidget {
  final VoidCallback onChanged;
  const TeamFeaturesSwitch({super.key, required this.onChanged});

  @override
  State<TeamFeaturesSwitch> createState() => _TeamFeaturesSwitchState();
}

class _TeamFeaturesSwitchState extends State<TeamFeaturesSwitch> {
  // Its own Material: a settings page need not have one behind it (the
  // Room Config Builder's does not), and a list tile cannot draw without.
  @override
  Widget build(BuildContext context) => Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        key: const ValueKey('team_features_switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Team chat, who is online and working-on tags'),
        subtitle: const Text(
            'Shared with the other CTS apps through the team folder on the '
            'file share. Turn off for a copy used on its own: the chat, '
            'project threads and team buttons go away, and nothing is '
            'written to the share.'),
        value: teamFeaturesOn,
        onChanged: (v) async {
          await setTeamFeaturesOn(v);
          if (!mounted) return;
          setState(() {});
          widget.onChanged();
        },
      ));
}

/// The team's two top-bar buttons: people online, and chat with its count.
class TeamToolbarButtons extends StatelessWidget {
  final VoidCallback onTeam;
  final VoidCallback onChat;

  /// False where the chat has its own floating button ([TeamChatFab]).
  final bool showChat;

  /// False where the team members are reached from inside the chat.
  final bool showTeam;
  const TeamToolbarButtons(
      {super.key,
      required this.onTeam,
      required this.onChat,
      this.showChat = true,
      this.showTeam = true});

  @override
  Widget build(BuildContext context) {
    final presence = Team.presence;
    final chat = Team.chat;
    if (presence == null || chat == null || !presence.active) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([presence, chat]),
      builder: (context, _) {
        final online = presence.others.length;
        final mentions = chat.mentionCount;
        final unread = chat.unreadCount;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showTeam)
            IconButton(
              key: const ValueKey('team_button'),
              tooltip: online == 0
                  ? 'Team: nobody else is online'
                  : 'Team: $online other${online == 1 ? '' : 's'} online',
              icon: Badge(
                isLabelVisible: online > 0,
                backgroundColor: Colors.green,
                label: Text('$online'),
                child: const Icon(Icons.groups_outlined),
              ),
              onPressed: onTeam,
            ),
            if (showChat)
              IconButton(
                key: const ValueKey('team_chat_button'),
                tooltip: mentions > 0
                    ? 'Team chat: you were mentioned'
                    : unread > 0
                        ? 'Team chat: $unread unread'
                        : 'Team chat',
                icon: TeamUnreadIcon(
                  unread: unread,
                  mentions: mentions,
                  color: mentions > 0 ? scheme.error : null,
                ),
                onPressed: onChat,
              ),
          ],
        );
      },
    );
  }
}

// --- the team page ---------------------------------------------------------

Future<void> showTeamPage(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _TeamPage(),
  );
}

class _TeamPage extends StatelessWidget {
  /// [TEAM]: drawn inside the chat rather than as a dialog - a dialog opened
  /// from the chat would sit behind it (the chat floats above the page's
  /// dialogs). [onClose] goes back to the messages.
  final bool embedded;
  final VoidCallback? onClose;
  const _TeamPage({this.embedded = false, this.onClose});

  void _close(BuildContext context) =>
      embedded ? onClose?.call() : Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final presence = Team.presence;
    final theme = Theme.of(context);
    if (embedded && (presence == null || !presence.active)) {
      return const Center(child: Text('The team folder is not set up.'));
    }
    if (presence == null || !presence.active) {
      return AlertDialog(
        title: const Text('Team'),
        content: const Text(
            'The team folder is not set up. Set the Team Folder in this '
            "app's settings to the shared team folder first."),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close')),
        ],
      );
    }
    final Widget page = ListenableBuilder(
          listenable: presence,
          builder: (context, _) {
            final others = presence.others;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Icon(Icons.groups_outlined),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text('Team', style: theme.textTheme.titleLarge)),
                    TextButton.icon(
                      key: const ValueKey('team_page_back_to_chat'),
                      icon: Icon(embedded ? Icons.arrow_back : Icons.forum_outlined,
                          size: 18),
                      label: Text(embedded ? 'Back to the chat' : 'Chat'),
                      onPressed: () {
                        _close(context);
                        if (!embedded) TeamChatPanel.instance.open(context);
                      },
                    ),
                    if (!embedded)
                      IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => _close(context)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    'Everyone online in any CTS app (and which one), the '
                    'room they are looking at, and what they have open to '
                    'change. '
                    'Updates as soon as anyone moves.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  // [TEAM KIT - WHO IS WHERE]: everyone as a chart - a row a
                  // person, a column an app, the page and room in each.
                  Expanded(
                    child: SingleChildScrollView(
                      child: TeamPresenceChart(
                        meUser: presence.me.user,
                        people: [
                          [presence.mineHere, ...presence.mineElsewhere],
                          ...teamPeople(others),
                        ],
                        onMessage: (user) {
                          _close(context);
                          final chat = Team.chat;
                          TeamChatPanel.instance.open(context,
                              channel: chat == null
                                  ? kChatEveryone
                                  : dmChannel(chat.me.user, user));
                        },
                        onOpenRoom: Team.openRoom == null
                            ? null
                            : (room) {
                                _close(context);
                                Team.openRoom!(room);
                              },
                      ),
                    ),
                  ),
                  if (others.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Nobody else is online.',
                          style: theme.textTheme.bodySmall),
                    ),
                  Text(presence.folder,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ],
              ),
            );
          },
        );
    if (embedded) return page;
    // Wide enough for every app's full name over its column ("Room Config
    // Builder" was cut short at 760), and no wider than the window.
    final screen = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: (screen.width * 0.9).clamp(400.0, 1280.0),
            maxHeight: (screen.height * 0.85).clamp(300.0, 900.0)),
        child: page,
      ),
    );
  }
}

// --- who else is in this room ---------------------------------------------

/// How many people get a chip of their own before the rest go in a list.
const int kTeamChipsShown = 3;

/// One other person on this room, as the configurator shows its editors:
/// their picture or initials in their color, their name, a ring in their
/// color - at full strength while they have the room open to change,
/// dimmed while they are only looking. Hover for who, where and since when.
class TeamPersonChip extends StatelessWidget {
  final TeamPresence presence;
  final bool editing;
  const TeamPersonChip(
      {super.key, required this.presence, this.editing = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final about = [
      '${presence.label} on ${presence.machine}',
      if (presence.whereText.isNotEmpty) 'Looking at ${presence.whereText}',
      for (final e in presence.editing)
        'Editing ${e.label} (${teamAgo(e.since)})',
      '${presence.appName} open since ${_clock(presence.since)}',
    ].join('\n');
    return Tooltip(
      message: about,
      child: Opacity(
        opacity: editing ? 1 : 0.6,
        child: Chip(
          key: ValueKey('team_person_${presence.user}@${presence.machine}'),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          avatar: Stack(
            clipBehavior: Clip.none,
            children: [
              TeamAvatar(presence.user, size: 24),
              if (editing)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Icon(Icons.edit,
                      size: 12, color: theme.colorScheme.tertiary),
                ),
            ],
          ),
          label: Text(presence.user, style: theme.textTheme.labelMedium),
          side: BorderSide(color: teamColorFor(presence.user), width: 1.5),
        ),
      ),
    );
  }
}

/// Others on [room] (as chips), and its chat thread: for the Room Hub header.
class RoomTeamStrip extends StatelessWidget {
  final String room;
  const RoomTeamStrip({super.key, required this.room});

  @override
  Widget build(BuildContext context) {
    final presence = Team.presence;
    final chat = Team.chat;
    if (presence == null || chat == null || !presence.active || room.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: Listenable.merge([presence, chat]),
      builder: (context, _) {
        final key = room.trim().toLowerCase();
        bool editingHere(TeamPresence p) =>
            p.editing.any((e) => e.key == 'room:$key' || e.key == 'pdu:$key');
        final here = presence.viewingRoom(room)
          // Editing first, like the configurator.
          ..sort((a, b) =>
              (editingHere(b) ? 1 : 0).compareTo(editingHere(a) ? 1 : 0));
        final unread = chat.unreadInRoom(room);
        final count = chat.countInRoom(room);
        return Row(
          key: const ValueKey('room_team_strip'),
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in here.take(kTeamChipsShown))
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: TeamPersonChip(presence: p, editing: editingHere(p)),
              ),
            if (here.length > kTeamChipsShown)
              PopupMenuButton<void>(
                key: const ValueKey('room_team_more'),
                tooltip: '${here.length - kTeamChipsShown} more on $room',
                position: PopupMenuPosition.under,
                itemBuilder: (_) => [
                  for (final p in here.skip(kTeamChipsShown))
                    PopupMenuItem<void>(
                      enabled: false,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: TeamAvatar(p.user),
                        title: Text(p.label,
                            style: TextStyle(
                                color:
                                    Theme.of(context).colorScheme.onSurface)),
                        subtitle: Text(editingHere(p)
                            ? 'Editing this room'
                            : 'Looking at it, on ${p.machine}'),
                      ),
                    ),
                ],
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.group_outlined, size: 16),
                  label: Text('+${here.length - kTeamChipsShown}'),
                ),
              ),
            IconButton(
              key: const ValueKey('room_chat_button'),
              visualDensity: VisualDensity.compact,
              tooltip: count == 0
                  ? 'Team chat - go to or start the $room thread'
                  : 'Team chat - $room thread: $count message${count == 1 ? '' : 's'}'
                      '${unread > 0 ? ', $unread unread' : ''}',
              icon: Badge(
                isLabelVisible: unread > 0 || count > 0,
                backgroundColor:
                    unread > 0 ? null : Theme.of(context).colorScheme.outline,
                label: Text('${unread > 0 ? unread : count}'),
                child: const Icon(Icons.chat_outlined, size: 20),
              ),
              // [TEAM CHAT]: the chat opens where it was; its header offers
              // this room's thread (or to start one).
              onPressed: () =>
                  TeamChatPanel.instance.open(context, room: room),
            ),
          ],
        );
      },
    );
  }
}

// --- editing -----------------------------------------------------------------

/// Wrap an editor (a dialog) in this: while it is up, the team sees this
/// person has [editKey] open, and a banner says who else does.
class TeamEditingScope extends StatefulWidget {
  final String editKey;
  final String label;
  final Widget child;

  const TeamEditingScope({
    super.key,
    required this.editKey,
    required this.label,
    required this.child,
  });

  @override
  State<TeamEditingScope> createState() => _TeamEditingScopeState();
}

class _TeamEditingScopeState extends State<TeamEditingScope> {
  TeamPresenceBoard? _board;

  @override
  void initState() {
    super.initState();
    _board = Team.presence;
    if (_board?.active ?? false) {
      _board!.beginEditing(widget.editKey, widget.label);
    }
  }

  @override
  void dispose() {
    _board?.endEditing(widget.editKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = _board;
    if (board == null || !board.active) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: ListenableBuilder(
            listenable: board,
            builder: (context, _) {
              final others = board.editingKey(widget.editKey);
              if (others.isEmpty) return const SizedBox.shrink();
              final scheme = Theme.of(context).colorScheme;
              return Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 640),
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  child: Material(
                    key: const ValueKey('team_editing_banner'),
                    elevation: 6,
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.edit_note,
                              color: scheme.onTertiaryContainer),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '${others.map((p) => p.label).join(', ')} '
                              '${others.length == 1 ? 'is' : 'are'} also editing '
                              '${widget.label} - the last save wins, so agree '
                              'who goes first.',
                              style:
                                  TextStyle(color: scheme.onTertiaryContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// --- chat panel --------------------------------------------------------------

/// The team chat, as a floating panel over the app (one at a time).
/// Where the team chat sits.
enum TeamChatMode {
  floating('Floating panel', Icons.picture_in_picture_alt),
  slideOut('Slide out from the right', Icons.view_sidebar_outlined),
  top('Docked at the top', Icons.border_top),
  bottom('Docked at the bottom', Icons.border_bottom);

  final String label;
  final IconData icon;
  const TeamChatMode(this.label, this.icon);

  bool get docked => this == TeamChatMode.top || this == TeamChatMode.bottom;

  static TeamChatMode byName(Object? name) => TeamChatMode.values
      // Slides out from the right, like the CTS Assistant, until someone
      // picks another way.
      .firstWhere((m) => m.name == name, orElse: () => TeamChatMode.slideOut);
}

/// The team chat over the app (one at a time): a floating panel, a panel that
/// slides out from the right like the CTS Assistant, or docked across the
/// top or bottom like the built-in browser - where the page makes room for
/// it ([reserved], applied by [TeamChatInset]). The way it was last shown,
/// and how big, are remembered (window_memory.json).
class TeamChatPanel {
  TeamChatPanel._();
  static final TeamChatPanel instance = TeamChatPanel._();

  OverlayEntry? _entry;
  final ValueNotifier<String> _draft = ValueNotifier('');

  /// How it is shown. Changing it moves an open chat at once.
  late final ValueNotifier<TeamChatMode> mode = ValueNotifier(
      TeamChatMode.byName(TeamHost.readSetting('teamChatMode')));

  /// A docked chat's share of the height the page has.
  late final ValueNotifier<double> dockShare = ValueNotifier(
      ((TeamHost.readSetting('teamChatShare') as num?) ?? 0.45)
          .toDouble()
          .clamp(0.2, 0.7));

  /// The slide-out's width, in layout pixels.
  late final ValueNotifier<double> slideWidth = ValueNotifier(
      ((TeamHost.readSetting('teamChatWidth') as num?) ?? 600)
          .toDouble()
          .clamp(340.0, 1100.0));

  /// The edge of the window a docked chat takes, so the page can make room.
  static final ValueNotifier<EdgeInsets> reserved =
      ValueNotifier(EdgeInsets.zero);

  /// How much of the right edge a slid-out chat covers, so the floating
  /// buttons there can move aside.
  static final ValueNotifier<double> rightCover = ValueNotifier(0);

  /// [TEAM CHAT]: the slid-out panel's width WHILE its edge is being dragged
  /// (null otherwise). Only the floating chat button listens, so it can ride
  /// along with the edge without the page re-laying out on every step.
  static final ValueNotifier<double?> dragCover = ValueNotifier(null);

  /// Room already taken at the right edge (the CTS Assistant, 400 wide when
  /// open): a slid-out chat sits just left of it.
  static final ValueNotifier<double> rightOffset = ValueNotifier(0);

  bool get isOpen => _entry != null;

  /// [isOpen], to listen to.
  final ValueNotifier<bool> showing = ValueNotifier(false);

  /// Filling the app's window, whichever mode it is in.
  final ValueNotifier<bool> maximized = ValueNotifier(false);

  /// Puts the chat in a window of its own (set by the dashboard, which owns
  /// the pop-out host). Null: no pop-out button.
  static VoidCallback? onPopOut;

  /// Showing the team members inside the chat instead of the messages.
  final ValueNotifier<bool> showingMembers = ValueNotifier(false);

  /// [TEAM CHAT]: the room the chat was opened from (the Room Hub's chat
  /// button). The chat does not jump to its thread; it offers a button to
  /// go to it, or start it. '' for the room on screen.
  final ValueNotifier<String> contextRoom = ValueNotifier('');

  /// Opens the chat on the team members.
  void openMembers(BuildContext context) {
    showingMembers.value = true;
    open(context);
  }

  void toggle(BuildContext context) => isOpen ? close() : open(context);

  void setMode(TeamChatMode m) {
    mode.value = m;
    TeamHost.writeSetting('teamChatMode', m.name);
  }

  /// Opens it on [channel], with [draft] typed in, when given. [room]: the
  /// room it was opened from, offered as a button rather than shown.
  void open(BuildContext context,
      {String? channel, String? draft, String? room}) {
    final chat = Team.chat;
    if (chat == null) return;
    contextRoom.value = room ?? '';
    if (channel != null) chat.selectChannel(channel);
    if (draft != null) _draft.value = draft;
    // Opened again while sliding away: it turns round instead of a second
    // one starting.
    final back = _leavingEntry;
    if (back != null) {
      _leaveTimer?.cancel();
      _leavingEntry = null;
      _entry = back;
      leaving.value = false;
      showing.value = true;
      chat.setOpen(true);
      return;
    }
    if (_entry != null) {
      chat.setOpen(true);
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (_) => _ChatHost(
        panel: this,
        // Its own layer: moving or resizing the frame does not repaint the
        // messages.
        body: RepaintBoundary(child: _ChatBody(chat: chat, draft: _draft)),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    showing.value = true;
    chat.setOpen(true);
  }

  /// [TEAM CHAT]: a slid-out chat sliding back off the edge before it goes,
  /// the way the CTS Assistant does - it used to vanish on the spot.
  final ValueNotifier<bool> leaving = ValueNotifier(false);
  OverlayEntry? _leavingEntry;
  Timer? _leaveTimer;

  /// How long the slide in and out takes - the Assistant's 300 ms.
  static const Duration slideDuration = Duration(milliseconds: 300);

  void close() {
    final entry = _entry;
    _entry = null;
    final bool slideAway = entry != null &&
        mode.value == TeamChatMode.slideOut &&
        !maximized.value;
    reserved.value = EdgeInsets.zero;
    rightCover.value = 0;
    dragCover.value = null;
    showing.value = false;
    maximized.value = false;
    showingMembers.value = false;
    Team.chat?.setOpen(false);
    if (slideAway) {
      _leavingEntry = entry;
      leaving.value = true;
      _leaveTimer?.cancel();
      _leaveTimer = Timer(slideDuration, () {
        if (!identical(_leavingEntry, entry)) return;
        _leavingEntry = null;
        leaving.value = false;
        try {
          entry.remove();
        } catch (_) {}
      });
      return;
    }
    try {
      entry?.remove();
    } catch (_) {}
  }
}

/// Lays [child] out in the part of the window a docked team chat leaves
/// free. Wrap the app's page in it, outside [InAppBrowserInset], so a chat
/// and a browser docked together both get their room.
class TeamChatInset extends StatelessWidget {
  final Widget child;
  const TeamChatInset({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeInsets>(
        valueListenable: TeamChatPanel.reserved,
        child: child,
        builder: (context, inset, child) => AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          padding: inset,
          child: child,
        ),
      );
}

/// The menu that moves the chat between its four places.
class _ChatModeMenu extends StatelessWidget {
  final TeamChatPanel panel;
  const _ChatModeMenu({required this.panel});

  @override
  Widget build(BuildContext context) => MenuAnchor(
        builder: (context, controller, _) => IconButton(
          key: const ValueKey('team_chat_mode'),
          tooltip: 'Where the chat sits',
          visualDensity: VisualDensity.compact,
          icon: Icon(panel.mode.value.icon, size: 18),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
        menuChildren: [
          for (final m in TeamChatMode.values)
            MenuItemButton(
              key: ValueKey('team_chat_mode_${m.name}'),
              leadingIcon: Icon(m.icon, size: 18),
              trailingIcon: m == panel.mode.value
                  ? const Icon(Icons.check, size: 16)
                  : null,
              onPressed: () => panel.setMode(m),
              child: Text(m.label),
            ),
        ],
      );
}

class _ChatHost extends StatefulWidget {
  final TeamChatPanel panel;
  final Widget body;
  const _ChatHost({required this.panel, required this.body});

  @override
  State<_ChatHost> createState() => _ChatHostState();
}

class _ChatHostState extends State<_ChatHost> {
  TeamChatPanel get panel => widget.panel;

  /// A drag on a docked or slid-out edge, applied when let go.
  double? _dragShare;
  double? _dragWidth;

  @override
  void initState() {
    super.initState();
    panel.mode.addListener(_changed);
    panel.maximized.addListener(_changed);
    panel.dockShare.addListener(_changed);
    panel.slideWidth.addListener(_changed);
    TeamHost.reservedEdges.addListener(_changed);
    TeamChatPanel.rightOffset.addListener(_changed);
    panel.leaving.addListener(_changed);
  }

  @override
  void dispose() {
    panel.mode.removeListener(_changed);
    panel.maximized.removeListener(_changed);
    panel.dockShare.removeListener(_changed);
    panel.slideWidth.removeListener(_changed);
    TeamHost.reservedEdges.removeListener(_changed);
    TeamChatPanel.rightOffset.removeListener(_changed);
    panel.leaving.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Tells the page how much room to make. After the frame: changing the
  /// page's padding mid-build would be a setState during build.
  void _publish(EdgeInsets inset, {double cover = 0}) {
    if (TeamChatPanel.reserved.value == inset &&
        TeamChatPanel.rightCover.value == cover) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!panel.isOpen || !mounted) return;
      TeamChatPanel.reserved.value = inset;
      TeamChatPanel.rightCover.value = cover;
    });
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const Icon(Icons.forum_outlined, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Team chat',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          _membersButton(),
          if (TeamChatPanel.onPopOut != null) _popOutButton(),
          _maxButton(),
          _ChatModeMenu(panel: panel),
          IconButton(
            key: const ValueKey('team_chat_close'),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: panel.close,
          ),
        ],
      ),
    );
  }

  /// [TEAM]: who is on the dashboard - the team page - from inside the chat,
  /// with how many others are online.
  Widget _membersButton() {
    final presence = Team.presence;
    return ListenableBuilder(
      listenable: presence ?? ValueNotifier(0),
      builder: (context, _) {
        final online = presence?.others.length ?? 0;
        return IconButton(
          key: const ValueKey('team_chat_members'),
          tooltip: online == 0
              ? 'Team members (nobody else online)'
              : 'Team members ($online online)',
          visualDensity: VisualDensity.compact,
          icon: Badge(
            isLabelVisible: online > 0,
            backgroundColor: Colors.green,
            label: Text('$online'),
            child: const Icon(Icons.groups_outlined, size: 18),
          ),
          // In the chat, not a dialog: a dialog would open behind it.
          onPressed: () => TeamChatPanel.instance.showingMembers.value =
              !TeamChatPanel.instance.showingMembers.value,
        );
      },
    );
  }

  Widget _popOutButton() => IconButton(
        key: const ValueKey('team_chat_pop_out'),
        tooltip: 'Its own window',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.open_in_new, size: 18),
        onPressed: () {
          TeamChatPanel.onPopOut?.call();
          panel.close();
        },
      );

  Widget _maxButton() => IconButton(
        key: const ValueKey('team_chat_maximize'),
        tooltip: panel.maximized.value ? 'Restore' : 'Maximize',
        visualDensity: VisualDensity.compact,
        icon: Icon(
            panel.maximized.value ? Icons.fullscreen_exit : Icons.fullscreen,
            size: 18),
        onPressed: () => panel.maximized.value = !panel.maximized.value,
      );

  /// The grip on the edge facing the page; [vertical] for a top/bottom dock.
  Widget _grip({
    required bool vertical,
    required GestureDragUpdateCallback onDrag,
    required VoidCallback onEnd,
  }) {
    return MouseRegion(
      cursor: vertical
          ? SystemMouseCursors.resizeUpDown
          : SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        key: const ValueKey('team_chat_resize'),
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onPanUpdate: onDrag,
        onPanEnd: (_) => onEnd(),
        onPanCancel: onEnd,
        child: Container(
          width: vertical ? double.infinity : 6,
          height: vertical ? 6 : double.infinity,
          color: Theme.of(context).dividerColor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = panel.mode.value;
    if (panel.maximized.value) {
      // Over the whole app (inside a docked browser), with the page left as
      // it is underneath - restoring puts it back where it was.
      _publish(EdgeInsets.zero);
      final browser = TeamHost.reservedEdges.value;
      return Stack(children: [
        Positioned.fill(
          left: 8,
          right: 8,
          top: browser.top + 8,
          bottom: browser.bottom + 8,
          child: Material(
            elevation: 16,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                Expanded(child: widget.body),
              ],
            ),
          ),
        ),
      ]);
    }
    if (mode == TeamChatMode.floating) {
      _publish(EdgeInsets.zero);
      return TeamFloatingPanelFrame(
        // A new key: the panel opens at the new, larger size once, then
        // remembers wherever it is put.
        geometryKey: 'team_chat_v2',
        title: 'Team chat',
        initialSize: const Size(1000, 680),
        minSize: const Size(560, 380),
        liveResize: true,
        onClose: panel.close,
        titleBarActions: [
          _membersButton(),
          if (TeamChatPanel.onPopOut != null) _popOutButton(),
          _maxButton(),
          _ChatModeMenu(panel: panel),
        ],
        child: widget.body,
      );
    }
    final theme = Theme.of(context);
    final browser = TeamHost.reservedEdges.value;
    return LayoutBuilder(builder: (context, box) {
      final area = box.biggest;
      final frame = Material(
        elevation: 12,
        color: theme.scaffoldBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            Expanded(child: widget.body),
          ],
        ),
      );

      if (mode == TeamChatMode.slideOut) {
        // Over the page, like the CTS Assistant; between a browser docked at
        // the top and one at the bottom.
        final maxW = (area.width - 200).clamp(340.0, 1100.0);
        // [PERFORMANCE - RESIZE]: the panel keeps its size while its edge is
        // dragged - a guide line shows where it will go - and takes the new
        // width once on release. Re-laying out the whole chat (and moving the
        // floating buttons) on every step of the drag is what made it lag.
        // [TEAM CHAT]: the edge drags live, like the configurator's chat -
        // the panel follows the pointer. Only the page (the floating
        // buttons beside it) waits for the release: moving those on every
        // step is what made the old live drag lag.
        final double settled = panel.slideWidth.value.clamp(340.0, maxW);
        final double w = (_dragWidth ?? settled).clamp(340.0, maxW);
        if (!panel.leaving.value) _publish(EdgeInsets.zero, cover: settled);
        return Stack(children: [
          AnimatedPositioned(
            duration: _dragWidth != null
                ? Duration.zero
                : const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            right: TeamChatPanel.rightOffset.value,
            top: browser.top,
            bottom: browser.bottom,
            width: w,
            child: RepaintBoundary(
              // In from the edge on open and back out on close, over the
              // Assistant's 300 ms and curve.
              child: TweenAnimationBuilder<double>(
              key: const ValueKey('team_chat_slide'),
              tween: Tween(begin: 1, end: panel.leaving.value ? 1 : 0),
              duration: TeamChatPanel.slideDuration,
              curve: Curves.easeInOut,
              builder: (context, t, child) => FractionalTranslation(
                  translation: Offset(t, 0), child: child),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _grip(
                    vertical: false,
                    onDrag: (d) {
                      setState(
                          () => _dragWidth = (_dragWidth ?? w) - d.delta.dx);
                      TeamChatPanel.dragCover.value =
                          _dragWidth!.clamp(340.0, maxW);
                    },
                    onEnd: () {
                      final v = _dragWidth;
                      _dragWidth = null;
                      TeamChatPanel.dragCover.value = null;
                      if (v == null) return;
                      panel.slideWidth.value = v.clamp(340.0, 1100.0);
                      TeamHost.writeSetting(
                          'teamChatWidth', panel.slideWidth.value.round());
                    },
                  ),
                  Expanded(child: frame),
                ],
              ),
            ),
            ),
          ),
        ]);
      }

      // Docked: across the top or bottom, inside any docked browser.
      final free = (area.height - browser.top - browser.bottom)
          .clamp(0.0, double.infinity);
      double heightFor(double share) => (free * share.clamp(0.2, 0.7))
          .clamp(160.0, free < 160 ? 160.0 : free);
      // The docked chat keeps its height while its edge is dragged (a guide
      // line shows the new one) and the page makes room once, on release.
      final h = heightFor(panel.dockShare.value);
      final top = mode == TeamChatMode.top;
      _publish(top ? EdgeInsets.only(top: h) : EdgeInsets.only(bottom: h));
      final double? guideH =
          _dragShare == null ? null : heightFor(_dragShare!);
      final grip = _grip(
        vertical: true,
        onDrag: (d) {
          if (free <= 0) return;
          final change = (top ? d.delta.dy : -d.delta.dy) / free;
          setState(() => _dragShare =
              ((_dragShare ?? panel.dockShare.value) + change).clamp(0.2, 0.7));
        },
        onEnd: () {
          final v = _dragShare;
          _dragShare = null;
          if (v == null) return;
          panel.dockShare.value = v;
          TeamHost.writeSetting('teamChatShare', (v * 1000).round() / 1000);
        },
      );
      return Stack(children: [
        Positioned(
          left: 0,
          right: 0,
          top: top ? browser.top : null,
          bottom: top ? null : browser.bottom,
          height: h,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!top) grip,
              Expanded(child: frame),
              if (top) grip,
            ],
          ),
        ),
        if (guideH != null)
          Positioned(
            left: 0,
            right: 0,
            top: top ? browser.top : null,
            bottom: top ? null : browser.bottom,
            height: guideH,
            child: const IgnorePointer(child: _ResizeOutline()),
          ),
      ]);
    });
  }
}

class _ChatBody extends StatefulWidget {
  final TeamChat chat;
  final ValueNotifier<String> draft;
  const _ChatBody({required this.chat, required this.draft});

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

/// [TEAM CHAT - 1.23.0]: the quick reactions on a message's hover bar.
const List<String> _kQuickReactions = ['👍', '❤️', '😂', '🎉', '✅', '👀'];

class _ChatBodyState extends State<_ChatBody> {
  final _text = ChatFormatController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String _error = '';
  bool _sending = false;

  /// [TEAM CHAT]: search is a button that opens into a bar. Open, it lists
  /// the room threads (all of them while nothing is typed) and the messages
  /// that match.
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  String _query = '';

  /// The message under the pointer (its hover bar shows), and the one whose
  /// emoji menu is open (its bar stays while the pointer is in the menu).
  String? _hoverId;
  String? _menuOpenFor;

  /// The message being edited in place.
  String? _editingId;
  final _edit = ChatFormatController();

  /// [TEAM CHAT - FORMATTING]: the bar of bold, italic, fonts and colors
  /// above the box you write in.
  bool _formatOpen = false;

  /// [TEAM CHAT]: the "+" panel - find or start a thread, message someone,
  /// or make a group - shown in place of the messages.
  bool _newOpen = false;
  bool _groupMode = false;
  final _newSearch = TextEditingController();
  final _groupName = TextEditingController();
  final Set<String> _groupPick = {};
  final _editFocus = FocusNode();

  /// Pictures waiting to go with the next message (pasted or attached).
  final List<ClipboardPicture> _pending = [];

  bool _gifOpen = false;

  /// A picture shown full size over the chat.
  ChatAttachment? _viewing;

  TeamChat get chat => widget.chat;

  /// The thread whose own-message delete is waiting on a yes.
  ChatChannel? _confirmDelete;

  @override
  void initState() {
    super.initState();
    chat.addListener(_changed);
    widget.draft.addListener(_takeDraft);
    TeamChatPanel.instance.showingMembers.addListener(_changed);
    TeamChatPanel.instance.contextRoom.addListener(_changed);
    Team.presence?.addListener(_changed);
    ChatFormatController.hideMarkers.value =
        TeamHost.readSetting('chatHideMarkers') == true;
    ChatFormatController.hideMarkers.addListener(_changed);
    _takeDraft();
  }

  @override
  void dispose() {
    chat.removeListener(_changed);
    widget.draft.removeListener(_takeDraft);
    TeamChatPanel.instance.showingMembers.removeListener(_changed);
    TeamChatPanel.instance.contextRoom.removeListener(_changed);
    Team.presence?.removeListener(_changed);
    ChatFormatController.hideMarkers.removeListener(_changed);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _edit.dispose();
    _editFocus.dispose();
    _newSearch.dispose();
    _groupName.dispose();
    super.dispose();
  }

  void _takeDraft() {
    final d = widget.draft.value;
    if (d.isEmpty) return;
    _text.text = d;
    _text.selection = TextSelection.collapsed(offset: d.length);
    widget.draft.value = '';
    _focus.requestFocus();
  }

  void _changed() {
    if (!mounted) return;
    final atEnd = !_scroll.hasClients ||
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    setState(() {});
    if (atEnd && !_searchOpen) _toEnd();
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// The room the chat was opened from (the Room Hub's room), else the room
  /// on screen. The chat does not switch to its thread by itself; the
  /// header offers it.
  String get _hereRoom {
    final asked = TeamChatPanel.instance.contextRoom.value.trim();
    if (asked.isNotEmpty) return asked;
    return chat.whereAmI?.call().room.trim() ?? '';
  }

  void _openThread(String id) {
    _closeSearch();
    setState(() {
      _editingId = null;
      _newOpen = false;
    });
    chat.selectChannel(id, reopen: true);
    _toEnd();
    _focus.requestFocus();
  }

  // --- search ---------------------------------------------------------------

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    setState(() {
      _searchOpen = false;
      _query = '';
      _search.clear();
    });
    _toEnd();
  }

  // --- sending ----------------------------------------------------------------

  Future<void> _send() async {
    if (_sending) return;
    final pictures = List.of(_pending);
    if (_text.text.trim().isEmpty && pictures.isEmpty) return;
    // [TEAM CHAT - TOPICS]: "#word ..." goes to (and starts) #word's thread.
    var words = _text.text;
    final lead = topicLead(words);
    if (lead != null && lead.$1 != chat.channel) {
      _openThread(lead.$1);
      words = lead.$2;
      if (words.trim().isEmpty && pictures.isEmpty) {
        setState(() => _text.clear());
        return;
      }
    }
    setState(() => _sending = true);
    var problem = '';
    final attachments = <ChatAttachment>[];
    for (final p in pictures) {
      try {
        attachments.add(await chat.savePicture(p.bytes, p.ext,
            width: p.width, height: p.height));
      } catch (e) {
        problem = 'The picture could not be saved to the team folder: $e';
        break;
      }
    }
    if (problem.isEmpty) {
      problem = await chat.post(words, attachments: attachments);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = problem;
      if (problem.isEmpty) {
        _text.clear();
        _pending.clear();
      }
    });
    _focus.requestFocus();
    _toEnd();
  }

  Future<void> _postGif(GifResult g) async {
    setState(() => _gifOpen = false);
    final problem = await chat.post(_text.text, attachments: [
      ChatAttachment(kind: 'gif', url: g.url, width: g.width, height: g.height)
    ]);
    if (!mounted) return;
    setState(() {
      _error = problem;
      if (problem.isEmpty) _text.clear();
    });
    _focus.requestFocus();
    _toEnd();
  }

  /// Ctrl+V: words go in as words; with none on the clipboard, a screenshot
  /// or a copied picture file is added to the message.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final words = data?.text ?? '';
    if (words.isEmpty && ClipboardImage.hasPicture) {
      try {
        final pictures = await ClipboardImage.read();
        if (!mounted) return;
        if (pictures.isNotEmpty) {
          setState(() {
            _pending.addAll(pictures);
            _error = '';
          });
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() => _error = '$e'.replaceFirst('Bad state: ', ''));
        }
        return;
      }
    }
    if (words.isEmpty || !mounted) return;
    final v = _text.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    _text.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, words),
      selection: TextSelection.collapsed(offset: sel.start + words.length),
    );
    setState(() {});
  }

  Future<void> _attach() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: 'Pick a picture to post',
        type: FileType.custom,
        allowedExtensions: kChatPictureExtensions.toList(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open the file picker: $e');
      return;
    }
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      try {
        final file = File(path);
        final length = await file.length();
        if (length > kChatPictureMaxBytes) {
          setState(() => _error = '${f.name} is over '
              '${kChatPictureMaxBytes ~/ 1048576} MB.');
          continue;
        }
        final bytes = await file.readAsBytes();
        final size = await ClipboardImage.pictureSize(bytes);
        final dot = path.lastIndexOf('.');
        if (!mounted) return;
        setState(() => _pending.add(ClipboardPicture(
            bytes, path.substring(dot + 1).toLowerCase(), size.$1, size.$2,
            name: f.name)));
      } catch (e) {
        if (mounted) setState(() => _error = 'Could not read ${f.name}: $e');
      }
    }
    _focus.requestFocus();
  }

  void _insert(String s) {
    final v = _text.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    _text.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, s),
      selection: TextSelection.collapsed(offset: sel.start + s.length),
    );
    _focus.requestFocus();
    setState(() {});
  }

  // --- editing ----------------------------------------------------------------

  void _startEdit(TeamMessage m) {
    setState(() {
      _editingId = m.id;
      _edit.text = m.text;
      _edit.selection = TextSelection.collapsed(offset: m.text.length);
      _error = '';
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _editFocus.requestFocus());
  }

  Future<void> _saveEdit() async {
    final id = _editingId;
    if (id == null) return;
    final problem = await chat.editMessage(id, _edit.text);
    if (!mounted) return;
    setState(() {
      _error = problem;
      if (problem.isEmpty) _editingId = null;
    });
    if (problem.isEmpty) _focus.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editingId = null);
    _focus.requestFocus();
  }

  /// Up in an empty box edits your last message here, as in Teams.
  bool _editLast() {
    final mine = chat
        .shown()
        .where((m) => m.user.toLowerCase() == chat.me.user.toLowerCase());
    if (mine.isEmpty) return false;
    _startEdit(mine.last);
    return true;
  }

  Future<void> _react(TeamMessage m, String emoji) async {
    final problem = await chat.toggleReaction(m.id, emoji);
    if (mounted && problem.isNotEmpty) setState(() => _error = problem);
  }

  /// A thread's own menu: close it out of your list, or take back your
  /// messages in it.
  Widget _channelMenu(ChatChannel c) {
    final mine = chat.myMessageCount(c.id);
    if (!c.isRoom && mine == 0) return const SizedBox(width: 4);
    // A MenuAnchor, not a PopupMenuButton: its menu is drawn on the chat's
    // own layer. A pop-up menu is a route, and routes sit under the chat.
    return MenuAnchor(
      builder: (context, controller, _) => IconButton(
        key: ValueKey('team_chat_channel_menu_${c.id}'),
        tooltip: 'Thread options',
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        icon: const Icon(Icons.more_horiz, size: 16),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        if (c.isRoom)
          MenuItemButton(
            key: ValueKey('team_chat_close_${c.id}'),
            leadingIcon: const Icon(Icons.close, size: 18),
            onPressed: () => chat.closeChannel(c.id),
            child: const Text('Close this thread'),
          ),
        if (mine > 0)
          MenuItemButton(
            key: ValueKey('team_chat_delete_mine_${c.id}'),
            leadingIcon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => setState(() => _confirmDelete = c),
            child: Text('Delete my $mine message${mine == 1 ? '' : 's'} here'),
          ),
      ],
    );
  }

  /// The yes / no for deleting one's own messages, in the chat itself.
  Widget _deleteBar(ThemeData theme) {
    final c = _confirmDelete!;
    final mine = chat.myMessageCount(c.id);
    return Container(
      key: const ValueKey('team_chat_delete_confirm'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
                'Delete your $mine message${mine == 1 ? '' : 's'} in '
                "${c.label} for everyone? Other people's stay.",
                style: TextStyle(color: theme.colorScheme.onErrorContainer)),
          ),
          TextButton(
              onPressed: () => setState(() => _confirmDelete = null),
              child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('team_chat_delete_yes'),
            onPressed: () async {
              setState(() => _confirmDelete = null);
              final problem = await chat.deleteMyMessagesIn(c.id);
              if (mounted && problem.isNotEmpty) {
                setState(() => _error = problem);
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// The @word being typed at the cursor, or null.
  String? get _mentionPrefix {
    final sel = _text.selection.baseOffset;
    if (sel < 0) return null;
    final before = _text.text.substring(0, sel);
    final m = RegExp(r'@([A-Za-z0-9._-]*)$').firstMatch(before);
    return m?.group(1);
  }

  void _completeMention(String login) {
    final sel = _text.selection.baseOffset;
    final before = _text.text.substring(0, sel);
    final after = _text.text.substring(sel);
    final start = before.lastIndexOf('@');
    final next = '${before.substring(0, start)}@$login $after';
    _text.text = next;
    _text.selection = TextSelection.collapsed(offset: start + login.length + 2);
    _focus.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (TeamChatPanel.instance.showingMembers.value) {
      return _TeamPage(
        embedded: true,
        onClose: () => TeamChatPanel.instance.showingMembers.value = false,
      );
    }
    if (!chat.attached) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('The team folder is not set up, so there is nowhere to '
              'keep the chat. It is the "team" folder beside processors.json.'),
        ),
      );
    }
    final scheme = theme.colorScheme;
    final prefix = _mentionPrefix;
    final suggestions = prefix == null
        ? const <ChatPerson>[]
        : chat.people
            .where((p) =>
                p.login.toLowerCase() != chat.me.user.toLowerCase() &&
                (p.login.toLowerCase().startsWith(prefix.toLowerCase()) ||
                    p.name.toLowerCase().startsWith(prefix.toLowerCase())))
            .take(6)
            .toList();

    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sidebar(theme),
        VerticalDivider(width: 1, color: scheme.outlineVariant),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _paneHeader(theme),
              Expanded(
                  child: _newOpen
                      ? _newConversation(theme)
                      : _searchOpen
                          ? _results(theme)
                          : _messages(theme)),
              if (!_searchOpen && !_newOpen) ...[
                if (suggestions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final p in suggestions)
                          ActionChip(
                            avatar: TeamAvatar(p.login, size: 18),
                            label: Text(p.label),
                            onPressed: () => _completeMention(p.login),
                          ),
                      ],
                    ),
                  ),
                if (_confirmDelete != null) _deleteBar(theme),
                if (_gifOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                    child: SizedBox(
                      height: 300,
                      child: _GifPicker(
                        teamFolder: File(chat.folder).parent.path,
                        user: chat.me.user,
                        onPick: _postGif,
                        onClose: () {
                          setState(() => _gifOpen = false);
                          _focus.requestFocus();
                        },
                      ),
                    ),
                  ),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: Row(children: [
                      Icon(Icons.error_outline, size: 16, color: scheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_error,
                            style: TextStyle(color: scheme.error, fontSize: 12)),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        visualDensity: VisualDensity.compact,
                        iconSize: 14,
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _error = ''),
                      ),
                    ]),
                  ),
                _composer(theme),
              ],
            ],
          ),
        ),
      ],
    );
    final viewing = _viewing;
    if (viewing == null) return body;
    return Stack(children: [
      Positioned.fill(child: body),
      Positioned.fill(child: _viewer(viewing)),
    ]);
  }

  // --- the thread list ---------------------------------------------------------

  Widget _sidebar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final channels = chat.channels;
    final rooms = channels.where((c) => c.isRoom).toList();
    final general = channels
        .where((c) => !c.isRoom && !c.isProject && !c.isPrivate)
        .toList();
    // [TEAM CHAT - PROJECTS]: every project with a thread, in every app -
    // closed or never opened here too - plus the one on screen.
    final projects = [
      for (final p in chat.projectThreads())
        channels.firstWhere((c) => c.id == p.id, orElse: () => p),
    ];
    final hereProject = Team.currentProject?.call().trim() ?? '';
    if (hereProject.isNotEmpty &&
        !projects.any((p) => p.id == projectChannel(hereProject))) {
      projects.insert(
          0,
          ChatChannel(
              id: projectChannel(hereProject), label: hereProject));
    }
    final private = channels.where((c) => c.isPrivate).toList();
    final presence = Team.presence;
    final online = presence == null || !presence.active
        ? const <TeamPresence>[]
        : presence.others;
    Widget label(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 4),
          child: Text(text,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600)),
        );
    return SizedBox(
      width: 220,
      child: Material(
        color: scheme.surfaceContainerLow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  Row(children: [
                    Expanded(child: label('CHANNELS')),
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 8),
                      child: IconButton(
                        key: const ValueKey('team_chat_new'),
                        tooltip: 'Add a thread, message someone, or start a '
                            'group',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: const Icon(Icons.add),
                        onPressed: _openNew,
                      ),
                    ),
                  ]),
                  for (final c in general) _channelTile(c, theme),
                  label('ROOM THREADS'),
                  if (rooms.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 12, 4),
                      child: Text(
                          'None open. Start one from a room, or search to '
                          'find every thread.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  for (final c in rooms) _channelTile(c, theme),
                  label('PROJECTS'),
                  if (projects.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 12, 4),
                      child: Text(
                          "None yet. A project's chat in the Room Config "
                          'Builder starts its thread here.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  for (final c in projects) _channelTile(c, theme),
                  label('DIRECT MESSAGES'),
                  if (private.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 12, 4),
                      child: Text(
                          'Click a name to message someone, or + for a '
                          'group.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  for (final c in private) _channelTile(c, theme),
                ],
              ),
            ),
            // [TEAM]: who is on and where, kept live as their notes change.
            if (presence != null && presence.active) ...[
              Divider(height: 1, color: scheme.outlineVariant),
              label('ONLINE NOW · ${online.length}'),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: online.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
                        child: Text('Nobody else right now.',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          for (final sessions in teamPeople(online))
                            _onlinePerson(sessions, theme),
                        ],
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// [TEAM KIT]: people in "Online now" whose app list is unfolded.
  final Set<String> _onlineOpen = {};

  /// One person in "Online now": their first app's row, with a coloured
  /// pip for each app they have open; with more than one, an arrow unfolds a
  /// row per app - its colour, its name, the page and the room.
  Widget _onlinePerson(List<TeamPresence> sessions, ThemeData theme) {
    final first = sessions.first;
    if (sessions.length == 1) return _onlineTile(first, theme);
    final key = first.user.toLowerCase();
    final open = _onlineOpen.contains(key);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(children: [
          _onlineTile(first, theme, apps: sessions),
          Positioned(
            right: 4,
            top: 0,
            bottom: 0,
            child: IconButton(
              key: ValueKey('team_chat_online_more_$key'),
              tooltip: open
                  ? 'Hide their apps'
                  : 'Show all ${sessions.length} apps they have open',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: Icon(open ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(
                  () => open ? _onlineOpen.remove(key) : _onlineOpen.add(key)),
            ),
          ),
        ]),
        if (open)
          for (final p in sessions)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 12, 4),
              child: Row(children: [
                Container(
                  width: 3,
                  height: 26,
                  decoration: BoxDecoration(
                    color: TeamAppStyle.color(p.app, theme.brightness),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        TeamAppTag(p.app, short: true),
                        const SizedBox(width: 6),
                        Text(teamVersionText(p),
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                      Text(
                          p.editing.isNotEmpty
                              ? 'Editing ${p.editing.first.label}'
                              : teamPlaceText(p),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: p.editing.isNotEmpty
                                  ? scheme.tertiary
                                  : scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ]),
            ),
      ],
    );
  }

  Widget _onlineTile(TeamPresence p, ThemeData theme,
      {List<TeamPresence>? apps}) {
    final scheme = theme.colorScheme;
    final editing = p.editing.isNotEmpty;
    final where = editing
        ? 'Editing ${p.editing.first.label}'
        : '${TeamAppStyle.short(p.app)}: ${teamPlaceText(p)}';
    return InkWell(
      key: ValueKey('team_chat_online_${p.user}'),
      onTap: () => _openThread(dmChannel(chat.me.user, p.user)),
      child: Tooltip(
        message: '${p.label}: $where\nClick to message them directly',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              TeamAvatar(p.user, size: 24),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: scheme.surfaceContainerLow, width: 1.5),
                  ),
                ),
              ),
            ]),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(chat.nameOf(p.user),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 6),
                    // A pip per app they have open, in its colour.
                    for (final a in apps ?? [p])
                      Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Tooltip(
                          message: '${teamAppName(a.app)} '
                              '${teamVersionText(a)}: ${teamPlaceText(a)}',
                          child: Icon(TeamAppStyle.icon(a.app),
                              size: 12,
                              color: TeamAppStyle.color(
                                  a.app, theme.brightness)),
                        ),
                      ),
                    if (apps != null) const SizedBox(width: 24),
                  ]),
                  Text(where,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: editing
                              ? scheme.tertiary
                              : scheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (p.room.isNotEmpty && Team.openRoom != null)
              IconButton(
                tooltip: 'Open ${p.room} in the Room Hub',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 26, height: 26),
                iconSize: 15,
                icon: const Icon(Icons.meeting_room_outlined),
                onPressed: () => Team.openRoom!(p.room),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _channelTile(ChatChannel c, ThemeData theme) {
    final scheme = theme.colorScheme;
    final selected = !_searchOpen && c.id == chat.channel;
    final bold = c.unread > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('team_chat_channel_${c.id}'),
          onTap: () => _openThread(c.id),
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  if (c.isDirect)
                    TeamAvatar(chat.otherIn(c.id), size: 20)
                  else
                  Icon(_iconFor(c.id),
                      size: 17,
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(c.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight:
                                bold ? FontWeight.bold : FontWeight.normal,
                            color: selected
                                ? scheme.onSecondaryContainer
                                : null)),
                  ),
                  if (c.mentions > 0)
                    Badge(
                        backgroundColor: scheme.error,
                        label: Text('@${c.mentions}'))
                  else if (c.unread > 0)
                    Badge(label: Text('${c.unread}')),
                  _channelMenu(c),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- the header: thread name, its room's thread, search ---------------------

  Widget _paneHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    final title = chat.labelOf(chat.channel);
    final count = chat.countIn(chat.channel);
    final group = chat.groupOf(chat.channel);
    final String subtitle = switch (chat.channel.split(':').first) {
      'room' => 'Room thread · $count message${count == 1 ? '' : 's'}',
      'project' => 'Project · $count message${count == 1 ? '' : 's'}',
      'topic' => 'Topic · $count message${count == 1 ? '' : 's'}',
      'dm' => 'Direct message',
      'group' => 'Group · ${group?.members.map(chat.nameOf).join(', ') ?? ''}',
      'all' => 'Everyone in every CTS app',
      _ => () {
          final app = appOfChannel(chat.channel);
          return app == null
              ? 'Everyone on the team'
              : 'Everyone using ${teamAppName(app)}';
        }(),
    };
    final here = _hereRoom;
    final hereId = here.isEmpty ? '' : roomChannel(here);
    final hereCount = hereId.isEmpty ? 0 : chat.countIn(hereId);
    final project = Team.currentProject?.call().trim() ?? '';
    final projectId = project.isEmpty ? '' : projectChannel(project);
    final projectCount = projectId.isEmpty ? 0 : chat.countIn(projectId);

    final Widget content;
    if (_searchOpen) {
      content = Row(
        key: const ValueKey('team_chat_search_bar'),
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
              },
              child: TextField(
                key: const ValueKey('team_chat_search'),
                controller: _search,
                focusNode: _searchFocus,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Search messages and room threads',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('team_chat_search_close'),
            tooltip: 'Close search (Esc)',
            icon: const Icon(Icons.close, size: 18),
            onPressed: _closeSearch,
          ),
        ],
      );
    } else {
      content = Row(
        key: const ValueKey('team_chat_title_bar'),
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_iconFor(chat.channel),
                size: 17, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                Text(subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          // [TEAM CHAT - PROJECTS]: the open project's thread, the same way.
          if (projectId.isNotEmpty && projectId != chat.channel)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FilledButton.tonalIcon(
                key: const ValueKey('team_chat_project_thread'),
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                icon: Icon(
                    projectCount > 0
                        ? Icons.work_outline
                        : Icons.add_comment_outlined,
                    size: 16),
                label: Text(projectCount > 0
                    ? '$project ($projectCount)'
                    : 'Start the $project thread'),
                onPressed: () => _openThread(projectId),
              ),
            ),
          // [TEAM CHAT]: opened from a room, the chat stays where it was and
          // offers the room's thread here instead of jumping to it.
          if (hereId.isNotEmpty && hereId != chat.channel)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FilledButton.tonalIcon(
                key: const ValueKey('team_chat_room_thread'),
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                icon: Icon(
                    hereCount > 0
                        ? Icons.forum_outlined
                        : Icons.add_comment_outlined,
                    size: 16),
                label: Text(hereCount > 0
                    ? '$here thread ($hereCount)'
                    : 'Start a $here thread'),
                onPressed: () => _openThread(hereId),
              ),
            ),
          IconButton(
            key: const ValueKey('team_chat_search_button'),
            tooltip: 'Search messages and room threads',
            icon: const Icon(Icons.search, size: 20),
            onPressed: _openSearch,
          ),
        ],
      );
    }
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SizeTransition(
              sizeFactor: a,
              axis: Axis.horizontal,
              alignment: Alignment.centerRight,
              child: child),
        ),
        child: content,
      ),
    );
  }

  // --- search results -----------------------------------------------------------

  Widget _results(ThemeData theme) {
    final scheme = theme.colorScheme;
    final q = _query.trim();
    final threads = chat.roomThreads(query: q);
    final have = {for (final t in threads) t.id.toLowerCase()};
    final norm = q.replaceAll(' ', '').toLowerCase();
    final rooms = q.isEmpty
        ? const <String>[]
        : (Team.knownRooms?.call() ?? const <String>[])
            .where((r) =>
                r.replaceAll(' ', '').toLowerCase().contains(norm) &&
                !have.contains(roomChannel(r).toLowerCase()))
            .take(6)
            .toList();
    final messages =
        q.isEmpty ? const <TeamMessage>[] : chat.shown(query: q).reversed.toList();
    Widget label(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600)),
        );
    // Its own Material: a floating chat paints its background in a box, and
    // the tiles' ink would be drawn under it.
    return Material(
      type: MaterialType.transparency,
      child: ListView(
      key: const ValueKey('team_chat_results'),
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        label(q.isEmpty
            ? 'ALL ROOM THREADS · ${threads.length}'
            : 'ROOM THREADS · ${threads.length + rooms.length}'),
        if (threads.isEmpty && rooms.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Text(
                q.isEmpty
                    ? 'No room has a thread yet.'
                    : 'No room thread matches "$q".',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        for (final t in threads)
          ListTile(
            key: ValueKey('team_chat_result_thread_${t.id}'),
            dense: true,
            leading: const Icon(Icons.meeting_room_outlined, size: 20),
            title: Text(t.label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              '${t.count} message${t.count == 1 ? '' : 's'}',
              if (t.last != null) 'last ${teamAgo(t.last!)}',
              if (chat.isClosed(t.id, t.last)) 'closed',
            ].join(' · ')),
            trailing: t.unread > 0 ? Badge(label: Text('${t.unread}')) : null,
            onTap: () => _openThread(t.id),
          ),
        for (final r in rooms)
          ListTile(
            key: ValueKey('team_chat_result_room_$r'),
            dense: true,
            leading: const Icon(Icons.add_comment_outlined, size: 20),
            title: Text(r),
            subtitle: const Text('No thread yet - start one'),
            onTap: () => _openThread(roomChannel(r)),
          ),
        if (q.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('Type to search every message, or a room to find its '
                'thread.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          )
        else ...[
          label('MESSAGES · ${messages.length}'),
          if (messages.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Text('No message matches "$q".',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          for (final m in messages) _message(m, true, theme, inSearch: true),
        ],
      ],
      ),
    );
  }

  // --- messages -----------------------------------------------------------------

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dayLabel(DateTime d) {
    final now = DateTime.now();
    if (_sameDay(d, now)) return 'Today';
    if (_sameDay(d, now.subtract(const Duration(days: 1)))) return 'Yesterday';
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
      'Saturday', 'Sunday'];
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'];
    final s = '${days[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
    return d.year == now.year ? s : '$s, ${d.year}';
  }

  Widget _messages(ThemeData theme) {
    final scheme = theme.colorScheme;
    final messages = chat.shown();
    if (messages.isEmpty) {
      final everyone = pinnedChannels.contains(chat.channel) ||
          appOfChannel(chat.channel) != null;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(everyone ? Icons.waving_hand_outlined : _iconFor(chat.channel),
                size: 40, color: scheme.outline),
            const SizedBox(height: 8),
            Text(
                everyone
                    ? 'No messages yet. Say hello to the team.'
                    : chat.channel.startsWith('dm:') ||
                            chat.channel.startsWith('group:')
                        ? 'No messages with ${chat.labelOf(chat.channel)} yet.'
                        : 'No messages in ${chat.labelOf(chat.channel)} yet.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    // Day dividers, and a person's run of messages under one name.
    final rows = <Object>[];
    TeamMessage? prev;
    for (final m in messages) {
      if (prev == null || !_sameDay(prev.at, m.at)) rows.add(m.at);
      final grouped = prev != null &&
          _sameDay(prev.at, m.at) &&
          prev.user.toLowerCase() == m.user.toLowerCase() &&
          m.at.difference(prev.at).inMinutes < 5;
      rows.add((m, !grouped));
      prev = m;
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final row = rows[i];
        if (row is DateTime) return _dayDivider(row, theme);
        final (m, head) = row as (TeamMessage, bool);
        return _message(m, head, theme);
      },
    );
  }

  Widget _dayDivider(DateTime d, ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Row(children: [
        Expanded(child: Divider(color: scheme.outlineVariant)),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(_dayLabel(d),
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(child: Divider(color: scheme.outlineVariant)),
      ]),
    );
  }

  Widget _message(TeamMessage m, bool head, ThemeData theme,
      {bool inSearch = false}) {
    final scheme = theme.colorScheme;
    final mine = m.user.toLowerCase() == chat.me.user.toLowerCase();
    final mentionsMe = m.mentionsUser(chat.me.user);
    final editing = _editingId == m.id;
    final hovered = (_hoverId == m.id || _menuOpenFor == m.id) && !editing;
    final reactions = chat.reactionsOf(m.id);
    final small = theme.textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant, fontSize: 11);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (head)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (mine)
                  Text(m.who,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700))
                else
                  // [TEAM CHAT]: a click on a name messages them directly.
                  Tooltip(
                    message: 'Message ${m.who} directly',
                    child: InkWell(
                      key: ValueKey('team_chat_name_${m.id}'),
                      borderRadius: BorderRadius.circular(4),
                      onTap: () =>
                          _openThread(dmChannel(chat.me.user, m.user)),
                      child: Text(m.who,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                  ),
                Text(_clock(m.at), style: small),
                // [TEAM KIT]: which app it was written in.
                TeamAppTag(m.app),
                if (inSearch)
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _openThread(m.channel),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      child: Text('in ${chat.labelOf(m.channel)}',
                          style: small?.copyWith(
                              color: scheme.primary,
                              decoration: TextDecoration.underline)),
                    ),
                  ),
                if (m.room.isNotEmpty &&
                    (m.channel == kChatAllApps ||
                        appOfChannel(m.channel) != null))
                  Text('looking at ${m.room}', style: small),
              ],
            ),
          ),
        if (editing)
          _editor(theme)
        else if (m.text.isNotEmpty || m.editedAt != null)
          _messageText(m, theme, small),
        if (m.attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in m.attachments) _picture(a, theme),
              ],
            ),
          ),
        if (reactions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final r in reactions) _reactionChip(m, r, theme),
                _EmojiButton(
                  icon: Icons.add_reaction_outlined,
                  tooltip: 'Add a reaction',
                  size: 16,
                  onPick: (e) => _react(m, e),
                  onOpenChanged: (open) => setState(
                      () => _menuOpenFor = open ? m.id : null),
                ),
              ],
            ),
          ),
      ],
    );

    return MouseRegion(
      onEnter: (_) {
        if (_hoverId != m.id) setState(() => _hoverId = m.id);
      },
      onExit: (_) {
        if (_hoverId == m.id) setState(() => _hoverId = null);
      },
      child: Container(
        key: ValueKey('team_chat_message_${m.id}'),
        margin: EdgeInsets.only(top: head ? 8 : 0),
        decoration: BoxDecoration(
          color: mentionsMe
              ? scheme.tertiaryContainer.withValues(alpha: 0.35)
              : (hovered || editing)
                  ? scheme.onSurface.withValues(alpha: 0.04)
                  : null,
          border: mentionsMe
              ? Border(left: BorderSide(color: scheme.tertiary, width: 3))
              : null,
        ),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(mentionsMe ? 13 : 16, 3, 16, 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 36,
                    child: head
                        ? Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: TeamAvatar(m.user, size: 34),
                          )
                        : hovered
                            ? Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(_clock(m.at).split(' ').last,
                                    style: small?.copyWith(fontSize: 10)),
                              )
                            : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: content),
                ],
              ),
            ),
            if (hovered && !inSearch)
              Positioned(
                top: 0,
                right: 12,
                child: _hoverBar(m, mine, theme),
              ),
          ],
        ),
      ),
    );
  }

  /// React, edit and delete, over the top-right corner of the message.
  Widget _hoverBar(TeamMessage m, bool mine, ThemeData theme) {
    final scheme = theme.colorScheme;
    Widget emoji(String e) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _react(m, e),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(e, style: const TextStyle(fontSize: 16)),
          ),
        );
    Widget action(IconData icon, String tip, VoidCallback onTap, {Key? key}) =>
        IconButton(
          key: key,
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          iconSize: 16,
          icon: Icon(icon),
          onPressed: onTap,
        );
    return Material(
      key: const ValueKey('team_chat_hover_bar'),
      elevation: 2,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _kQuickReactions.take(4)) emoji(e),
            _EmojiButton(
              icon: Icons.add_reaction_outlined,
              tooltip: 'More reactions',
              size: 16,
              onPick: (e) => _react(m, e),
              onOpenChanged: (open) =>
                  setState(() => _menuOpenFor = open ? m.id : null),
            ),
            if (mine) ...[
              SizedBox(
                  height: 18,
                  child: VerticalDivider(
                      width: 8, color: scheme.outlineVariant)),
              action(Icons.edit_outlined, 'Edit', () => _startEdit(m),
                  key: const ValueKey('team_chat_edit')),
              action(Icons.delete_outline, 'Delete for everyone', () async {
                final problem = await chat.deleteMessage(m.id);
                if (mounted && problem.isNotEmpty) {
                  setState(() => _error = problem);
                }
              }, key: const ValueKey('team_chat_delete')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _reactionChip(TeamMessage m, ChatReaction r, ThemeData theme) {
    final scheme = theme.colorScheme;
    final names = r.users.map(chat.nameOf).toList();
    return Tooltip(
      message: '${names.join(', ')} reacted with ${r.emoji}'
          '${r.mine ? '\nClick to take yours off' : ''}',
      child: InkWell(
        key: ValueKey('team_chat_reaction_${m.id}_${r.emoji}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _react(m, r.emoji),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: r.mine
                ? scheme.primaryContainer.withValues(alpha: 0.7)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: r.mine ? scheme.primary : scheme.outlineVariant),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(r.emoji, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            Text('${r.users.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: r.mine ? scheme.onPrimaryContainer : null)),
          ]),
        ),
      ),
    );
  }

  Widget _editor(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Focus(
            onKeyEvent: (node, e) {
              if (e is! KeyDownEvent) return KeyEventResult.ignored;
              if (e.logicalKey == LogicalKeyboardKey.escape) {
                _cancelEdit();
                return KeyEventResult.handled;
              }
              if (e.logicalKey == LogicalKeyboardKey.enter &&
                  !HardwareKeyboard.instance.isShiftPressed) {
                _saveEdit();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              key: const ValueKey('team_chat_edit_input'),
              controller: _edit,
              focusNode: _editFocus,
              minLines: 1,
              maxLines: 6,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: scheme.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Text('Enter to save · Esc to cancel',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const Spacer(),
            TextButton(onPressed: _cancelEdit, child: const Text('Cancel')),
            const SizedBox(width: 4),
            FilledButton(
              key: const ValueKey('team_chat_edit_save'),
              onPressed: _saveEdit,
              child: const Text('Save'),
            ),
          ]),
        ],
      ),
    );
  }

  /// A picture in a message, at most 360 x 260, opening full size on a
  /// click.
  Widget _picture(ChatAttachment a, ThemeData theme) {
    final scheme = theme.colorScheme;
    const maxW = 360.0, maxH = 260.0;
    double? w, h;
    if (a.width > 0 && a.height > 0) {
      final scale = [maxW / a.width, maxH / a.height, 1.0]
          .reduce((x, y) => x < y ? x : y);
      w = a.width * scale;
      h = a.height * scale;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget broken(Object _, Object? __, StackTrace? ___) => Container(
          width: w ?? 200,
          height: h ?? 120,
          color: scheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.broken_image_outlined, color: scheme.outline),
            const SizedBox(height: 4),
            Text(a.isWeb ? 'GIF not available' : 'Picture not found',
                style: theme.textTheme.labelSmall),
          ]),
        );
    final Widget image = a.isWeb
        ? Image.network(a.url,
            width: w, height: h, fit: BoxFit.cover, errorBuilder: broken)
        : Image.file(File(chat.pathOf(a)),
            width: w,
            height: h,
            fit: BoxFit.cover,
            // Decoded at the size shown: a screenshot is a 1080p picture.
            cacheWidth: w == null ? 720 : (w * dpr).round(),
            errorBuilder: broken);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _viewing = a),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxW, maxHeight: maxH),
              child: image,
            ),
          ),
        ),
      ),
    );
  }

  /// A picture full size, over the chat (a dialog would open behind it).
  Widget _viewer(ChatAttachment a) {
    final String path = a.isWeb ? '' : chat.pathOf(a);
    void close() => setState(() => _viewing = null);
    return Focus(
      autofocus: true,
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        key: const ValueKey('team_chat_picture_viewer'),
        color: Colors.black.withValues(alpha: 0.88),
        child: Stack(children: [
          Positioned.fill(
            child: GestureDetector(onTap: close),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(
                  child: a.isWeb
                      ? Image.network(a.url, fit: BoxFit.contain)
                      : Image.file(File(path), fit: BoxFit.contain),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Row(children: [
              IconButton(
                tooltip: a.isWeb ? 'Open in the browser' : 'Open the file',
                color: Colors.white,
                icon: const Icon(Icons.open_in_new),
                onPressed: () => launchUrl(
                    a.isWeb ? Uri.parse(a.url) : Uri.file(path)),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: close,
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// The icon for a kind of conversation.
  IconData _iconFor(String id) {
    if (id == kChatAllApps) return Icons.public;
    final app = appOfChannel(id);
    if (app != null) return TeamAppStyle.icon(app);
    if (id.startsWith('room:')) return Icons.meeting_room_outlined;
    if (id.startsWith('project:')) return Icons.work_outline;
    if (id.startsWith('dm:')) return Icons.person_outline;
    if (id.startsWith('group:')) return Icons.group_outlined;
    return Icons.tag;
  }

  /// [TEAM KIT - EFFECTS]: a message's words - its text effects playing and
  /// its emoji moving (unless turned off), an emoji-only message large.
  Widget _messageText(TeamMessage m, ThemeData theme, TextStyle? small) =>
      _formattedText(m.text, theme,
          edited: m.editedAt == null
              ? null
              : TextSpan(
                  text: '  (edited)',
                  style: small?.copyWith(fontStyle: FontStyle.italic)));

  Widget _formattedText(String text, ThemeData theme,
      {InlineSpan? edited, bool preview = false}) {
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodyMedium ?? const TextStyle();
    final jumbo = ChatFormat.isEmojiOnly(text);
    final emojiSize = jumbo ? 44.0 : (base.fontSize ?? 14) * 1.35;
    var moving = false;
    final spans = <InlineSpan>[
      ...ChatFormat.spans(
        text,
        hideStray: preview,
        base: jumbo ? base.copyWith(fontSize: 34) : base,
        scheme: scheme,
        onHashtag: (tag) {
          final id = topicChannel(tag);
          if (id != null) _openThread(id);
        },
        onLink: (url) => teamOpenLink(url),
        onEffect: teamAnimateText
            ? (words, effect, style) {
                moving = true;
                // One box per word, not one for the whole phrase: a single
                // box cannot wrap, so a long effect ran off the side of the
                // chat. The spaces stay text, where the line can break.
                final total = words.replaceAll(RegExp(r'\s'), '').length;
                var from = 0;
                return TextSpan(children: [
                  for (final piece in RegExp(r'\s+|\S+').allMatches(words))
                    if (piece[0]!.trim().isEmpty)
                      TextSpan(text: piece[0], style: style)
                    else
                      () {
                        final word = piece[0]!;
                        final span = WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: TeamTextEffect(
                              text: word,
                              effect: effect,
                              style: style,
                              letterFrom: from,
                              letterCount: total),
                        );
                        from += word.length;
                        return span;
                      }(),
                ]);
              }
            : null,
        onEmoji: teamAnimateEmoji
            ? (emoji, style) {
                moving = true;
                return WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: TeamAnimatedEmoji(emoji,
                        size: emojiSize, style: style),
                  ),
                );
              }
            : null,
      ),
      if (edited != null) edited,
    ];
    return moving
        ? Text.rich(TextSpan(children: spans))
        : SelectableText.rich(TextSpan(children: spans));
  }

  // --- formatting ---------------------------------------------------------------

  final _colorMenu = MenuController();

  void _format(String open, String close) {
    _text.toggle(open, close);
    _focus.requestFocus();
    setState(() {});
  }

  Widget _formatBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    Widget style(String label, String tip, String open, String close,
            TextStyle look, {Key? key}) =>
        Tooltip(
          message: tip,
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(6),
            onTap: () => _format(open, close),
            child: SizedBox(
              width: 32,
              height: 30,
              child: Center(child: Text(label, style: look)),
            ),
          ),
        );
    Widget menu(IconData icon, String tip, List<Widget> items,
            {Key? key, MenuController? controller}) =>
        MenuAnchor(
          controller: controller,
          menuChildren: items,
          builder: (context, controller, _) => _ComposerTool(
            key: key,
            icon: icon,
            tooltip: tip,
            size: 30,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        );
    final base = TextStyle(color: scheme.onSurface, fontSize: 15);
    return Container(
      key: const ValueKey('team_chat_format_bar'),
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        children: [
          style('B', 'Bold (Ctrl+B)', '**', '**',
              base.copyWith(fontWeight: FontWeight.w800),
              key: const ValueKey('team_chat_bold')),
          style('I', 'Italic (Ctrl+I)', '*', '*',
              base.copyWith(fontStyle: FontStyle.italic)),
          style('U', 'Underline (Ctrl+U)', '__', '__',
              base.copyWith(decoration: TextDecoration.underline)),
          style('S', 'Strikethrough', '~~', '~~',
              base.copyWith(decoration: TextDecoration.lineThrough)),
          style('</>', 'Code', '`', '`',
              base.copyWith(fontFamily: 'Consolas', fontSize: 13)),
          SizedBox(
              height: 20,
              child: VerticalDivider(width: 12, color: scheme.outlineVariant)),
          menu(Icons.font_download_outlined, 'Font', [
            for (final e in ChatFormat.fonts.entries)
              MenuItemButton(
                key: ValueKey('team_chat_font_${e.key}'),
                onPressed: () => _format('[font=${e.key}]', '[/font]'),
                child: Text(ChatFormat.fontLabels[e.key] ?? e.key,
                    style: TextStyle(fontFamily: e.value, fontSize: 15)),
              ),
          ], key: const ValueKey('team_chat_font')),
          menu(Icons.format_color_text, 'Color', [
            _ColorMenu(onPick: (color) {
              _colorMenu.close();
              _format('[color=$color]', '[/color]');
            }),
          ], key: const ValueKey('team_chat_color'), controller: _colorMenu),
          menu(Icons.format_size, 'Size', [
            for (final e in const {
              'small': 'Small',
              'large': 'Large',
              'huge': 'Huge',
            }.entries)
              MenuItemButton(
                onPressed: () => _format('[size=${e.key}]', '[/size]'),
                child: Text(e.value,
                    style: TextStyle(
                        fontSize: 14 * (ChatFormat.sizes[e.key] ?? 1))),
              ),
          ]),
          // [TEAM KIT - EFFECTS]: the iPhone's text effects, and the switches
          // for effects and moving emoji.
          menu(Icons.auto_awesome_outlined, 'Effects', [
            for (final e in ChatFormat.effects.entries)
              MenuItemButton(
                key: ValueKey('team_chat_fx_${e.key}'),
                onPressed: () => _format('[fx=${e.key}]', '[/fx]'),
                child: Text(e.value),
              ),
            const Divider(height: 8),
            CheckboxMenuButton(
              value: teamAnimateText,
              onChanged: (v) => setState(() =>
                  TeamHost.writeSetting('chatAnimateText', v == true)),
              child: const Text('Play text effects'),
            ),
            CheckboxMenuButton(
              value: teamAnimateEmoji,
              onChanged: (v) => setState(() =>
                  TeamHost.writeSetting('chatAnimateEmoji', v == true)),
              child: const Text('Animated emoji'),
            ),
          ], key: const ValueKey('team_chat_effects')),
          SizedBox(
              height: 20,
              child: VerticalDivider(width: 12, color: scheme.outlineVariant)),
          // [TEAM CHAT - FORMATTING]: the codes ([color=red], **) can be
          // hidden, leaving only the styled words in the box.
          _ComposerTool(
            key: const ValueKey('team_chat_hide_codes'),
            icon: ChatFormatController.hideMarkers.value
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            tooltip: ChatFormatController.hideMarkers.value
                ? 'Show the style codes'
                : 'Hide the style codes - show only the styled words',
            on: ChatFormatController.hideMarkers.value,
            size: 30,
            onPressed: () {
              final hide = !ChatFormatController.hideMarkers.value;
              ChatFormatController.hideMarkers.value = hide;
              TeamHost.writeSetting('chatHideMarkers', hide);
              _focus.requestFocus();
            },
          ),
          Text('Select words, then pick a style',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  // --- add a thread, message someone, start a group --------------------------

  void _openNew() {
    _closeSearch();
    setState(() {
      _newOpen = true;
      _groupMode = false;
      _newSearch.clear();
      _groupName.clear();
      _groupPick.clear();
    });
  }

  Widget _newConversation(ThemeData theme) {
    final scheme = theme.colorScheme;
    final raw = _newSearch.text.trim();
    final q = raw.replaceFirst(RegExp(r'^#+'), '').replaceAll(' ', '').toLowerCase();
    final everyone = chat.people
        .where((p) => p.login.toLowerCase() != chat.me.user.toLowerCase())
        .where((p) =>
            q.isEmpty ||
            '${p.login}${p.name}'.replaceAll(' ', '').toLowerCase().contains(q))
        .toList();
    Widget label(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600)),
        );
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('team_chat_new_search'),
            controller: _newSearch,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: _groupMode
                  ? 'Find people to add'
                  : 'A room, a #topic, or a person',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Back to the messages',
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() => _newOpen = false),
        ),
      ]),
    );

    if (_groupMode) {
      final picked = chat.people
          .where((p) => _groupPick.contains(p.login.toLowerCase()))
          .toList();
      return Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: TextField(
                key: const ValueKey('team_chat_group_name'),
                controller: _groupName,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Group name (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            header,
            if (picked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final p in picked)
                    InputChip(
                      avatar: TeamAvatar(p.login, size: 18),
                      label: Text(chat.nameOf(p.login)),
                      onDeleted: () => setState(
                          () => _groupPick.remove(p.login.toLowerCase())),
                    ),
                ]),
              ),
            Expanded(
              child: ListView(children: [
                for (final p in everyone)
                  CheckboxListTile(
                    key: ValueKey('team_chat_group_pick_${p.login}'),
                    dense: true,
                    secondary: TeamAvatar(p.login, size: 26),
                    title: Text(chat.nameOf(p.login)),
                    subtitle: p.name.trim().isEmpty ? null : Text(p.login),
                    value: _groupPick.contains(p.login.toLowerCase()),
                    onChanged: (v) => setState(() => v == true
                        ? _groupPick.add(p.login.toLowerCase())
                        : _groupPick.remove(p.login.toLowerCase())),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                TextButton(
                    onPressed: () => setState(() => _groupMode = false),
                    child: const Text('Back')),
                const Spacer(),
                FilledButton.icon(
                  key: const ValueKey('team_chat_group_create'),
                  icon: const Icon(Icons.group_add_outlined, size: 18),
                  label: Text(picked.isEmpty
                      ? 'Pick people'
                      : 'Start the group (${picked.length + 1})'),
                  onPressed: picked.isEmpty
                      ? null
                      : () async {
                          final problem = await chat.createGroup(
                              _groupName.text,
                              [for (final p in picked) p.login]);
                          if (!mounted) return;
                          setState(() {
                            _error = problem;
                            if (problem.isEmpty) _newOpen = false;
                          });
                          _focus.requestFocus();
                        },
                ),
              ]),
            ),
          ],
        ),
      );
    }

    final threads = chat.threads(query: raw);
    final have = {for (final t in threads) t.id.toLowerCase()};
    final rooms = q.isEmpty
        ? const <String>[]
        : (Team.knownRooms?.call() ?? const <String>[])
            .where((r) =>
                r.replaceAll(' ', '').toLowerCase().contains(q) &&
                !have.contains(roomChannel(r).toLowerCase()))
            .take(6)
            .toList();
    // [TEAM CHAT - PROJECTS]: any project the host knows can have its thread
    // started here, not only those that have one already.
    final projects = q.isEmpty
        ? const <String>[]
        : (Team.knownProjects?.call() ?? const <String>[])
            .where((p) =>
                p.replaceAll(' ', '').toLowerCase().contains(q) &&
                !have.contains(projectChannel(p).toLowerCase()))
            .toSet()
            .take(6)
            .toList();
    final topic = topicChannel(raw);
    final newTopic = topic != null &&
            !have.contains(topic) &&
            (raw.startsWith('#') || (rooms.isEmpty && projects.isEmpty))
        ? topic
        : null;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                ListTile(
                  key: const ValueKey('team_chat_new_group'),
                  dense: true,
                  leading: const Icon(Icons.group_add_outlined),
                  title: const Text('New group chat'),
                  subtitle: const Text('Pick the people to talk with'),
                  onTap: () => setState(() {
                    _groupMode = true;
                    _newSearch.clear();
                  }),
                ),
                if (newTopic != null)
                  ListTile(
                    key: const ValueKey('team_chat_new_topic'),
                    dense: true,
                    leading: const Icon(Icons.tag),
                    title: Text('Start ${chat.labelOf(newTopic)}'),
                    subtitle: const Text('A thread anyone can join, named by '
                        'its hashtag'),
                    onTap: () => _openThread(newTopic),
                  ),
                if (threads.isNotEmpty ||
                    rooms.isNotEmpty ||
                    projects.isNotEmpty)
                  label('THREADS'),
                for (final t in threads.take(12))
                  ListTile(
                    key: ValueKey('team_chat_new_thread_${t.id}'),
                    dense: true,
                    leading: Icon(_iconFor(t.id), size: 20),
                    title: Text(t.label),
                    subtitle: Text('${t.count} message${t.count == 1 ? '' : 's'}'
                        '${t.last == null ? '' : ' · last ${teamAgo(t.last!)}'}'),
                    onTap: () => _openThread(t.id),
                  ),
                for (final r in rooms)
                  ListTile(
                    key: ValueKey('team_chat_new_room_$r'),
                    dense: true,
                    leading: const Icon(Icons.add_comment_outlined, size: 20),
                    title: Text(r),
                    subtitle: const Text('No thread yet - start one'),
                    onTap: () => _openThread(roomChannel(r)),
                  ),
                for (final p in projects)
                  ListTile(
                    key: ValueKey('team_chat_new_project_$p'),
                    dense: true,
                    leading: const Icon(Icons.work_outline, size: 20),
                    title: Text(p),
                    subtitle: const Text('Project - no thread yet, start one'),
                    onTap: () => _openThread(projectChannel(p)),
                  ),
                if (everyone.isNotEmpty) label('MESSAGE SOMEONE'),
                for (final p in everyone.take(30))
                  ListTile(
                    key: ValueKey('team_chat_new_dm_${p.login}'),
                    dense: true,
                    leading: TeamAvatar(p.login, size: 26),
                    title: Text(chat.nameOf(p.login)),
                    subtitle: p.name.trim().isEmpty ? null : Text(p.login),
                    onTap: () =>
                        _openThread(dmChannel(chat.me.user, p.login)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- the box you write in -----------------------------------------------------

  Widget _composer(ThemeData theme) {
    final scheme = theme.colorScheme;
    final canSend =
        !_sending && (_text.text.trim().isNotEmpty || _pending.isNotEmpty);
    // Every button in the box the same 36 x 36, so they sit in one line.
    Widget tool(IconData icon, String tip, VoidCallback onTap,
            {bool on = false, Key? key}) =>
        _ComposerTool(
            key: key, icon: icon, tooltip: tip, on: on, onPressed: onTap);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_formatOpen) _formatBar(theme),
          // [TEAM CHAT - TOPICS]: says where a "#word ..." message will go.
          if (topicLead(_text.text) case (final id, final rest)
              when id != chat.channel)
            Padding(
              key: const ValueKey('team_chat_topic_hint'),
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Row(children: [
                Icon(Icons.tag, size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${rest.trim().isEmpty ? 'Enter opens' : 'Enter posts in'} '
                    '${chat.labelOf(id)}'
                    '${chat.threads(query: id.substring(6)).any((t) => t.id == id) ? '' : ' - a new thread, seen in every app'}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
          // [TEAM KIT - EFFECTS]: a text box cannot hold moving words, so
          // with the codes hidden (the eye) a message with an effect is
          // shown above the box as it will be sent, effects playing. Keyed
          // by the text, so they play again as it is edited.
          if (ChatFormatController.hideMarkers.value &&
              teamAnimateText &&
              _text.text.contains('[fx='))
            Container(
              key: const ValueKey('team_chat_fx_preview'),
              margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Tooltip(
                      message: 'How it will look',
                      child: Icon(Icons.auto_awesome,
                          size: 14, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Expanded(
                    child: KeyedSubtree(
                        key: ValueKey(_text.text),
                        child: _formattedText(_text.text, theme,
                            preview: true)),
                  ),
                ],
              ),
            ),
          if (_pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _pending.length; i++)
                    _pendingThumb(i, theme),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                tool(Icons.text_format, 'Formatting: bold, italic, fonts, '
                    'colors', () => setState(() => _formatOpen = !_formatOpen),
                    on: _formatOpen,
                    key: const ValueKey('team_chat_format')),
                tool(Icons.add_photo_alternate_outlined,
                    'Attach a picture\nor paste a screenshot with Ctrl+V',
                    _attach,
                    key: const ValueKey('team_chat_attach')),
                tool(Icons.gif_box_outlined, 'Find a GIF', () {
                  setState(() => _gifOpen = !_gifOpen);
                }, on: _gifOpen, key: const ValueKey('team_chat_gif')),
                _EmojiButton(
                  icon: Icons.emoji_emotions_outlined,
                  tooltip: 'Emoji',
                  size: 20,
                  box: 36,
                  onPick: _insert,
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, e) {
                      if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
                        return KeyEventResult.ignored;
                      }
                      final key = e.logicalKey;
                      final keys = HardwareKeyboard.instance;
                      if (key == LogicalKeyboardKey.enter &&
                          !keys.isShiftPressed) {
                        _send();
                        return KeyEventResult.handled;
                      }
                      if (key == LogicalKeyboardKey.keyV &&
                          keys.isControlPressed &&
                          !keys.isShiftPressed) {
                        _paste();
                        return KeyEventResult.handled;
                      }
                      if (keys.isControlPressed && e is KeyDownEvent) {
                        final marker = switch (key) {
                          LogicalKeyboardKey.keyB => '**',
                          LogicalKeyboardKey.keyI => '*',
                          LogicalKeyboardKey.keyU => '__',
                          _ => null,
                        };
                        if (marker != null) {
                          _format(marker, marker);
                          return KeyEventResult.handled;
                        }
                      }
                      if (key == LogicalKeyboardKey.arrowUp &&
                          e is KeyDownEvent &&
                          _text.text.isEmpty &&
                          _editLast()) {
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      key: const ValueKey('team_chat_input'),
                      controller: _text,
                      focusNode: _focus,
                      // Codes hidden: erasing steps over them and takes an
                      // emptied style's codes with it.
                      inputFormatters: [ChatCodeEraser()],
                      autofocus: true,
                      minLines: 1,
                      maxLines: 6,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 9),
                        hintText: 'Message '
                            '${chat.labelOf(chat.channel)}'
                            '  ·  @ to mention, # for a topic, Shift+Enter for a new line',
                        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                        // One line, cut short when narrow: a wrapped hint
                        // made the empty box several lines tall, so it rode
                        // up from the bottom in a narrow chat.
                        hintMaxLines: 1,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: IconButton.filled(
                    key: const ValueKey('team_chat_send'),
                    constraints:
                        const BoxConstraints.tightFor(width: 36, height: 36),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    tooltip: 'Send (Enter)',
                    iconSize: 18,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                    onPressed: canSend ? _send : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pendingThumb(int i, ThemeData theme) {
    final p = _pending[i];
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(p.bytes,
              key: ValueKey('team_chat_pending_$i'),
              width: 72,
              height: 72,
              fit: BoxFit.cover,
              cacheWidth: 144,
              errorBuilder: (_, __, ___) => Container(
                  width: 72,
                  height: 72,
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.image_outlined))),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: Material(
            color: theme.colorScheme.inverseSurface,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => setState(() => _pending.removeAt(i)),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(Icons.close,
                    size: 12, color: theme.colorScheme.onInverseSurface),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// [TEAM CHAT - FORMATTING]: the Color menu - the named colors, then a
/// picker for any other color (written [color=#rrggbb]), and the last few
/// picked with it. Inside the menu rather than a dialog: a dialog opened
/// from the chat would sit behind it. [onPick] gets a name or `#rrggbb`.
class _ColorMenu extends StatefulWidget {
  final void Function(String color) onPick;
  const _ColorMenu({required this.onPick});

  @override
  State<_ColorMenu> createState() => _ColorMenuState();
}

class _ColorMenuState extends State<_ColorMenu> {
  static const double _width = 220;
  static const double _areaHeight = 120;
  static const double _hueHeight = 14;
  static const int _recentKept = 8;
  static final _hexPattern = RegExp(r'^[0-9a-fA-F]{6}$');

  HSVColor _hsv = HSVColor.fromColor(const Color(0xFF1E88E5));
  late final _hex = TextEditingController(text: _hexOf(_hsv.toColor()));

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');

  /// The picker's last few colors, newest first, as `rrggbb`.
  static List<String> get _recent {
    final v = TeamHost.readSetting('chatRecentColors');
    return v is String && v.isNotEmpty ? v.split(',') : const [];
  }

  void _pick(String hex) {
    hex = hex.toLowerCase();
    TeamHost.writeSetting(
        'chatRecentColors',
        [hex, ..._recent.where((h) => h != hex)]
            .take(_recentKept)
            .join(','));
    widget.onPick('#$hex');
  }

  /// From the square or the hue bar: the box follows.
  void _set(HSVColor hsv) => setState(() {
        _hsv = hsv;
        _hex.text = _hexOf(hsv.toColor());
      });

  /// Typed in the box: the square and hue bar follow.
  void _typed(String text) {
    if (!_hexPattern.hasMatch(text)) return setState(() {});
    setState(() => _hsv = HSVColor.fromColor(
        Color(0xFF000000 | int.parse(text, radix: 16))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label =
        theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final color = _hsv.toColor();
    final valid = _hexPattern.hasMatch(_hex.text);
    final recent = _recent;

    Widget swatch(Color c, String tip, VoidCallback onTap, {Key? key}) =>
        Tooltip(
          message: tip,
          child: InkWell(
            key: key,
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outlineVariant)),
            ),
          ),
        );
    // How the color reads on a light and on a dark background.
    Widget sample(Color background) => Container(
          width: 34,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scheme.outlineVariant)),
          child: Text('Aa',
              style: TextStyle(
                  color: color, fontSize: 15, fontWeight: FontWeight.w600)),
        );
    void inArea(Offset p) => _set(_hsv
        .withSaturation((p.dx / _width).clamp(0.0, 1.0))
        .withValue(1 - (p.dy / _areaHeight).clamp(0.0, 1.0)));
    void onHue(Offset p) =>
        _set(_hsv.withHue((p.dx / _width).clamp(0.0, 1.0) * 360));

    return Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: _width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final e in ChatFormat.colors.entries)
                  swatch(e.value, e.key, () => widget.onPick(e.key),
                      key: ValueKey('team_chat_color_${e.key}')),
              ],
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Recent', style: label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final h in recent)
                    if (_hexPattern.hasMatch(h))
                      swatch(Color(0xFF000000 | int.parse(h, radix: 16)),
                          '#$h', () => _pick(h),
                          key: ValueKey('team_chat_color_recent_$h')),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Text('Any color', style: label),
            const SizedBox(height: 6),
            // Saturation across, brightness down, for the hue below.
            GestureDetector(
              key: const ValueKey('team_chat_color_area'),
              onPanDown: (d) => inArea(d.localPosition),
              onPanUpdate: (d) => inArea(d.localPosition),
              child: SizedBox(
                width: _width,
                height: _areaHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                            color: HSVColor.fromAHSV(1, _hsv.hue, 1, 1)
                                .toColor()),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                              gradient: LinearGradient(
                                  colors: [Colors.white, Color(0x00FFFFFF)])),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                                gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Color(0x00000000), Colors.black])),
                            child: SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: _hsv.saturation * _width - 7,
                      top: (1 - _hsv.value) * _areaHeight - 7,
                      child: IgnorePointer(
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: Colors.white, width: 2),
                              boxShadow: const [
                                BoxShadow(blurRadius: 2, color: Colors.black54)
                              ]),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              key: const ValueKey('team_chat_color_hue'),
              onPanDown: (d) => onHue(d.localPosition),
              onPanUpdate: (d) => onHue(d.localPosition),
              child: SizedBox(
                width: _width,
                height: _hueHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_hueHeight / 2),
                        gradient: LinearGradient(colors: [
                          for (var i = 0; i <= 6; i++)
                            HSVColor.fromAHSV(1, i * 60.0, 1, 1).toColor()
                        ]),
                      ),
                      child: const SizedBox.expand(),
                    ),
                    Positioned(
                      left: _hsv.hue / 360 * _width - 3,
                      top: -2,
                      bottom: -2,
                      child: IgnorePointer(
                        child: Container(
                          width: 6,
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(3),
                              boxShadow: const [
                                BoxShadow(blurRadius: 2, color: Colors.black54)
                              ]),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                sample(Colors.white),
                const SizedBox(width: 4),
                sample(const Color(0xFF202124)),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    key: const ValueKey('team_chat_color_hex'),
                    controller: _hex,
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                    decoration: const InputDecoration(
                        isDense: true,
                        prefixText: '#',
                        border: OutlineInputBorder()),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                      LengthLimitingTextInputFormatter(6),
                    ],
                    onChanged: _typed,
                    onSubmitted: (text) {
                      if (_hexPattern.hasMatch(text)) _pick(text);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  key: const ValueKey('team_chat_color_use'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 12)),
                  onPressed: valid ? () => _pick(_hex.text) : null,
                  child: const Text('Use'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// [TEAM CHAT]: one of the composer's buttons - all the same square, so the
/// picture, GIF, emoji and formatting buttons sit in one line.
class _ComposerTool extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool on;
  final double size;
  final VoidCallback onPressed;
  const _ComposerTool({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.on = false,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      isSelected: on,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      iconSize: size * 0.56,
      color: on ? scheme.primary : scheme.onSurfaceVariant,
      // No 48 px tap target round it: that made one button taller than the
      // rest and knocked the row out of line.
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: on ? scheme.primary.withValues(alpha: 0.12) : null,
      ),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

/// [TEAM CHAT]: an emoji button whose grid opens on the chat's own layer
/// (a MenuAnchor - a pop-up route would open behind the chat).
class _EmojiButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final double size;
  final ValueChanged<String> onPick;
  final ValueChanged<bool>? onOpenChanged;

  /// The square it takes; null: just round the icon.
  final double? box;
  const _EmojiButton({
    required this.icon,
    required this.tooltip,
    required this.onPick,
    this.size = 18,
    this.box,
    this.onOpenChanged,
  });

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton> {
  final _controller = MenuController();

  @override
  Widget build(BuildContext context) => MenuAnchor(
        controller: _controller,
        onOpen: () => widget.onOpenChanged?.call(true),
        onClose: () => widget.onOpenChanged?.call(false),
        menuChildren: [
          _EmojiGrid(onPick: (e) {
            _controller.close();
            widget.onPick(e);
          }),
        ],
        builder: (context, controller, _) => IconButton(
          tooltip: widget.tooltip,
          visualDensity: widget.box == null
              ? VisualDensity.compact
              : VisualDensity.standard,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(
              width: widget.box ?? widget.size + 12,
              height: widget.box ?? widget.size + 12),
          style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          iconSize: widget.size,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          icon: Icon(widget.icon),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      );
}

/// The emoji to pick from, by kind.
const List<(String, List<String>)> _kEmoji = [
  ('Smileys', [
    '😀', '😃', '😄', '😁', '😆', '😅', '😂', '🤣', '🙂', '😉', '😊', '😇',
    '😍', '🤩', '😘', '😋', '😜', '🤪', '🤔', '🤨', '😐', '😑', '😶', '🙄',
    '😏', '😬', '😌', '😴', '😷', '🤒', '🤯', '🥳', '😎', '🤓', '😕', '😟',
    '😮', '😲', '😳', '🥺', '😢', '😭', '😱', '😤', '😡', '🤬', '💀', '🙃',
  ]),
  ('Gestures', [
    '👍', '👎', '👌', '✌️', '🤞', '🤙', '👋', '👏', '🙌', '🙏', '💪', '👀',
    '🫡', '🤝', '✋', '☝️', '👉', '👈', '👆', '👇', '🤷', '🤦', '🙋', '🧠',
  ]),
  ('Work', [
    '✅', '❌', '⚠️', '❗', '❓', '💯', '🔥', '⭐', '🎉', '🚀', '💡', '📌',
    '📎', '📝', '📅', '⏰', '⏳', '🔧', '🔨', '🛠️', '🔌', '🔋', '💻', '🖥️',
    '🖨️', '📽️', '🎥', '📷', '🎤', '🔊', '🔇', '📺', '📡', '🌐', '🔒', '🔑',
  ]),
  ('Things', [
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '☕', '🍕', '🍩', '🍪',
    '🎂', '🍻', '🌮', '🏫', '🎓', '📚', '🌞', '🌧️', '❄️', '🌈', '🐛', '🦆',
  ]),
];

class _EmojiGrid extends StatefulWidget {
  final ValueChanged<String> onPick;
  const _EmojiGrid({required this.onPick});

  @override
  State<_EmojiGrid> createState() => _EmojiGridState();
}

/// [TEAM KIT - EMOJI]: the common ones first, then every emoji
/// (team_emoji_data.dart), with a search box that matches their names.
class _EmojiGridState extends State<_EmojiGrid> {
  final _search = TextEditingController();
  String _query = '';

  /// [TEAM KIT - EMOJI]: the emoji under the mouse, and its name. It moves
  /// in the grid - in the full list and in search results alike - and is
  /// shown large in the strip at the bottom, so you can see how it will look
  /// before picking it. A notifier, so a hover redraws one cell and the
  /// strip rather than the whole grid.
  final ValueNotifier<(String, String)?> _hovered = ValueNotifier(null);

  /// Every emoji's name, for the common ones' tooltips. Looked up with and
  /// without the U+FE0F that makes a sign show as an emoji.
  static final Map<String, String> _names = {
    for (final (_, list) in kTeamEmojiAll)
      for (final (e, name) in list) ...{
        e: name,
        e.replaceAll('\u{FE0F}', ''): name,
      },
  };

  @override
  void dispose() {
    _search.dispose();
    _hovered.dispose();
    super.dispose();
  }

  /// Every word typed must start a word of the name ("thumb up" finds
  /// "thumbs up sign").
  bool _matches(String name) {
    final words = name.split(RegExp(r'[\s-]+'));
    return _query
        .split(RegExp(r'\s+'))
        .where((q) => q.isNotEmpty)
        .every((q) => words.any((w) => w.startsWith(q)));
  }

  List<(String, List<(String, String)>)> get _sections {
    if (_query.isEmpty) {
      return [
        (
          'Common',
          [
            for (final (_, list) in _kEmoji)
              for (final e in list)
                (e, _names[e] ?? _names[e.replaceAll('\u{FE0F}', '')] ?? ''),
          ]
        ),
        ...kTeamEmojiAll,
      ];
    }
    final found = [
      for (final (_, list) in kTeamEmojiAll)
        for (final item in list)
          if (_matches(item.$2)) item,
    ];
    return [
      (found.isEmpty ? 'No emoji found' : '${found.length} found', found)
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = _sections;
    return SizedBox(
      width: 360,
      height: 428,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: TextField(
              key: const ValueKey('team_chat_emoji_search'),
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: 'Search emoji',
                border: const OutlineInputBorder(),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
              ),
              onChanged: (v) =>
                  setState(() => _query = v.trim().toLowerCase()),
              // Enter picks the first one found.
              onSubmitted: (_) {
                final first = sections.first.$2;
                if (_query.isNotEmpty && first.isNotEmpty) {
                  widget.onPick(first.first.$1);
                }
              },
            ),
          ),
          Expanded(
            // Built as it scrolls: there are some 1,500.
            child: CustomScrollView(
              // Not the page's scroll view (the messages are).
              primary: false,
              slivers: [
                for (final (title, emoji) in sections) ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    sliver: SliverToBoxAdapter(
                      child: Text(title,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 40, mainAxisExtent: 36),
                      itemCount: emoji.length,
                      itemBuilder: (context, i) {
                        final (e, name) = emoji[i];
                        return Tooltip(
                          message: name,
                          waitDuration: const Duration(milliseconds: 500),
                          child: InkWell(
                            key: ValueKey('team_chat_emoji_$e'),
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => widget.onPick(e),
                            onHover: (on) {
                              if (on) {
                                _hovered.value = (e, name);
                              } else if (_hovered.value?.$1 == e) {
                                _hovered.value = null;
                              }
                            },
                            child: Center(
                              child: ValueListenableBuilder<(String, String)?>(
                                valueListenable: _hovered,
                                builder: (context, h, _) =>
                                    h?.$1 == e && teamAnimateEmoji
                                        ? TeamAnimatedEmoji(e,
                                            size: 26,
                                            style:
                                                const TextStyle(fontSize: 20))
                                        : Text(e,
                                            style:
                                                const TextStyle(fontSize: 20)),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          // The one under the mouse, large and moving, with its name.
          Container(
            key: const ValueKey('team_chat_emoji_preview'),
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant)),
            ),
            child: ValueListenableBuilder<(String, String)?>(
              valueListenable: _hovered,
              builder: (context, h, _) => h == null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Point at an emoji to see it move',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : Row(children: [
                      SizedBox(
                        width: 40,
                        child: Center(
                          child: teamAnimateEmoji
                              ? TeamAnimatedEmoji(h.$1,
                                  key: ValueKey('preview_${h.$1}'),
                                  size: 36,
                                  style: const TextStyle(fontSize: 28))
                              : Text(h.$1,
                                  style: const TextStyle(fontSize: 28)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(h.$2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium),
                      ),
                    ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// [TEAM CHAT - GIFS]: search the web for a GIF; a click posts it.
class _GifPicker extends StatefulWidget {
  final String teamFolder;
  final String user;
  final ValueChanged<GifResult> onPick;
  final VoidCallback onClose;
  const _GifPicker({
    required this.teamFolder,
    required this.user,
    required this.onPick,
    required this.onClose,
  });

  @override
  State<_GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<_GifPicker> {
  final _query = TextEditingController();
  GifSearchSettings? _settings;
  List<GifResult> _results = const [];
  String _problem = '';
  bool _loading = false;
  Timer? _debounce;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    GifSearchSettings.load(widget.teamFolder).then((s) {
      if (!mounted) return;
      setState(() => _settings = s);
      if (s.ready) _run('');
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(q));
    setState(() {});
  }

  Future<void> _run(String q) async {
    final s = _settings;
    if (s == null || !s.ready || GifSearch.fromLink(q) != null) return;
    final ask = ++_asked;
    setState(() {
      _loading = true;
      _problem = '';
    });
    try {
      final found = await GifSearch.search(s, q, user: widget.user);
      if (!mounted || ask != _asked) return;
      setState(() {
        _results = found;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || ask != _asked) return;
      setState(() {
        _loading = false;
        _problem = e is StateError
            ? e.message
            : 'GIF search could not be reached ($e).';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _settings;
    final link = GifSearch.fromLink(_query.text);
    final List<GifResult> shown = link != null ? [link] : _results;
    Widget body;
    if (s == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!s.ready && link == null) {
      // [TEAM CHAT - GIFS]: no search key (team_config.json "gifs"): the
      // picker is just a place to paste a GIF's link.
      body = Center(
        key: const ValueKey('team_chat_gif_paste_only'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gif_box_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 8),
            Text('Paste a GIF link above to post it',
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text('A web address ending in .gif or .webp',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    } else if (_problem.isNotEmpty && link == null) {
      body = Center(
          child: Text(_problem, style: TextStyle(color: scheme.error)));
    } else if (shown.isEmpty) {
      body = Center(
          child: _loading
              ? const CircularProgressIndicator()
              : Text('No GIFs found.', style: theme.textTheme.bodySmall));
    } else {
      body = GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 150,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 1.25,
        ),
        itemCount: shown.length,
        itemBuilder: (_, i) {
          final g = shown[i];
          return Tooltip(
            message: g.title.isEmpty ? 'Post this GIF' : g.title,
            child: InkWell(
              key: ValueKey('team_chat_gif_$i'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onPick(g),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  g.previewUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                      color: scheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined)),
                  loadingBuilder: (context, child, progress) => progress ==
                          null
                      ? child
                      : Container(color: scheme.surfaceContainerHighest),
                ),
              ),
            ),
          );
        },
      );
    }
    return Material(
      key: const ValueKey('team_chat_gif_picker'),
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 0),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('team_chat_gif_search'),
                  controller: _query,
                  autofocus: true,
                  onChanged: _changed,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surface,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: s != null && s.ready
                        ? 'Search ${s.providerLabel} for a GIF, or paste a link'
                        : 'Paste a GIF link (https://...gif)',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onClose,
              ),
            ]),
          ),
          Expanded(child: body),
          if (s != null && s.ready)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text('Powered by ${s.providerLabel}',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

/// The team chat's floating button (bottom right, where the CTS Assistant's
/// used to be): the unread count, or a red @ with how many messages name
/// you. Hidden until the team folder is joined.
class TeamChatFab extends StatelessWidget {
  final VoidCallback onPressed;
  const TeamChatFab({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final chat = Team.chat;
    final presence = Team.presence;
    if (chat == null || presence == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable:
          Listenable.merge([chat, presence, TeamChatPanel.instance.showing]),
      builder: (context, _) {
        if (!presence.active) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final mentions = chat.mentionCount;
        final unread = chat.unreadCount;
        final open = TeamChatPanel.instance.isOpen;
        return FloatingActionButton(
          key: const ValueKey('fab_team_chat'),
          heroTag: 'fab_team_chat',
          tooltip: open
              ? 'Close team chat'
              : mentions > 0
                  ? 'Team chat: you were mentioned $mentions '
                      'time${mentions == 1 ? '' : 's'}'
                  : unread > 0
                      ? 'Team chat: $unread unread'
                      : 'Team chat',
          backgroundColor: mentions > 0 ? scheme.error : Colors.green[700],
          foregroundColor: Colors.white,
          onPressed: onPressed,
          child: TeamUnreadIcon(
            key: ValueKey(mentions > 0
                ? 'fab_team_chat_mention'
                : 'fab_team_chat_unread'),
            unread: unread,
            mentions: mentions,
            open: open,
            color: Colors.white,
          ),
        );
      },
    );
  }
}

/// [PERFORMANCE - RESIZE]: the size a chat edge drag will land on, drawn
/// over the chat while the edge is held.
class _ResizeOutline extends StatelessWidget {
  const _ResizeOutline();

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.blueAccent.withValues(alpha: 0.10),
          border: Border.all(color: Colors.blueAccent, width: 2),
        ),
      );
}

/// [TEAM CHAT]: the chat on its own - the pop-out window's body. It runs a
/// chat of its own over [teamFolder] (the folder is all a chat needs), so it
/// needs nothing from the dashboard that opened it.
class TeamChatStandalone extends StatefulWidget {
  final String teamFolder;
  final String myName;
  const TeamChatStandalone(
      {super.key, required this.teamFolder, this.myName = ''});

  @override
  State<TeamChatStandalone> createState() => _TeamChatStandaloneState();
}

class _TeamChatStandaloneState extends State<TeamChatStandalone> {
  late final TeamChat _chat = TeamChat()..myName = () => widget.myName;
  final ValueNotifier<String> _draft = ValueNotifier('');

  /// Who is on and where, read only: the dashboard that opened this window
  /// already keeps this person's own note.
  late final TeamPresenceBoard _presence =
      TeamPresenceBoard(version: '', readOnly: true);

  @override
  void initState() {
    super.initState();
    Team.chat ??= _chat;
    Team.presence ??= _presence;
    _presence.attach(widget.teamFolder);
    _chat.attach(widget.teamFolder);
    if (widget.teamFolder.isNotEmpty) {
      TeamAvatars.instance.setFolder(
          '${widget.teamFolder}${Platform.pathSeparator}avatars');
    }
    _chat.setOpen(true);
  }

  @override
  void dispose() {
    if (identical(Team.chat, _chat)) Team.chat = null;
    if (identical(Team.presence, _presence)) Team.presence = null;
    _presence.dispose();
    _chat.dispose();
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.teamFolder.isEmpty
      ? const Center(child: Text('No team folder - set one in the app settings.'))
      : _ChatBody(chat: _chat, draft: _draft);
}

/// [TEAM KIT - APPS]: one look per app - a colour that reads on light and
/// dark backgrounds alike (a deep shade on light, a pale one on dark), an
/// icon, and a short name - used everywhere presence and messages say which
/// app.
class TeamAppStyle {
  TeamAppStyle._();

  /// The apps in the order they are listed (columns of the team chart).
  static const List<String> order = ['dashboard', 'configurator', 'instructor'];

  static String key(String app) => app.isEmpty ? 'dashboard' : app;

  static Color color(String app, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (key(app)) {
      'configurator' =>
        dark ? const Color(0xFFD1A3F0) : const Color(0xFF6A1B9A),
      'instructor' =>
        dark ? const Color(0xFF7FDBCB) : const Color(0xFF00695C),
      'dashboard' =>
        dark ? const Color(0xFF8EC5FF) : const Color(0xFF1155B8),
      _ => dark ? const Color(0xFFFFCC80) : const Color(0xFF9A4A00),
    };
  }

  static IconData icon(String app) => switch (key(app)) {
        'configurator' => Icons.construction,
        'instructor' => Icons.school_outlined,
        'dashboard' => Icons.dashboard_outlined,
        _ => Icons.apps,
      };

  /// 'Dashboard', 'Builder', 'Instructor' - for tight places.
  static String short(String app) => switch (key(app)) {
        'configurator' => 'Builder',
        'instructor' => 'Instructor',
        'dashboard' => 'Dashboard',
        _ => app,
      };
}

/// [TEAM KIT]: a small label saying which app something came from - a
/// message, or where someone is now. '' is the dashboard (before the kit,
/// only the dashboard wrote to the team folder).
class TeamAppTag extends StatelessWidget {
  final String app;

  /// The short name ('Builder') rather than the full one.
  final bool short;
  const TeamAppTag(this.app, {super.key, this.short = false});

  @override
  Widget build(BuildContext context) {
    final colour = TeamAppStyle.color(app, Theme.of(context).brightness);
    return Tooltip(
      message: 'In ${teamAppName(app)}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colour.withValues(alpha: 0.55)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(TeamAppStyle.icon(app), size: 11, color: colour),
          const SizedBox(width: 3),
          Text(short ? TeamAppStyle.short(app) : teamAppName(app),
              style: TextStyle(
                  fontSize: 10.5, color: colour, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// Everyone's notes as people: one entry per login, holding each app they
/// have open (in [TeamAppStyle.order]).
List<List<TeamPresence>> teamPeople(Iterable<TeamPresence> notes) {
  final by = <String, List<TeamPresence>>{};
  for (final p in notes) {
    by.putIfAbsent(p.user.toLowerCase(), () => []).add(p);
  }
  int rank(TeamPresence p) {
    final i = TeamAppStyle.order.indexOf(TeamAppStyle.key(p.app));
    return i < 0 ? 99 : i;
  }

  return [
    for (final sessions in by.values)
      sessions..sort((a, b) => rank(a) - rank(b)),
  ]..sort((a, b) =>
      a.first.label.toLowerCase().compareTo(b.first.label.toLowerCase()));
}

/// The version a note's app is, for show: 'v1.30.1' ('' when unknown).
String teamVersionText(TeamPresence p) {
  final v = p.version.split('+').first.trim();
  return v.isEmpty ? '' : 'v$v';
}

/// Where someone is in one app, in words: 'ARTS 209 · Room Hub', 'Settings',
/// 'Open'.
String teamPlaceText(TeamPresence p) {
  final parts = [
    if (p.room.isNotEmpty) p.room,
    if (p.tab.isNotEmpty) p.tab,
  ];
  return parts.isEmpty ? 'Open' : parts.join(' · ');
}

/// [TEAM KIT - WHO IS WHERE]: the team as a chart - a row per person, a
/// column per app, and in each cell (in that app's colour) the page and room
/// they have up there. Someone with all three apps open is one row with
/// three filled cells.
class TeamPresenceChart extends StatelessWidget {
  const TeamPresenceChart({
    super.key,
    required this.people,
    required this.meUser,
    this.onMessage,
    this.onOpenRoom,
  });

  /// From [teamPeople]; this person's row first when it is in here.
  final List<List<TeamPresence>> people;
  final String meUser;
  final void Function(String user)? onMessage;
  final void Function(String room)? onOpenRoom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final apps = <String>{
      ...TeamAppStyle.order,
      for (final s in people)
        for (final p in s) TeamAppStyle.key(p.app),
    }.toList();

    Widget header(String app) {
      final c = TeamAppStyle.color(app, theme.brightness);
      return Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
        child: Row(children: [
          Icon(TeamAppStyle.icon(app), size: 16, color: c),
          const SizedBox(width: 6),
          Flexible(
            // Wraps rather than cutting the name short.
            child: Text(teamAppName(app),
                maxLines: 2,
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: c, fontWeight: FontWeight.w700)),
          ),
        ]),
      );
    }

    Widget cell(String app, TeamPresence? p) {
      final c = TeamAppStyle.color(app, theme.brightness);
      if (p == null) {
        return Padding(
          padding: const EdgeInsets.all(6),
          child: Text('-',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.outlineVariant)),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(3),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border(left: BorderSide(color: c, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(
                  child: Text(p.tab.isEmpty ? 'Open' : p.tab,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
                if (p.room.isNotEmpty && onOpenRoom != null)
                  InkWell(
                    onTap: () => onOpenRoom!(p.room),
                    child: Tooltip(
                      message: 'Open ${p.room} in the Room Hub',
                      child:
                          Icon(Icons.meeting_room_outlined, size: 14, color: c),
                    ),
                  ),
              ]),
              if (p.room.isNotEmpty)
                Text(p.room,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: c, fontWeight: FontWeight.w600)),
              for (final e in p.editing)
                Text('Editing ${e.label}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.tertiary)),
              Text(
                  [
                    if (teamVersionText(p).isNotEmpty) teamVersionText(p),
                    p.machine,
                    'since ${_clock(p.since)}',
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    TableRow personRow(List<TeamPresence> sessions) {
      final first = sessions.first;
      final me = first.user.toLowerCase() == meUser.toLowerCase();
      TeamPresence? inApp(String a) {
        for (final p in sessions) {
          if (TeamAppStyle.key(p.app) == a) return p;
        }
        return null;
      }

      return TableRow(
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.5)))),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(children: [
              TeamAvatar(first.user, size: 30),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(me ? '${first.label} (you)' : first.label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                        '${sessions.length} '
                        '${sessions.length == 1 ? 'app' : 'apps'} open',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ]),
          ),
          for (final a in apps) cell(a, inApp(a)),
          me || onMessage == null
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Message ${first.label} directly',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  onPressed: () => onMessage!(first.user),
                ),
        ],
      );
    }

    return Table(
      columnWidths: {
        0: const FlexColumnWidth(1.25),
        for (var i = 0; i < apps.length; i++) i + 1: const FlexColumnWidth(1),
        apps.length + 1: const FixedColumnWidth(40),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(
              border:
                  Border(bottom: BorderSide(color: scheme.outlineVariant))),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
              child: Text('Person', style: theme.textTheme.labelLarge),
            ),
            for (final a in apps) header(a),
            const SizedBox.shrink(),
          ],
        ),
        for (final sessions in people) personRow(sessions),
      ],
    );
  }
}
