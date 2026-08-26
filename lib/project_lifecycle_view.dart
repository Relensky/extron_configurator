import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart' show formatEquipmentDate;
import 'campus_lifecycle_view.dart' show showCampusLifecycle;
import 'equipment_lifecycle.dart';
import 'lifecycle_export.dart';
import 'lifecycle_picture.dart';
import 'lifecycle_view.dart'
    show
        EquipmentTimingKey,
        LifecycleEverythingChunk,
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
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Nothing to age yet.\n\n'
                  'The replacement plan is built from the equipment in each '
                  'room and the date it went in. Open a room, go to its '
                  'Lifecycle tab, and record the dates - they roll up here.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                // OFFERED HERE TOO. A job with nothing dated on it is exactly
                // the job somebody opens in order to look at the OTHER
                // buildings - and a door that only appears once this one has
                // been surveyed is a door nobody finds.
                const _CampusButton(),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  return [
    SliverToBoxAdapter(
      child: _Summary(
        building: building,
        title: lifecycleDocumentTitle(estimate),
        fileStem: lifecycleFileStem(estimate),
      ),
    ),
    SliverToBoxAdapter(child: LifecycleYearGrid(building: building)),
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

/// What the documents this pane writes are headed with: the job, the building,
/// or failing both something that is at least not blank.
String lifecycleDocumentTitle(ProjectEstimate estimate) {
  final name = estimate.project.name.trim();
  final building = estimate.project.building.trim();
  if (name.isNotEmpty && building.isNotEmpty && name != building) {
    return '$name - $building - replacement plan';
  }
  final one = name.isNotEmpty ? name : building;
  return one.isEmpty ? 'Replacement plan' : '$one - replacement plan';
}

/// What they are CALLED on disk. The same rule the workbook uses, so a folder
/// holding both reads as one job rather than two.
String lifecycleFileStem(ProjectEstimate estimate) {
  final raw = estimate.project.name.trim().isNotEmpty
      ? estimate.project.name
      : estimate.project.building.trim().isNotEmpty
      ? estimate.project.building
      : 'project';
  final clean = raw
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
  return '${clean}_replacement_plan';
}

/// What the building reads as, in one strip.
class _Summary extends StatelessWidget {
  final BuildingLifecycle building;

  /// What the picture and the spreadsheet are headed with, and called.
  final String title;
  final String fileStem;

  const _Summary({
    required this.building,
    required this.title,
    required this.fileStem,
  });

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
              // THE TWO FIGURES A BUDGET MEETING ASKS FOR, SIDE BY SIDE.
              //
              // "What does this building need" has two honest answers and they
              // are a long way apart. One is what it needs NOW - everything
              // past its life plus everything inside the planning window - and
              // that is the number the refresh request is written for. The
              // other is what it would cost to replace the lot, which is what
              // sizes a ten-year budget and what "we cannot do it all at once"
              // is actually about.
              //
              // The sheet used to carry only the first, so the second was
              // arrived at by adding a column of room rows by hand - and the
              // two were being quoted at each other across the table.
              if (building.toReplaceCount > 0)
                _Figure(
                  label: 'Recommended now',
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
              // AND THEN A GAP, AND THE WHOLE-BUILDING FIGURE BEHIND A RULE.
              //
              // It used to be the last chip on this strip, in the quiet ink,
              // and quiet ink was not separation enough: it is the biggest
              // number on the screen and the least urgent one, and read along
              // a row with two asks it was being quoted back as a third ask.
              // Behind a gap and a rule, with its items and its money as two
              // figures rather than one run-on line, it reads as what it is -
              // see [LifecycleEverythingChunk].
              if (building.items.isNotEmpty)
                LifecycleEverythingChunk(
                  items: building.items.length,
                  cost: building.refreshCost,
                  currency: building.currency,
                  scope: 'this building',
                  undated: undated,
                ),
            ],
          ),
          // THE WAY OUT TO THE REST OF THE ESTATE.
          //
          // Under the building's own figures rather than up in the toolbar,
          // because it is the same question one step wider: everything above
          // this line is "what does this building need and when", and the next
          // thing anybody asks having read it is whether the year it lands in
          // is a year the campus can afford. The answer needs the other jobs
          // on the same calendar, and this is where somebody is standing when
          // they want it.
          // THE WAYS OUT OF THE SCREEN, ON ONE LINE.
          //
          // A picture of the plan, the plan as a spreadsheet, and the same
          // question one building wider. All three are "I have read this, now
          // what do I do with it", which is why they sit under the figures
          // rather than up in the tab's toolbar with Workbook and Quote
          // requests - those write the JOB, these write this sheet.
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PlanExportButtons(
                  building: building,
                  title: title,
                  fileStem: fileStem,
                ),
                const _CampusButton(),
              ],
            ),
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

