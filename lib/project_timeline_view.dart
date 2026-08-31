import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show formatMoney, trimNumber;
import 'name_colors.dart' show projectVendorColor;
import 'project_deliveries_view.dart' show PoFileButtons, showPoPartsDialog;
import 'equipment_lifecycle.dart'
    show RoomLifecycle, buildProjectLifecycle, formatLifecycleMoney;
import 'pinned_grid.dart'
    show
        GridZoomControls,
        gridMetric,
        kGridZoomNormal,
        kTimelineZoomSteps;
import 'project_estimate.dart';
import 'project_history_view.dart' show ItemHistory;
import 'project_reminders.dart';
import 'project_schedule.dart';
import 'stepped_date_picker.dart';
import 'vendor_rfq_view.dart';

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
    // The dates a refresh plan does have - its phases and its delivery date -
    // on the same rail the priced jobs get. It draws nothing until there are
    // two of them, so a plan nobody has dated is unchanged.
    SliverToBoxAdapter(
      child: ProjectDateGraph(
        schedule: schedule,
        project: provider.project,
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
    // THE WHOLE JOB AS ONE LINE, before the counts and the cards it is made
    // of. See [ProjectDateGraph]: the dates below are a list, and a list is
    // the one shape that cannot show how far apart two dates are.
    SliverToBoxAdapter(
      child: ProjectDateGraph(
        schedule: schedule,
        project: provider.project,
      ),
    ),
    SliverToBoxAdapter(
      child: _TimelineSummary(schedule: schedule, provider: provider),
    ),
    SliverToBoxAdapter(
      child: _ReminderBar(estimate: estimate, schedule: schedule),
    ),
    // WHAT HAS ALREADY GONE, before the dates that have not. See
    // [_QuoteRequests] and [_PlacedOrders]: the rest of this pane is a list of
    // deadlines, and an RFQ that went out last week is not a deadline.
    SliverToBoxAdapter(child: _QuoteRequests(estimate: estimate)),
    SliverToBoxAdapter(child: _PlacedOrders(estimate: estimate)),
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

// ---------------------------------------------------------------------------
//  WHAT IS OUT WITH THE VENDORS
// ---------------------------------------------------------------------------
//  A quote request is a DATE somebody is waiting on, which makes it the same
//  kind of thing as everything else on this pane and it was on none of it. The
//  Vendors pane knows perfectly well that the Extron RFQ went out on the 4th
//  and has never been answered; the timeline - the screen somebody opens to
//  ask "what is late" - did not, so the answer to "are we waiting on anybody"
//  was a second pane and a memory of which vendors there are.
//
//  So every vendor whose RFQ has gone ANYWHERE is here: sent and unanswered,
//  quoted and undecided, or ordered. It is the VENDOR's story. The block under
//  it is the PURCHASE ORDER's, which is a different question with a different
//  answer - a PO raised outside any vendor is there and not here, and a vendor
//  whose PO was renumbered is here and not there.

/// One vendor's RFQ, with what the job thinks the package is worth.
typedef _QuoteRequest = ({
  ProjectVendor vendor,
  Color tint,
  VendorPackage? package,

  /// The date the row is READ BY: the latest thing that happened to it. What
  /// the sort runs on.
  DateTime? on,
});

/// Every vendor with an RFQ out, the one that needs looking at first at the
/// top.
///
/// SENT BEFORE QUOTED BEFORE ORDERED, and inside each, OLDEST FIRST. The order
/// is the question being asked: an RFQ sent three weeks ago and never answered
/// is the thing to chase, and a quote that came back a month ago and has not
/// turned into an order is the thing going stale. Newest-first - which is the
/// right sort for the order log below, where the question is "what just
/// happened" - would bury both.
List<_QuoteRequest> _quoteRequests(
  BuildingProject project,
  ProjectEstimate estimate,
) {
  final rows = <_QuoteRequest>[];
  for (final vendor in project.vendors) {
    if (vendor.rfqStage == VendorRfqStage.none) continue;
    rows.add((
      vendor: vendor,
      tint: projectVendorColor(vendor),
      package: estimate.packageFor(vendor.id),
      on: vendor.orderedOn ?? vendor.quotedOn ?? vendor.rfqSentOn,
    ));
  }
  rows.sort((a, b) {
    final byStage = a.vendor.rfqStage.index.compareTo(b.vendor.rfqStage.index);
    if (byStage != 0) return byStage;
    final ad = a.on;
    final bd = b.on;
    // A stage with no date on it has not really happened yet as far as the
    // paperwork goes, so it sorts last rather than reading as the oldest.
    if (ad == null && bd == null) {
      return a.vendor.name.toLowerCase().compareTo(b.vendor.name.toLowerCase());
    }
    if (ad == null) return 1;
    if (bd == null) return -1;
    final byDate = ad.compareTo(bd);
    return byDate != 0
        ? byDate
        : a.vendor.name.toLowerCase().compareTo(b.vendor.name.toLowerCase());
  });
  return rows;
}

/// The block of quote requests that are out with somebody.
class _QuoteRequests extends StatelessWidget {
  final ProjectEstimate estimate;

  const _QuoteRequests({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final rows = _quoteRequests(provider.project, estimate);
    // Nothing has gone out yet, which is the ordinary state of a job being
    // priced. A heading over an empty box would be one more thing to read.
    if (rows.isEmpty) return const SizedBox.shrink();

    final waiting = [
      for (final r in rows)
        if (r.vendor.rfqStage == VendorRfqStage.sent) r,
    ].length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
            child: Text(
              waiting == 0
                  ? 'QUOTE REQUESTS (${rows.length})'
                  : 'QUOTE REQUESTS (${rows.length}) - $waiting UNANSWERED',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final row in rows)
            _QuoteRequestCard(row: row, estimate: estimate),
        ],
      ),
    );
  }
}

