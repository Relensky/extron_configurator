// ============================================================================
// [SETTINGS KIT]: the parts of Settings every CTS app shares, so the six
// read the same way (CTS Dashboard, Room Config Builder, Instructor Contact,
// GeoGuesser, Quizzer and Quizzer FOP):
//
//  * [SettingsSection] - one collapsible card: an icon, a title and a line
//    saying what is inside. Every settings page is a column of these.
//  * [AppUpdatesSettingsSection] - always the first card: shortcuts, checking
//    for a new version and the release folder (the updater's own section).
//  * [AppLogsSettingsSection] - always the second: View logs, the time zone
//    log times are shown in, and where the logs are.
//    The rest of a page's cards follow in alphabetical order.
//  * [FirstRunSetupDialog] - shown once, on a first launch: where the app's
//    files and data come from, and light or dark.
//
// This folder is byte-identical in every app, like lib/updater/ and
// lib/log_viewer/ - except in the Room Config Builder, whose copies import
// package:material_ui in place of package:flutter/material. Change it in one
// app and copy it to the others.
// ============================================================================

import 'package:material_ui/material_ui.dart';

import '../log_viewer/log_viewer.dart';
import '../log_viewer/log_viewer_platform.dart' as log_platform;
import '../updater/folder_updater.dart';
import '../updater/update_widgets.dart';
import 'settings_kit_platform.dart' as kit;

/// One collapsible area of a settings page: a heading that opens and closes
/// it, with a line saying what is inside. Whether each is open is remembered
/// for the session.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.id,
    required this.title,
    required this.summary,
    required this.icon,
    required this.children,
    this.initiallyOpen = false,
  });

  final String id;
  final String title;
  final String summary;
  final IconData icon;
  final bool initiallyOpen;
  final List<Widget> children;

  /// Opens every section from the start - for tests that look for a field.
  @visibleForTesting
  static bool startOpen = false;

  static final Map<String, bool> _open = {};

  /// The [SettingsSectionsScope.generation] each section last obeyed.
  static final Map<String, int> _obeyed = {};

  /// Forgets which sections were opened - for tests, which share a run.
  @visibleForTesting
  static void forgetOpenForTest() {
    _open.clear();
    _obeyed.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // An Expand all / Collapse all above the page: a new generation opens
    // or shuts every section once, and each is the user's again after.
    final SettingsSectionsScope? scope = SettingsSectionsScope.maybeOf(context);
    final int generation = scope?.generation ?? 0;
    if (scope != null && _obeyed[id] != generation) {
      if (generation > 0) _open[id] = scope.open;
      _obeyed[id] = generation;
    }
    return Card(
      key: ValueKey('settings_section_$id'),
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        // NOT a PageStorageKey: the tile keeps open-or-shut in page storage
        // under its key, and every text box inside it keeps its scroll
        // offset under the same key - so a box read "true" where it wanted a
        // number and failed to build. Open-or-shut is kept in [_open]. The
        // generation rebuilds it when Expand all / Collapse all is pressed.
        key: ValueKey('settings_section_tile_${id}_$generation'),
        initiallyExpanded: startOpen || (_open[id] ?? initiallyOpen),
        // The card is the border; no lines across it when it opens.
        shape: const Border(),
        collapsedShape: const Border(),
        // Fields keep their controllers and focus while the card is shut.
        maintainState: true,
        leading: Icon(icon),
        title: Text(title, style: theme.textTheme.titleMedium),
        subtitle: Text(summary, style: theme.textTheme.bodySmall),
        childrenPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        onExpansionChanged: (v) => _open[id] = v,
        children: children,
      ),
    );
  }
}

/// Above a page's sections, for an Expand all / Collapse all button: each
/// time [generation] goes up, every [SettingsSection] below opens ([open])
/// or shuts.
class SettingsSectionsScope extends InheritedWidget {
  const SettingsSectionsScope({
    super.key,
    required this.open,
    required this.generation,
    required super.child,
  });

  final bool open;
  final int generation;

  static SettingsSectionsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsSectionsScope>();

  @override
  bool updateShouldNotify(SettingsSectionsScope old) =>
      old.open != open || old.generation != generation;
}

/// The first card of every settings page: Desktop and Start menu shortcuts,
/// checking for a new version, and the release folder they come from.
class AppUpdatesSettingsSection extends StatelessWidget {
  const AppUpdatesSettingsSection({
    super.key,
    required this.updater,
    this.pickFolder,
    this.children = const [],
  });

