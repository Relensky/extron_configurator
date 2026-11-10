import 'package:flutter/material.dart';

import 'team_app_launch.dart';
import 'team_chat.dart';
import 'team_claims.dart';
import 'team_host.dart';
import 'team_widgets.dart';

// ============================================================================
// [TEAM KIT - WORKING ON]: the strip that says who is on a ticket or a room,
// and the button that changes it. See team_claims.dart.
//
// Tagging someone else sends them a direct message from you; joining
// something others are already on tells them too - so nobody finds out by
// accident that two people have been doing the same job.
// ============================================================================

/// Avatars of whoever is on [kind] [id], and a button to change it.
class TeamWorkingOn extends StatelessWidget {
  const TeamWorkingOn({
    super.key,
    required this.kind,
    required this.id,
    required this.label,
    this.noun = 'this',
    this.size = 22,
    this.showButton = true,
    this.file = '',
    this.project = '',
  });

  /// 'ticket', 'room'...
  final String kind;
  final String id;

  /// [TEAM KIT - PROJECTS]: the project file (and its name) the tag is made
  /// on - the Room Config Builder's open job - so the tag links to it.
  final String file;
  final String project;

  /// What the tag names it, in the chat and in tooltips:
  /// 'Ticket #12345 - Projector out'.
  final String label;

  /// 'this ticket', 'this room' - in the menu.
  final String noun;
  final double size;
  final bool showButton;

  @override
  Widget build(BuildContext context) {
    final claims = Team.claims;
    if (claims == null || !claims.active) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: claims,
      builder: (context, _) {
        final on = claims.on(kind, id);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in on)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Tooltip(
                  message: '${c.whoLabel} is working on $noun\n'
                      'since ${teamAgo(c.at)}'
                      '${c.self ? '' : ' - tagged by ${c.byLabel}'}'
                      ' (${teamAppName(c.app)})',
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Theme.of(context).colorScheme.surface,
                          width: 1.5),
                    ),
                    child: TeamAvatar(c.who, size: size),
                  ),
                ),
              ),
            if (showButton) _WorkingOnMenu(this, on),
          ],
        );
      },
    );
  }
}

/// Puts [who] on (or takes them off) [kind] [id], as this person, and tells
/// whoever it touches: someone else put on or taken off gets a direct
/// message from you; joining something others are on tells them too.
/// Every change also stays in the tag history (TeamClaims.historyFor).
/// Returns what went wrong, or ''.
Future<String> teamSetTag({
  required String kind,
  required String id,
  required String label,
  required String who,
  String whoName = '',
  required bool on,
  String file = '',
  String project = '',
}) async {
  final claims = Team.claims;
  if (claims == null) return 'The team folder cannot be reached.';
  final me = claims.me.user;
  final others = [
    for (final c in claims.on(kind, id))
      if (c.who.toLowerCase() != me.toLowerCase()) c,
  ];
  final error = await claims.set(
      kind: kind,
      id: id,
      label: label,
      who: who,
      whoName: whoName,
      on: on,
      file: file,
      project: project);
  if (error.isNotEmpty) return error;
  final chat = Team.chat;
  if (chat == null) return '';
  final what = teamTagWhat(kind, id, label);
  final byName = [claims.myName(), chat.myName(), me]
      .map((s) => s.trim())
      .firstWhere((s) => s.isNotEmpty, orElse: () => me);
  if (who.toLowerCase() != me.toLowerCase()) {
    // Someone else: they hear about it from you, either way - by name, so
    // the notice says who without opening the chat.
    await chat.post(
        on
            ? '$byName tagged you as working on $what.'
            : '$byName took you off $what - you are no longer tagged as '
                'working on it.',
        to: dmChannel(me, who));
  } else if (on) {
    // Joining: the people already on it hear that you are too.
    for (final c in others) {
      await chat.post('$byName is working on $what with you too.',
          to: dmChannel(me, c.who));
    }
  }
  return '';
}

