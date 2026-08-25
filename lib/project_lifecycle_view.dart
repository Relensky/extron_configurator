import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'equipment_lifecycle.dart';
import 'lifecycle_view.dart'
    show
        EquipmentTimingKey,
        equipmentConditionColor,
        equipmentConditionIcon,
        equipmentTimingColor,
        equipmentTimingFill,
        equipmentTimingIcon;
import 'project_estimate.dart';

/// ============================================================================
///  THE BUILDING'S REPLACEMENT PLAN
/// ============================================================================
///  The room's own Lifecycle tab answers "how old is this room". This answers
///  the question that gets asked in a budget meeting: WHICH ROOMS, WHAT YEAR,
///  HOW MUCH — across the whole building at once.
///
///  It is the Master RYG spreadsheet, derived. A row per room, a column per
///  year, and a cell that counts up through the room's life and then carries
///  the replacement figure in the year it falls due. Everything on it comes off
///  the install dates recorded on the equipment, so it cannot drift from the
///  rooms it describes the way a hand-maintained sheet does.
///
///  THE GRID IS THE POINT, so it scrolls sideways on its own rather than
///  forcing the whole tab to. A building with a twenty-year span is a wide
///  document, and the room names have to stay readable while it is read across.
/// ============================================================================

/// The building's replacement plan, as slivers for the project tab's one
/// scroll view.
List<Widget> lifecycleSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.watch<AppStateProvider>();
  final building = buildProjectLifecycle(
    estimate: estimate,
    library: provider.avDeviceLibrary,
    tier: provider.pricingTier,
  );

  if (building.items.isEmpty) {
    return const [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nothing to age yet.\n\n'
              'The replacement plan is built from the equipment in each room '
              'and the date it went in. Open a room, go to its Lifecycle tab, '
              'and record the dates - they roll up here.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ];
  }

  return [
    SliverToBoxAdapter(child: _Summary(building: building)),
    SliverToBoxAdapter(child: _YearGrid(building: building)),
    const SliverToBoxAdapter(child: Divider(height: 1)),
    SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => _RoomRow(
          room: building.rooms[i],
          currency: building.currency,
        ),
        childCount: building.rooms.length,
      ),
    ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

/// What the building reads as, in one strip.
class _Summary extends StatelessWidget {
  final BuildingLifecycle building;

  const _Summary({required this.building});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final undated = building.countOf(EquipmentCondition.unknown);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final c in kEquipmentConditionSeverity)
                if (building.roomsOf(c) > 0 || building.countOf(c) > 0)
                  _Band(
                    condition: c,
                    rooms: building.roomsOf(c),
                    items: building.countOf(c),
                    cost: building.costOf(c),
                    currency: building.currency,
                  ),
              // The whole ask, in one figure: everything past its life plus
              // everything inside the planning window, counted and priced. It
              // is the number a refresh request is written for, and it was
              // previously only arrived at by adding two bands by eye.
              if (building.toReplaceCount > 0)
                _Figure(
                  label: 'To replace',
                  value: formatEquipmentBand(
                    building.toReplaceCount,
                    building.toReplaceCost,
                    building.currency,
                  ),
                  color: equipmentConditionColor(
                    context,
                    building.countOf(EquipmentCondition.overdue) > 0
                        ? EquipmentCondition.overdue
                        : EquipmentCondition.ageing,
                  ),
                ),
              if (building.overdueCost > 0)
                _Figure(
                  label: 'Past its life today',
                  value: formatLifecycleMoney(
                    building.overdueCost,
                    building.currency,
                  ),
                  color: equipmentConditionColor(
                    context,
                    EquipmentCondition.overdue,
                  ),
                ),
            ],
          ),
          // The survey's own to-do list. Said out loud rather than left to be
          // inferred from a column of blanks, because a plan built on a
          // building that is half surveyed is a plan that reads far better
          // than the building actually is.
          if (undated > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '$undated item${undated == 1 ? '' : 's'} across the job have '
                'no install date, so nothing can be said about when they fall '
                'due. Record them on each room\'s Lifecycle tab.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Band extends StatelessWidget {
  final EquipmentCondition condition;
  final int rooms;
  final int items;

  /// What the items in this band cost to replace. A count on its own is not
  /// something a budget meeting can act on — see [RoomLifecycle.costOf].
  final double cost;
  final String currency;

  const _Band({
    required this.condition,
    required this.rooms,
    required this.items,
    required this.cost,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = equipmentConditionColor(context, condition);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(equipmentConditionIcon(condition), size: 20, color: color),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              kEquipmentConditionLabels[condition]!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '$rooms room${rooms == 1 ? '' : 's'} · '
              '${formatEquipmentBand(items, cost, currency)}',
              key: ValueKey('lifecycle_band_${condition.name}'),
              style: theme.textTheme.titleSmall?.copyWith(color: color),
            ),
          ],
        ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Figure({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.titleSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// The RYG grid itself: rooms down, years across.
class _YearGrid extends StatelessWidget {
  final BuildingLifecycle building;

  const _YearGrid({required this.building});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final years = building.years();
    final thisYear = building.asOf.year;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REPLACEMENT YEAR',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          // Six shades across a row are only readable against a key. The same
          // one the room's own tab carries, so a reader who learned it there
          // does not have to learn it again here.
          const EquipmentTimingKey(),
          const SizedBox(height: 6),
          // Its own horizontal scroller. The tab scrolls vertically as one
          // document; a grid twenty years wide has to move sideways without
          // dragging the header and the room list with it.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(width: _kRoomColumn),
                    for (final y in years)
                      SizedBox(
                        width: _kYearColumn,
                        child: Text(
                          '$y',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: y == thisYear
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                for (final room in building.rooms)
                  _GridRow(
                    room: room,
                    years: years,
                    currency: building.currency,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const double _kRoomColumn = 150;
const double _kYearColumn = 62;

class _GridRow extends StatelessWidget {
  final RoomLifecycle room;
  final List<int> years;
  final String currency;

  const _GridRow({
    required this.room,
    required this.years,
    required this.currency,
  });

  String _label(int year) {
    final money = room.costDueIn(year);
    if (money > 0) return formatLifecycleMoney(money, currency);
    if (room.dueIn(year).isNotEmpty) return 'due';
    final installed = room.oldestInstall?.year;
    final due = room.firstDueYear;
    if (installed == null || year < installed) return '';
    if (due != null && year > due) return '';
    return '${year - installed + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: _kRoomColumn,
            child: Text(
              room.roomName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final year in years)
            Builder(
              builder: (context) {
                // THE ROW WARMS UP ACROSS THE SHEET. Green while the room is
                // young, yellow the year it enters the planning window, amber,
                // orange, then red the year it falls due — which is the thing
                // the hand-coloured sheet did with six pencils and the thing a
                // single amber band could not say.
                final timing = room.timingIn(year);
                final text = _label(year);
                final color = equipmentTimingColor(context, timing);
                return Tooltip(
                  message: '${room.roomName} in $year: '
                      '${kEquipmentTimingLabels[timing]!}',
                  child: Container(
                    key: ValueKey('lifecycle_cell_${room.roomName}_$year'),
                    width: _kYearColumn - 2,
                    height: 22,
                    margin: const EdgeInsets.only(right: 2),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      // Filled only where there is something to say. An empty
                      // cell is a year outside the room's life, and painting
                      // it would put colour on the sheet that means nothing.
                      color: text.isEmpty
                          ? null
                          : equipmentTimingFill(context, timing),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      text,
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One room, under the grid: what it reads as and the money behind it.
class _RoomRow extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;

  const _RoomRow({required this.room, required this.currency});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timing = room.timing;
    final color = equipmentTimingColor(context, timing);
    return ListTile(
      key: ValueKey('lifecycle_room_${room.roomName}'),
      dense: true,
      leading: Tooltip(
        message: kEquipmentTimingLabels[timing]!,
        child: Icon(equipmentTimingIcon(timing), color: color),
      ),
      title: Text(room.roomName, style: theme.textTheme.titleSmall),
      subtitle: Text(
        [
          '${room.items.length} item${room.items.length == 1 ? '' : 's'}',
          room.oldestInstall == null
              ? 'never surveyed'
              : 'last done ${room.oldestInstall!.year}',
          room.firstDueYear == null
              ? 'no due date'
              : 'first due ${room.firstDueYear}',
          // How much of the room is on the list and what it costs — the two
          // halves of the answer, on the row the question is asked about.
          if (room.toReplaceCount > 0)
            'to replace: '
                '${formatEquipmentBand(
              room.toReplaceCount,
              room.toReplaceCost,
              currency,
            )}',
          if (room.undated > 0) '${room.undated} without a date',
        ].join('  ·  '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (room.overdueCost > 0)
            Text(
              '${formatLifecycleMoney(room.overdueCost, currency)} overdue',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          if (room.refreshCost > 0)
            Text(
              '${formatLifecycleMoney(room.refreshCost, currency)} to refresh',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
