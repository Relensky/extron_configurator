import 'package:flutter/material.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart' show PricingTier;
import 'base_costs.dart';
import 'building_project.dart';
import 'cost_estimate.dart' show formatMoney;
import 'equipment_lifecycle.dart' show kRoomRefreshCategory;
import 'project_schedule.dart' show formatScheduleDate;
import 'stepped_date_picker.dart';

/// ============================================================================
///  THE ROOMS NOBODY HAS DRAWN
/// ============================================================================
///  A refresh plan is read for the whole building, and most of a building has
///  never been through this app: the rooms that have are the ones somebody
///  rebuilt recently, and the other forty are a projector, a screen and a wall
///  plate that went in in 2014. Nobody is going to draw those forty to get
///  them onto a budget, and until now leaving them off was the only option —
///  which made every plan read as a fraction of the real ask.
///
///  So a room can be typed in: a name, when it was last done, how long it
///  lasts, and what it costs to do again. It ages on the same cycle as a drawn
///  room, lands in the same year columns and adds to the same totals. What it
///  does not do is pretend to know what is in it — there is no parts list, no
///  diagram and no order, and the money is a BASE COST unless somebody types a
///  figure. See [ManualRoom].
///
///  IT IS SAVED TO THE BUILDING, not to the campus. The campus is a list of
///  jobs read off disk and thrown away; the room belongs to the building it is
///  in, so it is written into that project file and is there the next time
///  anybody opens it — from the campus, from the Project tab, or from a
///  workbook.
/// ============================================================================

/// Opens the manager for [file]'s hand-added rooms. Returns true when the
/// project file was written, which is what tells the caller to re-read.
///
/// The project is loaded HERE rather than taken as an argument: the campus
/// holds paths and priced summaries, never the editable document, and handing
/// one around would be a second copy of a file somebody else may be editing.
Future<bool> showManualRoomsDialog(
  BuildContext context,
  AppStateProvider provider,
  String file, {
  String buildingName = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  BuildingProject project;
  try {
    project = await BuildingProject.load(file);
  } catch (e) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text('That job could not be opened: $e'),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
    return false;
  }
  if (!context.mounted) return false;

  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _ManualRoomsDialog(
      project: project,
      file: file,
      baseCosts: provider.baseCosts,
      currency: provider.currencySymbol,
      title: buildingName.trim().isEmpty
          ? (project.name.trim().isEmpty ? 'this job' : project.name.trim())
          : buildingName.trim(),
    ),
  );
  return saved == true;
}

class _ManualRoomsDialog extends StatefulWidget {
  final BuildingProject project;
  final String file;
  final BaseCostBook baseCosts;
  final String currency;
  final String title;

  const _ManualRoomsDialog({
    required this.project,
    required this.file,
    required this.baseCosts,
    required this.currency,
    required this.title,
  });

  @override
  State<_ManualRoomsDialog> createState() => _ManualRoomsDialogState();
}

class _ManualRoomsDialogState extends State<_ManualRoomsDialog> {
  /// Edited in memory and written once, on Save. A dialog that wrote the file
  /// on every keystroke would leave a half-typed room on disk the moment
  /// somebody changed their mind.
  bool _dirty = false;
  bool _saving = false;

  List<ManualRoom> get _rooms => widget.project.manualRooms;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      key: const ValueKey('manual_rooms_dialog'),
      title: Text('Rooms added by hand: ${widget.title}'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Rooms with no config on this job: a name, when it was last '
              'done, and what it costs to do again. They age and fall due on '
              'the plan like every other room. Leave the cost blank and the '
              'base-cost card prices them.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: _rooms.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'None yet. Add the rooms this building has that '
                        'nobody has drawn - they are usually most of it.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _rooms.length,
                      itemBuilder: (ctx, i) => _row(_rooms[i]),
                    ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('manual_room_add'),
                icon: const Icon(Icons.add_home_outlined, size: 18),
                label: const Text('Add a room'),
                onPressed: _saving ? null : _add,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('manual_rooms_save'),
          onPressed: _saving || !_dirty ? null : _save,
          child: const Text('Save to the job'),
        ),
      ],
    );
  }

  Widget _row(ManualRoom room) {
    final theme = Theme.of(context);
    final cost = room.replacementCost > 0
        ? formatMoney(room.replacementCost, widget.currency)
        : _basePrice(room) > 0
        ? '${formatMoney(_basePrice(room), widget.currency)} est.'
        : 'not priced';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(room.name, style: theme.textTheme.bodyMedium),
                Text(
                  [
                    room.installedOn == null
                        ? 'no date'
                        : 'last done ${formatScheduleDate(room.installedOn!)}',
                    room.lifeYears > 0
                        ? '${room.lifeYears} yr cycle'
                        : 'standard cycle',
                    cost,
                    if (room.notes.trim().isNotEmpty) room.notes.trim(),
                  ].join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('manual_room_edit_${room.id}'),
            tooltip: 'Edit this room',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () => _edit(room),
          ),
          IconButton(
            key: ValueKey('manual_room_remove_${room.id}'),
            tooltip: 'Take it off the plan',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => setState(() {
              widget.project.removeManualRoom(room.id);
              _dirty = true;
            }),
          ),
        ],
      ),
    );
  }

  /// What the base-cost card says a room like this costs, or 0.
  double _basePrice(ManualRoom room) {
    final wanted = room.category.trim().isEmpty
        ? kRoomRefreshCategory
        : room.category.trim();
    return widget.baseCosts.priceFor(wanted, PricingTier.msrp).price;
  }

  Future<void> _add() async {
    final asked = await _askRoom();
    if (asked == null) return;
    setState(() {
      widget.project.addManualRoom(
        name: asked.name,
        installedOn: asked.installedOn,
        lifeYears: asked.lifeYears,
        replacementCost: asked.replacementCost,
        category: asked.category,
        notes: asked.notes,
      );
      _dirty = true;
    });
  }

  Future<void> _edit(ManualRoom room) async {
    final asked = await _askRoom(existing: room);
    if (asked == null) return;
    setState(() {
      widget.project.updateManualRoom(asked.copyWith());
      _dirty = true;
    });
  }

  Future<ManualRoom?> _askRoom({ManualRoom? existing}) => showDialog<ManualRoom>(
    context: context,
    builder: (_) => _ManualRoomForm(
      existing: existing,
      baseCosts: widget.baseCosts,
      currency: widget.currency,
      id: existing?.id ?? '',
    ),
  );

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.project.save(widget.file);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showTimedSnackBar(
        messenger,
        SnackBar(
          content: Text('The job could not be saved: $e'),
          backgroundColor: snackErrorFillOn(messenger),
        ),
      );
    }
  }
}