  final FolderUpdater updater;

  /// The app's folder picker for Browse; without one the path is typed.
  final Future<String?> Function()? pickFolder;

  /// Anything the app adds under the updater's own controls.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SettingsSection(
        id: 'app_updates',
        title: 'Application updates',
        summary: 'Shortcuts, checking for a new version, and the release '
            'folder',
        icon: Icons.system_update_alt,
        children: [
          UpdateSettingsSection(updater: updater, pickFolder: pickFolder),
          ...children,
        ],
      );
}

/// The second card of every settings page: the log viewer, the time zone log
/// times are shown in, and where the logs are written.
class AppLogsSettingsSection extends StatefulWidget {
  const AppLogsSettingsSection({
    super.key,
    required this.config,
    this.logLocation,
    this.children = const [],
  });

  /// What the viewer shows. Its time zone, when the app keeps one, is the
  /// one offered here; otherwise the kit keeps the choice itself.
  final LogViewerConfig config;

  /// The log folder (or file) shown, with Open log folder beside it.
  final String? logLocation;

  /// What the app adds: how long logs are kept, where they go, and so on.
  final List<Widget> children;

  @override
  State<AppLogsSettingsSection> createState() => _AppLogsSettingsSectionState();
}

/// The name the kit keeps the log time zone under, for apps that do not.
const String _kZoneValue = 'log_time_zone';

class _AppLogsSettingsSectionState extends State<AppLogsSettingsSection> {
  late LogTimeZone _zone = LogTimeZone.fromId(
      widget.config.timeZoneId ?? kit.readKitValue(_kZoneValue));

  void _setZone(LogTimeZone zone) {
    setState(() => _zone = zone);
    LogViewerDialog.lastTimeZone = zone;
    final void Function(String)? own = widget.config.onTimeZoneChanged;
    if (own != null) {
      own(zone.id);
    } else {
      kit.writeKitValue(_kZoneValue, zone.id);
    }
  }

  /// [config] opening in the zone picked here, and saving a change made in
  /// the viewer the same way this card does.
  LogViewerConfig get _config {
    final LogViewerConfig c = widget.config;
    return LogViewerConfig(
      appName: c.appName,
      version: c.version,
      sources: c.sources,
      currentLogPath: c.currentLogPath,
      chooseSavePath: c.chooseSavePath,
      timeZoneId: _zone.id,
      onTimeZoneChanged: (id) {
        if (!mounted) return;
        _setZone(LogTimeZone.fromId(id));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? where = widget.logLocation;
    final List<LogTimeZone> zones = LogTimeZone.choices;
    return SettingsSection(
      id: 'app_logs',
      title: 'Application logs',
      summary: 'View logs, the time zone they are shown in, and where they '
          'are kept',
      icon: Icons.receipt_long_outlined,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            LogViewerButton(key: const ValueKey('kit_view_logs'), config: _config),
            if (where != null && where.isNotEmpty)
              OutlinedButton.icon(
                key: const ValueKey('kit_open_log_folder'),
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Open log folder'),
                onPressed: () => log_platform.revealInFileManager(where),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 360,
            child: DropdownButtonFormField<LogTimeZone>(
              key: const ValueKey('kit_log_time_zone'),
              initialValue: zones.contains(_zone) ? _zone : LogTimeZone.local,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Show log times in',
                helperText: 'Display only: copies and exports keep the times '
                    'as written.',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final LogTimeZone z in zones)
                  DropdownMenuItem(
                    value: z,
                    child: Text(z.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (z) {
                if (z != null) _setZone(z);
              },
            ),
          ),
        ),
        if (where != null && where.isNotEmpty) ...[
          const SizedBox(height: 12),
          SelectableText('Written to: $where', style: theme.textTheme.bodySmall),
        ],
        if (widget.children.isNotEmpty) const SizedBox(height: 8),
        ...widget.children,
      ],
    );
  }
}

// ============================================================================
// [FIRST-RUN SETUP]
// ============================================================================

/// One file or folder the first-run dialog asks about.
class FirstRunPath {
  const FirstRunPath({
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
    this.isFolder = false,
    this.optional = false,
    this.readOnly = false,
    this.browse,
  });

  final String label;

  /// Where it is now - asked each time the dialog builds, so a data source
  /// button that changes everything shows at once.
  final String Function() value;

  /// Saves a new location.
  final void Function(String path) onChanged;

  final String? helper;
  final bool isFolder;

