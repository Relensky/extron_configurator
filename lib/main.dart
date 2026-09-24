import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auris/auris.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'app_snack.dart';
import 'app_updates.dart';
import 'log_viewer/log_viewer.dart';
import 'log_viewer/log_viewer_platform.dart' show describeOperatingSystem;
import 'updater/update_widgets.dart';
import 'campus_file.dart';
import 'recent_files.dart' show RecentKind;
import 'recent_files_menu.dart';
import 'campus_lifecycle_view.dart'
    show showCampusLifecycle, showCampusLifecycleFile;
import 'responsive.dart';
import 'app_state.dart';
import 'changelog.dart';
import 'av_device_library.dart';
import 'av_only_notice.dart';
import 'av_flow_view.dart';
import 'contrast.dart';
import 'pinned_grid.dart' show gridMetric;
import 'error_reporting.dart';
import 'conversion_preview_view.dart';
import 'cost_estimate_view.dart';
import 'cost_estimate_actions.dart';
import 'collab/collab_widgets.dart';
import 'delivery_locations_dialog.dart';
import 'vendor_book_dialog.dart';
import 'device_editor_view.dart';
import 'device_info_editor.dart';
import 'flow_rules_view.dart';
import 'schema_editor_view.dart';
import 'device_start_wizard.dart';
import 'cabling_view.dart';
import 'color_wheel_picker.dart';
import 'floor_plan_view.dart';
import 'model_defaults_dialog.dart';
import 'online_copy_dialog.dart';
import 'undo_bar.dart'
    show ToolbarUndoButtons, ToolbarUndoTarget, toolbarUndoTarget;
import 'nav_rail.dart';
import 'project_room_picker.dart';
import 'project_history_view.dart' show showHistoryDialog;
import 'estimate_settings_section.dart';
import 'help_view.dart';
import 'project_view.dart';
import 'new_room_dialog.dart';
import 'rack_tab_view.dart';
import 'recovery_dialog.dart';
import 'save_actions.dart';
import 'dynamic_devices_view.dart';
import 'schematic_view.dart';
import 'setup_wizard_view.dart';
import 'json_editor_view.dart';
import 'legible_theme.dart';
import 'lifecycle_view.dart';
import 'screenshot_tools.dart';
import 'search_match.dart';
import 'side_pane.dart';
import 'system_settings_view.dart';
import 'tab_export.dart';
import 'workbook_export.dart';

void main() {
  // FIRST, before anything that could throw. See error_reporting.dart: without
  // these, an unhandled error in a release build goes to a console that a
  // double-clicked .exe does not have, and the log this app asks people to send
  // in never hears about it.
  installGlobalErrorHandlers();
  // Marks where each session starts in the log. Crashes the Dart handlers
  // cannot see are logged by windows/runner/crash_log.cpp.
  // The OS as people know it: Platform.operatingSystemVersion says "Windows
  // 10" on every Windows 11 machine. See lib/log_viewer/os_name.dart.
  unawaited(AppLogger.logInfo(
      'Room Config Builder $kAppVersion started on ${describeOperatingSystem()}.'));
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppStateProvider(),
      child: const RoomConfigApp(),
    ),
  );
  // Looks for a newer release just after launch, and again every half hour
  // once the user is not in the middle of an edit. See app_updates.dart.
  unawaited(appUpdater.start());
  UserActivityWatcher(appUpdater).start();
}

class RoomConfigApp extends StatelessWidget {
  const RoomConfigApp({super.key});

  /// The app's one navigator, so a shortcut registered ABOVE it can still open
  /// a dialog inside it — see [_helpShortcuts].
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// The swatches offered by the Auris accent picker. Amber first (the
  /// package's canonical accent), then HUD-intensity alternates.
  static const List<Color> aurisSwatches = [
    Color(0xFFF0A500), // amber (Auris default)
    Color(0xFF35E0C0), // teal
    Color(0xFFE0409A), // magenta
    Color(0xFFE84838), // red
    Color(0xFF6AB880), // green
    Color(0xFF4FC3F7), // blue
    Color(0xFFB388FF), // violet
    Color(0xFF8AABB0), // slate
  ];

  /// The swatches offered by the Classic color picker (App Config and the
  /// first-run setup dialog). Material primaries, stored as RRGGBB hex.
  static const List<Color> classicSwatches = [
    Color(0xFFF44336), // red
    Color(0xFFE91E63), // pink
    Color(0xFF9C27B0), // purple
    Color(0xFF673AB7), // deep purple
    Color(0xFF3F51B5), // indigo
    Color(0xFF2196F3), // blue
    Color(0xFF03A9F4), // light blue
    Color(0xFF00BCD4), // cyan
    Color(0xFF009688), // teal
    Color(0xFF4CAF50), // green
    Color(0xFF8BC34A), // light green
    Color(0xFFFFC107), // amber
    Color(0xFFFF9800), // orange
    Color(0xFFFF5722), // deep orange
    Color(0xFF795548), // brown
    Color(0xFF607D8B), // blue gray
  ];

  /// Parses a stored RRGGBB hex into a Color (falls back to [fallback]).
  static Color parseHexColor(String hex,
      {Color fallback = const Color(0xFF2196F3)}) {
    final v = int.tryParse(hex, radix: 16);
    return v == null ? fallback : Color(0xFF000000 | v);
  }

  /// Resolves the active ThemeData from the Theme Style chosen in App Config
  /// ('classic' | 'auris') plus the dark/light toggle. 'classic' (the
  /// default) is a Material theme generated by flex_color_scheme around the
  /// user's chosen accent color; 'auris' is the sci-fi HUD look built around
  /// its own accent swatch. Classic also takes an optional secondary
  /// element color ('' = Auto, let the theme derive it).
  ///
  /// Whatever comes back is put through [legibleTheme] before it is used.
  /// Both families are generated around a color somebody picked out of a
  /// wheel and neither measures the result — see legible_theme.dart for what
  /// that costs and which pairings it repairs.
  static ThemeData themeFor(String style, bool isDark, String classicColor,
          String aurisColor, String classicSecondary) =>
      legibleTheme(
        rawThemeFor(style, isDark, classicColor, aurisColor,
            classicSecondary),
      );

  /// The theme as its generator hands it over, BEFORE it is measured.
  ///
  /// Public for one reason: the contrast test measures this as well as the
  /// finished theme, so the repair pass has to keep proving it is repairing
  /// something. Nothing in the app should paint from it.
  static ThemeData rawThemeFor(String style, bool isDark,
      String classicColor, String aurisColor, String classicSecondary) {
    switch (style) {
      case 'auris':
        // The canonical amber look comes from the package default (null
        // accent) — passing the amber swatch explicitly would re-derive its
        // rungs instead of using the hand-tuned originals.
        final Color? accent = aurisColor.toUpperCase() == 'F0A500'
            ? null
            : parseHexColor(aurisColor, fallback: const Color(0xFFF0A500));
        return isDark
            ? AurisTheme.dark(accent: accent)
            : AurisTheme.light(accent: accent);
      case 'classic':
      default:
        final scheme = FlexSchemeColor.from(
          primary: parseHexColor(classicColor),
          secondary: classicSecondary.isEmpty
              ? null
              : parseHexColor(classicSecondary),
        );
        return isDark
            ? FlexThemeData.dark(colors: scheme.toDark())
            : FlexThemeData.light(colors: scheme);
    }
  }

  @override
  Widget build(BuildContext context) {
    // THE SIX SETTINGS THIS WIDGET IS MADE OF, and nothing else.
    //
    // This is the root MaterialApp: rebuilding it reconciles the entire app
    // below it. Watching the whole provider did that on every announcement it
    // makes — every keystroke in the wizard, every box dropped on a drawing,
    // every price typed into the estimate — to rebuild a theme out of six
    // values that only App Config can change. Selected as a record, which
    // compares by value, so the app is rebuilt when the LOOK of it changes.
    final theme = context.select((AppStateProvider p) => (
          style: p.themeStyle,
          dark: p.isDarkMode,
          classic: p.classicColor,
          auris: p.aurisColor,
          secondary: p.classicSecondary,
          textScale: p.textScale,
        ));

    return MaterialApp(
      // Remount the whole tree when crossing the Auris <-> Classic boundary.
      // Auris text styles use inherit: true while Classic's Material
      // defaults use inherit: false, and TextStyle.lerp throws on that
      // mismatch. themeAnimationDuration covers MaterialApp's own
      // cross-fade, but individual widgets (button labels, tab labels)
      // also animate their text styles — a remount skips every in-flight
      // animation. Auris accent changes and the dark/light toggle keep
      // the same key, so those still switch without losing UI state.
      key: ValueKey(theme.style == 'classic'),
      title: 'Deployment Configurator',
      // Style comes from App Config (Classic with a pickable accent color —
      // the default — or the Auris amber/teal/magenta variants); the
      // sun/moon toggle still switches dark <-> light within any style.
      theme: themeFor(
          theme.style,
          theme.dark,
          theme.classic,
          theme.auris,
          theme.secondary),
      themeAnimationDuration: Duration.zero,
      // App-wide text size (App Config > Text Size): scale every text style
      // by wrapping the whole app in a MediaQuery text scaler.
      navigatorKey: navigatorKey,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(theme.textScale),
        ),
        // The "update available" card sits over every tab and never blocks
        // anything; see app_updates.dart.
        child: UpdateNoticeHost(
          updater: appUpdater,
          child: _helpShortcuts(child!),
        ),
      ),
      home: const MainDashboard(),
    );
  }

  /// F1, FROM ANYWHERE, ON EVERY TAB.
  ///
  /// ============================================================================
  ///  WHY IT IS UP HERE AND NOT WITH THE OTHER SHORTCUTS
  /// ============================================================================
  ///  The save and undo keys are bound inside the page, which means they only
  ///  fire once something in the page has taken focus - a field, a button,
  ///  anything clicked. That is fine for them: nobody presses Ctrl+Z before
  ///  they have touched the thing they want undone.
  ///
  ///  Help is the opposite. It is pressed by somebody who has just arrived,
  ///  has not clicked anything, and does not know what to click - which is
  ///  precisely the state in which the primary focus is still the route's own
  ///  scope, an ANCESTOR of the page. A binding inside the page would never see
  ///  the key.
  ///
  ///  MaterialApp's builder inserts above the Navigator, so the key event
  ///  bubbling up out of that scope passes through here. The dialog still has
  ///  to open INSIDE the navigator, which is what [navigatorKey] is for.
  static Widget _helpShortcuts(Widget child) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.f1): _OpenHelpIntent(),
    },
    child: Actions(
      actions: {
        _OpenHelpIntent: CallbackAction<_OpenHelpIntent>(
          onInvoke: (_) {
            final context = navigatorKey.currentContext;
            if (context != null) showHelpBook(context);
            return null;
          },
        ),
      },
      child: child,
    ),
  );
}

/// Press F1 - see [RoomConfigApp._helpShortcuts].
class _OpenHelpIntent extends Intent {
  const _OpenHelpIntent();
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  bool _setupDialogShown = false; // Prompt at most once per app session

  /// Wraps the main content area so it can be captured to an image for the
  /// screenshot annotator.
  final GlobalKey _captureKey = GlobalKey();

  /// THE WINDOW'S X BUTTON, INTERCEPTED.
  ///
  /// Flutter's desktop embedders ask the app before the window closes, and
  /// [AppLifecycleListener.onExitRequested] is where that question arrives.
  /// Answering [ui.AppExitResponse.cancel] keeps the window open, which is
  /// what makes an "are you sure" possible at all — without it the config,
  /// four drawings and an estimate go with the window, and the first anybody
  /// knows about it is the next morning.
  ///
  /// Only ever asks when there is something to lose: a session with everything
  /// saved closes as immediately as it always did.
  AppLifecycleListener? _lifecycle;

  /// Guards against the second question. A user who takes ten seconds over the
  /// dialog can press the X again behind it, and two stacked copies of the
  /// same prompt is how somebody ends up answering "close without saving" to a
  /// dialog they thought they had already dismissed.
  bool _exitPromptOpen = false;

  /// The recovery copy this session has already asked about.
  ///
  /// The prompt is raised from [build] rather than from each of the four
  /// places a room can be opened from — by hand, from the start screen, from
  /// the project's room picker, off a processor — because a check that has to
  /// be added to a new open path is a check that will one day be missing from
  /// one. Keyed on the slot's folder so the NEXT room's recovery copy still
  /// gets its own prompt.
  String _recoveryAsked = '';

