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
                // HOW WELL THE JOB IS SPARED, before what it has spared. The
                // shelf list below answers "what did we ask for"; this answers
                // "is it enough", which is the question the shelf list cannot
                // be read for and the only one a target can settle.
                _SpareCoverCard(estimate: estimate),
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
              hint: 'to cover a repair',
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

// ---------------------------------------------------------------------------
//  HOW MUCH OF THE JOB IS SPARED
// ---------------------------------------------------------------------------
//  Every part the job installs, as a PERCENTAGE of it held on the shelf, and -
//  once the job has said what it wants held - which of them fall short.
//
//  The percentage is the whole point. "Two spare projectors" is a row nobody
//  can approve or cut; "2 of 40, 5%" is a decision, and "5% against a 10%
//  policy, two short" is an instruction. The target is what turns a list of
//  two hundred parts into the six that need doing something about.

/// The percentage table, its target, and the way to fix a row that is short.
class _SpareCoverCard extends StatefulWidget {
  final ProjectEstimate estimate;

  const _SpareCoverCard({required this.estimate});

  @override
  State<_SpareCoverCard> createState() => _SpareCoverCardState();
}

class _SpareCoverCardState extends State<_SpareCoverCard> {
  /// Whether every installed part is listed, or only the ones worth acting on.
  ///
  /// Off by default and deliberately: on a real job this table is two hundred
  /// rows, and two hundred rows above the shelf list would bury the shelf
  /// list. What shows without asking is what somebody would DO something
  /// about - the short ones when there is a target, the thinnest covered when
  /// there is not.
  bool _showAll = false;

  /// How many rows show before the table is opened up.
  static const int _preview = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final estimate = widget.estimate;
    final cover = estimate.spareCover;

    // Nothing installed is not "nothing spared" - it is a job with no rooms on
    // it yet, and a percentage table of no parts says nothing.
    if (cover.isEmpty) return const SizedBox.shrink();

