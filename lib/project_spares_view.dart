import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show formatMoney, trimNumber;
import 'live_text_field.dart';
import 'project_estimate.dart';

/// ============================================================================
///  THE SPARES SECTION
/// ============================================================================
///  What the job is buying that no drawing accounts for, in one place, in the
///  two shapes a spare actually comes in:
///
///    * FOR A ROOM. A fourth display for a room with three drawn. It is that
///      room's contingency, it belongs in that room's total, and the person who
///      approves it is whoever approves that room.
///    * FOR THE BUILDING. A switcher on a shelf for the campus. It belongs to
///      no room, it is the JOB's contingency, and it is approved as a
///      percentage rather than as a line - which is why a building spare
///      carries its COVERAGE: two spare projectors is a figure nobody can weigh
///      until they know two out of how many.
///
///  A BUILDING SPARE NAMES THE ROOMS IT COVERS. "2 spare projectors" on its own
///  is a row somebody has to go and research; with the twelve rooms that have
///  projectors listed under it, it is a row somebody can approve or cut.
///
///  MOVING ONE IS ONE PRESS. A spare put against a room that turns out to be
///  the shelf unit for the building, or the other way round, changes scope
///  without being deleted and retyped - see [AppStateProvider.moveProjectSpare].
///
///  TWO KINDS OF ROW, and the difference matters. A spare added here lives on
///  the PROJECT and is edited here. A spare a room asked for on its own Cost
///  tab lives in that room's file, travels with the room to whatever job it
///  ends up on, and is shown here as a fact rather than as a control: editing
///  it from the job would mean writing somebody else's room file behind their
///  back.
/// ============================================================================

