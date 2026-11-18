import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_logger.dart';
import 'app_state.dart';
import 'file_dialogs.dart';

/// ============================================================================
///  BUILD FOR DEPLOYMENT
/// ============================================================================
///  Runs the ControlScript template's own local_build.py for the rooms picked,
///  so a build from here is the same build as one from a terminal or CI: base
///  assets, the room's layout, the room's overlay, device drivers pruned to
///  the ones the room's config names, superseded configs and workbooks left
///  out of upload_to_root, and the Python platform check of every file
///  against the room's processor (Pro 3.5 or Pro xi 3.11).
///
///  The script builds into `<template>/dist/<Room>`. Rooms that build and pass
///  their check are then copied to the distribution folder, when one is set.
/// ============================================================================

/// The script, at the template folder's top.
const String kLocalBuildScript = 'local_build.py';

/// The ControlScript template folder [file] sits in: the nearest folder up
/// holding local_build.py and a rooms folder. Null when there is none.
String? controlScriptRootOf(String file) {
  if (file.isEmpty) return null;
  var dir = path.normalize(path.absolute(file));
  if (!Directory(dir).existsSync()) dir = path.dirname(dir);
  while (true) {
    if (isControlScriptRoot(dir)) return dir;
    final up = path.dirname(dir);
    if (up == dir) return null;
    dir = up;
  }
}

/// True when [dir] has local_build.py and a rooms folder.
bool isControlScriptRoot(String dir) =>
    dir.isNotEmpty &&
    File(path.join(dir, kLocalBuildScript)).existsSync() &&
    Directory(path.join(dir, 'rooms')).existsSync();

/// The template room [file] belongs to - `rooms/<Room>/...` - or ''.
String templateRoomOf(String file, String root) {
  if (file.isEmpty || root.isEmpty) return '';
  final rooms = path.join(root, 'rooms');
  if (!path.isWithin(rooms, file)) return '';
  return path.split(path.relative(file, from: rooms)).first;
}