  /// Held so [dispose] can stop listening without reaching for the context.
  AppStateProvider? _provider;
  bool _unsavedCheckScheduled = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    _provider = context.read<AppStateProvider>()
      ..addListener(_scheduleUnsavedCheck);
    _scheduleUnsavedCheck();
  }

  /// UNSAVED WORK HOLDS THE UPDATE CHECKS BACK.
  ///
  /// Somebody with edits that are not on disk is in the middle of something,
  /// so the half-hourly check waits (and its card stays hidden) until they
  /// save. Asked at most once a frame: the provider notifies many times a
  /// frame while editing, and each notify throws away the cached fingerprint
  /// [AppStateProvider.hasUnsavedWork] compares against.
  void _scheduleUnsavedCheck() {
    if (_unsavedCheckScheduled) return;
    _unsavedCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unsavedCheckScheduled = false;
      final provider = _provider;
      if (!mounted || provider == null) return;
      appUpdater.setBusy(this, provider.hasUnsavedWork);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _provider?.removeListener(_scheduleUnsavedCheck);
    appUpdater.setBusy(this, false);
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<ui.AppExitResponse> _onExitRequested() async {
    if (!mounted) return ui.AppExitResponse.exit;
    final provider = context.read<AppStateProvider>();
    if (!provider.hasUnsavedWork) return ui.AppExitResponse.exit;
    // A second X while the first prompt is still up must not stack another
    // dialog on top of it.
    if (_exitPromptOpen) return ui.AppExitResponse.cancel;

    _exitPromptOpen = true;
    try {
      final mayClose = await confirmCloseWithUnsavedWork(context, provider);
      return mayClose ? ui.AppExitResponse.exit : ui.AppExitResponse.cancel;
    } finally {
      _exitPromptOpen = false;
    }
  }

  /// Captures the current content area and opens the annotation editor. The
  /// default file name embeds the active tab + date.
  void _takeScreenshot(BuildContext context, int selectedIndex) {
    final tabToken =
        (selectedIndex >= 0 && selectedIndex < AppTab.values.length)
            ? AppTab.values[selectedIndex].token
            : 'view';
    final dateToken = DateTime.now().toLocal().toIso8601String().split('T').first;
    captureAndAnnotate(context, _captureKey,
        defaultFileName: '${tabToken}_screenshot_$dateToken.png');
  }

  /// Creates a new config from the template. Shared by the toolbar button
  /// (always available) and the landing screen button: asks for confirmation
  /// first when a config is already loaded, and routes to App Config with an
  /// explanation when no template can be found.
  Future<void> _createNewConfig(
      BuildContext context, AppStateProvider provider) async {
    if (provider.roomConfig.isNotEmpty) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Create New Config?'),
          content: const Text(
              'This replaces the currently loaded configuration with a fresh '
              'one from the template. Unsaved changes will be lost.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Create New'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!context.mounted) return;

    // Two questions that change what the rest of the session looks like: is
    // there a control system yet, and are the devices coming from the cost
    // estimator? Both default to the old behavior.
    final NewRoomChoice? choice = await showNewRoomDialog(context);
    if (choice == null || !context.mounted) return;

    // The room itself — template, mode and room-type preset — is shared with
    // the project picker's "New room on this project", so the two routes
    // cannot drift into producing different rooms. See [createRoomFromChoice].
    final bool success = await createRoomFromChoice(context, provider, choice);
    if (!context.mounted) return;
    if (success) {
      if (choice.startFromEstimator) {
        final started = await showDeviceStartWizard(context, provider);
        if (!context.mounted) return;
        if (started.placed > 0) {
          // Straight to the estimate: the list was just priced, and the
          // numbers are what the wizard was opened for.
          provider.selectTab(AppTab.cost.index);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 7),
              content: Text(
                [
                  '${started.placed} device'
                      '${started.placed == 1 ? '' : 's'} added - they are on '
                      'the Signal Flow canvas and priced here',
                  // What the Wizard tab and the Devices tab will now show, so
                  // the blocks are not a silent side effect.
                  if (started.blocks > 0)
                    '${started.blocks} device block'
                        '${started.blocks == 1 ? '' : 's'} written to the '
                        'config',
                  // Devices is hidden on an estimate.
                  if (started.withoutModule > 0 &&
                      choice.mode != RoomMode.estimate)
                    '${started.withoutModule} still needing a python module - '
                        'the Devices tab shows those in red',
                ].join('. '),
              ),
            ),
          );
          return;
        }
      }

      // An estimate starts on the Cost tab, where its building and room
      // number are set.
      if (choice.mode == RoomMode.estimate) {
        provider.selectTab(AppTab.cost.index);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            choice.mode == RoomMode.estimate
                ? 'New estimate created. Set the building and room number, '
                      'then add the equipment.'
                : 'New config created from template.',
          ),
        ),
      );
    } else {
      // createRoomFromChoice has already said what was missing; this is the
      // one thing it cannot do, which is send somebody to the setting.
      provider.selectTab(AppTab.appConfig.index);
    }
  }


  /// Puts the working file back the way it was before the last save, after
  /// showing exactly what that costs.
  ///
  /// The dialog lists the differences between the backup and the config on
  /// screen — which is more than the save wrote, because any editing done
  /// since is in there too and goes with it. That list is the whole point of
  /// the confirmation: "undo a save" is easy to press expecting only the last
  /// thing you typed to come back.


  Future<void> _undoLastSave(
      BuildContext context, AppStateProvider provider) async {
    final List<ConfigDelta> deltas = await provider.undoDeltas();
    if (!context.mounted) return;

    if (deltas.isEmpty) {
      // SAYS WHICH QUESTION IT ANSWERED. "Nothing to undo" sent people
      // looking for a broken Undo button; the room genuinely does match its
      // backup, and the edits they wanted back are on the real history.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'This room already matches the saved backup, so there is nothing to '
          'revert to. To step back through your edits, use Undo (Ctrl+Z) or '
          'the Undo button on the page you are editing.',
        ),
      ));
      return;
    }

    final String backupName =
        provider.saveBackupPath.split(Platform.pathSeparator).last;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // NAMED FOR WHAT IT DOES, like the button that opens it. A box titled
        // "Undo Last Save" over a list of everything about to be discarded is
        // the wrong promise: Undo steps back one edit, and this replaces the
        // room with a file.
        title: Row(children: [
          const Icon(Icons.settings_backup_restore, color: Colors.orange),
          const SizedBox(width: 10),
          Expanded(
              child: Text('Revert to the saved backup',
                  style: Theme.of(ctx).textTheme.titleLarge)),
        ]),
        content: SizedBox(
          width: 560,
          height: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Restoring $backupName rewrites both the file and what is '
                  'on screen. ${deltas.length} propert'
                  '${deltas.length == 1 ? 'y' : 'ies'} would change - this '
                  'includes anything you have edited since that save:'),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Theme.of(ctx).dividerColor),
                  ),
                  child: ListView.builder(
                    itemCount: deltas.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 6.0),
                      child: Text(deltas[index].summary,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.settings_backup_restore, size: 18),
            label: const Text('Restore Backup'),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final bool ok = await provider.undoLastSave();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Restored $backupName - the file and the editor are back to the '
              'previous save.'
          : 'Could not restore $backupName; nothing was changed.'),
      backgroundColor: ok ? Colors.green : Colors.orange.shade800,
    ));
  }

  /// Brings the schematic in line with the config that was just opened.
  ///
  /// A saved `<config>_control_schematic.json` belongs to the config file, so
  /// loaded from that folder as soon as the config is — no need to visit the
  /// Schematic tab first. The one case that isn't obvious is a session that has
  /// already arranged a diagram of its own: then the user is asked whether to
  /// take the saved one or discard it and keep what's on screen.
  Future<void> _syncSchematicAfterLoad(
      BuildContext context, AppStateProvider provider) async {
    if (!provider.schematicLayoutNeedsChoice) {
      provider.loadSchematicLayoutForCurrentConfig();
      return;
    }
    final bool? loadSaved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Saved control schematic found'),
        content: Text(
            'This config has a saved control schematic beside it:\n\n'
            '${provider.schematicSidecarPath}\n\n'
            'You also have a control schematic arranged in this session. '
            'Load the saved one, or discard it and keep yours?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Discard saved, keep mine'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Load saved control schematic'),
          ),
        ],
      ),
    );
    // Dismissed without answering: the file's own layout is the safe default.
    if (loadSaved == false) {
      provider.keepSchematicLayoutForCurrentConfig();
    } else {
      provider.loadSchematicLayoutForCurrentConfig();
    }
  }

  /// The AV Flow equivalent of [_syncSchematicAfterLoad], for the
  /// `<config>_av_flow.json` sidecar. Same rule: load it silently unless the
  /// session already has a diagram of its own worth protecting.
  Future<void> _syncAvFlowAfterLoad(
      BuildContext context, AppStateProvider provider) async {
    if (!provider.avFlowNeedsChoice) {
      provider.loadAvFlowForCurrentConfig();
      return;
    }
    final bool? loadSaved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Saved AV flow found'),
        content: Text('This config has a saved AV signal flow beside it:\n\n'
            '${provider.avFlowSidecarPath}\n\n'
            'You also have an AV flow drawn in this session. Load the saved '
            'one, or discard it and keep yours?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Discard saved, keep mine'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Load saved AV flow'),
          ),
        ],
      ),
    );
    if (loadSaved == false) {
      provider.keepAvFlowForCurrentConfig();
    } else {
      provider.loadAvFlowForCurrentConfig();
    }
  }

  /// Both diagrams belong to the config file, so both sidecars are picked up
  /// together whenever a config is opened or downloaded.
  Future<void> _syncDiagramsAfterLoad(
      BuildContext context, AppStateProvider provider) async {
    await _syncSchematicAfterLoad(context, provider);
    if (!context.mounted) return;
    await _syncAvFlowAfterLoad(context, provider);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final hasConfig = provider.roomConfig.isNotEmpty;
    // Selected tab lives in the provider so it survives the remount that a
    // theme-family change (Auris <-> Classic) forces via the MaterialApp key.
    final int selectedIndex = provider.selectedTabIndex;

    // A recovery copy that outlived the session that wrote it — see
    // recovery_dialog.dart. Post-frame, like the first-run dialog below it,
    // because this runs during a build.
    final recovery = provider.pendingRecovery;
    if (recovery != null && _recoveryAsked != recovery.folder) {
      _recoveryAsked = recovery.folder;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showRecoveryDialog(context, context.read<AppStateProvider>());
      });
    }

    // FIRST-RUN CHECK: once the saved settings have been read, show the
    // one-time setup dialog asking where each file is located. When setup
    // was completed on an earlier launch this is bypassed entirely.
    if (provider.settingsLoaded &&
        provider.firstRunSetupNeeded &&
        !_setupDialogShown) {
      _setupDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const FirstRunSetupDialog(),
        );
      });
    }

    // CTRL+S, WHEREVER YOU ARE STANDING.
    //
    // Wrapped around the whole page rather than hung off the toolbar button: a
    // shortcut is dispatched up from whatever has focus, so from here it
    // reaches a field on the wizard, a box on a drawing and a cell on the
    // estimate alike. What it saves is the tab's own scope — the same answer
    // the toolbar's Save gives, so the key and the button can never mean two
    // different files.
    final saveScope = saveScopeForTab(
      (selectedIndex >= 0 && selectedIndex < AppTab.values.length)
          ? AppTab.values[selectedIndex]
          : AppTab.wizard,
    );

    final currentTab =
        (selectedIndex >= 0 && selectedIndex < AppTab.values.length)
            ? AppTab.values[selectedIndex]
            : AppTab.wizard;
    final onCost = currentTab == AppTab.cost && hasConfig;

    // THE DOCUMENT ROW: Convert, and Save in its right-hand corner. The file
    // transfers went into the File menu and the exports onto the Export
    // button in the lower right.
    final documentActions = <Widget>[
      // CONVERT: the migration a legacy file needs, on demand. The load
      // already ran the conversion in memory — this is where it gets
      // reviewed, accepted or thrown away. Grayed out when the loaded
      // file had nothing to migrate, so its state is also the answer to
      // "does this room need converting?".
      IconButton(
        key: const ValueKey('convert_button'),
        icon: Badge(
          key: const ValueKey('conversion_badge'),
          isLabelVisible: provider.conversionNeedsAttention,
          label: Text('${provider.conversionChanges.length}'),
          child: const Icon(Icons.compare_arrows),
        ),
        tooltip: switch ((
          provider.lastLoadHadChanges,
          provider.conversionAcknowledged,
        )) {
          (false, _) => provider.lastLoadHadNotes
              ? 'Nothing to convert - open the notes on this file'
              : 'Nothing to convert in this file',
          (true, false) => 'Convert - review the changes this file needs',
          (true, true) => 'Conversion reviewed - open the log again',
        },
        onPressed: provider.lastLoadHadChanges || provider.lastLoadHadNotes
            ? () => _showMigrationLogDialog(context, provider.systemLogs)
            : null,
      ),
      // SAVE, AND EVERY OTHER WAY OF SAVING, in the corner of this row. One
      // button that writes whatever document the tab on screen belongs to,
      // with a dot when it is behind its file and a menu beside it - see
      // save_actions.dart.
      const SaveToolbar(),
    ];

    // The bar the gear's SELECTED accent is painted on, so it can be measured
    // against that fill rather than assumed to read on it.
    final appBarFill =
        theme.appBarTheme.backgroundColor ?? theme.colorScheme.primary;

    final page = Scaffold(
      // EVERY WAY A DOCUMENT LEAVES THE APP, on one button that floats in the
      // lower right - the room, the job or the campus, whichever are open.
      floatingActionButton: _ExportFab(
        selectedIndex: selectedIndex,
        hasConfig: hasConfig,
      ),
      appBar: AppBar(
        // THE FILE MENU AND THE STEPS AT THE LEFT, THE APP AT THE RIGHT.
        //
        // The hamburger holds everything that starts, opens or transfers a
        // document; Undo, Redo and the history sit beside it. The far corner
        // is the application: the screenshot and the light/dark toggle, Help,
        // and Settings in the corner itself.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FileMenu(
                      onNewRoom: () => _createNewConfig(context, provider),
                      onNewProject: () => startNewProject(context, provider),
                      onNewCampus: () => showCampusLifecycle(context),
                      onOpen: (title) =>
                          _openExistingConfig(context, provider, title: title),
                      onOpenPath: (file) =>
                          _openDocumentAtPath(context, provider, file),
                      onDownload: () => _downloadFromProcessor(context, provider),
                      onUpload: () => showDialog(
                        context: context,
                        barrierDismissible: false,
                        builder: (context) =>
                            const ProcessorSftpDialog(isUpload: true),
                      ),
                    ),
                    // BACK ONE STEP ON WHATEVER THIS PAGE EDITS. Nothing at
                    // all on the pages that carry their own pair - see
                    // [toolbarUndoTarget].
                    ToolbarUndoButtons(tab: currentTab),
                    // WHO CHANGED WHAT, from wherever you are standing.
                    IconButton(
                      key: const ValueKey('show_history'),
                      icon: const Icon(Icons.history),
                      tooltip: 'History - what has been changed on this room '
                          'and this job',
                      onPressed: () => showHistoryDialog(context),
                    ),
                    // REVERT TO THE SAVED BACKUP: put back the
                    // '<name>_previous.json' copy the save took of the file
                    // beforehand. Not Undo - it reads a FILE off disk and
                    // replaces the room with it.
                    IconButton(
                      key: const ValueKey('revert_to_backup'),
                      icon: const Icon(Icons.settings_backup_restore),
                      tooltip: provider.canUndoLastSave
                          ? 'Revert to the saved backup - replace this room '
                              'with '
                              '${provider.saveBackupPath.split(Platform.pathSeparator).last}'
                              ', the copy taken before the last save. This is '
                              'not Undo: it discards everything since that '
                              'save.'
                          : 'Revert to the saved backup - nothing has been '
                              'saved over a local file yet',
                      onPressed: provider.canUndoLastSave
                          ? () => _undoLastSave(context, provider)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (!projectIsOpen(provider)) ...const [
              Flexible(
                child: Text(
                  'Room Config Builder',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: 16),
            ],
            const Flexible(child: ProjectRoomPicker()),
          ],
        ),
        titleSpacing: 4,
        actions: [
          // SCREENSHOT - a menu, because there are two pictures somebody
          // means: the screen as it is, and on the Cost tab the whole
          // estimate rendered as a dated quote.
          PopupMenuButton<String>(
            key: const ValueKey('screenshot_menu'),
            icon: const Icon(Icons.photo_camera),
            tooltip: onCost
                ? 'Screenshot - the screen, or the estimate as a picture'
                : 'Screenshot & annotate',
            onSelected: (v) {
              switch (v) {
                case 'screen':
                  _takeScreenshot(context, selectedIndex);
                case 'estimate_light':
                  CostEstimateActions.current?.screenshot(Brightness.light);
                case 'estimate_dark':
                  CostEstimateActions.current?.screenshot(Brightness.dark);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                key: ValueKey('screenshot_screen'),
                value: 'screen',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.photo_camera),
                  title: Text('Screenshot & annotate'),
                  subtitle: Text('What is on screen now'),
                ),
              ),
              if (onCost && CostEstimateActions.current != null) ...const [
                PopupMenuDivider(),
                PopupMenuItem(
                  key: ValueKey('screenshot_estimate_light'),
                  value: 'estimate_light',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.light_mode),
                    title: Text('Estimate as a picture - light'),
                    subtitle: Text('The whole quote, dated, controls hidden'),
                  ),
                ),
                PopupMenuItem(
                  key: ValueKey('screenshot_estimate_dark'),
                  value: 'estimate_dark',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.dark_mode),
                    title: Text('Estimate as a picture - dark'),
                    subtitle: Text('For a dark slide deck'),
                  ),
                ),
              ],
            ],
          ),
          IconButton(
            key: const ValueKey('toggle_theme'),
            icon: Icon(provider.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            tooltip: provider.isDarkMode
                ? 'Switch to light mode'
                : 'Switch to dark mode',
            onPressed: () => provider.toggleTheme(),
          ),
          // HELP, just left of Settings.
          const HelpButton(),
          // SETTINGS, IN THE CORNER - and it toggles: the gear opens the
          // settings window over the page you were on, and the gear again
          // closes it and puts you back there.
          IconButton(
            key: const ValueKey('banner_app_config'),
            icon: const Icon(Icons.settings),
            isSelected: provider.settingsOpen,
            selectedIcon: Icon(
              Icons.settings,
              color: legibleTone(
                theme.colorScheme.secondary,
                appBarFill,
                minRatio: kContrastLarge,
              ),
            ),
            tooltip: provider.settingsOpen
                ? 'Close Settings'
                : 'Settings - file locations, theme, pricing, autosave',
            onPressed: provider.toggleSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // The job and the gear, above every tab rather than among them.
          TopLevelBar(
            selectedIndex: selectedIndex,
            onSelect: provider.selectTab,
            actions: documentActions,
          ),
          Expanded(
            child: Row(
        children: [
          // Inside a [SidePane] so the whole rail can be narrowed to icons or
          // folded away entirely: on a laptop, a drawing is worth more than a
          // column of labels, and the tab you are on is the only one you are
          // reading. The scrolling and the label sizing that make that
          // survivable live in [AppNavRail].
          SidePane(
            side: PaneSide.left,
            title: 'Tabs',
            storageKey: 'nav_rail',
            initialWidth: 108,
            minWidth: 72,
            maxWidth: 220,
            child: AppNavRail(
              selectedIndex: selectedIndex,
              onDestinationSelected: provider.selectTab,
              tabs: visibleNavTabs(estimateOnly: provider.isEstimateRoom),
            ),
          ),
          Expanded(
            child: RepaintBoundary(
              key: _captureKey,
              // A floor under every page: narrower than this and the page
              // scrolls sideways with a scrollbar instead of being cut off.
              child: MinWidthScroll(
                minWidth: 640,
                child: (!hasConfig && !_tabWorksWithoutConfig(selectedIndex))
                    ? _buildLandingScreen(context, provider)
                    : _buildMainContent(
                        selectedIndex,
                        provider.configRevision,
                        provider.isEstimateRoom,
                      ),
              ),
            ),
          )
        ],
      ),
          ),
        ],
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          // runSave already opens the "where should this go" dialog for a
          // document that has no file yet, so there is one branch here, not
          // two.
          if (saveBlockedReason(provider, saveScope).isEmpty) {
            runSave(context, provider, saveScope);
          }
        },
        // CTRL+SHIFT+S IS SAVE ALL - every open document that is behind its
        // file, the room and the job together. Save As moved to Ctrl+Alt+S.
        const SingleActivator(LogicalKeyboardKey.keyS,
                control: true, shift: true):
            () => saveEverything(context, provider),
        const SingleActivator(LogicalKeyboardKey.keyS,
            control: true, alt: true): () {
          if (saveScopeSupportsSaveAs(saveScope)) {
            runSave(context, provider, saveScope, saveAs: true);
          }
        },
        // UNDO AND REDO ON WHATEVER THIS PAGE EDITS, by the same rule the save
        // keys follow: the shortcut acts on the document the tab in front of
        // you belongs to. Every room page now answers that with the ROOM, so
        // Ctrl+Z on the estimate takes back the last thing done in this room
        // wherever it was done — and, like the button, moves the view to it.
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            _undoOnCurrentTab(context, provider, redo: false),
        // Both spellings, because both are muscle memory and neither is used
        // for anything else here.
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): () =>
            _undoOnCurrentTab(context, provider, redo: true),
        const SingleActivator(LogicalKeyboardKey.keyZ,
            control: true, shift: true): () =>
            _undoOnCurrentTab(context, provider, redo: true),
      },
      child: CollabNoticeListener(child: page),
    );
  }

  /// Ctrl+Z / Ctrl+Y on the document the current tab edits.
  ///
  /// Always the same document the pair in the title bar acts on, read from the
  /// same place: a shortcut that meant something other than the button beside
  /// it would be the worst of both.
  static void _undoOnCurrentTab(
    BuildContext context,
    AppStateProvider provider, {
    required bool redo,
  }) {
    final index = provider.selectedTabIndex;
    if (index < 0 || index >= AppTab.values.length) return;
    final target = toolbarUndoTarget(AppTab.values[index]);
    if (target == null) return;

    final said = switch ((target, redo)) {
      (ToolbarUndoTarget.project, false) => provider.undoProject(),
      (ToolbarUndoTarget.project, true) => provider.redoProject(),
      (ToolbarUndoTarget.room, false) => provider.undoRoom(),
      (ToolbarUndoTarget.room, true) => provider.redoRoom(),
      (ToolbarUndoTarget.catalog, final r) =>
        r ? provider.redoAppData(AppDataDocument.catalog)
          : provider.undoAppData(AppDataDocument.catalog),
      (ToolbarUndoTarget.schema, final r) =>
        r ? provider.redoAppData(AppDataDocument.schema)
          : provider.undoAppData(AppDataDocument.schema),
      (ToolbarUndoTarget.flowRules, final r) =>
        r ? provider.redoAppData(AppDataDocument.flowRules)
          : provider.undoAppData(AppDataDocument.flowRules),
    };
    if (said.isEmpty || !context.mounted) return;
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(content: Text('${redo ? 'Redid' : 'Undid'}: $said')),
    );
  }

  /// The three helpers behind the per-tab export button, each guarding the
  /// same thing: [selectedTabIndex] is an int, and an int can be out of range
  /// for a moment while the rail is rebuilt.
  static bool _tabExports(int index) =>
      index >= 0 &&
      index < AppTab.values.length &&
      tabCanExport(AppTab.values[index]);

  static String _tabExportLabel(int index) =>
      index >= 0 && index < AppTab.values.length
          ? tabExportLabel(AppTab.values[index])
          : 'This tab';

  static bool _tabWorksWithoutConfig(int index) =>
      index >= 0 &&
      index < AppTab.values.length &&
      AppTab.values[index].worksWithoutConfig;

  /// THE START SCREEN — the two questions a session actually begins with.
  ///
  /// A job is a building, and a building is a list of rooms. So the project
  /// comes first and the room file second, each as a card. The old screen
  /// offered only the room half, which is why people who had a project on disk
  /// started by opening a room from it and then went looking for where the job
  /// itself lived.
  ///
  /// MAKING IS PER CARD; OPENING IS NOT. A new document has to be told which
  /// kind it is - the two Create buttons are the whole of that question. But
  /// opening one does not: the file on disk already knows whether it is a
  /// room, a job or a campus, and [_openExistingConfig] reads it and does the
  /// right thing. Two Open buttons asked the reader to classify a file the app
  /// classifies better, and a reader who guessed wrong was told their campus
  /// was not a project - about a file that opens perfectly well. So there is
  /// ONE Open, under both cards, and it names all three.
  ///
  /// The cards are in a [Wrap], so on a narrow window they stack instead of
  /// being clipped, and the whole thing scrolls — at 150% text two cards side
  /// by side are taller than a laptop screen.
  Widget _buildLandingScreen(BuildContext context, AppStateProvider provider) {
    final theme = Theme.of(context);
    // A project counts as open once it has a file or any rooms on it — the two
    // ways somebody ends up with a job in front of them.
    // The same question the banner asks, asked the same way — a start screen
    // that thought a job was open while the banner did not (or the other way
    // round) would be two answers to "what am I working on".
    final projectOpen = provider.hasOpenProject;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_tree, size: 64, color: theme.disabledColor),
            const SizedBox(height: 16),
            Text('Room Config Builder',
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              projectOpen
                  ? '${provider.projectDisplayName} is open. Pick one of its '
                      'rooms from the Project tab, or start a new file here.'
                  : 'Start with the job, or go straight to a room.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.disabledColor),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            // THE TWO BUTTONS SIT ON ONE LINE.
            //
            // They did not. Each card was as tall as its own words, and the
            // two blurbs are different lengths - so Start a New Project sat a
            // line below Create a New File. Two buttons that do the same KIND
            // of thing, at two different heights, read as a mistake before
            // they read as anything else.
            //
            // Making the CARDS equal height does not fix it, which is the
            // trap: the slack then lands wherever the column happens to put
            // it, and the subtitles wrap to different line counts too, so the
            // buttons move apart again from below. What has to match is
            // everything ABOVE the button, and everything below it, exactly.
            //
            // So the two variable blocks are MEASURED - at the width they will
            // be drawn at, in the reader's own text size - and both cards
            // reserve the taller. Every row of both cards is then the same
            // height as its opposite number, which puts the buttons on one
            // line at any scale and makes the cards the same height into the
            // bargain. See [_startCardTextWidth] and [_tallestBlock].
            Builder(
              builder: (context) {
                // THE PROJECT HALF ONLY WHEN THERE IS NO PROJECT.
                //
                // Somebody with a job already open is not looking for a way to
                // start one — they are here because the room slot is empty,
                // and "Start a New Project" next to that is an invitation to
                // throw away the job they just opened. The Project button in
                // the banner is still one click away; what this screen owes
                // them is the room.
                const projectBlurb =
                    'A building and the rooms in it, with the vendor split '
                    'and the totals across the whole job.';
                const projectSub = 'No project open';
                const roomBlurb =
                    'One room: its config, its drawings, its rack and its '
                    'estimate.';
                const roomSub =
                    'New files start from the template in App Config';

                // Only over the cards actually on screen: reserving room for a
                // blurb nobody can see would leave a hole in the one card that
                // is left.
                final blurbs = [roomBlurb, if (!projectOpen) projectBlurb];
                final subs = [roomSub, if (!projectOpen) projectSub];
                final subStyle = theme.textTheme.bodySmall
                    ?.copyWith(color: theme.disabledColor);
                final blurbHeight =
                    _tallestBlock(context, blurbs, theme.textTheme.bodyMedium);
                final subtitleHeight =
                    _tallestBlock(context, subs, subStyle);

                return Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 24,
                  runSpacing: 24,
                  children: [
                    if (!projectOpen)
                      _StartCard(
                        icon: Icons.account_tree,
                        title: 'Project',
                        blurb: projectBlurb,
                        primaryLabel: 'Start a New Project',
                        primaryIcon: Icons.create_new_folder,
                        onPrimary: () => startNewProject(context, provider),
                        subtitle: projectSub,
                        blurbHeight: blurbHeight,
                        subtitleHeight: subtitleHeight,
                      ),
                    _StartCard(
                      icon: Icons.description,
                      title: 'Room file',
                      blurb: roomBlurb,
                      primaryLabel: 'Create a New File',
                      primaryIcon: Icons.note_add,
                      onPrimary: () => _createNewConfig(context, provider),
                      subtitle: roomSub,
                      blurbHeight: blurbHeight,
                      subtitleHeight: subtitleHeight,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            // THE ONE DOOR IN, FOR ANY OF THE THREE.
            //
            // Under both cards rather than inside either, because it belongs to
            // neither: it is the same button as the folder in the title bar,
            // and it takes whichever of the three documents it is handed. Sized
            // to the pair of cards on a wide window so it reads as the floor
            // under them, and it says the three out loud - a reader who does
            // not know a campus is a file it will take is a reader who never
            // finds out.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 704),
              child: Column(
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('start_open_any'),
                    icon: const Icon(Icons.folder_open),
                    label: const Text(
                      'Open a File',
                      textAlign: TextAlign.center,
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: () => _openExistingConfig(context, provider),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A room config, a project or a campus - it reads the file '
                    'and opens whichever it is.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.disabledColor),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            // WHAT THIS MACHINE WAS WORKING ON, on the screen somebody lands
            // on. The title bar has the same list a click away, but a start
            // screen is read by somebody who has just launched the app and is
            // deciding — and for them the answer to "where was I" should not
            // be behind a button. Draws nothing at all on a cold install.
            if (provider.recentFiles.isNotEmpty) ...[
              RecentFilesPanel(
                onOpen: (file) => _openDocumentAtPath(context, provider, file),
              ),
              const SizedBox(height: 28),
            ],
            // The recovery copies, mentioned exactly where somebody who has
            // just lost a session would look for them.
            Text(
              autosaveStatusLine(provider),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.disabledColor),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Fetches config.json off a processor - the File menu's Download.
  Future<void> _downloadFromProcessor(
      BuildContext context, AppStateProvider provider) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ProcessorSftpDialog(isUpload: false),
    );
    if (result != true || !context.mounted) return;
    // Working copy on disk now — pick up any schematic beside it.
    await _syncDiagramsAfterLoad(context, provider);
    // Same as a local open: the download lands, and Convert offers the
    // migration when the user is ready for it.
    if (provider.lastLoadHadChanges && context.mounted) {
      _announceConversionAvailable(context);
    }
  }

  /// Opening a room file, from the start screen and from the toolbar — the
  /// same load, the same sidecar sync, the same conversion notice, so which
  /// button was pressed cannot change what a room comes back as.
  Future<void> _openExistingConfig(
      BuildContext context, AppStateProvider provider,
      {String title = 'Open a room config, a project or a campus'}) async {
    // ONE OPEN BUTTON, EITHER DOCUMENT. Both a room and a job are a .json in
    // the same folder, and somebody who picks the job out of that folder means
    // to open the job — being told it is not a room config would be the app
    // refusing to do the obvious thing.
    final picked = await FilePicker.pickFiles(
      dialogTitle: title,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = picked?.files.single.path;
    if (file == null || !context.mounted) return;
    await _openDocumentAtPath(context, provider, file);
  }

  /// Opens whichever of the three documents [file] is - everything
  /// [_openExistingConfig] does once the picker has closed.
  ///
  /// Its own method because the picker is no longer the only way in: Open
  /// Recent hands a path straight here, and a room opened off that menu has to
  /// be the same room as one picked out of the dialog - same conversion
  /// notice, same sidecars, same message when the file turns out not to be
  /// what it says it is.
  Future<void> _openDocumentAtPath(
      BuildContext context, AppStateProvider provider, String file) async {
    // THREE DOCUMENTS, ONE BUTTON. A campus is a list of jobs somebody
    // assembled and named - see campus_file.dart - and opening it here rather
    // than only from inside the campus view means the file behaves like the
    // document it is: double-click-ish, from the same place as the other two.
    if (CampusFile.looksLikeCampus(file)) {
      try {
        final campus = await CampusFile.load(file);
        if (!context.mounted) return;
        await showCampusLifecycleFile(context, campus);
      } catch (e) {
        if (!context.mounted) return;
        showTimedSnackBar(
          ScaffoldMessenger.of(context),
          SnackBar(
            content: Text('${path.basename(file)} is not a campus: $e'),
          ),
        );
      }
      return;
    }

    if (isProjectFile(file)) {
      if (!await confirmLeavingProject(context, provider)) return;
      if (!context.mounted) return;
      await openProjectAtPath(context, provider, file);
      return;
    }

    final bool loaded = await provider.openConfigAtPath(file);
    if (!context.mounted) return;
    if (!loaded) {
      if (provider.lastOpenError.isNotEmpty) {
        final messenger = ScaffoldMessenger.of(context);
        showTimedSnackBar(
          messenger,
          SnackBar(
            key: const ValueKey('open_failed_snack'),
            duration: const Duration(seconds: 12),
            backgroundColor: snackErrorFillOn(messenger),
            content: Text(provider.lastOpenError),
          ),
        );
      }
      return;
    }
    await _syncDiagramsAfterLoad(context, provider);
    // The conversion is NOT shown here. Opening a file should open the file; a
    // migration dialog in front of it makes every load of a legacy room a
    // dialog to dismiss before any work starts. The Convert button in the
    // toolbar lights up instead.
    if (provider.lastLoadHadChanges && context.mounted) {
      _announceConversionAvailable(context);
    }
  }

  /// The active tab's view. [configRevision] identifies the loaded room: the
  /// config-driven tabs are keyed on it so replacing the config (New from
  /// template, opening a file, a download) rebuilds their fields from scratch.
  /// Text fields and autocompletes read `initialValue` once per element, so
  /// without this the previous room's name and number stayed on screen until
  /// the user switched tabs and came back. App Config is left unkeyed — its
  /// fields are application settings and have nothing to do with the room.
  Widget _buildMainContent(
      int selectedIndex, int configRevision, bool estimateOnly) {
    final key = ValueKey('tab_${selectedIndex}_cfg_$configRevision');
    if (selectedIndex < 0 || selectedIndex >= AppTab.values.length) {
      return const Center(child: Text("Select a category"));
    }
    final tab = AppTab.values[selectedIndex];
    // Hidden from the rail, but still reachable from links elsewhere.
    if (estimateOnly && kEstimateHiddenTabs.contains(tab)) {
      return ControlSystemPlaceholder(
        key: key,
        tabName: 'the ${navTabLabel(tab)} tab',
      );
    }
    switch (tab) {
      case AppTab.wizard:
        return SetupWizardView(key: key);
      case AppTab.devices:
        return DynamicDevicesTabsView(key: key);
      case AppTab.system:
        return SystemSettingsView(key: key);
      case AppTab.schematic:
        return SchematicView(key: key);
      case AppTab.avFlow:
        return AvFlowView(key: key);
      case AppTab.floorPlan:
        return FloorPlanView(key: key);
      case AppTab.cabling:
        return CablingView(key: key);
      case AppTab.racks:
        return RackTabView(key: key);
      case AppTab.cost:
        return CostEstimateView(key: key);
      case AppTab.lifecycle:
        return LifecycleView(key: key);
      case AppTab.project:
        // Unkeyed, like the catalog: a project spans rooms, so opening a
        // different room must not throw away the job somebody is quoting.
        return const ProjectView();
      case AppTab.deviceEditor:
        // Unkeyed: the catalog is application data, not room data, so it must
        // not be thrown away and rebuilt when a different room is opened.
        return const DeviceEditorView();
      case AppTab.rawJson:
        // Unkeyed on purpose: the raw editor already re-reads the config in
        // didChangeDependencies, and remounting it mid-Apply would cut off its
        // own "applied/saved" feedback.
        return const JsonEditorView();
      case AppTab.schemaEditor:
        // Unkeyed, like the catalog: the schema is application data, and a
        // half-finished field definition must not be thrown away because
        // somebody opened a different room.
        return const SchemaEditorView();
      case AppTab.flowRules:
        return const FlowRulesView();
      case AppTab.appConfig:
        // A window over the page, with its own close button - see
        // [_SettingsWindow].
        return const _SettingsWindow(child: AppSettingsView());
    }
  }
}

/// One half of the start screen: a document, what it holds, and the only two
/// things anybody ever does with one.
///
/// Both actions are full-width buttons rather than a button and a link,
/// because "open the one I already have" is not the lesser of the two — for
/// everybody past their first week it is the commoner one. The new-document
/// button is filled and the open button outlined only so the pair can be told
/// apart at a glance.
class _StartCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String blurb;
  final String subtitle;
  final IconData primaryIcon;
  final String primaryLabel;
  final VoidCallback onPrimary;

  /// ONE BUTTON PER CARD, and it is the one that MAKES something.
  ///
  /// The card used to carry an Open under its Create. Opening moved out to the
  /// single button under both cards - see [_buildLandingScreen] - because the
  /// file on disk already knows which of the three documents it is, and asking
  /// the reader to classify it first was asking a question the app answers
  /// better.
  /// How much room to leave for the blurb and for the subtitle, whatever this
  /// card's own words need.
  ///
  /// Handed DOWN rather than worked out here, because the question is not
  /// about this card: it is "how tall is the tallest of the cards on screen",
  /// and only the screen that lays them out knows the others. See
  /// [_tallestBlock] and the layout in [_buildLandingScreen].
  final double blurbHeight;
  final double subtitleHeight;

  const _StartCard({
    required this.icon,
    required this.title,
    required this.blurb,
    required this.subtitle,
    required this.primaryIcon,
    required this.primaryLabel,
    required this.onPrimary,
    required this.blurbHeight,
    required this.subtitleHeight,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _startCardWidth(context),
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, size: 28, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Reserved rather than natural, so a three-line blurb and a
              // two-line one leave their buttons at the same height. Top
              // aligned - the spare line belongs under the words, not around
              // them.
              SizedBox(
                height: blurbHeight,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(blurb, style: theme.textTheme.bodyMedium),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: Icon(primaryIcon),
                label: Text(primaryLabel, textAlign: TextAlign.center),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: onPrimary,
              ),
              const SizedBox(height: 14),
              // Reserved for the same reason, so the cards END level too.
              SizedBox(
                height: subtitleHeight,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.disabledColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How wide a start card is, and how wide the words inside it get to be.
///
/// The text width is the card less the [Card]'s own margin and the padding
/// around its column, and it has to be right: it is what the blocks below are
/// measured at, and a measurement taken at the wrong width reserves the wrong
/// number of lines.
///
/// GROWN WITH THE READER'S TYPE. Fixed at 340 the card was the first screen of
/// the application reading 'Create a New Fi...' on any display above 100% -
/// the blurbs reserved their lines properly and the one control on the card
/// did not, which is the wrong half to get right. See [gridMetric].
/// 368 rather than the 340 it was: the card's one button reads 'Create a New
/// File', and at 340 the label wanted twenty-two pixels the card did not have
/// even at 100%. A card is sized by the longest thing on it, and the longest
/// thing on this one is the control.
double _startCardWidth(BuildContext context) => gridMetric(context, 368);

double _startCardTextWidth(BuildContext context) =>
    _startCardWidth(context) - 8 - 48;

/// The height of the tallest of [blocks] when wrapped inside a start card.
///
/// Measured rather than guessed at a line count: the same sentence is three
/// lines at normal size and five at 200%, and a card that reserved three would
/// clip the reader who most needs to read it. Everything that affects the
/// answer - the style, the reader's text scale, the width - goes into the
/// painter, so the number is the one the [Text] will actually take.
double _tallestBlock(
  BuildContext context,
  Iterable<String> blocks,
  TextStyle? style,
) {
  var tallest = 0.0;
  for (final block in blocks) {
    final painter = TextPainter(
      text: TextSpan(text: block, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: _startCardTextWidth(context));
    if (painter.height > tallest) tallest = painter.height;
    painter.dispose();
  }
  return tallest;
}

//// THE TWO THINGS THAT ARE NOT VIEWS OF A ROOM.
///
/// A banner across the top of the page, under the title, holding the job and
/// the gear. Both used to be rows in the left rail, in among Racks, Cabling
/// and Flow Rules — which said they were fifteenth and fourteenth of the same
/// kind of thing, and they are not the same kind of thing at all:
///
///   * THE PROJECT is what the room belongs to. It is one level up from every
///     tab in the rail, so it sits above them rather than among them, and it
///     carries the job's name so "which building am I in" is answered without
///     opening anything.
///   * APP CONFIG is not a place in the work either. It is settings, and
///     settings are a gear, in the corner, where every other application on
///     the machine keeps them.
///
/// Outside the [SidePane] on purpose: the rail folds away to give a drawing
/// the width, and the way back to the job must not fold away with it.
class TopLevelBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// The document's own buttons — convert, the two SFTP transfers and the
  /// exports — led by the theme toggle and the screenshot. Handed in rather
  /// than built here because they need the dashboard's own methods, and most
  /// of them live on THIS row because they are about the document the job is
  /// made of, not about the application; the two app-level ones are here
  /// because they are pressed while working rather than while setting up.
  final List<Widget> actions;

  const TopLevelBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onProject = selectedIndex == AppTab.project.index;

    // Whether the page underneath is about the ROOM. Every tab that needs a
    // config is one, which is the same question the start screen asks to
    // decide whether it has anything to show - see [AppTab.worksWithoutConfig].
    // Worked out before the selection below because the name in the strip
    // reads differently on a room tab, and this comes off the widget rather
    // than off the provider.
    final onRoomTab = selectedIndex >= 0 &&
        selectedIndex < AppTab.values.length &&
        !AppTab.values[selectedIndex].worksWithoutConfig;

    // THREE FLAGS AND A NAME, watched instead of the whole provider. This
    // strip is on screen on every tab for the whole session, and a plain watch
    // rebuilt it on everything the provider announces — a box moved on a
    // drawing, a price typed into the estimate — to redraw a line that had not
    // changed. The name is built inside the selection rather than out here so
    // it stays live: it carries the room name the wizard is being typed into,
    // and a record compares by value, so this rebuilds when that line would
    // actually read differently. See the same reasoning at the root
    // MaterialApp.
    final state = context.select((AppStateProvider p) {
      final hasProject = p.hasOpenProject;
      final hasRoom =
          p.roomConfig.isNotEmpty || p.currentConfigPath.isNotEmpty;
      return (
        hasProject: hasProject,
        hasRoom: hasRoom,
        projectDirty: p.projectDirty,
        documentName: _bannerDocumentName(
          p,
          hasProject: hasProject,
          hasRoom: hasRoom,
          onRoomTab: onRoomTab,
        ),
      );
    });

    // WHICH DOCUMENT THIS STRIP IS ABOUT, which is not always a job.
    //
    // A session that has only ever opened one room has no job in front of it,
    // and the way in to the Project tab used to be offered anyway - leading to
    // an empty room list that answered a question nobody had asked. Worse, it
    // said "Project" beside a room, which is the app telling somebody they are
    // working on something they are not.
    //
    // So the strip names what is actually open: the JOB when there is one, the
    // ROOM when there is only a room, and nothing at all on a cold start. A
    // job is started from New Project or Open Project - see the title bar -
    // and never by pressing something that was already on screen.
    final hasProject = state.hasProject;
    final hasRoom = state.hasRoom;

    // THE STRIP IS A DIFFERENT COLOR IN EACH MODE.
    //
    // Room and project are the two states this app is ever in, and until now
    // the only thing that said which was a button somebody had to read. A
    // tint is read without being looked at - it is the same trick as a
    // terminal that changes color when you are root, and it is worth more
    // than the label, because the mistake it prevents (working on a room
    // believing it is on the job, or the other way round) is one nobody makes
    // deliberately.
    //
    // Blended rather than picked: the accent is a color somebody chose out of
    // a wheel, so a tint of it is a hint of THIS theme rather than a color
    // that could clash with it. Everything painted on it is measured against
    // whichever fill is in use - see the ink below.
    final bannerFill = hasProject
        ? theme.colorScheme.surfaceContainerHighest
        : roomModeBannerFill(theme);

    // The ink every button on this strip is painted in, held to the icon bar
    // rather than the body one — see the group at the end of the row.
    final actionInk = readableOn(
      bannerFill,
      prefer: [
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurfaceVariant,
        theme.colorScheme.onSurface,
      ],
      minRatio: kContrastLarge,
    );

    return Material(
      color: bannerFill,
      // Tight on purpose. Every pixel this takes is a pixel off the drawing
      // below it, and on a laptop the drawing is what somebody is here for.
      //
      // No padding on the right: the last button belongs in the corner, and an
      // IconButton already carries its own margin, so twelve more pixels only
      // left it floating short of the edge.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
        child: Row(
          children: [
            // THE WAY UP AND OUT OF THE ROOM — only when there is somewhere to
            // go. Pushed out rather than flat: it should read as a different
            // kind of control from the tabs below it.
            if (hasProject) ...[
              // BIGGER THAN THE BUTTONS IT SITS AMONG, on purpose. This is
              // the way out of a room and back to the job, and it is the one
              // control on the strip that changes which of the two modes the
              // session is in - so it should be the first thing the eye lands
              // on in the corner rather than one more small button in a row
              // of them. Its own text style rather than the default label
              // size, because a button that is only taller reads as a
              // mis-sized button rather than a more important one.
              (onProject ? FilledButton.icon : FilledButton.tonalIcon)(
                key: const ValueKey('banner_project'),
                icon: const Icon(Icons.apartment, size: 22),
                label: const Text('Project'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  minimumSize: const Size(0, 44),
                  textStyle: theme.textTheme.titleMedium,
                ),
                onPressed: () => onSelect(AppTab.project.index),
              ),
              // THE WAY BACK OUT, beside the way in. Closing a job is the only
              // thing that returns this session to room mode, and it used to
              // be a button on the Project tab - which is to say, inside the
              // mode you were trying to leave.
              IconButton(
                key: const ValueKey('banner_project_close'),
                icon: const Icon(Icons.close, size: 18),
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                tooltip: 'Close the project and go back to the room',
                color: readableOn(
                  bannerFill,
                  prefer: [
                    theme.textTheme.bodySmall?.color ??
                        theme.colorScheme.onSurfaceVariant,
                    theme.colorScheme.onSurface,
                  ],
                  minRatio: kContrastLarge,
                ),
                onPressed: () => closeProjectFile(context, context.read<AppStateProvider>()),
              ),
              // AND THE ROOM'S OWN WAY OUT, on the pages that are about the
              // room. A job stays open behind it - closing means the room, not
              // everything on screen - so this is how somebody finishes with
              // one room of a building without putting the building away.
              if (onRoomTab && hasRoom)
                _BannerClose(
                  keyValue: 'banner_room_close',
                  tooltip: 'Close the room (the job stays open)',
                  fill: bannerFill,
                  icon: Icons.meeting_room_outlined,
                  onPressed: () => closeRoomFile(context, context.read<AppStateProvider>()),
                ),
              // ONE LEVEL UP FROM THE JOB. The campus is the same session in a
              // wider frame - this job and the others on one calendar - and it
              // is reached from here rather than only from a button inside the
              // Lifecycle pane, so the three levels read as three levels:
              // campus over project over room, each with its own way out.
              TextButton.icon(
                key: const ValueKey('banner_campus_open'),
                icon: const Icon(Icons.location_city, size: 18),
                label: const Text('Campus'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: readableOn(
                    bannerFill,
                    prefer: [
                      theme.textTheme.bodySmall?.color ??
                          theme.colorScheme.onSurfaceVariant,
                      theme.colorScheme.onSurface,
                    ],
                    minRatio: kContrastLarge,
                  ),
                ),
                onPressed: () => showCampusLifecycle(context),
              ),
              const SizedBox(width: 8),
            ] else if (hasRoom) ...[
              // A ROOM ON ITS OWN. Said, not offered: there is nothing to
              // press, because the only thing that could be pressed would be a
              // way into a job that does not exist. Starting one is New
              // Project in the title bar, and opening one is Open File - which
              // takes a project as readily as a room.
              // Sized to match the Project button opposite it, because the
              // two of them say the same kind of thing - which mode this
              // session is in - and a mode that is announced in small print
              // is one somebody reads only after getting it wrong.
              Chip(
                key: const ValueKey('banner_room'),
                avatar: const Icon(Icons.meeting_room_outlined, size: 22),
                label: Text('Room', style: theme.textTheme.titleMedium),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              // THE WAY OUT OF A ROOM, beside the way it is named - the same
              // place, and the same shape, as the job's own close one mode up.
              // A job could be closed and a room could only ever be swapped for
              // another, so the empty session this app starts on could not be
              // got back to without restarting it. See [closeRoomFile].
              _BannerClose(
                keyValue: 'banner_room_close',
                tooltip: 'Close the room and go back to the start screen',
                fill: bannerFill,
                onPressed: () => closeRoomFile(context, context.read<AppStateProvider>()),
              ),
              const SizedBox(width: 12),
            ],
            // Which job, and whether it is on disk. Flexible so a long job name
            // ellipsizes instead of pushing the gear off the end.
            //
            // Measured against the banner's own fill rather than taking the
            // page's ink: this strip is a container color, and in the Classic
            // theme container colors are tinted from an accent somebody picks
            // out of a wheel. The "unsaved" red gets the same check — the error
            // color is the one that fails first on a dark accent.
            // Expanded, not Flexible-plus-Spacer. Both are flex:1, so the two
            // of them SPLIT the free width — and because a Flexible is loose,
            // the half the short job name did not use was left over at the end
            // of the row, which is to say to the RIGHT of the gear. That is
            // how a corner button ends up sitting in the middle of the window.
            // One tight child that eats everything going puts it back in the
            // corner, and the name still ellipsizes when it is long.
            Expanded(
              child: Text(
                // The name of whatever this strip is about - see
                // [_bannerDocumentName].
                state.documentName,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: hasProject && state.projectDirty
                      // The banner is a fill, so the container answer — but
                      // held to the small-text bar, because "— unsaved" is
                      // the smallest and most important red on the page.
                      ? legibleTone(
                          errorOn(theme.colorScheme, bannerFill), bannerFill)
                      : readableOn(
                          bannerFill,
                          prefer: [
                            theme.textTheme.bodySmall?.color ??
                                theme.colorScheme.onSurfaceVariant,
                            theme.colorScheme.onSurface,
                          ],
                        ),
                ),
              ),
            ),
            // THE DOCUMENT'S BUTTONS, MEASURED AGAINST THE STRIP THEY SIT ON.
            //
            // Same reasoning as [_BannerClose] and the job name above it: this
            // row is a CONTAINER color, and in the Classic theme container
            // colors are tinted from an accent somebody picks out of a wheel.
            // Taking the page's own icon ink meant these were the one block on
            // the banner nobody had checked — a tinted fill can leave
            // onSurfaceVariant at 2:1 on the strip, which is a row of icons
            // you can find only by knowing where they are.
            //
            // Two wrappers because the group is not all one widget: the icon
            // buttons take the ink through [IconButtonTheme], and the export
            // menu's icon reads [IconTheme] directly. Both are handed the same
            // color, so which one wins does not matter.
            //
            // The disabled entry is that ink faded rather than the theme's own
            // disabled gray, for the same reason: Convert and the exports
            // spend most of a session grayed out, and "grayed out" should mean
            // a fainter version of the row's ink and not a color picked
            // against a surface this row is not.
            // WHO ELSE HAS THIS OPEN - a person icon with their Windows
            // sign-in name, and a Merge button when one of them has saved.
            // See collab/collab_widgets.dart.
            if (selectedIndex >= 0 && selectedIndex < AppTab.values.length)
              CollabPresenceStrip(tab: AppTab.values[selectedIndex]),
            IconButtonTheme(
              data: IconButtonThemeData(
                style: ButtonStyle(
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.disabled)
                        ? actionInk.withValues(alpha: 0.38)
                        : actionInk,
                  ),
                ),
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: actionInk),
                // A plain Row, so the group lays out exactly as the spread it
                // replaced: every one of these is a fixed-size button, and
                // none of them was ever flexible.
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the banner's close buttons, measured against the strip it sits on.
///
/// Its own widget because there are now three of them - the job's, the room's,
/// and the room's again on a job - and a close that was a different size or a
/// different ink on one of them would read as a different kind of action.
class _BannerClose extends StatelessWidget {
  final String keyValue;
  final String tooltip;
  final Color fill;
  final IconData icon;
  final VoidCallback onPressed;

  const _BannerClose({
    required this.keyValue,
    required this.tooltip,
    required this.fill,
    required this.onPressed,
    this.icon = Icons.close,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      key: ValueKey(keyValue),
      icon: Icon(icon, size: 18),
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      // The strip is a container color, and in the Classic theme container
      // colors are tinted from an accent somebody picks out of a wheel.
      color: readableOn(
        fill,
        prefer: [
          theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurfaceVariant,
          theme.colorScheme.onSurface,
        ],
        minRatio: kContrastLarge,
      ),
      onPressed: onPressed,
    );
  }
}

/// What the banner is about, in one line.
///
/// THE JOB IS NOT ALWAYS THE ANSWER. With a job open the strip named the job
/// and nothing else, on every tab - so a reader who opened a building and then
/// went to a room page was looking at a drawing with the BUILDING's name over
/// it. On a job whose rooms have never been drawn - the refresh imports, where
/// every room is a line item and there is no config anywhere - that page was a
/// room editor with nothing on it and nothing saying so.
///
/// So on a page that is about the room, the room is named too: the job first,
/// because that is the wider thing and it is what a reader checks they are
/// still inside of, then the room. A job with no room open says so out loud,
/// rather than leaving its own name standing over an empty page as though that
/// were the document on screen.
///
/// With no job it is the room alone, and on a cold start it is nothing at all -
/// naming a project that does not exist is how somebody ends up believing their
/// room is on one.
String _bannerDocumentName(
  AppStateProvider provider, {
  required bool hasProject,
  required bool hasRoom,
  required bool onRoomTab,
}) {
  if (!hasProject) return hasRoom ? _roomFileName(provider) : '';
  final job = provider.projectDirty
      ? '${provider.projectDisplayName} - unsaved'
      : provider.projectDisplayName;
  if (!onRoomTab) return job;
  final room = hasRoom ? _roomFileName(provider) : 'no room open';
  return '$job  \u00b7  $room';
}

/// What the banner calls the open room when there is no job to name.
///
/// THE ROOM'S NAME FIRST, THEN ITS FILE. The file alone answers "which
/// document am I looking at" and nothing else - and a folder full of rooms is
/// a folder full of files called config.json, so the one thing the line was
/// for is the one thing it could not do. The wizard's generated full room name
/// is what the room is CALLED ("Bessey Hall 103"), which is how somebody knows
/// at a glance which room this window is on; the file name stays after it,
/// because it is still the thing they will look for on disk.
///
/// The name is dropped when the wizard has not filled it in yet rather than
/// leaving a dangling separator, and on a room that has been created but never
/// saved there is no file to name - so it says so rather than going blank,
/// which would read as nothing being open.
String _roomFileName(AppStateProvider provider) {
  final file = provider.currentConfigPath;
  final String fileLabel =
      file.isEmpty ? 'Unsaved room' : file.split(Platform.pathSeparator).last;

  final setup = provider.roomConfig['SYSTEM_SETUP'];
  final String roomName =
      (setup is Map ? setup['gui_full_room_name']?.toString() : '')?.trim() ??
          '';
  if (roomName.isEmpty) return fileLabel;
  return '$roomName - $fileLabel';
}

/// The banner's fill while the session is on a ROOM rather than a job.
///
/// A tint of the theme's own tertiary over the strip's ordinary color, at an
/// alpha low enough to stay a background and high enough to be seen without
/// being looked for. Tertiary because it is the role this app already uses for
/// "a fact about this document" and the one least likely to be read as a
/// warning.
///
/// Its own function so the contrast test can measure what the banner paints
/// rather than a color written down twice.
Color roomModeBannerFill(ThemeData theme) => Color.alphaBlend(
      theme.colorScheme.tertiary.withValues(alpha: 0.14),
      theme.colorScheme.surfaceContainerHighest,
    );

// A quiet nudge that the file needed migrating, pointing at the Convert
/// button rather than opening it. The whole point of the change is that the
/// user decides when to deal with the conversion.
void _announceConversionAvailable(BuildContext context) {
  // Shown right after a load, and its CONVERT action opens a dialog over the
  // top of it — both of which are how a snack bar ends up stuck. See
  // showTimedSnackBar: it keeps a timer outside the widget tree so the notice
  // goes away regardless.
  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      duration: const Duration(seconds: 8),
      content: const Text(
        'This file needs converting to the current format. The changes are '
        'ready in memory - press Convert in the toolbar to review them.',
      ),
      action: SnackBarAction(
        label: 'CONVERT',
        onPressed: () {
          final provider = context.read<AppStateProvider>();
          _showMigrationLogDialog(context, provider.systemLogs);
        },
      ),
    ),
  );
}

/// Displays a scrollable log of actions taken to make an older config compatible
void _showMigrationLogDialog(BuildContext context, List<String> logs) {
  showDialog(
    context: context,
    builder: (ctx) {
      // Theme-aware palette: keep the dark terminal feel in dark mode, use a
      // bordered light panel with high-contrast text in light mode.
      final bool isDark = Theme.of(ctx).brightness == Brightness.dark;
      final Color panelColor = isDark ? Colors.black87 : const Color(0xFFF5F5F5);
      final Color normalText = isDark ? Colors.greenAccent : Colors.green.shade800;
      final Color headerText = isDark ? Colors.orangeAccent : Colors.deepOrange.shade700;
      final Color warnText = isDark ? Colors.redAccent.shade100 : Colors.red.shade700;

      // Severity color per line so warnings stand out in the acknowledgement
      Color lineColor(String line, bool isHeader) {
        if (line.startsWith('WARNING') ||
            line.startsWith('CRITICAL') ||
            line.startsWith('COUNT WARNING') ||
            line.startsWith('CONFLICT') ||
            line.startsWith('FLAGGED') ||
            line.contains('SKIPPED')) {
          return warnText;
        }
        return isHeader ? headerText : normalText;
      }

      return AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange),
            const SizedBox(width: 10),
            const Text('Legacy Config Updated'),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  "The loaded file was missing required fields for the current "
                  "template. The following defaults were injected into memory. "
                  "\"Use Original\" discards every change and edits the file "
                  "exactly as it is on disk:"),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: panelColor,
                    borderRadius: BorderRadius.circular(4),
                    border: isDark
                        ? null
                        : Border.all(color: Colors.grey.shade400), // Define the panel in light mode
                  ),
                  child: ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      bool isHeader = index == 0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6.0),
                        child: Text(
                          logs[index],
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: lineColor(logs[index], isHeader),
                            fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text("Note: These changes are currently only in memory. Save the config to make them permanent.", 
                style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12)),
            ],
          ),
        ),
        actions: [
          // The log above says WHAT changed; the preview shows the converted
          // config itself, colored by where each value came from, and lets
          // individual changes be rejected.
          if (ctx.read<AppStateProvider>().hasConversionPreview)
            TextButton.icon(
              icon: const Icon(Icons.compare_arrows, size: 18),
              label: const Text('Review Conversion'),
              onPressed: () async {
                final provider = ctx.read<AppStateProvider>();
                final applied =
                    await showConversionPreviewDialog(ctx, provider);
                // Choices are applied inside the preview; closing the
                // acknowledgement too avoids re-confirming the same load.
                if (applied == true) {
                  provider.acknowledgeConversion();
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  // The same question Acknowledge asks. Reading the conversion
                  // in detail must not be the path that skips it: the preview
                  // says what the CONVERSION did, and this says where what it
                  // did disagrees with the driver — which is exactly the
                  // question somebody who opened the preview is asking.
                  if (context.mounted) {
                    await offerModelDefaults(context, provider);
                  }
                }
              },
            ),
          // DENY: throw away the key-mapping/migration changes and reload the
          // file exactly as it sits on disk (the disk copy was never touched).
          TextButton(
            onPressed: () async {
              final provider = ctx.read<AppStateProvider>();
              final messenger = ScaffoldMessenger.of(context);
              final bool ok = await provider.revertToOriginalLoad();
              if (ctx.mounted) Navigator.of(ctx).pop();
              messenger.showSnackBar(SnackBar(
                content: Text(ok
                    ? 'Changes discarded - editing the original file as-is.'
                    : 'Could not reload the original file; the migrated '
                        'version stays loaded.'),
                backgroundColor: ok ? null : snackErrorFillOn(messenger),
              ));
            },
            child: const Text('Use Original (discard changes)'),
          ),
          ElevatedButton(
            onPressed: () async {
              // Acknowledging IS dealing with it: the changes stay, and the
              // toolbar stops flagging them.
              final provider = ctx.read<AppStateProvider>();
              provider.acknowledgeConversion();
              Navigator.of(ctx).pop();
              // ...and then the one question the conversion itself cannot
              // answer: the family defaults it filled in are right for the
              // family and wrong for the exceptions, and only the model's own
              // driver knows which this is.
              await offerModelDefaults(context, provider);
            },
            child: const Text('Acknowledge'),
          ),
        ],
      );
    },
  );
}

/// Swatch grid for a theme color. Used for the primary accent and the
/// secondary element color of both styles in App Config (and in the
/// first-run setup dialog); tapping a swatch persists it immediately and
/// the theme rebuilds live. With [allowAuto], an extra first swatch clears
/// the setting so the theme derives the color itself. The last swatch opens
/// the color wheel for anything off the grid.
class AccentColorPicker extends StatelessWidget {
  /// Which provider setting the picker writes: 'classicColor' |
  /// 'aurisColor' | 'classicSecondary' | 'estimateAccent'.
  final String settingKey;
  final List<Color> swatches;
  final bool allowAuto;
  final String autoLabel;

  /// Fills the auto swatch when auto stands for one known color.
  final Color? autoColor;

  const AccentColorPicker(
      {super.key,
      required this.settingKey,
      required this.swatches,
      this.allowAuto = false,
      this.autoLabel = 'Auto (theme default)',
      this.autoColor});

  String _currentHex(AppStateProvider p) {
    switch (settingKey) {
      case 'aurisColor':
        return p.aurisColor;
      case 'classicSecondary':
        return p.classicSecondary;
      case 'estimateAccent':
        return p.estimateAccent;
      default:
        return p.classicColor;
    }
  }

  static String _hexOf(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  Widget _swatch(BuildContext context,
      {required bool selected,
      required VoidCallback onTap,
      Color? color,
      Widget? child}) {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected
              ? Border.all(
                  color: Theme.of(context).colorScheme.onSurface, width: 3)
              : Border.all(color: Colors.black26),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final String hexNow = _currentHex(provider);
    final Color current = RoomConfigApp.parseHexColor(hexNow);

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        // AUTO: clear the setting so the theme derives this color itself
        if (allowAuto)
          Tooltip(
            message: autoLabel,
            child: _swatch(
              context,
              selected: hexNow.isEmpty,
              color: autoColor,
              onTap: () => provider.updateSetting(settingKey, ''),
              child: Icon(Icons.auto_fix_normal,
                  size: 18,
                  color: autoColor != null
                      ? readableOn(autoColor!)
                      : Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ...swatches.map((color) {
          final bool selected =
              hexNow.isNotEmpty && color.toARGB32() == current.toARGB32();
          return _swatch(
            context,
            selected: selected,
            color: color,
            onTap: () => provider.updateSetting(settingKey, _hexOf(color)),
            child: selected
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : null,
          );
        }),
        // WHEEL: any color. Filled with the current one when it is off-grid.
        Builder(builder: (context) {
          final bool custom = hexNow.isNotEmpty &&
              !swatches.any((c) => c.toARGB32() == current.toARGB32());
          return Tooltip(
            message: 'Pick from the color wheel',
            child: _swatch(
              context,
              selected: custom,
              color: custom ? current : null,
              onTap: () async {
                final picked = await showColorWheelDialog(context,
                    initial: hexNow.isEmpty
                        ? autoColor ?? swatches.first
                        : current,
                    title: 'Pick a color');
                if (picked != null) {
                  provider.updateSetting(settingKey, _hexOf(picked));
                }
              },
              child: Icon(Icons.palette_outlined,
                  size: 18,
                  color: custom
                      ? readableOn(current)
                      : Theme.of(context).colorScheme.onSurface),
            ),
          );
        }),
      ],
    );
  }
}

/// One Theme Style dropdown entry: a colored accent swatch + label.
DropdownMenuItem<String> _themeStyleItem(
    String value, String label, Color swatch) {
  return DropdownMenuItem<String>(
    value: value,
    child: Row(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: swatch, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(label),
      ],
    ),
  );
}

/// ============================================================================
///  SEARCHABLE ROOM / BUILDING PICKER
/// ============================================================================
///  One searchable dropdown over the rooms in processors.json, with the full
///  building name resolved from buildings.json — so 'AGYM 129' is found by
///  typing 'acker', 'AGYM', '129', or its IP address. Used everywhere a room
///  is selected: App Config (Active Deployment Target) and both the SFTP
///  Upload and Download dialogs.
/// ============================================================================
class ProcessorSearchField extends StatelessWidget {
  final String label;
  final String? helperText;
  final void Function(Map<String, dynamic> processor) onSelected;
  /// Room shown when the field opens (usually the Active Deployment Target).
  final Map<String, dynamic>? initialProcessor;
  final bool enabled;

  /// Fired the moment the user engages with the search — focusing it or typing
  /// in it — BEFORE any room is chosen. The SFTP dialog uses this to drop the
  /// connection details belonging to the outgoing room, so nothing stale is on
  /// screen while a new one is being picked. [onSelected] then supplies the
  /// replacement.
  final VoidCallback? onInteracted;

  const ProcessorSearchField({
    super.key,
    required this.label,
    required this.onSelected,
    this.helperText,
    this.initialProcessor,
    this.enabled = true,
    this.onInteracted,
  });

  /// IP/hostname of one processors.json entry (same fallbacks as the
  /// provider's selectedProcessorIp).
  static String ipOf(Map<String, dynamic> p) =>
      (p['ip'] ?? p['ipAddress'] ?? p['ip_address'] ?? p['address'] ?? p['host'] ?? '')
          .toString();

  /// Display line for one room: "AGYM 129 — Acker Gymnasium (10.248.129.8)".
  /// The building code is the first word of roomName; unknown codes just
  /// show the room name and IP.
  static String displayFor(AppStateProvider provider, Map<String, dynamic> p) {
    final String roomName = p['roomName']?.toString() ?? '';
    final String code = roomName.split(' ').first;
    final String fullName = provider.fullBuildingNameForCode(code);
    final String ip = ipOf(p);
    final String suffix = ip.isEmpty ? '' : ' ($ip)';
    return fullName.isEmpty
        ? '$roomName$suffix'
        : '$roomName - $fullName$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();

    // Display string -> processor entry, in processors.json order
    final Map<String, Map<String, dynamic>> byDisplay = {};
    for (final proc in provider.processors) {
      if (proc is Map) {
        final p = Map<String, dynamic>.from(proc);
        byDisplay[displayFor(provider, p)] = p;
      }
    }

    final String initialText = initialProcessor == null
        ? ''
        : displayFor(provider, Map<String, dynamic>.from(initialProcessor!));

    FocusNode? fieldFocus;
    return Autocomplete<String>(
      // Remount when the selection changes elsewhere (e.g. Clear button)
      // so initialValue re-applies; stable while typing.
      key: ValueKey('procsearch_${initialProcessor?['roomId']}_${byDisplay.length}'),
      initialValue: TextEditingValue(text: initialText),
      optionsBuilder: (TextEditingValue textEditingValue) {
        final String text = textEditingValue.text;
        // Show the FULL list while the field still holds the current
        // selection, otherwise it filters itself down to one entry.
        if (text.isEmpty || text == initialText) return byDisplay.keys;
        // Separator-insensitive: "BSS103", "BSS 103" and "bss-103" all find
        // the same room, and an IP can be typed with or without its dots.
        return searchFilter(byDisplay.keys, text);
      },
      onSelected: (String selection) {
        fieldFocus?.unfocus(); // Close the options overlay
        final p = byDisplay[selection];
        if (p != null) onSelected(p);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        fieldFocus = focusNode;
        return Focus(
          // Gaining focus counts as engaging with the search, so clicking into
          // the box is enough — the caller doesn't have to wait for a keystroke.
          onFocusChange: (hasFocus) {
            if (hasFocus) onInteracted?.call();
          },
          child: TextFormField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            decoration: InputDecoration(
              labelText: label,
              helperText: helperText,
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: enabled
                  ? ClearFieldButton(controller: controller)
                  : null,
            ),
            // Typing counts too, for anyone who tabs in or pastes.
            onChanged: (_) => onInteracted?.call(),
            // ENTER PICKS THE HIGHLIGHTED ROOM. Autocomplete hands the
            // field builder this callback and does nothing with the key
            // itself, so a custom fieldViewBuilder that drops it - as this
            // one did - leaves the list navigable by arrow key but only
            // selectable by mouse. Wiring it through means Enter chooses
            // the highlighted entry (the top match until the arrows move
            // it) and fires onSelected, which is what fills the IP and
            // password below.
            onFieldSubmitted: (_) => onFieldSubmitted(),
          ),
        );
      },
    );
  }
}

/// View for mapping application paths and selecting the active deployment room
/// HOW WIDE THE BUTTON ON THE END OF A PATH ROW IS, at the reader's own text
/// size.
///
/// Every file-path row on the settings tab is a field that stretches and a
/// button that does not, and the button used to be exactly as wide as its own
/// label. So 'Reload Rules' was narrower than 'Reload Catalog', the field
/// beside it was correspondingly longer, and five rows that are the same row
/// ended in five different places down the page - which reads as five
/// different kinds of row rather than one kind repeated.
///
/// One width, set from the longest label there is, puts every field on the
/// same right-hand edge and makes every button the same size.
///
/// A BOX THAT DOES NOT GROW IS A LABEL THAT GETS CUT. Fixed at 264 this was a
/// tidy column on the machine it was written on and 'Re-read Mod...' on a
/// display at 150%, where the type is half again as big and the box was not -
/// the one failure mode this app cares most about, because the people reading
/// these screens in meeting rooms are exactly the ones with their text turned
/// up. It is grown the way the type inside it is grown; see [gridMetric],
/// which is how every other fixed dimension in the app handles the same
/// question.
const double _kSettingsActionWidth = 280;
const double _kSettingsActionHeight = 56;

/// The button on the end of a path row, at the one size they all share.
///
/// The height tracks an [OutlineInputBorder] text field, so the button sits
/// square with the field rather than floating above its helper text.
Widget _settingsAction(BuildContext context, Widget button) => SizedBox(
      width: gridMetric(context, _kSettingsActionWidth),
      height: gridMetric(context, _kSettingsActionHeight),
      child: button,
    );

class AppSettingsView extends StatelessWidget {
  const AppSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();

    return ListView(
      padding: const EdgeInsets.all(32.0),
      children: [
        // A Wrap rather than a Row: the heading and the button together are
        // wider than a half-width window at 130% text, and a Row would run the
        // button off the edge behind the overflow stripes. Here it drops onto
        // its own line instead.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            Text('Application Configuration', style: Theme.of(context).textTheme.headlineMedium),
            // Re-opens the same dialog shown on the very first launch, for
            // fixing paths guided-style instead of field by field.
            OutlinedButton.icon(
              icon: const Icon(Icons.tune),
              label: const Text('Run First-Time Setup'),
              onPressed: () => showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const FirstRunSetupDialog(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // All settings on this tab persist to a plain JSON file that travels
        // with the app, replacing the old hidden OS preference store.
        Text(
          'Settings are saved automatically to ${provider.settingsFilePath}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 22),

        // --- ACTIVE DEPLOYMENT TARGET ---
        // First on the tab because it is the one setting that changes between
        // sessions: every path below is set once and forgotten, while this
        // picks which room the next upload or download talks to. At the
        // bottom its dropdown opened off the end of a long scrolling page,
        // which meant scrolling to find the field and scrolling again to see
        // what it offered.
        Text('Active Deployment Target',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ProcessorSearchField(
                label: 'Select Room Deployment',
                helperText:
                    'Search by building name, code, room number, or IP - '
                    'rooms from processors.json, names from buildings.json.',
                initialProcessor: provider.selectedProcessor,
                onSelected: (proc) => provider.selectProcessor(proc),
              ),
            ),
            const SizedBox(width: 16),
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Clear Active Room',
                onPressed: () => provider.selectProcessor(null),
              ),
            ),
          ],
        ),
        const Divider(height: 40),

        // --- PRICING ---
        // Currency and which of a catalog entry's two prices the estimates
        // cost from. Both are app-wide: a shop bills in one currency, and
        // whether a job is quoted at list or at education pricing is a
        // decision about the job, not about each device.
        Text('Pricing', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        // Wrap, not Row: three controls plus their explanation is more than a
        // narrow window has room for on one line, and this tab is read at
        // whatever width the app happens to be open at.
        Wrap(
          spacing: 16,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                initialValue: kCurrencySymbols.contains(provider.currencySymbol)
                    ? provider.currencySymbol
                    : null,
                // A dropdown sizes itself to its WIDEST item, not the selected
                // one, so without this the box wants the width of "New Zealand
                // dollar" and overflows whatever it is put in.
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Currency symbol',
                  helperText: 'Shown in front of every figure',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in kCurrencySymbols)
                    DropdownMenuItem(
                      value: c,
                      child: Text('$c   ${kCurrencyNames[c] ?? ''}'),
                    ),
                ],
                onChanged: (val) {
                  if (val != null) provider.updateSetting('currencySymbol', val);
                },
              ),
            ),
            // Anything not on the list — a currency code, a local symbol.
            SizedBox(
              width: 200,
              child: TextFormField(
                key: ValueKey('currencySymbol_${provider.currencySymbol}'),
                decoration: const InputDecoration(
                  labelText: 'Or type one',
                  helperText: 'Blank resets to \$',
                  border: OutlineInputBorder(),
                ),
                initialValue: provider.currencySymbol,
                onChanged: (val) =>
                    provider.updateSetting('currencySymbol', val),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Estimate prices',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                // Short labels: two full names side by side is wider than a
                // narrow window, and a SegmentedButton does not wrap.
                SegmentedButton<PricingTier>(
                  segments: [
                    for (final t in PricingTier.values)
                      ButtonSegment(
                        value: t,
                        label: Text(kPricingTierShort[t] ?? t.name),
                        tooltip: kPricingTierLabels[t],
                      ),
                  ],
                  selected: {provider.pricingTier},
                  onSelectionChanged: (s) => provider.setPricingTier(s.first),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Every catalog entry carries both prices. A price typed on a room '
          'still wins over either; a line the catalog can only price at the '
          'other tier is flagged on the estimate rather than quietly costed.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 40),

        // --- ESTIMATE PDF ---
        const EstimateSettingsSection(),
        const Divider(height: 40),

        // --- THEME STYLE ---
        // Two styles, each with its own accent swatch picker below:
        // Classic (flex_color_scheme, the default) and Auris (sci-fi HUD).
        // Dark/light stays on thsdae toolbar toggle.
        DropdownButtonFormField<String>(
          decoration: const InputDecoration(
            labelText: 'Theme Style',
            helperText:
                'Both styles use the accent color picked below. The sun/moon '
                'button still toggles dark & light.',
            border: OutlineInputBorder(),
          ),
          initialValue: provider.themeStyle,
          items: [
            _themeStyleItem('classic', 'Classic (Default)',
                RoomConfigApp.parseHexColor(provider.classicColor)),
            _themeStyleItem(
                'auris',
                'Auris (Sci-Fi)',
                RoomConfigApp.parseHexColor(provider.aurisColor,
                    fallback: const Color(0xFFF0A500))),
          ],
          onChanged: (val) {
            if (val != null) provider.updateSetting('themeStyle', val);
          },
        ),
        const SizedBox(height: 12),

        // --- ACCENT COLOR PICKER (swatches follow the selected style) ---
        Text(
            provider.themeStyle == 'auris'
                ? 'Auris Accent Color'
                : 'Classic Accent Color',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        provider.themeStyle == 'auris'
            ? const AccentColorPicker(
                settingKey: 'aurisColor',
                swatches: RoomConfigApp.aurisSwatches)
            : const AccentColorPicker(
                settingKey: 'classicColor',
                swatches: RoomConfigApp.classicSwatches),
        const SizedBox(height: 16),

        // --- SECONDARY ELEMENT COLOR (Classic only; Auto = theme-derived).
        // Auris bakes its own slate secondary, so it has no picker here.
        if (provider.themeStyle == 'classic') ...[
          Text('Classic Secondary Color (other elements)',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Colors highlights, chips, and toggles. Auto derives it from the accent color.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          const AccentColorPicker(
              settingKey: 'classicSecondary',
              swatches: RoomConfigApp.classicSwatches,
              allowAuto: true),
        ],
        const SizedBox(height: 20),

        // --- TEXT SIZE ---
        // App-wide text scale, applied via the MediaQuery text scaler that
        // wraps the MaterialApp. Persisted like every other setting.
        Builder(builder: (context) {
          const Map<String, String> sizes = {
            '0.85': 'Small (85%)',
            '1.0': 'Normal (100%)',
            '1.15': 'Large (115%)',
            '1.3': 'Extra Large (130%)',
            '1.5': 'Huge (150%)',
          };
          // Match the stored double back to an option key; null (no
          // selection shown) if it was hand-set to something unlisted.
          final String current = sizes.keys.firstWhere(
              (k) => double.parse(k) == provider.textScale,
              orElse: () => '');
          return DropdownButtonFormField<String>(
            decoration: const InputDecoration(
              labelText: 'Text Size',
              helperText: 'Scales all text in the app.',
              border: OutlineInputBorder(),
            ),
            initialValue: (current.isNotEmpty) ? current : null,
            items: sizes.entries
                .map((e) =>
                    DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (val) {
              if (val != null) provider.updateSetting('textScale', val);
            },
          );
        }),
        const SizedBox(height: 20),

        // --- DEVICE DEFAULTS ON LOAD ---
        // Load-time counterpart of ui_schema.json "device_defaults": also
        // fill missing baseline properties when opening an existing config.
        SwitchListTile(
          title: const Text('Fill missing device defaults when loading'),
          subtitle: const Text(
              'Adds properties from ui_schema.json "device_defaults" that a '
              'loaded config\'s devices are missing (e.g. DSP audio groups). '
              'Additions are listed in the load acknowledgement - nothing is '
              'saved until you export or apply.'),
          value: provider.fillDeviceDefaultsOnLoad,
          onChanged: (val) => provider.setFillDeviceDefaultsOnLoad(val),
        ),
        const SizedBox(height: 8),

        // --- DELETE CONFIRMATION ---
        // Gate for the trash buttons on the Devices/System tabs: off =
        // one-click removal with no dialog (Check Defaults restores mistakes).
        SwitchListTile(
          title: const Text('Confirm before deleting settings'),
          subtitle: const Text(
              'Ask before a trash button removes a property from the config '
              '(Devices & System tabs). Turn off for one-click deletes - '
              '"Check Defaults" can re-add anything removed by mistake.'),
          value: provider.confirmBeforeDelete,
          onChanged: (val) => provider.setConfirmBeforeDelete(val),
        ),
        const SizedBox(height: 20),

        // --- HOW DEEP A ROOM SCAN LOOKS ---
        // "Find rooms in a folder…" on the new-project screen walks down from
        // the folder it is pointed at. Two levels is what this app writes; a
        // site whose configs come off the processor keeps them further down
        // (BSS 101/code/upload_to_root/config.json is four), and there is no
        // depth that is right for both — too shallow finds nothing, too deep
        // starts returning archived copies as if they were rooms.
        Text('Finding rooms in a folder',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SizedBox(
          width: 320,
          child: DropdownButtonFormField<int>(
            key: const ValueKey('room_scan_depth'),
            initialValue: AppStateProvider.kRoomScanDepths
                    .contains(provider.roomScanDepth)
                ? provider.roomScanDepth
                : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'How deep to look for room configs',
              helperText:
                  'Sub-folders under the folder you point at. Raise it if '
                  'each room keeps its config further down (e.g. '
                  '101/code/upload_to_root); lower it if a scan comes back '
                  'with backup copies.',
              helperMaxLines: 4,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final d in AppStateProvider.kRoomScanDepths)
                DropdownMenuItem(
                  value: d,
                  child: Text(d == 1
                      ? 'The folder itself only'
                      : '$d folders down'),
                ),
            ],
            onChanged: (val) {
              if (val != null) provider.setRoomScanDepth(val);
            },
          ),
        ),
        const SizedBox(height: 20),

        // --- APP UPDATES ---
        // New versions come from the release folder on the file share. See
        // app_updates.dart; nothing installs until the user presses Update.
        Text('App Updates', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        UpdateSettingsSection(
          updater: appUpdater,
          pickFolder: () => FilePicker.getDirectoryPath(
            dialogTitle: 'Select the release folder',
          ),
        ),
        const SizedBox(height: 20),

        // --- AUTOSAVE ---
        // Recovery copies on a timer. Read the header comment on
        // AppStateProvider.writeAutosaveSnapshot for why this never writes
        // over the user's own files: an autosave that saved would make "close
        // without saving" impossible to honor, and would make the warning on
        // exit a lie.
        Text('Autosave', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SwitchListTile(
          key: const ValueKey('autosave_enabled'),
          title: const Text('Keep a recovery copy of unsaved work'),
          subtitle: const Text(
              'While a room or project has unsaved changes, the app keeps a '
              'working copy of it - config, drawings, racks, plans and '
              'estimate - in its own folder. Your files are never written to; '
              'saving is what does that, and a save deletes the copy. If the '
              'app closes without saving, the copy is offered back the next '
              'time that file is opened, with a list of every difference.'),
          value: provider.autosaveEnabled,
          onChanged: (val) => provider.setAutosaveEnabled(val),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<int>(
                key: const ValueKey('autosave_interval'),
                initialValue:
                    AppStateProvider.kAutosaveIntervals
                            .contains(provider.autosaveMinutes)
                        ? provider.autosaveMinutes
                        : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'How often',
                  helperText: 'Only writes when there is unsaved work',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final m in AppStateProvider.kAutosaveIntervals)
                    DropdownMenuItem(
                      value: m,
                      child: Text('Every $m minute${m == 1 ? '' : 's'}'),
                    ),
                ],
                onChanged: provider.autosaveEnabled
                    ? (val) {
                        if (val != null) provider.setAutosaveMinutes(val);
                      }
                    : null,
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.backup_outlined),
              label: const Text('Copy unsaved work now'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final folder =
                    await provider.writeAutosaveSnapshot(force: true);
                showTimedSnackBar(
                  messenger,
                  SnackBar(
                    duration: const Duration(seconds: 6),
                    content: Text(folder.isEmpty
                        ? (provider.lastAutosaveError.isEmpty
                            ? 'Everything is saved - there is nothing a '
                                'recovery copy would hold.'
                            : 'The recovery copy failed: '
                                '${provider.lastAutosaveError}')
                        : 'Recovery copy written to $folder'),
                    backgroundColor: provider.lastAutosaveError.isEmpty
                        ? null
                        : snackErrorFillOn(messenger),
                  ),
                );
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Open recovery folder'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final error = await provider.openAutosaveFolder();
                if (error != null) {
                  showTimedSnackBar(
                    messenger,
                    SnackBar(content: Text(error)),
                  );
                }
              },
            ),
            // Beside the recovery folder because they are the same question:
            // where does this app put the things it writes for itself. A log
            // somebody is asked to send in and cannot find is not a log.
            OutlinedButton.icon(
              icon: const Icon(Icons.article_outlined),
              label: const Text('Open log folder'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final error = await provider.openInDesktop(AppLogger.logFolder);
                if (error != null) {
                  showTimedSnackBar(
                    messenger,
                    SnackBar(content: Text(error)),
                  );
                }
              },
            ),
            // Reading them without leaving the app, and getting them to
            // whoever asked: search, Copy and Export. Crash dumps are binary
            // and are sent as they are, from the folder.
            LogViewerButton(config: configuratorLogViewerConfig()),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '${autosaveStatusLine(provider)}\n'
          'Recovery copies live in ${provider.autosaveFolder}, one folder '
          'per file, and each is deleted as soon as its document is saved.\n'
          'The error, info and migration logs, and any crash dumps, live in '
          '${AppLogger.logFolder}.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),

        // Python Modules Path
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                // Value in the key forces a refresh when the path is picked
                // via the dialog. The field-name prefix keeps the key unique
                // among this ListView's children: on a fresh install every
                // path is blank, so the bare value alone made four siblings
                // share a ValueKey('').
                key: ValueKey('modulesPath_${provider.modulesPath}'),
                decoration: InputDecoration(
                  labelText: 'Python Modules Path',
                  // Blank = the "devices" sub-folder of the Root Folder
                  hintText: provider.effectiveModulesPath,
                  helperText:
                      'Blank = "devices" sub-folder of the Root Folder. '
                      '${provider.availableModules.length} module'
                      '${provider.availableModules.length == 1 ? '' : 's'} '
                      'read. Drivers are parsed once, so re-read them after '
                      'editing one.',
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder),
                    tooltip: 'Select Directory',
                    onPressed: () async {
                      String? selectedDirectory =
                          await FilePicker.getDirectoryPath();
                      if (selectedDirectory != null) {
                        provider.updateSetting(
                            'modulesPath', selectedDirectory);
                      }
                    },
                  ),
                ),
                initialValue: provider.modulesPath,
                onChanged: (val) =>
                    provider.updateSetting('modulesPath', val),
              ),
            ),
            const SizedBox(width: 16),
            // A DRIVER EDITED WHILE THE APP IS OPEN is a driver the app does
            // not know about: every .py is parsed once and the answer kept.
            // This re-reads the folder and then puts the open config back to
            // the drivers as they are NOW - see [offerModuleRecheck].
            _settingsAction(
              context,
              ElevatedButton.icon(
                key: const ValueKey('reload_python_modules'),
                icon: const Icon(Icons.refresh),
                label: const Text('Re-read Modules'),
                onPressed: () => offerModuleRecheck(context, provider),
              ),
            ),
          ],
        ),
        // A DRIVER WITH NO DEVICE_INFO IS SILENT, NOT BROKEN: it loads, it
        // answers, and its models simply never reach the Model dropdown -
        // which reads as the app not supporting the product. This is where
        // that is seen and fixed; see device_info_editor.dart.
        //
        // ON ITS OWN LINE, not on the row above. Every path row on this tab
        // is one field and one button of one fixed width, so the fields all
        // end on the same edge - see settings_path_rows_test.dart. A second
        // button in that row pushes one field short of the column.
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('edit_device_info'),
            icon: const Icon(Icons.description),
            label: const Text('What each driver declares…'),
            onPressed: () => showDeviceInfoEditor(context),
          ),
        ),
        const SizedBox(height: 20),

        // Documentation Path (per-module PDF manuals)
        TextFormField(
          key: ValueKey('documentationPath_${provider.documentationPath}'),
          decoration: InputDecoration(
            labelText: 'Documentation Path (PDF manuals)',
            // Blank = the "documentation" sub-folder of the Root Folder
            hintText: provider.effectiveDocumentationPath,
            helperText: 'Blank = "documentation" sub-folder of the Root Folder. '
                'Each manual is named after its python module, e.g. extr_dsp_DMP_64_Plus_Series.pdf',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.folder),
              tooltip: 'Select Directory',
              onPressed: () async {
                String? selectedDirectory = await FilePicker.getDirectoryPath();
                if (selectedDirectory != null) {
                  provider.updateSetting('documentationPath', selectedDirectory);
                }
              },
            ),
          ),
          initialValue: provider.documentationPath,
          onChanged: (val) => provider.updateSetting('documentationPath', val),
        ),
        const SizedBox(height: 20),

        // SPEC SHEETS - one shared folder, so a sheet attached to a catalog
        // entry on one machine opens on every other. See spec_sheets.dart.
        TextFormField(
          key: ValueKey('specSheetFolder_${provider.specSheetFolder}'),
          decoration: InputDecoration(
            labelText: 'Spec Sheet Folder (shared)',
            hintText: provider.effectiveSpecSheetFolder,
            helperText: 'Blank = "spec_sheets" sub-folder of the Root Folder. '
                'Point it at a shared folder: the Catalog tab files each sheet '
                'as <maker>/<model>.pdf and stores the name relative to here.',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.folder_shared),
              tooltip: 'Select Directory',
              onPressed: () async {
                final dir = await FilePicker.getDirectoryPath();
                if (dir != null) provider.updateSetting('specSheetFolder', dir);
              },
            ),
          ),
          initialValue: provider.specSheetFolder,
          onChanged: (val) => provider.updateSetting('specSheetFolder', val),
        ),
        const SizedBox(height: 20),

        // EDITING TOGETHER - see collab/collab_controller.dart.
        SwitchListTile(
          key: const ValueKey('collab_enabled_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show who else is editing a shared file'),
          subtitle: Text(
            'While a room, project or the catalog is open, a small note in a '
            '".editing" folder beside it tells other copies of the app you '
            'have it open (as ${provider.collab.me.user}). Their names appear '
            'on the banner, and when one of them saves you are offered their '
            'changes to merge - Save merges them too.',
          ),
          value: provider.collabEnabled,
          onChanged: provider.setCollabEnabled,
        ),
        const SizedBox(height: 20),

        // GOOGLE SHEETS - see google_sheets_export.dart.
        Text('Google Sheets', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Optional. With a Google Cloud OAuth client of type "Desktop app" '
          '(and the Google Drive API enabled on its project), Export > Upload '
          'workbook to Google Sheets puts the workbook straight into your '
          'Drive as a Sheet. Without one, the export saves the .xlsx and opens '
          'Google Sheets for you to upload it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('googleClientId_field'),
          decoration: const InputDecoration(
            labelText: 'Google OAuth client ID',
            border: OutlineInputBorder(),
          ),
          initialValue: provider.googleClientId,
          onChanged: (val) => provider.updateSetting('googleClientId', val),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('googleClientSecret_field'),
          decoration: const InputDecoration(
            labelText: 'Google OAuth client secret',
            helperText: 'Desktop-app clients are issued one; it is not a '
                'password and is stored with the other settings.',
            border: OutlineInputBorder(),
          ),
          initialValue: provider.googleClientSecret,
          onChanged: (val) => provider.updateSetting('googleClientSecret', val),
        ),
        const SizedBox(height: 20),

        // Buildings JSON Path
        TextFormField(
          key: ValueKey('buildingsFilePath_${provider.buildingsFilePath}'),
          decoration: InputDecoration(
            labelText: 'Buildings JSON File Path',
            // Blank = buildings.json in the Root Folder
            hintText: provider.effectiveBuildingsFilePath,
            helperText: 'Blank = buildings.json in the Root Folder',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.file_open),
              tooltip: 'Select JSON File',
              onPressed: () async {
                FilePickerResult? result = await FilePicker.pickFiles(
                  type: FileType.custom, 
                  allowedExtensions: ['json']
                );
                if (result != null) {
                  // updateSetting reloads the buildings list itself
                  provider.updateSetting('buildingsFilePath', result.files.single.path!);
                }
              },
            ),
          ),
          initialValue: provider.buildingsFilePath,
          // updateSetting reloads the buildings list itself
          onChanged: (val) => provider.updateSetting('buildingsFilePath', val),
        ),
        const SizedBox(height: 20),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Default config.json Template Path
            Expanded(
              child: TextFormField(
                key: ValueKey('templateFilePath_${provider.templateFilePath}'),
                decoration: InputDecoration(
                  labelText: 'Default config.json Template Path',
                  // Blank = config.json in the Root Folder
                  hintText: provider.effectiveTemplateFilePath,
                  helperText: 'Blank = config.json in the Root Folder',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.file_open),
                    tooltip: 'Select JSON File',
                    onPressed: () async {
                      FilePickerResult? result = await FilePicker.pickFiles(
                        type: FileType.custom, 
                        allowedExtensions: ['json']
                      );
                      if (result != null) {
                        provider.updateSetting('templateFilePath', result.files.single.path!);
                      }
                    },
                  ),
                ),
                initialValue: provider.templateFilePath,
                onChanged: (val) => provider.updateSetting('templateFilePath', val),
              ),
            ),
            const SizedBox(width: 16),
            _settingsAction(
              context,
              ElevatedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text('Load Template'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white, // FIX: label/icon were unreadable in light mode
                ),
                onPressed: () async {
                  // Validates & registers the template only. The file is not
                  // opened into the editor until 'Create New Config' is pressed.
                  // A blank field validates the default: config.json in the
                  // Root Folder / working directory.
                  bool valid = await provider
                      .validateConfigTemplate(provider.effectiveTemplateFilePath);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(valid
                          ? 'Template validated & saved as default. Use "Create New Config" to start from it.'
                          : 'No valid template at ${provider.effectiveTemplateFilePath} (missing or invalid JSON).'),
                      backgroundColor: valid ? Colors.green : Colors.red,
                    ));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // UI Schema (GUI field definitions) Path
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey('uiSchemaPath_${provider.uiSchemaPath}'),
                decoration: InputDecoration(
                  labelText: 'UI Schema File Path (ui_schema.json)',
                  hintText: 'Blank = ui_schema.json in the Root Folder / next to the app',
                  helperText: 'Active schema: ${provider.uiSchema.source} - ${provider.uiSchema.fieldCount} field definitions',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.file_open),
                    tooltip: 'Select JSON File',
                    onPressed: () async {
                      FilePickerResult? result = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                      );
                      if (result != null) {
                        provider.updateSetting('uiSchemaPath', result.files.single.path!);
                      }
                    },
                  ),
                ),
                initialValue: provider.uiSchemaPath,
                onChanged: (val) => provider.updateSetting('uiSchemaPath', val),
              ),
            ),
            const SizedBox(width: 16),
            _settingsAction(
              context,
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reload Schema'),
                onPressed: () async {
                  // Pull in edits made to ui_schema.json without restarting
                  await provider.loadUiSchema();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Schema reloaded: ${provider.uiSchema.source} '
                          '(${provider.uiSchema.fieldCount} field definitions)'),
                    ));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Device Catalog (av_devices.json) Path
        //
        // The one worth pointing at a SHARE: the catalog is the department's
        // price list, and a save merges another editor's changes rather than
        // overwriting them, so several people can keep it up to date at once.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(
                    'avDevicesFilePath_${provider.avDevicesFilePath}'),
                decoration: InputDecoration(
                  labelText: 'Device Catalog File Path (av_devices.json)',
                  hintText:
                      'Blank = av_devices.json in the Root Folder / next to the app',
                  helperText:
                      'Active catalog: ${provider.avDeviceLibrary.source} - '
                      '${provider.avDeviceLibrary.customCount} priced entries. '
                      'Put it on a shared drive to keep one price list for '
                      'everybody; saves merge rather than overwrite.',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.file_open),
                    tooltip: 'Select JSON File',
                    onPressed: () async {
                      FilePickerResult? result = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                      );
                      if (result != null) {
                        provider.updateSetting(
                            'avDevicesFilePath', result.files.single.path!);
                      }
                    },
                  ),
                ),
                initialValue: provider.avDevicesFilePath,
                onChanged: (val) =>
                    provider.updateSetting('avDevicesFilePath', val),
              ),
            ),
            const SizedBox(width: 16),
            _settingsAction(
              context,
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reload Catalog'),
                onPressed: () async {
                  // Pick up what a colleague has saved to the share since
                  // this copy read it — and reset the baseline a merge
                  // measures against, so the next save is weighed against
                  // what is actually in the file now.
                  await provider.loadAvDeviceLibrary();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          'Catalog reloaded: ${provider.avDeviceLibrary.source} '
                          '(${provider.avDeviceLibrary.customCount} entries)'),
                    ));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // AV Flow Rules (av_flow_rules.json) Path
        //
        // Worth pointing at the same share as the catalog, and for the same
        // reason: the rules are a description of how this shop builds rooms —
        // which box a config key means, what goes between two ends that do not
        // take the same cable, what hangs off the USB switcher — and two
        // engineers drawing the same room should draw it the same way.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(
                    'flowRulesFilePath_${provider.flowRulesFilePath}'),
                decoration: InputDecoration(
                  labelText: 'AV Flow Rules File Path (av_flow_rules.json)',
                  hintText:
                      'Blank = av_flow_rules.json in the Root Folder / next to '
                      'the app',
                  helperText:
                      'Active rules: ${provider.flowRules.source}. Edited on '
                      'the Flow Rules tab; with no file at all the app draws '
                      'with its built-in rules.',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.file_open),
                    tooltip: 'Select JSON File',
                    onPressed: () async {
                      FilePickerResult? result = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                      );
                      if (result != null) {
                        provider.updateSetting(
                            'flowRulesFilePath', result.files.single.path!);
                      }
                    },
                  ),
                ),
                initialValue: provider.flowRulesFilePath,
                onChanged: (val) =>
                    provider.updateSetting('flowRulesFilePath', val),
              ),
            ),
            const SizedBox(width: 16),
            _settingsAction(
              context,
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reload Rules'),
                onPressed: () async {
                  await provider.loadFlowRules();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          'Flow rules reloaded: ${provider.flowRules.source}'),
                    ));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Delivery Locations (delivery_locations.json) Path
        //
        // The docks kit is dropped at and the rooms gear is held in.
        // Worth pointing at the same share as the catalog, and for the same
        // reason: a loading dock is a fact about the estate, and one list of
        // names is what makes "everything at Central Stores" a question a job
        // can answer.
        Text('Delivery locations',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Set the places up once and every delivery on every job can be '
          'filed against one of them in a click, instead of the same dock '
          'being typed four ways. A delivery can still be logged somewhere '
          'that is not on the list.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(
                    'deliveryLocationsFilePath_${provider.deliveryLocationsFilePath}'),
                decoration: InputDecoration(
                  labelText:
                      'Delivery Locations File Path (delivery_locations.json)',
                  hintText:
                      'Blank = delivery_locations.json in the Root Folder / '
                      'next to the app',
                  helperText:
                      'Active list: ${provider.deliveryLocations.source.isEmpty ? 'none' : provider.deliveryLocations.source} - '
                      '${provider.deliveryLocations.count} place'
                      '${provider.deliveryLocations.count == 1 ? '' : 's'}. '
                      'Put it on a shared drive to give the whole shop one set '
                      'of names.',
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  // RE-READING THE FILE IS A FIELD ACTION, so it lives on the
                  // field beside the button that picks the file, rather than
                  // as a second button on the end of the row. That is what
                  // keeps this row on the same grid as every other path row -
                  // see [_kSettingsActionWidth].
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Re-read the file',
                        onPressed: () async {
                          // Pick up what a colleague has saved to the share
                          // since this copy read it.
                          await provider.loadDeliveryLocations();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('Delivery locations reloaded: '
                                  '${provider.deliveryLocations.count} places'),
                            ));
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.file_open),
                        tooltip: 'Select JSON File',
                        onPressed: () async {
                          FilePickerResult? result =
                              await FilePicker.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: ['json'],
                          );
                          if (result != null) {
                            provider.updateSetting('deliveryLocationsFilePath',
                                result.files.single.path!);
                          }
                        },
                      ),
                    ],
                  ),
                ),
                initialValue: provider.deliveryLocationsFilePath,
                onChanged: (val) =>
                    provider.updateSetting('deliveryLocationsFilePath', val),
              ),
            ),
            const SizedBox(width: 16),
            _settingsAction(
              context,
              ElevatedButton.icon(
                key: const ValueKey('edit_delivery_locations'),
                icon: const Icon(Icons.warehouse_outlined),
                label: const Text('Edit Locations'),
                onPressed: () => showDeliveryLocationsDialog(context),
              ),
            ),
          ],
        ),
        // Default Vendors (vendor_list.json) Path
        //
        // Who the shop asks to quote. Same reason to share it as the delivery
        // locations: the spelling of a company name and the rep behind it are
        // facts about the department, and one directory is what keeps three
        // jobs from comparing quotes from three different 'Extron's.
        Text('Default vendors', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Set the companies up once and every new job starts with them on '
          'its Packages tab, instead of the same directory being retyped per '
          'building. A job can still add, rename or drop any vendor it likes.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(
                    'vendorListFilePath_${provider.vendorListFilePath}'),
                decoration: InputDecoration(
                  labelText: 'Default Vendor List File Path (vendor_list.json)',
                  hintText:
                      'Blank = vendor_list.json in the Root Folder / next to '
                      'the app',
                  helperText:
                      'Active list: ${provider.vendorBook.source.isEmpty ? 'none' : provider.vendorBook.source} - '
                      '${provider.vendorBook.count} vendor'
                      '${provider.vendorBook.count == 1 ? '' : 's'}. '
                      'Put it on a shared drive to give the whole shop one '
                      'directory.',
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  // Re-reading the file is a field action - see the delivery
                  // locations row above.
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Re-read the file',
                        onPressed: () async {
                          // Pick up what a colleague has saved to the share
                          // since this copy read it.
                          await provider.loadVendorBook();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('Default vendors reloaded: '
                                  '${provider.vendorBook.count} vendors'),
                            ));
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.file_open),
                        tooltip: 'Select JSON File',
                        onPressed: () async {
                          FilePickerResult? result =
                              await FilePicker.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: ['json'],
                          );
                          if (result != null) {
                            provider.updateSetting('vendorListFilePath',
                                result.files.single.path!);
                          }
                        },
                      ),
                    ],
                  ),
                ),
                initialValue: provider.vendorListFilePath,
                onChanged: (val) =>
                    provider.updateSetting('vendorListFilePath', val),
              ),
            ),
            const SizedBox(width: 16),
            _settingsAction(
              context,
              ElevatedButton.icon(
                key: const ValueKey('edit_default_vendors'),
                icon: const Icon(Icons.store_outlined),
                label: const Text('Edit Vendors'),
                onPressed: () => showVendorBookDialog(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        const SizedBox(height: 20),

        // Legacy Key Map (key_map.json) Path
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey('keyMapPath_${provider.keyMapPath}'),
                decoration: InputDecoration(
                  labelText: 'Legacy Key Map File Path (key_map.json)',
                  hintText: 'Blank = key_map.json in the Root Folder / next to the app',
                  helperText: 'Active map: ${provider.keyMap.source} - ${provider.keyMap.ruleCount} rules. '
                      'Applied automatically when a config is loaded.',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.file_open),
                    tooltip: 'Select JSON File',
                    onPressed: () async {
                      FilePickerResult? result = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                      );
                      if (result != null) {
                        provider.updateSetting('keyMapPath', result.files.single.path!);
                      }
                    },
                  ),
                ),
                initialValue: provider.keyMapPath,
                onChanged: (val) => provider.updateSetting('keyMapPath', val),
              ),
            ),
            const SizedBox(width: 16),
            _settingsAction(
              context,
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reload Key Map'),
                onPressed: () async {
                  // Pull in edits made to key_map.json without restarting
                  await provider.loadKeyMap();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Key map reloaded: ${provider.keyMap.source} '
                          '(${provider.keyMap.ruleCount} rules)'),
                    ));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Processors JSON Path
        TextFormField(
          key: ValueKey('processorsFilePath_${provider.processorsFilePath}'),
          decoration: InputDecoration(
            labelText: 'Processors JSON File Path',
            // Blank = processors.json in the Root Folder; read automatically on boot
            hintText: provider.effectiveProcessorsFilePath,
            helperText: 'Blank = processors.json in the Root Folder. Read automatically on startup.',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.file_open),
              tooltip: 'Select JSON File',
              onPressed: () async {
                FilePickerResult? result = await FilePicker.pickFiles(
                  type: FileType.custom, 
                  allowedExtensions: ['json']
                );
                if (result != null) {
                  // updateSetting reloads the processors list itself
                  provider.updateSetting('processorsFilePath', result.files.single.path!);
                }
              },
            ),
          ),
          initialValue: provider.processorsFilePath,
          // updateSetting reloads the processors list itself
          onChanged: (val) => provider.updateSetting('processorsFilePath', val),
        ),
        const SizedBox(height: 20),
        
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.sync),
            label: const Text('Load Processors Data'),
            onPressed: () => provider.loadProcessorsList(),
          ),
        ),
        const SizedBox(height: 20),

        // Template Root Path
        TextFormField(
          key: ValueKey('rootFolderPath_${provider.rootFolderPath}'),
          decoration: InputDecoration(
            labelText: 'Root Folder Path (default base for all blank paths above)',
            hintText: provider.effectiveRootFolder,
            helperText: 'Blank = the app\'s working directory. Blank paths above default to files in this folder '
                '(config.json, processors.json, buildings.json, ui_schema.json, key_map.json, and the "devices" modules sub-folder).',
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.folder),
              tooltip: 'Select Directory',
              onPressed: () async {
                String? selectedDirectory = await FilePicker.getDirectoryPath();
                if (selectedDirectory != null) {
                  provider.updateSetting('rootFolderPath', selectedDirectory);
                }
              },
            ),
          ),
          initialValue: provider.rootFolderPath,
          onChanged: (val) => provider.updateSetting('rootFolderPath', val),
        ),
        const SizedBox(height: 20),

        Text('Processor Connection', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
            'SFTP settings used for every processor transfer. The defaults are '
            'the Extron standards - only change them for nonstandard hardware.'),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                decoration: const InputDecoration(
                  labelText: 'SFTP Username',
                  helperText: 'Default: admin',
                  border: OutlineInputBorder(),
                ),
                initialValue: provider.sftpUsername,
                onChanged: (val) => provider.updateSetting('sftpUsername', val),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                decoration: const InputDecoration(
                  labelText: 'SFTP Port',
                  helperText: 'Default: 22022 (Extron secure file transfer)',
                  border: OutlineInputBorder(),
                ),
                initialValue: provider.sftpPort,
                keyboardType: TextInputType.number,
                onChanged: (val) => provider.updateSetting('sftpPort', val),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Remote config path',
                  helperText: 'Default: /config.json',
                  border: OutlineInputBorder(),
                ),
                initialValue: provider.sftpRemoteConfigPath,
                onChanged: (val) =>
                    provider.updateSetting('sftpRemoteConfigPath', val),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // --- DEFAULT PROCESSOR PASSWORD (opt-in) ---
        // Rooms are typically all on one standard admin credential, so the
        // password is the only thing retyped on every transfer. Unlike every
        // other value on this tab it never reaches app_config.json — it goes to
        // the OS keystore (DPAPI on Windows), encrypted for the logged-in
        // account. Still opt-in: storing a credential at all is the user's call.
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: provider.useDefaultProcessorPassword,
          onChanged: (val) => provider.setUseDefaultProcessorPassword(val),
          title: const Text('Autofill the processor password'),
          subtitle: const Text(
              'Pre-fills the password in the SFTP upload/download dialogs. '
              'Kept in the Windows credential store, not in app_config.json - '
              'turning this off deletes it again.'),
        ),
        if (provider.useDefaultProcessorPassword) ...[
          const SizedBox(height: 8),
          _DefaultPasswordField(provider: provider),
        ],
        const SizedBox(height: 30),

      ],
    );
  }
}

