import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'building_project.dart';
import 'project_estimate.dart';

/// ============================================================================
///  WHO CHANGED WHAT, AND WHEN
/// ============================================================================
///  A job is worked on by more than one person over more than one month, and
///  the question that comes up months later is always the same: "this says four
///  weeks — it said eight in March. Who changed it?"
///
///  A file that holds only the current value cannot answer that, so the
///  decisions made on a job are logged as they are made, against the ITEM they
///  belong to, under the Windows login of whoever made them. See [ProjectEdit].
///
///  TWO LOGS, because a session has two documents open and they are saved in
///  different files: the JOB's decisions (lead times, orders, vendor pins,
///  dates) live in the project file, and the ROOM's edits (its fields, its
///  drawing, its racks) live in `<config>_history.json` beside the room. Both
///  are read on one screen — see [showHistoryDialog] — because "what happened
///  last Tuesday" is one question, and answering it should not depend on
///  knowing which of the two files the answer is in.
///
///  THREE WAYS TO READ IT:
///
///    * WHAT HAS HAPPENED, full stop — [showHistoryDialog], off the toolbar, so
///      it is reachable from every tab rather than only from the job.
///    * WHAT HAS HAPPENED TO THIS PART — [ItemHistory], shown on the item's own
///      editor. This is the one people actually ask, and a flat list of four
///      hundred edits across nine rooms cannot answer it.
///
///  IT IS A LOG, NOT AN UNDO. Nothing here puts anything back — the AV document
///  has its own undo, and a history that offered to revert a decision made six
///  weeks ago by somebody else would be a much bigger promise than this makes.
///  It says what happened.
/// ============================================================================

/// The history pane, as slivers for the project tab's one scroll view.
List<Widget> historySlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.watch<AppStateProvider>();
  final theme = Theme.of(context);
  final entries = provider.project.recentHistory;

  if (entries.isEmpty) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          child: Center(
            child: Text(
              'Nothing recorded yet.\n\n'
              'Lead times, orders, vendor pins, dates, notes and the job list '
              'are logged here as they are changed - with the login of '
              'whoever changed them.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ),
    ];
  }

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(
          '${entries.length} change${entries.length == 1 ? '' : 's'}, newest '
          'first. Every one is stamped with the Windows login it was made '
          'under.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      sliver: SliverList.builder(
        itemCount: entries.length,
        itemBuilder: (context, i) => _EditRow(
          edit: entries[i],
          // A date heading whenever the day changes, so a long log reads as
          // days rather than as four hundred identical rows.
          showDay: i == 0 || !_sameDay(entries[i].at, entries[i - 1].at),
        ),
      ),
    ),
  ];
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// One logged change.
class _EditRow extends StatelessWidget {
  final ProjectEdit edit;
  final bool showDay;

  /// Which log this came out of, or null when only one is on screen and
  /// saying so on every row would be noise.
  final HistoryScope? source;