/// Every room in the template, by name.
List<String> templateRooms(String root) {
  final dir = Directory(path.join(root, 'rooms'));
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<Directory>()
      .map((d) => path.basename(d.path))
      .toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// local_build.py's arguments for [rooms]. Rooms and options always given,
/// so the script never stops to ask.
List<String> localBuildArgs(
  List<String> rooms, {
  bool prune = true,
  bool skipCheck = false,
}) => [
  '-u',
  kLocalBuildScript,
  ...rooms,
  prune ? '--prune-modules' : '--all-modules',
  if (skipCheck) '--skip-check',
];

/// How a room came out of local_build.py.
enum RoomBuildStatus {
  ready('Built and checked'),
  unchecked('Built, platform check skipped'),
  notSafe('Built, but NOT safe to upload'),
  failed('Build failed');

  final String label;
  const RoomBuildStatus(this.label);

  bool get shippable => this == ready || this == unchecked;
}

/// Each room's outcome, from local_build.py's [output] and exit code. The
/// script names the rooms that failed in its closing summary; every other
/// room it was asked for came out fine.
Map<String, RoomBuildStatus> parseLocalBuild(
  String output,
  List<String> rooms,
  int exitCode, {
  bool skipCheck = false,
}) {
  Set<String> named(String prefix) {
    for (final line in const LineSplitter().convert(output)) {
      final t = line.trim();
      if (t.startsWith(prefix)) {
        return t
            .substring(prefix.length)
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    }
    return const {};
  }

  final failed = named('Build failed:');
  final notSafe = named('Built, but NOT safe to upload:');
  // A non-zero exit naming nobody - Python missing a module, a crash before
  // the summary - is a failure of the lot.
  final crashed = exitCode != 0 && failed.isEmpty && notSafe.isEmpty;
  return {
    for (final r in rooms)
      r: crashed || failed.contains(r)
          ? RoomBuildStatus.failed
          : notSafe.contains(r)
          ? RoomBuildStatus.notSafe
          : skipCheck
          ? RoomBuildStatus.unchecked
          : RoomBuildStatus.ready,
  };
}

/// What sits in a built room's upload_to_root besides the two files the
/// program reads there (config.json and the panel's where-used sheet):
/// anything local_build.py did not leave out. Paths relative to
/// upload_to_root.
List<String> extraRootFiles(String builtRoom) {
  final root = Directory(path.join(builtRoom, 'upload_to_root'));
  if (!root.existsSync()) return const [];
  bool runtime(String rel) =>
      rel == 'config.json' || rel.endsWith('_WhereUsedReportSheet.csv');
  return root
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => path.relative(f.path, from: root.path))
      .where((rel) => !runtime(rel))
      .toList()
    ..sort();
}

/// Copies the built [room] from the template's dist into [dest], replacing
/// what an earlier build left there. Returns the copy's folder.
Future<String> copyBuiltRoom(String root, String room, String dest) async {
  final from = Directory(path.join(root, 'dist', room));
  final to = Directory(path.join(dest, room));
  if (path.equals(from.path, to.path)) return to.path;
  if (await to.exists()) await to.delete(recursive: true);
  await for (final e in from.list(recursive: true, followLinks: false)) {
    final target = path.join(to.path, path.relative(e.path, from: from.path));
    if (e is Directory) {
      await Directory(target).create(recursive: true);
    } else if (e is File) {
      await Directory(path.dirname(target)).create(recursive: true);
      await e.copy(target);
    }
  }
  return to.path;
}

/// Runs local_build.py in [root] with [args], handing each line of output
/// to [onLine]. Returns the exit code. [started] gets the process, so it
/// can be stopped.
typedef LocalBuildRunner = Future<int> Function(
  String root,
  List<String> args,
  void Function(String line) onLine,
  void Function(Process process) started,
);

/// The real runner: `python`, else the `py -3` launcher.
Future<int> runLocalBuild(
  String root,
  List<String> args,
  void Function(String line) onLine,
  void Function(Process process) started,
) async {
  Process? process;
  for (final (exe, pre) in const [
    ('python', <String>[]),
    ('py', ['-3']),
  ]) {
    try {
      process = await Process.start(
        exe,
        [...pre, ...args],
        workingDirectory: root,
        environment: const {
          'PYTHONIOENCODING': 'utf-8',
          'PYTHONUNBUFFERED': '1',
        },
      );
      onLine('> $exe ${[...pre, ...args].join(' ')}');
      break;
    } on ProcessException {
      continue;
    }
  }
  if (process == null) {
    onLine('Python was not found. Install Python 3 so "python" or "py" '
        'runs from a command prompt, then build again.');
    return -1;
  }
  started(process);
  // stdin is never read: rooms and options are always on the command line.
  unawaited(process.stdin.close());
  final done = [
    for (final s in [process.stdout, process.stderr])
      s
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine)
          .asFuture<void>(),
  ];
  final code = await process.exitCode;
  await Future.wait(done);
  return code;
}