/// The saved processor password field on App Config.
///
/// Stateful only for the show/hide eye: the value itself lives in the provider.
/// Obscured by default so it isn't sitting readable on a settings tab that gets
/// screen-shared, with a reveal for checking a typo.
class _DefaultPasswordField extends StatefulWidget {
  final AppStateProvider provider;
  const _DefaultPasswordField({required this.provider});

  @override
  State<_DefaultPasswordField> createState() => _DefaultPasswordFieldState();
}

class _DefaultPasswordFieldState extends State<_DefaultPasswordField> {
  bool _visible = false;

  /// Set when the keystore refused the write, so a password that did NOT get
  /// saved never looks like it did.
  bool _saveFailed = false;

  Future<void> _save(String value) async {
    final ok = await widget.provider.setDefaultProcessorPassword(value);
    if (mounted && ok == _saveFailed) setState(() => _saveFailed = !ok);
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: widget.provider.defaultProcessorPassword,
      obscureText: !_visible,
      decoration: InputDecoration(
        labelText: 'Default Processor Password',
        helperText: _saveFailed
            ? 'Could not save to the Windows credential store - the password '
                'is in use for this session only.'
            : 'Stored in the Windows credential store, encrypted for your user '
                'account - never in app_config.json.',
        helperMaxLines: 2,
        helperStyle:
            _saveFailed ? TextStyle(color: Colors.red.shade400) : null,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
          tooltip: _visible ? 'Hide' : 'Show',
          onPressed: () => setState(() => _visible = !_visible),
        ),
      ),
      onChanged: _save,
    );
  }
}

