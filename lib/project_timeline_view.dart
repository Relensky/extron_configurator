import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show trimNumber;
import 'equipment_lifecycle.dart'
    show RoomLifecycle, buildProjectLifecycle, formatLifecycleMoney;
import 'project_estimate.dart';
import 'project_history_view.dart' show ItemHistory;
import 'project_reminders.dart';
import 'project_schedule.dart';
import 'stepped_date_picker.dart';

/// ============================================================================
///  THE DELIVERY TIMELINE
/// ============================================================================
///  The Core Components list answers "what does this job need and who sells
///  it". This answers the question that comes next and used to live entirely in
///  somebody's head: WHEN does each of those have to be bought.
///
///  One date drives it — the day the building has to be finished — and one
///  figure per part: how long that part takes to arrive. Everything on screen
///  is the subtraction between them (see project_schedule.dart), so moving the
///  deadline moves every order date with it.
///
///  THE EXCEPTION IS THE POINT. A job does not need everything on the same day:
///  screens, mounts, floor boxes and conduit go in while the walls are still
///  open, weeks before the rack is delivered. Those parts carry their OWN need-
///  by date, and the schedule prefers it over the project's — which is why the
///  order-by column can show a part being bought two months before a job whose
///  deadline is in June.
///
///  READ AS A LIST OF DAYS, not a list of parts. An order date is a trip to the
///  purchasing office, and eleven parts sharing one is one trip; grouping them
///  is what turns a hundred-row table into the half-dozen dates somebody
///  actually has to put in a calendar.
/// ============================================================================

/// The timeline for a job that has a replacement plan and no parts.
///
/// Everything here comes off the SAME lifecycle the plan is drawn from - see
/// [buildProjectLifecycle] - so the year a room is listed under here and the
/// year its cell is coloured in there can never disagree.
List<Widget> _lifecycleSlivers(
  BuildContext context,
  ProjectEstimate estimate,
  ProjectSchedule schedule,
) {
  final theme = Theme.of(context);
  final provider = context.watch<AppStateProvider>();
  final building = buildProjectLifecycle(
    estimate: estimate,
    library: provider.avDeviceLibrary,
    baseCosts: provider.baseCosts,
    tier: provider.pricingTier,
  );

  // One entry per year anything is due, earliest first. A room with no date is
  // not on a year and is counted separately - it is a survey to do, not a year
  // to budget.
  final byYear = <int, List<RoomLifecycle>>{};
  var undated = 0;
  for (final room in building.rooms) {
    final year = room.firstDueYear;
    if (year == null) {
      undated++;
      continue;
    }
    byYear.putIfAbsent(year, () => []).add(room);
  }
  final years = byYear.keys.toList()..sort();

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          'This building is on the plan and not yet drawn, so there is nothing '
          'to order and no lead times to work back from. What it does have is '
          'a year per room. Set the phases below to break the refresh up; the '
          'order dates appear as rooms get built.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
    // THE PHASES, which are the thing a refresh is actually planned in and the
    // one part of this pane that never needed a part to exist.
    SliverToBoxAdapter(child: _TrackStrip(schedule: schedule)),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 12, 16, 4),
        child: Text(
          'DUE BY YEAR',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      sliver: SliverList.builder(
        itemCount: years.length,
        itemBuilder: (context, index) => _DueYearCard(
          year: years[index],
          rooms: byYear[years[index]]!,
          currency: building.currency,
          thisYear: building.asOf.year,
          first: index == 0,
          last: index == years.length - 1,
        ),
      ),
    ),
    if (undated > 0)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            '$undated room${undated == 1 ? '' : 's'} on this job '
            '${undated == 1 ? 'has' : 'have'} no date, so nothing can be said '
            'about when ${undated == 1 ? 'it falls' : 'they fall'} due. Put a '
            'last-done date on the line item and it lands on a year here.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

/// One year of the replacement plan: what falls due, and what it comes to.
///
/// Deliberately the shape of an [_OrderDayCard] - a date, a total, and the
/// things that land on it - because it is read for the same reason: this is
/// the year somebody has to find the money in.
class _DueYearCard extends StatelessWidget {
  final int year;
  final List<RoomLifecycle> rooms;
  final String currency;
  final int thisYear;
  final bool first;
  final bool last;

