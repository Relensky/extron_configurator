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
import 'pinned_grid.dart';
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
///  THE GRID IS THE POINT, so it scrolls BOTH WAYS on its own rather than
///  forcing the whole tab to, and the room names and the year headings stay
///  pinned while it moves. A building with a twenty-year span is a wide
///  document and a building with forty rooms is a tall one; either way the
///  thing a cell is about has to still be on screen next to the cell.
/// ============================================================================

/// The building's replacement plan, as slivers for the project tab's one
/// scroll view.
List<Widget> lifecycleSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.watch<AppStateProvider>();
  final building = buildProjectLifecycle(
    estimate: estimate,
    library: provider.avDeviceLibrary,
    baseCosts: provider.baseCosts,
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
    // ROOM BY ROOM, WITH THE MONEY BROKEN OUT BY THE YEAR IT LANDS. The grid
    // above is the picture; this is the list a budget request is written from.
    SliverList.separated(
      itemCount: building.rooms.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _RoomRow(
        room: building.rooms[i],
        currency: building.currency,
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
                style: theme.textTheme.bodyMedium?.copyWith(
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
        Icon(
          equipmentConditionIcon(condition),
          size: gridMetric(context, 22),
          color: color,
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              kEquipmentConditionLabels[condition]!.toUpperCase(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '$rooms room${rooms == 1 ? '' : 's'} · '
              '${formatEquipmentBand(items, cost, currency)}',
              key: ValueKey('lifecycle_band_${condition.name}'),
              style: theme.textTheme.titleMedium?.copyWith(color: color),
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
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color)),
      ],
    );
  }
}

/// One line of the grid: a room, or one of that room's due dates.
///
/// A ROOM IS RARELY ONE DATE. The projector went in in 2016 and the displays
/// in 2019, and a sheet with one row per room can only ever show the first of
/// the two - which leaves the rest of the room's money invisible until the
/// year it lands. So a room with more than one due date is drawn as its
/// summary row PLUS one line per date, each a leading line from the year that
/// equipment went in to the year it falls due.
typedef _GridLine = ({RoomLifecycle room, RoomDueGroup? group});

/// The RYG grid itself: rooms down, years across.
///
/// IT SCROLLS IN ITS OWN FRAME, both ways, with the room names and the year
/// headings pinned — see [PinnedGrid]. Before this it was laid out at full
/// size inside the tab's one scroll view, which meant a building with forty
/// rooms pushed the room list under it clean off the bottom of the window, and
/// reading across a twenty-year span took the room names off the left edge
/// with it. A cell that says '2031' against a room you can no longer see is a
/// cell that says nothing.
///
/// EVERY CELL SAYS WHAT IS IN IT ON HOVER. The colour says when, the figure
/// says how much, and neither says WHICH BOXES - which is the first question
/// anybody asks of a cell with 24,000 dollars in it. The tooltip names them.
class _YearGrid extends StatelessWidget {
  final BuildingLifecycle building;

  const _YearGrid({required this.building});

