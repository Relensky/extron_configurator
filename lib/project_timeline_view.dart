import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show trimNumber;
import 'project_estimate.dart';
import 'project_schedule.dart';

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
  final picked = await showDatePicker(
    context: context,
    initialDate: initial ?? now,
    // A job can be scheduled against a date that has already gone — a project
    // picked up halfway through is the ordinary case, and a picker that
    // refuses last month makes recording what actually happened impossible.
    firstDate: DateTime(now.year - 5),
    lastDate: DateTime(now.year + 10),
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
      return errorTextOn(theme.colorScheme, theme.cardColor);
    case OrderStatus.dueSoon:
      return theme.colorScheme.tertiary;
    case OrderStatus.onTrack:
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
};

/// The timeline pane, as slivers for the project tab's one scroll view.
List<Widget> timelineSlivers(BuildContext context, ProjectEstimate estimate) {
  final theme = Theme.of(context);
  final provider = context.watch<AppStateProvider>();
  final schedule = buildProjectSchedule(estimate: estimate);

  if (estimate.master.isEmpty) {
    return const [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nothing to schedule yet.\n\n'
              'The timeline is built from the core components list — add '
              'rooms that have equipment on them.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ];
  }

  return [
    SliverToBoxAdapter(
      child: _TimelineSummary(schedule: schedule, provider: provider),
    ),
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
                'time on the parts that matter — the Core Components list has '
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
            firstOrder == null ? '—' : formatScheduleDate(firstOrder),
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
                    'Not on the timeline — no lead time recorded '
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
    widget.provider.setProjectPartLeadTime(widget.line.key, days);
    widget.provider.setProjectPartNeedBy(widget.line.key, _needBy);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deadline = widget.provider.project.deliveryDeadline;
    final typed = int.tryParse(_days.text.trim());
    final effectiveNeed = _needBy ?? deadline;
    final preview = (typed != null && effectiveNeed != null)
        ? dateOnly(effectiveNeed.subtract(Duration(days: typed)))
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
                              ? 'With the job — '
                                  '${formatScheduleDate(deadline)}'
                              : 'With the job (no deadline set)',
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
              'earlier than everything else — a screen or a mount that goes '
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
                        ? 'Order by — needs a lead time and a delivery date.'
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
