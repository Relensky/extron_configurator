import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'team/team_claims.dart';
import 'team/team_host.dart';
import 'team/team_presence.dart';
import 'team/team_widgets.dart' show TeamAvatar, teamAgo;

/// ============================================================================
///  ROOM STATUS: WORKING ON, READY FOR REVIEW, REVIEW COMPLETE
/// ============================================================================
///  "Working on" is the team kit's tag (team_claims.dart): while someone else
///  is on a room, it cannot be saved over here until they are taken off it.
///
///  Review marks are kept the same way, in their own folder so the other team
///  apps do not read them as "working on":
///
///    * READY TO APPROVE - the room is done and wants checking before
///      anything is bought for it.
///    * APPROVED - READY TO ORDER - it was checked. Marking it clears ready;
///      marking it ready again clears approved, for the next round.
///
///  Who has a room open right now comes from the team presence notes.
/// ============================================================================

const String kRoomReadyKind = 'room-ready';
const String kRoomReviewedKind = 'room-reviewed';

/// Everything known about one room's status.
class RoomTeamStatus {
  /// People with the room open right now, in this app.
  final List<TeamPresence> editing;
  final List<TeamClaim> working;
  final TeamClaim? ready;
  final TeamClaim? reviewed;

  const RoomTeamStatus({
    this.editing = const [],
    this.working = const [],
    this.ready,
    this.reviewed,
  });

  bool get isEmpty =>
      editing.isEmpty && working.isEmpty && ready == null && reviewed == null;
}

TeamClaim? _newest(List<TeamClaim> list) =>
    list.isEmpty ? null : list.reduce((a, b) => a.at.isAfter(b.at) ? a : b);

RoomTeamStatus roomTeamStatus(
  TeamClaims claims,
  TeamClaims reviews,
  String roomId, {
  TeamPresenceBoard? presence,
}) {
  if (roomId.isEmpty) return const RoomTeamStatus();
  final id = roomId.toLowerCase();
  return RoomTeamStatus(
    editing: [
      for (final p in presence?.others ?? const <TeamPresence>[])
        if (p.app == TeamHost.appId && p.room.toLowerCase() == id) p,
    ],
    working: claims.active ? claims.on('room', roomId) : const [],
    ready: reviews.active ? _newest(reviews.on(kRoomReadyKind, roomId)) : null,
    reviewed:
        reviews.active ? _newest(reviews.on(kRoomReviewedKind, roomId)) : null,
  );
}

Future<String> _clear(TeamClaims reviews, String kind, String roomId) async {
  for (final c in reviews.on(kind, roomId)) {
    final error = await reviews.set(
      kind: kind,
      id: roomId,
      label: c.label,
      who: c.who,
      whoName: c.whoName,
      on: false,
    );
    if (error.isNotEmpty) return error;
  }
  return '';
}

/// Marks [roomId] ready for review ([on] false: no longer). Returns '' or
/// what went wrong.
Future<String> setRoomReady(
  TeamClaims reviews,
  String roomId, {
  required bool on,
}) async {
  if (!on) return _clear(reviews, kRoomReadyKind, roomId);
  final error = await reviews.set(
    kind: kRoomReadyKind,
    id: roomId,
    label: '$roomId - ready to approve',
    who: reviews.me.user,
    whoName: reviews.myName(),
    on: true,
  );
  if (error.isNotEmpty) return error;
  return _clear(reviews, kRoomReviewedKind, roomId);
}

/// Marks [roomId]'s review complete ([on] false: not complete). Returns ''
/// or what went wrong.
Future<String> setRoomReviewed(
  TeamClaims reviews,
  String roomId, {
  required bool on,
}) async {
  if (!on) return _clear(reviews, kRoomReviewedKind, roomId);
  final error = await reviews.set(
    kind: kRoomReviewedKind,
    id: roomId,
    label: '$roomId - approved, ready to order',
    who: reviews.me.user,
    whoName: reviews.myName(),
    on: true,
  );
  if (error.isNotEmpty) return error;
  return _clear(reviews, kRoomReadyKind, roomId);
}

/// The status of a room, each with the person behind it: who is editing it
/// now, who is tagged as working on it, who marked it ready to approve, who
/// approved it. Each person is their avatar with a small badge for what they
/// are doing. Nothing when there is nothing to say. [labels] adds a word or
/// two beside each, for the Project page's rows.
class RoomStatusIcons extends StatelessWidget {
  const RoomStatusIcons({
    super.key,
    required this.roomId,
    this.size = 18,
    this.color,
    this.labels = false,
  });

