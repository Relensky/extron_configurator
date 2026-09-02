import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'live_text_field.dart';
import 'project_estimate.dart';
import 'project_schedule.dart';
import 'project_timeline_view.dart'
    show ClearDateButton, showProjectDatePicker;

/// ============================================================================
///  THE JOB'S TO-DO LIST
/// ============================================================================
///  Every other pane on this tab answers a question about the BUILDING: what is
///  in it, what it costs, who sells it, when it has to be ordered. This one is
///  the only place for the other half of a job — the things that are true of
///  the work rather than of the product.
///
///    "client wants the second display moved to the north wall"
///    "chase Extron on the DTP lead time"
///    "check whether 214 is still in scope before we quote it"
///
///  Those used to live in an email thread, and the cost of that is not that
///  they get lost — it is that the person who picks the job back up in three
///  weeks has no way of knowing they existed. The project file is the document
///  that gets opened then, so it is where they belong.
///
///  DELIBERATELY PLAIN: a note, a state, a room it is about, and a date it has
///  to be done by. No assignees and no priority ladder — a to-do list that
///  needs its own workflow is one people stop filling in.
///
///  THE DATE IS OPTIONAL, and the list is built around that. Most notes never
///  get one, so an undated note never nags and never sorts to the top; the ones
///  that carry a date carry a real one, and those sort first, color as they
///  approach, and turn up in the briefing when a project is opened.
///
///  NOTHING IS DELETED BY TICKING IT. Done items stay on the list, grayed, with
///  the date they were finished, because "when did we agree to move that
///  display" is a question that gets asked. Clearing them is one explicit
///  button.
/// ============================================================================