/// Opens the campus overview: this job and any others, on one calendar.
class _CampusButton extends StatelessWidget {
  const _CampusButton();

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const ValueKey('lifecycle_campus'),
    onPressed: () => showCampusLifecycle(context),
    icon: const Icon(Icons.location_city, size: 18),
    label: const Text('Compare across the campus…'),
  );
}

/// The two documents this pane hands over: a picture of the plan, and the plan
/// as a spreadsheet with a chart of the money against the years.
///
/// BOTH ARE DEALT FROM THE [BuildingLifecycle] ON SCREEN, not re-derived. A
/// spreadsheet that priced the building a second time would be a document that
/// could disagree with the sheet it was exported from, which is exactly the
/// drift the whole feature exists to remove.
class _PlanExportButtons extends StatefulWidget {
  final BuildingLifecycle building;
  final String title;
  final String fileStem;

  const _PlanExportButtons({
    required this.building,
    required this.title,
    required this.fileStem,
  });

  @override
  State<_PlanExportButtons> createState() => _PlanExportButtonsState();
}

class _PlanExportButtonsState extends State<_PlanExportButtons> {
  bool _busy = false;

  Widget get _sheet =>
      LifecyclePlanSheet(building: widget.building, title: widget.title);

  void _picture() => showLifecycleSheetPicture(
    context,
    dialogTitle: 'The replacement plan as a picture',
    fileStem: widget.fileStem,
    what: 'The replacement plan',
    sheet: _sheet,
  );