  const _EditRow({required this.edit, required this.showDay, this.source});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showDay)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(
              formatEditDay(edit.at),
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: muted,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 46,
                child: Text(
                  formatEditTime(edit.at),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              Icon(editKindIcon(edit.itemKind), size: 13, color: muted),
              const SizedBox(width: 6),
              if (source != null) ...[
                Text(
                  source == HistoryScope.room ? 'ROOM' : 'JOB',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: muted,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                    children: [
                      // The ITEM first: a log is read looking for a thing, not
                      // for a field name.
                      if (edit.itemName.isNotEmpty)
                        TextSpan(
                          text: '${edit.itemName}  ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      TextSpan(
                        text: '${edit.field} ${edit.summary}',
                        style: TextStyle(color: muted),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                // A blank login is left blank rather than dressed up as a
                // name — see [currentUserName].
                edit.user.isEmpty ? '-' : edit.user,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What has happened to ONE item, for showing on that item's own editor.
///
/// The question people actually ask. Collapsed by default: most of the time
/// somebody is editing the thing, not auditing it, and a dialog that opens
/// with eleven lines of history above the field is a dialog that got taller
/// for no reason.
class ItemHistory extends StatefulWidget {
  final List<ProjectEdit> entries;

  const ItemHistory({super.key, required this.entries});

  @override
  State<ItemHistory> createState() => _ItemHistoryState();
}

class _ItemHistoryState extends State<ItemHistory> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final entries = widget.entries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('item_history_toggle'),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: muted,
                ),
                const SizedBox(width: 4),
                Text(
                  '${entries.length} change'
                  '${entries.length == 1 ? '' : 's'} on this item',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                const SizedBox(width: 8),
                // The most recent one is worth showing even while collapsed:
                // "who touched this last" is most of what gets asked.
                Expanded(
                  child: Text(
                    '${entries.first.field} ${entries.first.summary}'
                    '${entries.first.user.isEmpty ? '' : ' — '
                        '${entries.first.user}'}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 2),
              child: Text(
                '${formatEditDay(e.at)} ${formatEditTime(e.at)}  ·  '
                '${e.field} ${e.summary}'
                '${e.user.isEmpty ? '' : '  ·  ${e.user}'}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
      ],
    );
  }
}

IconData editKindIcon(String kind) => switch (kind) {
  'part' => Icons.inventory_2_outlined,
  'todo' => Icons.checklist,
  'room' => Icons.meeting_room_outlined,
  'track' => Icons.alt_route,
  'po' => Icons.receipt_long,
  'delivery' => Icons.inventory,
  _ => Icons.apartment,
};

/// '23 Aug 2026', or 'Today' / 'Yesterday' for the two days people actually
/// think in.
String formatEditDay(DateTime at, {DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  final day = dateOnly(at);
  final gap = daysBetween(day, today);
  if (gap == 0) return 'Today';
  if (gap == 1) return 'Yesterday';
  return '${day.day} ${_months[day.month - 1]} ${day.year}';
}

/// '14:32' — 24 hour, because this app is read on both sides of the Atlantic
/// and an am/pm a reader has to squint at defeats the point of a timestamp.
String formatEditTime(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

// ---------------------------------------------------------------------------
//  FINISHED TASKS
// ---------------------------------------------------------------------------

/// One note that left the open list: completed (still listed, or cleared
/// since) or deleted while open.
typedef FinishedTask = ({
  ProjectTodo todo,
  bool completed,

  /// Who it counts for: whoever completed it, else whoever deleted it.
  String by,

  /// When it was completed, or deleted.
  DateTime at,

  /// Who took it off the list, when somebody did; '' while it is still on.
  String removedBy,
});

/// Every finished note on [project], newest first.
List<FinishedTask> finishedTasks(BuildingProject project) {
  final out = <FinishedTask>[
    for (final t in project.todos)
      if (t.isDone)
        (
          todo: t,
          completed: true,
          by: t.completedBy,
          at: t.completed ?? t.created,
          removedBy: '',
        ),
    for (final a in project.todoArchive)
      (
        todo: a.todo,
        completed: a.wasCompleted,
        by: a.by,
        at: a.wasCompleted ? (a.todo.completed ?? a.removedAt) : a.removedAt,
        removedBy: a.removedBy,
      ),
  ];
  out.sort((a, b) => b.at.compareTo(a.at));
  return out;
}

/// The job list's completed and deleted notes, grouped under the person who
/// finished each one, with a filter for one person.
class FinishedTasksPane extends StatefulWidget {
  final BuildingProject project;

  const FinishedTasksPane({super.key, required this.project});

  @override
  State<FinishedTasksPane> createState() => _FinishedTasksPaneState();
}

class _FinishedTasksPaneState extends State<FinishedTasksPane> {
  /// One person, or null for everybody.
  String? _person;
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static String _name(String user) => user.isEmpty ? 'Not recorded' : user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final all = finishedTasks(widget.project);
    if (all.isEmpty) {
      return Padding(
        padding: _headerPad,
        child: Text(
          'Nothing finished yet. Notes ticked off or deleted on the job list '
          'are kept here, under the login of whoever finished them.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      );
    }

    // People in order of how much they finished.
    final counts = <String, int>{};
    for (final t in all) {
      counts[_name(t.by)] = (counts[_name(t.by)] ?? 0) + 1;
    }
    final people = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    if (_person != null && !counts.containsKey(_person)) _person = null;
    final shown = [
      for (final t in all)
        if (_person == null || _name(t.by) == _person) t,
    ];
    final groups = <String, List<FinishedTask>>{
      for (final p in people)
        if (_person == null || p == _person)
          p: [for (final t in shown) if (_name(t.by) == p) t],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: _headerPad,
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const ValueKey('finished_person_all'),
                label: Text('Everyone (${all.length})'),
                selected: _person == null,
                onSelected: (_) => setState(() => _person = null),
              ),
              for (final p in people)
                ChoiceChip(
                  key: ValueKey('finished_person_$p'),
                  label: Text('$p (${counts[p]})'),
                  selected: _person == p,
                  onSelected: (_) => setState(() => _person = p),
                ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.only(left: 24, right: 20),
              children: [
                for (final g in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Text(
                      '${g.key} - ${g.value.where((t) => t.completed).length} '
                      'completed, ${g.value.where((t) => !t.completed).length} '
                      'deleted',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  for (final t in g.value) _FinishedRow(task: t),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FinishedRow extends StatelessWidget {
  final FinishedTask task;

  const _FinishedRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final t = task.todo;
    final scope = t.scopeLabel.trim();
    final notes = [
      task.completed ? 'Completed' : 'Deleted',
      '${formatEditDay(task.at)}${task.completed ? '' : ' ${formatEditTime(task.at)}'}',
      if (scope.isNotEmpty) scope,
      // Cleared by somebody other than who finished it: both are named.
      if (task.completed &&
          task.removedBy.isNotEmpty &&
          task.removedBy != task.by)
        'cleared by ${task.removedBy}',
    ];
    return Padding(
      key: ValueKey('finished_${t.id}'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            task.completed ? Icons.check_circle_outline : Icons.delete_outline,
            size: 15,
            color: task.completed ? Colors.green.shade600 : muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: t.text,
                    style: TextStyle(
                      decoration: task.completed
                          ? null
                          : TextDecoration.lineThrough,
                    ),
                  ),
                  TextSpan(
                    text: '   ${notes.join('  ·  ')}',
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  THE WHOLE LOG, FROM ANYWHERE
// ---------------------------------------------------------------------------

/// Which log is on screen.
enum HistoryScope { both, project, room }

const Map<HistoryScope, String> kHistoryScopeLabels = {
  HistoryScope.both: 'Everything',
  HistoryScope.project: 'The job',
  HistoryScope.room: 'This room',
};

/// The history, off the toolbar.
///
/// A DIALOG RATHER THAN A PANE, and off the toolbar rather than the Project
/// tab, because the log is not a thing about the job in particular. It is
/// about the SESSION: half of what somebody wants to look up happened on a
/// drawing tab, and having to leave that tab and go to the project to find out
/// what they just changed is the reason nobody looked.
Future<void> showHistoryDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _HistoryDialog(),
);

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog();

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

/// What the dialog's own content is inset by, now that the content padding is
/// zero so the scrollbar can sit at the edge. The Material default, so the
/// header still lines up with every other dialog in the app.
const EdgeInsets _headerPad = EdgeInsets.symmetric(horizontal: 24);

class _HistoryDialogState extends State<_HistoryDialog> {
  HistoryScope _scope = HistoryScope.both;

  /// Shared by the bar and the list, because a Scrollbar with no controller
  /// and a ListView with none are two different scroll positions and the
  /// thumb ends up tracking nothing.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);

    final hasProject = provider.hasOpenProject;
    final hasRoom = provider.roomConfig.isNotEmpty;

    // Tagged as they are merged, so a combined list can still say which
    // document each line came out of — otherwise "Deadline set to 14 Jun" and
    // "Baud rate was 9600, now 115200" read as entries in the same file.
    final rows = <({ProjectEdit edit, HistoryScope from})>[
      if (_scope != HistoryScope.room)
        for (final e in provider.project.history)
          (edit: e, from: HistoryScope.project),
      if (_scope != HistoryScope.project)
        for (final e in provider.roomHistory)
          (edit: e, from: HistoryScope.room),
    ]..sort((a, b) => b.edit.at.compareTo(a.edit.at));

    final changes = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Only offered when there are two logs to choose between. On a
            // session with just a room open, a switcher whose other two
            // options are both empty is a control that can only disappoint.
            if (hasProject && hasRoom)
              Padding(
                padding: _headerPad,
                child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<HistoryScope>(
                  segments: [
                    for (final scope in HistoryScope.values)
                      ButtonSegment(
                        value: scope,
                        label: Text(
                          kHistoryScopeLabels[scope]!,
                          key: ValueKey('history_scope_${scope.name}'),
                        ),
                      ),
                  ],
                  selected: {_scope},
                  onSelectionChanged: (v) => setState(() => _scope = v.first),
                ),
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: _headerPad,
              child: Text(
              rows.isEmpty
                  ? 'Nothing recorded yet. Edits to this room and decisions on '
                      'the job are logged here as they are made, with the '
                      'login of whoever made them.'
                  : '${rows.length} change${rows.length == 1 ? '' : 's'}, '
                      'newest first. Every one is stamped with the Windows '
                      'login it was made under.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              ),
            ),
            const Divider(),
            Expanded(
              child: rows.isEmpty
                  ? const SizedBox.shrink()
                  : Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: ListView.builder(
                      controller: _scroll,
                      // The rows keep the inset the header has; the gap on the
                      // right is the lane the thumb runs in, so it never lands
                      // on a word.
                      padding: const EdgeInsets.only(left: 24, right: 20),
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _EditRow(
                        edit: rows[i].edit,
                        showDay: i == 0 ||
                            !_sameDay(rows[i].edit.at, rows[i - 1].edit.at),
                        // The badge earns its place only while both logs are
                        // on screen at once.
                        source: _scope == HistoryScope.both
                            ? rows[i].from
                            : null,
                      ),
                      ),
                    ),
            ),
          ],
        );

    return AlertDialog(
      key: const ValueKey('history_dialog'),
      title: const Text('What has been changed'),
      // THE SCROLLBAR RIDES THE DIALOG'S EDGE, not the text's. With the
      // default content padding the list stops 24px in and the thumb comes
      // down on top of the last words of every long line. So the padding is
      // taken off here and put back on the things that are NOT the list -
      // see [_headerPad] - which leaves the bar out at the edge where a
      // scrollbar belongs and the rows clear of it.
      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
      content: SizedBox(
        width: 760,
        height: 560,
        // FINISHED TASKS, ON A TAB OF THEIR OWN: the job list's completed and
        // deleted notes, by who finished them - see [FinishedTasksPane].
        child: !hasProject
            ? changes
            : DefaultTabController(
                length: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(
                          key: ValueKey('history_tab_changes'),
                          text: 'Changes',
                        ),
                        Tab(
                          key: ValueKey('history_tab_finished'),
                          text: 'Finished tasks',
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TabBarView(
                        children: [
                          changes,
                          FinishedTasksPane(project: provider.project),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('history_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