  const _DueYearCard({
    required this.year,
    required this.rooms,
    required this.currency,
    required this.thisYear,
    required this.first,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = rooms.fold<double>(0, (sum, r) => sum + r.costDueIn(year));
    // A year already gone is money that is late, and reads as late.
    final overdue = year < thisYear;
    final ink = overdue
        ? errorTextOn(theme.colorScheme, theme.cardColor)
        : theme.colorScheme.onSurface;

    return Card(
      key: ValueKey('timeline_due_$year'),
      margin: EdgeInsets.fromLTRB(0, first ? 4 : 2, 0, last ? 4 : 2),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  overdue ? Icons.warning_amber : Icons.event,
                  size: 18,
                  color: ink,
                ),
                const SizedBox(width: 8),
                Text(
                  '$year',
                  style: theme.textTheme.titleMedium?.copyWith(color: ink),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${rooms.length} room${rooms.length == 1 ? '' : 's'}'
                    '${overdue ? '  ·  already past' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  formatLifecycleMoney(total, currency),
                  style: theme.textTheme.titleSmall?.copyWith(color: ink),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final room in rooms)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(
                      '${room.roomName}  '
                      '${formatLifecycleMoney(room.costDueIn(year), currency)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The project deadline, as a chip that sets it.
///
/// In the header strip beside the money because every other date on the tab is
/// derived from this one, and a deadline that has to be navigated to is a
/// deadline that stays unset.
class DeadlineChip extends StatelessWidget {
  final ProjectEstimate estimate;
  const DeadlineChip({super.key, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final deadline = provider.project.deliveryDeadline;
    final schedule = buildProjectSchedule(estimate: estimate);
    final late = schedule.lateCount;

    // The chip earns a warning fill only when something is actually behind.
    // A deadline that has not been set yet is not an error — most projects are
    // quoted before a date exists — so it reads as an invitation instead.
    final warn = late > 0;
    final fill = warn ? theme.colorScheme.errorContainer : null;
    final ink = warn
        ? foregroundOn(theme.colorScheme, theme.colorScheme.errorContainer)
        : null;

    final chip = Tooltip(
      message: deadline == null
          ? 'Set the date this job has to be delivered by. Every order-by '
              'date on the Timeline is worked back from it.'
          : warn
              ? '$late ${late == 1 ? 'part is' : 'parts are'} already past '
                  'the date they had to be ordered on.\nClick to change the '
                  'deadline.'
              : 'Everything on this job has to be on site by this date.\n'
                  'Click to change it.',
      child: ActionChip(
        key: const ValueKey('project_deadline'),
        avatar: Icon(
          warn ? Icons.event_busy : Icons.event,
          size: 18,
          color: ink,
        ),
        label: Text(
          deadline == null
              ? 'Set deadline'
              : 'Due ${formatScheduleDate(deadline)}',
          style: TextStyle(color: ink),
        ),
        backgroundColor: fill,
        onPressed: () => _pickDeadline(context, provider),
      ),
    );

    // Nothing to clear until there is a deadline, so the × only appears once
    // there is one — and never inside the picker, where Escape would hit it.
    if (deadline == null) return chip;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip,
        ClearDateButton(
          buttonKey: const ValueKey('project_deadline_clear'),
          tooltip: 'Clear the delivery deadline',
          onPressed: () => provider.setProjectDeadline(null),
        ),
      ],
    );
  }

  Future<void> _pickDeadline(
    BuildContext context,
    AppStateProvider provider,
  ) async {
    final picked = await showProjectDatePicker(
      context,
      initial: provider.project.deliveryDeadline,
      title: 'Delivery deadline',
    );
    if (picked == null) return;
    provider.setProjectDeadline(picked.date);
  }
}

/// What [showProjectDatePicker] came back with: a date, or an explicit clear.
///
/// Null-for-cancel and null-for-cleared are two different answers and a bare
/// `DateTime?` cannot tell them apart — the difference between leaving a
/// deadline alone and deleting it.
class PickedDate {
  final DateTime? date;
  final bool cleared;
  const PickedDate.on(DateTime this.date) : cleared = false;
  const PickedDate.cleared() : date = null, cleared = true;
}

/// Picks a date. Returns null when the user backed out, and never clears
/// anything on its own.
///
/// CLEARING IS NOT PART OF THIS DIALOG, deliberately. The Material picker has
/// exactly one dismissal — Cancel, Escape and a tap outside all come back as
/// the same null — so a picker that treated "no date chosen" as "delete the
/// date" would wipe a deadline every time somebody hit Escape, which is the
/// one thing a person does when they open a dialog by accident. Clearing is a
/// separate control on the thing that owns the date; see [ClearDateButton].
Future<PickedDate?> showProjectDatePicker(
  BuildContext context, {
  required DateTime? initial,
  required String title,
}) async {
  final now = today();
  // NOT the Material picker. Almost every date on this tab is months or years
  // out — an order date worked back from a delivery next spring, a phase in
  // the summer after this one — and Material's only shortcut out of the month
  // grid is a year list that drops back onto the same month number in the new
  // year. This one narrows: year, then month, then day. See
  // stepped_date_picker.dart.
  final picked = await showSteppedDatePicker(
    context,
    initialDate: initial ?? now,
    // A job can be scheduled against a date that has already gone — a project
    // picked up halfway through is the ordinary case, and a picker that
    // refuses last month makes recording what actually happened impossible.
    firstDate: DateTime(now.year - 5, 1, 1),
    // THE LAST DAY OF THE LAST YEAR, not the first.
    //
    // `DateTime(y)` is the 1st of January, so a range ending at
    // `DateTime(now.year + 10)` offered a final year in which exactly one day
    // — New Year's Day — could be picked, and eleven months that the grid
    // greyed out with no explanation. A picker whose last year refuses almost
    // every cell in it reads as a picker that has stopped working.
    lastDate: DateTime(now.year + 10, 12, 31),
    helpText: title,
    confirmText: 'Set',
  );
  return picked == null ? null : PickedDate.on(dateOnly(picked));
}

/// The small × that takes a date back off, beside whatever shows it.
///
/// Its own control rather than a button inside the picker, so that backing out
/// of the picker and deleting the date can never be the same gesture.
class ClearDateButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onPressed;
  final Key? buttonKey;

  const ClearDateButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.buttonKey,
  });

  @override
  Widget build(BuildContext context) => IconButton(
    key: buttonKey,
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    icon: const Icon(Icons.close, size: 14),
    onPressed: onPressed,
  );
}

/// The colour a status reads in. Kept in one place because the chip, the row
/// and the timeline all have to agree — three shades of "late" would read as
/// three different states.
Color orderStatusColor(BuildContext context, OrderStatus status) {
  final theme = Theme.of(context);
  switch (status) {
    case OrderStatus.late:
    // Bought and still going to be late. It reads as a problem because it is
    // one — nothing on the ordering side can fix it now.
    case OrderStatus.arrivingLate:
      return errorTextOn(theme.colorScheme, theme.cardColor);
    case OrderStatus.dueSoon:
      return theme.colorScheme.tertiary;
    case OrderStatus.onTrack:
    // Bought and on its way: the same settled colour as a part with time in
    // hand, because from here neither needs anybody to do anything.
    case OrderStatus.ordered:
    case OrderStatus.received:
      return theme.colorScheme.primary;
    case OrderStatus.unknown:
    case OrderStatus.noDeadline:
      return theme.colorScheme.onSurfaceVariant;
  }
}

IconData orderStatusIcon(OrderStatus status) => switch (status) {
  OrderStatus.late => Icons.error_outline,
  OrderStatus.dueSoon => Icons.schedule,
  OrderStatus.onTrack => Icons.check_circle_outline,
  OrderStatus.unknown => Icons.help_outline,
  OrderStatus.noDeadline => Icons.event_note,
  OrderStatus.arrivingLate => Icons.running_with_errors,
  OrderStatus.ordered => Icons.local_shipping_outlined,
  OrderStatus.received => Icons.inventory_2,
};

