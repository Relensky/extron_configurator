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