/// What a tag is on, for its chat message: 'room **ARTS 209**', or the
/// label alone when it already says what it is ('**Ticket #12345 - ...**').
/// A room is named by its full room name - this app's label adds
/// "(room configuration)".
String teamTagWhat(String kind, String id, String label) {
  final name = label.trim().isEmpty ? id : label.trim();
  if (kind.toLowerCase() == 'room') return 'room **$id**';
  if (name.toLowerCase().startsWith(kind.toLowerCase())) return '**$name**';
  return '$kind **$name**';
}

/// Takes [c] off, as this person - see [teamSetTag].
Future<String> teamTakeOff(TeamClaim c) => teamSetTag(
    kind: c.kind,
    id: c.id,
    label: c.label,
    who: c.who,
    whoName: c.whoName,
    on: false,
    file: c.file,
    project: c.project);

/// Taking someone else off asks first: anyone may, but they are told and it
/// stays in their history. Your own tags - whoever put them there - and the
/// ones you placed on yourself come off without asking.
bool teamTakeOffNeedsWarning(TeamClaim c) {
  final me = Team.claims?.me.user.toLowerCase() ?? '';
  return c.who.toLowerCase() != me;
}

/// The warning [teamTakeOffNeedsWarning] asks for, in words.
String teamTakeOffWarning(TeamClaim c) {
  final me = Team.claims?.me.user.toLowerCase() ?? '';
  final placed = c.by.toLowerCase() == me
      ? 'you tagged them'
      : c.self
          ? 'they tagged themselves'
          : '${c.byLabel} tagged them';
  return 'Take ${c.whoLabel} off ${c.label.isEmpty ? c.id : c.label}? '
      '($placed ${teamAgo(c.at)}.) They get a message from you, and it is '
      'kept in their tag history.';
}

/// Takes off every tag on this person (whoever placed it) and every tag
/// they placed on others - who are each told. Returns what went wrong, or ''.
Future<String> teamClearMyTags() async {
  final claims = Team.claims;
  if (claims == null) return '';
  final me = claims.me.user.toLowerCase();
  for (final c in [
    for (final c in claims.current)
      if (c.by.toLowerCase() == me || c.who.toLowerCase() == me) c,
  ]) {
    final error = await teamTakeOff(c);
    if (error.isNotEmpty) return error;
  }
  return '';
}

/// A tag's kind as an icon: a ticket, a room, anything else.
IconData teamTagKindIcon(String kind) => switch (kind.toLowerCase()) {
      'ticket' => Icons.confirmation_number_outlined,
      'room' => Icons.meeting_room_outlined,
      'project' => Icons.construction,
      _ => Icons.label_outline,
    };

/// [TEAM KIT - WORKING ON]: whether this app can open what a [kind] tag is on
/// ([TeamHost.openClaim]; a room also through [Team.openRoom]).
bool teamCanOpenClaim(String kind) {
  if (TeamHost.openClaim != null) {
    return TeamHost.canOpenClaim?.call(kind) ?? true;
  }
  return kind.toLowerCase() == 'room' && Team.openRoom != null;
}

/// [TEAM KIT - PROJECTS]: the project file a tag is on - the file it was
/// made on (TeamClaim.file), or a 'project' tag's id - else ''.
String teamClaimFile(TeamClaim c) => c.file.isNotEmpty
    ? c.file
    : c.kind.toLowerCase() == 'project'
        ? c.id
        : '';

