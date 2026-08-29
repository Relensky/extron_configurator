import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_state.dart';
import 'project_schedule.dart' show formatScheduleDate;
import 'project_timeline_view.dart' show showProjectDatePicker;

/// ============================================================================
///  SETTING A JOB UP ON THE DAY IT STARTS
/// ============================================================================
///  A new project used to arrive as an empty shell: a name nobody had typed, no
///  rooms, no deadline, and a to-do list somebody would start keeping in a
///  notebook instead. Every one of those is a thing that gets filled in
///  eventually — and "eventually" is the problem, because the schedule, the
///  spares check and the reminders all read facts that were never entered.
///
///  So the questions are asked ONCE, at the start, in the order somebody
///  actually answers them:
///
///    1. WHAT IS THIS JOB. The name on the front of the quote, the building,
///       the number it is billed under, and who it is for.
///    2. WHICH ROOMS. Pointed at a FOLDER rather than picked file by file - a
///       building's rooms live together on a share, and picking eighteen of
///       them out of a file dialog is how somebody ends up adding four and
///       coming back for the rest next week.
///    3. WHEN IT IS DUE. One date, and every order-by date on the job derives
///       from it.
///    4. WHAT HAS TO BE DONE FIRST. The four or five things that are true of
///       every job, offered rather than typed.
///
///  WHAT IT HOLDS SPARE IS NOT ASKED. It used to be - a percentage, typed
///  before the job had any parts on it - and the rule it fed has been replaced
///  by one that needs no policy: one spare of everything a room installs. See
///  [ProjectEstimate.unsparedParts].
///
///  NOTHING HERE IS COMPULSORY. Skip leaves exactly the empty project this
///  screen replaced, and every field on it is editable afterwards on the tab it
///  belongs to. It is a head start, not a gate.
/// ============================================================================

/// What the setup screen came back with.
typedef NewProjectSetup = ({
  String name,
  String building,
  String projectNumber,
  String stakeholder,

  /// Absolute paths of the room configs to put on the job, in the order they
  /// are to be added.
  List<String> roomPaths,

  /// The date the job needs everything by, or null when nobody has said.
  DateTime? deadline,

  /// The notes to start the job's list with.
  List<String> todos,
});

/// The room configs under [folder], deepest folder last, in a stable order.
///
/// A ROOM CONFIG IS A FILE ENDING IN `config.json`. That catches both spellings
/// this app writes — `BSS_101_config.json` beside the room's other files, and a
/// bare `config.json` in a folder of its own — and it excludes everything that
/// lives beside one: the sidecars are `_config_av_flow.json` and
/// `_config_cost.json`, the job itself is `_project.json`, and none of them end
/// in `config.json`.
///
/// [maxDepth] is how many folders down to look. Two by default, which covers
/// the two ways THIS APP lays a share out: every room's files loose in one
/// folder, and a folder per room inside a folder for the building. Going
/// deeper finds backup copies and old revisions, which is worse than missing a
/// room — a room that was missed can be added, and a room added twice doubles
/// its cost on the quote.
///
/// A share that keeps its configs further down — a processor export lands as
/// `BSS 101/code/upload_to_root/config.json`, which is four folders down — is
/// covered by raising [AppStateProvider.roomScanDepth] in App Config once,
/// rather than by deepening the default for everybody.
///
/// [skipAppConfig] keeps the app's OWN `app_config.json` out of the list. It
/// ends in `config.json` and it is not a room, and somebody who points this at
/// their working folder should not have it offered.
List<String> findRoomConfigs(
  String folder, {
  int maxDepth = AppStateProvider.kDefaultRoomScanDepth,
}) {
  final out = <String>[];

  void walk(Directory dir, int depth) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      // A folder that cannot be read is skipped rather than fatal: a share
      // with one locked subfolder in it should still hand back the rooms.
      return;
    }
    entries.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    for (final entry in entries) {
      if (entry is File) {
        final name = path.basename(entry.path).toLowerCase();
        if (!name.endsWith('config.json')) continue;
        if (name == 'app_config.json') continue;
        out.add(entry.path);
      } else if (entry is Directory && depth < maxDepth) {
        walk(entry, depth + 1);
      }
    }
  }

  final root = Directory(folder);
  if (!root.existsSync()) return out;
  walk(root, 1);
  return out;
}

