import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart' show PricingTier;
import 'building_project.dart' show ManualRoom;
import 'contrast.dart' show errorTextOn;
import 'cost_estimate.dart' show formatMoney;
import 'equipment_lifecycle.dart' show kRoomRefreshCategory;
import 'manual_rooms_dialog.dart' show showManualRoomForm;
import 'project_schedule.dart' show formatScheduleDate;
import 'save_actions.dart' show buildRoomFromLineItem;

/// ============================================================================
///  THE PLAN AS LINE ITEMS
/// ============================================================================
///  A building can be on this app's refresh plan without a single room having
///  been drawn. The RYG imports are exactly that: a folder of jobs whose rooms
///  are a name, a date, a life and a figure off a spreadsheet, with no config
///  file anywhere under them. See [ManualRoom].
///
///  Those jobs were readable and not editable. The plan drew them, the totals
///  counted them, the campus sheet added them up, and the only way to
///  correct a date was the campus's per-job dialog - which is a screen up and
///  one building sideways from where the wrong date is being read. From the
///  job itself there was nothing to press.
///
///  So every row that did NOT come from a config file is a LINE ITEM here: the
///  date, the years in service and the cost are edited in place, on the job,
///  and written to the job's own file by the same Save as everything else.
///
///  WHY A ROW FROM A CONFIG FILE IS NOT ONE. A drawn room's dates live on its
///  equipment — fourteen boxes, each with its own install date and its own
///  life — and the plan's figure for that room is the sum of them. A cost box
///  on the plan row would have to either overwrite fourteen prices or sit
///  beside them meaning nothing. Those rooms are edited where their facts are,
///  which is the room's own Lifecycle tab.
///
///  AND THE LINE IS MEANT TO BE REPLACED. An estimate typed off a spreadsheet
///  is a placeholder for a room somebody will eventually draw, and the swap is
///  one action — see [swapManualRoomLine] and
///  [AppStateProvider.swapManualRoomForConfig] — so the estimate leaves the
///  plan in the same breath the real room joins it.
/// ============================================================================

/// Adds a line item to the open job, asking for it first.
Future<void> addManualRoomLine(BuildContext context) async {
  final provider = context.read<AppStateProvider>();
  final asked = await showManualRoomForm(
    context,
    baseCosts: provider.baseCosts,
    currency: provider.project.currency,
  );
  if (asked == null) return;
  provider.addProjectManualRoom(
    name: asked.name,
    installedOn: asked.installedOn,
    lifeYears: asked.lifeYears,
    replacementCost: asked.replacementCost,
    category: asked.category,
    notes: asked.notes,
  );
}

/// Edits one line item on the open job: the date, the years in service, the
/// cost.
Future<void> editManualRoomLine(BuildContext context, ManualRoom room) async {
  final provider = context.read<AppStateProvider>();
  final asked = await showManualRoomForm(
    context,
    existing: room,
    baseCosts: provider.baseCosts,
    currency: provider.project.currency,
    id: room.id,
  );
  if (asked == null) return;
  provider.updateProjectManualRoom(asked);
}

/// Takes a line off the plan, with the undo beside the news of it.
///
/// A line item is the only record of its room - there is no file behind it -
/// so this is the one removal on the Project tab that cannot be shrugged off
/// as "the file is untouched". See
/// [AppStateProvider.removeProjectManualRoom].
void removeManualRoomLine(BuildContext context, ManualRoom room) {
  final provider = context.read<AppStateProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final at = provider.projectManualRoomIndex(room.id);
  final removed = provider.removeProjectManualRoom(room.id);
  if (removed == null) return;
  showTimedSnackBar(
    messenger,
    SnackBar(
      content: Text('${removed.name} is off the plan.'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => provider.restoreProjectManualRoom(removed, at: at),
      ),
    ),
  );
}

/// Builds a REAL ROOM from one line item, and takes the estimate off the plan.
///
/// The other half of [swapManualRoomLine]. That one is for a room somebody has
/// already drawn; this is for the far more common case where nobody has, and
/// the estimate is all there is. The room type the line was priced against is
/// already known - it is in the line's own notes - so the new-room dialog opens
/// on it instead of on a list of twenty-seven. See [buildRoomFromLineItem].
Future<void> buildRoomFromLine(BuildContext context, ManualRoom room) async {
  final provider = context.read<AppStateProvider>();
  await buildRoomFromLineItem(context, provider, room);
}

/// Replaces one line item with the room config somebody has since drawn.
///
/// The point of the whole feature: a building enters as an estimate per room
/// and is rebuilt one room at a time, and each time a room is drawn its
/// estimate becomes the wrong number on the plan. The picker asks for the
/// config, the job gains the real room under the line's own name, and the line
/// goes — in one step, so the two of them can never both be on the plan.
Future<void> swapManualRoomLine(BuildContext context, ManualRoom room) async {
  final provider = context.read<AppStateProvider>();
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Which room config replaces ${room.name}?',
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  final file = picked?.files.single.path;
  if (file == null || !context.mounted) return;

  final error = provider.swapManualRoomForConfig(room.id, file);
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  final card = Theme.of(context).cardColor;
  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(
        error.isEmpty
            ? '${room.name} is now ${path.basename(file)}. Its estimate is off '
                  'the plan and the room is priced from its own parts.'
            : error,
      ),
      backgroundColor: error.isEmpty ? null : errorTextOn(scheme, card),
    ),
  );
}