/// A dialog that handles both SFTP directions with the processor:
///  - Upload:   pushes the in-memory config to /config.json on the processor
///  - Download: pulls /config.json, backs it up, prompts for a new working file
/// The IP is pre-filled from the Active Deployment Target (App Config tab);
/// when no room is selected, the user is prompted for it as before.
class ProcessorSftpDialog extends StatefulWidget {
  final bool isUpload;
  const ProcessorSftpDialog({super.key, required this.isUpload});

  @override
  State<ProcessorSftpDialog> createState() => _ProcessorSftpDialogState();
}

class _ProcessorSftpDialogState extends State<ProcessorSftpDialog> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  
  String _statusText = '';
  bool _isBusy = false;
  String _targetRoomName = '';

  /// Room chosen in this dialog's searchable picker (pre-filled from the
  /// Active Deployment Target). Feeds the IP field and backup naming.
  Map<String, dynamic>? _selectedProcessor;

  /// Optional additional file to push alongside config.json (upload mode
  /// only). Stays blank unless the user picks one — e.g. Whereused.csv.
  String _extraFilePath = '';

  /// Pending auto-close of a successful upload. Held so [dispose] can cancel
  /// it — a timer that fires after the dialog is gone is what turned a late
  /// Cancel into a black window.
  Timer? _autoCloseTimer;

  @override
  void initState() {
    super.initState();
    // Pre-fill from the Active Deployment Target if one is selected
    final provider = context.read<AppStateProvider>();
    final ip = provider.selectedProcessorIp;
    if (ip.isNotEmpty) {
      _ipController.text = ip;
      _selectedProcessor = provider.selectedProcessor;
      _targetRoomName = provider.selectedProcessor?['roomName']?.toString() ?? '';
    }
    // Saved default password, when App Config has one and the toggle is on.
    _passController.text = provider.autofillProcessorPassword;
    _statusText = widget.isUpload
        ? 'Enter processor details to upload config.json'
        : 'Enter processor details to download config.json';
  }

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    _ipController.dispose();
    _passController.dispose();
    super.dispose();
  }

  /// Called as soon as the room search is touched (focus or a keystroke).
  ///
  /// The IP is cleared the moment the search is in play, so the field can never
  /// sit showing the previous room's address while a different one is being
  /// picked — that stale pairing is how a transfer ends up at the wrong
  /// processor. It's filled back in by [_applyTarget] when a room is actually
  /// selected. Typing an IP by hand still works: this only fires from the
  /// search box.
  void _clearTargetForSearch() {
    if (_ipController.text.isEmpty && _targetRoomName.isEmpty) return;
    setState(() {
      _ipController.clear();
      _targetRoomName = '';
      _selectedProcessor = null;
      _statusText = 'Pick a room to fill in its IP.';
    });
    context.read<AppStateProvider>().selectProcessor(null);
  }

  /// A room was picked: fill the IP in and make it the Active Deployment
  /// Target. The password is left as it stands — either the App Config default
  /// or whatever was typed — since it's the same admin credential room to room.
  void _applyTarget(Map<String, dynamic> proc) {
    setState(() {
      _selectedProcessor = proc;
      _ipController.text = ProcessorSearchField.ipOf(proc);
      _targetRoomName = proc['roomName']?.toString() ?? '';
      _statusText = 'Target set to $_targetRoomName.';
    });
    context.read<AppStateProvider>().selectProcessor(proc);
  }

  Future<void> _startTransfer() async {
    // Basic validation
    if (_ipController.text.isEmpty || _passController.text.isEmpty) {
      setState(() => _statusText = "Error: IP and Password are required.");
      return;
    }

    setState(() {
      _isBusy = true;
      _statusText = "Initializing...";
    });

    final provider = context.read<AppStateProvider>();
    
    bool success;
    if (widget.isUpload) {
      success = await provider.uploadConfigToProcessor(
        ipAddress: _ipController.text.trim(),
        password: _passController.text,
        onStatusUpdate: (status) => setState(() => _statusText = status),
        // Blank = upload only config.json (the default behavior)
        extraFilePath: _extraFilePath.isNotEmpty ? _extraFilePath : null,
      );
    } else {
      success = await provider.downloadConfigFromProcessor(
        ipAddress: _ipController.text.trim(),
        password: _passController.text,
        onStatusUpdate: (status) {
          if (mounted) setState(() => _statusText = status);
        },
      );
    }

    if (!mounted) return;
    setState(() => _isBusy = false);

    if (success) {
      if (widget.isUpload) {
        scheduleUploadAutoClose();
      } else {
        // Close immediately and signal success so the audit dialog can be shown
        Navigator.of(context).pop(true);
      }
    }
  }

  /// Leaves the upload's success message up for a moment, then closes.
  ///
  /// The delay races the Cancel button, which is live again now that _isBusy is
  /// false. Cancel pops this dialog, but the State stays mounted until the
  /// route finishes its exit animation — so a Cancel in the last fraction of
  /// the wait used to find `mounted` still true here and pop a SECOND time,
  /// taking the route UNDERNEATH the dialog with it. That left an empty
  /// navigator: the black window.
  ///
  /// Hence both guards: a timer [dispose] can cancel, and a check that the
  /// thing being popped is still this dialog.
  @visibleForTesting
  void scheduleUploadAutoClose() {
    final route = ModalRoute.of(context);
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (route == null || !route.isCurrent) return; // already dismissed
      Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isUpload ? 'Direct SFTP Upload' : 'Download Config from Processor'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_targetRoomName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Text(
                  'Active Deployment Target: $_targetRoomName',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),

            // --- SEARCHABLE ROOM PICKER ---
            // Same searchable building/room dropdown as App Config: rooms
            // from processors.json, full building names from buildings.json.
            // Selecting a room fills the IP below and becomes the Active
            // Deployment Target (drives backup naming on download). Typing
            // an IP manually still works exactly as before.
            ProcessorSearchField(
              label: 'Search Room / Building',
              helperText: 'Search by building name, code, room number, or IP.',
              initialProcessor: _selectedProcessor,
              enabled: !_isBusy,
              onInteracted: _clearTargetForSearch,
              onSelected: _applyTarget,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'Processor IP / Hostname',
                border: OutlineInputBorder(),
              ),
              enabled: !_isBusy,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Admin Password',
                border: OutlineInputBorder(),
              ),
              enabled: !_isBusy,
            ),

            // --- ADDITIONAL FILE (upload only, optional) ---
            // Leave blank to upload just config.json. Typically used to push
            // a Whereused.csv along with the config in one connection.
            if (widget.isUpload) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade600),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Additional File (optional)',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      _extraFilePath.isEmpty
                          ? 'None selected - only config.json will be uploaded.'
                          : 'Will also upload: ${_extraFilePath.split(Platform.pathSeparator).last}',
                      style: TextStyle(
                        fontSize: 12,
                        color: _extraFilePath.isEmpty ? Colors.grey : null,
                        fontStyle: _extraFilePath.isEmpty ? FontStyle.italic : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.attach_file, size: 18),
                          label: Text(_extraFilePath.isEmpty ? 'Add File' : 'Change File'),
                          onPressed: _isBusy
                              ? null
                              : () async {
                                  // Any file type: Whereused.csv is typical,
                                  // but module .py files etc. work too.
                                  final result = await FilePicker.pickFiles();
                                  if (result != null && mounted) {
                                    setState(() => _extraFilePath =
                                        result.files.single.path ?? '');
                                  }
                                },
                        ),
                        if (_extraFilePath.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          TextButton.icon(
                            icon: const Icon(Icons.clear, size: 18),
                            label: const Text('Clear'),
                            onPressed: _isBusy
                                ? null
                                : () => setState(() => _extraFilePath = ''),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            
            // Status read-out container (contrast-safe in both themes)
            Builder(builder: (context) {
              final bool isDark = Theme.of(context).brightness == Brightness.dark;
              final Color boxColor = isDark ? Colors.black26 : const Color(0xFFF0F0F0);
              final TextStyle statusStyle = TextStyle(
                fontFamily: 'monospace',
                color: isDark ? Colors.white70 : Colors.black87,
              );
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: boxColor,
                  borderRadius: BorderRadius.circular(4),
                  border: isDark ? null : Border.all(color: Colors.grey.shade400),
                ),
                height: 80,
                alignment: Alignment.centerLeft,
                child: _isBusy && _statusText.contains("Connecting")
                    ? Row(
                        children: [
                          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 16),
                          Expanded(child: Text(_statusText, style: statusStyle)),
                        ],
                      )
                    : Text(_statusText, style: statusStyle),
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isBusy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          icon: Icon(widget.isUpload ? Icons.cloud_upload : Icons.cloud_download),
          label: Text(widget.isUpload ? 'Upload' : 'Download'),
          onPressed: _isBusy ? null : _startTransfer,
        ),
      ],
    );
  }
}