/// The to-do pane, as slivers for the project tab's one scroll view.
List<Widget> todoSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.watch<AppStateProvider>();
  final project = provider.project;
  final todos = project.todos;

  // Open first, then the done ones newest-first, which is the order somebody
  // reads a history in.
  //
  // Within the open list: DATED ITEMS FIRST, soonest due at the top, because a
  // date somebody put on a note is the strongest statement of what matters on
  // this list. Undated notes follow, oldest first — one that has been sitting
  // three weeks is the one worth looking at. Blocked sinks below both, since
  // the list should start with what can be picked up today.
  final now = today();
  final open = [for (final t in todos) if (t.isOpen) t]
    ..sort((a, b) {
      final byState = a.state.index.compareTo(b.state.index);
      if (byState != 0) return byState;
      final ad = a.due;
      final bd = b.due;
      if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
      if (ad == null && bd != null) return 1;
      if (ad != null && bd == null) return -1;
      return a.created.compareTo(b.created);
    });
  final done = [for (final t in todos) if (t.isDone) t]
    ..sort((a, b) => (b.completed ?? b.created).compareTo(
          a.completed ?? a.created,
        ));

  // THE BUILDING CODE AND ROOM NUMBER — 'BSS 103' — not the config file name.
  //
  // A note is filed against a room, and the room somebody means is the one on
  // the door. Falling through to the file name put "BSS_101_config" on the
  // list, which is an artifact of how the room is stored and not a thing
  // anybody calls it. See [ProjectRoomCost.codeName].
  //
  // Built once here and handed to the picker, the menu and every row, so all
  // three name a room the same way — a note that says "BSS 103" in the list
  // and something else in its own dropdown is a note nobody trusts.
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};

  /// The rooms a note can be filed against, in project order, with the name
  /// each is shown under. Rooms that failed to read are still offered: a note
  /// about a room whose file is missing is exactly the note somebody needs to
  /// be able to write.
  final roomChoices = [
    for (final r in estimate.rooms) (id: r.ref.id, name: roomNames[r.ref.id]!),
  ];

  return [
    SliverToBoxAdapter(
      child: _AddTodoBar(provider: provider, rooms: roomChoices),
    ),
    if (todos.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 24),
          child: Center(
            child: Text(
              'Nothing on the list.\n\n'
              'This is the job\'s own notebook - the change the client asked '
              'for, the vendor to chase, the room whose scope is not settled. '
              'It is saved with the project, so it is still here the next time '
              'somebody opens it.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else ...[
      if (open.isNotEmpty)
        SliverToBoxAdapter(
          child: _SectionLabel(
            text: () {
              final late = project.overdueTodos(now).length;
              return late == 0
                  ? 'TO DO (${open.length})'
                  : 'TO DO (${open.length}) - $late PAST ITS DATE';
            }(),
            warn: project.overdueTodos(now).isNotEmpty,
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        sliver: SliverList.builder(
          itemCount: open.length,
          itemBuilder: (context, i) => _TodoRow(
            todo: open[i],
            provider: provider,
            estimate: estimate,
            roomNames: roomNames,
            rooms: roomChoices,
          ),
        ),
      ),
      if (done.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(child: _SectionLabel(text: 'DONE (${done.length})')),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: TextButton.icon(
                  key: const ValueKey('todo_clear_done'),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear done'),
                  onPressed: () => provider.clearDoneProjectTodos(),
                ),
              ),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverList.builder(
            itemCount: done.length,
            itemBuilder: (context, i) => _TodoRow(
              todo: done[i],
              provider: provider,
              estimate: estimate,
              roomNames: roomNames,
              rooms: roomChoices,
            ),
          ),
        ),
      ],
    ],
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

class _SectionLabel extends StatelessWidget {
  final String text;

  /// Reads in the error color — used when the heading is carrying a count of
  /// things that have gone past their date.
  final bool warn;

  const _SectionLabel({required this.text, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: warn
              ? errorTextOn(theme.colorScheme, theme.scaffoldBackgroundColor)
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The one row at the top that everything gets added from.
///
/// A plain field and a button rather than a dialog: the whole value of a job
/// list is that writing something down costs nothing, and a modal between the
/// thought and the note is enough friction to lose it.
class _AddTodoBar extends StatefulWidget {
  final AppStateProvider provider;

  /// Room id and the name to show it under — the building code and number.
  /// Passed in rather than read off the project, which only knows each room's
  /// file path and label and so cannot name one.
  final List<({String id, String name})> rooms;

  const _AddTodoBar({required this.provider, required this.rooms});

  @override
  State<_AddTodoBar> createState() => _AddTodoBarState();
}

/// The sentinel the scope dropdown uses for "something I will type".
///
/// Not a room id — those are always `room<n>` — so it can never collide with
/// one, the same trick the parts list's filters use.
const String _kCustomScope = '<custom>';

class _AddTodoBarState extends State<_AddTodoBar> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _scope = TextEditingController();
  final FocusNode _focus = FocusNode();
  final FocusNode _scopeFocus = FocusNode();

  /// '' for the job, a room id, or [_kCustomScope] when the scope is typed.
  String _scopeChoice = '';

  @override
  void dispose() {
    _text.dispose();
    _scope.dispose();
    _focus.dispose();
    _scopeFocus.dispose();
    super.dispose();
  }

  void _add() {
    if (_text.text.trim().isEmpty) return;
    final custom = _scopeChoice == _kCustomScope;
    widget.provider.addProjectTodo(
      _text.text,
      roomId: custom ? '' : _scopeChoice,
      scopeLabel: custom ? _scope.text : '',
    );
    _text.clear();
    // The SCOPE is deliberately left as it was. Notes arrive in batches about
    // the same thing — three about Extron, four about the punch list — and
    // resetting the picker after every one would mean setting it every time.
    _focus.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rooms = widget.rooms;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('todo_new_text'),
              controller: _text,
              focusNode: _focus,
              decoration: const InputDecoration(
                labelText: 'Add to the job list',
                hintText: 'client wants the second display moved',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
          // What the note is ABOUT: the job, one room, or something typed.
          // The third exists because a job does not divide cleanly into the
          // first two — "Extron", "the punch list", "phase 2" are each a
          // handful of notes and a room dropdown can name none of them.
          const SizedBox(width: 8),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              key: const ValueKey('todo_new_room'),
              initialValue: _scopeChoice,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'About',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('The job')),
                for (final r in rooms)
                  DropdownMenuItem(
                    value: r.id,
                    child: Text(r.name, overflow: TextOverflow.ellipsis),
                  ),
                const DropdownMenuItem(
                  value: _kCustomScope,
                  child: Text('Something else…'),
                ),
              ],
              onChanged: (v) => setState(() => _scopeChoice = v ?? ''),
            ),
          ),
          if (_scopeChoice == _kCustomScope) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 170,
              // An Autocomplete over the labels already in use, because a
              // second "Punch List" beside an existing "punch list" splits the
              // group in two and nothing would ever say so.
              child: RawAutocomplete<String>(
                textEditingController: _scope,
                focusNode: _scopeFocus,
                optionsBuilder: (value) {
                  final typed = value.text.trim().toLowerCase();
                  return [
                    for (final label in widget.provider.project.todoScopeLabels)
                      if (typed.isEmpty || label.toLowerCase().contains(typed))
                        label,
                  ];
                },
                fieldViewBuilder: (_, controller, focus, onSubmit) => TextField(
                  key: const ValueKey('todo_new_scope'),
                  controller: controller,
                  focusNode: focus,
                  decoration: const InputDecoration(
                    labelText: 'Called',
                    hintText: 'punch list',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _add(),
                ),
                optionsViewBuilder: (context, onSelected, options) => Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    child: SizedBox(
                      width: 170,
                      child: ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final o in options)
                            ListTile(
                              dense: true,
                              title: Text(o),
                              onTap: () => onSelected(o),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: FilledButton.icon(
              key: const ValueKey('todo_add'),
              onPressed: _text.text.trim().isEmpty ? null : _add,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The due date on one note: sets it, changes it, clears it.
///
/// A text button rather than a field, and nothing at all until somebody presses
/// it. Most notes on a job never get a date and should not — a deadline on
/// everything is a deadline on nothing — so the unset state is a quiet "Add a
/// date" rather than an empty box asking to be filled in.
class _DueButton extends StatelessWidget {
  final ProjectTodo todo;
  final AppStateProvider provider;

  const _DueButton({required this.todo, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = todo.due;
    final overdue = todo.isOverdue();
    final gap = todo.daysUntilDue();

    final color = due == null
        ? theme.colorScheme.onSurfaceVariant
        : overdue
            ? errorTextOn(theme.colorScheme, theme.cardColor)
            : (gap ?? 99) <= 7
                ? theme.colorScheme.tertiary
                : theme.colorScheme.onSurfaceVariant;

    final button = InkWell(
      key: ValueKey('todo_due_${todo.id}'),
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final picked = await showProjectDatePicker(
          context,
          initial: due,
          title: 'Due by',
        );
        if (picked == null) return;
        provider.setProjectTodoDue(todo.id, picked.date);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              due == null
                  ? Icons.event_available_outlined
                  : overdue
                      ? Icons.event_busy
                      : Icons.event,
              size: 12,
              color: color,
            ),
            const SizedBox(width: 3),
            Text(
              due == null
                  ? 'Add a date'
                  : 'due ${formatScheduleDate(due)} '
                      '(${formatDayGap(gap ?? 0)})',
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: overdue ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );

    // Nothing to take off until there is a date. Its own control rather than
    // an option inside the picker, so backing out of the picker and deleting
    // the date can never be the same gesture.
    if (due == null) return button;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        ClearDateButton(
          buttonKey: ValueKey('todo_due_clear_${todo.id}'),
          tooltip: 'Take the date off this note',
          onPressed: () => provider.setProjectTodoDue(todo.id, null),
        ),
      ],
    );
  }
}

/// What a note is filed under, as a control that changes it.
///
/// Three answers, which is what a real job needs: the whole job, one room, or
/// something somebody types. The third is not a fallback — "Extron", "the
/// punch list", "phase 2" are each a handful of notes, and no list of rooms
/// can name any of them.
class _ScopeButton extends StatelessWidget {
  final ProjectTodo todo;
  final AppStateProvider provider;

  /// The same room names the picker offers — see [todoSlivers].
  final List<({String id, String name})> rooms;

  /// The resolved name, or '' when the note is about the job as a whole.
  final String label;
  final IconData icon;

  const _ScopeButton({
    required this.todo,
    required this.provider,
    required this.rooms,
    required this.label,
    required this.icon,
  });

  static const String _job = '<job>';
  static const String _custom = '<custom>';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return PopupMenuButton<String>(
      key: ValueKey('todo_scope_${todo.id}'),
      tooltip: 'What this note is about',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        const PopupMenuItem(value: _job, child: Text('The job')),
        for (final r in rooms)
          PopupMenuItem(value: r.id, child: Text(r.name)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: _custom, child: Text('Something else…')),
      ],
      onSelected: (value) async {
        if (value == _job) {
          provider.setProjectTodoRoom(todo.id, '');
          provider.setProjectTodoScopeLabel(todo.id, '');
          return;
        }
        if (value != _custom) {
          provider.setProjectTodoRoom(todo.id, value);
          return;
        }
        final typed = await _askForScope(context, provider, todo.scopeLabel);
        if (typed == null) return;
        provider.setProjectTodoScopeLabel(todo.id, typed);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            label.isEmpty ? Icons.work_outline : icon,
            size: 12,
            color: muted,
          ),
          const SizedBox(width: 3),
          Text(
            label.isEmpty ? 'the job' : label,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          Icon(Icons.arrow_drop_down, size: 14, color: muted),
        ],
      ),
    );
  }
}

/// Asks for a scope to file a note under. Null when the user backed out;
/// blank is a real answer and means "back on the job".
Future<String?> _askForScope(
  BuildContext context,
  AppStateProvider provider,
  String initial,
) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('File this note under'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('todo_scope_text'),
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Called',
                hintText: 'punch list',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
            const SizedBox(height: 8),
            // The labels already in use, as one tap each. A second "Punch
            // List" beside an existing "punch list" splits the group in two
            // and nothing would ever say so.
            if (provider.project.todoScopeLabels.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final label in provider.project.todoScopeLabels)
                    ActionChip(
                      label: Text(label),
                      onPressed: () => Navigator.of(ctx).pop(label),
                    ),
                ],
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
          key: const ValueKey('todo_scope_save'),
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('File it'),
        ),
      ],
    ),
  );
}