class _QuoteRequestCard extends StatelessWidget {
  final _QuoteRequest row;
  final ProjectEstimate estimate;

  const _QuoteRequestCard({required this.row, required this.estimate});

  /// How long this has been sitting, said the way somebody says it out loud.
  static String _waited(DateTime since, DateTime asOf) {
    final days = asOf.difference(since).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return '1 day';
    if (days < 21) return '$days days';
    return '${(days / 7).floor()} weeks';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final muted = theme.colorScheme.onSurfaceVariant;
    final vendor = row.vendor;
    final stage = vendor.rfqStage;
    final package = row.package;
    final quote = vendor.quoteFilePath.trim();

    // THE WAIT, on the two stages where waiting is the question being asked.
    // An order that went in four months ago is not "119 days out" - it is
    // delivered or it is late, and the blocks below answer that.
    final since = switch (stage) {
      VendorRfqStage.sent => vendor.rfqSentOn,
      VendorRfqStage.quoted => vendor.quotedOn,
      _ => null,
    };
    final waited = since == null
        ? ''
        : stage == VendorRfqStage.sent
        ? 'out ${_waited(since, today())} with no answer'
        : 'in ${_waited(since, today())}, not ordered';

    return Card(
      key: ValueKey('timeline_rfq_${vendor.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      // The card wears the vendor's colour, the same one its parts carry on
      // the master list and its order carries below - so the three lists are
      // visibly the same four vendors rather than three to cross-reference by
      // name.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: row.tint.withValues(alpha: 0.85), width: 1.4),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(rfqIcon(stage), size: 18, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vendor.name.trim().isEmpty
                            ? '(unnamed vendor)'
                            : vendor.name.trim(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // The whole story as one sentence, said exactly the way
                      // the vendor card says it - see [vendorRfqSentence].
                      Text(
                        vendorRfqSentence(vendor),
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                VendorRfqChip(vendor: vendor),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (waited.isNotEmpty) waited,
                if (package != null)
                  '${package.lines.length} part'
                      '${package.lines.length == 1 ? '' : 's'} - '
                      '${formatMoney(package.total, estimate.currency)} at the '
                      'job\'s own prices'
                else
                  'nothing on the job is tagged to this vendor',
              ].join('  ·  '),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            // THE PAPER, one press from the row it belongs to. Attached on the
            // Vendors pane at the moment the quote came back; read here, which
            // is where somebody is asking what it said.
            if (quote.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: ValueKey('timeline_rfq_quote_${vendor.id}'),
                  icon: Icon(
                    quoteDrawableHere(quote)
                        ? Icons.picture_as_pdf
                        : Icons.description_outlined,
                    size: 18,
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      path.basename(quote),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onPressed: () => openVendorQuoteFile(
                    context,
                    provider,
                    stored: quote,
                    vendorName: vendor.name,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  WHAT HAS ALREADY BEEN BOUGHT
// ---------------------------------------------------------------------------
//  Everything else on this pane is a date in the FUTURE: order by the 4th, or
//  the job is late. That is the right shape for planning and it says nothing
//  at all about the half of the job that has already gone out, which on a live
//  project is most of the anxiety - "did the Extron order actually go, and what
//  was on it".
//
//  So the orders that HAVE been placed get a block of their own at the top,
//  before the ones that have not. One row per purchase order: the number, who
//  it went to, when, what it was raised for, how many parts are on it - and the
//  two ways in that were missing entirely, which are the equipment it bought
//  and the order itself as a document.
//
//  IT IS BUILT FROM THE PURCHASE ORDERS, not from the vendor rows. A PO raised
//  from the Deliveries pane, one marked from a vendor card, and one typed onto
//  a single part all end up as the same row - see [ProjectPo] on why the LINK
//  is the number rather than a row id.

/// The purchase orders on the job, newest first, with what each one holds.
///
/// A record rather than a class: it is a row on a summary, it is rebuilt every
/// time the pane is drawn, and nothing stores it.
typedef _PlacedOrder = ({
  ProjectPo po,

  /// Who it went to, resolved: the vendor on the job's list, or whatever was
  /// typed on the PO.
  String vendorName,

  /// The vendor's colour, so the row is marked the same way its parts are on
  /// the master list. Null when the PO went somewhere that is not one of the
  /// job's vendors.
  Color? tint,

  /// Part keys bought on it, and how many of those are marked arrived.
  int parts,
  int received,
});

List<_PlacedOrder> _placedOrders(BuildingProject project) {
  final rows = <_PlacedOrder>[];
  for (final po in project.purchaseOrders) {
    final parts = project.partsOnPo(po.number);
    final vendor = po.vendorId.isEmpty ? null : project.vendorById(po.vendorId);
    rows.add((
      po: po,
      vendorName: vendor?.name.trim() ?? po.vendor.trim(),
      tint: vendor == null ? null : projectVendorColor(vendor),
      parts: parts.length,
      received: [
        for (final key in parts)
          if (project.orderForPart(key)?.isReceived == true) key,
      ].length,
    ));
  }
  // Newest first: an order log is read from the top, and what went out this
  // week is what somebody is asking about. A PO with no date on it has not
  // been raised yet as far as the paperwork goes, so it sorts last rather
  // than first.
  rows.sort((a, b) {
    final ad = a.po.issuedOn;
    final bd = b.po.issuedOn;
    if (ad == null && bd == null) return b.po.id.compareTo(a.po.id);
    if (ad == null) return 1;
    if (bd == null) return -1;
    final byDate = bd.compareTo(ad);
    return byDate != 0 ? byDate : b.po.id.compareTo(a.po.id);
  });
  return rows;
}

/// The block of orders that have already gone.
class _PlacedOrders extends StatelessWidget {
  final ProjectEstimate estimate;

  const _PlacedOrders({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final rows = _placedOrders(provider.project);
    // Nothing has been ordered yet, which is the ordinary state of a job being
    // planned. A heading over an empty box would be one more thing to read.
    if (rows.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
            child: Text(
              'ORDERED (${rows.length})',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final row in rows)
            _PlacedOrderCard(row: row, estimate: estimate),
        ],
      ),
    );
  }
}

class _PlacedOrderCard extends StatelessWidget {
  final _PlacedOrder row;
  final ProjectEstimate estimate;

  const _PlacedOrderCard({required this.row, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final muted = theme.colorScheme.onSurfaceVariant;
    final po = row.po;
    final tint = row.tint;

    return Card(
      key: ValueKey('timeline_order_${po.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      // The card wears the vendor's colour, the same one its parts carry on
      // the master list - so this block and that list are visibly the same
      // four orders rather than two lists to cross-reference by name.
      shape: tint == null
          ? null
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: tint.withValues(alpha: 0.85), width: 1.4),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.receipt_long, size: 18, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        po.number.trim().isEmpty ? 'PO' : po.number.trim(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        [
                          if (row.vendorName.isNotEmpty) row.vendorName,
                          if (po.issuedOn != null)
                            'ordered ${formatScheduleDate(po.issuedOn!)}',
                          if (po.expectedOn != null)
                            'promised ${formatScheduleDate(po.expectedOn!)}',
                          if (po.amount > 0)
                            formatMoney(po.amount, estimate.currency),
                        ].join('  ·  '),
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              row.parts == 0
                  ? 'Nothing on the job points at this PO yet. Open it to tick '
                        'the equipment it bought.'
                  : '${row.parts} part${row.parts == 1 ? '' : 's'} bought on it '
                        '- ${row.received} marked arrived.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // THE LINK BACK TO THE EQUIPMENT. The whole reason this block
                // is on the timeline rather than only on the Deliveries pane:
                // a PO number that cannot be followed to what it bought is a
                // number, not a record.
                OutlinedButton.icon(
                  key: ValueKey('timeline_order_parts_${po.id}'),
                  icon: const Icon(Icons.playlist_add_check, size: 18),
                  label: Text(
                    row.parts == 0
                        ? 'Put equipment on this PO'
                        : 'Equipment on this PO (${row.parts})',
                  ),
                  onPressed: () => showPoPartsDialog(
                    context,
                    provider: provider,
                    estimate: estimate,
                    po: po,
                  ),
                ),
                PoFileButtons(po: po, provider: provider),
              ],
            ),
          ],
        ),
      ),
    );
  }
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

  /// The PO numbers this job already mentions - see
  /// [BuildingProject.poNumbersInUse]. Offered beside the field so a number
  /// that has already been typed on nine other parts is picked rather than
  /// retyped, which is how one PO ends up on a job under three spellings.
  final List<String> poNumbers;

  const _OrderBlock({
    required this.order,
    required this.needBy,
    required this.onChanged,
    this.poNumbers = const [],
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
                decoration: InputDecoration(
                  labelText: 'PO number',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: widget.poNumbers.isEmpty
                      ? null
                      : PopupMenuButton<String>(
                          key: const ValueKey('part_po_pick'),
                          tooltip: 'Pick a purchase order on the job',
                          icon: const Icon(Icons.arrow_drop_down),
                          itemBuilder: (_) => [
                            for (final n in widget.poNumbers)
                              PopupMenuItem(value: n, child: Text(n)),
                          ],
                          onSelected: (n) {
                            _po.text = n;
                            widget.onChanged(order.copyWith(poNumber: n));
                          },
                        ),
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

/// What of this part is on site, and how much of that is in a room.
///
/// Nothing when no arrival has been logged against it: a job that does not
/// track deliveries should not grow a line on this dialog saying it has none.
class _DeliveredHere extends StatelessWidget {
  final AppStateProvider provider;
  final String partKey;

  /// How many the job is buying, so 'on site' can be read against something.
  final double ordered;

  const _DeliveredHere({
    required this.provider,
    required this.partKey,
    required this.ordered,
  });

  @override
  Widget build(BuildContext context) {
    final project = provider.project;
    final rows = project.deliveriesForPart(partKey);
    if (rows.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final here = project.deliveredQty(partKey);
    final installed = project.installedQty(partKey);
    final waiting = here - installed;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory, size: 18, color: muted),
              const SizedBox(width: 8),
              Text('On site', style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              '${formatUnits(here)} of ${formatUnits(ordered)} arrived',
              if (installed > 0) '${formatUnits(installed)} installed',
              if (waiting > 0) '${formatUnits(waiting)} not in a room yet',
            ].join('  ·  '),
            key: const ValueKey('part_delivered_summary'),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          for (final row in rows.take(4))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                [
                  if (row.deliveredOn != null)
                    formatScheduleDate(row.deliveredOn!),
                  if (formatUnits(row.qty).isNotEmpty)
                    '${formatUnits(row.qty)} units',
                  // The code on the door - 'BSS 103' - the way every other
                  // pane names a room, rather than the config's file stem.
                  row.state == DeliveryState.installed &&
                          provider.projectRoomCode(row.roomId).isNotEmpty
                      ? 'installed in '
                            '${provider.projectRoomCode(row.roomId)}'
                      : row.whereText,
                ].join(' - '),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          if (rows.length > 4)
            Text(
              '+${rows.length - 4} more on the Deliveries pane',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
        ],
      ),
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


// ---------------------------------------------------------------------------
//  THE DATES, ON ONE LINE
// ---------------------------------------------------------------------------
//  Everything else on this tab is a LIST: the order days down the page, a card
//  each, a phase strip across the top. That is the right shape for working
//  FROM - a card is a trip to the purchasing office - and the wrong shape for
//  the question that gets asked first, which is when this job actually
//  happens. Nine cards do not say whether the first order is next week or in
//  March, nor whether the infrastructure phase lands before the walls close,
//  because a list has no distance in it: two dates a fortnight apart and two a
//  year apart are one row apart either way.
//
//  So the same dates are drawn once, in order, on one rail: today, the first
//  order, every order date as a dot, each phase's on-site day, and the day the
//  job is due. NOTHING HERE IS A NEW FACT - every date on it is one of the
//  cards below - which is exactly the point. It is the same schedule seen from
//  far enough away to have a shape.

/// One date the graph points at, and the words that go beside it.
typedef _DateMark = ({DateTime date, String label, Color color});

/// A callout's size before the reader's text size is applied, the lanes they
/// stack in, and the gap that counts as clear.
///
/// Constants because the painter and the callouts have to agree to the pixel:
/// a stem drawn to a lane no card is in is a line pointing at nothing.
const double _kMarkWidth = 128;
const double _kMarkHeight = 44;

/// FOUR RATHER THAN THREE, since the vendors' quote requests came onto the
/// rail. On a six-vendor job the RFQ dates cluster - they all went out the
/// same week - and three lanes put two of them on top of each other. Zooming
/// in is the real answer to a cluster; a fourth lane is what keeps the fitted
/// view honest until somebody does.
const int _kMarkLanes = 4;
const double _kMarkGap = 6;

/// How much rail one month label needs to itself before the months thin out.
const double _kMonthLabelWidth = 56;

/// The whole schedule as one line, above the cards it is made of.
///
/// Hidden rather than empty when there is nothing to draw. A rail with one
/// date on it is not a graph - it is a date with a line through it - so the
/// graph appears once there are two, which is also the first moment the
/// distance between them means anything.
class ProjectDateGraph extends StatefulWidget {
  final ProjectSchedule schedule;
  final BuildingProject project;

  const ProjectDateGraph({
    super.key,
    required this.schedule,
    required this.project,
  });

  @override
  State<ProjectDateGraph> createState() => _ProjectDateGraphState();
}

/// ============================================================================
///  A RAIL THAT IS SIX YEARS LONG AND HAS TO BE READ BY THE WEEK
/// ============================================================================
///  The rail always fitted the whole job into the width of the card, which is
///  the right default and was for a long time the only thing it did. On a
///  campus refresh that runs three years, one pixel of it is four days: every
///  order date in a fortnight is one dot, the four RFQs that went out in March
///  are one dot, and the question somebody actually has - "does the conduit
///  order go in before or after the walls close" - is a question about a gap
///  narrower than the dot drawn over it.
///
///  So the rail zooms. FITTED IS STILL THE DEFAULT and still the whole job;
///  from there it goes in as far as thirty-two times, at which point three
///  years of rail is about six weeks in the frame, and it scrolls sideways
///  under a bar. See [kTimelineZoomSteps].
///
///  ZOOMING HOLDS THE MIDDLE OF THE FRAME. A zoom that jumped back to January
///  every time would make the arrows useless for the thing they are for, which
///  is looking harder at the fortnight already on screen.
class _ProjectDateGraphState extends State<ProjectDateGraph> {
  /// How far in the rail is read at. 1 is the whole job in the frame - see
  /// [kTimelineZoomSteps], which does not go below it.
  double _zoom = kGridZoomNormal;

  final ScrollController _scroll = ScrollController();

  ProjectSchedule get schedule => widget.schedule;
  BuildingProject get project => widget.project;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Where the middle of the frame is, as a fraction of the whole rail. What a
  /// zoom is anchored on.
  double _centreFraction() {
    if (!_scroll.hasClients) return 0;
    final view = _scroll.position.viewportDimension;
    final whole = view + _scroll.position.maxScrollExtent;
    if (whole <= 0) return 0;
    return ((_scroll.offset + view / 2) / whole).clamp(0.0, 1.0);
  }

  /// Puts [fraction] of the rail back under the middle of the frame.
  void _centreOn(double fraction) {
    if (!_scroll.hasClients) return;
    final view = _scroll.position.viewportDimension;
    final whole = view + _scroll.position.maxScrollExtent;
    _scroll.jumpTo(
      (fraction * whole - view / 2).clamp(0.0, _scroll.position.maxScrollExtent),
    );
  }

  void _setZoom(double zoom) {
    // Read BEFORE the rail changes width, put back AFTER it has been laid out
    // at the new one.
    final centre = _centreFraction();
    setState(() => _zoom = zoom);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _centreOn(centre);
    });
  }

  /// The whole job back in the frame, from wherever somebody had got to.
  void _fitAll() {
    setState(() => _zoom = kGridZoomNormal);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  /// The dates worth a label. Order days are on the rail as dots - there can
  /// be thirty of them and a name on each is a graph nobody can read - so what
  /// gets named is the handful somebody actually diarises.
  List<_DateMark> _marks(BuildContext context) {
    final theme = Theme.of(context);
    final out = <_DateMark>[
      (
        date: schedule.asOf,
        label: 'Today',
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ];

    // The day the job starts, as opposed to the day it is due. Coloured by
    // what that order actually is: a first order already behind is the whole
    // reading, and a rail that drew it in the same ink as the rest would bury
    // it.
    final firstOrder = schedule.firstOrderDate;
    if (firstOrder != null) {
      out.add((
        date: firstOrder,
        label: 'First order',
        color: orderStatusColor(
          context,
          schedule.lateCount > 0
              ? OrderStatus.late
              : schedule.dueSoonCount > 0
                  ? OrderStatus.dueSoon
                  : OrderStatus.onTrack,
        ),
      ));
    }

    // THE PHASES, each on its own day. The reading this graph exists for: the
    // infrastructure going in months before the tech, and whether the two
    // actually line up with when the walls close.
    for (final track in project.tracks) {
      final deadline = track.deadline;
      if (deadline != null) {
        out.add((
          date: deadline,
          label: '${track.name} on site',
          color: theme.colorScheme.tertiary,
        ));
      }
      final done = track.completion;
      if (done != null) {
        out.add((
          date: done,
          label: '${track.name} finished',
          color: theme.colorScheme.primary,
        ));
      }
    }

    final deadline = schedule.deadline;
    if (deadline != null) {
      out.add((
        date: deadline,
        label: 'Delivery deadline',
        color: schedule.lateCount > 0
            ? errorTextOn(theme.colorScheme, theme.cardColor)
            : theme.colorScheme.primary,
      ));
    }

    // WHERE EACH VENDOR HAS GOT TO, ON THE SAME RAIL AS EVERYTHING ELSE.
    //
    // An RFQ is a date somebody is waiting on, and the block below reads it as
    // a list - which has the failing every list on this pane has: no distance
    // in it. "Extron quoted on the 11th and the conduit order goes in on the
    // 14th" is three days or three months apart depending on the year, and the
    // list says the same thing either way.
    //
    // ONE MARK PER VENDOR, on its LATEST date, because that is where the
    // vendor actually is - the same reading the QUOTE REQUESTS block gives.
    // Every date in a vendor's history on the rail would be three cards per
    // vendor saying what one card says.
    //
    // IN THE VENDOR'S OWN COLOUR, the one its parts carry on the master list
    // and its order carries below. The callout draws the colour as a fill at
    // 12% behind text in onSurface, so it is a second way to read the rail and
    // never the only one - the words say which vendor it is too.
    for (final vendor in project.vendors) {
      final tint = projectVendorColor(vendor);
      final name = vendor.name.trim().isEmpty ? 'Vendor' : vendor.name.trim();
      switch (vendor.rfqStage) {
        case VendorRfqStage.none:
          break;
        case VendorRfqStage.sent:
          out.add((date: vendor.rfqSentOn!, label: '$name RFQ out', color: tint));
        case VendorRfqStage.quoted:
          out.add((date: vendor.quotedOn!, label: '$name quoted', color: tint));
        case VendorRfqStage.ordered:
          // An ordered vendor without a date is one somebody typed a PO number
          // against - real, and not a point on a calendar.
          final on = vendor.orderedOn;
          if (on != null) {
            out.add((date: on, label: '$name ordered', color: tint));
          }
      }
    }

    // The same date under the same name twice is one card, not two on top of
    // each other.
    final seen = <String>{};
    return [
      for (final mark in out)
        if (seen.add('${formatIsoDate(mark.date)}|${mark.label}')) mark,
    ]..sort((a, b) => a.date.compareTo(b.date));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final marks = _marks(context);
    final days = schedule.orderDays;

    var first = schedule.asOf;
    var last = schedule.asOf;
    for (final date in [
      for (final m in marks) m.date,
      for (final d in days) d.date,
    ]) {
      if (date.isBefore(first)) first = date;
      if (date.isAfter(last)) last = date;
    }
    final span = daysBetween(first, last);
    if (span <= 0 || marks.length < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        key: const ValueKey('timeline_date_graph'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'THE DATES',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${formatScheduleDate(first)}  to  '
                      '${formatScheduleDate(last)}'
                      '${days.isEmpty ? '' : '  ·  ${days.length} order '
                          'date${days.length == 1 ? '' : 's'}'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // HOW FAR IN THE RAIL IS READ AT, said as a stretch of time
                  // rather than as a multiplier: '6 weeks' is the number
                  // somebody wants off a calendar, and '800%' is the number
                  // they would have to divide the job by to get it.
                  GridZoomControls(
                    keyPrefix: 'timeline_graph',
                    zoom: _zoom,
                    steps: kTimelineZoomSteps,
                    levelLabel: _spanLabel(span, _zoom),
                    zoomOutTooltip: 'A longer stretch of the job in the frame',
                    zoomInTooltip: 'A shorter stretch, read closer',
                    fitted: _zoom == kGridZoomNormal,
                    onFit: _fitAll,
                    onChanged: _setZoom,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // THE RAIL SCROLLS ONCE IT IS LONGER THAN THE CARD. Fitted it
              // never is, and the bar stays out of the way; zoomed it is the
              // only way to reach March, so the bar is always shown rather
              // than fading in on a gesture nobody made yet.
              LayoutBuilder(
                builder: (context, box) {
                  final plotWidth = box.maxWidth * _zoom;
                  final plot = _plot(
                    context,
                    width: plotWidth,
                    marks: marks,
                    first: first,
                    span: span,
                  );
                  if (_zoom == kGridZoomNormal) return plot;
                  return Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SizedBox(width: plotWidth, child: plot),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// HOW MUCH OF THE JOB IS IN FRONT OF SOMEBODY, in the unit they would say
  /// it in. Kept to four characters or so, because it sits in a fixed box
  /// between two arrows that must not shuffle sideways as it changes.
  static String _spanLabel(int span, double zoom) {
    final days = (span / zoom).round();
    if (days <= 0) return '1 d';
    if (days < 21) return '$days d';
    if (days < 120) return '${(days / 7).round()} wk';
    if (days < 730) return '${(days / 30.44).round()} mo';
    final years = days / 365.25;
    return '${years.toStringAsFixed(years < 10 ? 1 : 0)} yr';
  }

  /// The rail and everything on it, at the height this particular job needs.
  ///
  /// SIZED FROM WHAT IT HOLDS rather than from the worst case. A job with a
  /// deadline and one order date needs one lane of cards; reserving three on
  /// every job would put two empty lanes of white above the commonest rail
  /// there is, at the top of a tab whose first screen is the point.
  Widget _plot(
    BuildContext context, {
    required double width,
    required List<_DateMark> marks,
    required DateTime first,
    required int span,
  }) {
    final theme = Theme.of(context);
    final markWidth = gridMetric(context, _kMarkWidth);
    final markHeight = gridMetric(context, _kMarkHeight);
    final lane = markHeight + _kMarkGap;

    // The rail stops short of both edges, so a dot on the last day is a dot on
    // the rail rather than half a dot over the border.
    const pad = 10.0;
    final plot = (width - pad * 2).clamp(1.0, double.infinity);
    double xOf(DateTime date) =>
        pad + (daysBetween(first, date) / span).clamp(0.0, 1.0) * plot;

    // WHICH LANE EACH CALLOUT SITS IN, worked out left to right: a card takes
    // the first lane whose last card has already finished, so two dates a week
    // apart stack instead of printing over each other. Lane 0 ends up nearest
    // the rail, which is where the commonest case - a rail that needs one lane
    // - should be.
    final used = List<double>.filled(_kMarkLanes, -1e9);
    final placed = <({_DateMark mark, double left, int lane})>[];
    for (final mark in marks) {
      final left = (xOf(mark.date) - markWidth / 2)
          .clamp(0.0, (width - markWidth).clamp(0.0, width));
      // Every lane still occupied: the card goes in whichever clears soonest,
      // which is the least bad overlap on offer.
      var slot = 0;
      var fallback = 0;
      var clear = false;
      for (var i = 0; i < _kMarkLanes; i++) {
        if (used[i] < left - _kMarkGap) {
          slot = i;
          clear = true;
          break;
        }
        if (used[i] < used[fallback]) fallback = i;
      }
      if (!clear) slot = fallback;
      used[slot] = left + markWidth;
      placed.add((mark: mark, left: left, lane: slot));
    }

    final lanes = placed.fold<int>(1, (m, p) => p.lane + 1 > m ? p.lane + 1 : m);
    // Lane 0 nearest the rail, counting up from it.
    double topOf(int slot) => (lanes - 1 - slot) * lane;
    final railY = lanes * lane + 2;
    final ticks = _monthTicks(first, span, plot, xOf);

    return SizedBox(
      height: railY + gridMetric(context, 26),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DateGraphPainter(
                railY: railY,
                startX: pad,
                endX: pad + plot,
                todayX: xOf(schedule.asOf),
                axis: theme.colorScheme.outlineVariant,
                gone:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
                today: theme.colorScheme.onSurfaceVariant,
                ground: theme.cardColor,
                dots: [
                  for (final day in schedule.orderDays)
                    (
                      x: xOf(day.date),
                      color: orderStatusColor(
                        context,
                        day.parts
                            .map((p) => p.status)
                            .reduce((a, b) => a.index < b.index ? a : b),
                      ),
                    ),
                ],
                stems: [
                  for (final p in placed)
                    (
                      x: xOf(p.mark.date),
                      top: topOf(p.lane) + markHeight,
                      color: p.mark.color,
                    ),
                ],
                ticks: [for (final t in ticks) t.x],
              ),
            ),
          ),
          // The months under the rail. What turns a row of dots into a
          // distance: without them the gap between two dates is a gap, and
          // with them it is three months.
          for (final tick in ticks)
            Positioned(
              top: railY + 6,
              left: tick.x - _kMonthLabelWidth / 2,
              width: _kMonthLabelWidth,
              child: Text(
                tick.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final p in placed)
            Positioned(
              top: topOf(p.lane),
              left: p.left,
              width: markWidth,
              height: markHeight,
              child: _DateCallout(
                markKey: ValueKey('timeline_date_mark_${p.mark.label}'),
                label: p.mark.label,
                date: p.mark.date,
                color: p.mark.color,
              ),
            ),
        ],
      ),
    );
  }

  /// A tick on the first of every nth month, thinned until each label has
  /// [_kMonthLabelWidth] of rail to itself. Months printed over each other are
  /// worse than no months at all.
  List<({double x, String label})> _monthTicks(
    DateTime first,
    int span,
    double plot,
    double Function(DateTime) xOf,
  ) {
    final last = addDays(first, span);
    final months =
        (last.year - first.year) * 12 + (last.month - first.month) + 1;
    final room = (plot / _kMonthLabelWidth).floor().clamp(1, 24);
    final step = (months / room).ceil().clamp(1, 120);

    final out = <({double x, String label})>[];
    // The first of the month the rail starts in is behind the rail; the tick
    // goes on the next one.
    var when = DateTime(first.year, first.month);
    if (when.isBefore(first)) when = DateTime(first.year, first.month + 1);
    while (!when.isAfter(last)) {
      out.add((
        x: xOf(when),
        // The year only where it changes: 'Jan 2026' on every tick is four
        // characters repeated the width of the page.
        label: out.isEmpty || when.month == 1
            ? '${formatScheduleMonth(when)} ${when.year}'
            : formatScheduleMonth(when),
      ));
      when = DateTime(when.year, when.month + step);
    }
    return out;
  }
}

/// One named date, as it sits over the rail.
class _DateCallout extends StatelessWidget {
  final Key markKey;
  final String label;
  final DateTime date;
  final Color color;

  const _DateCallout({
    required this.markKey,
    required this.label,
    required this.date,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '$label  ·  ${formatScheduleDate(date)}',
      child: Container(
        key: markKey,
        padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          // The colour is a second way to read the rail, never the only one -
          // this tab gets printed and photographed. The words say it too.
          border: Border(left: BorderSide(color: color, width: 2.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            Text(
              formatScheduleDate(date),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rail, the days already gone, the order dates on it, and the stems up to
/// the cards.
class _DateGraphPainter extends CustomPainter {
  final double railY;
  final double startX, endX, todayX;
  final Color axis, gone, today, ground;

  /// One per order date, in the colour the worst part on that day reads in.
  final List<({double x, Color color})> dots;

  /// Up from the rail to the bottom of each callout.
  final List<({double x, double top, Color color})> stems;

  /// Where the month labels are, so the rail can carry a tick under each.
  final List<double> ticks;

  const _DateGraphPainter({
    required this.railY,
    required this.startX,
    required this.endX,
    required this.todayX,
    required this.axis,
    required this.gone,
    required this.today,
    required this.ground,
    required this.dots,
    required this.stems,
    required this.ticks,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(startX, railY),
      Offset(endX, railY),
      Paint()
        ..color = axis
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    // TIME ALREADY SPENT, drawn heavier than the rest of the rail. A schedule
    // is read from where the reader is standing, and the part behind them is
    // the part no decision can be taken about any more.
    if (todayX > startX) {
      canvas.drawLine(
        Offset(startX, railY),
        Offset(todayX, railY),
        Paint()
          ..color = gone
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }

    for (final x in ticks) {
      canvas.drawLine(
        Offset(x, railY - 3),
        Offset(x, railY + 3),
        Paint()
          ..color = axis
          ..strokeWidth = 1,
      );
    }

    for (final stem in stems) {
      canvas.drawLine(
        Offset(stem.x, railY),
        Offset(stem.x, stem.top),
        Paint()
          ..color = stem.color.withValues(alpha: 0.6)
          ..strokeWidth = 1.5,
      );
    }

    // THE ORDER DATES. Each is punched out of the rail first, so eleven dates
    // in one fortnight read as eleven dates rather than as one thick smear.
    for (final dot in dots) {
      canvas.drawCircle(Offset(dot.x, railY), 5, Paint()..color = ground);
      canvas.drawCircle(Offset(dot.x, railY), 3.5, Paint()..color = dot.color);
    }

    // Where today is: a full-height rule rather than a dot, because every
    // other mark on the rail is read against it.
    canvas.drawLine(
      Offset(todayX, 0),
      Offset(todayX, railY),
      Paint()
        ..color = today.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
    canvas.drawCircle(Offset(todayX, railY), 4, Paint()..color = today);
  }

  @override
  bool shouldRepaint(_DateGraphPainter old) =>
      old.railY != railY ||
      old.todayX != todayX ||
      old.startX != startX ||
      old.endX != endX ||
      old.dots.length != dots.length ||
      old.stems.length != stems.length ||
      old.ticks.length != ticks.length;
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
    // A PO NUMBER TYPED HERE JOINS THE JOB'S PO LIST. Otherwise the list is
    // only ever as complete as somebody's memory of entering it twice, and
    // "what is on PO-1188" answers nothing for the PO that was only ever
    // typed onto a part. Adding one that is already there is a no-op - see
    // [BuildingProject.addPo].
    if (_order.poNumber.trim().isNotEmpty) {
      widget.provider.addProjectPo(number: _order.poNumber);
    }
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
              poNumbers: widget.provider.project.poNumbersInUse,
              onChanged: (o) => setState(() => _order = o),
            ),

            // WHAT OF IT IS ACTUALLY HERE. The order record says it was
            // bought and the arrival date says it landed; neither says where
            // it went, which on a part spread over five rooms is the question
            // that follows straight after. See project_deliveries_view.dart.
            _DeliveredHere(
              provider: widget.provider,
              partKey: widget.line.key,
              ordered: widget.line.qty,
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
