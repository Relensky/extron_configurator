import 'package:flutter/material.dart';

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
  });

  /// 'ticket', 'room'...
  final String kind;
  final String id;

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
}) async {
  final claims = Team.claims;
  if (claims == null) return 'The team folder cannot be reached.';
  final me = claims.me.user;
  final others = [
    for (final c in claims.on(kind, id))
      if (c.who.toLowerCase() != me.toLowerCase()) c,
  ];
  final error = await claims.set(
      kind: kind, id: id, label: label, who: who, whoName: whoName, on: on);
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
    on: false);

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

/// [TEAM KIT - WORKING ON]: for the team page - what each person is tagged
/// on, in every app, and the app each tag was made in. Every tag has an x:
/// your own (whoever put them there) and the ones you placed come off
/// straight away; anyone else's asks first, in place. The heading clears
/// all of yours at once, and History lists every change to your tags -
/// including who took you off what.
class TeamWorkingOnList extends StatefulWidget {
  const TeamWorkingOnList({super.key, this.onOpenRoom});

  /// Opens a room tag's room (null: room tags are plain text).
  final void Function(String room)? onOpenRoom;

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

  /// History open under the heading.
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

  /// One line of [TeamClaims.historyFor], said from this person's side.
  static String _historyLine(TeamClaim c, String me) {
    final byMe = c.by.toLowerCase() == me;
    final what = c.label.isEmpty ? c.id : c.label;
    if (c.on) {
      return byMe ? 'You tagged yourself on $what' : '${c.byLabel} tagged you on $what';
    }
    return byMe ? 'You took yourself off $what' : '${c.byLabel} took you off $what';
  }

  static IconData _kindIcon(String kind) => switch (kind.toLowerCase()) {
        'ticket' => Icons.confirmation_number_outlined,
        'room' => Icons.meeting_room_outlined,
        _ => Icons.label_outline,
      };

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
          final room = c.kind.toLowerCase() == 'room' &&
              widget.onOpenRoom != null;
          final name = Text(c.label.isEmpty ? c.id : c.label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: room ? scheme.primary : scheme.onSurface,
                  fontWeight: FontWeight.w600));
          return Padding(
            key: ValueKey('working_on_tag_${c.key}'),
            padding: const EdgeInsets.only(left: 38, top: 2, bottom: 2),
            child: Row(children: [
              Icon(_kindIcon(c.kind), size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: room
                    ? InkWell(
                        onTap: () => widget.onOpenRoom!(c.id),
                        child: Tooltip(
                            message: 'Open ${c.id} in the Room Hub',
                            child: name),
                      )
                    : name,
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
                if (history.isNotEmpty && !_confirming)
                  TextButton.icon(
                    key: const ValueKey('working_on_history'),
                    icon: Icon(_history ? Icons.expand_less : Icons.history,
                        size: 18),
                    label: const Text('History'),
                    onPressed: () => setState(() => _history = !_history),
                  ),
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
            if (_history)
              Container(
                key: const ValueKey('working_on_history_list'),
                margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Your tag history',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 4),
                    for (final c in history.take(30))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Icon(
                              c.on
                                  ? Icons.person_add_alt_1_outlined
                                  : Icons.person_remove_outlined,
                              size: 15,
                              color: c.on || c.by.toLowerCase() == me
                                  ? scheme.onSurfaceVariant
                                  : scheme.error),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(_historyLine(c, me),
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall),
                          ),
                          const SizedBox(width: 6),
                          TeamAppTag(c.app, short: true),
                          const SizedBox(width: 6),
                          Text(teamAgo(c.at),
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                  ],
                ),
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
    );
    if (error.isNotEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}
