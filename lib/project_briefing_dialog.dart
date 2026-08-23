import 'package:flutter/material.dart';

import 'app_state.dart';
import 'contrast.dart';
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