/// [findRoomConfigs] in the shape [compute] can hand to a background isolate:
/// one positional argument, and a return value that can cross between them.
///
/// Top-level rather than a closure because that is the only kind of function
/// an isolate can be started on — a closure captures the widget it was written
/// inside, and none of that can be sent.
List<String> scanRoomConfigs(({String folder, int maxDepth}) args) =>
    findRoomConfigs(args.folder, maxDepth: args.maxDepth);

/// The notes nearly every job starts with, offered rather than typed.
///
/// Offered because they are the ones that are true before anybody has looked
/// at the building: the deadline is somebody else's to confirm, the lead times
/// come from vendors who have not been rung yet, and the rooms have not been
/// walked. A job that starts with these four on its list is a job where the
/// first week's questions are already written down.
const List<String> kStarterProjectTodos = [
  'Confirm the delivery deadline with the stakeholder',
  'Get lead times from the vendors for the long-pole parts',
  'Walk the rooms and check what is already installed',
  'Send the quote requests out',
];

/// Puts a filled-in setup onto the open project, and says what it did.
///
/// Applied here rather than inside the dialog so the same answers can be
/// applied by a test, and so the dialog stays a form: it collects, this
/// commits.
String applyProjectSetup(AppStateProvider provider, NewProjectSetup setup) {
  provider.setProjectField(
    name: setup.name.trim(),
    building: setup.building.trim(),
    projectNumber: setup.projectNumber.trim(),
    stakeholder: setup.stakeholder.trim(),
  );

  var added = 0;
  final problems = <String>[];
  for (final room in setup.roomPaths) {
    final error = provider.addRoomToProject(room);
    if (error.isEmpty) {
      added++;
    } else {
      problems.add(error);
    }
  }

  if (setup.deadline != null) provider.setProjectDeadline(setup.deadline);
  for (final todo in setup.todos) {
    provider.addProjectTodo(todo);
  }

  return [
    'New project started',
    if (added > 0) '$added room${added == 1 ? '' : 's'} added',
    if (setup.deadline != null)
      'due ${formatScheduleDate(setup.deadline!)}',
    if (setup.todos.isNotEmpty)
      '${setup.todos.length} note${setup.todos.length == 1 ? '' : 's'} on the '
          'list',
    if (problems.isNotEmpty) problems.first,
  ].join('. ');
}

/// Asks the questions. Null when the user skipped.
///
/// [scanDepth] is how many folders down "Find rooms in a folder…" looks —
/// passed in rather than read off the provider here so the form stays a form,
/// and so a test can open it without an app around it.
Future<NewProjectSetup?> showProjectSetupDialog(
  BuildContext context, {
  String name = '',
  String building = '',
  int scanDepth = AppStateProvider.kDefaultRoomScanDepth,
}) => showDialog<NewProjectSetup>(
  context: context,
  // Not dismissible on a tap outside: this is a form somebody is halfway
  // through typing into, and a stray click on the scrim would throw away four
  // answers with no way back.
  barrierDismissible: false,
  builder: (_) => _ProjectSetupDialog(
    name: name,
    building: building,
    scanDepth: scanDepth,
  ),
);

class _ProjectSetupDialog extends StatefulWidget {
  final String name;
  final String building;
  final int scanDepth;

  const _ProjectSetupDialog({
    required this.name,
    required this.building,
    required this.scanDepth,
  });

  @override
  State<_ProjectSetupDialog> createState() => _ProjectSetupDialogState();
}

