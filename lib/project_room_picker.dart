import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'pinned_grid.dart' show gridMetric;
import 'save_actions.dart' show createProjectRoom;

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

/// Whether there is a JOB open, which is what puts the picker on the bar.
///
/// Public because the title bar has to know it too: the app's own name gives
/// the title slot up to the job the moment there is one - see main.dart.
bool projectIsOpen(AppStateProvider provider) =>
    provider.project.rooms.isNotEmpty ||
    provider.currentProjectPath.isNotEmpty ||
    provider.project.name.trim().isNotEmpty;

class ProjectRoomPicker extends StatelessWidget {
  const ProjectRoomPicker({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final rooms = provider.project.rooms;

    // Shown once there is a PROJECT, not once there are rooms.
    //
    // It used to need rooms, which hid it on exactly the job that needs it
    // most: a project just started has none, and the menu is now where a room
    // is started FROM. With no project at all it stays hidden — a permanently
    // empty dropdown explaining itself is worse than nothing.
    if (!projectIsOpen(provider)) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final open = provider.openProjectRoom;
    final onBar =
        theme.appBarTheme.foregroundColor ?? theme.colorScheme.onPrimary;

    // WHAT COMES OFF FIRST WHEN THE BAR RUNS OUT.
    //
    // This row sits in the title slot, which is whatever New, Open, Save and
    // the rest of the actions leave over - and on a window dragged narrow that
    // is not much. Its contents used to be fixed width apart from the job's
    // name, so past a certain point the Save button and the room menu were
    // simply painted over the buttons to their right.
    //
    // So it sheds, in the order the things on it can be done without:
    //
    //   1. THE STEPPERS. Previous and next room are a convenience; every room
    //      on the job is in the menu beside them.
    //   2. THE WORD ON SAVE. The button stays - a room behind its file is the
    //      one thing on this row that is a warning - as the icon it already
    //      carries, with the words on its tooltip.
    //
    // The job's name and the room stay, because between them they are what
    // the row is for: which building, which room.
    return LayoutBuilder(builder: (context, box) {
      final tight = box.maxWidth < gridMetric(context, 340);

      return Row(
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
          if (rooms.isNotEmpty && !tight)
            _StepButton(
              icon: Icons.chevron_left,
              tooltip: 'Previous room on the project',
              delta: -1,
            ),
          Flexible(child: _RoomMenu(open: open, rooms: rooms)),
          if (rooms.isNotEmpty && !tight)
            _StepButton(
              icon: Icons.chevron_right,
              tooltip: 'Next room on the project',
              delta: 1,
            ),
          if (open != null && provider.roomHasUnsavedChanges)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tooltip(
                message: 'Save this room. It has changes that are not in its '
                    'file - the project total already counts them; the file '
                    'does not.',
                child: tight
                    ? IconButton(
                        key: const ValueKey('room_picker_save'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => saveOpenRoom(context, provider),
                        icon: Icon(Icons.save, size: 16, color: onBar),
                      )
                    : TextButton.icon(
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
      );
    });
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
  /// Not a room id — those are always `room<n>` — so the last entry on the
  /// menu can never be mistaken for one of the rooms above it.
  static const String _newRoom = '<new-room>';

  final ProjectRoomRef? open;
  final List<ProjectRoomRef> rooms;

  const _RoomMenu({required this.open, required this.rooms});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final onBar =
        theme.appBarTheme.foregroundColor ?? theme.colorScheme.onPrimary;

    // EVERY NAME ON THIS MENU, WORKED OUT IN ONE PASS.
    //
    // These used to be functions asked per room and per line: the subtitle
    // alone called both of them, and it was called twice for each item just to
    // decide whether there was a subtitle at all. Each of those calls walked
    // the job's rooms or assembled a map of them, so drawing a forty-room menu
    // was hundreds of passes over the same forty rooms - and the BUTTON did
    // one of them on every rebuild of the app bar, which is every keystroke
    // anywhere in the application.
    final names = _namesOf(provider);

    return PopupMenuButton<String>(
      key: const ValueKey('room_picker_menu'),
      // The name the button no longer has room for.
      tooltip: open == null
          ? 'Switch to another room on this project'
          : '${names.nameFor(open!)}'
              '\n\nSwitch to another room on this project',
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 460),
      onSelected: (id) async {
        // Starting a room is the same decision as switching to one — "which
        // room am I working on" — so it belongs on the same menu rather than
        // three clicks away on the Project tab. It goes LAST, under a divider:
        // the rooms are the answer nearly every time this is opened.
        if (id == _newRoom) {
          await createProjectRoom(context, provider);
          return;
        }
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
              title: Text(names.codeFor(ref)),
              // THE FULL NAME BELONGS ON THE MENU, not on the button. The
              // button has to be short enough to live in a title bar; the menu
              // is a list somebody has stopped to read, and 'BSS 101' with no
              // name under it is a room nobody can tell from BSS 103.
              //
              // Worth saying here as well as on the Rooms pane: an excluded
              // room is still a room somebody works on, and the picker is
              // where they pick it.
              subtitle: names.subtitleFor(ref) == null
                  ? null
                  : Text(names.subtitleFor(ref)!),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _newRoom,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add_home_work_outlined, size: 18),
            title: Text('New room on this project…'),
            subtitle: Text('Created, saved and added to the job'),
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // THE CODE ON THE DOOR, NOT THE ROOM'S FULL NAME.
            //
            // This button lives in the title bar, in front of New, Open and
            // Save, sharing whatever those leave over with the job's name. A
            // room called 'Bessey Hall 101 Lecture Theater' filled that slot
            // by itself and pushed the rest of the row under the buttons to
            // its right. 'BSS 101' is what the room is called on every door,
            // drawing and work order in the building, it is seven characters,
            // and the full name is one press or one hover away.
            Flexible(
              child: Text(
                open != null
                    ? names.codeFor(open!)
                    : rooms.isEmpty
                    ? 'No rooms yet'
                    : 'Pick a room',
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: onBar,
                  fontStyle: open == null ? FontStyle.italic : null,
                ),
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
  /// Every room's names, read off the job once.
  static _RoomNames _namesOf(AppStateProvider provider) {
    final estimate = provider.priceProject();
    return _RoomNames(
      full: {for (final room in estimate.rooms) room.ref.id: room.name},
      codes: estimate.roomCodeNames,
    );
  }
}

/// What to call each room, in the two lengths the picker needs.
///
/// A value built once per build rather than three functions asked per room:
/// the button, the menu titles and the menu subtitles all want the same two
/// answers about the same rooms, and computing them per question is how a
/// dropdown of forty ended up walking the job hundreds of times to open.
class _RoomNames {
  /// Room id -> what the room is actually called.
  final Map<String, String> full;

  /// Room id -> the code on its door, which is often the same string.
  final Map<String, String> codes;

  const _RoomNames({required this.full, required this.codes});

  /// A room's full name: the label somebody typed, else what the job calls it,
  /// else the file it lives in.
  String nameFor(ProjectRoomRef ref) {
    if (ref.label.trim().isNotEmpty) return ref.label.trim();
    return full[ref.id] ?? ref.fallbackName;
  }

  /// The shortest true name this room has: usually the code on the door.
  ///
  /// WIDTH IS THE WHOLE REASON THIS EXISTS, so width is what picks between the
  /// two. On a real room the code wins by a mile - 'BSS 101' against 'Bessey
  /// Hall 101 Lecture Theater' - which is the case this button was made
  /// shorter for.
  ///
  /// It loses on the rooms where it is not really a code. A config still
  /// carrying the template's defaults reads as 'UNKNOWN 000', and a room that
  /// could not be read has no code at all; both are longer than, or no better
  /// than, what the room is actually called. Comparing the two lengths sorts
  /// every one of those cases out without this having to know what any
  /// particular placeholder looks like.
  String codeFor(ProjectRoomRef ref) {
    final name = nameFor(ref);
    final code = codes[ref.id] ?? '';
    if (code.isEmpty) return name;
    return code.length <= name.length ? code : name;
  }

  /// What goes under a room on the menu: its full name when that is not just
  /// the code again, and whether the job counts it.
  String? subtitleFor(ProjectRoomRef ref) {
    final name = nameFor(ref);
    final parts = [
      if (name != codeFor(ref)) name,
      if (!ref.included) 'Not counted in the project total',
    ];
    return parts.isEmpty ? null : parts.join('  ·  ');
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
        '$name has changes that are not in its file - a field, a box on a '
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