/// One room, typed in.
class _ManualRoomForm extends StatefulWidget {
  final ManualRoom? existing;
  final BaseCostBook baseCosts;
  final String currency;
  final String id;

  const _ManualRoomForm({
    required this.existing,
    required this.baseCosts,
    required this.currency,
    required this.id,
  });

  @override
  State<_ManualRoomForm> createState() => _ManualRoomFormState();
}

class _ManualRoomFormState extends State<_ManualRoomForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _life = TextEditingController(
    text: (widget.existing?.lifeYears ?? 0) > 0
        ? '${widget.existing!.lifeYears}'
        : '',
  );
  late final TextEditingController _cost = TextEditingController(
    text: (widget.existing?.replacementCost ?? 0) > 0
        ? '${widget.existing!.replacementCost}'
        : '',
  );
  late final TextEditingController _notes = TextEditingController(
    text: widget.existing?.notes ?? '',
  );
  late DateTime? _installed = widget.existing?.installedOn;
  late String _category = widget.existing?.category ?? '';

  @override
  void dispose() {
    _name.dispose();
    _life.dispose();
    _cost.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    // The card's own lines, so a room is priced off the same figures every
    // other estimate in the app falls back to.
    final categories = [
      kRoomRefreshCategory,
      for (final c in widget.baseCosts.costs)
        if (c.category != kRoomRefreshCategory) c.category,
    ];

    return AlertDialog(
      key: const ValueKey('manual_room_form'),
      title: Text(widget.existing == null ? 'Add a room' : 'Edit the room'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('manual_room_name'),
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Room',
                  hintText: 'e.g. BSS 214',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('manual_room_date'),
                      icon: const Icon(Icons.event, size: 18),
                      label: Text(
                        _installed == null
                            ? 'When was it last done?'
                            : formatScheduleDate(_installed!),
                      ),
                      onPressed: () async {
                        final picked = await showSteppedDatePicker(
                          context,
                          initialDate: _installed ?? DateTime(now.year - 8),
                          firstDate: DateTime(now.year - 40),
                          lastDate: DateTime(now.year + 5, 12, 31),
                          helpText: 'When was this room last done?',
                        );
                        if (picked != null) setState(() => _installed = picked);
                      },
                    ),
                  ),
                  if (_installed != null)
                    IconButton(
                      tooltip: 'Nobody knows the date',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _installed = null),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('manual_room_life'),
                      controller: _life,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Life (years)',
                        hintText: 'blank = the standard cycle',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('manual_room_cost'),
                      controller: _cost,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Cost to do again',
                        prefixText: widget.currency,
                        hintText: 'blank = base cost',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Only worth asking while the cost is blank: it is the line the
              // room is priced FROM, and a card figure quietly overridden by a
              // typed one is two answers on one row.
              if ((double.tryParse(_cost.text.trim()) ?? 0) <= 0)
                DropdownButtonFormField<String>(
                  key: const ValueKey('manual_room_category'),
                  initialValue: categories.contains(_category)
                      ? _category
                      : kRoomRefreshCategory,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Priced from',
                    helperText: 'A line on the shared base-cost card',
                  ),
                  items: [
                    for (final c in categories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _category = v ?? ''),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('manual_room_notes'),
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'e.g. projector only, no audio',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Nothing here is ordered or drawn. The room is on the '
                'replacement plan and in its totals, and says its figure is an '
                'estimate wherever it is shown.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('manual_room_ok'),
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  ManualRoom(
                    id: widget.id,
                    name: _name.text.trim(),
                    installedOn: _installed,
                    lifeYears: int.tryParse(_life.text.trim()) ?? 0,
                    replacementCost: double.tryParse(_cost.text.trim()) ?? 0,
                    category: _category,
                    notes: _notes.text.trim(),
                  ),
                ),
          child: Text(widget.existing == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}
