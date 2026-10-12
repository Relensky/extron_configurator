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

/// Takes off every tag this person placed - on themselves and on others.
/// Returns what went wrong, or ''.
Future<String> teamClearMyTags() async {
  final claims = Team.claims;
  if (claims == null) return '';
  final me = claims.me.user.toLowerCase();
  for (final c in [
    for (final c in claims.current)
      if (c.by.toLowerCase() == me) c,
  ]) {
    final error = await claims.set(
        kind: c.kind,
        id: c.id,
        label: c.label,
        who: c.who,
        whoName: c.whoName,
        on: false);
    if (error.isNotEmpty) return error;
  }
  return '';
}

/// [TEAM KIT - WORKING ON]: for the team page - what each person is tagged
/// on, in every app, and the app each tag was made in. Tags this person
/// placed get an x, and the heading can clear them all at once.
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
      _error = error;
    });
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
        final placed = all.where((c) => c.by.toLowerCase() == me).length;
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
              if (mine)
                IconButton(
                  key: ValueKey('working_on_clear_${c.key}'),
                  tooltip: c.self
                      ? 'Take this tag off'
                      : 'Take ${c.whoLabel} off this',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: const Icon(Icons.close),
                  onPressed: _busy
                      ? null
                      : () => _run(() => claims.set(
                          kind: c.kind,
                          id: c.id,
                          label: c.label,
                          who: c.who,
                          whoName: c.whoName,
                          on: false)),
                ),
            ]),
          );
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
                    label: Text('Clear the $placed '
                        'tag${placed == 1 ? '' : 's'} I placed'),
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
              for (final c in tags) tag(c),
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
    final claims = Team.claims!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final others = [
      for (final c in on)
        if (c.who.toLowerCase() != claims.me.user.toLowerCase()) c,
    ];
    final error = await claims.set(
      kind: owner.kind,
      id: owner.id,
      label: owner.label,
      who: who,
      whoName: whoName,
      on: v,
    );
    if (error.isNotEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final chat = Team.chat;
    if (!v || chat == null) return;
    if (!self) {
      // Tagged by someone else: they hear about it from you.
      await chat.post(
          'I tagged you as working on **${owner.label}**.',
          to: dmChannel(claims.me.user, who));
    } else {
      // Joining: the people already on it hear that you are too.
      for (final c in others) {
        await chat.post('I am working on **${owner.label}** with you too.',
            to: dmChannel(claims.me.user, c.who));
      }
    }
  }
}