/// The project's name for [c]: the one it was tagged with, else the file's.
String teamClaimProjectName(TeamClaim c) {
  if (c.project.trim().isNotEmpty) return c.project.trim();
  final name = teamClaimFile(c).split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Whether a link can open [c] - its project file, or what it is on.
bool teamCanOpenTag(TeamClaim c) => c.kind.toLowerCase() == 'project'
    ? teamClaimFile(c).isNotEmpty
    : teamIsBuilderRoomTag(c) || teamCanOpenClaim(c.kind);

/// [TEAM KIT - WORKING ON]: a room tag made in the Room Config Builder - its
/// link opens the room there, from every app ([teamOpenBuilderRoom]).
bool teamIsBuilderRoomTag(TeamClaim c) =>
    c.kind.toLowerCase() == 'room' && c.app == 'configurator';

/// Opens [c]'s room in the Room Config Builder ('openRoom' {room, file} -
/// here when this is the Builder, else it is started or brought to the
/// front): the project or room configuration file the tag was made on, or
/// - an older tag with no file - the room found by name.
Future<bool> teamOpenBuilderRoom(BuildContext? context, TeamClaim c) =>
    teamOpenInApp(context, 'configurator', action: 'openRoom', args: {
      'room': c.id,
      if (c.file.isNotEmpty) 'file': c.file,
    });

/// Opens room [roomId] in the CTS Dashboard's Room Hub - here when this is
/// the dashboard, else it is started or brought to the front.
void teamOpenInRoomHub(BuildContext? context, String roomId) {
  if (TeamHost.appId == 'dashboard') {
    final open = TeamHost.openClaim;
    if (open != null) {
      open('room', roomId, roomId);
    } else {
      Team.openRoom?.call(roomId);
    }
    return;
  }
  teamOpenInApp(context, 'dashboard',
      action: 'openRoom', args: {'room': roomId});
}

/// Whether a room tag also gets a Room Hub button: wherever its own link
/// opens something else (the Builder, or another app's room).
bool teamShowsRoomHubLink(TeamClaim c) =>
    c.kind.toLowerCase() == 'room' &&
    c.id.isNotEmpty &&
    (TeamHost.appId != 'dashboard' || teamIsBuilderRoomTag(c));

/// [TEAM KIT - PROJECTS]: opens [c]'s project file in the Room Config
/// Builder ('openProject' - here when this is the Builder, else it is
/// started or brought to the front with the file); [withRoom] and a room
/// tag: that room in it too.
Future<bool> teamOpenProject(BuildContext? context, TeamClaim c,
    {bool withRoom = false}) {
  final file = teamClaimFile(c);
  if (file.isEmpty) return Future.value(false);
  return teamOpenInApp(context, 'configurator', action: 'openProject', args: {
    'file': file,
    if (withRoom && c.kind.toLowerCase() == 'room') 'room': c.id,
  });
}

/// [TEAM KIT - WORKING ON]: opens what [c] is on - see [teamCanOpenTag]. A
/// project tag, and in the Room Config Builder a room tag made on a project
/// file, open that file ([teamOpenProject]).
void teamOpenClaim(TeamClaim c, [BuildContext? context]) {
  final kind = c.kind.toLowerCase();
  if (teamIsBuilderRoomTag(c)) {
    teamOpenBuilderRoom(context, c);
    return;
  }
  if (kind == 'project' ||
      (kind == 'room' &&
          c.file.isNotEmpty &&
          TeamHost.appId == 'configurator')) {
    teamOpenProject(context, c, withRoom: true);
    return;
  }
  final open = TeamHost.openClaim;
  if (open != null) {
    open(c.kind, c.id, c.label);
  } else if (c.kind.toLowerCase() == 'room') {
    Team.openRoom?.call(c.id);
  }
}

/// [TEAM KIT - WORKING ON]: what a tag is on, as a link to it when this app
/// can open it ([teamCanOpenClaim]) - underlined under the pointer - else
/// plain text. [beforeOpen] runs first (the team page closes itself).
class TeamClaimLink extends StatefulWidget {
  const TeamClaimLink(this.claim,
      {super.key, this.style, this.beforeOpen});

  final TeamClaim claim;
  final TextStyle? style;
  final VoidCallback? beforeOpen;

  @override
  State<TeamClaimLink> createState() => _TeamClaimLinkState();
}

class _TeamClaimLinkState extends State<TeamClaimLink> {
  bool _hover = false;
  bool _hoverProject = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.claim;
    final scheme = Theme.of(context).colorScheme;
    final base = widget.style ?? Theme.of(context).textTheme.bodySmall;
    final kind = c.kind.toLowerCase();
    final what = c.label.isNotEmpty
        ? c.label
        : kind == 'project'
            ? teamClaimProjectName(c)
            : c.id;
    final Widget main;
    if (!teamCanOpenTag(c)) {
      main = Text(what,
          overflow: TextOverflow.ellipsis,
          style: base?.copyWith(color: scheme.onSurface));
    } else {
      main = _link(
        key: ValueKey('working_on_link_${c.key}'),
        text: what,
        tooltip: switch (kind) {
          'project' => TeamHost.appId == 'configurator'
              ? 'Open the project ${teamClaimProjectName(c)}'
              : 'Open the project ${teamClaimProjectName(c)} in the Room '
                  'Config Builder',
          'room' when teamIsBuilderRoomTag(c) =>
            (TeamHost.appId == 'configurator'
                    ? 'Open ${c.id}'
                    : 'Open ${c.id} in the Room Config Builder') +
                (c.file.isEmpty ? '' : '\n${c.file}'),
          'room' when c.file.isNotEmpty && TeamHost.appId == 'configurator' =>
            'Open ${c.id} in ${teamClaimProjectName(c)}',
          'room' => 'Open ${c.id} in the Room Hub',
          'ticket' => 'Open ticket #${c.id}',
          _ => 'Open $what',
        },
        style: base,
        hover: _hover,
        onHover: (v) => setState(() => _hover = v),
        onTap: (context) => teamOpenClaim(c, context),
      );
    }
    // [TEAM KIT - PROJECTS]: a tag made on a project (a room in the Room
    // Config Builder) also links to that project; a room configuration file
    // has no project name and is the main link's already.
    final projectLink = kind != 'project' &&
        c.file.isNotEmpty &&
        c.project.trim().isNotEmpty;
    // [TEAM KIT - WORKING ON]: a room whose link opens elsewhere (the
    // Builder, or a room tag in another app) also opens in the Room Hub.
    final hubLink = teamShowsRoomHubLink(c);
    if (!projectLink && !hubLink) return main;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: main),
      if (projectLink) ...[
        Text('  ·  ', style: base?.copyWith(color: scheme.outline)),
        Icon(Icons.construction, size: 13, color: scheme.primary),
        const SizedBox(width: 3),
        Flexible(
          child: _link(
            key: ValueKey('working_on_project_link_${c.key}'),
            text: teamClaimProjectName(c),
            tooltip: TeamHost.appId == 'configurator'
                ? 'Open the project ${teamClaimProjectName(c)}\n${c.file}'
                : 'Open the project ${teamClaimProjectName(c)} in the Room '
                    'Config Builder\n${c.file}',
            style: base?.copyWith(fontWeight: FontWeight.normal),
            hover: _hoverProject,
            onHover: (v) => setState(() => _hoverProject = v),
            onTap: (context) => teamOpenProject(context, c),
          ),
        ),
      ],
      if (hubLink) ...[
        const SizedBox(width: 6),
        Tooltip(
          message: TeamHost.appId == 'dashboard'
              ? 'Open ${c.id} in the Room Hub'
              : 'Open ${c.id} in the CTS Dashboard Room Hub',
          child: InkWell(
            key: ValueKey('working_on_room_hub_link_${c.key}'),
            borderRadius: BorderRadius.circular(4),
            onTap: () {
              final root =
                  Navigator.maybeOf(context, rootNavigator: true)?.context;
              widget.beforeOpen?.call();
              teamOpenInRoomHub(root ?? context, c.id);
            },
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.dashboard_outlined,
                  size: 15, color: scheme.primary),
            ),
          ),
        ),
      ],
    ]);
  }

  /// One underlined-under-the-pointer link. [onTap] gets a context that
  /// outlives the team page ([beforeOpen] closes it): the root navigator's.
  Widget _link({
    required Key key,
    required String text,
    required String tooltip,
    required TextStyle? style,
    required bool hover,
    required ValueChanged<bool> onHover,
    required void Function(BuildContext context) onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final root =
                Navigator.maybeOf(context, rootNavigator: true)?.context;
            widget.beforeOpen?.call();
            onTap(root ?? context);
          },
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(
                  color: scheme.primary,
                  decoration: hover ? TextDecoration.underline : null,
                  decorationColor: scheme.primary)),
        ),
      ),
    );
  }
}

