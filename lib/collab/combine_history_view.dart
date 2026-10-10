import 'package:material_ui/material_ui.dart';

import 'combine_history.dart';

/// The combine history, by room, project or campus. Each group expands to
/// its combines; each combine expands to every line it touched.
class CombineHistoryPane extends StatefulWidget {
  const CombineHistoryPane({super.key, required this.store});

  /// Null when combines are not logged on this machine.
  final CombineHistoryStore? store;

  @override
  State<CombineHistoryPane> createState() => _CombineHistoryPaneState();
}

class _CombineHistoryPaneState extends State<CombineHistoryPane> {
  CombineHistoryScope _scope = CombineHistoryScope.room;
  List<CombineHistoryEntry>? _entries;
  CombineHistoryCheck? _check;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = widget.store;
    if (store == null) {
      setState(() => _entries = const []);
      return;
    }
    final entries = await store.load();
    final check = await store.check();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _check = check;
    });
  }

  Future<void> _repair() async {
    final error = await widget.store!.repair();
    if (!mounted) return;
    setState(() => _error = error);
    await _load();
  }

  static const _scopeLabels = {
    CombineHistoryScope.room: 'Per room',
    CombineHistoryScope.project: 'Per project',
    CombineHistoryScope.campus: 'Per campus',
  };

  String _blank(CombineHistoryScope scope) => switch (scope) {
        CombineHistoryScope.room => 'Project-wide (no room)',
        CombineHistoryScope.project => 'No project',
        CombineHistoryScope.campus => 'No campus',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final groups = groupCombineHistory(entries, _scope);
    final check = _check;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<CombineHistoryScope>(
                segments: [
                  for (final s in CombineHistoryScope.values)
                    ButtonSegment(
                      value: s,
                      label: Text(
                        _scopeLabels[s]!,
                        key: ValueKey('combine_scope_${s.name}'),
                      ),
                    ),
                ],
                selected: {_scope},
                onSelectionChanged: (v) => setState(() => _scope = v.first),
              ),
              if (check != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      check.matches ? Icons.verified_outlined : Icons.sync_problem,
                      size: 16,
                      color: check.matches
                          ? muted
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      check.matches
                          ? 'Backup matches (${check.mainCount} entries)'
                          : 'Backup differs: ${check.mainCount} in the log, '
                              '${check.backupCount} in the backup',
                      key: const ValueKey('combine_backup_check'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: check.matches ? muted : theme.colorScheme.error,
                      ),
                    ),
                    if (!check.matches)
                      TextButton(
                        key: const ValueKey('combine_backup_repair'),
                        onPressed: _repair,
                        child: const Text('Combine them'),
                      ),
                  ],
                ),
            ],
          ),
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
            child: Text(_error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            widget.store == null
                ? 'Combines are not logged here.'
                : entries.isEmpty
                    ? 'No combines yet. Each time another person\'s save is '
                        'combined into yours, every line is listed here.'
                    : '${entries.length} combine'
                        '${entries.length == 1 ? '' : 's'}, newest first. '
                        'Expand one for every line it changed.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        const Divider(),
        Expanded(
          child: ListView(
            key: const ValueKey('combine_history_list'),
            padding: const EdgeInsets.only(left: 16, right: 16),
            children: [
              for (final g in groups.entries)
                ExpansionTile(
                  key: ValueKey('combine_group_${_scope.name}_${g.key}'),
                  leading: Icon(switch (_scope) {
                    CombineHistoryScope.room => Icons.meeting_room_outlined,
                    CombineHistoryScope.project => Icons.apartment,
                    CombineHistoryScope.campus => Icons.location_city,
                  }),
                  title: Text(g.key.isEmpty ? _blank(_scope) : g.key),
                  subtitle: Text(
                    '${g.value.length} combine'
                    '${g.value.length == 1 ? '' : 's'} - last '
                    '${formatCombineTime(g.value.first.at)}',
                  ),
                  children: [
                    for (final e in g.value) _EntryTile(entry: e),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `9 Oct 2026, 2:30:05 PM`.
String formatCombineTime(DateTime at) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.day} ${months[at.month - 1]} ${at.year}, '
      '$h:${two(at.minute)}:${two(at.second)} ${at.hour < 12 ? 'AM' : 'PM'}';
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final CombineHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final e = entry;
    final where = [
      if (e.room.isNotEmpty) e.room,
      if (e.project.isNotEmpty) e.project,
      if (e.campus.isNotEmpty) e.campus,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        key: ValueKey('combine_entry_${e.id}'),
        dense: true,
        title: Text(
          '${formatCombineTime(e.at)} - ${e.who.isEmpty ? 'Someone' : e.who} '
          'combined ${e.from.isEmpty ? 'another save' : '${e.from}\'s save'}',
        ),
        subtitle: Text(
          '${e.approvedCount} approved'
          '${e.declinedCount > 0 ? ', ${e.declinedCount} left out' : ''}'
          '${where.isEmpty ? '' : '  ·  $where'}',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
        children: [
          SelectableText(
            [
              'Edited ${formatCombineTime(e.at)}'
                  '${e.user.isEmpty ? '' : ' by ${e.user}'}'
                  '${e.machine.isEmpty ? '' : ' on ${e.machine}'}',
              if (e.file.isNotEmpty) 'File: ${e.file}',
              if (e.backup.isNotEmpty) 'Backup before combining: ${e.backup}',
            ].join('\n'),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 4),
          for (final i in e.items)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                i.conflict
                    ? Icons.call_merge
                    : i.approved
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                size: 18,
                color: i.approved ? theme.colorScheme.primary : muted,
              ),
              title: Text(i.place.isEmpty ? i.path : i.place),
              subtitle: Text(
                [
                  if (i.conflict) 'Both changed it',
                  if (!i.conflict && !i.approved) 'Left out',
                  if (i.before.isNotEmpty)
                    i.conflict ? 'yours ${i.before}' : 'was ${i.before}',
                  if (i.after.isNotEmpty)
                    i.conflict ? 'result: ${i.after}' : 'now ${i.after}',
                ].join(' - '),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}