  /// The rooms, opened out into one line per due date where there is more than
  /// one. A room whose whole contents fall due together is one line: a second
  /// row saying the same thing as the first is a row to read past.
  static List<_GridLine> linesOf(BuildingLifecycle building) => [
    for (final room in building.rooms) ...[
      (room: room, group: null),
      if (room.dueGroups.length > 1)
        for (final g in room.dueGroups) (room: room, group: g),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final years = building.years();
    final thisYear = building.asOf.year;
    if (years.isEmpty || building.rooms.isEmpty) return const SizedBox.shrink();

    final lines = linesOf(building);

    // EVERY BOX ON THE SHEET IS THE READER'S SIZE. These were fixed pixels,
    // which on a machine at 150% gave the same 62-wide cell with a larger
    // figure clipped inside it. See [gridMetric].
    final yearColumn = gridMetric(context, 72);
    final rowHeight = gridMetric(context, 28);
    final roomColumn = gridMetric(context, 168);
    final headHeight = gridMetric(context, 26);
    final gap = gridMetric(context, 8);

    final headStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(16, gap * 0.5, 16, gap * 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REPLACEMENT YEAR',
            style: headStyle?.copyWith(fontWeight: FontWeight.bold),
          ),
          SizedBox(height: gap * 0.5),
          // Six shades across a row are only readable against a key. The same
          // one the room's own tab carries, so a reader who learned it there
          // does not have to learn it again here.
          const EquipmentTimingKey(),
          SizedBox(height: gap * 0.5),
          Text(
            'A room with more than one replacement date opens into a line per '
            'date - the run from when that equipment went in to when it falls '
            'due. Hover any cell for what is in it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: gap * 0.75),
          PinnedGrid(
            frozenWidth: roomColumn,
            headerHeight: headHeight,
            bodyWidth: yearColumn * years.length,
            bodyHeight: rowHeight * lines.length,
            corner: Align(
              alignment: Alignment.bottomLeft,
              child: Text('ROOM', style: headStyle),
            ),
            header: Row(
              children: [
                for (final y in years)
                  SizedBox(
                    width: yearColumn,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Text(
                        '$y',
                        style: headStyle?.copyWith(
                          fontWeight: y == thisYear
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: y == thisYear
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            frozen: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in lines)
                  SizedBox(
                    height: rowHeight,
                    child: Padding(
                      padding: EdgeInsets.only(
                        // A date line is indented under the room it belongs
                        // to, so the eye reads the block as one room rather
                        // than as four.
                        left: line.group == null ? 0 : gap * 1.5,
                        right: gap,
                        bottom: 2,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: line.group == null
                            ? Text(
                                line.room.roomName,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              )
                            : Text(
                                '${line.group!.items.length} item'
                                '${line.group!.items.length == 1 ? '' : 's'} '
                                'due ${line.group!.dueYear}',
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in lines)
                  line.group == null
                      ? _GridRow(
                          room: line.room,
                          years: years,
                          currency: building.currency,
                          columnWidth: yearColumn,
                          rowHeight: rowHeight,
                        )
                      : _TimelineRow(
                          room: line.room,
                          group: line.group!,
                          years: years,
                          currency: building.currency,
                          columnWidth: yearColumn,
                          rowHeight: rowHeight,
                        ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// WHAT IS IN A CELL, IN WORDS.
///
/// The colour says when and the figure says how much; neither says which
/// boxes, and "which boxes" is the first thing anybody asks of a cell with
/// 24,000 dollars in it. Naming them is also what makes the sheet checkable —
/// a total nobody can break down is a total nobody argues with, which is worse
/// than one that is wrong.
///
/// Capped at [_kTooltipItems] lines. A rack refresh is thirty positions and a
/// tooltip that tall is a panel covering the sheet it describes.
String equipmentDueTooltip({
  required String roomName,
  required int year,
  required List<EquipmentLife> due,
  required String currency,
  String? fallback,
}) {
  if (due.isEmpty) return fallback ?? '$roomName in $year';

  final total = due.fold<double>(0, (sum, i) => sum + i.replacementCost);
  final shown = due.take(_kTooltipItems);
  return [
    '$roomName - due $year',
    for (final i in shown)
      '• ${i.node.label}'
          '${i.node.model.trim().isEmpty ? '' : ' (${i.node.model.trim()})'}'
          ' - ${i.replacementCost > 0
              ? '${formatLifecycleMoney(i.replacementCost, currency)}'
                    '${i.costIsEstimate ? ' est.' : ''}'
              : 'not priced'}',
    if (due.length > _kTooltipItems)
      '• …and ${due.length - _kTooltipItems} more',
    '${due.length} item${due.length == 1 ? '' : 's'}  ·  '
        '${total > 0 ? formatLifecycleMoney(total, currency) : 'not priced'}',
  ].join('\n');
}

/// How many positions a cell's tooltip names before it starts counting them.
const int _kTooltipItems = 8;

/// One room's years, as cells. The room's NAME is not here: it is in the
/// frozen half, laid out on the same [rowHeight] so the two line up.
class _GridRow extends StatelessWidget {
  final RoomLifecycle room;
  final List<int> years;
  final String currency;
  final double columnWidth;
  final double rowHeight;

  const _GridRow({
    required this.room,
    required this.years,
    required this.currency,
    required this.columnWidth,
    required this.rowHeight,
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
    return SizedBox(
      height: rowHeight,
      child: Row(
        children: [
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
                  message: equipmentDueTooltip(
                    roomName: room.roomName,
                    year: year,
                    due: room.dueIn(year),
                    currency: currency,
                    fallback: '${room.roomName} in $year: '
                        '${kEquipmentTimingLabels[timing]!}',
                  ),
                  child: Container(
                    key: ValueKey('lifecycle_cell_${room.roomName}_$year'),
                    width: columnWidth - 2,
                    height: rowHeight - 2,
                    margin: const EdgeInsets.only(right: 2, bottom: 2),
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
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: color,
                      ),
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

/// ONE OF A ROOM'S DUE DATES, AS A RUN ACROSS THE SHEET.
///
/// A leading line from the year that equipment went in to the year it falls
/// due, warming from green to red along its length and carrying the money at
/// the end of it. The point is the SPAN: a room row says "2027" and this says
/// "these three went in in 2019 and land in 2027", which is the sentence a
/// phased refresh is actually planned in.
class _TimelineRow extends StatelessWidget {
  final RoomLifecycle room;
  final RoomDueGroup group;
  final List<int> years;
  final String currency;
  final double columnWidth;
  final double rowHeight;

  const _TimelineRow({
    required this.room,
    required this.group,
    required this.years,
    required this.currency,
    required this.columnWidth,
    required this.rowHeight,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = equipmentDueTooltip(
      roomName: room.roomName,
      year: group.dueYear,
      due: group.items,
      currency: currency,
    );

    return SizedBox(
      height: rowHeight,
      child: Row(
        children: [
          for (final year in years)
            Builder(
              builder: (context) {
                final inSpan =
                    year >= group.startYear && year <= group.dueYear;
                // Banded on the tranche's OWN life, so this line warms up
                // against its own due date rather than against the room's
                // first one.
                final timing = timingFor(
                  yearsRemaining: (group.dueYear - year).toDouble(),
                  lifeYears: group.lifeYears,
                );
                final isDue = year == group.dueYear;
                final isStart = year == group.startYear;

                // A year outside the run is blank space that keeps the
                // column in step - no key, and nothing to hover: a tooltip on
                // empty sheet is a tooltip that goes off under the pointer on
                // the way somewhere else.
                if (!inSpan) {
                  return SizedBox(width: columnWidth, height: rowHeight);
                }

                return Tooltip(
                  message: message,
                  child: SizedBox(
                    key: ValueKey(
                      'lifecycle_span_${room.roomName}_'
                      '${group.dueYear}_$year',
                    ),
                    width: columnWidth,
                    height: rowHeight,
                    child: isDue
                        ? Container(
                            margin: const EdgeInsets.only(
                              right: 2,
                              top: 3,
                              bottom: 5,
                            ),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: equipmentTimingFill(context, timing),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              group.cost > 0
                                  ? formatLifecycleMoney(group.cost, currency)
                                  : 'due',
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: equipmentTimingColor(context, timing),
                              ),
                            ),
                          )
                        : _SpanSegment(
                            color: equipmentTimingFill(
                              context,
                              timing,
                              alpha: 0.9,
                            ),
                            leading: isStart,
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

/// One year of a leading line: the rule itself, with a stop on the year the
/// equipment went in so the run has a visible beginning.
class _SpanSegment extends StatelessWidget {
  final Color color;
  final bool leading;

  const _SpanSegment({required this.color, required this.leading});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 2),
    child: Row(
      children: [
        if (leading)
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        Expanded(child: Container(height: 2, color: color)),
      ],
    ),
  );
}

/// One room, under the grid: what it reads as, WHAT TO BUDGET AND WHEN, and
/// the money behind it.
///
/// THE GRID IS THE PICTURE AND THIS IS THE ANSWER. A cell painted amber in the
/// 2027 column says a year; it does not say "put twenty-four thousand in the
/// 2027 request for this room", which is the sentence the whole screen exists
/// to produce. So every room carries its replacement dates as a line of
/// figures - one per date, in the year it lands - and a reader who wants the
/// boxes behind one of them hovers it.
class _RoomRow extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;

  const _RoomRow({required this.room, required this.currency});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timing = room.timing;
    final color = equipmentTimingColor(context, timing);
    final gap = gridMetric(context, 8);
    final groups = room.dueGroups;

    final facts = [
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
    ].join('  ·  ');

    return Padding(
      padding: EdgeInsets.fromLTRB(16, gap, 16, gap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: kEquipmentTimingLabels[timing]!,
            child: Icon(
              equipmentTimingIcon(timing),
              size: gridMetric(context, 24),
              color: color,
            ),
          ),
          SizedBox(width: gap * 1.5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room.roomName,
                  key: ValueKey('lifecycle_room_${room.roomName}'),
                  style: theme.textTheme.titleMedium,
                ),
                Text(facts, style: theme.textTheme.bodyMedium),
                if (groups.isNotEmpty) ...[
                  SizedBox(height: gap * 0.75),
                  Text(
                    'BUDGET FOR THIS ROOM',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: gap * 0.4),
                  Wrap(
                    spacing: gap,
                    runSpacing: gap * 0.6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final g in groups)
                        _DueYearChip(
                          room: room,
                          group: g,
                          currency: currency,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: gap),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (room.overdueCost > 0)
                Text(
                  '${formatLifecycleMoney(room.overdueCost, currency)} overdue',
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              if (room.refreshCost > 0)
                Text(
                  '${formatLifecycleMoney(room.refreshCost, currency)} '
                  'to refresh',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One of a room's replacement dates, as a figure to put in that year.
///
/// THE YEAR AND THE MONEY, TOGETHER, IN THE COLOUR OF HOW SOON. A budget
/// request is written a year at a time, and a room that reads "18,000 to
/// refresh" answers a question nobody asked - the money does not all land at
/// once. This is the same tranche the grid draws as a run, said as a figure.
///
/// A figure that came off the base card rather than off a real catalog price
/// is marked. A typical price presented as a quote is how a budget goes wrong
/// quietly - the same bargain the room's own tab makes.
class _DueYearChip extends StatelessWidget {
  final RoomLifecycle room;
  final RoomDueGroup group;
  final String currency;

  const _DueYearChip({
    required this.room,
    required this.group,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Banded on the tranche's own life, as of the room's own asOf day - the
    // same reading the grid's run of cells ends on.
    final timing = timingFor(
      yearsRemaining: (group.dueYear - room.asOf.year).toDouble(),
      lifeYears: group.lifeYears,
    );
    final ink = equipmentTimingColor(context, timing);
    final estimated = group.items.any((i) => i.costIsEstimate);

    return Tooltip(
      message: equipmentDueTooltip(
        roomName: room.roomName,
        year: group.dueYear,
        due: group.items,
        currency: currency,
      ),
      child: Container(
        key: ValueKey('lifecycle_due_${room.roomName}_${group.dueYear}'),
        padding: EdgeInsets.symmetric(
          horizontal: gridMetric(context, 10),
          vertical: gridMetric(context, 5),
        ),
        decoration: BoxDecoration(
          color: equipmentTimingFill(context, timing, alpha: 0.18),
          border: Border.all(
            color: equipmentTimingFill(context, timing, alpha: 0.8),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${group.dueYear}',
              style: theme.textTheme.titleSmall?.copyWith(color: ink),
            ),
            SizedBox(width: gridMetric(context, 8)),
            Text(
              group.cost > 0
                  ? '${estimated ? '~' : ''}'
                        '${formatLifecycleMoney(group.cost, currency)}'
                  : 'not priced',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                fontStyle: estimated ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            SizedBox(width: gridMetric(context, 8)),
            Text(
              '${group.items.length} item'
              '${group.items.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