  /// Missing is fine (an optional extra): shown amber, not red.
  final bool optional;

  /// Shown, not changed here (set some other way, such as a variable).
  final bool readOnly;

  /// The app's picker. Without one the row is edited by typing.
  final Future<String?> Function()? browse;
}

/// Where the app's shared data lives - a folder on the file share - and a
/// button that points everything at it.
class FirstRunDataSource {
  const FirstRunDataSource({
    required this.location,
    required this.inUse,
    required this.use,
    this.title = 'Data source',
    this.buttonLabel = 'Use this location',
  });

  final String title;
  final String location;

  /// Whether the app already reads from [location].
  final bool Function() inUse;

  /// Points the app's settings at [location].
  final Future<void> Function() use;

  final String buttonLabel;
}

/// Light or dark, whichever the Windows desktop is set to now - what a first
/// start's theme question opens on.
ThemeMode desktopThemeMode() =>
    WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark
        ? ThemeMode.dark
        : ThemeMode.light;

/// Light, dark (and, where the app follows it, the system's choice).
class ThemeModeChoice extends StatelessWidget {
  const ThemeModeChoice({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowSystem = false,
  });

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;
  final bool allowSystem;

  @override
  Widget build(BuildContext context) => SegmentedButton<ThemeMode>(
        key: const ValueKey('kit_theme_mode'),
        showSelectedIcon: false,
        segments: [
          if (allowSystem)
            const ButtonSegment(
              value: ThemeMode.system,
              label: Text('System'),
              icon: Icon(Icons.brightness_auto),
            ),
          const ButtonSegment(
            value: ThemeMode.light,
            label: Text('Light'),
            icon: Icon(Icons.light_mode),
          ),
          const ButtonSegment(
            value: ThemeMode.dark,
            label: Text('Dark'),
            icon: Icon(Icons.dark_mode),
          ),
        ],
        selected: {
          !allowSystem && value == ThemeMode.system ? ThemeMode.light : value
        },
        onSelectionChanged: (s) => onChanged(s.first),
      );
}

/// Shown once, on an app's first launch: where its files and data come from
/// (green found, red missing), and light or dark. Finishing or skipping both
/// call [onFinish], which records that setup is done.
class FirstRunSetupDialog extends StatefulWidget {
  const FirstRunSetupDialog({
    super.key,
    required this.appName,
    required this.paths,
    required this.onFinish,
    this.intro,
    this.dataSource,
    this.themeMode,
    this.onThemeMode,
    this.allowSystemTheme = false,
    this.children = const [],
    this.refresh,
  });

  final String appName;
  final String? intro;
  final FirstRunDataSource? dataSource;
  final List<FirstRunPath> paths;

  /// Null for an app with one look, where the question is not asked.
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeMode;
  final bool allowSystemTheme;

  /// Anything else the app asks on a first start.
  final List<Widget> children;

  /// Rebuilds the rows when it changes - for a location saved in the
  /// background.
  final Listenable? refresh;

  final Future<void> Function() onFinish;

  /// Stands in for asking the disk whether a path is there.
  @visibleForTesting
  static bool? pathsExistForTest;

