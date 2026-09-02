import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_snack.dart';
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

    Widget fact(IconData icon, String label, String value, {Color? color}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: color ?? muted),
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
                    color: color,
                    fontWeight: color == null ? null : FontWeight.w600,
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
            'Equipment',
            o.partsWithoutLeadTime == 0
                ? '${o.parts}'
                : '${o.parts}  ·  ${o.partsWithoutLeadTime} with no lead time',
          ),
          // The half of the job that is DONE. Without it, a count of what is
          // late is a number nobody can weigh.
          if (o.partsOnOrder > 0 || o.partsReceived > 0)
            fact(
              Icons.local_shipping_outlined,
              'Bought',
              [
                if (o.partsOnOrder > 0) '${o.partsOnOrder} on order',
                if (o.partsReceived > 0) '${o.partsReceived} arrived',
              ].join('  ·  '),
            ),
          // THE DRAWING SET. Part of what the job IS rather than what is
          // wrong with it - "is there a plan set at all" is asked before
          // anybody goes looking for one. A broken link is colored, because
          // it is the half of this line that needs doing something about.
          if (o.plans > 0)
            fact(
              Icons.architecture,
              'Plans',
              o.plansMissing == 0
                  ? '${o.plans}'
                  : '${o.plans}  ·  ${o.plansMissing} not where the project '
                      'says',
              color: o.plansMissing == 0
                  ? null
                  : errorTextOn(theme.colorScheme, theme.cardColor),
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
                        '${phase.parts == 1 ? '' : 's'} - no date'
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
            ? 'due ${formatScheduleDate(todo.due!)} - '
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
              // THE JOB'S DATES, IN THE ORDER THEY HAPPEN. Above the facts
              // because it is the shape of the job rather than a fact about
              // it: whether the buying finishes before the delivery date, and
              // how much room is left, is a question a list of rows cannot
              // answer however carefully each row is written.
              BriefingCalendar(briefing: briefing),
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
        // COPY, beside the dismissal rather than buried in the title. "Where
        // does this job stand" is almost never asked by the person reading the
        // screen — it is asked on email, on a call, or in a chat window — and
        // until this button the answer was retyped by somebody reading it off,
        // which is how a status loses its dates.
        TextButton.icon(
          key: const ValueKey('briefing_copy'),
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy'),
          onPressed: () => _copy(context),
        ),
        FilledButton(
          key: const ValueKey('briefing_close'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }

  /// Puts the whole briefing on the clipboard and says so.
  ///
  /// The dialog STAYS OPEN. Copying is something somebody does on the way to
  /// pasting it somewhere, and a dialog that closed itself would take the text
  /// off screen at exactly the moment they want to check they got the right
  /// job before they send it.
  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(text: renderBriefingText(briefing, title: title)),
    );
    showTimedSnackBar(
      messenger,
      const SnackBar(
        duration: Duration(seconds: 3),
        content: Text('Where this job stands copied to the clipboard'),
      ),
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


/// ============================================================================
///  THE JOB'S CALENDAR
/// ============================================================================
///  Every date on the briefing, laid out in the order it happens: today, the
///  order dates, the phases, the delivery, and the job notes that carry a date.
///
///  WHY A CALENDAR AND NOT ANOTHER LIST. The rows above are each true and each
///  answer a different question, and between them they cannot answer the one
///  everybody actually asks: is there room. "Order by 18 Jul" and "Delivery
///  12 Aug" three rows apart are two facts; the same two on a line are three
///  weeks of slack you can see, or a date that lands after the one it feeds.
///
///  IT IS DRAWN TO SCALE, so the gaps are real. A marker whose label will not
///  fit keeps its dot and loses its words rather than being dropped: a date
///  that is on the job is on the calendar, and hovering it says what it is.
///
///  A job with no dates at all draws nothing. One marker on a line is a line
///  that says nothing a date on a row does not, and today on its own is not a
///  schedule.
/// ============================================================================
class BriefingCalendar extends StatelessWidget {
  final ProjectBriefing briefing;

  const BriefingCalendar({super.key, required this.briefing});

  /// How tall the band is: a row for labels above, the line, a row below.
  static const double _height = 104;

  /// The vertical middle, where the axis sits.
  static const double _axisY = 52;

  /// How wide a label is allowed to be, and how much air two of them need
  /// between them before they read as two labels.
  static const double _labelWidth = 118;
  static const double _labelGap = 6;

  @override
  Widget build(BuildContext context) {
    final milestones = briefingMilestones(briefing);
    // Today plus nothing is not a schedule.
    if (milestones.length < 2) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final first = milestones.first.date;
    final last = milestones.last.date;
    // A job whose dates all land in one week still needs a line with two ends.
    final span = last.difference(first).inDays;
    final start = span < 14
        ? first.subtract(Duration(days: (14 - span) ~/ 2 + 1))
        : first.subtract(Duration(days: (span * 0.06).ceil()));
    final end = span < 14
        ? last.add(Duration(days: (14 - span) ~/ 2 + 1))
        : last.add(Duration(days: (span * 0.06).ceil()));
    final total = end.difference(start).inDays.toDouble();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth;
          double xOf(DateTime d) =>
              (d.difference(start).inDays / total * width).clamp(0.0, width);

          // Labels are laid out in date order, alternating above and below the
          // line, and a label that would sit on top of its neighbor on both
          // rows is dropped to a dot. The alternative — squeezing the type or
          // sliding the label off its own marker — is a calendar that points
          // at the wrong day.
          final placed =
              <({BriefingMilestone m, double x, bool above, bool labeled})>[];
          final lastRight = <bool, double>{true: -1e9, false: -1e9};
          var above = true;
          for (final m in milestones) {
            final x = xOf(m.date);
            final left = (x - _labelWidth / 2).clamp(0.0, width - _labelWidth);
            bool fits(bool row) => left >= lastRight[row]! + _labelGap;
            bool? row;
            if (fits(above)) {
              row = above;
            } else if (fits(!above)) {
              row = !above;
            }
            if (row == null) {
              // No room on either side: the date keeps its dot and loses its
              // words. Dropping the marker itself would take a date off the
              // job; the tooltip still says what it is.
              placed.add((m: m, x: x, above: above, labeled: false));
              continue;
            }
            lastRight[row] = left + _labelWidth;
            placed.add((m: m, x: x, above: row, labeled: true));
            above = !row;
          }

          return SizedBox(
            height: _height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The months the job runs through, so a marker can be read
                // against a real calendar rather than against its neighbors.
                for (final month in _months(start, end))
                  Positioned(
                    left: xOf(month),
                    top: _axisY - 10,
                    child: Container(
                      width: 1,
                      height: 20,
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                for (final month in _months(start, end))
                  Positioned(
                    left: (xOf(month) + 3).clamp(0.0, width - 46),
                    top: _axisY + 10,
                    child: Text(
                      _monthLabel(month),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: muted,
                        fontSize: 10,
                      ),
                    ),
                  ),
                // The line itself.
                Positioned(
                  left: 0,
                  right: 0,
                  top: _axisY,
                  child: Container(
                    height: 2,
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
                for (final p in placed) ..._marker(context, p, width),
              ],
            ),
          );
        },
      ),
    );
  }

  /// One date: its dot, its stalk and (where there is room) its words.
  List<Widget> _marker(
    BuildContext context,
    ({BriefingMilestone m, double x, bool above, bool labeled}) placed,
    double width,
  ) {
    final theme = Theme.of(context);
    final m = placed.m;
    final color = _colorFor(context, m);
    final today = m.kind == BriefingDateKind.today;
    final dot = today ? 11.0 : 9.0;
    final left = (placed.x - _labelWidth / 2).clamp(0.0, width - _labelWidth);

    return [
      // TODAY IS A LINE, not a dot: it is the one marker that is not something
      // to do, and the whole calendar is read as "before this" and "after it".
      if (today)
        Positioned(
          left: placed.x - 0.5,
          top: 14,
          child: Container(height: _height - 34, width: 1, color: color),
        ),
      Positioned(
        left: placed.x - dot / 2,
        top: _axisY + 1 - dot / 2,
        child: Tooltip(
          message: m.detail,
          child: Container(
            key: ValueKey('briefing_marker_${m.kind.name}_'
                '${m.date.toIso8601String().split('T').first}'),
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.dialogTheme.backgroundColor ??
                    theme.colorScheme.surface,
                width: 1.5,
              ),
            ),
          ),
        ),
      ),
      if (placed.labeled)
      Positioned(
        left: left,
        top: placed.above ? 6 : _axisY + 26,
        width: _labelWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
                fontSize: 11,
              ),
            ),
            Text(
              formatScheduleDate(m.date),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Color _colorFor(BuildContext context, BriefingMilestone m) {
    final theme = Theme.of(context);
    if (m.late) {
      return errorTextOn(
        theme.colorScheme,
        theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
      );
    }
    return switch (m.kind) {
      BriefingDateKind.today => theme.colorScheme.onSurfaceVariant,
      BriefingDateKind.order => theme.colorScheme.primary,
      BriefingDateKind.phase => theme.colorScheme.tertiary,
      BriefingDateKind.delivery => theme.colorScheme.secondary,
      BriefingDateKind.todo => theme.colorScheme.onSurfaceVariant,
    };
  }

  /// The first of each month the calendar covers, capped so a job spanning
  /// three years does not draw thirty-six gridlines into 600 pixels.
  static List<DateTime> _months(DateTime start, DateTime end) {
    final out = <DateTime>[];
    var at = DateTime(start.year, start.month + 1);
    while (!at.isAfter(end) && out.length < 240) {
      out.add(at);
      at = DateTime(at.year, at.month + 1);
    }
    if (out.length <= 14) return out;
    // Every third month on a long job, so the labels stay apart.
    final step = (out.length / 12).ceil();
    return [
      for (var i = 0; i < out.length; i += step) out[i],
    ];
  }

  static String _monthLabel(DateTime month) {
    const names = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final name = names[month.month - 1];
    // The year on January, and only there: repeating it on twelve gridlines is
    // eleven repetitions of a fact that changes once.
    return month.month == 1 ? '$name ${month.year}' : name;
  }
}
