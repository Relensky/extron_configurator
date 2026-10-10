import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'team/team_claims.dart';
import 'team/team_widgets.dart' show teamAgo;

/// ============================================================================
///  ROOM STATUS: WORKING ON, READY FOR REVIEW, REVIEW COMPLETE
/// ============================================================================
///  "Working on" is the team kit's tag (team_claims.dart): while someone else
///  is on a room, it cannot be saved over here until they are taken off it.
///
///  Review marks are kept the same way, in their own folder so the other team
///  apps do not read them as "working on":
///
///    * READY FOR REVIEW - the room is done and wants checking before
///      anything is bought for it.
///    * REVIEW COMPLETE - it was checked. Marking it clears ready; marking it
///      ready again clears complete, for the next round.
/// ============================================================================

const String kRoomReadyKind = 'room-ready';
const String kRoomReviewedKind = 'room-reviewed';

/// Everything known about one room's status.
class RoomTeamStatus {
  final List<TeamClaim> working;
  final TeamClaim? ready;
  final TeamClaim? reviewed;

  const RoomTeamStatus({
    this.working = const [],
    this.ready,
    this.reviewed,
  });

  bool get isEmpty => working.isEmpty && ready == null && reviewed == null;
}

TeamClaim? _newest(List<TeamClaim> list) =>
    list.isEmpty ? null : list.reduce((a, b) => a.at.isAfter(b.at) ? a : b);

RoomTeamStatus roomTeamStatus(
  TeamClaims claims,
  TeamClaims reviews,
  String roomId,
) {
  if (roomId.isEmpty) return const RoomTeamStatus();
  return RoomTeamStatus(
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
    label: '$roomId - ready for review',
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
    label: '$roomId - review complete',
    who: reviews.me.user,
    whoName: reviews.myName(),
    on: true,
  );
  if (error.isNotEmpty) return error;
  return _clear(reviews, kRoomReadyKind, roomId);
}

/// The icons for a room: someone working on it, ready for review, review
/// complete. Nothing when there is nothing to say.
class RoomStatusIcons extends StatelessWidget {
  const RoomStatusIcons({
    super.key,
    required this.roomId,
    this.size = 16,
    this.color,
  });

  final String roomId;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final claims = provider.teamClaims;
    final reviews = provider.teamReviews;
    if (roomId.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([claims, reviews]),
      builder: (context, _) {
        final status = roomTeamStatus(claims, reviews, roomId);
        if (status.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final locked = provider.roomLockHoldersFor(roomId).isNotEmpty;
        Widget icon(String key, IconData data, Color? tint, String tip) =>
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tooltip(
                message: tip,
                child: Icon(data,
                    key: ValueKey('${key}_$roomId'),
                    size: size,
                    color: tint ?? color),
              ),
            );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status.working.isNotEmpty)
              icon(
                'room_status_claimed',
                locked ? Icons.lock_person : Icons.person_pin_circle,
                locked ? scheme.tertiary : null,
                '${status.working.map((c) => c.whoLabel).join(', ')} '
                '${status.working.length == 1 ? 'is' : 'are'} working on '
                'this room'
                '${locked ? '\nLocked: it cannot be saved over until they '
                    'are taken off it' : ''}',
              ),
            if (status.ready != null)
              icon(
                'room_status_ready',
                Icons.rate_review,
                scheme.secondary,
                'Ready for review - marked by ${status.ready!.whoLabel} '
                '${teamAgo(status.ready!.at)}',
              ),
            if (status.reviewed != null)
              icon(
                'room_status_reviewed',
                Icons.verified,
                scheme.primary,
                'Review complete - ${status.reviewed!.whoLabel} '
                '${teamAgo(status.reviewed!.at)}',
              ),
          ],
        );
      },
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
              child: const Text('Ready for review'),
            ),
            CheckboxMenuButton(
              key: ValueKey('room_review_done_$roomId'),
              value: reviewed,
              onChanged: (v) => run(
                  () => setRoomReviewed(reviews, roomId, on: v == true)),
              child: const Text('Review complete'),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            key: ValueKey('room_review_button_$roomId'),
            tooltip: reviewed
                ? 'Review complete - change the review status'
                : ready
                    ? 'Ready for review - change the review status'
                    : 'Mark this room ready for review, or reviewed',
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