/// Opens Build for Deployment. [runner] stands in for Python in tests.
Future<void> showDeployBuildDialog(
  BuildContext context, {
  LocalBuildRunner runner = runLocalBuild,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => DeployBuildDialog(runner: runner),
);

class DeployBuildDialog extends StatefulWidget {
  final LocalBuildRunner runner;
  const DeployBuildDialog({super.key, this.runner = runLocalBuild});

  @override
  State<DeployBuildDialog> createState() => _DeployBuildDialogState();
}

class _DeployBuildDialogState extends State<DeployBuildDialog> {
  String _root = '';
  List<String> _rooms = const [];
  final Set<String> _picked = {};
  String _openRoom = '';
  String _filter = '';
  bool _prune = true;
  bool _skipCheck = false;

  bool _running = false;
  Process? _process;
  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();
  Map<String, RoomBuildStatus> _results = const {};
  final Map<String, String> _copiedTo = {};
  final Map<String, List<String>> _extras = {};
  String _copyError = '';

  @override
  void initState() {
    super.initState();
    final p = context.read<AppStateProvider>();
    final fromOpen = controlScriptRootOf(p.currentConfigPath);
    _setRoot(
      fromOpen ??
          (isControlScriptRoot(p.deployTemplatePath)
              ? p.deployTemplatePath
              : ''),
    );
    _openRoom = templateRoomOf(p.currentConfigPath, _root);
    if (_rooms.contains(_openRoom)) _picked.add(_openRoom);
  }

  @override
  void dispose() {
    _process?.kill();
    _logScroll.dispose();
    super.dispose();
  }

  void _setRoot(String root) {
    _root = root;
    _rooms = root.isEmpty ? const [] : templateRooms(root);
    _picked.removeWhere((r) => !_rooms.contains(r));
  }

  /// Where built rooms go to be sent out.
  String _dest(AppStateProvider p) => p.deployOutputPath.isNotEmpty
      ? p.deployOutputPath
      : path.join(_root, 'dist');

  Future<void> _pickRoot(AppStateProvider p) async {
    final dir = await getDirectoryPathCompat(
      dialogTitle: 'The ControlScript template folder (with local_build.py)',
      initialDirectory: _root.isEmpty ? null : _root,
    );
    if (dir == null || !mounted) return;
    if (!isControlScriptRoot(dir)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('That folder has no local_build.py and rooms folder.'),
      ));
      return;
    }
    setState(() => _setRoot(dir));
    await p.updateSetting('deployTemplatePath', dir);
  }

  Future<void> _pickDest(AppStateProvider p) async {
    final dir = await getDirectoryPathCompat(
      dialogTitle: 'Where built rooms are copied to send out',
      initialDirectory: _dest(p),
    );
    if (dir == null || !mounted) return;
    await p.updateSetting(
      'deployOutputPath',
      _root.isNotEmpty && path.equals(dir, path.join(_root, 'dist')) ? '' : dir,
    );
    setState(() {});
  }

  void _line(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _build(AppStateProvider p) async {
    final rooms = _rooms.where(_picked.contains).toList();
    final root = _root;
    final dest = _dest(p);
    setState(() {
      _running = true;
      _log.clear();
      _results = const {};
      _copiedTo.clear();
      _extras.clear();
      _copyError = '';
    });
    AppLogger.logInfo('Build for deployment: ${rooms.join(', ')} in $root');
    int code;
    try {
      code = await widget.runner(
        root,
        localBuildArgs(rooms, prune: _prune, skipCheck: _skipCheck),
        _line,
        (proc) => _process = proc,
      );
    } catch (e, stack) {
      AppLogger.logError('Build for deployment failed to run', e, stack);
      _line('Could not run $kLocalBuildScript: $e');
      code = -1;
    }
    _process = null;
    if (!mounted) return;
    final results = parseLocalBuild(
      _log.join('\n'),
      rooms,
      code,
      skipCheck: _skipCheck,
    );
    for (final r in rooms) {
      if (!results[r]!.shippable) continue;
      _extras[r] = extraRootFiles(path.join(root, 'dist', r));
      try {
        _copiedTo[r] = await copyBuiltRoom(root, r, dest);
      } catch (e, stack) {
        AppLogger.logError('Copy of built $r to $dest failed', e, stack);
        _copyError = 'Could not copy $r to $dest: $e';
      }
    }
    AppLogger.logInfo('Build for deployment done (exit $code): '
        '${results.entries.map((e) => '${e.key} ${e.value.name}').join(', ')}');
    if (!mounted) return;
    setState(() {
      _running = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final shown = _rooms
        .where((r) => r.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
    final openUnsaved = _picked.contains(_openRoom) && p.roomHasUnsavedChanges;

    Widget folderRow(String label, String value, VoidCallback onChange,
            {Key? key}) =>
        Row(
          children: [
            SizedBox(width: 130, child: Text(label, style: small)),
            Expanded(
              child: SelectableText(
                value.isEmpty ? 'Not set' : value,
                key: key,
                style: small?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            TextButton(
              onPressed: _running ? null : onChange,
              child: const Text('Change...'),
            ),
          ],
        );

    return AlertDialog(
      key: const ValueKey('deploy_build_dialog'),
      title: const Text('Build for deployment'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Runs the template\'s $kLocalBuildScript: base assets, the '
                'room\'s layout and files, its device drivers, and the '
                'Python check of every file against the room\'s processor.',
                style: small,
              ),
              const SizedBox(height: 12),
              folderRow(
                'Template folder',
                _root,
                () => _pickRoot(p),
                key: const ValueKey('deploy_build_root'),
              ),
              folderRow(
                'Distribution folder',
                _root.isEmpty ? '' : _dest(p),
                () => _pickDest(p),
                key: const ValueKey('deploy_build_dest'),
              ),
              if (_root.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Pick the ControlScript template folder: the one with '
                    '$kLocalBuildScript and a rooms folder.',
                    style: small?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              if (_rooms.isNotEmpty) ...[
                const Divider(height: 24),
                Row(
                  children: [
                    Text('Rooms (${_picked.length} of ${_rooms.length})',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 180,
                      child: TextField(
                        key: const ValueKey('deploy_build_filter'),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: 'Find a room',
                        ),
                        onChanged: (t) => setState(() => _filter = t),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('deploy_build_all'),
                      onPressed: _running
                          ? null
                          : () => setState(() => _picked.addAll(shown)),
                      child: const Text('All'),
                    ),
                    TextButton(
                      onPressed: _running
                          ? null
                          : () => setState(() => _picked.removeAll(shown)),
                      child: const Text('None'),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final r in shown)
                          FilterChip(
                            key: ValueKey('deploy_build_room_$r'),
                            label: Text(r == _openRoom ? '$r (open)' : r),
                            selected: _picked.contains(r),
                            onSelected: _running
                                ? null
                                : (v) => setState(() =>
                                    v ? _picked.add(r) : _picked.remove(r)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('deploy_build_prune'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Only the device drivers each room uses'),
                  subtitle: const Text(
                    'Off copies every driver: use it if a device fails to '
                    'load after a pruned build.',
                  ),
                  value: _prune,
                  onChanged:
                      _running ? null : (v) => setState(() => _prune = v),
                ),
                SwitchListTile(
                  key: const ValueKey('deploy_build_skip_check'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Skip the Python platform check'),
                  subtitle: Text(
                    'The only warning before a blocked import or newer '
                    'syntax stops the room on its processor.',
                    style: _skipCheck
                        ? small?.copyWith(color: theme.colorScheme.error)
                        : null,
                  ),
                  value: _skipCheck,
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _skipCheck = v),
                ),
                if (openUnsaved)
                  Text(
                    '$_openRoom has unsaved changes. The build uses what is '
                    'saved: save first to send them out.',
                    key: const ValueKey('deploy_build_unsaved'),
                    style: small?.copyWith(color: theme.colorScheme.error),
                  ),
              ],
              if (_running) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_results.isNotEmpty) ...[
                const Divider(height: 24),
                for (final MapEntry(key: r, value: s) in _results.entries)
                  _resultRow(theme, r, s),
                if (_copyError.isNotEmpty)
                  Text(_copyError,
                      style: small?.copyWith(color: theme.colorScheme.error)),
              ],
              if (_log.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  height: 220,
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    controller: _logScroll,
                    child: SelectableText(
                      _log.join('\n'),
                      key: const ValueKey('deploy_build_log'),
                      style: small?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_log.isNotEmpty && !_running)
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy output'),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: _log.join('\n'))),
          ),
        if (_copiedTo.isNotEmpty && !_running)
          TextButton.icon(
            key: const ValueKey('deploy_build_open_dest'),
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Open distribution folder'),
            onPressed: () => p.openInDesktop(_dest(p)),
          ),
        if (_running)
          TextButton(
            onPressed: () => _process?.kill(),
            child: const Text('Stop'),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        FilledButton.icon(
          key: const ValueKey('deploy_build_go'),
          icon: const Icon(Icons.build, size: 18),
          label: Text(_picked.length > 1
              ? 'Build ${_picked.length} rooms'
              : 'Build'),
          onPressed: _running || _root.isEmpty || _picked.isEmpty
              ? null
              : () => _build(p),
        ),
      ],
    );
  }

  Widget _resultRow(ThemeData theme, String room, RoomBuildStatus s) {
    final small = theme.textTheme.bodySmall;
    final ok = s == RoomBuildStatus.ready;
    final extras = _extras[room] ?? const [];
    final copied = _copiedTo[room];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok
                ? Icons.check_circle
                : s.shippable
                ? Icons.warning_amber
                : Icons.cancel,
            size: 18,
            color: ok
                ? Colors.green
                : s.shippable
                ? Colors.orange
                : theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$room: ${s.label}',
                  key: ValueKey('deploy_build_result_$room'),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (copied != null)
                  Text('Ready to send: $copied', style: small),
                if (s == RoomBuildStatus.notSafe)
                  Text(
                    'Not copied out. The check\'s findings are in the '
                    'output below and dist/$room-platform-check.log.',
                    style: small,
                  ),
                if (extras.isNotEmpty)
                  Tooltip(
                    message: extras.join('\n'),
                    child: Text(
                      'upload_to_root also holds ${extras.length} file(s) '
                      'the program does not read (${_folders(extras)}). '
                      'Check them before sending.',
                      key: ValueKey('deploy_build_extras_$room'),
                      style: small?.copyWith(color: Colors.orange.shade800),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The top-level names in [files]: "room_files, .editing".
  static String _folders(List<String> files) =>
      {for (final f in files) path.split(f).first}.join(', ');
}
