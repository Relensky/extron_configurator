// ============================================================================
// LOG VIEWER
//
// Every CTS app keeps an always-on log, and the first thing anybody asked to
// "send the log" needs is to see it, find the part that matters, and get it
// off the machine. This is that, in one dialog, opened from each app's
// settings:
//
//   * the recent log files, newest first, the one this session is writing
//     marked;
//   * the chosen file, with a search (space- and case-agnostic, like every
//     search box in these apps) and Problems only, which keeps the lines that
//     mention an error, crash, warning or failure;
//   * Copy — this file, what is shown, or all recent logs — ready to paste
//     into a ticket, an email or a Teams message;
//   * Export — this file or all recent logs, as one .txt to attach.
//
// Anything copied or exported starts with a header naming the app, its
// version, the computer and the user, so whoever receives it knows where it
// came from without asking.
//
// Shared unchanged by the five apps — see log_viewer_types.dart.
// ============================================================================
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'log_viewer_platform.dart' as platform;
import 'log_viewer_types.dart';

export 'log_viewer_types.dart';

/// Asks where to save an export, suggesting [suggestedName]. Returns the path,
/// or null when the person cancelled. Apps with file_picker pass one; without
/// it the export goes to the Downloads folder.
typedef ChooseSavePath = Future<String?> Function(String suggestedName);

/// What one app's log viewer shows.
class LogViewerConfig {
  /// The app's name as people know it, for the title and the export header.
  final String appName;

  /// The running version, for the export header.
  final String version;

  /// Where the logs are.
  final List<LogSource> sources;

  /// The file this session is writing, asked each time the list is read.
  final String? Function()? currentLogPath;

  /// See [ChooseSavePath].
  final ChooseSavePath? chooseSavePath;

  const LogViewerConfig({
    required this.appName,
    required this.version,
    required this.sources,
    this.currentLogPath,
    this.chooseSavePath,
  });
}

/// How much of a file is shown: its last 1 MB. More than that is slow to lay
/// out and nobody scrolls it; Copy and Export still take the whole file.
const int kLogViewBytes = 1024 * 1024;

/// How much of one file Copy this file and Export this file take.
const int kLogCopyBytes = 8 * 1024 * 1024;

/// All recent logs takes the newest this many files...
const int kLogBundleFiles = 10;

/// ...and at most this much of the end of each.
const int kLogBundleBytesPerFile = 2 * 1024 * 1024;

final RegExp _problem = RegExp(
  r'error|crash|exception|fatal|warn|fail|did not exit cleanly|stack ?trace',
  caseSensitive: false,
);

/// Whether [line] reports a problem — what Problems only keeps.
bool logLineIsProblem(String line) => _problem.hasMatch(line);