    final short = [for (final c in cover) if (c.short) c];
    final shown = _showAll
        ? cover
        : short.isNotEmpty
            ? short
            : cover.take(_preview).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.percent,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'HOW MUCH OF THIS JOB IS SPARED',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // THE POLICY, ON THE TABLE IT GOVERNS. A target set three
              // screens away would be a rule nobody could check against the
              // rows it is flagging.
              SizedBox(
                width: 128,
                child: LiveTextField(
                  fieldId: 'project_spare_target',
                  initial: estimate.hasSpareTarget
                      ? trimNumber(estimate.spareTargetPercent)
                      : '',
                  label: 'Target',
                  hint: 'none',
                  suffix: '%',
                  numeric: true,
                  onChanged: (v) {
                    final text = v.trim();
                    // An empty box is "no policy" rather than nought per cent,
                    // which here is the same thing: both stop the flagging
                    // instead of flagging everything.
                    context.read<AppStateProvider>().setProjectSpareTarget(
                      text.isEmpty ? 0 : (double.tryParse(text) ?? 0),
                    );
                  },
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: _CoverSummary(
              estimate: estimate,
              parts: cover.length,
              short: short.length,
            ),
          ),
          for (final c in shown) _CoverRow(cover: c, estimate: estimate),
          if (cover.length > shown.length || _showAll)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('spare_cover_show_all'),
                onPressed: () => setState(() => _showAll = !_showAll),
                child: Text(
                  _showAll
                      ? 'Show only what needs doing'
                      : 'Show every part (${cover.length})',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One line saying whether the job meets its own rule.
class _CoverSummary extends StatelessWidget {
  final ProjectEstimate estimate;
  final int parts;
  final int short;

  const _CoverSummary({
    required this.estimate,
    required this.parts,
    required this.short,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!estimate.hasSpareTarget) {
      return Text(
        'Every part below is what the job installs and what it holds spare of '
        'it. Set a target and anything held below that share is flagged.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final target = trimNumber(estimate.spareTargetPercent);
    if (short == 0) {
      return Text(
        'All $parts ${parts == 1 ? 'part' : 'parts'} meet the $target% target.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.tertiary,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Text(
      '$short of $parts ${parts == 1 ? 'part' : 'parts'} '
      '${short == 1 ? 'is' : 'are'} below the $target% target.',
      style: theme.textTheme.bodySmall?.copyWith(
        color: errorTextOn(theme.colorScheme, theme.cardColor),
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// One part's cover, and - when it is short - the way to fix it.
class _CoverRow extends StatelessWidget {
  final SparePartCover cover;
  final ProjectEstimate estimate;

  const _CoverRow({required this.cover, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = cover.line;
    final flag = cover.short
        ? errorTextOn(theme.colorScheme, theme.cardColor)
        : theme.colorScheme.tertiary;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.description,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${trimNumber(cover.spares)} spare of '
                  '${trimNumber(cover.installed)} installed  ·  '
                  '${formatSpareCover(cover.coverage)}'
                  '${cover.short ? '  ·  '
                      '${trimNumber(cover.shortfall)} short' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: flag,
                    fontWeight: cover.short ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // THE FIX, ON THE ROW THAT IS WRONG. A table that says a part is two
          // short and then sends somebody to a control somewhere else to add
          // them is a table that gets read and then ignored. A short row
          // offers the shortfall itself; every other row can still be topped
          // up by one.
          if (cover.short)
            FilledButton.tonal(
              key: ValueKey('spare_cover_add_${line.key}'),
              onPressed: () => showAddSpareDialog(
                context,
                estimate,
                partKey: line.key,
                qty: cover.shortfall,
              ),
              child: Text('Add ${trimNumber(cover.shortfall)}'),
            )
          else
            IconButton(
              key: ValueKey('spare_cover_add_${line.key}'),
              tooltip: 'Add a spare of this part',
              icon: const Icon(Icons.add, size: 18),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () => showAddSpareDialog(
                context,
                estimate,
                partKey: line.key,
              ),
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
///
/// [partKey] and [qty] prefill it, for the places that already know the
/// answer - a part flagged as short opens with itself picked and the shortfall
/// typed in, so the fix is one press rather than a part hunted out of a list
/// of two hundred.
Future<void> showAddSpareDialog(
  BuildContext context,
  ProjectEstimate estimate, {
  String partKey = '',
  double qty = 1,
}) async {
  final provider = context.read<AppStateProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final parts = [
    for (final l in estimate.master)
      if (l.kind == MasterPartKind.equipment) l,
  ]..sort(
    (a, b) => a.description.toLowerCase().compareTo(b.description.toLowerCase()),
  );

  if (parts.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'There is nothing to spare yet. Add rooms with equipment on them '
          'first.',
        ),
      ),
    );
    return;
  }

  final answer = await showDialog<_NewSpare>(
    context: context,
    builder: (_) => _AddSpareDialog(
      parts: parts,
      estimate: estimate,
      // A key that no longer resolves - a part flagged short on a list built
      // before somebody swapped the model - falls back to the first rather
      // than throwing. The dialog is a way in, not an assertion.
      initialPartKey: parts.any((l) => l.key == partKey) ? partKey : '',
      initialQty: qty,
    ),
  );
  if (answer == null) return;

  final line = parts.firstWhere((l) => l.key == answer.partKey);
  provider.addProjectSpare(
    partKey: line.key,
    // The part as it reads TODAY. Stored on the spare so the row still says
    // what it is after every room has been swapped off this model.
    description: line.description,
    model: line.model,
    manufacturer: line.manufacturer,
    partNumber: line.partNumber,
    qty: answer.qty,
    roomId: answer.roomId,
    note: answer.note,
  );
}

/// What the add dialog came back with.
typedef _NewSpare = ({
  String partKey,
  String roomId,
  double qty,
  String note,
});

/// The dialog owns its own text controllers.
///
/// Stateful for exactly that reason: a controller made by the caller has to be
/// disposed by the caller, and the only moment the caller can do it is while
/// the dialog is still animating away with the fields still on screen - which
/// throws. Owned here, they go when the dialog's State does.
class _AddSpareDialog extends StatefulWidget {
  final List<MasterPartLine> parts;
  final ProjectEstimate estimate;

  /// The part to open with, or '' to open on the first in the list.
  final String initialPartKey;

  /// How many to open with. The shortfall, when this was opened off a part
  /// flagged as below the job's target.
  final double initialQty;

  const _AddSpareDialog({
    required this.parts,
    required this.estimate,
    this.initialPartKey = '',
    this.initialQty = 1,
  });

  @override
  State<_AddSpareDialog> createState() => _AddSpareDialogState();
}

class _AddSpareDialogState extends State<_AddSpareDialog> {
  late String _partKey = widget.initialPartKey.isNotEmpty
      ? widget.initialPartKey
      : widget.parts.first.key;

  /// '' is the building, and is the default: a spare added from the JOB is
  /// more often the shelf unit for the campus than a fourth display for one
  /// room, which is a decision that gets made on that room's own page.
  String _roomId = '';

  late final TextEditingController _qty = TextEditingController(
    text: trimNumber(widget.initialQty <= 0 ? 1 : widget.initialQty),
  );
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
            initialValue: _partKey,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Spare of',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final l in widget.parts)
                DropdownMenuItem(
                  value: l.key,
                  child: Text(
                    l.description,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _partKey = v ?? _partKey),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('add_spare_scope'),
            initialValue: _roomId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'A spare for',
              helperText:
                  'The building keeps it on a shelf for every room. A room '
                  'keeps it against that room.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('The building'),
              ),
              for (final room in widget.estimate.rooms)
                DropdownMenuItem(
                  value: room.ref.id,
                  child: Text(room.name),
                ),
            ],
            onChanged: (v) => setState(() => _roomId = v ?? ''),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  key: const ValueKey('add_spare_qty'),
                  controller: _qty,
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
                  controller: _note,
                  decoration: const InputDecoration(
                    labelText: 'Why',
                    hintText: 'to cover a repair',
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
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('add_spare_confirm'),
        onPressed: () => Navigator.of(context).pop((
          partKey: _partKey,
          roomId: _roomId,
          qty: double.tryParse(_qty.text.trim()) ?? 1,
          note: _note.text,
        )),
        child: const Text('Add'),
      ),
    ],
  );
}