  final String roomId;
  final double size;
  final Color? color;
  final bool labels;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final claims = provider.teamClaims;
    final reviews = provider.teamReviews;
    final presence = provider.teamPresence;
    if (roomId.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([claims, reviews, presence]),
      builder: (context, _) {
        final status =
            roomTeamStatus(claims, reviews, roomId, presence: presence);
        if (status.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final locked = provider.roomLockHoldersFor(roomId).isNotEmpty;

        Widget item({
          required String key,
          required List<String> logins,
          required IconData badge,
          required Color tint,
          required String tip,
          required String word,
        }) =>
            Padding(
              padding: EdgeInsets.only(left: labels ? 8 : 4),
              child: Tooltip(
                message: tip,
                child: Row(
                  key: ValueKey('${key}_$roomId'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final login in logins)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: _BadgedAvatar(
                          login: login,
                          badge: badge,
                          tint: tint,
                          size: size,
                        ),
                      ),
                    if (labels) ...[
                      const SizedBox(width: 2),
                      Text(
                        word,
                        key: ValueKey('${key}_label_$roomId'),
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: color ?? tint),
                      ),
                    ],
                  ],
                ),
              ),
            );
        String names(Iterable<String> list) => list.join(', ');
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 2,
          children: [
            if (status.editing.isNotEmpty)
              item(
                key: 'room_status_editing',
                logins: [for (final p in status.editing) p.user],
                badge: Icons.edit,
                tint: scheme.tertiary,
                tip: [
                  for (final p in status.editing)
                    '${p.label} has this room open in ${p.appName}',
                ].join('\n'),
                word: 'Editing: ${names(status.editing.map((p) => p.label))}',
              ),
            if (status.working.isNotEmpty)
              item(
                key: 'room_status_claimed',
                logins: [for (final c in status.working) c.who],
                badge: locked ? Icons.lock : Icons.push_pin,
                tint: locked ? scheme.error : scheme.secondary,
                tip: '${names(status.working.map((c) => c.whoLabel))} '
                    '${status.working.length == 1 ? 'is' : 'are'} working on '
                    'this room'
                    '${locked ? '\nLocked: it cannot be saved over until they '
                        'are taken off it' : ''}',
                word: '${locked ? 'Locked' : 'Working on'}: '
                    '${names(status.working.map((c) => c.whoLabel))}',
              ),
            if (status.ready != null)
              item(
                key: 'room_status_ready',
                logins: [status.ready!.who],
                badge: Icons.rate_review,
                tint: scheme.secondary,
                tip: 'Ready to approve - marked by ${status.ready!.whoLabel} '
                    '${teamAgo(status.ready!.at)}',
                word: 'Ready to approve',
              ),
            if (status.reviewed != null)
              item(
                key: 'room_status_reviewed',
                logins: [status.reviewed!.who],
                badge: Icons.verified,
                tint: scheme.primary,
                tip: 'Approved - ready to order. Approved by '
                    '${status.reviewed!.whoLabel} '
                    '${teamAgo(status.reviewed!.at)}',
                word: 'Approved - ready to order',
              ),
          ],
        );
      },
    );
  }
}

/// A person's avatar with a small round badge at its lower right.
class _BadgedAvatar extends StatelessWidget {
  const _BadgedAvatar({
    required this.login,
    required this.badge,
    required this.tint,
    required this.size,
  });

  final String login;
  final IconData badge;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final dot = size * 0.6;
    return SizedBox(
      width: size + dot * 0.35,
      height: size + dot * 0.35,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          TeamAvatar(login, size: size),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: tint,
                shape: BoxShape.circle,
                border: Border.all(color: surface, width: 1.2),
              ),
              child: Icon(badge, size: dot * 0.7, color: surface),
            ),
          ),
        ],
      ),
    );
  }
}

/// A button whose menu marks a room ready for review or reviewed.
class RoomReviewMenu extends StatelessWidget {
  const RoomReviewMenu({
    super.key,
    required this.roomId,
    this.size = 20,
    this.color,
  });

  final String roomId;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final reviews = provider.teamReviews;
    if (roomId.isEmpty || !reviews.active) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: reviews,
      builder: (context, _) {
        final status =
            roomTeamStatus(provider.teamClaims, reviews, roomId);
        final ready = status.ready != null;
        final reviewed = status.reviewed != null;
        Future<void> run(Future<String> Function() action) async {
          final messenger = ScaffoldMessenger.maybeOf(context);
          final error = await action();
          if (error.isNotEmpty) {
            messenger?.showSnackBar(SnackBar(content: Text(error)));
          }
        }

        return MenuAnchor(
          menuChildren: [
            CheckboxMenuButton(
              key: ValueKey('room_review_ready_$roomId'),
              value: ready,
              onChanged: (v) => run(
                  () => setRoomReady(reviews, roomId, on: v == true)),
              child: const Text('Ready to approve'),
            ),
            CheckboxMenuButton(
              key: ValueKey('room_review_done_$roomId'),
              value: reviewed,
              onChanged: (v) => run(
                  () => setRoomReviewed(reviews, roomId, on: v == true)),
              child: const Text('Approved - ready to order'),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            key: ValueKey('room_review_button_$roomId'),
            tooltip: reviewed
                ? 'Approved - ready to order. Change the approval'
                : ready
                    ? 'Ready to approve - change the approval'
                    : 'Mark this room ready to approve, or approved',
            visualDensity: VisualDensity.compact,
            iconSize: size,
            color: color,
            icon: Icon(reviewed
                ? Icons.verified
                : ready
                    ? Icons.rate_review
                    : Icons.rate_review_outlined),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        );
      },
    );
  }
}

/// Before the open room is saved over: when someone else is working on it,
/// asks whether to take them off. True when the save can go ahead.
Future<bool> confirmRoomUnlocked(
  BuildContext context,
  AppStateProvider provider,
) async {
  final holders = provider.roomLockHolders;
  if (holders.isEmpty) return true;
  final names = holders.map((c) => c.whoLabel).join(', ');
  final room = provider.teamRoomId;
  final answer = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('room_locked_dialog'),
      icon: const Icon(Icons.lock_person),
      title: Text('$room is locked'),
      content: Text(
        '$names ${holders.length == 1 ? 'is' : 'are'} working on this room, '
        'so it cannot be saved over.\n\n'
        'Take ${holders.length == 1 ? 'them' : 'everyone'} off the room to '
        'save, or cancel and leave it locked.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('room_locked_unclaim'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(holders.length == 1
              ? 'Take ${holders.first.whoLabel} off and save'
              : 'Take them off and save'),
        ),
      ],
    ),
  );
  if (answer != true) return false;
  for (final c in holders) {
    final error = await provider.teamClaims.set(
      kind: 'room',
      id: room,
      label: c.label,
      who: c.who,
      whoName: c.whoName,
      on: false,
    );
    if (error.isNotEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(error)));
      }
      return false;
    }
  }
  return provider.roomLockHolders.isEmpty;
}
