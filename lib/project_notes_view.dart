import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'live_text_field.dart';
import 'project_estimate.dart';

/// ============================================================================
///  NOTES — WHAT IS TRUE ABOUT THE JOB THAT NO FIELD ASKS FOR
/// ============================================================================
///  Every other thing this app records is a field somebody filled in: a model,
///  a price, a vendor, a date. A job also accumulates facts that are not
///  answers to any question the app knows how to ask —
///
///    "the customer has approved the 86in, not the 98in, get it in writing"
///    "ceiling is asbestos above the grid, no drilling until abatement"
///    "214 shares a wall with the recording studio — no fans on that side"
///
///  — and until there was somewhere to put them they lived in an email, which
///  means the person who picks the job up next does not have them.
///
///  TWO LEVELS, because that is how they actually arrive. Some are about the
///  BUILDING and apply to everything on it (the contract, the site access, who
///  signs off). Some are about ONE ROOM and are meaningless anywhere else. A
///  single box for the whole job turns the second kind into a wall of text
///  prefixed with room numbers, which is what a notes field looks like right
///  before people stop using it.
///
///  NOT A TO-DO LIST. The job list next door is for things that have to be
///  DONE and then stop being true; this is for things that are simply true and
///  stay true. A note with a state and a due date is a to-do, and it belongs on
///  that pane — see project_todo_view.dart.
///
///  BOTH ALREADY GO OUT ON THE WORKBOOK: the project's own note is on the
///  Summary, and a room's note is in the Status column of the Rooms table. So
///  what is typed here reaches the document somebody else reads without
///  anybody having to copy it across.
/// ============================================================================

/// The notes pane, as slivers for the project tab's one scroll view.
List<Widget> notesSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.watch<AppStateProvider>();
  final theme = Theme.of(context);
  final project = provider.project;

  // The building code and room number — 'BSS 103' — the same as everywhere
  // else a room has to be told apart from the others in the same building.
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(
              icon: Icons.apartment,
              text: 'THE JOB',
              hint: 'True of the whole building — the contract, site access, '
                  'who signs off.',
            ),
            const SizedBox(height: 6),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: LiveTextField(
                  key: const ValueKey('project_notes_box'),
                  // Keyed on the project's file so opening a different job
                  // replaces what is in the box rather than leaving the last
                  // job's notes on screen.
                  fieldId: 'project_notes_${provider.currentProjectPath}',
                  initial: project.notes,
                  hint: 'e.g. Customer approved the 86in, not the 98in — get '
                      'it in writing before the order goes in.',
                  maxLines: 6,
                  onChanged: (v) => provider.setProjectField(notes: v),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _SectionLabel(
              icon: Icons.meeting_room,
              text: 'THE ROOMS',
              hint: project.rooms.isEmpty
                  ? 'Add rooms to the job and each gets its own note.'
                  : 'True of one room only. Goes out beside that room on the '
                        'workbook.',
            ),
          ],
        ),
      ),
    ),
    if (project.rooms.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Center(
            child: Text(
              'No rooms on this job yet.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        sliver: SliverList.builder(
          itemCount: project.rooms.length,
          itemBuilder: (context, i) {
            final ref = project.rooms[i];
            return _RoomNote(
              roomId: ref.id,
              // The ref's own fallback while the room has not been read —
              // a room whose file is missing still gets a note, and it is
              // exactly the room somebody needs to write one about.
              name: roomNames[ref.id] ?? ref.fallbackName,
              notes: ref.notes,
              included: ref.included,
              provider: provider,
              theme: theme,
            );
          },
        ),
      ),
  ];
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  final String hint;

  const _SectionLabel({
    required this.icon,
    required this.text,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: muted),
            const SizedBox(width: 5),
            Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: muted,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 19, top: 1),
          child: Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// One room's note.
class _RoomNote extends StatelessWidget {
  final String roomId;
  final String name;
  final String notes;
  final bool included;
  final AppStateProvider provider;
  final ThemeData theme;

  const _RoomNote({
    required this.roomId,
    required this.name,
    required this.notes,
    required this.included,
    required this.provider,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (!included) ...[
                  const SizedBox(width: 8),
                  // Worth saying here as well as on the Rooms pane: a note
                  // about a room that is out of the total still gets written
                  // and still goes out on the workbook.
                  Text(
                    'not counted in the total',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ],
            ),
            LiveTextField(
              key: ValueKey('room_notes_box_$roomId'),
              fieldId: 'room_notes_$roomId',
              initial: notes,
              hint: 'e.g. Ceiling is asbestos above the grid — no drilling '
                  'until abatement.',
              maxLines: 3,
              onChanged: (v) =>
                  provider.updateProjectRoom(roomId, notes: v),
            ),
          ],
        ),
      ),
    );
  }
}