String _squash(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// The indexes of the [lines] that match [query] (ignoring spacing and case)
/// and, with [problemsOnly], report a problem.
List<int> filterLogLines(
  List<String> lines,
  String query, {
  bool problemsOnly = false,
}) {
  final String q = _squash(query);
  return [
    for (var i = 0; i < lines.length; i++)
      if ((!problemsOnly || logLineIsProblem(lines[i])) &&
          (q.isEmpty || _squash(lines[i]).contains(q)))
        i,
  ];
}

/// A file name for an export: `<app>_logs_<date>_<time>.txt`, or with the
/// exported file's own name in place of `logs`.
String suggestedLogExportName(
  String appName, {
  String? fileName,
  DateTime? now,
}) {
  String slug(String s) => s
      .replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final DateTime t = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final String stamp = '${t.year}-${two(t.month)}-${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}';
  final String what = fileName == null ? 'logs' : slug(fileName);
  return '${slug(appName)}_${what}_$stamp.txt';
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _when(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// The block at the top of anything copied or exported.
String logExportHeader(
  LogViewerConfig config,
  List<LogFileInfo> files, {
  String? note,
  DateTime? now,
}) {
  final StringBuffer b = StringBuffer()
    ..writeln('=' * 72)
    ..writeln('${config.appName} ${config.version} logs')
    ..writeln(platform.machineSummary())
    ..writeln('Exported: ${_when(now ?? DateTime.now())}');
  if (note != null) b.writeln(note);
  if (files.isNotEmpty) {
    b.writeln('Files:');
    for (final f in files) {
      b.writeln('  ${f.path}  (${_size(f.bytes)}, last written '
          '${_when(f.modified)}${f.isCurrent ? ', this session' : ''})');
    }
  }
  b.writeln('=' * 72);
  return b.toString();
}

/// One file's part of a copy or export: a heading, then its text.
String logFileSection(LogFileInfo file, LogText text) {
  final StringBuffer b = StringBuffer()
    ..writeln()
    ..writeln('----- ${file.name} (${file.label}) -----');
  if (text.error != null) {
    b.writeln('(could not be read: ${text.error})');
  } else {
    if (text.truncated) {
      b.writeln('(the last ${_size(text.text.length)} of '
          '${_size(text.totalBytes)})');
    }
    b.write(text.text);
    if (!text.text.endsWith('\n')) b.writeln();
  }
  return b.toString();
}

/// Everything in the newest [kLogBundleFiles] files, for All recent logs.
String buildLogBundle(LogViewerConfig config, List<LogFileInfo> files) {
  final List<LogFileInfo> chosen = files.take(kLogBundleFiles).toList();
  final StringBuffer b = StringBuffer(logExportHeader(config, chosen,
      note: files.length > chosen.length
          ? 'The newest ${chosen.length} of ${files.length} log files.'
          : null));
  for (final f in chosen) {
    b.write(logFileSection(
        f, platform.readLogText(f.path, maxBytes: kLogBundleBytesPerFile)));
  }
  return b.toString();
}

/// Opens the log viewer.
Future<void> showLogViewer(BuildContext context, LogViewerConfig config) =>
    showDialog<void>(
      context: context,
      builder: (_) => LogViewerDialog(config: config),
    );

/// The button each app's settings put beside its log's path.
class LogViewerButton extends StatelessWidget {
  final LogViewerConfig config;
  final String label;

  const LogViewerButton({
    super.key,
    required this.config,
    this.label = 'View logs',
  });

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        icon: const Icon(Icons.receipt_long_outlined, size: 18),
        label: Text(label),
        onPressed: platform.logViewerSupported
            ? () => showLogViewer(context, config)
            : null,
      );
}

enum _Take { thisFile, shown, allRecent }

class LogViewerDialog extends StatefulWidget {
  final LogViewerConfig config;

  const LogViewerDialog({super.key, required this.config});

  /// Whether the viewer fills the window. Kept for the life of the process,
  /// like the help dialog's.
  static bool expanded = false;

  @override
  State<LogViewerDialog> createState() => _LogViewerDialogState();
}

class _LogViewerDialogState extends State<LogViewerDialog> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  List<LogFileInfo> _files = const [];
  int _selected = 0;
  LogText? _text;
  List<String> _lines = const [];
  List<int> _shown = const [];
  bool _problemsOnly = false;

  /// What the last Copy or Export did, shown in the bottom bar.
  String? _status;
  bool _statusIsError = false;

  /// A file just exported, for the Show button beside [_status].
  String? _exportedPath;

  LogViewerConfig get _config => widget.config;

  @override
  void initState() {
    super.initState();
    _reload(keepSelection: false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload({bool keepSelection = true}) {
    final String? previous = keepSelection && _selected < _files.length
        ? _files[_selected].path
        : null;
    final List<LogFileInfo> files = platform.listLogFiles(
      _config.sources,
      currentPath: _config.currentLogPath?.call(),
    );
    var index = previous == null
        ? 0
        : files.indexWhere((f) => f.path == previous);
    if (index < 0) index = 0;
    setState(() {
      _files = files;
      _selected = index;
    });
    _load();
  }

  void _select(int index) {
    if (index == _selected) return;
    setState(() => _selected = index);
    _load();
  }

  void _load() {
    if (_files.isEmpty) {
      setState(() {
        _text = null;
        _lines = const [];
        _shown = const [];
      });
      return;
    }
    final LogText text =
        platform.readLogText(_files[_selected].path, maxBytes: kLogViewBytes);
    final List<String> lines = text.text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    setState(() {
      _text = text;
      _lines = lines;
      _shown = filterLogLines(lines, _search.text,
          problemsOnly: _problemsOnly);
    });
    // Open at the end: the newest lines are the ones anybody came for.
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  void _jumpToEnd() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _refilter() {
    setState(() {
      _shown = filterLogLines(_lines, _search.text,
          problemsOnly: _problemsOnly);
    });
  }

  void _onQuery(String _) {
    // A few hundred thousand lines is a lot to squash on every keystroke.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), _refilter);
    setState(() {}); // the clear button
  }

  // --- Copy and Export --------------------------------------------------

  String _textFor(_Take take) {
    final LogFileInfo file = _files[_selected];
    switch (take) {
      case _Take.thisFile:
        return logExportHeader(_config, [file]) +
            logFileSection(
                file, platform.readLogText(file.path, maxBytes: kLogCopyBytes));
      case _Take.shown:
        final String filter = [
          if (_search.text.trim().isNotEmpty) 'matching "${_search.text.trim()}"',
          if (_problemsOnly) 'problems only',
        ].join(', ');
        final String header = logExportHeader(_config, [file],
            note: 'Lines shown: ${_shown.length} of ${_lines.length}'
                '${filter.isEmpty ? '' : ' ($filter)'}');
        return '$header\n${[for (final i in _shown) _lines[i]].join('\n')}\n';
      case _Take.allRecent:
        return buildLogBundle(_config, _files);
    }
  }

  void _say(String message, {bool error = false, String? exported}) {
    setState(() {
      _status = message;
      _statusIsError = error;
      _exportedPath = exported;
    });
  }

  Future<void> _copy(_Take take) async {
    if (_files.isEmpty) return;
    final String text = _textFor(take);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _say('Copied ${_size(text.length)}. Paste it into a ticket, an email '
          'or a message.');
    } catch (e) {
      _say('Could not copy: $e', error: true);
    }
  }

  Future<void> _export(_Take take) async {
    if (_files.isEmpty) return;
    final String name = suggestedLogExportName(_config.appName,
        fileName: take == _Take.thisFile ? _files[_selected].name : null);
    String? path;
    final ChooseSavePath? choose = _config.chooseSavePath;
    if (choose != null) {
      try {
        path = await choose(name);
      } catch (e) {
        _say('Could not open the Save dialog: $e', error: true);
        return;
      }
      if (path == null) return; // cancelled
      if (!path.toLowerCase().endsWith('.txt')) path = '$path.txt';
    } else {
      path = platform.exportPathIn(platform.defaultExportFolder(), name);
    }
    final String? error = platform.writeLogExport(path, _textFor(take));
    if (!mounted) return;
    if (error != null) {
      _say('Could not save $path: $error', error: true);
    } else {
      _say('Saved to $path', exported: path);
    }
  }

  // --- Layout -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    final bool narrow = screen.width < 820;
    final bool expanded = LogViewerDialog.expanded;
    const double inset = 8;

    return Dialog(
      insetPadding: EdgeInsets.all(expanded ? inset : 24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: expanded
            ? BoxConstraints.tightFor(
                width: screen.width - inset * 2,
                height: screen.height - inset * 2)
            : BoxConstraints(
                maxWidth: 1200,
                maxHeight: screen.height * 0.9,
                minHeight: screen.height * 0.9 < 480 ? 0 : 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(theme),
            const Divider(height: 1),
            Flexible(
              child: _files.isEmpty
                  ? _empty(theme)
                  : narrow
                      ? Column(children: [
                          _fileDropdown(theme),
                          const Divider(height: 1),
                          Expanded(child: _viewer(theme)),
                        ])
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 280, child: _fileList(theme)),
                            const VerticalDivider(width: 1),
                            Expanded(child: _viewer(theme)),
                          ],
                        ),
            ),
            const Divider(height: 1),
            _actions(theme),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final bool expanded = LogViewerDialog.expanded;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.receipt_long_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${_config.appName} logs',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh: read the files again',
            onPressed: _reload,
          ),
          IconButton(
            icon: Icon(expanded ? Icons.close_fullscreen : Icons.open_in_full),
            tooltip:
                expanded ? 'Restore to normal size' : 'Expand to fill the window',
            onPressed: () =>
                setState(() => LogViewerDialog.expanded = !expanded),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    final List<String> places = [
      for (final s in _config.sources)
        if ((s.folder ?? s.file ?? '').trim().isNotEmpty) (s.folder ?? s.file)!,
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text('No log files found.', style: theme.textTheme.titleMedium),
            if (places.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText('Looked in:\n${places.join('\n')}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fileTitle(LogFileInfo f, ThemeData theme) => Text(
        f.name,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      );

  String _fileSubtitle(LogFileInfo f) =>
      '${f.isCurrent ? 'This session · ' : ''}${f.label} · '
      '${_when(f.modified)} · ${_size(f.bytes)}';

  Widget _fileList(ThemeData theme) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _files.length,
        itemBuilder: (context, i) {
          final LogFileInfo f = _files[i];
          return ListTile(
            dense: true,
            selected: i == _selected,
            selectedTileColor:
                theme.colorScheme.primary.withValues(alpha: 0.12),
            leading: Icon(
                f.isCurrent
                    ? Icons.fiber_manual_record
                    : Icons.description_outlined,
                size: 18,
                color: f.isCurrent ? Colors.green : theme.hintColor),
            title: _fileTitle(f, theme),
            subtitle: Text(_fileSubtitle(f),
                style: TextStyle(fontSize: 11, color: theme.hintColor)),
            onTap: () => _select(i),
          );
        },
      );

  Widget _fileDropdown(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: DropdownButtonFormField<int>(
          key: ValueKey(_files.length),
          initialValue: _selected,
          isExpanded: true,
          decoration: const InputDecoration(
              isDense: true, border: OutlineInputBorder(), labelText: 'File'),
          items: [
            for (var i = 0; i < _files.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                    '${_files[i].isCurrent ? '● ' : ''}${_files[i].name} · '
                    '${_when(_files[i].modified)}',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => _select(v ?? _selected),
        ),
      );

  Widget _viewer(ThemeData theme) {
    final LogText? text = _text;
    final bool dark = theme.brightness == Brightness.dark;
    final TextStyle mono = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Courier New', 'monospace'],
      fontSize: 12.5,
      height: 1.35,
      color: dark ? Colors.white.withValues(alpha: 0.87) : Colors.black87,
    );
    final TextStyle problem = mono.copyWith(
        color: dark ? const Color(0xFFFF8A80) : const Color(0xFFB00020));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _search,
                  onChanged: _onQuery,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    hintText: 'Search this log',
                    border: const OutlineInputBorder(),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _search.clear();
                              _refilter();
                            },
                          ),
                  ),
                ),
              ),
              FilterChip(
                label: const Text('Problems only'),
                tooltip: 'Only lines that mention an error, crash, warning or '
                    'failure',
                selected: _problemsOnly,
                onSelected: (v) {
                  _problemsOnly = v;
                  _refilter();
                },
              ),
              Text(
                  '${_shown.length == _lines.length ? '' : '${_shown.length} of '}'
                  '${_lines.length} lines',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor)),
              IconButton(
                icon: const Icon(Icons.vertical_align_top),
                tooltip: 'Go to the start',
                onPressed: () {
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                },
              ),
              IconButton(
                icon: const Icon(Icons.vertical_align_bottom),
                tooltip: 'Go to the end, the newest lines',
                onPressed: _jumpToEnd,
              ),
            ],
          ),
        ),
        if (text?.error != null)
          _notice(theme, 'This file could not be read: ${text!.error}',
              error: true)
        else if (text?.truncated ?? false)
          _notice(
              theme,
              'Showing the last ${_size(kLogViewBytes)} of '
              '${_size(text!.totalBytes)}. Copy and Export take the whole '
              'file.'),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            decoration: BoxDecoration(
              color: dark
                  ? Colors.black.withValues(alpha: 0.35)
                  : Colors.black.withValues(alpha: 0.035),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: theme.dividerColor),
            ),
            child: _shown.isEmpty
                ? Center(
                    child: Text(
                        _lines.isEmpty
                            ? 'This log is empty.'
                            : 'No lines match.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.hintColor)),
                  )
                : Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(10),
                        itemCount: _shown.length,
                        itemBuilder: (context, i) {
                          final String line = _lines[_shown[i]];
                          return Text(line,
                              style: logLineIsProblem(line) ? problem : mono);
                        },
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _notice(ThemeData theme, String text, {bool error = false}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Text(text,
            style: theme.textTheme.bodySmall?.copyWith(
                color: error ? theme.colorScheme.error : theme.hintColor)),
      );

  Widget _menu({
    required IconData icon,
    required String label,
    required String tooltip,
    required List<(String, _Take)> items,
    required void Function(_Take) onSelected,
  }) {
    final bool enabled = _files.isNotEmpty;
    return PopupMenuButton<_Take>(
      tooltip: tooltip,
      enabled: enabled,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final (text, take) in items)
          PopupMenuItem(value: take, child: Text(text)),
      ],
      child: IgnorePointer(
        child: OutlinedButton.icon(
          icon: Icon(icon, size: 18),
          label: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label),
            const Icon(Icons.arrow_drop_down, size: 18),
          ]),
          onPressed: enabled ? () {} : null,
        ),
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final String? status = _status;
    final String? exported = _exportedPath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _menu(
            icon: Icons.copy,
            label: 'Copy',
            tooltip: 'Copy to the clipboard, to paste and send',
            items: const [
              ('Copy this file', _Take.thisFile),
              ('Copy what is shown', _Take.shown),
              ('Copy all recent logs', _Take.allRecent),
            ],
            onSelected: _copy,
          ),
          _menu(
            icon: Icons.save_alt,
            label: 'Export',
            tooltip: 'Save as a .txt file to attach',
            items: const [
              ('Export this file…', _Take.thisFile),
              ('Export what is shown…', _Take.shown),
              ('Export all recent logs…', _Take.allRecent),
            ],
            onSelected: _export,
          ),
          TextButton.icon(
            icon: const Icon(Icons.folder_open_outlined, size: 18),
            label: const Text('Show in folder'),
            onPressed: _files.isEmpty
                ? null
                : () => platform.revealInFileManager(_files[_selected].path),
          ),
          if (status != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                      _statusIsError
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 18,
                      color: _statusIsError
                          ? theme.colorScheme.error
                          : Colors.green),
                  const SizedBox(width: 6),
                  Flexible(
                    child: SelectableText(status,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: _statusIsError
                                ? theme.colorScheme.error
                                : null)),
                  ),
                  if (exported != null)
                    TextButton(
                      onPressed: () => platform.revealInFileManager(exported),
                      child: const Text('Show'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