/// What a line item says on one line: when it was last done, how long it is
/// good for, and what it costs to do again.
///
/// The cost says whether it is a typed figure or one off the base-cost card,
/// because a card figure read as a quote is how a budget goes wrong quietly —
/// the same bargain every other estimated figure in this app makes.
String manualRoomLineFacts(
  BuildContext context,
  ManualRoom room, {
  required String currency,
}) {
  final provider = context.read<AppStateProvider>();
  final base = provider.baseCosts
      .priceFor(
        room.category.trim().isEmpty
            ? kRoomRefreshCategory
            : room.category.trim(),
        PricingTier.msrp,
      )
      .price;
  return [
    room.installedOn == null
        ? 'no date'
        : 'last done ${formatScheduleDate(room.installedOn!)}',
    room.lifeYears > 0
        ? '${room.lifeYears} years in service'
        : 'standard cycle',
    if (room.replacementCost > 0)
      formatMoney(room.replacementCost, currency)
    else if (base > 0)
      '${formatMoney(base, currency)} est.'
    else
      'not priced',
    if (room.notes.trim().isNotEmpty) room.notes.trim(),
  ].join('  ·  ');
}

/// The three things that can be done to a line item, as icon buttons: edit it,
/// swap the real room in for it, take it off the plan.
///
/// One widget rather than three copies, because the line appears in two places
/// on the Project tab — the room list and the replacement plan — and a swap
/// that was offered on one of them and not the other would read as two
/// different kinds of row.
class ManualRoomLineActions extends StatelessWidget {
  final ManualRoom room;

  /// Smaller on the plan, where the row is already dense with year chips.
  final double iconSize;

  const ManualRoomLineActions({
    super.key,
    required this.room,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: ValueKey('line_item_edit_${room.id}'),
        tooltip: 'Change the date, the years in service or the cost',
        icon: Icon(Icons.edit_outlined, size: iconSize),
        onPressed: () => editManualRoomLine(context, room),
      ),
      // BUILD IT. The estimate becomes a room file with the equipment its own
      // room type is priced on already in it - which is the point of having
      // priced it that way. Before Swap, because on a refresh plan almost
      // nothing has been drawn yet: the room that already exists is the rare
      // case.
      IconButton(
        key: ValueKey('line_item_build_${room.id}'),
        tooltip: room.sourceType.isEmpty
            ? 'Build a room file from this line'
            : 'Build a room file from this line (${room.sourceType})',
        icon: Icon(Icons.construction_outlined, size: iconSize),
        onPressed: () => buildRoomFromLine(context, room),
      ),
      IconButton(
        key: ValueKey('line_item_swap_${room.id}'),
        tooltip: 'Replace this estimate with a room config that already exists',
        icon: Icon(Icons.swap_horiz, size: iconSize),
        onPressed: () => swapManualRoomLine(context, room),
      ),
      IconButton(
        key: ValueKey('line_item_remove_${room.id}'),
        tooltip: 'Take this line off the plan',
        icon: Icon(Icons.close, size: iconSize),
        onPressed: () => removeManualRoomLine(context, room),
      ),
    ],
  );
}

/// The button that starts one. Named for what it makes rather than for what it
/// is not: 'a room with no config' is how the code thinks about these and not
/// how anybody reading a budget does.
class AddManualRoomLineButton extends StatelessWidget {
  final bool filled;

  const AddManualRoomLineButton({super.key, this.filled = false});

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.playlist_add, size: 18);
    const label = Text('Add a line item…');
    const key = ValueKey('line_item_add');
    return filled
        ? FilledButton.tonalIcon(
            key: key,
            onPressed: () => addManualRoomLine(context),
            icon: icon,
            label: label,
          )
        : OutlinedButton.icon(
            key: key,
            onPressed: () => addManualRoomLine(context),
            icon: icon,
            label: label,
          );
  }
}

/// One line item as a card, for the job's room list.
///
/// It sits under the drawn rooms and looks deliberately unlike them: a room
/// card carries labor, parts and a room total, and this carries a date, a
/// cycle and one figure, because that is all there is. Dressing it up to match
/// would be claiming a parts list that does not exist.
class ManualRoomLineCard extends StatelessWidget {
  final ManualRoom room;
  final String currency;

  const ManualRoomLineCard({
    super.key,
    required this.room,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('line_item_${room.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              Icons.playlist_add_check,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(room.name, style: theme.textTheme.titleSmall),
                  Text(
                    manualRoomLineFacts(context, room, currency: currency),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ManualRoomLineActions(room: room),
          ],
        ),
      ),
    );
  }
}

/// What the line-item list is headed with, and why it is a separate list.
class ManualRoomLinesHeading extends StatelessWidget {
  final int count;

  const ManualRoomLinesHeading({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'LINE ITEMS: $count room${count == 1 ? '' : 's'} with no config',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'A date, how many years it is good for and what it costs to do '
          'again. They age and fall due on the replacement plan like a drawn '
          'room, and nothing here is priced from parts or ordered. Swap one '
          'for its room config once somebody has drawn it.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