/// One note: tick it, park it, edit it, or throw it away.
class _TodoRow extends StatelessWidget {
  final ProjectTodo todo;
  final AppStateProvider provider;
  final ProjectEstimate estimate;
  final Map<String, String> roomNames;

  /// The same rooms the picker at the top offers, so the menu on a row and
  /// the picker never disagree about what a room is called.
  final List<({String id, String name})> rooms;

  const _TodoRow({
    required this.todo,
    required this.provider,
    required this.estimate,
    required this.roomNames,
    required this.rooms,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final blocked = todo.state == ProjectTodoState.blocked;

    // How long it has been sitting. The useful question about an open item is
    // its age, not the date it was written — "eighteen days" is a prompt and
    // "3 Mar" is a fact somebody has to do arithmetic on.
    final age = daysBetween(todo.created, today());
    final ageText = todo.isDone
        ? todo.completed == null
            ? ''
            : 'done ${formatScheduleDate(todo.completed!)}'
        : age <= 0
            ? 'added today'
            : age == 1
                ? 'added yesterday'
                : 'open $age days';

    // What this note is filed under, and the icon that says which KIND of
    // scope it is — a room the project knows about, or a label somebody typed.
    // Without the distinction a scope called "Bessey 103" would be
    // indistinguishable from the actual room.
    final room = todo.roomId.isEmpty ? '' : roomNames[todo.roomId] ?? '';
    final custom = todo.scopeLabel.trim();
    final scopeText = room.isNotEmpty ? room : custom;
    final scopeIcon = room.isNotEmpty ? Icons.meeting_room : Icons.sell_outlined;

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
        child: Row(
          children: [
            Checkbox(
              key: ValueKey('todo_done_${todo.id}'),
              value: todo.isDone,
              onChanged: (on) => provider.setProjectTodoState(
                todo.id,
                on == true ? ProjectTodoState.done : ProjectTodoState.open,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Editable in place while it is open. A note is written in a
                  // hurry and is usually wrong in some small way an hour
                  // later, and a list that can only be corrected by deleting
                  // and retyping is one that fills up with stale text.
                  //
                  // Finished notes are plain text: they are a record of what
                  // was decided, and a record with an edit box around it
                  // invites somebody to rewrite history by accident.
                  if (todo.isDone)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 0, 0),
                      child: Text(
                        todo.text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: muted,
                        ),
                      ),
                    )
                  else
                    LiveTextField(
                      fieldId: 'todo_text_${todo.id}',
                      initial: todo.text,
                      onChanged: (_) {},
                      onSubmitted: (v) =>
                          provider.setProjectTodoText(todo.id, v),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 4),
                    child: Row(
                      children: [
                        // Editable in place, and on a done note too — filing
                        // something correctly after the fact is exactly what
                        // somebody does when they come back to a finished
                        // list looking for one thing.
                        _ScopeButton(
                          todo: todo,
                          provider: provider,
                          rooms: rooms,
                          label: scopeText,
                          icon: scopeIcon,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          ageText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                        if (!todo.isDone) ...[
                          const SizedBox(width: 10),
                          _DueButton(todo: todo, provider: provider),
                        ] else if (todo.due != null) ...[
                          const SizedBox(width: 10),
                          Text(
                            'was due ${formatScheduleDate(todo.due!)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                        if (blocked) ...[
                          const SizedBox(width: 10),
                          Icon(
                            Icons.pause_circle_outline,
                            size: 12,
                            color: theme.colorScheme.tertiary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            kProjectTodoStateLabels[ProjectTodoState.blocked]!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.tertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!todo.isDone)
              IconButton(
                key: ValueKey('todo_block_${todo.id}'),
                tooltip: blocked
                    ? 'Back on the list - this can be picked up again'
                    : 'Waiting on somebody else',
                icon: Icon(
                  blocked ? Icons.play_circle_outline : Icons.pause_circle_outline,
                  size: 18,
                  color: blocked ? theme.colorScheme.tertiary : null,
                ),
                onPressed: () => provider.setProjectTodoState(
                  todo.id,
                  blocked ? ProjectTodoState.open : ProjectTodoState.blocked,
                ),
              ),
            IconButton(
              key: ValueKey('todo_remove_${todo.id}'),
              tooltip: 'Remove this note',
              icon: Icon(
                Icons.close,
                size: 18,
                color: errorTextOn(theme.colorScheme, theme.cardColor),
              ),
              onPressed: () => provider.removeProjectTodo(todo.id),
            ),
          ],
        ),
      ),
    );
  }
}