/// ============================================================================
///  FIRST-RUN SETUP DIALOG
/// ============================================================================
///  Shown ONCE on the very first launch (before any settings are saved),
///  asking where each external file is located. Finishing (or skipping)
///  persists 'initialSetupComplete', so the check is bypassed on every
///  later launch. Can be re-opened any time from the App Config tab.
///
///  Pick the Root Folder first: every file found inside it is detected
///  automatically (green check). Browse individually only for files that
///  live somewhere else. Every Browse choice is saved immediately.
/// ============================================================================
class FirstRunSetupDialog extends StatelessWidget {
  const FirstRunSetupDialog({super.key});

  Future<void> _finish(BuildContext context, AppStateProvider provider) async {
    await provider.completeFirstRunSetup();
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // watch: rows refresh live as paths are picked (updateSetting notifies)
    final provider = context.watch<AppStateProvider>();

    final bool rootExists = Directory(provider.effectiveRootFolder).existsSync();
    final bool templateExists = File(provider.effectiveTemplateFilePath).existsSync();
    final bool processorsExists = File(provider.effectiveProcessorsFilePath).existsSync();
    final bool buildingsExists = File(provider.effectiveBuildingsFilePath).existsSync();
    final bool schemaExists = File(provider.effectiveUiSchemaPath).existsSync();
    final bool keyMapExists = File(provider.effectiveKeyMapPath).existsSync();
    final bool flowRulesExists =
        File(provider.effectiveFlowRulesPath).existsSync();
    final bool avDevicesExists =
        File(provider.effectiveAvDevicesPath).existsSync();
    final bool modulesExists = Directory(provider.effectiveModulesPath).existsSync();
    final bool documentationExists = Directory(provider.effectiveDocumentationPath).existsSync();

    return AlertDialog(
      title: Row(
        children: const [
          Icon(Icons.tune),
          SizedBox(width: 10),
          Expanded(child: Text('First-Time Setup - Locate Your Files')),
        ],
      ),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pick the Root Folder first - every file found inside it is detected '
                'automatically. Use Browse on any row where a file lives somewhere else. '
                'Green = found at the shown location, red = not found (you can still '
                'finish and set it later in App Config). Choices are saved immediately, '
                'and this dialog will not appear again after you finish.',
              ),
              const SizedBox(height: 18),
              // --- PREFERRED ACCENT COLOR ---
              // Follows the ACTIVE theme style, so re-running setup while
              // Auris is selected offers the Auris swatches (which actually
              // apply) instead of the Classic ones. Saved instantly, and
              // changeable any time under App Config > Theme Style.
              const Text('Preferred accent color',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              Text(
                provider.themeStyle == 'auris'
                    ? 'Pick the accent for the Auris theme. You can change it '
                        'later in App Config.'
                    : 'Pick the color the app theme is built around. You can '
                        'change it later in App Config.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              provider.themeStyle == 'auris'
                  ? const AccentColorPicker(
                      settingKey: 'aurisColor',
                      swatches: RoomConfigApp.aurisSwatches)
                  : const AccentColorPicker(
                      settingKey: 'classicColor',
                      swatches: RoomConfigApp.classicSwatches),
              const Divider(height: 24),
              _pathRow(context, provider,
                  label: 'Root Folder (default base for everything below)',
                  value: provider.effectiveRootFolder,
                  exists: rootExists,
                  isDirectory: true,
                  settingKey: 'rootFolderPath'),
              const Divider(height: 18),
              _pathRow(context, provider,
                  label: 'Template config.json',
                  value: provider.effectiveTemplateFilePath,
                  exists: templateExists,
                  settingKey: 'templateFilePath'),
              _pathRow(context, provider,
                  label: 'processors.json (deployment targets - read on startup)',
                  value: provider.effectiveProcessorsFilePath,
                  exists: processorsExists,
                  settingKey: 'processorsFilePath'),
              _pathRow(context, provider,
                  label: 'buildings.json (building names & abbreviations)',
                  value: provider.effectiveBuildingsFilePath,
                  exists: buildingsExists,
                  settingKey: 'buildingsFilePath'),
              _pathRow(context, provider,
                  label: 'ui_schema.json (GUI field definitions - optional)',
                  value: provider.effectiveUiSchemaPath,
                  exists: schemaExists,
                  settingKey: 'uiSchemaPath'),
              _pathRow(context, provider,
                  label: 'key_map.json (legacy key translation - optional)',
                  value: provider.effectiveKeyMapPath,
                  exists: keyMapExists,
                  settingKey: 'keyMapPath'),
              _pathRow(context, provider,
                  label: 'av_devices.json (device catalog & price list - put '
                      'it on a share to keep one between you)',
                  value: provider.effectiveAvDevicesPath,
                  exists: avDevicesExists,
                  settingKey: 'avDevicesFilePath'),
              _pathRow(context, provider,
                  label: 'av_flow_rules.json (how a room draws itself - '
                      'optional)',
                  value: provider.effectiveFlowRulesPath,
                  exists: flowRulesExists,
                  settingKey: 'flowRulesFilePath'),
              _pathRow(context, provider,
                  label: 'Python modules folder (default: "devices" sub-folder)',
                  value: provider.effectiveModulesPath,
                  exists: modulesExists,
                  isDirectory: true,
                  settingKey: 'modulesPath'),
              _pathRow(context, provider,
                  label: 'Documentation folder (PDF manuals - default: "documentation" sub-folder)',
                  value: provider.effectiveDocumentationPath,
                  exists: documentationExists,
                  isDirectory: true,
                  settingKey: 'documentationPath'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          // Skipping also completes setup, so the app never nags again;
          // everything runs on the defaults shown above.
          onPressed: () => _finish(context, provider),
          child: const Text('Skip - use the defaults shown'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.check),
          label: const Text('Finish Setup'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green.shade700,
            foregroundColor: Colors.white,
          ),
          onPressed: () => _finish(context, provider),
        ),
      ],
    );
  }

