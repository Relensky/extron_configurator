import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'building_project.dart';
import 'project_schedule.dart' show formatScheduleDate;
import 'stepped_date_picker.dart';

/// The building's walkthroughs on the Timeline pane: when it was last checked,
/// and each visit with who went and what was checked or is being done.
class WalkthroughsCard extends StatelessWidget {
  const WalkthroughsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final walks = [...provider.project.walkthroughs]
      ..sort((a, b) => b.date.compareTo(a.date));
    final today = dateOnly(DateTime.now());
    final past = [
      for (final w in walks)
        if (!w.date.isAfter(today)) w,
    ];
    final last = past.firstOrNull;
    final next = [
      for (final w in walks.reversed)
        if (w.date.isAfter(today)) w,
    ].firstOrNull;

    String ago(DateTime d) {
      final days = today.difference(dateOnly(d)).inDays;
      return days == 0
          ? 'today'
          : days == 1
          ? 'yesterday'
          : '$days days ago';
    }

    final summary = [
      last == null
          ? 'Not walked through yet'
          : 'Last walked through ${formatScheduleDate(last.date)} '
                '(${ago(last.date)})',
      if (next != null) 'next ${formatScheduleDate(next.date)}',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        key: const ValueKey('project_walkthroughs'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.directions_walk, size: 20, color: muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Walkthroughs', style: theme.textTheme.titleSmall),
                        Text(
                          summary,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('project_walkthrough_add'),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add walkthrough'),
                    onPressed: () => showWalkthroughDialog(context),
                  ),
                ],
              ),
              if (walks.isNotEmpty) const SizedBox(height: 8),
              for (final w in walks)
                ListTile(
                  key: ValueKey('project_walkthrough_${w.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    w.date.isAfter(today)
                        ? Icons.event_outlined
                        : Icons.event_available,
                    size: 20,
                  ),
                  title: Text(
                    [
                      formatScheduleDate(w.date),
                      if (w.by.trim().isNotEmpty) w.by.trim(),
                    ].join(' · '),
                  ),
                  subtitle: w.notes.trim().isEmpty
                      ? null
                      : Text(w.notes.trim()),
                  onTap: () => showWalkthroughDialog(context, walk: w),
                  trailing: IconButton(
                    tooltip: 'Remove this walkthrough',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => provider.removeProjectWalkthrough(w.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Adds a walkthrough, or edits [walk].
Future<void> showWalkthroughDialog(
  BuildContext context, {
  ProjectWalkthrough? walk,
}) {
  final provider = context.read<AppStateProvider>();
  final by = TextEditingController(text: walk?.by ?? '');
  final notes = TextEditingController(text: walk?.notes ?? '');
  var date = walk?.date ?? dateOnly(DateTime.now());
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        key: const ValueKey('project_walkthrough_dialog'),
        title: Text(walk == null ? 'Add a walkthrough' : 'Walkthrough'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('project_walkthrough_date'),
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(formatScheduleDate(date)),
                onPressed: () async {
                  final picked = await showSteppedDatePicker(
                    ctx,
                    initialDate: date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                    helpText: 'Walkthrough date',
                  );
                  if (picked != null) setLocal(() => date = picked);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('project_walkthrough_by'),
                controller: by,
                decoration: const InputDecoration(
                  labelText: 'Who went',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('project_walkthrough_notes'),
                controller: notes,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'What was checked, and what is being done',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('project_walkthrough_save'),
            onPressed: () {
              provider.saveProjectWalkthrough(
                ProjectWalkthrough(
                  id: walk?.id ?? '',
                  date: date,
                  by: by.text.trim(),
                  notes: notes.text.trim(),
                ),
              );
              Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
