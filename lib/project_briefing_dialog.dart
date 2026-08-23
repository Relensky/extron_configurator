import 'package:flutter/material.dart';

import 'app_state.dart';
import 'contrast.dart';
import 'building_project.dart' show daysBetween;
import 'cost_estimate.dart' show formatMoney;
import 'project_briefing.dart';
import 'project_schedule.dart';

/// ============================================================================
///  THE BRIEFING, ON SCREEN
/// ============================================================================
///  Shown once, when a project is opened. See project_briefing.dart for what it
///  says and why; this file is only how it reads.
///
///  THREE RULES, because a dialog that appears on every open is a dialog that
///  gets dismissed unread within a week:
///
///    * IT ONLY INTERRUPTS WHEN SOMETHING IS TIME-CRITICAL. A job with nothing
///      late and nothing due soon opens straight onto the tab — the standing
///      questions are still there on the panes that own them. See
///      [ProjectBriefing.isQuiet].
///    * IT IS DISMISSED WITH ONE KEY. Escape, Enter, or the button.
///    * EVERY LINE NAMES THE PANE THAT FIXES IT, so it is a route rather than a
///      complaint.
/// ============================================================================

/// Shows the briefing for the project [provider] currently has open.
///
/// [force] shows it even when nothing is time-critical — what the "Open
/// briefing" action on the tab passes, since somebody asking for it should get
/// it. Otherwise a quiet project shows nothing at all and this returns without
/// putting anything on screen.
Future<void> showProjectBriefing(
  BuildContext context,
  AppStateProvider provider, {
  bool force = false,
  DateTime? asOf,
}) async {
  final briefing = buildProjectBriefing(
    estimate: provider.priceProject(),
    asOf: asOf,
  );
  if (!force && briefing.isQuiet) return;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (_) => _BriefingDialog(
      briefing: briefing,
      title: provider.projectDisplayName,
    ),
  );
}

/// The job in five lines and a strip of dates.
///
/// Deliberately not a dashboard. It answers what somebody coming back to a job
/// has to know before they can read the warnings underneath — how big it is,
/// what it costs, when it delivers, and when the buying starts — and then the
/// ORDER DATES themselves, because "3 parts are late" is a count and
/// "18 Jul: 2 parts" is a thing to put in a calendar.
class _Overview extends StatelessWidget {
  final BriefingOverview overview;
  final DateTime asOf;

  const _Overview({required this.overview, required this.asOf});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final o = overview;

    Widget fact(IconData icon, String label, String value, {Color? colour}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: colour ?? muted),
              const SizedBox(width: 6),
              SizedBox(
                width: 108,
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colour,
                    fontWeight: colour == null ? null : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          fact(
            Icons.meeting_room_outlined,
            'Rooms',
            o.roomsCosted == o.roomsTotal
                ? '${o.roomsCosted}'
                : '${o.roomsCosted} of ${o.roomsTotal} counted',
          ),
          fact(
            Icons.payments_outlined,
            'Project total',
            formatMoney(o.grandTotal, o.currency),
          ),
          fact(
            Icons.inventory_2_outlined,
            'Core components',
            o.partsWithoutLeadTime == 0
                ? '${o.parts}'
                : '${o.parts}  ·  ${o.partsWithoutLeadTime} with no lead time',
          ),
          fact(
            Icons.event,
            'Delivery',
            o.deadline == null
                ? 'no deadline set'
                : '${formatScheduleDate(o.deadline!)}'
                      '${_gapNote(o.deadline!)}',
          ),
          // The phases, when the job has split into them: each one's date is
          // what its own parts are worked back from, so a reader checking a
          // date needs to see them rather than the job's single deadline.
          for (final phase in o.phases)
            fact(
              Icons.alt_route,
              phase.name,
              phase.deadline == null
                  ? '${phase.parts} part'
                        '${phase.parts == 1 ? '' : 's'} — no date'
                  : '${formatScheduleDate(phase.deadline!)}'
                        '  ·  ${phase.parts} part'
                        '${phase.parts == 1 ? '' : 's'}',
            ),
          if (o.firstOrder != null)
            fact(
              Icons.shopping_cart_outlined,
              'Buying runs',
              '${formatScheduleDate(o.firstOrder!)}'
              '${o.lastDelivery == null ? '' : ' → '
                  '${formatScheduleDate(o.lastDelivery!)}'}',
            ),