/// [TEAM KIT - WORKING ON]: for the team page - what each person is tagged
/// on, in every app, and the app each tag was made in. Each tag is a link to
/// what it is on ([TeamClaimLink]). Every tag has an x: your own (whoever
/// put them there) and the ones you placed come off straight away; anyone
/// else's asks first, in place. The heading clears all of yours at once, and
/// History - folded at the bottom until clicked - lists every change to your
/// tags by day, including who took you off what.
class TeamWorkingOnList extends StatefulWidget {
  const TeamWorkingOnList({super.key, this.beforeOpen});

  /// Runs before a tag's link opens what it is on (the team page closes).
  final VoidCallback? beforeOpen;

  @override
  State<TeamWorkingOnList> createState() => _TeamWorkingOnListState();
}

class _TeamWorkingOnListState extends State<TeamWorkingOnList> {
  /// The "clear all" button asks again in place - a dialog would open
  /// behind the chat when this page is inside it.
  bool _confirming = false;
  bool _busy = false;
  String _error = '';

  /// The tag (TeamClaim.key) whose take-off is waiting on a yes.
  String? _confirmKey;

  /// History open at the bottom. Folded away to start with.
  bool _history = false;

  Future<void> _run(Future<String> Function() job) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    final error = await job();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _confirming = false;
      _confirmKey = null;
      _error = error;
    });
  }

  /// A history day's heading: Today, Yesterday, else 'Mon 3 Nov' (with the
  /// year when it is not this one).
  static String _dayHeading(DateTime day, DateTime today) {
    final d = today.difference(day).inDays;
    if (d == 0) return 'Today';
    if (d == 1) return 'Yesterday';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final text =
        '${days[day.weekday - 1]} ${day.day} ${months[day.month - 1]}';
    return day.year == today.year ? text : '$text ${day.year}';
  }

  /// [TEAM KIT - WORKING ON]: one change to this person's tags - who did it,
  /// what to (a link), the app and the time.
  Widget _historyRow(TeamClaim c, String me, int index, ThemeData theme) {
    final scheme = theme.colorScheme;
    final byMe = c.by.toLowerCase() == me;
    final forMe = c.who.toLowerCase() == me;
    final actor = byMe ? 'You' : c.byLabel;
    final target = forMe ? (byMe ? 'yourself' : 'you') : c.whoLabel;
    final verb = c.on ? 'put $target on' : 'took $target off';
    final removedByOther = !c.on && !byMe;
    final muted =
        theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      key: ValueKey('working_on_history_${c.key}_${c.at.microsecondsSinceEpoch}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      color: index.isOdd
          ? scheme.onSurface.withValues(alpha: 0.035)
          : Colors.transparent,
      child: Row(children: [
        Icon(teamTagKindIcon(c.kind),
            size: 16,
            color: removedByOther ? scheme.error : scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Tooltip(message: actor, child: TeamAvatar(c.by, size: 20)),
        const SizedBox(width: 8),
        Expanded(
          child: Row(children: [
            Flexible(
              flex: 2,
              child: Text('$actor $verb ',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: removedByOther ? scheme.error : null)),
            ),
            Flexible(
              flex: 3,
              child: TeamClaimLink(c,
                  beforeOpen: widget.beforeOpen,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        TeamAppTag(c.app, short: true),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: Tooltip(
            message: c.at.toLocal().toString().substring(0, 16),
            child: Text(teamAgo(c.at),
                textAlign: TextAlign.right, style: muted),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final claims = Team.claims;
    if (claims == null || !claims.active) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: claims,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final me = claims.me.user.toLowerCase();
        final all = claims.current;
        final placed = all
            .where((c) =>
                c.by.toLowerCase() == me || c.who.toLowerCase() == me)
            .length;
        final history = claims.historyFor();
        // A group a person, this person first, then by name.
        final by = <String, List<TeamClaim>>{};
        for (final c in all) {
          by.putIfAbsent(c.who.toLowerCase(), () => []).add(c);
        }
        final people = by.values.toList()
          ..sort((a, b) {
            final am = a.first.who.toLowerCase() == me ? 0 : 1;
            final bm = b.first.who.toLowerCase() == me ? 0 : 1;
            if (am != bm) return am - bm;
            return a.first.whoLabel
                .toLowerCase()
                .compareTo(b.first.whoLabel.toLowerCase());
          });

        Widget tag(TeamClaim c) {
          final mine = c.by.toLowerCase() == me;
          return Padding(
            key: ValueKey('working_on_tag_${c.key}'),
            padding: const EdgeInsets.only(left: 38, top: 2, bottom: 2),
            child: Row(children: [
              Icon(teamTagKindIcon(c.kind),
                  size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: TeamClaimLink(c,
                    beforeOpen: widget.beforeOpen,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              TeamAppTag(c.app, short: true),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                    'since ${teamAgo(c.at)}'
                    '${c.self ? '' : ' - tagged by ${mine ? 'you' : c.byLabel}'}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              IconButton(
                key: ValueKey('working_on_clear_${c.key}'),
                tooltip: c.who.toLowerCase() == me
                    ? 'Take this tag off'
                    : 'Take ${c.whoLabel} off this'
                        '${mine ? '' : ' (asks first - they are told)'}',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: const Icon(Icons.close),
                onPressed: _busy
                    ? null
                    : teamTakeOffNeedsWarning(c)
                        ? () => setState(() => _confirmKey = c.key)
                        : () => _run(() => teamTakeOff(c)),
              ),
            ]),
          );
        }

        // Asked in place, under the tag - a dialog would open behind the
        // chat when this page is inside it.
        Widget confirm(TeamClaim c) => Padding(
              key: ValueKey('working_on_confirm_${c.key}'),
              padding: const EdgeInsets.fromLTRB(38, 2, 4, 6),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(teamTakeOffWarning(c),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onErrorContainer)),
                  ),
                  TextButton(
                    key: ValueKey('working_on_confirm_yes_${c.key}'),
                    onPressed: _busy ? null : () => _run(() => teamTakeOff(c)),
                    child: const Text('Take off'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _confirmKey = null),
                    child: const Text('Keep'),
                  ),
                ]),
              ),
            );

        // History by day, newest first, a heading a day.
        final shown = history.take(50).toList();
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final historyRows = <Widget>[];
        DateTime? lastDay;
        var row = 0;
        for (final c in shown) {
          final local = c.at.toLocal();
          final day = DateTime(local.year, local.month, local.day);
          if (day != lastDay) {
            lastDay = day;
            row = 0;
            historyRows.add(Padding(
              padding: EdgeInsets.fromLTRB(8, historyRows.isEmpty ? 4 : 10, 8, 4),
              child: Text(_dayHeading(day, today),
                  style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700)),
            ));
          }
          historyRows.add(_historyRow(c, me, row++, theme));
        }

        return Column(
          key: const ValueKey('team_working_on_list'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
              child: Row(children: [
                const Icon(Icons.assignment_ind_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('Working on',
                        style: theme.textTheme.titleMedium)),
                if (placed > 0 && !_confirming)
                  TextButton.icon(
                    key: const ValueKey('working_on_clear_mine'),
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: Text('Clear my $placed '
                        'tag${placed == 1 ? '' : 's'}'),
                    onPressed:
                        _busy ? null : () => setState(() => _confirming = true),
                  ),
                if (placed > 0 && _confirming) ...[
                  Text('Take off all $placed?',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(width: 4),
                  TextButton(
                    key: const ValueKey('working_on_clear_mine_yes'),
                    onPressed: _busy ? null : () => _run(teamClearMyTags),
                    child: const Text('Clear them'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _confirming = false),
                    child: const Text('Keep'),
                  ),
                ],
              ]),
            ),
            if (_confirming)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                    'Your own tags and the ones you placed on others come '
                    'off; anyone you placed is sent a message.',
                    style: theme.textTheme.bodySmall),
              ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(_error,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error)),
              ),
            if (people.isEmpty)
              Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                    'Nobody is tagged as working on anything. Use the '
                    'person button on a ticket or room to tag yourself.',
                    style: theme.textTheme.bodySmall),
              ),
            for (final tags in people) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
                child: Row(children: [
                  TeamAvatar(tags.first.who, size: 26),
                  const SizedBox(width: 12),
                  Text(
                      tags.first.who.toLowerCase() == me
                          ? '${tags.first.whoLabel} (you)'
                          : tags.first.whoLabel,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Text('${tags.length} '
                      '${tags.length == 1 ? 'thing' : 'things'}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              for (final c in tags) ...[
                tag(c),
                if (_confirmKey == c.key) confirm(c),
              ],
            ],
            // [TEAM KIT - WORKING ON]: History, folded at the bottom until
            // clicked - your tag changes by day.
            if (history.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: scheme.outlineVariant),
              InkWell(
                key: const ValueKey('working_on_history'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _history = !_history),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Row(children: [
                    const Icon(Icons.history, size: 20),
                    const SizedBox(width: 8),
                    Text('Your tag history',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${history.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer,
                              fontWeight: FontWeight.w700)),
                    ),
                    const Spacer(),
                    Text(_history ? 'Hide' : 'Show',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.primary)),
                    Icon(_history ? Icons.expand_less : Icons.expand_more,
                        size: 20, color: scheme.primary),
                  ]),
                ),
              ),
              if (_history)
                Container(
                  key: const ValueKey('working_on_history_list'),
                  margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...historyRows,
                      if (history.length > shown.length)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                          child: Text(
                              'and ${history.length - shown.length} older',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant)),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _WorkingOnMenu extends StatelessWidget {
  const _WorkingOnMenu(this.owner, this.on);
  final TeamWorkingOn owner;
  final List<TeamClaim> on;

  @override
  Widget build(BuildContext context) {
    final claims = Team.claims!;
    final me = claims.me.user;
    final mineOn = on.any((c) => c.who.toLowerCase() == me.toLowerCase());
    // Everyone the team knows: online now first, then everyone who has used
    // the chat.
    final people = <String, String>{};
    for (final p in Team.presence?.others ?? const []) {
      people.putIfAbsent(p.user.toLowerCase(), () => p.label);
    }
    for (final p in Team.chat?.people ?? const <ChatPerson>[]) {
      people.putIfAbsent(p.login.toLowerCase(), () => p.label);
    }
    people.remove(me.toLowerCase());
    final logins = {
      for (final p in Team.presence?.others ?? const []) p.user.toLowerCase(): p.user,
      for (final p in Team.chat?.people ?? const <ChatPerson>[])
        p.login.toLowerCase(): p.login,
    };
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      menuChildren: [
        CheckboxMenuButton(
          key: ValueKey('working_on_me_${owner.kind}_${owner.id}'),
          value: mineOn,
          onChanged: (v) =>
              _set(context, me, claims.myName(), v == true, self: true),
          child: Text('I am working on ${owner.noun}'),
        ),
        if (people.isNotEmpty) const Divider(height: 8),
        if (people.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Text('Tag someone - they get a message',
                style: Theme.of(context).textTheme.labelSmall),
          ),
        for (final e in people.entries)
          CheckboxMenuButton(
            value: on.any((c) => c.who.toLowerCase() == e.key),
            onChanged: (v) =>
                _set(context, logins[e.key] ?? e.key, e.value, v == true),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              TeamAvatar(logins[e.key] ?? e.key, size: 18),
              const SizedBox(width: 8),
              Text(e.value),
            ]),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        key: ValueKey('working_on_${owner.kind}_${owner.id}'),
        tooltip: on.isEmpty
            ? 'Working on it? Tag yourself or someone else'
            : 'Who is working on ${owner.noun}',
        visualDensity: VisualDensity.compact,
        iconSize: owner.size * 0.9,
        color: mineOn ? scheme.primary : null,
        icon: Icon(on.isEmpty ? Icons.person_add_alt_1_outlined : Icons.group_add_outlined),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Future<void> _set(BuildContext context, String who, String whoName, bool v,
      {bool self = false}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!v) {
      // Taking someone else off: anyone may, after a warning.
      final had = on.where((c) => c.who.toLowerCase() == who.toLowerCase());
      if (had.isNotEmpty && teamTakeOffNeedsWarning(had.first)) {
        final yes = await showDialog<bool>(
          context: context,
          useRootNavigator: true,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded),
            title: Text('Take ${had.first.whoLabel} off?'),
            content: Text(teamTakeOffWarning(had.first)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Keep'),
              ),
              FilledButton(
                key: const ValueKey('working_on_take_off_yes'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Take off'),
              ),
            ],
          ),
        );
        if (yes != true) return;
      }
    }
    final error = await teamSetTag(
      kind: owner.kind,
      id: owner.id,
      label: owner.label,
      who: who,
      whoName: whoName,
      on: v,
      file: owner.file,
      project: owner.project,
    );
    if (error.isNotEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}