  /// One row: found/missing icon, label, resolved path, Browse button.
  Widget _pathRow(BuildContext context, AppStateProvider provider,
      {required String label,
      required String value,
      required bool exists,
      bool isDirectory = false,
      required String settingKey}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            exists ? Icons.check_circle : Icons.error_outline,
            color: exists ? Colors.green : Colors.red.shade400,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: Icon(isDirectory ? Icons.folder_open : Icons.file_open,
                size: 18),
            label: const Text('Browse'),
            onPressed: () async {
              if (isDirectory) {
                String? dir = await FilePicker.getDirectoryPath();
                if (dir != null) {
                  // Persisted immediately; updateSetting also reloads
                  // whatever depends on this path.
                  provider.updateSetting(settingKey, dir);
                }
              } else {
                FilePickerResult? result = await FilePicker.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['json'],
                );
                if (result != null) {
                  provider.updateSetting(
                      settingKey, result.files.single.path!);
                }
              }
            },
          ),
        ],
      ),
    );
  }
}

/// What App Config's log viewer shows: the error, info and migration logs.
LogViewerConfig configuratorLogViewerConfig() => LogViewerConfig(
  appName: 'Extron Configurator',
  version: kAppVersion,
  sources: [
    LogSource.folder(
      AppLogger.logFolder,
      label: 'Log',
      include: (name) => name.toLowerCase().endsWith('.txt'),
    ),
  ],
  chooseSavePath: (name) => FilePicker.saveFile(
    dialogTitle: 'Export logs',
    fileName: name,
    type: FileType.custom,
    allowedExtensions: ['txt'],
  ),
);