/// The timeline pane, as slivers for the project tab's one scroll view.
List<Widget> timelineSlivers(BuildContext context, ProjectEstimate estimate) {
  final theme = Theme.of(context);
  final provider = context.watch<AppStateProvider>();
  final schedule = buildProjectSchedule(estimate: estimate);

  if (estimate.master.isEmpty) {
    // A JOB CAN HAVE A CALENDAR AND NO PARTS.
    //
    // The order dates on this pane are worked back from lead times, and a lead
    // time is a fact about a part - so a building whose rooms are all line
    // items has nothing to order and this pane said "nothing to schedule".
    // Which was true about the parts and quite wrong about the job: a refresh
    // plan is the one kind of work that is ALL calendar, and the year each
    // room falls due is the only date anybody is planning against.
    //
    // So when there are no parts but there is a replacement plan, the pane
    // shows the plan: the phases, which are what a refresh gets broken into,
    // and the rooms under the year they come due. The deadline chip in the
    // header still sets the job's date, and both survive the first room being
    // drawn - at which point the parts arrive and the order dates with them.
    if (provider.project.manualRooms.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Nothing to schedule yet.\n\n'
                'The timeline is built from the Equipment list - add '
                'rooms that have equipment on them, or add line items on the '
                'Rooms pane and this becomes the replacement calendar.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ];
    }
    return _lifecycleSlivers(context, estimate, schedule);
  }

  return [
    SliverToBoxAdapter(
      child: _TimelineSummary(schedule: schedule, provider: provider),
    ),
    SliverToBoxAdapter(
      child: _ReminderBar(estimate: estimate, schedule: schedule),
    ),
    // The phases, each with its own delivery date, laid out one after the
    // other — the reading this exists for: whether the infrastructure order
    // going in months before the tech order actually lines up.
    SliverToBoxAdapter(child: _TrackStrip(schedule: schedule)),
    if (schedule.hasNoDates)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No deadline yet.\n\n'
                'Set the delivery deadline in the header, then put a lead '
                'time on the parts that matter - the Equipment list has '
                'a Lead time column. Anything that has to arrive earlier than '
                'the rest (screens, mounts, floor boxes) gets its own date on '
                'the same editor.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ),
      )
    else ...[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 4, 16, 4),
          child: Text(
            'ORDER BY',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        sliver: SliverList.builder(
          itemCount: schedule.orderDays.length,
          itemBuilder: (context, index) {
            final day = schedule.orderDays[index];
            return _OrderDayCard(
              day: day,
              asOf: schedule.asOf,
              first: index == 0,
              last: index == schedule.orderDays.length - 1,
            );
          },
        ),
      ),
    ],
    if (schedule.unknownCount > 0)
      SliverToBoxAdapter(
        child: _UnknownLeadTimes(schedule: schedule),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

/// Getting the order dates out of this app and into the calendar that will
/// actually remind somebody.
///
/// The timeline is read by whoever is building the job; the purchase order is
/// raised by somebody who lives in Outlook and will never open this. A date
/// that is not in their calendar is a date that gets missed, so the schedule
/// exports as an ICS: one all-day event per order date, with an alarm a week
/// before. See project_reminders.dart.
class _ReminderBar extends StatelessWidget {
  final ProjectEstimate estimate;
  final ProjectSchedule schedule;

  const _ReminderBar({required this.estimate, required this.schedule});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final tracks = provider.project.tracks;
    final dated = schedule.orderDays.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('timeline_export_ics'),
            icon: const Icon(Icons.event_available, size: 18),
            label: Text(
              dated == 0
                  ? 'Calendar reminders'
                  : 'Calendar reminders ($dated dates)',
            ),
            onPressed: dated == 0
                ? null
                : () => exportOrderReminders(context, provider, estimate),
          ),
          // A purchasing office running the infrastructure order and the tech
          // order as two jobs wants two calendars, not one with both in it.
          for (final t in tracks)
            if (schedule.linesForTrack(t.id).any((l) => l.orderBy != null))
              OutlinedButton.icon(
                key: ValueKey('timeline_export_ics_${t.id}'),
                icon: const Icon(Icons.alt_route, size: 16),
                label: Text('${t.name} only'),
                onPressed: () => exportOrderReminders(
                  context,
                  provider,
                  estimate,
                  trackId: t.id,
                  trackName: t.name,
                ),
              ),
          Text(
            'Imports into Outlook, Gmail or Apple Calendar. Each date reminds '
            '$kReminderLeadDays days ahead.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Writes the order dates out as a calendar file.
///
/// Re-exporting the same project UPDATES the events already imported rather
/// than duplicating them — the uids are stable and the sequence number rises —
/// so moving a deadline and exporting again is a supported thing to do rather
/// than something that leaves two sets of dates in somebody's calendar.
Future<void> exportOrderReminders(
  BuildContext context,
  AppStateProvider provider,
  ProjectEstimate estimate, {
  String trackId = '',
  String trackName = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final export = buildOrderReminders(
    estimate: estimate,
    sequence: provider.nextReminderSequence(),
    trackId: trackId,
  );
  if (export.isEmpty) {
    showTimedSnackBar(
      messenger,
      const SnackBar(
        content: Text(
          'Nothing has an order date yet - set a delivery deadline and some '
          'lead times first.',
        ),
      ),
    );
    return;
  }

  final picked = await FilePicker.saveFile(
    dialogTitle: 'Save the order reminders',
    fileName:
        '${reminderFileStem(provider.project, trackName: trackName)}.ics',
    type: FileType.custom,
    allowedExtensions: const ['ics'],
  );
  if (picked == null) return;
  final target = picked.toLowerCase().endsWith('.ics') ? picked : '$picked.ics';

  try {
    await File(target).writeAsString(export.ics);
  } catch (e) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text('The calendar could not be written: $e'),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
    return;
  }
  if (!context.mounted) return;

  // What could not be scheduled is said out loud rather than left out: a
  // calendar quietly missing the parts nobody has a lead time for reads as a
  // complete schedule, which is the one thing it must not do.
  showSavedFileSnack(
    context,
    provider,
    export.skipped.isEmpty
        ? '${export.events} order date'
              '${export.events == 1 ? '' : 's'}'
        : '${export.events} order date'
              '${export.events == 1 ? '' : 's'} '
              '(${export.skipped.length} part'
              '${export.skipped.length == 1 ? '' : 's'} could not be dated)',
    target,
  );
}

/// Whether this part has been bought, and what the vendor promised.
///
/// Four facts, all of which somebody already has written down: the PO it went
/// out on, the day it went, the date promised, and the day it turned up. This
/// is a record of a decision, not a procurement system.
///
/// THE ORDER DATE IS WHAT COUNTS. A PO number with no date cannot be measured
/// against a deadline, so a part is only treated as bought once there is a day
/// on it — see [PartOrder.isOrdered].
class _OrderBlock extends StatefulWidget {
  final PartOrder order;

  /// The day this part is actually needed, so a promised date landing after it
  /// can be called out here rather than discovered later.
  final DateTime? needBy;

  final ValueChanged<PartOrder> onChanged;

  const _OrderBlock({
    required this.order,
    required this.needBy,
    required this.onChanged,
  });

  @override
  State<_OrderBlock> createState() => _OrderBlockState();
}

class _OrderBlockState extends State<_OrderBlock> {
  /// Its own controller, built once. A TextEditingController rebuilt on every
  /// keystroke puts the caret back to the start, which is what typing into a
  /// PO number felt like the first time this was written.
  late final TextEditingController _po = TextEditingController(
    text: widget.order.poNumber,
  );

  @override
  void dispose() {
    _po.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final order = widget.order;
    final arrivingLate = order.arrivesLate(widget.needBy);
    final alarm = errorTextOn(theme.colorScheme, theme.cardColor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              order.isReceived
                  ? Icons.inventory_2
                  : order.isOrdered
                  ? Icons.local_shipping_outlined
                  : Icons.shopping_cart_checkout,
              size: 18,
              color: muted,
            ),
            const SizedBox(width: 8),
            Text('Bought?', style: theme.textTheme.labelMedium),
            const Spacer(),
            // The one-click case. The paperwork usually catches up later, and
            // a record that demands a PO number before it will believe the
            // order went in is one nobody fills in on the day.
            if (!order.isOrdered)
              FilledButton.tonal(
                key: const ValueKey('part_mark_ordered'),
                onPressed: () =>
                    widget.onChanged(order.copyWith(orderedOn: today())),
                child: const Text('Ordered today'),
              )
            else if (!order.isReceived)
              FilledButton.tonal(
                key: const ValueKey('part_mark_received'),
                onPressed: () =>
                    widget.onChanged(order.copyWith(receivedOn: today())),
                child: const Text('Arrived today'),
              )
            else
              TextButton(
                key: const ValueKey('part_clear_received'),
                onPressed: () =>
                    widget.onChanged(order.copyWith(clearReceivedOn: true)),
                child: const Text('Not arrived after all'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('part_po_number'),
                controller: _po,
                decoration: const InputDecoration(
                  labelText: 'PO number',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => widget.onChanged(order.copyWith(poNumber: v)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _DateButton(
                label: 'Ordered',
                value: order.orderedOn,
                buttonKey: const ValueKey('part_ordered_on'),
                onPick: (d) => widget.onChanged(
                  d == null
                      ? order.copyWith(clearOrderedOn: true)
                      : order.copyWith(orderedOn: d),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _DateButton(
                label: 'Vendor promised',
                value: order.expectedOn,
                buttonKey: const ValueKey('part_expected_on'),
                warn: arrivingLate,
                onPick: (d) => widget.onChanged(
                  d == null
                      ? order.copyWith(clearExpectedOn: true)
                      : order.copyWith(expectedOn: d),
                ),
              ),
            ),
          ],
        ),
        if (order.isReceived)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Arrived ${formatScheduleDate(order.receivedOn!)}. This part is '
              'finished with - it is off the order schedule.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          )
        else if (arrivingLate) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.running_with_errors, size: 16, color: alarm),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'The vendor is promising it AFTER the day it is needed. It '
                  'is bought - but the room will not have it in time.',
                  key: const ValueKey('part_arriving_late'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: alarm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A labelled date, picked or cleared.
class _DateButton extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPick;
  final Key? buttonKey;
  final bool warn;

  const _DateButton({
    required this.label,
    required this.value,
    required this.onPick,
    this.buttonKey,
    this.warn = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = warn
        ? errorTextOn(theme.colorScheme, theme.cardColor)
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            key: buttonKey,
            onPressed: () async {
              final picked = await showProjectDatePicker(
                context,
                initial: value,
                title: label,
              );
              if (picked == null) return;
              onPick(picked.date);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: ink),
                ),
                Text(
                  value == null ? 'not set' : formatScheduleDate(value!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: warn ? ink : null,
                    fontWeight: warn ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (value != null)
          ClearDateButton(
            tooltip: 'Clear $label',
            onPressed: () => onPick(null),
          ),
      ],
    );
  }
}

/// The job's delivery phases, side by side.
///
/// A building is not finished on one date — the conduit and the mounts go in
/// while the walls are open, the racks months later — and until a job says so,
/// every order date is worked back from one deadline that can only be right for
/// one of them. See [ProjectTrack].
class _TrackStrip extends StatelessWidget {
  final ProjectSchedule schedule;
  const _TrackStrip({required this.schedule});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final project = provider.project;

    if (project.tracks.isEmpty) {
      // Offered rather than imposed: a job delivered in one go is a real job
      // and should not have to dismiss a structure it does not want.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'This job delivers on one date. If the infrastructure goes in '
                'before the tech does, split it into phases and each gets its '
                'own delivery date.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('timeline_add_starter_tracks'),
              icon: const Icon(Icons.alt_route, size: 18),
              label: const Text('Split into phases'),
              onPressed: provider.addStarterProjectTracks,
            ),
          ],
        ),
      );
    }

    final byTrack = {
      for (final entry in schedule.byTrack(project))
        entry.track?.id ?? '': entry.parts,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // HOW THE PHASES ARE ORDERED, and the two dates that can order them.
          // The order is a decision - the work happens in a sequence, which is
          // not always the sequence of the dates - so dragging is the primary
          // way and the sorts are one press that rewrites it.
          if (project.tracks.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.drag_indicator,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Drag a phase by its handle to reorder',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    key: const ValueKey('timeline_sort_delivery'),
                    onPressed: () =>
                        provider.sortProjectTracks(byCompletion: false),
                    icon: const Icon(Icons.event, size: 16),
                    label: const Text('By delivery date'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('timeline_sort_completion'),
                    onPressed: () =>
                        provider.sortProjectTracks(byCompletion: true),
                    icon: const Icon(Icons.flag_outlined, size: 16),
                    label: const Text('By completion date'),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (i, track) in project.tracks.indexed)
                _DraggablePhase(
                  index: i,
                  onMove: provider.moveProjectTrack,
                  child: _TrackCard(
                    track: track,
                    parts: byTrack[track.id] ?? const [],
                    asOf: schedule.asOf,
                    dragIndex: project.tracks.length > 1 ? i : null,
                  ),
                ),
              // Not draggable and not a drop target: it is not a phase, it is
              // everything nobody put on one, and it has no place in an order
              // somebody arranged.
              if ((byTrack[''] ?? const []).isNotEmpty)
                _TrackCard(
                  track: null,
                  parts: byTrack['']!,
                  asOf: schedule.asOf,
                ),
              // Whatever this job is actually divided into — "Phase 2",
              // "Furniture", "Owner-furnished".
              ActionChip(
                key: const ValueKey('timeline_add_track'),
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add a phase'),
                onPressed: () => _addTrack(context, provider),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addTrack(
    BuildContext context,
    AppStateProvider provider,
  ) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a delivery phase'),
        content: SizedBox(
          width: 380,
          child: TextField(
            key: const ValueKey('track_name'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Called',
              hintText: 'Phase 2',
              helperText: 'Give it a delivery date once it exists.',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('track_add'),
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null) return;
    provider.addProjectTrack(name);
  }
}

/// One phase card, as something that can be picked up and dropped on another.
///
/// A [Draggable] on a HANDLE rather than on the whole card: the card carries a
/// menu button and a date, and a card that started a drag anywhere on itself
/// would make those two controls a lottery on a trackpad. The whole card is a
/// drop TARGET though - the thing being aimed at is the phase, and asking
/// somebody to hit a 16-pixel handle with a card already in hand is a drop
/// that misses.
class _DraggablePhase extends StatefulWidget {
  final int index;
  final void Function(int from, int to) onMove;
  final Widget child;

  const _DraggablePhase({
    required this.index,
    required this.onMove,
    required this.child,
  });

  @override
  State<_DraggablePhase> createState() => _DraggablePhaseState();
}

class _DraggablePhaseState extends State<_DraggablePhase> {
  /// Whether a phase is hovering over this one, so the card can say where the
  /// drop would land before it lands.
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) {
        if (d.data == widget.index) return false;
        setState(() => _over = true);
        return true;
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        widget.onMove(d.data, widget.index);
      },
      builder: (context, candidate, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _over ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        // The card as it is. What STARTS a drag is the handle inside it - see
        // [_TrackCard.dragIndex].
        child: widget.child,
      ),
    );
  }
}

/// One phase: its date, what is on it, and when its first order goes in.
class _TrackCard extends StatelessWidget {
  /// Null for the parts delivered with the job rather than on a phase — they
  /// still have to be shown, or they vanish off the timeline.
  final ProjectTrack? track;
  final List<PartScheduleLine> parts;
  final DateTime asOf;

  /// Where this phase sits in the timeline, when it is one that can be moved.
  /// Null on the "with the job" card and on a job with a single phase, and
  /// then no handle is drawn - a control that cannot do anything is one more
  /// thing to try.
  final int? dragIndex;

  const _TrackCard({
    required this.track,
    required this.parts,
    required this.asOf,
    this.dragIndex,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final t = track;

    DateTime? firstOrder;
    var late = 0;
    for (final p in parts) {
      if (p.status == OrderStatus.late) late++;
      final d = p.orderBy;
      if (d == null) continue;
      if (firstOrder == null || d.isBefore(firstOrder)) firstOrder = d;
    }
    final deadline = t?.deadline ?? provider.project.deliveryDeadline;
    final warn = late > 0;
    final ink = warn
        ? errorTextOn(theme.colorScheme, theme.cardColor)
        : theme.colorScheme.onSurface;

    return SizedBox(
      width: 252,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (dragIndex != null)
                    Draggable<int>(
                      data: dragIndex,
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      feedback: _DragLabel(name: t?.name ?? ''),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Tooltip(
                          message: 'Drag to move this phase',
                          child: Icon(
                            Icons.drag_indicator,
                            key: ValueKey('track_drag_${t?.id ?? ''}'),
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  Icon(
                    t == null ? Icons.work_outline : Icons.alt_route,
                    size: 15,
                    color: ink,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      t?.name ?? 'With the job',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: ink,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (t != null)
                    PopupMenuButton<String>(
                      key: ValueKey('track_menu_${t.id}'),
                      tooltip: 'This phase',
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_vert, size: 16),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'date',
                          child: Text('Set the delivery date…'),
                        ),
                        if (t.deadline != null)
                          const PopupMenuItem(
                            value: 'cleardate',
                            child: Text('Use the job deadline'),
                          ),
                        const PopupMenuItem(
                          value: 'done',
                          child: Text('Set the completion date…'),
                        ),
                        if (t.completion != null)
                          const PopupMenuItem(
                            value: 'cleardone',
                            child: Text('Clear the completion date'),
                          ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove this phase'),
                        ),
                      ],
                      onSelected: (v) async {
                        if (v == 'remove') {
                          provider.removeProjectTrack(t.id);
                          return;
                        }
                        if (v == 'cleardate') {
                          provider.setProjectTrackDeadline(t.id, null);
                          return;
                        }
                        if (v == 'cleardone') {
                          provider.setProjectTrackCompletion(t.id, null);
                          return;
                        }
                        if (v == 'done') {
                          final done = await showProjectDatePicker(
                            context,
                            initial: t.completion,
                            title: '${t.name} - finished by',
                          );
                          if (done == null) return;
                          provider.setProjectTrackCompletion(t.id, done.date);
                          return;
                        }
                        final picked = await showProjectDatePicker(
                          context,
                          initial: t.deadline,
                          title: '${t.name} - on site by',
                        );
                        if (picked == null) return;
                        provider.setProjectTrackDeadline(t.id, picked.date);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 2),
              _line(
                theme,
                Icons.event,
                deadline == null
                    ? 'no delivery date'
                    : 'on site ${formatScheduleDate(deadline)}'
                          '${t?.deadline == null ? ' (job)' : ''}',
              ),
              _line(
                theme,
                Icons.play_arrow,
                firstOrder == null
                    ? 'nothing scheduled yet'
                    : 'first order ${formatScheduleDate(firstOrder)}',
              ),
              // The other end of the phase. Only once somebody has committed
              // to one: a line saying "no completion date" on every phase of
              // every job is a line nobody reads.
              if (t?.completion != null)
                _line(
                  theme,
                  Icons.flag_outlined,
                  'finished ${formatScheduleDate(t!.completion!)}',
                ),
              _line(
                theme,
                Icons.inventory_2_outlined,
                '${parts.length} part${parts.length == 1 ? '' : 's'}'
                '${late > 0 ? '  ·  $late late' : ''}',
                colour: warn ? ink : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(ThemeData theme, IconData icon, String text, {Color? colour}) =>
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            Icon(
              icon,
              size: 12,
              color: colour ?? theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colour ?? theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

/// The three counts the timeline exists to surface, above the dates.
class _TimelineSummary extends StatelessWidget {
  final ProjectSchedule schedule;
  final AppStateProvider provider;

  const _TimelineSummary({required this.schedule, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deadline = schedule.deadline;
    final firstOrder = schedule.firstOrderDate;

    Widget stat(String label, String value, {Color? color, IconData? icon}) =>
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 14, color: color),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color ?? theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          stat(
            'Delivery deadline',
            deadline == null ? 'not set' : formatScheduleDate(deadline),
            icon: Icons.event,
          ),
          stat(
            'First order due',
            firstOrder == null ? '-' : formatScheduleDate(firstOrder),
            icon: Icons.play_arrow,
          ),
          if (schedule.lateCount > 0)
            stat(
              'Order date passed',
              '${schedule.lateCount}',
              icon: Icons.error_outline,
              color: errorTextOn(theme.colorScheme, theme.cardColor),
            ),
          if (schedule.dueSoonCount > 0)
            stat(
              'Order now',
              '${schedule.dueSoonCount}',
              icon: Icons.schedule,
              color: theme.colorScheme.tertiary,
            ),
          if (schedule.unknownCount > 0)
            stat(
              'No lead time',
              '${schedule.unknownCount}',
              icon: Icons.help_outline,
            ),
        ],
      ),
    );
  }
}

/// One order date, and everything that has to be bought on it.
class _OrderDayCard extends StatelessWidget {
  final ({DateTime date, List<PartScheduleLine> parts}) day;
  final DateTime asOf;
  final bool first;
  final bool last;

  const _OrderDayCard({
    required this.day,
    required this.asOf,
    required this.first,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The worst status on the day decides the day's colour: a date with one
    // part already late is a late date, however healthy the other ten are.
    final status = day.parts
        .map((p) => p.status)
        .reduce((a, b) => a.index < b.index ? a : b);
    final color = orderStatusColor(context, status);
    final gap = daysBetween(asOf, day.date);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The spine: a dot on the date, a line between the dates. Drawn with
          // boxes rather than a painter so it inherits the theme and survives
          // a text-scale change without measuring anything.
          SizedBox(
            width: 24,
            child: Column(
              children: [
                SizedBox(
                  height: 18,
                  child: Center(
                    child: Container(
                      width: 2,
                      color: first
                          ? Colors.transparent
                          : theme.dividerColor,
                    ),
                  ),
                ),
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Container(
                      width: 2,
                      color: last ? Colors.transparent : theme.dividerColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(orderStatusIcon(status), size: 16, color: color),
                        const SizedBox(width: 6),
                        Text(
                          formatScheduleDate(day.date),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatDayGap(gap),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: color,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${day.parts.length} '
                          '${day.parts.length == 1 ? 'part' : 'parts'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final part in day.parts) _partLine(context, part),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _partLine(BuildContext context, PartScheduleLine part) {
    final theme = Theme.of(context);
    final needBy = part.needBy;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              '${trimNumber(part.line.qty)} × ${part.line.description}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              part.line.vendor?.name ?? 'no vendor',
              style: theme.textTheme.bodySmall?.copyWith(
                color: part.line.vendor == null
                    ? errorTextOn(theme.colorScheme, theme.cardColor)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              needBy == null
                  ? ''
                  // The part's own date is called out, because a delivery
                  // ahead of the job's deadline is the thing somebody has to
                  // remember and the reason this row is where it is.
                  : part.needByIsOwn
                      ? 'on site ${formatScheduleDate(needBy)} (early)'
                      : 'on site ${formatScheduleDate(needBy)}',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: part.needByIsOwn ? FontStyle.italic : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: Text(
              formatLeadTime(part.leadDays),
              textAlign: TextAlign.right,
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

/// The parts that cannot be scheduled, listed rather than left out.
///
/// A timeline that silently omits the eleven parts nobody has a lead time for
/// reads as complete while being the exact opposite, so these get a card of
/// their own at the foot with the way to fix them on it.
class _UnknownLeadTimes extends StatelessWidget {
  final ProjectSchedule schedule;
  const _UnknownLeadTimes({required this.schedule});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = schedule.unknownLines;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.help_outline, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Not on the timeline - no lead time recorded '
                    '(${lines.length})',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'These cannot be scheduled until somebody asks the vendor how '
                'long they take. Set it in the Lead time column on Core '
                'Components.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${trimNumber(l.line.qty)} × ${l.line.description}',
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        l.line.vendor?.name ?? 'no vendor',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  SETTING A PART'S LEAD TIME AND ITS OWN DATE
// ---------------------------------------------------------------------------

/// Sets the lead time and the early-delivery date for one core component.
///
/// Both on one dialog because they are one decision — "this takes six weeks
/// and it has to be in before the walls close" is a single thing somebody
/// learns from a single phone call, and splitting it across two menus would
/// mean opening two of them every time.
Future<void> showPartScheduleDialog(
  BuildContext context,
  AppStateProvider provider,
  MasterPartLine line,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _PartScheduleDialog(provider: provider, line: line),
  );
}

class _PartScheduleDialog extends StatefulWidget {
  final AppStateProvider provider;
  final MasterPartLine line;

  const _PartScheduleDialog({required this.provider, required this.line});

  @override
  State<_PartScheduleDialog> createState() => _PartScheduleDialogState();
}

class _PartScheduleDialogState extends State<_PartScheduleDialog> {
  late final TextEditingController _days = TextEditingController(
    text: widget.provider.project.partLeadTimes[widget.line.key]?.toString() ??
        '',
  );
  late DateTime? _needBy = widget.provider.project.partNeedBy[widget.line.key];
  late String _trackId =
      widget.provider.project.partTracks[widget.line.key] ?? '';
  late PartOrder _order =
      widget.provider.project.orderForPart(widget.line.key) ??
      const PartOrder();

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  void _save() {
    final text = _days.text.trim();
    // Blank means "nobody has asked yet" and is a real answer — it puts the
    // part back on the unscheduled list rather than pretending it is in stock.
    final days = text.isEmpty ? null : int.tryParse(text);
    // The part's DESCRIPTION goes with each entry, so the history still reads
    // correctly after the part is renamed or drops off the job.
    final name = widget.line.description;
    widget.provider.setProjectPartLeadTime(
      widget.line.key,
      days,
      partName: name,
    );
    widget.provider.setProjectPartNeedBy(
      widget.line.key,
      _needBy,
      partName: name,
    );
    widget.provider.setProjectPartTrack(
      widget.line.key,
      _trackId,
      partName: name,
    );
    widget.provider.setProjectPartOrder(
      widget.line.key,
      _order,
      partName: name,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The date this part actually works back from, in the same order the
    // schedule resolves it: its own, then its phase's, then the job's.
    final track = widget.provider.project.trackById(_trackId);
    final deadline =
        track?.deadline ?? widget.provider.project.deliveryDeadline;
    final typed = int.tryParse(_days.text.trim());
    final effectiveNeed = _needBy ?? deadline;
    final preview = (typed != null && effectiveNeed != null)
        ? addDays(effectiveNeed, -typed)
        : null;

    return AlertDialog(
      title: const Text('Lead time & delivery date'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.line.description,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (widget.line.model.isNotEmpty ||
                widget.line.partNumber.isNotEmpty)
              Text(
                [
                  if (widget.line.manufacturer.isNotEmpty)
                    widget.line.manufacturer,
                  if (widget.line.model.isNotEmpty) widget.line.model,
                  if (widget.line.partNumber.isNotEmpty)
                    'PN ${widget.line.partNumber}',
                ].join('  ·  '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('part_lead_days'),
              controller: _days,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Lead time (calendar days)',
                hintText: 'blank = nobody has asked the vendor yet',
                helperText: '0 means it is on the shelf. 42 is six weeks.',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            // Which delivery phase this part rides on. Above the date,
            // because picking a phase usually ANSWERS the date question —
            // most parts want their phase's date, not one of their own.
            if (widget.provider.project.tracks.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const ValueKey('part_track'),
                initialValue: _trackId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Delivered in',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('With the job'),
                  ),
                  for (final t in widget.provider.project.tracks)
                    DropdownMenuItem(
                      value: t.id,
                      child: Text(
                        t.deadline == null
                            ? t.name
                            : '${t.name} - ${formatScheduleDate(t.deadline!)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _trackId = v ?? ''),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Has to be on site by',
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('part_need_by'),
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(
                      _needBy != null
                          ? formatScheduleDate(_needBy!)
                          : deadline != null
                          ? 'With ${track?.name ?? 'the job'} - '
                                '${formatScheduleDate(deadline)}'
                          : 'With ${track?.name ?? 'the job'} '
                                '(no deadline set)',
                    ),
                    onPressed: () async {
                      final picked = await showProjectDatePicker(
                        context,
                        initial: _needBy ?? deadline,
                        title: 'On site by',
                      );
                      if (picked == null) return;
                      setState(() => _needBy = picked.date);
                    },
                  ),
                ),
                // Its own control, so backing out of the picker can never be
                // mistaken for taking the part's early date off.
                if (_needBy != null)
                  TextButton(
                    key: const ValueKey('part_need_by_clear'),
                    onPressed: () => setState(() => _needBy = null),
                    child: const Text('Use the job deadline'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Leave this on the job deadline unless the part has to arrive '
              'earlier than everything else - a screen or a mount that goes '
              'in before the walls close.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.shopping_cart_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    preview == null
                        ? 'Order by - needs a lead time and a delivery date.'
                        : 'Order by ${formatScheduleDate(preview)}'
                            '  ·  ${formatDayGap(daysBetween(today(), preview))}',
                    key: const ValueKey('part_order_preview'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: preview == null ? null : FontWeight.w600,
                      color: preview == null
                          ? theme.colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
              ],
            ),

            // --- and whether it has actually been bought -------------------
            //
            // On the same dialog as the lead time, because they are the two
            // halves of one question. Once this is filled in the part stops
            // being scheduled at all: it is bought, and the only thing left is
            // whether the vendor's date still clears the day it is needed.
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            _OrderBlock(
              order: _order,
              needBy: effectiveNeed,
              onChanged: (o) => setState(() => _order = o),
            ),

            // WHAT HAS HAPPENED TO THIS PART. The question people actually
            // ask — "it said eight weeks in March, who changed it" — and the
            // one a flat log across a nine-room job cannot answer.
            ItemHistory(
              entries: widget.provider.project.historyFor(
                AppStateProvider.projectPartItemKey(widget.line.key),
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
          key: const ValueKey('part_schedule_save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  ONE ANSWER, MANY PARTS
// ---------------------------------------------------------------------------

/// Sets one lead time - and one on-site date, and one phase - across a whole
/// selection of parts.
///
/// WHY THIS EXISTS. A lead time is learned one phone call at a time and it is
/// almost never learned about one PART: the answer that comes back is "six to
/// eight weeks on anything of ours", for a vendor with nineteen lines on the
/// job. Typed one row at a time that is nineteen dialogs, and what actually
/// happened is that the first three got the figure and the rest stayed blank -
/// which reads on the timeline as sixteen parts nobody has to think about.
///
/// EVERY FIELD IS OPTIONAL, AND UNTOUCHED MEANS UNTOUCHED. A bulk edit that
/// wrote all three fields whether or not they were filled in would quietly
/// wipe the early on-site date somebody set on the two screens in the
/// selection, and there is nothing on the screen afterwards that would say so.
Future<void> showBulkPartScheduleDialog(
  BuildContext context,
  AppStateProvider provider,
  List<MasterPartLine> lines, {
  /// What the selection IS, when it is a group rather than a hand-picked set -
  /// 'Extron', 'Parts with no lead time'. Shown so the dialog says what it is
  /// about to change rather than only how many.
  String scopeLabel = '',
}) async {
  if (lines.isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _BulkPartScheduleDialog(
      provider: provider,
      lines: lines,
      scopeLabel: scopeLabel,
    ),
  );
}

class _BulkPartScheduleDialog extends StatefulWidget {
  final AppStateProvider provider;
  final List<MasterPartLine> lines;
  final String scopeLabel;

  const _BulkPartScheduleDialog({
    required this.provider,
    required this.lines,
    required this.scopeLabel,
  });

  @override
  State<_BulkPartScheduleDialog> createState() =>
      _BulkPartScheduleDialogState();
}

class _BulkPartScheduleDialogState extends State<_BulkPartScheduleDialog> {
  /// Which of the three fields this edit is about.
  ///
  /// The lead time is on, because it is what somebody opened this for. The
  /// other two are off: they are the fields a bulk edit can do real damage
  /// with, and each one has to be asked for.
  bool _setLead = true;
  bool _setNeedBy = false;
  bool _setTrack = false;

  final TextEditingController _days = TextEditingController();
  DateTime? _needBy;
  String _trackId = '';

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  /// True when at least one field is armed - what Apply is gated on.
  bool get _anything => _setLead || _setNeedBy || _setTrack;

  int get _count => widget.lines.length;

  void _apply() {
    final text = _days.text.trim();
    // Blank means "nobody has asked the vendor yet", exactly as it does on the
    // single-part dialog: it puts them back on the unscheduled list rather
    // than pretending they are in stock.
    final days = text.isEmpty ? null : int.tryParse(text);

    for (final line in widget.lines) {
      // The part's DESCRIPTION goes into each history entry, so the trail
      // still reads correctly after the part is renamed or drops off the job.
      final name = line.description;
      if (_setLead) {
        widget.provider.setProjectPartLeadTime(line.key, days, partName: name);
      }
      if (_setNeedBy) {
        widget.provider.setProjectPartNeedBy(line.key, _needBy, partName: name);
      }
      if (_setTrack) {
        widget.provider.setProjectPartTrack(line.key, _trackId, partName: name);
      }
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = widget.provider.project;
    final track = _setTrack ? project.trackById(_trackId) : null;
    final deadline = track?.deadline ?? project.deliveryDeadline;
    final typed = int.tryParse(_days.text.trim());
    final effectiveNeed = (_setNeedBy ? _needBy : null) ?? deadline;
    final preview = (_setLead && typed != null && effectiveNeed != null)
        ? addDays(effectiveNeed, -typed)
        : null;
    final plural = _count == 1 ? '' : 's';

    /// One armed field: the box that turns it on, and the control it turns on.
    ///
    /// Greyed rather than hidden, so the dialog does not resize itself under
    /// the pointer every time a box is ticked - and so somebody can see what
    /// the other two fields WOULD do before deciding to use them.
    Widget field({
      required String label,
      required bool on,
      required ValueChanged<bool> onChanged,
      required Widget child,
      Key? boxKey,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Checkbox(
              key: boxKey,
              value: on,
              onChanged: (v) => setState(() => onChanged(v ?? false)),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                IgnorePointer(
                  ignoring: !on,
                  child: Opacity(opacity: on ? 1 : 0.45, child: child),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return AlertDialog(
      key: const ValueKey('bulk_part_schedule_dialog'),
      title: Text('Lead time for $_count part$plural'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // WHAT IS ABOUT TO CHANGE, NAMED. A bulk edit whose scope is
              // only a count is one nobody can check before pressing it, and
              // this one writes to every part on the list at once.
              if (widget.scopeLabel.trim().isNotEmpty)
                Text(
                  widget.scopeLabel.trim(),
                  key: const ValueKey('bulk_scope_label'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                _named,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              field(
                label: 'Lead time (calendar days)',
                on: _setLead,
                boxKey: const ValueKey('bulk_lead_on'),
                onChanged: (v) => _setLead = v,
                child: TextField(
                  key: const ValueKey('bulk_lead_days'),
                  controller: _days,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    hintText: 'blank puts them all back to "not asked"',
                    helperText: '0 means on the shelf. 42 is six weeks.',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              field(
                label: 'Has to be on site by',
                on: _setNeedBy,
                boxKey: const ValueKey('bulk_needby_on'),
                onChanged: (v) => _setNeedBy = v,
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('bulk_need_by'),
                        icon: const Icon(Icons.event, size: 18),
                        label: Text(
                          _needBy != null
                              ? formatScheduleDate(_needBy!)
                              : 'Back to the job deadline',
                        ),
                        onPressed: () async {
                          final picked = await showProjectDatePicker(
                            context,
                            initial: _needBy ?? deadline,
                            title: 'On site by',
                          );
                          if (picked == null) return;
                          setState(() => _needBy = picked.date);
                        },
                      ),
                    ),
                    if (_needBy != null)
                      TextButton(
                        key: const ValueKey('bulk_need_by_clear'),
                        onPressed: () => setState(() => _needBy = null),
                        child: const Text('Use the deadline'),
                      ),
                  ],
                ),
              ),
              if (project.tracks.isNotEmpty)
                field(
                  label: 'Delivered in',
                  on: _setTrack,
                  boxKey: const ValueKey('bulk_track_on'),
                  onChanged: (v) => _setTrack = v,
                  child: DropdownButtonFormField<String>(
                    key: const ValueKey('bulk_track'),
                    initialValue: _trackId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('With the job'),
                      ),
                      for (final t in project.tracks)
                        DropdownMenuItem(
                          value: t.id,
                          child: Text(
                            t.deadline == null
                                ? t.name
                                : '${t.name} - '
                                      '${formatScheduleDate(t.deadline!)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _trackId = v ?? ''),
                  ),
                ),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.shopping_cart_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preview == null
                          ? 'Order by - needs a lead time and a delivery date.'
                          : 'Ordered by ${formatScheduleDate(preview)}'
                                '  ·  '
                                '${formatDayGap(daysBetween(today(), preview))}',
                      key: const ValueKey('bulk_order_preview'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: preview == null ? null : FontWeight.w600,
                        color: preview == null
                            ? theme.colorScheme.onSurfaceVariant
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // The parts carrying their OWN on-site date do not land on that
              // date, and saying so here is cheaper than somebody finding it
              // out from the timeline afterwards.
              if (!_setNeedBy)
                Text(
                  'Parts that carry their own on-site date keep it, so those '
                  'order earlier than the date above.',
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
          key: const ValueKey('bulk_part_schedule_save'),
          onPressed: _anything ? _apply : null,
          child: Text('Apply to $_count part$plural'),
        ),
      ],
    );
  }

  /// The first few by name, then a count.
  ///
  /// NAMED RATHER THAN COUNTED. "19 parts" is a number somebody has to trust;
  /// four names and "and 15 more" is a selection they can recognise as the one
  /// they meant to make.
  String get _named {
    const shown = 4;
    final names = widget.lines.take(shown).map((l) => l.description).join(', ');
    if (_count <= shown) return names;
    return '$names, and ${_count - shown} more';
  }
}

/// What a phase looks like under the pointer while it is being moved.
///
/// A label rather than the card itself: the card is 252 wide and carries three
/// lines of dates, and a full-size copy of it following the cursor covers the
/// phases it is being dropped between.
class _DragLabel extends StatelessWidget {
  final String name;

  const _DragLabel({required this.name});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Opacity(
        opacity: 0.9,
        child: Chip(
          avatar: const Icon(Icons.alt_route, size: 16),
          label: Text(name),
          backgroundColor: theme.colorScheme.secondaryContainer,
        ),
      ),
    );
  }
}
