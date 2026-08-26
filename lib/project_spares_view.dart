import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
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

/// The colour the spares panels actually paint, rather than the one they ask
/// for.
///
/// Both of them fill with `surfaceContainerHighest` at HALF ALPHA, so what a
/// reader's eye is measuring against is that colour blended over the page
/// behind it — and every foreground on these panels has to be checked against
/// the blend rather than against either ingredient. Checking against
/// `theme.cardColor`, which is what the rest of the app's cards use, would be
/// measuring text on a card these panels are not.
Color spareSectionFill(ThemeData theme) => Color.alphaBlend(
      theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      theme.scaffoldBackgroundColor,
    );

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
                      'Nothing on this job has a spare yet. Add one here for '
                      'the building or for a room, or ask for one on a room\'s '
                      'own Cost page.',
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

    final fill = spareSectionFill(theme);

    return Row(
      children: [
        Icon(
          Icons.inventory_outlined,
          size: 18,
          // 3:1 rather than 7:1 — the bar a graphic has to clear, not the one
          // small text does.
          color: accentTextOn(
            theme.colorScheme,
            fill,
            minRatio: kContrastLarge,
          ),
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
                color: accentTextOn(theme.colorScheme, fill),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        // ONE OF EVERYTHING, IN ONE PRESS.
        //
        // Beside the button that adds one spare, because it is the same
        // decision taken across the whole job at once - and it is the decision
        // the rule this page is built on actually asks for. Doing it a row at
        // a time is how a job ends up spared down to the first forty parts
        // somebody had the patience for.
        //
        // Offered only while there is something to do. A button that adds
        // nothing is a button somebody presses twice to find out why.
        if (estimate.unsparedParts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              key: const ValueKey('project_spare_one_each'),
              onPressed: () => _addOneOfEach(context, estimate),
              icon: const Icon(Icons.playlist_add_check, size: 18),
              label: Text(
                'One each for the '
                '${estimate.unsparedParts.length} with none',
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

/// Puts one of every unspared part on the building's shelf.
///
/// IT ASKS FIRST, and shows what it is about to buy. This is the only control
/// on the page that writes two hundred lines at once, and the figure it comes
/// to is money somebody has to justify - so it is named and priced before it
/// happens rather than explained afterwards.
Future<void> _addOneOfEach(
  BuildContext context,
  ProjectEstimate estimate,
) async {
  final provider = context.read<AppStateProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final lines = [for (final c in estimate.unsparedParts) c.line];
  if (lines.isEmpty) return;

  final cost = lines.fold<double>(0, (sum, l) => sum + l.unitPrice);
  final unpriced = lines.where((l) => l.unitPrice <= 0).length;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('spare_one_each_confirm'),
      title: Text(
        'One spare of ${lines.length} part${lines.length == 1 ? '' : 's'}?',
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Every part this job installs and holds none of gets one, on '
              'the shelf for the building. Parts that already have a spare '
              'are left alone.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            Text(
              cost > 0
                  ? 'About ${formatMoney(cost, estimate.currency)} at the '
                      'prices on this job'
                  : 'Nothing on this list is priced yet',
              style: Theme.of(ctx).textTheme.titleSmall,
            ),
            if (unpriced > 0 && cost > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$unpriced of them ${unpriced == 1 ? 'has' : 'have'} no '
                  'price, so the real figure is higher.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            // Every one of them is an ordinary spare afterwards, editable and
            // removable a row at a time - this is a short cut, not a mode.
            Text(
              'Each one lands as an ordinary shelf spare, so any of them can '
              'be changed or taken off afterwards.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
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
          key: const ValueKey('spare_one_each_go'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('Add ${lines.length}'),
        ),
      ],
    ),
  );
  if (go != true) return;

  final added = provider.addOneSpareOfEach(lines);
  showTimedSnackBar(
    messenger,
    SnackBar(
      content: Text(
        'One spare each added for $added '
        'part${added == 1 ? '' : 's'}, on the shelf for the building.',
      ),
    ),
  );
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
        color: accentTextOn(theme.colorScheme, spareSectionFill(theme)),
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
                      // Measured against what this panel paints, not against
                      // the card colour it is not using — see
                      // [spareSectionFill].
                      : errorTextOn(
                          theme.colorScheme,
                          spareSectionFill(theme),
                        ),
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
//  Every part the job installs, as a PERCENTAGE of it held on the shelf, and
//  which of them have nothing held at all.
//
//  ONE SPARE OR NONE is the rule, and it is the rule because it is the only
//  one that needs no policy typed before the table will say anything. This
//  used to measure every part against a percentage the job had to be told -
//  which asked for four spare wall plates on a job with forty and said nothing
//  about the one switcher the whole building runs through.
//
//  The percentage is still what every row SAYS. "Two spare projectors" is a
//  row nobody can approve or cut; "2 of 40, 5%" is a decision.
//
//  AND IT IS NOW ALSO WHAT THE ROW RECOMMENDS. A percentage of what goes in is
//  the only thing that can turn "this has a spare" into "this has enough", and
//  that is the question somebody opens this page with. So every row carries
//  what the job's target comes to against its own installed count, and how
//  many more would meet it - see [BuildingProject.spareCoverTarget].
//
//  THE TARGET IS THE JOB'S, AND IT IS SET HERE. A lecture block with twelve
//  identical rooms and a shelf of spares is not the same job as one theatre
//  with one of everything in it, so the figure is typed on the page it is read
//  on rather than compiled into the app. It opens at the suggestion, and a job
//  nobody tells keeps that.
//
//  IT IS A NOTE, NOT A FLAG. Nothing is drawn in the error ink for being under
//  the target; only a part with NO SPARE AT ALL is. That is the whole reason
//  the percentage could come back: it advises without turning forty wall
//  plates into forty faults, which is what the old typed-in target did.

/// The percentage table, and the way to fix a row with nothing spared.
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
                  'HOW MUCH OF THIS JOB HAS A SPARE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          // WHAT THE JOB IS AIMING AT, on the page the aim is read on.
          const _CoverTargetField(),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: _CoverSummary(
              estimate: estimate,
              parts: cover.length,
              short: short.length,
            ),
          ),
          // WHAT WOULD BE ENOUGH, under what is missing. The line above says
          // whether the job meets its own rule; this says what a percentage of
          // the job would ask for on top of it, and how many units that is
          // across the whole order - which is the figure somebody is actually
          // deciding about when they widen the spares budget.
          _RecommendedNote(estimate: estimate, parts: cover.length),
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

    final fill = spareSectionFill(theme);
    if (short == 0) {
      return Text(
        'All $parts ${parts == 1 ? 'part' : 'parts'} have at least one spare. '
        'The share each one covers is on its row.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: accentTextOn(theme.colorScheme, fill),
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Text(
      '$short of $parts ${parts == 1 ? 'part' : 'parts'} '
      '${short == 1 ? 'has' : 'have'} no spare on the order.',
      style: theme.textTheme.bodySmall?.copyWith(
        color: errorTextOn(theme.colorScheme, fill),
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// The job's spare target, typed as a percentage.
///
/// ON THIS PAGE RATHER THAN IN A SETTINGS SCREEN. It is a decision about this
/// building, it is made while looking at what the building actually holds, and
/// a number that has to be hunted for on another screen is a number that stays
/// at whatever it was.
///
/// NOUGHT IS OFFERED, NOT HIDDEN. The recommendation never asks for less than
/// one of anything, so a target of nought means exactly "one of everything the
/// job installs" - which is a policy plenty of jobs actually run, and the
/// answer for anybody who wants the Add buttons on the rows below to offer one
/// each rather than a share of the count.
class _CoverTargetField extends StatelessWidget {
  const _CoverTargetField();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final target = provider.project.spareCoverTarget;
    final percent = target * 100;

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 108,
            child: LiveTextField(
              key: const ValueKey('spare_cover_target'),
              fieldId: 'spare_cover_target',
              initial: trimNumber(percent),
              label: 'Aim for',
              suffix: '%',
              numeric: true,
              // A BLANK BOX IS SOMEBODY MID-TYPE, not a target of nought. It
              // is left alone until there is a number in it again - clearing
              // the box to type '25' must not re-price the job at nought and
              // then at two and then at twenty-five.
              onChanged: (v) {
                final typed = double.tryParse(v.trim());
                if (typed == null) return;
                provider.setSpareCoverTarget(typed / 100);
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              percent <= 0
                  ? 'One of everything the job installs, and no more. '
                      '${formatSpareCover(kSuggestedSpareCover)} is the '
                      'suggestion if you want a share of the count instead.'
                  : 'of what goes in, rounded up, never less than one. '
                      '${formatSpareCover(kSuggestedSpareCover)} suggested; '
                      '0 asks for one of everything.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // Back to the suggestion in one press. A figure somebody has pushed
          // to 40% to see what it looked like needs a way home that is not
          // "remember what it used to say".
          if ((target - kSuggestedSpareCover).abs() > 1e-9)
            TextButton(
              key: const ValueKey('spare_cover_target_suggested'),
              onPressed: () =>
                  provider.setSpareCoverTarget(kSuggestedSpareCover),
              child: Text(
                'Use ${formatSpareCover(kSuggestedSpareCover)}',
              ),
            ),
        ],
      ),
    );
  }
}

/// What a percentage of the job would have it hold, and how far off it is.
///
/// SEPARATE FROM [_CoverSummary] AND IN A QUIETER INK, deliberately. The line
/// above it is the job's own rule and is drawn as a pass or a fault; this one
/// is advice, and advice that borrows the fault's red is advice that gets
/// argued with instead of read.
class _RecommendedNote extends StatelessWidget {
  final ProjectEstimate estimate;
  final int parts;

  const _RecommendedNote({required this.estimate, required this.parts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final under = estimate.partsUnderRecommendedCover.length;
    final units = estimate.unitsToRecommendedCover;
    // At nought the aim is not a percentage at all, and a sentence about
    // '0% of what goes in' is a sentence nobody can act on.
    final aim = estimate.spareCoverTarget <= 0
        ? 'one of everything the job installs'
        : '${formatSpareCover(estimate.spareCoverTarget)} of what goes in, '
            'rounded up and never less than one';

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Text(
        under == 0
            ? 'This job aims for $aim. All $parts '
                '${parts == 1 ? 'part is' : 'parts are'} at or above it.'
            : 'This job aims for $aim. $under of $parts '
                '${parts == 1 ? 'part is' : 'parts are'} under it - '
                '${trimNumber(units)} more ${units == 1 ? 'unit' : 'units'} '
                'across the job would meet it. An aim, not a rule: only a part '
                'with no spare at all is flagged.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
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
    final fill = spareSectionFill(theme);
    final flag = cover.short
        ? errorTextOn(theme.colorScheme, fill)
        : accentTextOn(theme.colorScheme, fill);

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
                  '${cover.short ? '  ·  no spare' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: flag,
                    fontWeight: cover.short ? FontWeight.w600 : null,
                  ),
                ),
                // WHAT WOULD BE ENOUGH, on the row it is about. In the quiet
                // ink whatever the row above it is drawn in: a part with one
                // spare of forty is not a fault, and this is the sentence that
                // tells somebody it is still worth another three.
                if (cover.toRecommend > 0)
                  Text(
                    'Aiming for ${trimNumber(cover.recommended)}'
                    '${estimate.spareCoverTarget <= 0 ? '' : ' at '
                        '${formatSpareCover(estimate.spareCoverTarget)}'}'
                    '  ·  ${trimNumber(cover.toRecommend)} more to reach it',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // THE FIX, ON THE ROW THAT IS WRONG. A table that says a part has
          // nothing spared and then sends somebody to a control somewhere else
          // to add one is a table that gets read and then ignored. A row with
          // nothing on the shelf offers the first one; every other row can
          // still be topped up.
          //
          // THE NUMBER ON THE BUTTON IS WHAT THE JOB IS AIMING AT, not what
          // the rule demands. Both are one press, so the one worth offering is
          // the one that leaves the part actually covered - and with the aim
          // set to nought it IS one each, which is what the field above it is
          // for. The dialog it opens is still a dialog, with the figure in a
          // box somebody can change before confirming.
          if (cover.short)
            FilledButton.tonal(
              key: ValueKey('spare_cover_add_${line.key}'),
              onPressed: () => showAddSpareDialog(
                context,
                estimate,
                partKey: line.key,
                qty: cover.toRecommend,
              ),
              child: Text('Add ${trimNumber(cover.toRecommend)}'),
            )
          else if (cover.toRecommend > 0)
            OutlinedButton(
              key: ValueKey('spare_cover_add_${line.key}'),
              onPressed: () => showAddSpareDialog(
                context,
                estimate,
                partKey: line.key,
                qty: cover.toRecommend,
              ),
              child: Text('Add ${trimNumber(cover.toRecommend)}'),
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

  /// The part the dialog is currently pointed at.
  MasterPartLine get _line =>
      widget.parts.firstWhere((l) => l.key == _partKey, orElse: () => widget.parts.first);

  /// The amounts the menu offers: one, the job's own aim for this part, and a
  /// few round figures above it.
  ///
  /// Trimmed to what makes sense for the part - there is no point offering ten
  /// spares of a switcher the job installs two of - and always including one,
  /// which is the answer on most rows.
  List<double> _qtyChoices() {
    final installed = _line.drawnQty;
    final aim = recommendedSpares(installed, widget.estimate.spareCoverTarget);
    final out = <double>{
      1,
      if (aim > 0) aim,
      for (final n in const [2.0, 3.0, 5.0, 10.0])
        if (installed <= 0 || n <= installed) n,
    }.toList()
      ..sort();
    return out;
  }

  /// One amount on the menu, with the cover it would leave.
  String _qtyChoiceLabel(double n) {
    final installed = _line.drawnQty;
    if (installed <= 0) {
      return '${trimNumber(n)}  ·  no room installs this';
    }
    // The shelf AFTER this is added, which is what the reader is choosing
    // between - not the share this one addition happens to be.
    final held = _line.spareQty + n;
    return '${trimNumber(n)}  ·  ${formatSpareCover(held / installed)} of '
        '${trimNumber(installed)} installed';
  }

  /// The sentence under the row: what the shelf ends up holding.
  String _coverLine() {
    final installed = _line.drawnQty;
    final typed = double.tryParse(_qty.text.trim()) ?? 0;
    if (installed <= 0) {
      return 'No room on this job installs this part, so there is no share to '
          'measure it against.';
    }
    if (typed <= 0) {
      return 'Type how many, or pick one of the usual amounts.';
    }
    final held = _line.spareQty + typed;
    final aim = recommendedSpares(installed, widget.estimate.spareCoverTarget);
    return '${trimNumber(held)} spare of ${trimNumber(installed)} installed  '
        '·  ${formatSpareCover(held / installed)}'
        '${held + 1e-9 >= aim ? '  ·  meets what this job aims for' : '  ·  '
            'this job aims for ${trimNumber(aim)}'}';
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
            // The cover line and the menu are both about the chosen part, so
            // both follow it.
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
                width: 168,
                child: TextField(
                  key: const ValueKey('add_spare_qty'),
                  controller: _qty,
                  keyboardType: TextInputType.number,
                  // The percentage moves as the figure does, so it has to be
                  // rebuilt on every keystroke rather than only when the
                  // dropdown is used.
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'How many',
                    border: const OutlineInputBorder(),
                    // THE AMOUNTS WORTH PICKING, EACH SAYING WHAT IT COVERS.
                    //
                    // "How many spares" is not a number anybody knows; it is a
                    // SHARE somebody is trying to hit, and until now this box
                    // asked for the number and said nothing about the share.
                    // Every choice on the menu carries the cover it would
                    // leave - one of forty included, which is the one worth
                    // spelling out, because 'a spare' sounds like enough right
                    // up until it is read as two and a half per cent.
                    //
                    // Typed as well as picked: the menu is the usual answers,
                    // not the only ones. Same bargain the party fields on the
                    // responsibility matrix make.
                    suffixIcon: PopupMenuButton<double>(
                      key: const ValueKey('add_spare_qty_menu'),
                      tooltip: 'The usual amounts, and what each covers',
                      icon: const Icon(Icons.arrow_drop_down),
                      itemBuilder: (_) => [
                        for (final n in _qtyChoices())
                          PopupMenuItem(
                            value: n,
                            child: Text(_qtyChoiceLabel(n)),
                          ),
                      ],
                      onSelected: (n) =>
                          setState(() => _qty.text = trimNumber(n)),
                    ),
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
          // WHAT THE SHELF WILL ACTUALLY HOLD once this is added, as a share.
          // Said for one as loudly as for ten: a single spare is the amount
          // people add without thinking about it, and it is the amount whose
          // cover most often turns out not to be what they assumed.
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _coverLine(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
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