/// THE FILE MENU - the hamburger in the top-left corner.
///
/// Everything that starts, opens or moves a document: New and Open for each
/// of the three (room, project, campus), the recent files in a menu that
/// opens to the side, and the two transfers to and from a processor.
class _FileMenu extends StatelessWidget {
  final VoidCallback onNewRoom;
  final VoidCallback onNewProject;
  final VoidCallback onNewCampus;
  final void Function(String dialogTitle) onOpen;
  final Future<void> Function(String file) onOpenPath;
  final VoidCallback onDownload;
  final VoidCallback onUpload;

  const _FileMenu({
    required this.onNewRoom,
    required this.onNewProject,
    required this.onNewCampus,
    required this.onOpen,
    required this.onOpenPath,
    required this.onDownload,
    required this.onUpload,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final recents = provider.recentFiles;

    Widget item(String key, IconData icon, String label, VoidCallback onTap) =>
        MenuItemButton(
          key: ValueKey(key),
          leadingIcon: Icon(icon, size: 20),
          onPressed: onTap,
          child: Text(label),
        );

    final recentItems = <Widget>[];
    for (final kind in RecentKind.values) {
      final list = recents[kind];
      if (list.isEmpty) continue;
      recentItems.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: Text(
          kind.heading.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ));
      for (final entry in list) {
        recentItems.add(MenuItemButton(
          leadingIcon: Icon(recentKindIcon(kind), size: 20),
          onPressed: () => openRecentFile(context, kind, entry, onOpenPath),
          // The name, and under it the whole folder - two rooms called
          // "Conference Room" on two jobs are told apart by where they live.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(entry.label),
              Text(
                path.dirname(entry.file),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ));
      }
    }
    if (recentItems.isNotEmpty) {
      recentItems
        ..add(const Divider(height: 8))
        ..add(MenuItemButton(
          key: const ValueKey('file_recent_clear'),
          leadingIcon: const Icon(Icons.playlist_remove, size: 20),
          onPressed: provider.clearRecentFiles,
          child: const Text('Clear the list'),
        ));
    }

    return MenuAnchor(
      builder: (context, controller, _) => IconButton(
        key: const ValueKey('file_menu'),
        icon: const Icon(Icons.menu),
        tooltip: 'File - new, open, recent files, processor transfers',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        SubmenuButton(
          key: const ValueKey('file_new'),
          leadingIcon: const Icon(Icons.add_circle_outline, size: 20),
          menuChildren: [
            item('file_new_room', Icons.note_add, 'New Room', onNewRoom),
            item('file_new_project', Icons.create_new_folder, 'New Project',
                onNewProject),
            item('file_new_campus', Icons.location_city, 'New Campus',
                onNewCampus),
          ],
          child: const Text('New'),
        ),
        SubmenuButton(
          key: const ValueKey('file_open'),
          leadingIcon: const Icon(Icons.folder_open, size: 20),
          menuChildren: [
            item('file_open_room', Icons.meeting_room_outlined, 'Open Room...',
                () => onOpen('Open a room config')),
            item('file_open_project', Icons.account_tree_outlined,
                'Open Project...', () => onOpen('Open a project')),
            item('file_open_campus', Icons.location_city, 'Open Campus...',
                () => onOpen('Open a campus')),
          ],
          child: const Text('Open'),
        ),
        SubmenuButton(
          key: const ValueKey('file_recent'),
          leadingIcon: const Icon(Icons.schedule, size: 20),
          menuChildren: recentItems.isEmpty
              ? [
                  const MenuItemButton(
                    onPressed: null,
                    child: Text('Nothing opened or saved yet'),
                  ),
                ]
              : recentItems,
          child: const Text('Open Recent'),
        ),
        const Divider(height: 8),
        item('file_download', Icons.cloud_download, 'Download Config',
            onDownload),
        item('file_upload', Icons.cloud_upload, 'Upload Config', onUpload),
      ],
    );
  }
}

/// SETTINGS AS A WINDOW. It sits over a dimmed page with its own title bar
/// and close button; Esc, the X and the gear all close it and put you back on
/// the page you came from.
class _SettingsWindow extends StatelessWidget {
  final Widget child;