class _ProjectSetupDialogState extends State<_ProjectSetupDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  late final TextEditingController _building = TextEditingController(
    text: widget.building,
  );
  final TextEditingController _projectNumber = TextEditingController();
  final TextEditingController _stakeholder = TextEditingController();
  final TextEditingController _todo = TextEditingController();

  /// Every room found so far, and whether it is going on the job.
  ///
  /// Found rooms are TICKED and shown rather than added silently: a folder of
  /// eighteen configs usually holds one that is a spare copy or a room on
  /// somebody else's job, and a list nobody could untick would make this
  /// button dangerous to press.
  final Map<String, bool> _rooms = {};

  /// The folders that have been scanned, so a second look at the same one does
  /// not report "0 rooms found" when it found them all the first time.
  final Set<String> _scanned = {};

  DateTime? _deadline;

  /// Which starter notes are going on the list. All of them by default: they
  /// are the questions of the first week whether or not anybody writes them
  /// down, and unticking is cheaper than typing.
  final Set<String> _starters = {...kStarterProjectTodos};

  /// Notes typed here rather than offered.
  final List<String> _typed = [];

  bool _scanning = false;

  @override
  void dispose() {
    _name.dispose();
    _building.dispose();
    _projectNumber.dispose();
    _stakeholder.dispose();
    _todo.dispose();
    super.dispose();
  }

  Future<void> _findRooms() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Where do this building\'s room configs live?',
    );
    if (folder == null || !mounted) return;

    setState(() => _scanning = true);
    // OFF THE UI THREAD FOR REAL — a background isolate, not a later turn of
    // this one.
    //
    // This used to be `Future(() => findRoomConfigs(...))`, which schedules the
    // work as its own event and then runs every synchronous `listSync` of it on
    // the same thread that draws the window. On a local folder nobody noticed.
    // On a departmental share with a few hundred room folders on it, walking
    // the tree is seconds of blocking I/O with no frames in between, and an app
    // that paints nothing and answers no clicks for seconds is an app somebody
    // reports as frozen.
    //
    // A share that has gone away is worse still: an SMB path waiting on a dead
    // host blocks until the network stack gives up, which is tens of seconds.
    // Both of those now happen somewhere else, and the dialog keeps saying
    // "Looking…" and keeps responding while they do.
    final List<String> found;
    try {
      found = await compute(scanRoomConfigs, (
        folder: folder,
        maxDepth: widget.scanDepth,
      ));
    } catch (_) {
      // An isolate that could not be started or died mid-walk leaves the form
      // exactly as it was, minus the spinner. Nothing has been added, and the
      // button can simply be pressed again.
      if (mounted) setState(() => _scanning = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _scanned.add(folder);
      for (final room in found) {
        // Already listed is left as it is: a second scan of an overlapping
        // folder must not re-tick a room somebody deliberately unticked.
        _rooms.putIfAbsent(room, () => true);
      }
    });
  }

  /// What to show under a room's file name.
  ///
  /// The folder RELATIVE to the one that was scanned, because on a nested
  /// share every config is called `config.json` and every full path starts
  /// with the same forty characters of share name — which is exactly the part
  /// an ellipsis keeps. `BSS 101/code/upload_to_root` says which room it is;
  /// the full path to it, cut off after the share name, does not.
  String _folderLabel(String room) {
    final dir = path.dirname(room);
    for (final root in _scanned) {
      if (!path.isWithin(root, room)) continue;
      final rel = path.relative(dir, from: root);
      return rel == '.' ? path.basename(root) : rel;
    }
    return dir;
  }

  void _addTypedTodo() {
    final text = _todo.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _typed.add(text);
      _todo.clear();
    });
  }

  List<String> get _chosenRooms =>
      [for (final e in _rooms.entries) if (e.value) e.key];

  List<String> get _chosenTodos => [
    for (final t in kStarterProjectTodos)
      if (_starters.contains(t)) t,
    ..._typed,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = _chosenRooms.length;

    return AlertDialog(
      key: const ValueKey('project_setup_dialog'),
      title: const Text('Set up this project'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Everything here can be changed afterwards, and none of it is '
                'required - but a job that answers these on day one is a job '
                'whose schedule and spares checks work from day one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const _SetupHeading('THE JOB'),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: const ValueKey('setup_name'),
                      controller: _name,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Project name',
                        hintText: 'Holt Hall Refresh',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: const ValueKey('setup_building'),
                      controller: _building,
                      decoration: const InputDecoration(
                        labelText: 'Building',
                        hintText: 'BSS',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('setup_project_number'),
                      controller: _projectNumber,
                      decoration: const InputDecoration(
                        labelText: 'Project number',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('setup_stakeholder'),
                      controller: _stakeholder,
                      decoration: const InputDecoration(
                        labelText: 'For whom',
                        hintText: 'the department, the dean, facilities',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),

              // THE ROOMS, by the folder they live in. See the file header on
              // why this is a folder and not a file dialog.
              const _SetupHeading('THE ROOMS'),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('setup_find_rooms'),
                    onPressed: _scanning ? null : _findRooms,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(
                      _rooms.isEmpty
                          ? 'Find rooms in a folder…'
                          : 'Add another folder…',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _scanning
                          ? 'Looking…'
                          : _rooms.isEmpty
                              ? _scanned.isEmpty
                                  ? 'Point at the folder the room configs are '
                                      'in. Rooms can also be added later on '
                                      'the Project tab.'
                                  : 'No room configs within '
                                      '${widget.scanDepth} folder'
                                      '${widget.scanDepth == 1 ? '' : 's'} of '
                                      'that one. If they sit deeper - in a '
                                      'code/upload_to_root under each room, '
                                      'say - raise "How deep to look for room '
                                      'configs" in App Config.'
                              : '$chosen of ${_rooms.length} going on the job',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (_rooms.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 190),
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final room in _rooms.keys)
                        CheckboxListTile(
                          key: ValueKey('setup_room_${path.basename(room)}'),
                          dense: true,
                          value: _rooms[room] ?? false,
                          title: Text(
                            path.basename(room),
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                          // The folder under the file name, because on a share
                          // laid out one folder per room every file is called
                          // config.json and the folder is the only thing that
                          // says which room it is.
                          subtitle: Text(
                            _folderLabel(room),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (v) =>
                              setState(() => _rooms[room] = v ?? false),
                        ),
                    ],
                  ),
                ),

              // WHEN IT IS DUE. One date, and every order-by date on the job
              // is worked out from it — see project_schedule.dart.
              const _SetupHeading('WHEN IT IS DUE'),
              Row(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('setup_deadline'),
                    onPressed: () async {
                      final picked = await showProjectDatePicker(
                        context,
                        initial: _deadline,
                        title: 'Delivery deadline',
                      );
                      if (picked == null) return;
                      setState(() => _deadline = picked.date);
                    },
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(
                      _deadline == null
                          ? 'Set the delivery deadline'
                          : 'Due ${formatScheduleDate(_deadline!)}',
                    ),
                  ),
                  if (_deadline != null)
                    IconButton(
                      key: const ValueKey('setup_deadline_clear'),
                      tooltip: 'No deadline yet',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _deadline = null),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Every order-by date on the job is worked back from '
                      'this and the parts\' lead times.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),

              // WHAT HAS TO BE DONE FIRST.
              const _SetupHeading('WHAT HAS TO BE DONE FIRST'),
              for (final starter in kStarterProjectTodos)
                CheckboxListTile(
                  key: ValueKey('setup_todo_${kStarterProjectTodos.indexOf(
                    starter,
                  )}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _starters.contains(starter),
                  title: Text(starter, style: theme.textTheme.bodySmall),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _starters.add(starter);
                    } else {
                      _starters.remove(starter);
                    }
                  }),
                ),
              for (final typed in _typed)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.check_box_outlined, size: 18),
                  title: Text(typed, style: theme.textTheme.bodySmall),
                  trailing: IconButton(
                    tooltip: 'Take it off the list',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _typed.remove(typed)),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('setup_todo_text'),
                      controller: _todo,
                      decoration: const InputDecoration(
                        labelText: 'Anything else that has to happen',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addTypedTodo(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('setup_todo_add'),
                    tooltip: 'Put it on the list',
                    icon: const Icon(Icons.add),
                    onPressed: _addTypedTodo,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        // SKIP LEAVES THE EMPTY PROJECT, which is exactly what starting a new
        // job used to give. Named for what it does rather than 'Cancel': the
        // project has already been started by the time this is on screen, and
        // 'Cancel' would read as a way to undo that.
        TextButton(
          key: const ValueKey('setup_skip'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Skip for now'),
        ),
        FilledButton(
          key: const ValueKey('setup_confirm'),
          onPressed: () => Navigator.of(context).pop((
            name: _name.text,
            building: _building.text,
            projectNumber: _projectNumber.text,
            stakeholder: _stakeholder.text,
            roomPaths: _chosenRooms,
            deadline: _deadline,
            todos: _chosenTodos,
          )),
          child: const Text('Start the project'),
        ),
      ],
    );
  }
}

/// A section heading inside the setup form.
class _SetupHeading extends StatelessWidget {
  final String label;

  const _SetupHeading(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