/// The spares section, as slivers for the project tab's one scroll view.
List<Widget> spareSectionSlivers(
  BuildContext context,
  ProjectEstimate estimate,
) {
  final provider = context.watch<AppStateProvider>();
  final theme = Theme.of(context);
  final currency = estimate.currency;
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.name};

  final buildingSpares = estimate.buildingSpares;
  final byRoom = estimate.sparesByRoom;

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Card(
          key: const ValueKey('project_spares_section'),
          margin: EdgeInsets.zero,
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _SectionHeader(estimate: estimate),
                if (buildingSpares.isEmpty && byRoom.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Nothing on this job is spared yet. Add one here for the '
                      'building or for a room, or ask for one on a room\'s own '
                      'Cost page.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                // THE BUILDING'S OWN, first. It is the shorter list and the one
                // nothing else in the app would ever raise: a room's spares at
                // least show up on that room's page.
                if (buildingSpares.isNotEmpty) ...[
                  _GroupHeading(
                    label: 'For the building',
                    count: buildingSpares.length,
                  ),
                  for (final shelf in buildingSpares)
                    _BuildingSpareRow(
                      shelf: shelf,
                      estimate: estimate,
                      roomNames: roomNames,
                      currency: currency,
                      provider: provider,
                    ),
                ],
                for (final room in byRoom) ...[
                  _GroupHeading(label: room.name, count: room.parts),
                  ..._roomSpareRows(
                    context,
                    provider: provider,
                    estimate: estimate,
                    roomId: room.roomId,
                    currency: currency,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  ];
}

/// One room's spares: the job's own, then whatever that room asked for itself.
List<Widget> _roomSpareRows(
  BuildContext context, {
  required AppStateProvider provider,
  required ProjectEstimate estimate,
  required String roomId,
  required String currency,
}) {
  final mine = provider.project.sparesFor(roomId);
  final byPartKey = {for (final l in estimate.master) l.key: l};

  // What the job put here, by part, so the room's OWN figure can be worked out
  // as the remainder rather than counted twice.
  final fromProject = <String, double>{};
  for (final spare in mine) {
    fromProject[spare.partKey] = (fromProject[spare.partKey] ?? 0) + spare.qty;
  }

  return [
    for (final spare in mine)
      _ProjectSpareRow(
        spare: spare,
        line: byPartKey[spare.partKey],
        estimate: estimate,
        currency: currency,
        provider: provider,
      ),
    // THE ROOM'S OWN, as a fact rather than as a control. It lives in that
    // room's cost file and travels with the room; editing it from the job
    // would mean writing somebody else's room file behind their back.
    for (final line in estimate.master)
      if (((line.spareByRoom[roomId] ?? 0) - (fromProject[line.key] ?? 0)) >
          0.0001)
        _RoomOwnSpareRow(
          line: line,
          qty: (line.spareByRoom[roomId] ?? 0) - (fromProject[line.key] ?? 0),
          currency: currency,
        ),
  ];
}

class _SectionHeader extends StatelessWidget {
  final ProjectEstimate estimate;

  const _SectionHeader({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final units = estimate.spareUnits;
    final parts = estimate.sparedParts.length;
    final forBuilding = estimate.buildingSpareUnits;

    return Row(
      children: [
        Icon(
          Icons.inventory_outlined,
          size: 18,
          color: theme.colorScheme.tertiary,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Spares', style: theme.textTheme.titleSmall),
        ),
        if (units > 0)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              [
                '${trimNumber(units)} ${units == 1 ? 'unit' : 'units'}',
                'across $parts ${parts == 1 ? 'part' : 'parts'}',
                formatMoney(estimate.sparesTotal, estimate.currency),
                if (forBuilding > 0)
                  '${trimNumber(forBuilding)} for the building',
              ].join('  ·  '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        FilledButton.tonalIcon(
          key: const ValueKey('project_add_spare'),
          onPressed: () => showAddSpareDialog(context, estimate),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add spare'),
        ),
      ],
    );
  }
}

class _GroupHeading extends StatelessWidget {
  final String label;
  final int count;

  const _GroupHeading({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Text(
        '${label.toUpperCase()}  ($count)',
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A spare on the shelf for the building, with what it covers.
class _BuildingSpareRow extends StatelessWidget {
  final BuildingSpareLine shelf;
  final ProjectEstimate estimate;
  final Map<String, String> roomNames;
  final String currency;
  final AppStateProvider provider;

  const _BuildingSpareRow({
    required this.shelf,
    required this.estimate,
    required this.roomNames,
    required this.currency,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // Every project spare of this part that is on the building. Usually one;
    // two when somebody added a pair at different times for different reasons,
    // and each keeps its own note.
    final entries = [
      for (final s in provider.project.buildingSpares)
        if (s.partKey == shelf.line.key) s,
    ];

    // WHAT IT IS A SPARE FOR. A shelf unit is unreadable without this: "2
    // spare projectors" is a row to go and research, and the rooms that have
    // projectors in them is a row to approve or cut.
    final covers = [
      for (final id in shelf.roomIds.take(6))
        '${roomNames[id] ?? id} ×'
            '${trimNumber(shelf.line.qtyByRoom[id] ?? 0)}',
    ].join(', ');
    final more = shelf.roomIds.length - 6;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shelf.line.description,
                      style: theme.textTheme.bodyMedium,
                    ),
                    _CoverageLine(shelf: shelf),
                    if (shelf.roomIds.isNotEmpty)
                      Text(
                        'Spare for $covers${more > 0 ? ', and $more more' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                formatMoney(shelf.cost, currency),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          for (final spare in entries)
            _SpareControls(
              spare: spare,
              estimate: estimate,
              provider: provider,
            ),
        ],
      ),
    );
  }
}

/// The percentage a building spare covers, and the units it is measured
/// against.
class _CoverageLine extends StatelessWidget {
  final BuildingSpareLine shelf;

  const _CoverageLine({required this.shelf});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverage = shelf.coverage;

    if (coverage == null) {
      return Text(
        '${trimNumber(shelf.qty)} on the shelf. No room on this job is having '
        'this part, so there is nothing to cover.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    // Rounded to whole points below ten per cent and to one place above, so a
    // thin coverage reads as the small number it is rather than as "0%".
    final percent = coverage * 100;
    final text = percent >= 10
        ? percent.toStringAsFixed(0)
        : percent.toStringAsFixed(1);

    return Text(
      '${trimNumber(shelf.qty)} on the shelf for '
      '${trimNumber(shelf.installed)} installed  ·  $text% coverage',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.tertiary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// A spare the JOB is buying for one room.
class _ProjectSpareRow extends StatelessWidget {
  final ProjectSpare spare;

  /// The master line it is counted onto, or null when nothing on the job has
  /// this part any more.
  final MasterPartLine? line;

  final ProjectEstimate estimate;
  final String currency;
  final AppStateProvider provider;

  const _ProjectSpareRow({
    required this.spare,
    required this.line,
    required this.estimate,
    required this.currency,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = line?.unitPrice ?? 0;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spare.description,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                unit > 0
                    ? formatMoney(unit * spare.qty, currency)
                    : 'not priced',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: unit > 0
                      ? null
                      : errorTextOn(theme.colorScheme, theme.cardColor),
                ),
              ),
            ],
          ),
          _SpareControls(
            spare: spare,
            estimate: estimate,
            provider: provider,
          ),
        ],
      ),
    );
  }
}

/// The quantity, the scope and the way off the job, on one line.
class _SpareControls extends StatelessWidget {
  final ProjectSpare spare;
  final ProjectEstimate estimate;
  final AppStateProvider provider;

  const _SpareControls({
    required this.spare,
    required this.estimate,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: LiveTextField(
              fieldId: 'spare_qty_${spare.id}',
              initial: trimNumber(spare.qty),
              label: 'Spares',
              numeric: true,
              onChanged: (v) {
                final qty = double.tryParse(v.trim());
                if (qty != null) provider.setProjectSpareQty(spare.id, qty);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LiveTextField(
              fieldId: 'spare_note_${spare.id}',
              initial: spare.note,
              label: 'Why',
              hint: 'for the store',
              onChanged: (v) => provider.setProjectSpareNote(spare.id, v),
            ),
          ),
          const SizedBox(width: 8),
          // ONE MENU FOR THE SCOPE, listing the building and every room. A
          // spare moves between them without being deleted and retyped, which
          // is the whole reason its room is a field rather than a fact about
          // where it is stored.
          _ScopeButton(
            spare: spare,
            estimate: estimate,
            provider: provider,
          ),
          IconButton(
            key: ValueKey('spare_remove_${spare.id}'),
            tooltip: 'Take this spare off the job',
            icon: const Icon(Icons.close, size: 18),
            color: theme.colorScheme.onSurfaceVariant,
            onPressed: () => provider.removeProjectSpare(spare.id),
          ),
        ],
      ),
    );
  }
}

class _ScopeButton extends StatelessWidget {
  final ProjectSpare spare;
  final ProjectEstimate estimate;
  final AppStateProvider provider;

  const _ScopeButton({
    required this.spare,
    required this.estimate,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: ValueKey('spare_scope_${spare.id}'),
    tooltip: 'Who this is a spare for',
    initialValue: spare.roomId,
    onSelected: (value) => provider.moveProjectSpare(spare.id, value),
    itemBuilder: (context) => [
      const PopupMenuItem(
        key: ValueKey('spare_scope_building'),
        value: '',
        child: Text('The building'),
      ),
      const PopupMenuDivider(),
      for (final room in estimate.rooms)
        PopupMenuItem(
          value: room.ref.id,
          child: Text(room.name),
        ),
    ],
    child: Chip(
      avatar: Icon(
        spare.forBuilding ? Icons.apartment : Icons.meeting_room_outlined,
        size: 16,
      ),
      label: Text(
        spare.forBuilding
            ? 'The building'
            : estimate.rooms
                  .where((r) => r.ref.id == spare.roomId)
                  .map((r) => r.name)
                  .firstOrNull ??
                spare.roomId,
      ),
    ),
  );
}

/// A spare the ROOM asked for, on its own Cost page.
///
/// Shown, and not editable here. It lives in that room's file and travels with
/// the room to whatever job it ends up on; changing it from the project would
/// be writing somebody else's room behind their back, and moving it here would
/// leave the room's own page disagreeing with this one.
class _RoomOwnSpareRow extends StatelessWidget {
  final MasterPartLine line;
  final double qty;
  final String currency;

  const _RoomOwnSpareRow({
    required this.line,
    required this.qty,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.description, style: theme.textTheme.bodyMedium),
                Text(
                  '${trimNumber(qty)} asked for on this room\'s own Cost page',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          Text(
            formatMoney(qty * line.unitPrice, currency),
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// Adds a spare: which part, how many, and who it is for.
///
/// THE PART IS PICKED FROM THE JOB, not typed. A spare typed by hand would
/// merge onto no line, price at nothing, and read as a different product from
/// the one it is a spare for the moment anybody swapped the model.
Future<void> showAddSpareDialog(
  BuildContext context,
  ProjectEstimate estimate,
) async {
  final provider = context.read<AppStateProvider>();
  final parts = [
    for (final l in estimate.master)
      if (l.kind == MasterPartKind.equipment) l,
  ]..sort(
    (a, b) => a.description.toLowerCase().compareTo(b.description.toLowerCase()),
  );

  if (parts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'There is nothing to spare yet. Add rooms with equipment on them '
          'first.',
        ),
      ),
    );
    return;
  }

  String partKey = parts.first.key;
  String roomId = '';
  final qty = TextEditingController(text: '1');
  final note = TextEditingController();

  final added = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        key: const ValueKey('add_spare_dialog'),
        title: const Text('Add a spare'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('add_spare_part'),
                initialValue: partKey,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Spare of',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final l in parts)
                    DropdownMenuItem(
                      value: l.key,
                      child: Text(
                        l.description,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setLocal(() => partKey = v ?? partKey),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('add_spare_scope'),
                initialValue: roomId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'A spare for',
                  helperText:
                      'The building keeps it on a shelf for every room. A '
                      'room keeps it against that room.',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('The building'),
                  ),
                  for (final room in estimate.rooms)
                    DropdownMenuItem(
                      value: room.ref.id,
                      child: Text(room.name),
                    ),
                ],
                onChanged: (v) => setLocal(() => roomId = v ?? ''),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      key: const ValueKey('add_spare_qty'),
                      controller: qty,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'How many',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('add_spare_note'),
                      controller: note,
                      decoration: const InputDecoration(
                        labelText: 'Why',
                        hintText: 'for the store',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('add_spare_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );

  // Read BEFORE they are disposed, which is the whole reason these two lines
  // are not the last thing in the function.
  final typedQty = double.tryParse(qty.text.trim()) ?? 1;
  final typedNote = note.text;
  qty.dispose();
  note.dispose();
  if (added != true) return;

  final line = parts.firstWhere((l) => l.key == partKey);
  provider.addProjectSpare(
    partKey: line.key,
    // The part as it reads TODAY. Stored on the spare so the row still says
    // what it is after every room has been swapped off this model.
    description: line.description,
    model: line.model,
    manufacturer: line.manufacturer,
    partNumber: line.partNumber,
    qty: typedQty,
    roomId: roomId,
    note: typedNote,
  );
}