  Future<void> _spreadsheet() async {
    setState(() => _busy = true);
    Uint8List? picture;
    try {
      // The sheet as it reads, dropped in under the tables. Rendered off the
      // side of the screen rather than grabbed off this one: the grid on this
      // page is a window onto eight rooms and six years, and a workbook
      // illustrated with that is a workbook illustrated with a fragment.
      picture = await captureOffscreenSheet(context, _sheet);
    } finally {
      // In a finally: a button left spinning is worse than a book with no
      // picture in it, and the book is written either way.
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await saveLifecycleWorkbook(
      context,
      fileStem: widget.fileStem,
      what: 'The replacement plan',
      bytes: buildBuildingLifecycleXlsx(
        building: widget.building,
        title: widget.title,
        picture: picture,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      OutlinedButton.icon(
        key: const ValueKey('lifecycle_picture'),
        onPressed: _busy ? null : _picture,
        icon: const Icon(Icons.image_outlined, size: 18),
        label: const Text('Picture…'),
      ),
      FilledButton.tonalIcon(
        key: const ValueKey('lifecycle_spreadsheet'),
        onPressed: _busy ? null : _spreadsheet,
        icon: const Icon(Icons.table_view, size: 18),
        label: Text(_busy ? 'Drawing…' : 'Spreadsheet…'),
      ),
    ],
  );
}

/// THE WHOLE PLAN AT ITS FULL SIZE, for a picture of it.
///
/// [LifecycleYearGrid] is the version for READING: it scrolls in its own
/// frame, builds its rows a screenful at a time, and pins the room names and
/// the year headings so a cell always has the thing it is about beside it.
/// None of that survives being photographed - a capture of a scrolling frame
/// is a capture of the frame.
///
/// So this is the same sheet laid out flat: nothing scrolls, nothing is lazy,
/// nothing is pinned because nothing moves. It carries its own heading and
/// figures too, because a picture ends up in a document with no app around it
/// and a grid of coloured cells with no title on it explains nothing.
///
/// The CELLS are the same widgets the screen draws - see [_GridRow] and
/// [_TimelineRow] - so the picture cannot come out saying something different
/// from the sheet it is a picture of.
class LifecyclePlanSheet extends StatelessWidget {
  final BuildingLifecycle building;
  final String title;

  const LifecyclePlanSheet({
    super.key,
    required this.building,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final years = building.years(maxColumns: 20);
    final lines = LifecycleYearGrid.linesOf(building);
    final currency = building.currency;
    final thisYear = building.asOf.year;
    final undated = building.countOf(EquipmentCondition.unknown);

    final yearColumn = gridMetric(context, 76);
    final rowHeight = gridMetric(context, 28);
    final roomColumn = gridMetric(context, 200);

    final headStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              'As of ${formatEquipmentDate(building.asOf)}  ·  '
              '${building.rooms.length} room'
              '${building.rooms.length == 1 ? '' : 's'}  ·  '
              '${building.items.length} item'
              '${building.items.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            // The figures, in words. A picture that carries the grid and none
            // of the totals is a picture somebody has to be told the totals
            // for, which defeats handing it over at all.
            Wrap(
              spacing: 28,
              runSpacing: 6,
              children: [
                if (building.toReplaceCount > 0)
                  _SheetFigure(
                    label: 'Recommended now',
                    value: formatEquipmentBand(
                      building.toReplaceCount,
                      building.toReplaceCost,
                      currency,
                    ),
                    color: equipmentConditionColor(
                      context,
                      building.countOf(EquipmentCondition.overdue) > 0
                          ? EquipmentCondition.overdue
                          : EquipmentCondition.ageing,
                    ),
                  ),
                if (building.overdueCost > 0)
                  _SheetFigure(
                    label: 'Past its life today',
                    value: formatLifecycleMoney(building.overdueCost, currency),
                    color: equipmentConditionColor(
                      context,
                      EquipmentCondition.overdue,
                    ),
                  ),
                _SheetFigure(
                  label: 'Everything, whatever its age',
                  value: formatEquipmentBand(
                    building.items.length,
                    building.refreshCost,
                    currency,
                  ),
                ),
              ],
            ),
            if (undated > 0) ...[
              const SizedBox(height: 6),
              Text(
                '$undated item${undated == 1 ? '' : 's'} carry no install '
                'date, so they fall due in no year on this sheet and are in '
                'none of the figures above.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            const EquipmentTimingKey(),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(width: roomColumn, child: Text('ROOM', style: headStyle)),
                for (final y in years)
                  SizedBox(
                    width: yearColumn,
                    child: Center(
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
            const SizedBox(height: 4),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 2),
            for (final line in lines)
              Row(
                children: [
                  SizedBox(
                    width: roomColumn,
                    height: rowHeight,
                    child: Padding(
                      padding: EdgeInsets.only(
                        // Indented under the room it belongs to, exactly as on
                        // screen, so the block reads as one room and not four.
                        left: line.group == null ? 0 : 12,
                        right: 8,
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
                  if (line.group == null)
                    _GridRow(
                      room: line.room,
                      years: years,
                      currency: currency,
                      columnWidth: yearColumn,
                      rowHeight: rowHeight,
                    )
                  else
                    _TimelineRow(
                      room: line.room,
                      group: line.group!,
                      years: years,
                      currency: currency,
                      columnWidth: yearColumn,
                      rowHeight: rowHeight,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// One figure in a sheet's heading block. The screen's [_Figure] with no
/// interaction behind it.
class _SheetFigure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SheetFigure({required this.label, required this.value, this.color});

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
        Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color)),
      ],
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
typedef LifecycleGridLine = ({RoomLifecycle room, RoomDueGroup? group});

/// The RYG grid itself: rooms down, years across.
///
/// PUBLIC, BECAUSE A ROOM ASKS THE SAME QUESTION AS A BUILDING. The room's own
/// Lifecycle tab used to answer "how old is this room" as a list of positions
/// and no calendar at all - so the year a room falls due, the tranches it
/// falls due in and what each of them costs were only ever visible from the
/// project. They are the same facts about the same room either way, and the
/// room is where somebody is standing when they ask. It takes a
/// [BuildingLifecycle] of one room there; everything below works the same on
/// one row as on forty.
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
class LifecycleYearGrid extends StatelessWidget {
  final BuildingLifecycle building;

  /// Whether to draw the colour key above the sheet.
  ///
  /// ONE KEY PER PAGE. Six shades across a row can only be read against a key,
  /// so the grid carries its own wherever it is the first thing on the page -
  /// which it is on the Project tab. On the room's own Lifecycle tab it is
  /// not: the summary strip above it already ends in the same key, under the
  /// same six colours, and printing it twice on one page says that the two are
  /// different keys for two different things.
  final bool showKey;

  const LifecycleYearGrid({
    super.key,
    required this.building,
    this.showKey = true,
  });

  /// The rooms, opened out into one line per due date where there is more than
  /// one. A room whose whole contents fall due together is one line: a second
  /// row saying the same thing as the first is a row to read past.
  static List<LifecycleGridLine> linesOf(BuildingLifecycle building) => [
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
          // does not have to learn it again here - and on that tab it is the
          // one already on screen, so this one stands down.
          if (showKey) ...[
            const EquipmentTimingKey(),
            SizedBox(height: gap * 0.5),
          ],
          Text(
            'A room with more than one replacement date opens into a line per '
            'date - the run from when that equipment went in to when it falls '
            'due. Hover any cell for what is in it, and the end of a line for '
            'what refreshing the whole room comes to. Click a line to play it '
            'through, year by year.',
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
            // ROW AT A TIME. A building with several replacement dates per
            // room is two hundred rows of fourteen cells, and the frame shows
            // eight of them - see [PinnedGrid].
            rowCount: lines.length,
            rowExtent: rowHeight,
            frozenRowBuilder: (context, i) {
              final line = lines[i];
              return _PlayRow(
                room: line.room,
                currency: building.currency,
                child: Padding(
                  padding: EdgeInsets.only(
                    // A date line is indented under the room it belongs to, so
                    // the eye reads the block as one room rather than as four.
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
              );
            },
            bodyRowBuilder: (context, i) {
              final line = lines[i];
              return _PlayRow(
                room: line.room,
                currency: building.currency,
                child: line.group == null
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
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One line of the grid, as something that can be PLAYED.
///
/// A bare [GestureDetector] rather than an InkWell: this sits inside a grid
/// that scrolls both ways, and a ripple that fires every time somebody flicks
/// the sheet sideways is a sheet that flashes at them. The tap loses the arena
/// to a drag on its own, which is exactly the behaviour wanted - a scroll is
/// not a click.
class _PlayRow extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;
  final Widget child;

  const _PlayRow({
    required this.room,
    required this.currency,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showRefreshWalkthrough(context, room, currency),
      child: child,
    ),
  );
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

  /// Lines to add under the breakdown. WHAT THE END OF A RUN IS FOR: the cell
  /// a line finishes on is the one people hover, and until now all it said was
  /// what lands in that one year - which is never the figure being asked for.
  /// The room's whole refresh total goes here, and so does the fact that the
  /// row can be played through.
  List<String> footer = const [],
}) {
  if (due.isEmpty) {
    return [fallback ?? '$roomName in $year', ...footer].join('\n\n');
  }

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
    // A blank line before the footer: it is about the ROOM and everything
    // above it is about one year, and two paragraphs is how that reads.
    if (footer.isNotEmpty) '\n${footer.join('\n')}',
  ].join('\n');
}

/// How many positions a cell's tooltip names before it starts counting them.
const int _kTooltipItems = 8;

/// WHAT THE END OF A ROOM'S LINE SAYS BEYOND THE YEAR IT LANDS IN.
///
/// The cell a run finishes on is the one that gets hovered - it is the red one
/// with the money in it - and what it carried was the cost of that ONE date.
/// A room with three replacement dates therefore had no cell anywhere on the
/// sheet showing what refreshing it actually comes to, which is the figure the
/// whole screen is read for.
///
/// Only on the end cell. Putting the room total on every cell of the run would
/// be the same number under the pointer five times over, and by the third it
/// stops being read as a total at all.
List<String> lineEndFooter(RoomLifecycle room, String currency) => [
  if (room.dueGroups.length > 1)
    'Full refresh for ${room.roomName}: '
        '${room.refreshCost > 0 ? formatLifecycleMoney(room.refreshCost, currency) : 'not priced'}'
        '  ·  across ${room.dueGroups.length} dates'
  else
    'Full refresh for ${room.roomName}: '
        '${room.refreshCost > 0 ? formatLifecycleMoney(room.refreshCost, currency) : 'not priced'}',
  'Click the row to play the plan through.',
];

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
          for (final year in years) _cell(context, theme, year),
        ],
      ),
    );
  }

  /// One year of one room.
  ///
  /// A YEAR OUTSIDE THE ROOM'S LIFE IS BLANK SPACE, and blank space is built
  /// as blank space: no fill, no tooltip, no message string. Every cell used
  /// to carry all three whether it had anything to say or not, which on a
  /// sheet of a few thousand cells is a few thousand strings composed to
  /// describe nothing.
  Widget _cell(BuildContext context, ThemeData theme, int year) {
    final text = _label(year);
    if (text.isEmpty) {
      return SizedBox(width: columnWidth, height: rowHeight);
    }

    // THE ROW WARMS UP ACROSS THE SHEET. Green while the room is young, yellow
    // the year it enters the planning window, amber, orange, then red the year
    // it falls due — which is the thing the hand-coloured sheet did with six
    // pencils and the thing a single amber band could not say.
    final timing = room.timingIn(year);
    final due = room.dueIn(year);

    return Tooltip(
      message: equipmentDueTooltip(
        roomName: room.roomName,
        year: year,
        due: due,
        currency: currency,
        fallback: '${room.roomName} in $year: '
            '${kEquipmentTimingLabels[timing]!}',
        // The room's row runs from when it went in to when it first falls due,
        // so THAT year is the end of this line.
        footer: year == room.firstDueYear
            ? lineEndFooter(room, currency)
            : const [],
      ),
      child: Container(
        key: ValueKey('lifecycle_cell_${room.roomName}_$year'),
        width: columnWidth - 2,
        height: rowHeight - 2,
        margin: const EdgeInsets.only(right: 2, bottom: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: equipmentTimingFill(context, timing),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            color: equipmentTimingColor(context, timing),
          ),
          overflow: TextOverflow.ellipsis,
        ),
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
    // The last cell of a run says what the run costs AND what the room costs.
    // The two are different numbers on any room with more than one date, and
    // the second is the one a budget request is written for.
    final endMessage = equipmentDueTooltip(
      roomName: room.roomName,
      year: group.dueYear,
      due: group.items,
      currency: currency,
      footer: lineEndFooter(room, currency),
    );

    return SizedBox(
      height: rowHeight,
      child: Row(
        children: [
          for (final year in years)
            _cell(
              context,
              theme,
              year == group.dueYear ? endMessage : message,
              year,
            ),
        ],
      ),
    );
  }

  /// One year of the run.
  ///
  /// A year outside it is blank space that keeps the column in step - no
  /// tooltip and nothing to paint: a tooltip on empty sheet is one that opens
  /// under the pointer on its way somewhere else.
  Widget _cell(
    BuildContext context,
    ThemeData theme,
    String message,
    int year,
  ) {
    if (year < group.startYear || year > group.dueYear) {
      return SizedBox(width: columnWidth, height: rowHeight);
    }

    // Banded on the tranche's OWN life, so this line warms up against its own
    // due date rather than against the room's first one.
    final timing = timingFor(
      yearsRemaining: (group.dueYear - year).toDouble(),
      lifeYears: group.lifeYears,
    );

    return Tooltip(
      message: message,
      child: SizedBox(
        key: ValueKey(
          'lifecycle_span_${room.roomName}_${group.dueYear}_$year',
        ),
        width: columnWidth,
        height: rowHeight,
        child: year == group.dueYear
            ? Container(
                margin: const EdgeInsets.only(right: 2, top: 3, bottom: 5),
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
                color: equipmentTimingFill(context, timing, alpha: 0.9),
                leading: year == group.startYear,
              ),
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

// ---------------------------------------------------------------------------
//  PLAYING ONE ROOM'S PLAN THROUGH
// ---------------------------------------------------------------------------
//  The grid says WHEN and HOW MUCH, and it says both at once, in a sheet of
//  three hundred cells. That is the right shape for comparing forty rooms and
//  the wrong shape for the other thing this screen gets used for: standing in
//  front of somebody and walking them through ONE room - it went in here, it
//  lands here, that is what it costs, and this is the total you are being
//  asked for.
//
//  So a row can be played. The line draws itself across the years at reading
//  speed, each replacement date pops up as the line reaches it with its year
//  and its money on it, and the full refresh figure lands at the end. It is
//  the same numbers the row already carries - nothing here is computed that
//  the sheet does not already say - said one at a time instead of all at once.
//
//  IT RESPECTS "REDUCE MOTION". With animations turned off at the system level
//  the whole plan is simply there, complete, on the first frame: the point of
//  the panel is the figures, and the animation is how they are introduced.

/// Plays [room]'s replacement plan through, one date at a time.
///
/// A room with nothing dated has no plan to play and says so rather than
/// opening an empty panel — "nothing here happens when I click it" is the
/// worst answer a control can give.
Future<void> showRefreshWalkthrough(
  BuildContext context,
  RoomLifecycle room,
  String currency,
) async {
  if (room.dueGroups.isEmpty) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(
          '${room.roomName} has no install dates on it yet, so there is no '
          'plan to play. Record them on the room\'s Lifecycle tab.',
        ),
      ),
    );
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (_) => _RefreshWalkthrough(room: room, currency: currency),
  );
}

/// One room's plan, drawn across its own years and revealed as it goes.
class _RefreshWalkthrough extends StatefulWidget {
  final RoomLifecycle room;
  final String currency;

  const _RefreshWalkthrough({required this.room, required this.currency});

  @override
  State<_RefreshWalkthrough> createState() => _RefreshWalkthroughState();
}

class _RefreshWalkthroughState extends State<_RefreshWalkthrough>
    with SingleTickerProviderStateMixin {
  /// The span the plot covers: the oldest install in the room to the last year
  /// anything in it falls due.
  late final int _first;
  late final int _last;

  late final AnimationController _run;

  /// Whether the first play has been started. [didChangeDependencies] is where
  /// it can be, because whether to animate at all is a MediaQuery question and
  /// initState is too early to ask one.
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final groups = widget.room.dueGroups;
    var first = groups.first.startYear;
    var last = groups.first.dueYear;
    for (final g in groups) {
      if (g.startYear < first) first = g.startYear;
      if (g.dueYear > last) last = g.dueYear;
    }
    _first = first;
    // A plan that starts and ends in one year still needs a line with two ends
    // on it, or every x on the plot divides by nothing.
    _last = last > first ? last : first + 1;

    // READING SPEED, NOT A FIXED LENGTH. A four-year span played over the same
    // time as a twenty-year one crawls; the same twenty played over a
    // four-year one is a flicker. So it is paced per year, floored and capped
    // so neither end becomes a wait.
    //
    // FAST. This is not a title sequence - it is a figure being introduced,
    // and the second time somebody plays it they already know what it says.
    // The pacing was more than twice this and a twenty-year plan took six
    // seconds to arrive at a number that was going to be read in one.
    _run = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: ((_last - _first) * 110).clamp(600, 2200),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _play();
  }

  void _play() {
    // Reduce motion means "show me the answer", not "show me a faster
    // animation". The plan arrives complete.
    if (MediaQuery.disableAnimationsOf(context)) {
      _run.value = 1;
      return;
    }
    _run.forward(from: 0);
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  /// The year the playhead has reached, as a fraction — 2019.4 halfway through
  /// the year after 2019.
  double get _playYear => _first + (_last - _first) * _run.value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final room = widget.room;
    final groups = room.dueGroups;
    final items = groups.fold<int>(0, (sum, g) => sum + g.items.length);

    return AlertDialog(
      key: const ValueKey('lifecycle_walkthrough'),
      title: Text('${room.roomName}: when it falls due'),
      content: SizedBox(
        width: 760,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$_first to $_last  ·  '
              '${groups.length} replacement date'
              '${groups.length == 1 ? '' : 's'}  ·  '
              '$items item${items == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: _kPlotHeight,
              child: LayoutBuilder(
                builder: (context, box) => AnimatedBuilder(
                  animation: _run,
                  builder: (context, _) => _plot(context, box.maxWidth),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // WHAT THE TOTAL DOES NOT SAY. The figure itself is on the end of
            // the line where it belongs; this is the small print that would
            // make a callout unreadable - how much of it is already on the
            // list, and how many positions are in none of it because nobody
            // has dated them.
            AnimatedBuilder(
              animation: _run,
              builder: (context, _) => AnimatedOpacity(
                duration: const Duration(milliseconds: 190),
                opacity: _run.value >= 1 ? 1 : 0,
                child: _TotalFootnote(room: room, currency: widget.currency),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('lifecycle_walkthrough_replay'),
          onPressed: _play,
          icon: const Icon(Icons.replay, size: 18),
          label: const Text('Play again'),
        ),
        FilledButton(
          key: const ValueKey('lifecycle_walkthrough_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// The plot: the axis, the line as far as it has got, and every date the
  /// line has already passed.
  Widget _plot(BuildContext context, double width) {
    final theme = Theme.of(context);
    final room = widget.room;
    final groups = room.dueGroups;
    final span = _last - _first;
    final plotWidth =
        (width - _kPlotPadLeft - _kPlotPadRight).clamp(1.0, double.infinity);

    double xOf(num year) =>
        _kPlotPadLeft + ((year - _first) / span).clamp(0.0, 1.0) * plotWidth;

    // The longest life in the room drives the warm-up, so the colour ramp on
    // this line means the same thing it means on the room's row.
    var life = kDefaultEquipmentLifeYears;
    for (final g in groups) {
      if (g.lifeYears > life) life = g.lifeYears;
    }

    // ONE COLOURED SEGMENT PER YEAR, worked out here rather than in the
    // painter: the ramp is a theme question and a painter has no context to
    // ask one with.
    final segments = <({double from, double to, Color color})>[
      for (var y = _first; y < _last; y++)
        (
          from: xOf(y),
          to: xOf(y + 1),
          color: equipmentTimingFill(
            context,
            timingFor(
              yearsRemaining: (_last - y).toDouble(),
              lifeYears: life,
            ),
            alpha: 0.9,
          ),
        ),
    ];

    // A label on every year is unreadable past about sixteen of them, so they
    // thin out rather than overlap.
    final step = (span / 16).ceil().clamp(1, 100);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _PlanPainter(
              segments: segments,
              headX: xOf(_playYear),
              startX: xOf(_first),
              axis: theme.colorScheme.outlineVariant,
              head: theme.colorScheme.onSurfaceVariant,
              stems: [
                for (var i = 0; i < groups.length; i++)
                  if (_playYear >= groups[i].dueYear)
                    (
                      x: xOf(groups[i].dueYear),
                      lane: _kLaneY[i % _kLaneY.length],
                      color: equipmentTimingFill(
                        context,
                        timingFor(
                          yearsRemaining:
                              (groups[i].dueYear - room.asOf.year).toDouble(),
                          lifeYears: groups[i].lifeYears,
                        ),
                        alpha: 0.9,
                      ),
                    ),
              ],
              ticks: [
                for (var y = _first; y <= _last; y += step) xOf(y),
              ],
            ),
          ),
        ),
        // The years under the line.
        for (var y = _first; y <= _last; y += step)
          Positioned(
            top: _kLineY + 8,
            left: xOf(y) - 24,
            width: 48,
            child: Text(
              '$y',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: y <= _playYear
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        // WHAT THE WHOLE LINE ADDS UP TO, AT THE END OF IT.
        //
        // The point of walking the years one at a time is arriving somewhere,
        // and the place to say where is the end of the run - not a box under
        // the chart, which is a different object that happens to be nearby.
        // It lands when the line does.
        _RefreshTotal(
          room: room,
          currency: widget.currency,
          shown: _run.value >= 1,
          left: xOf(_last) + 14,
        ),
        // EVERY DATE POPS UP AS THE LINE REACHES IT. Two lanes, alternating,
        // because two tranches a year apart would otherwise be two cards on
        // top of each other — which is the one thing a callout must never do.
        for (var i = 0; i < groups.length; i++)
          _DueCallout(
            group: groups[i],
            room: room,
            currency: widget.currency,
            shown: _playYear >= groups[i].dueYear,
            left: (xOf(groups[i].dueYear) - _kCalloutWidth / 2)
                .clamp(0.0, (width - _kCalloutWidth).clamp(0.0, width)),
            bottom: _kPlotHeight - _kLaneY[i % _kLaneY.length],
          ),
      ],
    );
  }
}

/// How tall the plot is, and where the line, the callout lanes and the total
/// sit in it.
///
/// Constants rather than measurements because the painter and the callouts
/// have to agree about them to the pixel: a stem drawn to a lane the card is
/// not in is a line pointing at nothing.
///
/// THE TWO LANES ARE A CARD APART. They were 68 apart with cards about 70 tall
/// in them, so a callout in the upper lane ran off the top of the plot and
/// over the line of type above it. The lanes are set from the card height now,
/// and the box is tall enough to hold both of them plus the years.
const double _kPlotHeight = 260;
const double _kLineY = 224;
const double _kCalloutHeight = 70;
const List<double> _kLaneY = [200, 200 - _kCalloutHeight - 8];
const double _kCalloutWidth = 168;

/// The room either side of the line itself.
///
/// THE RIGHT-HAND MARGIN IS WHERE THE TOTAL GOES. The line stops short of the
/// edge so the figure it adds up to can sit at the end of it, the way a label
/// sits on the end of a run - see [_RefreshTotal]. Without the margin the
/// total had nowhere to be except a box underneath the chart, which is the one
/// place it stops reading as the end of the line.
const double _kPlotPadLeft = 30;
const double _kPlotPadRight = 178;

/// One replacement date, as it pops up on the line.
class _DueCallout extends StatelessWidget {
  final RoomDueGroup group;
  final RoomLifecycle room;
  final String currency;
  final bool shown;
  final double left;
  final double bottom;

  const _DueCallout({
    required this.group,
    required this.room,
    required this.currency,
    required this.shown,
    required this.left,
    required this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timing = timingFor(
      yearsRemaining: (group.dueYear - room.asOf.year).toDouble(),
      lifeYears: group.lifeYears,
    );
    final ink = equipmentTimingColor(context, timing);
    final estimated = group.items.any((i) => i.costIsEstimate);

    return Positioned(
      left: left,
      bottom: bottom,
      width: _kCalloutWidth,
      child: AnimatedOpacity(
        // Half the line's own pace: a callout still settling when the playhead
        // has reached the next year is a callout the reader is chasing.
        duration: const Duration(milliseconds: 130),
        opacity: shown ? 1 : 0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOutBack,
          scale: shown ? 1 : 0.7,
          alignment: Alignment.bottomCenter,
          child: Container(
            key: ValueKey(
              'lifecycle_play_${room.roomName}_${group.dueYear}',
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                equipmentTimingFill(context, timing, alpha: 0.18),
                theme.dialogTheme.backgroundColor ??
                    theme.colorScheme.surfaceContainerHigh,
              ),
              border: Border.all(
                color: equipmentTimingFill(context, timing, alpha: 0.8),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${group.dueYear}',
                  style: theme.textTheme.titleSmall?.copyWith(color: ink),
                ),
                Text(
                  group.cost > 0
                      ? '${estimated ? '~' : ''}'
                          '${formatLifecycleMoney(group.cost, currency)}'
                      : 'not priced',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontStyle: estimated ? FontStyle.italic : FontStyle.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${group.items.length} item'
                  '${group.items.length == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// WHAT THE LINE ADDS UP TO, drawn on the end of it.
///
/// Anchored to the last year on the plot rather than laid out under the chart,
/// because the sentence this is the end of is "it went in here, it lands here,
/// and here is what the room comes to" - and a figure in a box below breaks
/// that sentence in half. The right-hand margin exists to hold it; see
/// [_kPlotPadRight].
class _RefreshTotal extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;
  final bool shown;
  final double left;

  const _RefreshTotal({
    required this.room,
    required this.currency,
    required this.shown,
    required this.left,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = equipmentTimingColor(context, room.timing);

    return Positioned(
      left: left,
      // Centred on the line, so it reads as the label on the end of it.
      top: _kLineY - 34,
      width: _kPlotPadRight - 22,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 190),
        opacity: shown ? 1 : 0,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOut,
          // Arrives from the left, along the line it belongs to.
          offset: shown ? Offset.zero : const Offset(-0.12, 0),
          child: Container(
            key: const ValueKey('lifecycle_walkthrough_total'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                equipmentTimingFill(context, room.timing, alpha: 0.16),
                theme.dialogTheme.backgroundColor ??
                    theme.colorScheme.surfaceContainerHigh,
              ),
              border: Border.all(
                color: equipmentTimingFill(context, room.timing, alpha: 0.8),
                width: 1.4,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FULL REFRESH',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  room.refreshCost > 0
                      ? formatLifecycleMoney(room.refreshCost, currency)
                      : 'not priced',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${room.items.length} item'
                  '${room.items.length == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The small print under the chart: what the total does NOT say.
///
/// Separate from the figure, and under the plot rather than on it, because
/// both of these are qualifications - and a callout on the end of a line has
/// room for a number, not for a paragraph.
class _TotalFootnote extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;

  const _TotalFootnote({required this.room, required this.currency});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = [
      if (room.toReplaceCount > 0)
        'On the list now: '
            '${formatEquipmentBand(
          room.toReplaceCount,
          room.toReplaceCost,
          currency,
        )}',
      if (room.undated > 0)
        '${room.undated} item${room.undated == 1 ? '' : 's'} with no install '
            'date fall due in no year here, and are in none of these figures',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Text(
      parts.join('  ·  '),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// The axis, the line as far as it has been drawn, and a stem up to every
/// callout already on screen.
class _PlanPainter extends CustomPainter {
  /// One year of the line each, already in the colour that year reads in.
  final List<({double from, double to, Color color})> segments;

  /// Where the playhead has got to, and where the line starts.
  final double headX, startX;

  final Color axis, head;

  /// A stem per callout that has popped up: up from the line to its lane.
  final List<({double x, double lane, Color color})> stems;

  /// Where the year labels are, so the axis can carry a tick under each.
  final List<double> ticks;

  const _PlanPainter({
    required this.segments,
    required this.headX,
    required this.startX,
    required this.axis,
    required this.head,
    required this.stems,
    required this.ticks,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = axis
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(_kPlotPadLeft * 0.5, _kLineY),
      Offset(size.width - _kPlotPadRight * 0.25, _kLineY),
      rule,
    );
    for (final x in ticks) {
      canvas.drawLine(Offset(x, _kLineY - 3), Offset(x, _kLineY + 3), rule);
    }

    // THE LINE, ONE YEAR AT A TIME, clipped to wherever the playhead is. A
    // year only half reached is drawn half.
    final line = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final s in segments) {
      if (s.from >= headX) break;
      line.color = s.color;
      canvas.drawLine(
        Offset(s.from, _kLineY),
        Offset(s.to < headX ? s.to : headX, _kLineY),
        line,
      );
    }

    // Where the room was last done: the line has to have a visible beginning
    // or it reads as running off the left edge from further back.
    canvas.drawCircle(Offset(startX, _kLineY), 5, Paint()..color = head);

    for (final stem in stems) {
      canvas.drawLine(
        Offset(stem.x, _kLineY),
        Offset(stem.x, stem.lane),
        Paint()
          ..color = stem.color
          ..strokeWidth = 2,
      );
      canvas.drawCircle(Offset(stem.x, _kLineY), 5, Paint()..color = stem.color);
    }

    // The playhead itself, so the years being crossed are legible while it
    // moves rather than only where it stops.
    canvas.drawCircle(
      Offset(headX, _kLineY),
      4,
      Paint()..color = head,
    );
  }

  @override
  bool shouldRepaint(_PlanPainter old) =>
      old.headX != headX ||
      old.stems.length != stems.length ||
      old.segments.length != segments.length;
}