  const _SettingsWindow({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): provider.closeSettings,
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: theme.colorScheme.scrim.withValues(alpha: 0.18),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Material(
                  key: const ValueKey('settings_window'),
                  elevation: 12,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  color: theme.colorScheme.surface,
                  child: Column(
                    children: [
                      Container(
                        color: theme.colorScheme.surfaceContainerHigh,
                        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                        child: Row(
                          children: [
                            const Icon(Icons.settings, size: 20),
                            const SizedBox(width: 8),
                            Text('Settings',
                                style: theme.textTheme.titleMedium),
                            const Spacer(),
                            IconButton(
                              key: const ValueKey('settings_close'),
                              icon: const Icon(Icons.close),
                              tooltip: 'Close Settings (Esc)',
                              onPressed: provider.closeSettings,
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// EXPORT, AS A BUTTON FLOATING IN THE LOWER RIGHT.
///
/// It lists what is actually open: the room's workbook when a room is, the
/// job's when a job is, the campus when the job has one - each once - then
/// Google Sheets and the online copy for the same documents, and the page's
/// own tables (on the Cost tab, the estimate as PDF, Excel, text or
/// clipboard).
class _ExportFab extends StatelessWidget {
  final int selectedIndex;
  final bool hasConfig;

  const _ExportFab({required this.selectedIndex, required this.hasConfig});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final tab = (selectedIndex >= 0 && selectedIndex < AppTab.values.length)
        ? AppTab.values[selectedIndex]
        : AppTab.wizard;
    if (tab == AppTab.appConfig) return const SizedBox.shrink();

    final hasRoom = hasConfig;
    final hasProject = provider.hasOpenProject;
    final hasCampus = hasProject && provider.projectCampusFile.isNotEmpty;
    // The Cost tab's own exports (PDF, Excel, text, clipboard) come from the
    // page, which registers them as it mounts - a moment AFTER this button is
    // built. So the menu is only decided when it is opened (see buildItems),
    // and here "on the Cost tab" is enough.
    final onCost = tab == AppTab.cost && hasConfig;
    final tabExports = !onCost &&
        _MainDashboardState._tabExports(selectedIndex) &&
        (hasConfig || _MainDashboardState._tabWorksWithoutConfig(selectedIndex));
    final tabLabel = _MainDashboardState._tabExportLabel(selectedIndex);

    PopupMenuItem<String> item(
      String value,
      IconData icon,
      String title,
      String subtitle,
    ) =>
        PopupMenuItem<String>(
          key: ValueKey('export_item_$value'),
          value: value,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(subtitle),
          ),
        );

    List<PopupMenuEntry<String>> buildItems() {
      final estimate = onCost && CostEstimateActions.current != null;
      final items = <PopupMenuEntry<String>>[
        if (hasRoom)
          item('room_workbook', Icons.meeting_room_outlined,
              'Export the room', 'Every tab of this room, one .xlsx'),
        if (hasProject)
          item('project_workbook', Icons.domain, 'Export the project',
              'The whole job, one .xlsx'),
        if (hasCampus)
          item('campus', Icons.location_city, 'Export the campus',
              'Opens the campus refresh plan to export it'),
        if (hasRoom || hasProject) ...[
          const PopupMenuDivider(),
          if (hasRoom)
            item('sheets_room', Icons.table_chart_outlined,
                'Room to Google Sheets', _sheetsHint(provider)),
          if (hasProject)
            item('sheets_project', Icons.table_chart_outlined,
                'Project to Google Sheets', _sheetsHint(provider)),
          if (hasRoom)
            item('publish_room', Icons.cloud_sync_outlined,
                'Publish the room online',
                'Into the synced folder other people read from'),
          if (hasProject)
            item('publish_project', Icons.cloud_sync_outlined,
                'Publish the project online',
                'Into the synced folder other people read from'),
        ],
        if (estimate) ...[
          const PopupMenuDivider(),
          item('cost_pdf', Icons.picture_as_pdf_outlined,
              'Cost estimate as PDF', 'The quote, ready to send'),
          item('cost_xlsx', Icons.grid_on, 'Cost estimate as Excel (.xlsx)',
              'Every line, to sum and sort'),
          item('cost_txt', Icons.description_outlined,
              'Cost estimate as plain text (.txt)', 'For a ticket or a note'),
          item('cost_copy', Icons.content_copy,
              'Copy the cost estimate to the clipboard', 'To paste in an email'),
        ],
        if (tabExports) ...[
          const PopupMenuDivider(),
          item('tab_xlsx', Icons.grid_on, '$tabLabel as a spreadsheet (.xlsx)',
              'This tab\'s tables'),
          item('tab_txt', Icons.description_outlined,
              '$tabLabel as plain text (.txt)', 'This tab\'s tables'),
          item('tab_copy', Icons.content_copy,
              'Copy ${tabLabel.toLowerCase()} to the clipboard',
              'This tab\'s tables'),
        ],
      ];
      // Drop a leading divider when nothing sits above it.
      while (items.isNotEmpty && items.first is PopupMenuDivider) {
        items.removeAt(0);
      }
      return items;
    }

    if (!hasRoom && !hasProject && !onCost && !tabExports) {
      return const SizedBox.shrink();
    }

    return PopupMenuButton<String>(
      key: const ValueKey('export_menu'),
      tooltip: 'Export',
      position: PopupMenuPosition.over,
      onSelected: (v) async {
        switch (v) {
          case 'room_workbook':
            await exportRoomWorkbook(context, provider);
          case 'project_workbook':
            await exportProjectWorkbook(context, provider);
          case 'campus':
            await showCampusLifecycle(context);
          case 'sheets_room':
            await exportWorkbookToGoogleSheets(context, provider,
                scope: WorkbookScope.room);
          case 'sheets_project':
            await exportWorkbookToGoogleSheets(context, provider,
                scope: WorkbookScope.project);
          case 'publish_room':
            await publishRoomCopy(context, provider);
          case 'publish_project':
            await showOnlineCopyDialog(context, provider);
          case 'tab_xlsx':
          case 'tab_txt':
          case 'tab_copy':
            await exportTabReport(context, provider, tab, v.substring(4));
          case 'cost_pdf':
          case 'cost_xlsx':
          case 'cost_txt':
          case 'cost_copy':
            await CostEstimateActions.current?.export(context, v.substring(5));
        }
      },
      itemBuilder: (ctx) => buildItems(),
      child: IgnorePointer(
        child: FloatingActionButton.extended(
          heroTag: 'export_fab',
          onPressed: () {},
          icon: const Icon(Icons.ios_share),
          label: const Text('Export'),
        ),
      ),
    );
  }

  static String _sheetsHint(AppStateProvider provider) =>
      provider.googleClientId.trim().isEmpty
          ? 'Saves the .xlsx and opens Google Sheets to import it'
          : 'Straight into your Google Drive, as a Sheet';
}
