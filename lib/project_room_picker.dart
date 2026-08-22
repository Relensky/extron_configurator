import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';

/// ============================================================================
///  THE ROOM PICKER IN THE TITLE BAR
/// ============================================================================
///  A job is a building and a building is a folder of rooms, so the thing
///  somebody does over and over is not "open a config" — it is "now the one
///  next door". Doing that through a file dialog means remembering which file
///  was which, and doing it from the Project tab means leaving whatever page
///  the question came up on.
///
///  So the picker lives in the title bar, on every tab. Switch rooms while
///  standing on Cost and you are looking at the next room's Cost; switch while
///  standing on Racks and you are looking at its rack. That is the whole point:
///  the tab is the QUESTION and the room is the SUBJECT, and they should be
///  changeable independently.
///
///  It appears only when a project has rooms. With no project it would be a
///  permanently empty dropdown explaining itself, which is worse than nothing.
///
///  SWITCHING LOADS FROM DISK, so unsaved work in the room being left would go.
///  [AppStateProvider.roomHasUnsavedChanges] is asked first — it compares the
///  room to its files rather than trusting a flag somebody forgot to set — and
///  the offer to save is the default action.
/// ============================================================================

class ProjectRoomPicker extends StatelessWidget {
  const ProjectRoomPicker({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final rooms = provider.project.rooms;
    if (rooms.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final open = provider.openProjectRoom;
    final onBar =
        theme.appBarTheme.foregroundColor ?? theme.colorScheme.onPrimary;

    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.apartment, size: 16, color: onBar.withValues(alpha: 0.7)),
          const SizedBox(width: 6),
          // The job's name, small: it is context, not the subject. The room is
          // the subject and it is the thing in the button.
          //
          // Flexible, and the only flexible thing in this Row, so it is the
          // first to give way. The title slot is a few hundred pixels wide and
          // this row can carry a stepper, a room menu AND a Save room button
          // once the open room is behind its file — which is exactly when the
          // job's name is the least of what somebody needs to read.
          if (provider.projectDisplayName.trim().isNotEmpty)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  provider.projectDisplayName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: onBar.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          _StepButton(
            icon: Icons.chevron_left,
            tooltip: 'Previous room on the project',
            delta: -1,
          ),
          _RoomMenu(open: open, rooms: rooms),
          _StepButton(
            icon: Icons.chevron_right,
            tooltip: 'Next room on the project',
            delta: 1,
          ),
          if (open != null && provider.roomHasUnsavedChanges)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tooltip(
                message: 'This room has changes that are not in its file. The '
                    'project total already counts them; the file does not.',
                child: TextButton.icon(
                  key: const ValueKey('room_picker_save'),
                  onPressed: () => saveOpenRoom(context, provider),
                  icon: Icon(Icons.save, size: 16, color: onBar),
                  label: Text(
                    'Save room',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: onBar),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Writes the open room back over its own file. Shared by the picker's button
/// and by the "save first" answer to the switch prompt.
Future<bool> saveOpenRoom(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await provider.saveRoomInPlace();
  final failed = result.startsWith('Error');
  showTimedSnackBar(
    messenger,
    SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(failed ? result : 'Room saved to $result'),
      backgroundColor: failed ? snackErrorFillOn(messenger) : null,
    ),
  );
  return !failed;
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final int delta;

  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.delta,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    return IconButton(
      key: ValueKey('room_picker_step_$delta'),
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      onPressed: provider.project.rooms.length < 2
          ? null
          : () async {
              if (!await confirmLeavingRoom(context, provider)) return;
              if (!context.mounted) return;
              final messenger = ScaffoldMessenger.of(context);
              final error = await provider.stepProjectRoom(delta);
              if (error.isEmpty) return;
              showTimedSnackBar(
                messenger,
                SnackBar(
                  duration: const Duration(seconds: 5),
                  content: Text(error),
                  backgroundColor: snackErrorFillOn(messenger),
                ),
              );
            },
    );
  }
}

class _RoomMenu extends StatelessWidget {
  final ProjectRoomRef? open;
  final List<ProjectRoomRef> rooms;

  const _RoomMenu({required this.open, required this.rooms});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final onBar =
        theme.appBarTheme.foregroundColor ?? theme.colorScheme.onPrimary;

    return PopupMenuButton<String>(
      key: const ValueKey('room_picker_menu'),
      tooltip: 'Switch to another room on this project',
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 460),
      onSelected: (id) async {
        final ref = provider.project.roomById(id);
        if (ref == null) return;
        if (!await confirmLeavingRoom(context, provider)) return;
        if (!context.mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        final error = await provider.openProjectRoomRef(ref);
        if (error.isEmpty) return;
        showTimedSnackBar(
          messenger,
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text(error),
            backgroundColor: snackErrorFillOn(messenger),
          ),
        );
      },
      itemBuilder: (ctx) => [
        for (final ref in rooms)
          PopupMenuItem(
            value: ref.id,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                ref.id == open?.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
              ),
              title: Text(_nameFor(provider, ref)),
              subtitle: ref.included
                  ? null
                  // Worth saying here as well as on the Rooms pane: an
                  // excluded room is still a room somebody works on, and the
                  // picker is where they pick it.
                  : const Text('Not counted in the project total'),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              open == null
                  ? 'Pick a room'
                  : _nameFor(provider, open!),
              style: theme.textTheme.titleSmall?.copyWith(
                color: onBar,
                fontStyle: open == null ? FontStyle.italic : null,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 18, color: onBar),
          ],
        ),
      ),
    );
  }

  /// The room's label if it has one, else the config's own name once it has
  /// been read, else the file name. The middle case is why this asks the
  /// project's cached read rather than only the ref.
  String _nameFor(AppStateProvider provider, ProjectRoomRef ref) {
    if (ref.label.trim().isNotEmpty) return ref.label.trim();
    for (final room in provider.priceProject().rooms) {
      if (room.ref.id == ref.id) return room.name;
    }
    return ref.fallbackName;
  }
}

/// Offers to save the open room before it is replaced.
///
/// Returns false only when the user backs out — a failed save also stops the
/// switch, because losing the work to a full disk would be the same loss with
/// an extra step.
Future<bool> confirmLeavingRoom(
  BuildContext context,
  AppStateProvider provider,
) async {
  if (!provider.roomHasUnsavedChanges) return true;
  final name = provider.openProjectRoom?.fallbackName ?? 'This room';

  final answer = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save this room first?'),
      content: Text(
        '$name has changes that are not in its file — a field, a box on a '
        'drawing, a price, or all three.\n\n'
        'Switching rooms reads the next room off disk, so anything not saved '
        'here goes.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'cancel'),
          child: const Text('Stay here'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'discard'),
          child: const Text('Discard'),
        ),
        FilledButton(
          key: const ValueKey('leave_room_save'),
          onPressed: () => Navigator.pop(ctx, 'save'),
          child: const Text('Save and switch'),
        ),
      ],
    ),
  );

  if (answer == 'save') {
    if (!context.mounted) return false;
    return saveOpenRoom(context, provider);
  }
  return answer == 'discard';
}