          // THE ORDER DATES THEMSELVES. A count of what is late is something
          // to worry about; a date with a number of parts on it is something
          // to act on, and it is the whole reason the timeline exists.
          if (o.nextOrders.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'ORDER BY',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: muted,
              ),
            ),
            const SizedBox(height: 2),
            for (final day in o.nextOrders)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Icon(
                      day.late ? Icons.error_outline : Icons.circle,
                      size: day.late ? 13 : 7,
                      color: day.late
                          ? errorTextOn(
                              theme.colorScheme,
                              theme.dialogTheme.backgroundColor ??
                                  theme.colorScheme.surface,
                            )
                          : theme.colorScheme.primary,
                    ),
                    SizedBox(width: day.late ? 5 : 8),
                    SizedBox(
                      width: 104,
                      child: Text(
                        formatScheduleDate(day.date),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: day.late
                              ? errorTextOn(
                                  theme.colorScheme,
                                  theme.dialogTheme.backgroundColor ??
                                      theme.colorScheme.surface,
                                )
                              : null,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${day.parts} part${day.parts == 1 ? '' : 's'}'
                        '  ·  ${formatDayGap(daysBetween(asOf, day.date))}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],

          // THE JOB LIST, as items. "4 job notes are still open" is a number
          // to go and look at; the notes are what somebody came back to the
          // project to read, and most of them are one line long.
          if (o.todos.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'STILL TO DO',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: muted,
              ),
            ),
            const SizedBox(height: 2),
            for (final todo in o.todos) _todoLine(context, todo),
            if (o.moreTodos > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 15),
                child: Text(
                  'and ${o.moreTodos} more',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _todoLine(BuildContext context, BriefingTodo todo) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final ink = todo.late
        ? errorTextOn(
            theme.colorScheme,
            theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
          )
        : null;

    // What the note is filed under and when it is due, after the note itself —
    // both are qualifiers, and a row that leads with "BSS 103" buries the one
    // thing being read.
    final tail = [
      if (todo.scope.isNotEmpty) todo.scope,
      if (todo.due != null)
        todo.late
            ? 'due ${formatScheduleDate(todo.due!)} — '
                  '${formatDayGap(daysBetween(asOf, todo.due!))}'
            : 'due ${formatScheduleDate(todo.due!)}',
      if (todo.blocked) 'waiting on somebody',
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              todo.late
                  ? Icons.error_outline
                  : todo.blocked
                  ? Icons.pause_circle_outline
                  : Icons.check_box_outline_blank,
              size: 13,
              color: todo.late
                  ? ink
                  : todo.blocked
                  ? theme.colorScheme.tertiary
                  : muted,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  todo.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: ink,
                    fontWeight: todo.late ? FontWeight.w600 : null,
                  ),
                ),
                if (tail.isNotEmpty)
                  Text(
                    tail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: todo.late ? ink : muted,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// " — in 82 days" / " — 3 days late", for a date that has one.
  String _gapNote(DateTime when) {
    final gap = daysBetween(asOf, when);
    return '  ·  ${formatDayGap(gap)}';
  }
}

class _BriefingDialog extends StatelessWidget {
  final ProjectBriefing briefing;
  final String title;

  const _BriefingDialog({required this.briefing, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      key: const ValueKey('project_briefing'),
      title: Row(
        children: [
          const Icon(Icons.flag_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Where this job stands on '
                '${formatScheduleDate(briefing.asOf)}.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              // WHAT THE JOB IS, before what is wrong with it. Five warnings
              // mean something different on a nine-room building due in March
              // than on a one-room job with no date on it, and the reader
              // needs the second fact to weigh the first.
              _Overview(overview: briefing.overview, asOf: briefing.asOf),
              const SizedBox(height: 4),
              // In urgency order, with a heading on each block. The headings
              // are what make it skimmable: somebody who only has a moment
              // reads the first block and stops, and the first block is the
              // one that cannot wait.
              if (briefing.lateLines.isNotEmpty)
                _block(context, 'Already late', briefing.lateLines),
              if (briefing.soonLines.isNotEmpty)
                _block(context, 'Coming up', briefing.soonLines),
              if (briefing.openLines.isNotEmpty)
                _block(context, 'Still open', briefing.openLines),
              for (final line in briefing.lines)
                if (line.urgency == BriefingUrgency.clear)
                  _lineTile(context, line),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('briefing_close'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }

  Widget _block(BuildContext context, String heading, List<BriefingLine> ls) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Text(
            heading.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final l in ls) _lineTile(context, l),
      ],
    );
  }

  Widget _lineTile(BuildContext context, BriefingLine line) {
    final theme = Theme.of(context);
    final color = _urgencyColor(context, line.urgency);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(_urgencyIcon(line.urgency), size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: line.urgency == BriefingUrgency.late
                        ? FontWeight.w600
                        : null,
                  ),
                ),
                for (final d in line.detail)
                  Padding(
                    padding: const EdgeInsets.only(left: 2, top: 1),
                    child: Text(
                      '· $d',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (line.urgency != BriefingUrgency.clear)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Fixed on ${kBriefingPaneLabels[line.pane]}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _urgencyColor(BuildContext context, BriefingUrgency u) {
    final theme = Theme.of(context);
    switch (u) {
      case BriefingUrgency.late:
        return errorTextOn(theme.colorScheme, theme.dialogTheme.backgroundColor
            ?? theme.colorScheme.surface);
      case BriefingUrgency.soon:
        return theme.colorScheme.tertiary;
      case BriefingUrgency.open:
        return theme.colorScheme.onSurface;
      case BriefingUrgency.clear:
        return theme.colorScheme.primary;
    }
  }

  IconData _urgencyIcon(BriefingUrgency u) => switch (u) {
    BriefingUrgency.late => Icons.error_outline,
    BriefingUrgency.soon => Icons.schedule,
    BriefingUrgency.open => Icons.radio_button_unchecked,
    BriefingUrgency.clear => Icons.check_circle_outline,
  };
}
