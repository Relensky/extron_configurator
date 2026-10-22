import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'cost_estimate.dart' show formatMoney;
import 'project_estimate.dart' show ProjectRoomCost;

/// How much of a room's optional upgrades the project total counts.
enum RoomOptionsState { all, some, none }

/// [room]'s options on the project: all counted, some, or none. See
/// [BuildingProject.optionsCounted] and [ProjectRoomRef.optionalLinesOff].
RoomOptionsState roomOptionsState(AppStateProvider provider,
    ProjectRoomCost room) {
  if (!provider.project.optionsCounted(room.ref)) return RoomOptionsState.none;
  final keys = {for (final l in room.optionLines) l.key};
  return room.ref.optionalLinesOff.any(keys.contains)
      ? RoomOptionsState.some
      : RoomOptionsState.all;
}

/// A room's optional upgrades on the Project tab, as an icon: whether the
/// project total counts them, with what they come to on hover. Its menu
/// counts the room's options or leaves them out, and each one by itself.
/// On the room list and the priority card, so a room left out reads as left
/// out.
class ProjectRoomOptionsButton extends StatelessWidget {
  final ProjectRoomCost room;
  final String currency;

  /// The ink for the icon on the row's own fill. Null takes the theme's.
  final Color? ink;

  const ProjectRoomOptionsButton({
    super.key,
    required this.room,
    required this.currency,
    this.ink,
  });

  /// The room has options to count or leave out.
  static bool shows(ProjectRoomCost room) => room.hasOptions;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final ref = room.ref;
    final state = roomOptionsState(provider, room);
    final lines = room.optionLines;
    final allKeys = {for (final l in lines) l.key};
    final counted = provider.project.optionsCounted(ref);
    String money(double v) => formatMoney(v, currency);
    final all = money(room.grandWithOptions - room.grandWithoutOptions);
    final (icon, color, says) = switch (state) {
      RoomOptionsState.all => (
        Icons.playlist_add_check,
        ink ?? theme.colorScheme.primary,
        'Options $all - in the project total',
      ),
      RoomOptionsState.some => (
        Icons.playlist_add,
        ink ?? theme.colorScheme.tertiary,
        'Options - ${money(room.optionsCounted)} of $all in the project '
            'total',
      ),
      RoomOptionsState.none => (
        Icons.playlist_remove,
        theme.colorScheme.error,
        'Options $all - left out of the project total',
      ),
    };
    return PopupMenuButton<String>(
      key: ValueKey('project_room_optional_${ref.id}'),
      tooltip: '$says. Click to choose.',
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          key: ValueKey('project_room_optional_${ref.id}_room'),
          value: 'room',
          checked: counted,
          child: const Text('Count this room\'s options'),
        ),
        if (lines.length > 1) ...[
          const PopupMenuDivider(),
          for (final l in lines)
            CheckedPopupMenuItem(
              key: ValueKey('project_room_optional_${ref.id}_${l.key}'),
              value: 'line:${l.key}',
              checked: counted && !ref.optionalLinesOff.contains(l.key),
              child: Text('${l.name}  ${money(l.amount)}'),
            ),
        ],
      ],
      onSelected: (v) {
        if (v == 'room') {
          provider.setProjectRoomOptionsCounted(ref.id, !counted);
          return;
        }
        final key = v.substring(5);
        provider.setProjectRoomOptionLine(
          ref.id,
          key,
          !(counted && !ref.optionalLinesOff.contains(key)),
          allKeys: allKeys,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            Icon(Icons.arrow_drop_down, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}