  @override
  State<FirstRunSetupDialog> createState() => _FirstRunSetupDialogState();
}

class _FirstRunSetupDialogState extends State<FirstRunSetupDialog> {
  /// A first start matches the desktop: the question opens on Windows' own
  /// light or dark, and that is applied straight away.
  late ThemeMode? _theme = widget.themeMode == null ? null : desktopThemeMode();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final ThemeMode? start = _theme;
    if (start != null && start != widget.themeMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onThemeMode?.call(start);
      });
    }
  }

  /// Found or not, by path; missing while it is being asked.
  final Map<String, bool> _found = {};

  void _ask(String path, bool folder) {
    if (_found.containsKey(path)) return;
    final bool? forTest = FirstRunSetupDialog.pathsExistForTest;
    if (forTest != null) {
      _found[path] = forTest;
      return;
    }
    kit.kitPathExists(path, folder: folder).then((there) {
      if (mounted) setState(() => _found[path] = there);
    });
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    await widget.onFinish();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _edit(FirstRunPath p) async {
    final TextEditingController c = TextEditingController(text: p.value());
    final String? typed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(p.label),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: c,
            autofocus: true,
            decoration: InputDecoration(
              labelText: p.isFolder ? 'Folder' : 'File',
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    if (typed != null && mounted) setState(() => p.onChanged(typed.trim()));
  }

  Future<void> _browse(FirstRunPath p) async {
    final String? picked = await p.browse!();
    if (picked != null && mounted) setState(() => p.onChanged(picked));
  }

  Widget _row(FirstRunPath p) {
    final ThemeData theme = Theme.of(context);
    final String value = p.value();
    _ask(value, p.isFolder);
    final bool? found = _found[value];
    final Color missing =
        p.optional ? Colors.amber.shade700 : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: found == null
                ? const Padding(
                    padding: EdgeInsets.all(3),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    found ? Icons.check_circle : Icons.error_outline,
                    color: found ? Colors.green : missing,
                    size: 20,
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                Text(
                  value.isEmpty ? '(not set)' : value,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                if (p.helper != null)
                  Text(p.helper!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (p.browse != null && !p.readOnly)
            TextButton.icon(
              icon: Icon(p.isFolder ? Icons.folder_open : Icons.file_open,
                  size: 18),
              label: const Text('Browse'),
              onPressed: () => _browse(p),
            ),
          if (!p.readOnly)
            IconButton(
              tooltip: 'Type the location',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _edit(p),
            ),
        ],
      ),
    );
  }

  Widget _dataSourceBox(FirstRunDataSource source) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? small = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSecondaryContainer);
    final bool inUse = source.inUse();
    _ask(source.location, true);
    final bool? reachable = _found[source.location];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(source.title,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onSecondaryContainer)),
                SelectableText(source.location, style: small),
                Text(
                  key: const ValueKey('kit_first_run_source_status'),
                  inUse
                      ? 'The app is reading its data from here.'
                      : reachable == null
                          ? 'Checking whether this computer can reach it...'
                          : reachable
                              ? 'Reachable.'
                              : 'Not reachable from this computer. Set it '
                                  'once you are on the network.',
                  style: small,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          inUse
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, color: Colors.green.shade600),
                    const SizedBox(width: 6),
                    const Text('In use'),
                  ],
                )
              : FilledButton.icon(
                  key: const ValueKey('kit_first_run_use_source'),
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await source.use();
                          if (!mounted) return;
                          setState(() {
                            _busy = false;
                            _found.clear();
                          });
                        },
                  icon: const Icon(Icons.folder_shared, size: 18),
                  label: Text(source.buttonLabel),
                ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Listenable? refresh = widget.refresh;
    if (refresh == null) return _build(context);
    return ListenableBuilder(
        listenable: refresh, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle heading =
        const TextStyle(fontWeight: FontWeight.bold, fontSize: 13);
    return AlertDialog(
      key: const ValueKey('kit_first_run_setup'),
      title: Row(
        children: [
          const Icon(Icons.tune),
          const SizedBox(width: 10),
          Expanded(child: Text('First-Time Setup - ${widget.appName}')),
        ],
      ),
      content: SizedBox(
        width: 696,
        child: SingleChildScrollView(
          // A lane of its own for the scroll bar, clear of the buttons.
          padding: const EdgeInsets.only(right: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.intro ??
                  'Check where the app reads its files and data from. Green '
                      '= found, red = not found (you can still finish and '
                      'set it later in Settings). Choices are saved at once, '
                      'and this will not appear again once you finish.'),
              if (widget.dataSource != null) ...[
                const SizedBox(height: 14),
                _dataSourceBox(widget.dataSource!),
              ],
              if (_theme != null) ...[
                const SizedBox(height: 18),
                Text('Theme', style: heading),
                const SizedBox(height: 4),
                Text('Light or dark. You can change it later in Settings.',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                ThemeModeChoice(
                  value: _theme!,
                  allowSystem: widget.allowSystemTheme,
                  onChanged: (m) {
                    setState(() => _theme = m);
                    widget.onThemeMode?.call(m);
                  },
                ),
              ],
              ...widget.children,
              if (widget.paths.isNotEmpty) ...[
                const Divider(height: 28),
                Text('Files and folders', style: heading),
                const SizedBox(height: 10),
                for (final FirstRunPath p in widget.paths) _row(p),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('kit_first_run_skip'),
          onPressed: _busy ? null : _finish,
          child: const Text('Skip - use the defaults shown'),
        ),
        FilledButton.icon(
          key: const ValueKey('kit_first_run_finish'),
          icon: const Icon(Icons.check),
          label: const Text('Finish Setup'),
          onPressed: _busy ? null : _finish,
        ),
      ],
    );
  }
}
