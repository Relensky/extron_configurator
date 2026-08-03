import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'config_dictionary.dart';
import 'config_key_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'secret_store.dart';
import 'sftp_client.dart';
import 'ui_schema.dart';
import 'package:file_picker/file_picker.dart';

/// Core State Manager for the Room Configuration Application
class AppStateProvider extends ChangeNotifier {
  // --- Application Paths & Settings ---
  String modulesPath = '';
  String processorsFilePath = '';
  String rootFolderPath = ''; 
  String buildingsFilePath = '';
  String templateFilePath = '';
  String uiSchemaPath = ''; // Optional path to ui_schema.json (GUI field definitions)
  String keyMapPath = '';   // Optional path to key_map.json (legacy key translation)
  String documentationPath = ''; // Folder of per-module PDF manuals (blank = <root>/documentation)

  // --- Processor connection settings (App Config > Processor Connection) ---
  // Defaults are the Extron standards; editable for nonstandard processors.
  String sftpUsername = 'admin';
  String sftpPort = '22022';
  String sftpRemoteConfigPath = '/config.json';

  /// Shared processor admin password, pre-filled into the SFTP dialogs when
  /// [useDefaultProcessorPassword] is on — the rooms are typically all on one
  /// standard credential, and retyping it per transfer is the slow part.
  ///
  /// This field is the in-memory copy only. The stored copy lives in the OS
  /// keystore (see [SecretStore]) and NEVER in app_config.json, so the settings
  /// file stays hand-editable without carrying a credential. On Windows the
  /// keystore encrypts it against the logged-in account.
  String defaultProcessorPassword = '';

  /// Whether to pre-fill [defaultProcessorPassword]. Off unless turned on, so
  /// the password is never stored or used by accident.
  bool useDefaultProcessorPassword = false;

  /// Turning the toggle OFF also forgets the saved password — cleared from
  /// memory AND deleted from the keystore — so switching it off is enough to
  /// get the credential off the machine.
  Future<void> setUseDefaultProcessorPassword(bool value) async {
    useDefaultProcessorPassword = value;
    if (!value) {
      defaultProcessorPassword = '';
      await _secrets.delete(SecretKeys.processorPassword);
    }
    notifyListeners();
    await _persistSettings();
  }

  /// Serializes keystore writes. The field calls this on every keystroke, so
  /// without a queue two writes can be in flight at once and an earlier, shorter
  /// value can land last — leaving a truncated password stored. Chaining them
  /// makes the last keystroke the last write.
  Future<void> _passwordWrites = Future.value();

  /// Saves the processor password to the OS keystore (and to the in-memory copy
  /// the SFTP dialogs read). Returns false when the keystore refused it, which
  /// the UI surfaces rather than pretending the password was saved.
  Future<bool> setDefaultProcessorPassword(String value) {
    defaultProcessorPassword = value;
    notifyListeners();
    final result = Completer<bool>();
    _passwordWrites = _passwordWrites.then((_) async {
      result.complete(await _secrets.write(SecretKeys.processorPassword, value));
    });
    return result.future;
  }

  /// Pulls the saved password out of the keystore into memory at startup, and
  /// migrates one that an older build wrote into app_config.json as plain text:
  /// moved into the keystore, then stripped from the JSON on the next save.
  /// [savedJson] is the settings file as parsed.
  Future<void> _loadProcessorPassword(Map<String, dynamic> savedJson) async {
    final legacy = savedJson['defaultProcessorPassword']?.toString() ?? '';
    if (legacy.isNotEmpty) {
      final moved = await _secrets.write(SecretKeys.processorPassword, legacy);
      defaultProcessorPassword = legacy;
      AppLogger.logInfo(moved
          ? 'Moved the saved processor password out of app_config.json into the '
              'OS keystore; the plain-text copy is dropped on the next save.'
          : 'Could not move the saved processor password into the OS keystore — '
              'it stays in app_config.json for now.');
      return;
    }
    defaultProcessorPassword =
        await _secrets.read(SecretKeys.processorPassword) ?? '';
  }

  /// The password the SFTP dialogs should open with: the saved default when the
  /// toggle is on and one is set, otherwise blank (type it per transfer).
  String get autofillProcessorPassword =>
      useDefaultProcessorPassword ? defaultProcessorPassword : '';

  /// Parsed SFTP port with the Extron default as the fallback.
  int get effectiveSftpPort => int.tryParse(sftpPort) ?? 22022;

  // ---------------------------------------------------------------------
  //  DEFAULT PATH RESOLUTION
  //  Every external file falls back to the Root Folder when no explicit
  //  path has been chosen in App Config. The Root Folder itself falls back
  //  to the app's base directory (see _appBaseDir). Python modules default
  //  to the "devices" sub-folder of the root. The UI should always read
  //  these effective* getters instead of the raw fields.
  // ---------------------------------------------------------------------

  /// Cached result of [_appBaseDir]; the base directory never changes during
  /// a run, and resolving it touches the disk, so it is computed once.
  static String? _cachedAppBaseDir;

  /// The default base folder for every blank path AND for app_config.json.
  ///
  /// It must be a STABLE, WRITABLE location: the process working directory
  /// ([Directory.current]) is neither. When a packaged Windows app is
  /// launched from a shortcut or the Start menu, the working directory is
  /// often C:\Windows\System32 — the wrong place to look for the shipped
  /// config.json / processors.json, and one the app cannot write settings
  /// to. So this resolves, in order:
  ///   1. A directory that already holds our own app_config.json — keeps
  ///      settings continuity across launches regardless of how the app was
  ///      started (checks the working dir, then the executable's folder).
  ///   2. A directory that holds the app's shipped data files (config.json,
  ///      ui_schema.json, processors.json, buildings.json, or a devices/
  ///      folder) — the real root the user drops files into. In dev
  ///      (`flutter run`) that is the project root = the working directory.
  ///   3. True first run with nothing placed yet: the executable's own
  ///      folder, because it is stable and writable no matter how the app
  ///      was launched. Falls back to the working directory only when the
  ///      executable path can't be resolved.
  static String _appBaseDir() {
    if (_cachedAppBaseDir != null) return _cachedAppBaseDir!;

    final List<String> candidates = [Directory.current.path];
    try {
      candidates.add(File(Platform.resolvedExecutable).parent.path);
    } catch (_) {}

    // 1. Prefer wherever our settings file already lives.
    for (final d in candidates) {
      if (File(path.join(d, 'app_config.json')).existsSync()) {
        return _cachedAppBaseDir = d;
      }
    }
    // 2. Otherwise a directory that clearly holds the app's data files.
    bool looksLikeData(String d) =>
        File(path.join(d, 'config.json')).existsSync() ||
        File(path.join(d, 'ui_schema.json')).existsSync() ||
        File(path.join(d, 'processors.json')).existsSync() ||
        File(path.join(d, 'buildings.json')).existsSync() ||
        Directory(path.join(d, 'devices')).existsSync();
    for (final d in candidates) {
      if (looksLikeData(d)) return _cachedAppBaseDir = d;
    }
    // 3. Nothing placed yet — use the executable's folder when known.
    return _cachedAppBaseDir =
        candidates.length > 1 ? candidates[1] : candidates[0];
  }

  /// Root Folder setting, falling back to the app's base directory.
  String get effectiveRootFolder =>
      rootFolderPath.isNotEmpty ? rootFolderPath : _appBaseDir();

  /// Python modules folder: explicit choice, else `<root>/devices`.
  String get effectiveModulesPath => modulesPath.isNotEmpty
      ? modulesPath
      : path.join(effectiveRootFolder, 'devices');

  /// PDF manuals folder: explicit choice, else `<root>/documentation`.
  /// Each module's manual is `<module file name>.pdf` in this folder.
  String get effectiveDocumentationPath => documentationPath.isNotEmpty
      ? documentationPath
      : path.join(effectiveRootFolder, 'documentation');

  /// processors.json: explicit choice, else `<root>/processors.json`.
  String get effectiveProcessorsFilePath => processorsFilePath.isNotEmpty
      ? processorsFilePath
      : path.join(effectiveRootFolder, 'processors.json');

  /// buildings.json: explicit choice, else `<root>/buildings.json`.
  String get effectiveBuildingsFilePath => buildingsFilePath.isNotEmpty
      ? buildingsFilePath
      : path.join(effectiveRootFolder, 'buildings.json');

  /// Template config: explicit choice, else `<root>/config.json`.
  String get effectiveTemplateFilePath => templateFilePath.isNotEmpty
      ? templateFilePath
      : path.join(effectiveRootFolder, 'config.json');

  /// ui_schema.json / key_map.json: use the root-folder copy only when it
  /// actually exists there, so the loaders' own working-dir / executable
  /// search still applies otherwise (returns '' to trigger that search).
  String _resolveOptionalFile(String explicit, String filename) {
    if (explicit.isNotEmpty) return explicit;
    if (rootFolderPath.isNotEmpty) {
      final candidate = path.join(rootFolderPath, filename);
      if (File(candidate).existsSync()) return candidate;
    }
    return '';
  }

  /// Display-oriented resolved locations for the setup dialog / App Config
  /// hints (explicit choice, else the root-folder default location).
  String get effectiveUiSchemaPath => uiSchemaPath.isNotEmpty
      ? uiSchemaPath
      : path.join(effectiveRootFolder, 'ui_schema.json');
  String get effectiveKeyMapPath => keyMapPath.isNotEmpty
      ? keyMapPath
      : path.join(effectiveRootFolder, 'key_map.json');

  // ---------------------------------------------------------------------
  //  SETTINGS PERSISTENCE (app_config.json)
  //  Every application setting (file paths, SFTP connection, theme,
  //  toggles) lives in a plain, hand-editable app_config.json — kept in the
  //  per-user settings folder (%APPDATA%\RoomConfigBuilder on Windows) so
  //  that installing a new build never overwrites it. Its exact location is
  //  shown on the App Config tab. The file is created automatically with
  //  defaults on the very first launch, so startup never depends on the user
  //  picking a folder or location. A file left next to the app by an older
  //  version is migrated in once, as are settings saved by even older
  //  versions in the OS store (SharedPreferences).
  // ---------------------------------------------------------------------

  /// Absolute path of the app_config.json in use (shown in App Config).
  String settingsFilePath = '';

  /// True once first-run setup has been completed (persisted in the file).
  bool _initialSetupComplete = false;

  /// The app folder copy of app_config.json — where settings used to live, and
  /// still the file [_appBaseDir] looks for when working out the app's root.
  static String _legacySettingsFilePath() =>
      path.join(_appBaseDir(), 'app_config.json');

  /// Per-user settings folder: %APPDATA%\RoomConfigBuilder on Windows, else
  /// ~/.room_config_builder. Falls back to the app folder when the environment
  /// gives us nothing to work with.
  static String _userSettingsDir() {
    final env = Platform.environment;
    final String base = Platform.isWindows
        ? (env['APPDATA'] ?? env['LOCALAPPDATA'] ?? '')
        : (env['XDG_CONFIG_HOME'] ?? env['HOME'] ?? '');
    if (base.isEmpty) return _appBaseDir();
    return path.join(
        base, Platform.isWindows ? 'RoomConfigBuilder' : '.room_config_builder');
  }

  /// Where app_config.json is read from and written to.
  ///
  /// It deliberately does NOT live next to the executable any more. Deploying a
  /// new build by copying the output folder over the installed one replaced the
  /// settings file along with it, which is how toggles like "Confirm before
  /// deleting settings" and the processor-password autofill kept reverting to
  /// an old build's values. A per-user location is outside anything a deploy
  /// overwrites, so settings carry over across updates.
  ///
  /// A file left in the app folder by an earlier version is migrated on the
  /// first launch (see [_migrateLegacySettingsFile]) and then left alone —
  /// [_appBaseDir] still uses its presence to resolve the app's root folder.
  static String _resolveSettingsFilePath() =>
      path.join(_userSettingsDir(), 'app_config.json');

  /// The resolved app_config.json location, for tests that guard it against
  /// drifting back next to the executable.
  @visibleForTesting
  static String resolvedSettingsFilePath() => _resolveSettingsFilePath();

  /// The app-folder location settings used to live in, for the same tests.
  @visibleForTesting
  static String legacySettingsFilePath() => _legacySettingsFilePath();

  /// One-time move of an app-folder app_config.json into the per-user folder.
  /// Only runs when the per-user file doesn't exist yet, so it can never
  /// clobber newer settings, and never deletes the original.
  static void _migrateLegacySettingsFile(String target) {
    try {
      if (File(target).existsSync()) return;
      final legacy = File(_legacySettingsFilePath());
      if (legacy.path == target || !legacy.existsSync()) return;
      Directory(path.dirname(target)).createSync(recursive: true);
      legacy.copySync(target);
      AppLogger.logInfo(
          'Moved app_config.json into the per-user settings folder '
          '($target) so it survives app updates. The old copy at '
          '${legacy.path} is no longer read.');
    } catch (e, stack) {
      AppLogger.logError('Could not migrate the old app_config.json', e, stack);
    }
  }

  /// Everything that goes into app_config.json.
  ///
  /// Deliberately NOT here: the processor password. It is the one stored value
  /// that isn't a setting, so it lives in the OS keystore instead — and leaving
  /// it out of this map is also what strips a plain-text copy written by an
  /// older build, on the next save.
  @visibleForTesting
  Map<String, dynamic> settingsAsJson() => {
      '__readme':
          'Application settings for the Room Config Builder. File paths may '
          'be edited by hand while the app is closed; blank paths fall back '
          'to files in the Root Folder (blank root = the app folder).',
      'initialSetupComplete': _initialSetupComplete,
      'rootFolderPath': rootFolderPath,
      'modulesPath': modulesPath,
      'processorsFilePath': processorsFilePath,
      'buildingsFilePath': buildingsFilePath,
      'templateFilePath': templateFilePath,
      'uiSchemaPath': uiSchemaPath,
      'keyMapPath': keyMapPath,
      'documentationPath': documentationPath,
      'sftpUsername': sftpUsername,
      'sftpPort': sftpPort,
      'sftpRemoteConfigPath': sftpRemoteConfigPath,
      // defaultProcessorPassword is deliberately absent: it lives in the OS
      // keystore, never in this file. Omitting it here is also what strips a
      // plain-text copy left by an older build.
      'useDefaultProcessorPassword': useDefaultProcessorPassword,
      'isDarkMode': isDarkMode,
      'themeStyle': themeStyle,
      'classicColor': classicColor,
      'aurisColor': aurisColor,
      'classicSecondary': classicSecondary,
      'textScale': textScale,
      'fillDeviceDefaultsOnLoad': fillDeviceDefaultsOnLoad,
      'confirmBeforeDelete': confirmBeforeDelete,
    };

  /// Serializes every setting to app_config.json. Failures are logged but
  /// never thrown — a read-only folder must not break the running app.
  Future<void> _persistSettings() async {
    if (!_persistenceEnabled) return; // Test provider: leave the file alone
    if (settingsFilePath.isEmpty) settingsFilePath = _resolveSettingsFilePath();
    final Map<String, dynamic> data = settingsAsJson();
    try {
      const encoder = JsonEncoder.withIndent('    ');
      final file = File(settingsFilePath);
      // The per-user settings folder doesn't exist on a first launch.
      await file.parent.create(recursive: true);
      await file.writeAsString(encoder.convert(data));
    } catch (e, stack) {
      AppLogger.logError(
          'Failed to save settings to $settingsFilePath', e, stack);
    }
  }

  /// One-time import of settings saved by older versions in the OS store
  /// (SharedPreferences). Only runs when no app_config.json exists yet; the
  /// result is written to the file right afterwards. Bounded by a timeout so
  /// a hung OS store can never freeze startup.
  Future<Map<String, dynamic>> _migrateFromSharedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final keys = prefs.getKeys();
      if (keys.isEmpty) return {};
      final Map<String, dynamic> saved = {
        for (final key in keys) key: prefs.get(key),
      };
      AppLogger.logInfo(
          'Imported ${saved.length} setting(s) from the OS store into app_config.json.');
      return saved;
    } catch (e) {
      AppLogger.logError('Skipped OS-store settings migration', e);
      return {};
    }
  }

  // ---------------------------------------------------------------------
  //  FIRST-RUN SETUP
  //  On the very first launch (no saved settings yet) the UI shows a
  //  one-time dialog asking where each file is located. Once the user
  //  finishes (or skips) the dialog, 'initialSetupComplete' is persisted
  //  and the check is bypassed on every later launch. The app is fully
  //  usable either way — every path has a working default, so nothing
  //  blocks if no folder is ever selected.
  // ---------------------------------------------------------------------

  /// True while the one-time setup dialog should be shown.
  bool firstRunSetupNeeded = false;

  /// True once _loadSavedSettings has finished reading SharedPreferences,
  /// so the UI doesn't flash the setup dialog before the answer is known.
  bool settingsLoaded = false;

  /// Marks first-run setup as done (persisted), then loads everything from
  /// the chosen/default locations so the app is immediately usable.
  Future<void> completeFirstRunSetup() async {
    firstRunSetupNeeded = false;
    _initialSetupComplete = true;
    await _persistSettings();

    await loadUiSchema();
    await loadKeyMap();
    await loadBuildingsList();
    await loadProcessorsList();
    // ignore: unawaited_futures
    preloadAllModules();
    notifyListeners();
    AppLogger.logInfo("First-run setup completed. Paths saved; check bypassed on future launches.");
  }

  /// Lets App Config re-open the setup dialog at any time.
  void requestFirstRunSetup() {
    firstRunSetupNeeded = true;
    notifyListeners();
  }

  // --- UI Schema (drives labels, descriptions, dropdowns for config keys) ---
  // Starts with built-in defaults so the editor works before/without a file.
  UiSchema uiSchema = UiSchema.builtIn();

  // --- Key Map (translates legacy config key names on load) ---
  // Built-in map is empty, so with no key_map.json loading behaves as before.
  ConfigKeyMap keyMap = ConfigKeyMap.builtIn();

  /// The active working file on disk: the file opened locally, or the working
  /// copy chosen during an SFTP download. Empty when the session started from
  /// 'Create New' and hasn't been saved anywhere yet.
  String currentConfigPath = '';
  
  // --- Data State ---
  List<dynamic> processors = [];
  Map<String, dynamic> buildings = {}; // NEW: Store building abbreviations
  Map<String, dynamic>? selectedProcessor;
  Map<String, dynamic> roomConfig = {};

  /// Bumped every time [roomConfig] is REPLACED wholesale — New from template,
  /// opening a file, an SFTP download, Apply Changes in the raw editor, Use
  /// Original. The views key their content on it so Flutter throws the old
  /// input elements away instead of reusing them: `TextFormField.initialValue`
  /// and `Autocomplete.initialValue` are read once per element, so without a
  /// changing key the previous room's name/number sat on the Wizard until the
  /// tab was switched away and back.
  int configRevision = 0;

  /// Call after any wholesale replacement of [roomConfig]. Callers still
  /// notifyListeners() themselves — this only moves the identity forward.
  void _bumpConfigRevision() => configRevision++;

  bool isDarkMode = true;

  /// Visual style selected in App Config. 'classic' (the default) is a
  /// Material theme built with flex_color_scheme around [classicColor];
  /// 'auris' is the sci-fi HUD look built around [aurisColor]. Dark/light
  /// stays a separate toggle that works with every style.
  String themeStyle = 'classic';

  /// Accent color for the Classic theme, stored as a 6-digit RRGGBB hex
  /// string. Chosen from the color picker in App Config (or the first-run
  /// setup dialog). Default: Material blue.
  String classicColor = '2196F3';

  /// Accent color for the Auris theme (RRGGBB hex), chosen from its own
  /// swatch picker in App Config. Default: the package's canonical amber.
  String aurisColor = 'F0A500';

  /// Secondary element color for the Classic style (RRGGBB hex, or '' =
  /// Auto — let the theme derive it). Feeds into flex_color_scheme and
  /// colors the navigation highlight, chips, and toggles. (Auris bakes its
  /// own slate secondary, so it has no counterpart setting.)
  String classicSecondary = '';

  /// App-wide text scale factor (1.0 = normal). Chosen from the Text Size
  /// dropdown in App Config and applied to every view via a MediaQuery
  /// text scaler around the whole MaterialApp.
  double textScale = 1.0;

  /// When true (default), loading a config also fills any device properties
  /// missing from the schema's "device_defaults" (e.g. a DSP without its
  /// audio group numbers). Additions are listed in the acknowledgement
  /// dialog and change log like every other load-time migration. Toggle
  /// lives in App Config.
  bool fillDeviceDefaultsOnLoad = true;

  Future<void> setFillDeviceDefaultsOnLoad(bool value) async {
    fillDeviceDefaultsOnLoad = value;
    notifyListeners();
    await _persistSettings();
  }

  /// When true (default), the trash buttons on the Devices/System tabs ask
  /// for confirmation before removing a property. Toggle lives in App Config
  /// for users who prefer one-click deletes.
  bool confirmBeforeDelete = true;

  Future<void> setConfirmBeforeDelete(bool value) async {
    confirmBeforeDelete = value;
    notifyListeners();
    await _persistSettings();
  }

  /// True when the LAST load actually changed or flagged anything (key
  /// mapping, migrations, defaults, audits). The acknowledgement dialog only
  /// appears when this is set — a clean re-load of an already-migrated file
  /// stays silent.
  bool lastLoadHadChanges = false;

  // ---------------------------------------------------------------------
  //  CONVERSION PROVENANCE
  //  Filled at the end of every load: where each value in the working config
  //  came from, and the reversible list of what the conversion did. The
  //  preview panel and the field editors both read these; both are cleared
  //  when a config is created from the template rather than converted.
  // ---------------------------------------------------------------------

  /// 'SECTION.key' -> where that value came from. A key absent from the map
  /// has no conversion history (a config built from the template, or a value
  /// the user has since typed) and is drawn in the normal text colour.
  final Map<String, ValueOrigin> valueOrigins = {};

  /// Every reversible change the last conversion made, in section/key order.
  final List<ConversionChange> conversionChanges = [];

  /// True when the last load actually converted something, i.e. the preview
  /// has something to show.
  bool get hasConversionPreview => conversionChanges.isNotEmpty;

  /// The deep copy of the file as it was parsed, before any conversion step.
  /// Used to diff against and to restore individual rejected changes.
  Map<String, dynamic> _originalLoadedConfig = {};

  ValueOrigin? originFor(String sectionKey, String fieldKey) =>
      valueOrigins['$sectionKey.$fieldKey'];

  /// Seeds the "file as parsed" side of the diff, so a test can drive
  /// [computeConversionProvenance] without a real load.
  @visibleForTesting
  set originalLoadedConfig(Map<String, dynamic> value) =>
      _originalLoadedConfig = value;

  /// Drops the colouring and the preview — for a config that wasn't converted
  /// (built from the template, or reloaded as-is).
  void _clearConversionProvenance() {
    valueOrigins.clear();
    conversionChanges.clear();
    _originalLoadedConfig = {};
  }

  /// Applies the accept/reject choices from the preview: every REJECTED
  /// change is undone against the working config, and the provenance map is
  /// rebuilt so the tabs recolour to match. Accepted changes stay as they are.
  void applyConversionChoices() {
    for (final change in conversionChanges) {
      if (change.accepted) continue;
      // An empty key is a scalar sitting at the root of the file rather than a
      // property inside a block, so the whole entry is what gets put back or
      // taken away.
      if (change.key.isEmpty) {
        switch (change.kind) {
          case ConversionKind.added:
            roomConfig.remove(change.section);
            valueOrigins.remove(change.id);
            break;
          case ConversionKind.removed:
          case ConversionKind.changed:
            roomConfig[change.section] = change.before;
            valueOrigins[change.id] = ValueOrigin.legacy;
            break;
        }
        continue;
      }
      final section = roomConfig[change.section];
      switch (change.kind) {
        case ConversionKind.added:
          if (section is Map) section.remove(change.key);
          valueOrigins.remove(change.id);
          break;
        case ConversionKind.removed:
        case ConversionKind.changed:
          // Put the loaded file's value back; recreate the block if the whole
          // section was dropped, so rejecting never silently does nothing.
          if (section is Map) {
            section[change.key] = change.before;
          } else {
            roomConfig[change.section] = <String, dynamic>{
              change.key: change.before,
            };
          }
          valueOrigins[change.id] = ValueOrigin.legacy;
          break;
      }
    }
    notifyListeners();
  }

  /// The "deny" path of the acknowledgement dialog: throws away every load-
  /// time change (key mapping, migrations, injected defaults) and reloads the
  /// working file EXACTLY as it sits on disk. The disk file was never
  /// touched by the load, so re-reading it restores the original.
  Future<bool> revertToOriginalLoad() async {
    if (currentConfigPath.isEmpty) return false;
    try {
      final contents = await File(currentConfigPath).readAsString();
      roomConfig = jsonDecode(contents);
      systemLogs.clear();
      lastLoadHadChanges = false;
      // Nothing was converted, so there is no provenance to colour by
      _clearConversionProvenance();
      _bumpConfigRevision(); // Every field now shows the on-disk value
      _preloadModulesFromConfig();
      notifyListeners();
      AppLogger.logInfo(
          "Load changes discarded — reloaded original file $currentConfigPath");
      return true;
    } catch (e, stack) {
      AppLogger.logError(
          "Failed to reload original file $currentConfigPath", e, stack);
      return false;
    }
  }

  /// The navigation rail tab currently shown (0 = Wizard ... 4 = App Config).
  /// Lives in the provider — above the MaterialApp — so it survives the full
  /// remount that switching between the Auris and Classic theme families
  /// forces (see the MaterialApp key in main.dart). Session-only by design.
  int selectedTabIndex = 0;

  void selectTab(int index) {
    selectedTabIndex = index;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  //  SCHEMATIC TAB STATE
  //  Node positions dragged in edit mode and user-drawn connection lines.
  //  Held here (not in the view) so edits survive tab switches; persisted
  //  on demand to a sidecar file next to the working config
  //  ("<config>_schematic.json") via saveSchematicLayout, and re-loaded as
  //  soon as that config is opened (the saved diagram belongs to the file, so
  //  it comes back with it). When the session already has a diagram of its
  //  own, the UI asks first — see schematicLayoutNeedsChoice.
  // ---------------------------------------------------------------------

  /// Node id (device key / 'PROCESSOR' / 'IDF' / 'TOUCHPANEL') -> position
  /// override. Nodes absent from the map sit at their auto-layout spot.
  final Map<String, Offset> schematicPositions = {};

  /// User-drawn lines: {'from': id, 'to': id, 'color': 'RRGGBB', 'label': s}.
  final List<Map<String, String>> schematicLinks = [];

  /// Auto-generated lines the user has deleted or re-routed, identified as
  /// "fromId>toId". Filtered out of the diagram; restorable from the edit
  /// panel. Persisted in the sidecar with the rest of the layout.
  final Set<String> schematicHiddenEdges = {};

  /// The config path the schematic state currently belongs to, so switching
  /// configs resets the layout instead of carrying stale node spots over.
  String _schematicSyncedPath = ' never';

  void setSchematicPosition(String nodeId, Offset pos) {
    schematicPositions[nodeId] = pos;
    notifyListeners();
  }

  void addSchematicLink(String from, String to, String colorHex, String label) {
    schematicLinks.add(
        {'from': from, 'to': to, 'color': colorHex, 'label': label});
    notifyListeners();
  }

  void removeSchematicLinkAt(int index) {
    if (index < 0 || index >= schematicLinks.length) return;
    schematicLinks.removeAt(index);
    notifyListeners();
  }

  /// Rewrites a user-drawn line in place (the edit-line dialog).
  void updateSchematicLinkAt(
      int index, String from, String to, String colorHex, String label) {
    if (index < 0 || index >= schematicLinks.length) return;
    schematicLinks[index] =
        {'from': from, 'to': to, 'color': colorHex, 'label': label};
    notifyListeners();
  }

  void hideSchematicEdge(String edgeId) {
    schematicHiddenEdges.add(edgeId);
    notifyListeners();
  }

  void restoreSchematicEdge(String edgeId) {
    schematicHiddenEdges.remove(edgeId);
    notifyListeners();
  }

  /// Clears dragged positions (auto-layout takes over again). Custom lines
  /// are kept — they are removed individually from the edit panel.
  void resetSchematicPositions() {
    schematicPositions.clear();
    notifyListeners();
  }

  /// Sidecar file the layout persists to ('' when the session has no working
  /// file yet — Create New that was never saved).
  String get schematicSidecarPath {
    if (currentConfigPath.isEmpty) return '';
    final dir = path.dirname(currentConfigPath);
    final base = path.basenameWithoutExtension(currentConfigPath);
    return path.join(dir, '${base}_schematic.json');
  }

  /// True when the in-memory diagram holds anything the user arranged by hand
  /// (dragged nodes, drawn lines, deleted auto-edges). Drives the "keep or
  /// replace" prompt when a config with its own saved layout is opened.
  bool get hasSchematicLayout =>
      schematicPositions.isNotEmpty ||
      schematicLinks.isNotEmpty ||
      schematicHiddenEdges.isNotEmpty;

  /// True when a `<config>_schematic.json` sits next to the working config.
  bool get hasSavedSchematicLayout {
    final sidecar = schematicSidecarPath;
    return sidecar.isNotEmpty && File(sidecar).existsSync();
  }

  /// True when the config that was just opened needs the user's call on the
  /// diagram: they arranged one in this session AND the file has its own saved
  /// layout beside it. Without both, loading the sidecar (or clearing) is the
  /// obvious answer and happens without a prompt.
  bool get schematicLayoutNeedsChoice =>
      _schematicSyncedPath != currentConfigPath &&
      hasSchematicLayout &&
      hasSavedSchematicLayout;

  /// Empties the in-memory diagram and detaches it from any file, so the next
  /// Schematic tab visit starts from the auto-layout.
  void _resetSchematicLayout() {
    _schematicSyncedPath = currentConfigPath;
    schematicPositions.clear();
    schematicLinks.clear();
    schematicHiddenEdges.clear();
  }

  /// Adopts the CURRENT in-memory diagram for the working config, ignoring any
  /// saved sidecar next to it — the "discard the saved schematic" answer to the
  /// prompt shown on load. Nothing is written; the sidecar on disk is only
  /// replaced if the user later hits Save Layout.
  void keepSchematicLayoutForCurrentConfig() {
    _schematicSyncedPath = currentConfigPath;
    AppLogger.logInfo(
        'Kept the in-memory schematic layout; the saved layout beside '
        '$currentConfigPath was not loaded.');
    notifyListeners();
  }

  /// Called when the Schematic tab opens: if the working config changed since
  /// the last visit, drop the old layout and load the sidecar if one exists.
  void ensureSchematicLayoutForCurrentConfig() {
    if (_schematicSyncedPath == currentConfigPath) return;
    loadSchematicLayoutForCurrentConfig();
  }

  /// Replaces the in-memory diagram with the layout saved beside the working
  /// config (blank when there is no sidecar). Called unconditionally when a
  /// config is opened — the saved schematic belongs to the file, so it comes
  /// back with it — and lazily by the Schematic tab for older sessions.
  void loadSchematicLayoutForCurrentConfig() {
    _resetSchematicLayout();
    // Notify in every path — the tab has already built by the time this runs
    // (post-frame), so without it a loaded sidecar wouldn't show until the
    // next unrelated rebuild.
    final sidecar = schematicSidecarPath;
    if (sidecar.isEmpty || !File(sidecar).existsSync()) {
      notifyListeners();
      return;
    }
    try {
      final doc = jsonDecode(File(sidecar).readAsStringSync());
      if (doc is! Map) {
        notifyListeners();
        return;
      }
      final positions = doc['positions'];
      if (positions is Map) {
        positions.forEach((id, xy) {
          if (xy is List && xy.length == 2) {
            schematicPositions[id.toString()] = Offset(
                (xy[0] as num).toDouble(), (xy[1] as num).toDouble());
          }
        });
      }
      final links = doc['links'];
      if (links is List) {
        for (final l in links) {
          if (l is Map && l['from'] != null && l['to'] != null) {
            schematicLinks.add({
              'from': l['from'].toString(),
              'to': l['to'].toString(),
              'color': (l['color'] ?? '2196F3').toString(),
              'label': (l['label'] ?? '').toString(),
            });
          }
        }
      }
      final hidden = doc['hiddenEdges'];
      if (hidden is List) {
        schematicHiddenEdges.addAll(hidden.map((e) => e.toString()));
      }
      AppLogger.logInfo('Schematic layout loaded from $sidecar '
          '(${schematicPositions.length} positions, ${schematicLinks.length} lines).');
    } catch (e) {
      AppLogger.logError('Failed to load schematic layout from $sidecar', e);
    }
    notifyListeners();
  }

  /// Writes the layout sidecar. Returns the saved path, or '' when there is
  /// no working config file to sit next to (or the write failed).
  Future<String> saveSchematicLayout() async {
    final sidecar = schematicSidecarPath;
    if (sidecar.isEmpty) return '';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await File(sidecar).writeAsString(encoder.convert({
        '__readme': 'Schematic tab layout for the Room Config Builder: '
            'dragged node positions and user-drawn connection lines.',
        'positions': schematicPositions
            .map((id, p) => MapEntry(id, [p.dx, p.dy])),
        'links': schematicLinks,
        'hiddenEdges': schematicHiddenEdges.toList(),
      }));
      return sidecar;
    } catch (e, stack) {
      AppLogger.logError('Failed to save schematic layout to $sidecar', e, stack);
      return '';
    }
  }

  List<String> systemLogs = []; // NEW: Store user-facing session logs
  
  // Cache for parsed python module commands to prevent repetitive disk I/O
  final Map<String, List<String>> _moduleCommandsCache = {};
  // Cache for parsed python module inputs (previously re-read from disk on every rebuild)
  final Map<String, List<String>> _moduleInputsCache = {};
  // Cache for per-command state lists ("<module path>::<command>"), used by
  // the schema-driven "module_states" field type.
  final Map<String, List<String>> _moduleStatesCache = {};
  // All python modules discovered under modulesPath (dot notation), for the
  // module selection dropdown/autocomplete on device tabs.
  List<String> availableModules = [];

  /// [availableModules] in the form the config stores — `modules.device.<stem>`.
  /// The device tab's picker and autocomplete offer these, so what is selected
  /// is exactly what is written and the field never shows a bare stem the
  /// processor could not import.
  List<String> get availableModuleImports =>
      availableModules.map(normalizeModuleName).toList();

  // --- MODEL REGISTRY -------------------------------------------------
  // Every model name found across the module files, mapped to the module
  // that should be used for it. Sources, in order of authority:
  //   1. a module-level DEVICE_INFO = { "models": [...] } dict (explicit —
  //      marks that file as the DEFAULT module for those models)
  //   2. the keys of the driver's own self.Models = {...} dict (fallback,
  //      so the dropdown works even before DEVICE_INFO is added)
  final Map<String, ModelEntry> modelRegistry = {};
  // Per-module property defaults: DEVICE_INFO["connection"] merged with
  // DEVICE_INFO["defaults"] (two keys in the file purely for readability).
  // Keys are config.json device properties (protocol, net_port, com_type,
  // keep_alive_command, input, ...) applied when a model is picked.
  final Map<String, Map<String, dynamic>> moduleDefaults = {};

  /// Per-module DEVICE_INFO "omit" lists: config-key patterns the model does
  /// NOT use, so a family default that supplies them gets undone. Keyed by
  /// module stem, same as [moduleDefaults].
  final Map<String, List<String>> moduleOmits = {};

  /// Sorted model names for the device-tab Model dropdown (every model).
  List<String> get availableModels => modelRegistry.keys.toList()..sort();

  /// The modules-folder-relative stem of a config `module` value — the inverse
  /// of [normalizeModuleName]. The config stores the import path the processor
  /// needs ('modules.device.avr_TR311'), but the file sits at
  /// `<modules path>/avr_TR311.py`, so that prefix must come off before the
  /// remaining dots become folder separators. A bare stem, a '.py' suffix, or a
  /// sub-foldered 'vendor.model' value all resolve the same way — which is what
  /// lets one preload (keyed by the stem) serve both spellings instead of the
  /// dropdowns coming up empty until the module is picked again by hand.
  static String moduleStem(String raw) => raw
      .trim()
      .replaceAll(RegExp(r'\.py$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\\/]'), '.')
      .replaceFirst(RegExp(r'^modules\.'), '')
      .replaceFirst(RegExp(r'^devices?\.'), '');

  /// Absolute path of the .py file backing a config `module` value ('' when the
  /// value is blank). See [moduleStem] for how the import prefix is handled.
  String modulePyPath(String moduleValue) {
    final stem = moduleStem(moduleValue);
    if (stem.isEmpty) return '';
    return path.join(
        effectiveModulesPath, '${stem.replaceAll('.', path.separator)}.py');
  }

  /// The module's DEVICE_INFO connection/defaults, accepting either the dotted
  /// config spelling or the bare stem [moduleDefaults] is keyed by.
  Map<String, dynamic>? moduleDefaultsFor(String moduleValue) =>
      moduleDefaults[moduleStem(moduleValue)];

  /// Config-key patterns a module's DEVICE_INFO "omit" list says the model does
  /// not use, keyed the same way as [moduleDefaults]. Empty for most modules.
  List<String> moduleOmitsFor(String moduleValue) =>
      moduleOmits[moduleStem(moduleValue)] ?? const [];

  /// True when [key] matches any pattern in [patterns]. Patterns are plain key
  /// names or globs with '*' ("group_*"); matching is case-insensitive so a
  /// legacy block's GROUP_PROG_GAIN is caught alongside group_prog_gain.
  @visibleForTesting
  static bool keyMatchesOmitPattern(String key, List<String> patterns) {
    for (final pattern in patterns) {
      final regex = RegExp(
          '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
          caseSensitive: false);
      if (regex.hasMatch(key)) return true;
    }
    return false;
  }

  /// Model names offered on [deviceKey]'s tab: only models whose module's
  /// DEVICE_INFO declares a matching "device_type". Untyped models (no
  /// DEVICE_INFO device_type, e.g. the self.Models fallbacks) are left out —
  /// they surface only through the picker's "Show all device types" checkbox.
  List<String> availableModelsFor(String deviceKey) {
    return modelRegistry.values
        .where((e) => modelMatchesDevice(e, deviceKey))
        .map((e) => e.model)
        .toList()
      ..sort();
  }

  /// True when [entry]'s device_type list matches [deviceKey]'s family.
  /// Token-based against the family's section prefix, count key, and label
  /// words, so "projector", "display", or "Projectors" all hit the
  /// PROJECTORDEVICE_ family. A model with NO declared device_type is filtered
  /// OUT of a known family (checkbox-only); a deviceKey outside every known
  /// family isn't filtered at all (nothing to match against).
  bool modelMatchesDevice(ModelEntry entry, String deviceKey) {
    final spec = uiSchema.deviceTypeForSection(deviceKey);
    if (spec == null) return true; // unknown family: no device_type to filter on
    if (entry.deviceTypes.isEmpty) return false; // untyped: checkbox-only
    final Set<String> familyTokens = {
      _normalizeTypeToken(spec.prefix),
      _normalizeTypeToken(spec.countKey.replaceFirst('dev_', '')),
      for (final w in spec.label.split(RegExp(r'[^A-Za-z0-9]+')))
        if (w.isNotEmpty) _normalizeTypeToken(w),
    }..remove('');
    return entry.deviceTypes
        .any((t) => familyTokens.contains(_normalizeTypeToken(t)));
  }

  /// Lowercases, strips non-alphanumerics, and drops 'device' / plural-s
  /// suffixes: 'PROJECTORDEVICE_', 'Projectors', 'projector' all become
  /// 'projector'.
  static String _normalizeTypeToken(String s) {
    var t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (t.endsWith('device')) t = t.substring(0, t.length - 6);
    if (t.endsWith('s') && t.length > 1) t = t.substring(0, t.length - 1);
    return t;
  }

  /// Attempts to find commonly named inputs inside the Python module for the autocomplete field
  Future<List<String>> getInputsForModule(String moduleFileName) async {
    final fullPath = modulePyPath(moduleFileName);

    // Serve from cache when the module was already parsed (startup preload or prior visit)
    if (_moduleInputsCache.containsKey(fullPath)) {
      return _moduleInputsCache[fullPath]!;
    }

    try {
      final file = File(fullPath);
      // If no file exists, return some default Extron input strings
      if (!await file.exists()) return ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT', 'DisplayPort']; 
      
      final content = await file.readAsString();
      
      // Look for common Extron string literals that represent inputs
      final RegExp inputRegex = RegExp(r"['""](HDMIs*d*|HDBaseT|VGA|DisplayPort|DVI|SDI|Composite|Component|Videos*d*|RGB|Type-C|USB-C)['""]", caseSensitive: false);
      
      final Set<String> inputs = {};
      for (final match in inputRegex.allMatches(content)) {
        if (match.group(1) != null) {
          inputs.add(match.group(1)!);
        }
      }
      
      final result = inputs.isEmpty
          ? ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT', 'DisplayPort']
          : (inputs.toList()..sort());
      _moduleInputsCache[fullPath] = result;
      return result;
    } catch (e) {
      return ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT'];
    }
  }

  /// Scans the entire modules directory at startup (or when the path changes)
  /// and parses every .py file into the command/input caches up front.
  /// Fault-tolerant: one unreadable file or folder no longer aborts the scan.
  Future<void> preloadAllModules() async {
    // Resolve once: explicit setting, else "<root>/devices" (see getters).
    final String mPath = effectiveModulesPath;
    final List<String> discovered = [];
    // Rebuilt from scratch on every scan so renamed/removed files drop out.
    modelRegistry.clear();
    moduleDefaults.clear();
    moduleOmits.clear();
    try {
      final dir = Directory(mPath);
      if (!await dir.exists()) {
        if (modulesPath.isEmpty) {
          // Default folder simply not created yet — not an error.
          AppLogger.logInfo(
              "Default modules folder not found (looked in $mPath). "
              "Create a 'devices' sub-folder in the root folder or set the Modules Path in App Config.");
        } else {
          AppLogger.logError("Modules path does not exist: $mPath");
        }
        return;
      }

      // Collect entries first, tolerating unreadable folders/links mid-scan
      final List<FileSystemEntity> entities = [];
      await for (final entity in dir
          .list(recursive: true, followLinks: false)
          .handleError((err) => AppLogger.logError("Skipped unreadable entry while scanning modules", err))) {
        entities.add(entity);
      }

      for (final entity in entities) {
        try {
          if (entity is! File) continue;
          final p = entity.path;
          if (!p.toLowerCase().endsWith('.py')) continue;
          if (p.contains('__pycache__')) continue; // Compiled/cache dirs are never modules

          // Convert the file path back into the dot-notation used by the config
          String rel = path.relative(p, from: mPath);
          String moduleName = rel
              .replaceAll(RegExp(r'\.py$', caseSensitive: false), '')
              .replaceAll(RegExp(r'[\\/]'), '.');
          discovered.add(moduleName);
          await getCommandsForModule(moduleName);
          await getInputsForModule(moduleName);
          await _registerModuleModels(moduleName);
        } catch (e) {
          // Skip this one file, keep parsing the rest
          AppLogger.logError("Skipped unparseable module ${entity.path}", e);
        }
      }
      AppLogger.logInfo("Preloaded ${discovered.length} python module dictionaries from $mPath");
    } catch (e, stack) {
      AppLogger.logError("Failed to preload python module dictionaries", e, stack);
    } finally {
      // Publish whatever was found, even after a partial failure, so the
      // module dropdown and keep-alive lists work with the successful portion.
      availableModules = discovered..sort();
      notifyListeners();
    }
  }

  /// Warms the parser caches for every module referenced by the active config.
  /// Called after any config is loaded so device tabs open instantly.
  /// Works out where every value in the converted config came from, and what
  /// the conversion changed, by diffing the working config against the file as
  /// it was parsed.
  ///
  /// A key that existed in the corresponding ORIGINAL section with the SAME
  /// value is [ValueOrigin.legacy]; one whose value the conversion rewrote is
  /// [ValueOrigin.changed] (a rename alone is not a rewrite — the value is
  /// what is being coloured); a key the conversion introduced is
  /// [ValueOrigin.written]. Sections are lined up through [sectionRenames],
  /// and keys through the same lowercase/no-underscore comparison
  /// auto_case_normalization uses, so COMTYPE and com_type are recognized as
  /// the same property.
  ///
  /// Root-level scalars (`startup_watchdog_stage`, which the processor writes
  /// into the file itself) are diffed too, under an empty field key. They used
  /// to be skipped along with every other non-Map, which drew them orange
  /// whatever had happened to them and kept them out of the change list
  /// entirely.
  @visibleForTesting
  void computeConversionProvenance(
    Map<String, String> sectionRenames,
    List<ConversionConflict> conflicts,
  ) {
    valueOrigins.clear();
    conversionChanges.clear();

    // Converted section name -> its name in the loaded file
    final Map<String, String> originalSectionOf = {
      for (final entry in sectionRenames.entries) entry.value: entry.key,
    };

    String norm(String s) => s.toLowerCase().replaceAll('_', '');

    /// The original block a converted section came from, keyed by normalized
    /// property name, plus the original spelling of each key.
    (Map<String, dynamic>, Map<String, String>) originalBlock(String section) {
      final name = originalSectionOf[section] ?? section;
      final block = _originalLoadedConfig[name];
      if (block is! Map) return (const {}, const {});
      final byNorm = <String, dynamic>{};
      final spelling = <String, String>{};
      block.forEach((k, v) {
        byNorm[norm(k.toString())] = v;
        spelling[norm(k.toString())] = k.toString();
      });
      return (byNorm, spelling);
    }

    /// Records one surviving value: its origin, and the rejectable change when
    /// the conversion added or rewrote it. [key] is '' for a root scalar.
    void record(String sectionKey, String key, dynamic value,
        {required bool wasInFile, dynamic before}) {
      final id = '$sectionKey.$key';
      if (!wasInFile) {
        valueOrigins[id] = ValueOrigin.written;
        conversionChanges.add(ConversionChange(
          section: sectionKey,
          key: key,
          kind: ConversionKind.added,
          after: value,
        ));
        return;
      }
      if (jsonEncode(before) == jsonEncode(value)) {
        valueOrigins[id] = ValueOrigin.legacy;
        return;
      }
      // Same key, new value: the conversion wrote what is on screen, so it
      // gets its own colour as well as a rejectable change.
      valueOrigins[id] = ValueOrigin.changed;
      conversionChanges.add(ConversionChange(
        section: sectionKey,
        key: key,
        kind: ConversionKind.changed,
        before: before,
        after: value,
      ));
    }

    // --- Values that survived into the working config ----------------------
    roomConfig.forEach((sectionKey, block) {
      if (block is! Map) {
        // A scalar at the root of the file rather than a settings block.
        final originalName = originalSectionOf[sectionKey] ?? sectionKey;
        final bool wasInFile =
            _originalLoadedConfig.containsKey(originalName) &&
                _originalLoadedConfig[originalName] is! Map;
        record(sectionKey, '', block,
            wasInFile: wasInFile,
            before: wasInFile ? _originalLoadedConfig[originalName] : null);
        return;
      }
      final (originalByNorm, _) = originalBlock(sectionKey);
      block.forEach((rawKey, value) {
        final key = rawKey.toString();
        final n = norm(key);
        record(sectionKey, key, value,
            wasInFile: originalByNorm.containsKey(n),
            before: originalByNorm[n]);
      });
    });

    // --- Values the conversion dropped -------------------------------------
    // Indexed by conflict id so a removed property that was ALSO a conflict
    // (an IP on a serial device) carries its reason into the preview.
    final Map<String, ConversionConflict> conflictById = {
      for (final c in conflicts) '${c.section}.${c.key}': c,
    };
    for (final c in conflicts) {
      conversionChanges.add(ConversionChange(
        section: c.section,
        key: c.key,
        kind: ConversionKind.removed,
        before: c.value,
        conflictReason: c.reason,
      ));
    }

    _originalLoadedConfig.forEach((originalSection, block) {
      // Where did this section end up? (unchanged name, or its rename)
      final String section = sectionRenames[originalSection] ?? originalSection;
      if (block is! Map) {
        // A root scalar the conversion dropped (the 'ROOM' removal rule and
        // the like) — reported like any other removal instead of vanishing.
        if (!roomConfig.containsKey(section)) {
          conversionChanges.add(ConversionChange(
            section: section,
            key: '',
            kind: ConversionKind.removed,
            before: block,
          ));
        }
        return;
      }
      final current = roomConfig[section];
      final Set<String> survivingNorms = current is Map
          ? current.keys.map((k) => norm(k.toString())).toSet()
          : <String>{};
      block.forEach((rawKey, value) {
        final key = rawKey.toString();
        if (survivingNorms.contains(norm(key))) return;
        // Conflicts were already added above, with their reason attached
        if (conflictById.containsKey('$section.$key')) return;
        conversionChanges.add(ConversionChange(
          section: section,
          key: key,
          kind: ConversionKind.removed,
          before: value,
        ));
      });
    });

    conversionChanges.sort((a, b) {
      final s = a.section.compareTo(b.section);
      return s != 0 ? s : a.key.compareTo(b.key);
    });
  }

  /// Normalizes a config `module` value into the dotted form the processor
  /// imports — `modules.device.<file stem>`. Accepts a bare stem, a file path,
  /// a name with the .py still on it, or a half-qualified 'device.foo', and
  /// leaves an already-correct value untouched.
  static String normalizeModuleName(String raw) {
    var name = raw.trim();
    if (name.isEmpty) return name;
    name = name
        .replaceAll(RegExp(r'\.py$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\\/]'), '.');
    if (name.startsWith('modules.device.')) return name;
    // Strip a leading 'modules.' and/or 'device.'/'devices.' so a partially
    // qualified value doesn't come out doubled.
    name = name
        .replaceFirst(RegExp(r'^modules\.'), '')
        .replaceFirst(RegExp(r'^devices?\.'), '');
    return name.isEmpty ? '' : 'modules.device.$name';
  }

  /// Fills a device's `module` from its `model` using the parsed module
  /// registry when the converted config didn't carry one, and rewrites every
  /// module value into the `modules.device.` form. A model no module claims is
  /// flagged rather than guessed at. Each change lands in systemLogs.
  Future<void> _resolveDeviceModules() async {
    // The registry is warmed in the background at startup — make sure it has
    // actually landed before concluding that a model is unknown.
    if (modelRegistry.isEmpty) await preloadAllModules();

    // Model names in the wild differ in case/spacing from the DEVICE_INFO
    // spelling ("TR311hw" vs "TR311HW"), so match forgivingly.
    final Map<String, ModelEntry> byLowerModel = {
      for (final e in modelRegistry.values) e.model.toLowerCase().trim(): e,
    };

    roomConfig.forEach((sectionKey, block) {
      if (block is! Map) return;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) return;
      final Map<String, dynamic> section = block as Map<String, dynamic>;

      final String module = section['module']?.toString().trim() ?? '';

      if (module.isEmpty) {
        final String model = section['model']?.toString().trim() ?? '';
        if (model.isEmpty) return; // nothing to look the module up by
        final ModelEntry? match =
            modelRegistry[model] ?? byLowerModel[model.toLowerCase()];
        if (match == null) {
          systemLogs.add(
              "FLAGGED: '$sectionKey.module' is empty and no python module "
              "claims model '$model' — set it by hand.");
          return;
        }
        final String resolved = normalizeModuleName(match.module);
        section['module'] = resolved;
        systemLogs.add(
            "MODULE: '$sectionKey.module' set to '$resolved' from model '$model'.");
        return;
      }

      final String normalized = normalizeModuleName(module);
      if (normalized != module) {
        section['module'] = normalized;
        systemLogs.add(
            "MODULE: '$sectionKey.module' rewritten '$module' -> '$normalized'.");
      }
    });
  }

  void _preloadModulesFromConfig() {
    roomConfig.forEach((key, value) {
      if (value is Map && value['module'] is String && (value['module'] as String).isNotEmpty) {
        // Fire-and-forget: results land in the caches used by the FutureBuilders
        getCommandsForModule(value['module']);
        getInputsForModule(value['module']);
      }
    });
  }

  Future<bool> uploadConfigToProcessor({
    required String ipAddress,
    required String password,
    required Function(String) onStatusUpdate,
    String? extraFilePath, // Optional additional file (e.g. Whereused.csv)
  }) async {
    if (roomConfig.isEmpty) {
      onStatusUpdate("Error: No configuration loaded to upload.");
      return false;
    }

    // Validate the optional attachment up front so we don't push a config
    // and THEN discover the second file is missing.
    if (extraFilePath != null && extraFilePath.isNotEmpty) {
      if (!await File(extraFilePath).exists()) {
        onStatusUpdate("Error: Additional file not found: $extraFilePath");
        return false;
      }
    }

    try {
      onStatusUpdate("System: Preparing configuration data...");

      // 1. Clean out unused devices, sort keys, and format as a clean JSON string
      Map<String, dynamic> exportData = _pruneConfig(roomConfig);
      final encoder = const JsonEncoder.withIndent('    ');
      final jsonString = encoder.convert(_sortJson(exportData));

      // 2. Create a temporary directory and file
      // SftpLogger expects a physical file path, so we write the JSON string to a temp file
      final tempDir = await Directory.systemTemp.createTemp('deployment_app_');
      final tempFile = File(path.join(tempDir.path, 'config.json'));
      await tempFile.writeAsString(jsonString);

      // 3. Instantiate your existing SftpLogger and trigger the upload
      final sftpClient = SftpLogger();
      bool success = await sftpClient.uploadFileToProcessor(
        ipAddress: ipAddress,
        password: password,
        inputPath: tempFile.path,
        // Target path / credentials from App Config > Processor Connection
        remoteFilename: sftpRemoteConfigPath,
        username: sftpUsername,
        port: effectiveSftpPort,
        onStatusUpdate: onStatusUpdate,
      );

      if (success) {
        AppLogger.logInfo("Successfully uploaded config.json to $ipAddress");
      } else {
        AppLogger.logError("Failed SFTP upload of config.json to $ipAddress");
      }

      // 3b. Upload the optional additional file (e.g. Whereused.csv) to the
      // processor root, keeping its own file name. Only attempted after a
      // successful config upload; overall success requires BOTH.
      if (success && extraFilePath != null && extraFilePath.isNotEmpty) {
        final extraName = path.basename(extraFilePath);
        onStatusUpdate("System: Uploading additional file $extraName...");
        final extraOk = await sftpClient.uploadFileToProcessor(
          ipAddress: ipAddress,
          password: password,
          inputPath: extraFilePath,
          remoteFilename: '/$extraName',
          username: sftpUsername,
          port: effectiveSftpPort,
          onStatusUpdate: onStatusUpdate,
        );
        if (extraOk) {
          AppLogger.logInfo("Successfully uploaded $extraName to $ipAddress");
          onStatusUpdate("System: Upload complete. Wrote /config.json and /$extraName");
        } else {
          AppLogger.logError("Failed SFTP upload of $extraName to $ipAddress");
          onStatusUpdate(
              "System Error: config.json uploaded, but $extraName FAILED. Retry the additional file.");
          success = false;
        }
      }

      // 4. Clean up the temporary file immediately so we don't clutter the OS
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      
      // Also delete the temp directory itself
      if (await tempDir.exists()) {
        await tempDir.delete();
      }

      return success;
      
    } catch (e, stack) {
      AppLogger.logError("Failed to upload config directly to processor", e, stack);
      onStatusUpdate("System Error: Failed to prepare upload. $e");
      return false;
    }
  }

  // --- Constructor triggers auto-load on startup ---
  // Tests pass autoLoadSettings: false — it disables BOTH the load and every
  // later save. Widget tests drive real UI (theme toggles, updateSetting)
  // whose saves would hit the developer's real app_config.json; worse, a
  // write started inside a test's fake-async zone can be killed mid-flight
  // at teardown, leaving a truncated 0-byte file.
  /// Where the processor password lives — the OS keystore in the app, an
  /// in-memory stand-in under `flutter test` (which has no platform plugin).
  late final SecretStore _secrets;

  AppStateProvider({bool autoLoadSettings = true, SecretStore? secretStore}) {
    _persistenceEnabled = autoLoadSettings;
    // A test provider gets a memory store unless it asks for a real one, so no
    // test ever depends on a keystore being present.
    _secrets = secretStore ??
        (autoLoadSettings ? OsSecretStore() : InMemorySecretStore());
    if (autoLoadSettings) _loadSavedSettings();
  }

  /// False on test-constructed providers: never touch app_config.json.
  bool _persistenceEnabled = true;

  /// Loads saved settings from app_config.json in the root folder. The file
  /// is (re)written with the resolved values on every startup, so it exists
  /// with working defaults from the very first launch — the app starts even
  /// when no folder or location has ever been selected. Settings saved by
  /// older versions in the OS store are imported once.
  Future<void> _loadSavedSettings() async {
    try {
      settingsFilePath = _resolveSettingsFilePath();
      // Carry an older build's app-folder settings over the first time the
      // per-user location is used, so nothing is re-entered after an update.
      _migrateLegacySettingsFile(settingsFilePath);
      Map<String, dynamic> saved = {};
      final file = File(settingsFilePath);
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) saved = decoded;
        } catch (e, stack) {
          // Broken JSON (hand-edit typo): keep a copy for inspection and
          // continue on defaults; the rewrite below recreates a valid file.
          AppLogger.logError(
              'app_config.json is not valid JSON — starting with defaults '
              '(original kept as app_config.json.invalid)', e, stack);
          try {
            await file.copy('$settingsFilePath.invalid');
          } catch (_) {}
        }
      } else {
        // No app_config.json yet: import settings from older versions
        saved = await _migrateFromSharedPreferences();
      }

      String str(String key, String fallback) {
        final v = saved[key]?.toString() ?? '';
        return v.isEmpty ? fallback : v;
      }

      modulesPath = str('modulesPath', '');
      processorsFilePath = str('processorsFilePath', '');
      rootFolderPath = str('rootFolderPath', '');
      buildingsFilePath = str('buildingsFilePath', '');
      templateFilePath = str('templateFilePath', '');
      uiSchemaPath = str('uiSchemaPath', '');
      keyMapPath = str('keyMapPath', '');
      documentationPath = str('documentationPath', '');
      sftpUsername = str('sftpUsername', 'admin');
      sftpPort = str('sftpPort', '22022');
      sftpRemoteConfigPath = str('sftpRemoteConfigPath', '/config.json');
      useDefaultProcessorPassword =
          saved['useDefaultProcessorPassword'] is bool
              ? saved['useDefaultProcessorPassword']
              : false;
      // From the OS keystore, not this file — and migrated out of it if an
      // older build left a plain-text copy behind.
      await _loadProcessorPassword(saved);
      isDarkMode = saved['isDarkMode'] is bool ? saved['isDarkMode'] : true;
      themeStyle = str('themeStyle', 'classic');
      classicColor = str('classicColor', '2196F3');
      aurisColor = str('aurisColor', 'F0A500');
      classicSecondary = str('classicSecondary', '');
      textScale = double.tryParse(str('textScale', '')) ?? 1.0;
      fillDeviceDefaultsOnLoad = saved['fillDeviceDefaultsOnLoad'] is bool
          ? saved['fillDeviceDefaultsOnLoad']
          : true;
      confirmBeforeDelete = saved['confirmBeforeDelete'] is bool
          ? saved['confirmBeforeDelete']
          : true;

      // MIGRATION: the Auris style used to be stored as one value per accent
      // ('amber' | 'teal' | 'magenta'); it is now 'auris' + aurisColor.
      const legacyAuris = {
        'amber': 'F0A500',
        'teal': '35E0C0',
        'magenta': 'E0409A',
      };
      if (legacyAuris.containsKey(themeStyle)) {
        aurisColor = legacyAuris[themeStyle]!;
        themeStyle = 'auris';
      }

      // FIRST-RUN CHECK: only ask for file locations when setup was never
      // completed. Once 'initialSetupComplete' is saved, this is bypassed
      // on every later launch. (Existing installs that already have any
      // path saved are treated as set up — no nagging after an update.)
      final bool setupDone = saved['initialSetupComplete'] == true;
      final bool hasAnySavedPath = rootFolderPath.isNotEmpty ||
          modulesPath.isNotEmpty ||
          processorsFilePath.isNotEmpty ||
          buildingsFilePath.isNotEmpty ||
          templateFilePath.isNotEmpty;
      if (setupDone || hasAnySavedPath) {
        firstRunSetupNeeded = false;
        // Grandfather existing installs in so they're never asked.
        _initialSetupComplete = true;
      } else {
        firstRunSetupNeeded = true;
      }

      // Write the file back immediately so app_config.json exists in the
      // root folder (with defaults or the imported values) from now on.
      await _persistSettings();

      // Load the GUI field schema (falls back to built-in defaults on any error)
      await loadUiSchema();
      // Load the legacy key translation map (empty/no-op when no file exists)
      await loadKeyMap();

      // Load files into memory on boot. The loaders resolve their own
      // default paths (Root Folder / working directory) when no explicit
      // path is set, so processors.json and buildings.json are read on
      // startup even on a fresh install with everything left blank.
      await loadBuildingsList();
      await loadProcessorsList();

      // Warm the python module caches in the background so the keep-alive /
      // input dropdowns are instant the first time a device tab is opened.
      // Uses the effective path (default: <root>/devices) and exits quietly
      // if that folder doesn't exist yet.
      // ignore: unawaited_futures
      preloadAllModules();

    } catch (e, stack) {
      AppLogger.logError("Startup Initialization Error", e, stack);
    } finally {
      // Update the UI once all heavy lifting is done
      settingsLoaded = true; // Safe for the UI to show (or skip) first-run setup
      notifyListeners(); 
    }
  }

  /// Prompts the user to pick an existing config file and loads it.
  /// Automatically creates a backup of the original file if migration is needed.
  Future<bool> loadExistingConfig() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom, 
        allowedExtensions: ['json']
      );
      if (result != null) {
        final file = File(result.files.single.path!);
        final originalContents = await file.readAsString();
        final Map<String, dynamic> parsedConfig = jsonDecode(originalContents);

        // Remember the working file so 'Apply Changes' in the raw editor can
        // save back to it directly.
        currentConfigPath = file.path;

        await _processLoadedConfig(
          originalContents: originalContents,
          parsedConfig: parsedConfig,
          backupDirectory: file.parent.path,
          sourceLabel: file.path,
          // Change log named after the opened file: <name>_backup_log.txt
          changeLogBaseName: path.basenameWithoutExtension(file.path),
        );
        AppLogger.logInfo("Loaded existing config from ${file.path}");
        return true;
      }
      return false;
    } catch (e, stack) {
      AppLogger.logError("Failed to load existing config", e, stack);
      return false;
    }
  }

  /// Downloads /config.json from the processor's root folder over SFTP,
  /// prompts the user for a NEW working file location, writes a backup of the
  /// exact downloaded original, and loads the config into memory for editing.
  Future<bool> downloadConfigFromProcessor({
    required String ipAddress,
    required String password,
    required Function(String) onStatusUpdate,
  }) async {
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('deployment_app_dl_');
      final tempPath = path.join(tempDir.path, 'config.json');

      final sftpClient = SftpLogger();
      final ok = await sftpClient.downloadProcessorFile(
        ipAddress: ipAddress,
        password: password,
        // Remote path / credentials from App Config > Processor Connection
        remoteFilename: sftpRemoteConfigPath,
        outputPath: tempPath,
        username: sftpUsername,
        port: effectiveSftpPort,
        onStatusUpdate: onStatusUpdate,
      );
      if (!ok) return false;

      final originalContents = await File(tempPath).readAsString();
      final Map<String, dynamic> parsedConfig = jsonDecode(originalContents);

      // Backup base name comes from the Active Deployment Target dropdown
      // (e.g. roomName 'BSS103' or 'BSS 103' -> 'BSS103_old_config.json').
      // Sanitized for filesystem safety; blank when no room is selected.
      final String backupBase = (selectedProcessor?['roomName']?.toString() ?? '')
          .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '');

      // Prompt for where the NEW (editable) working copy should live.
      // Per convention, the working file is always plain config.json.
      onStatusUpdate('System: Choose where to save the new working copy...');
      String? savePath = await FilePicker.saveFile(
        dialogTitle: 'Save Downloaded Config As (new working file)',
        fileName: 'config.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (savePath == null) {
        onStatusUpdate('System: Download cancelled (no save location chosen).');
        return false;
      }

      // Write the working copy exactly as downloaded; your edits are exported later
      await File(savePath).writeAsString(originalContents);

      // Remember the working file so 'Apply Changes' in the raw editor can
      // save back to it directly.
      currentConfigPath = savePath;

      // Backup the pristine download next to the working copy, then load it
      await _processLoadedConfig(
        originalContents: originalContents,
        parsedConfig: parsedConfig,
        backupDirectory: File(savePath).parent.path,
        sourceLabel: 'SFTP download from $ipAddress -> $savePath',
        backupBaseName: backupBase.isNotEmpty ? backupBase : null,
        // Change log matches the backup name: e.g. BSS103_backup_log.txt
        changeLogBaseName: backupBase.isNotEmpty ? backupBase : null,
      );

      onStatusUpdate('System: Config downloaded, backed up, and loaded for editing.');
      return true;
    } catch (e, stack) {
      AppLogger.logError("Failed to download config from processor $ipAddress", e, stack);
      onStatusUpdate('System Error: Failed to process downloaded config - $e');
      return false;
    } finally {
      try { if (tempDir != null && await tempDir.exists()) await tempDir.delete(recursive: true); } catch (_) {}
    }
  }

  /// Shared pipeline for any incoming config (local file or SFTP download):
  /// backs up the original, migrates missing keys, flags non-template items,
  /// writes the migration log file, and warms the module caches.
  Future<void> _processLoadedConfig({
    required String originalContents,
    required Map<String, dynamic> parsedConfig,
    required String backupDirectory,
    required String sourceLabel,
    String? backupBaseName, // e.g. 'BSS103' from the Active Deployment Target
    String? changeLogBaseName, // base for the per-load change log file name
  }) async {
    systemLogs.clear(); // Clear old logs on new load

    roomConfig = parsedConfig;

    // Snapshot the file EXACTLY as parsed, before any conversion step. Every
    // later stage mutates roomConfig in place, so this deep copy is the only
    // record of what the room looked like on disk — the provenance colouring
    // and the preview's per-change reject both diff against it.
    _originalLoadedConfig = jsonDecode(jsonEncode(parsedConfig)) as Map<String, dynamic>;
    Map<String, String> sectionRenames = const {};
    List<ConversionConflict> conflicts = const [];

    // --- LEGACY KEY MAPPING (key_map.json) ---
    // Translate old section/property names (e.g. CAMERA1DEVICE.IPADDRESS ->
    // CAMERADEVICE_1.ip_address) BEFORE the template migration runs, so the
    // rest of the pipeline only ever sees current-schema keys. The pristine
    // original text is backed up right after this step (naming the backup
    // needs the mapped room identity).
    if (keyMap.ruleCount > 0) {
      // Canonical key list powers auto-case-normalization: any legacy
      // property whose lowercased/underscore-stripped form matches a current
      // key gets renamed without needing an explicit rule for every variant.
      final canonicalKeys = <String>{
        ...ConfigDictionary.descriptions.keys,
        ...uiSchema.exactKeys,
      }.toList();
      final result = keyMap.apply(roomConfig, canonicalKeys: canonicalKeys);
      // Kept even when nothing else changed: the renames are how the
      // provenance diff lines converted sections up with the original file.
      sectionRenames = result.sectionRenames;
      conflicts = result.conflicts;
      if (result.changed) {
        roomConfig = result.config;
        systemLogs.add("KEY MAPPING: Translated ${result.changes.length} legacy item(s) using ${keyMap.source}");
        systemLogs.addAll(result.changes);
        systemLogs.add("--------------------------------------------------");
        AppLogger.logInfo("Key map applied ${result.changes.length} change(s) to loaded config.");
      }
    }

    // --- AUTOMATIC BACKUP (pristine original text) ---
    // Runs AFTER key mapping so the file name can use the room identity that
    // is now inside the config: gve_bldg abbreviation + gve_room, e.g.
    // 'BSS103_old_config.json' — even for legacy files that stored them as
    // SYSTEM.GVE_BLDG / GVE_ROOM. The CONTENT is still the untouched original.
    try {
      String backupFileName;
      if (backupBaseName != null && backupBaseName.isNotEmpty) {
        // Caller supplied a name (SFTP download: the processor dropdown's
        // room name), e.g. BSS103_old_config.json
        backupFileName = '${backupBaseName}_old_config.json';
      } else {
        String bldg = "UNKNOWN";
        String room = "000";
        final setup = roomConfig['SYSTEM_SETUP'];
        if (setup is Map) {
          bldg = setup['gve_bldg']?.toString() ?? "UNKNOWN";
          room = setup['gve_room']?.toString() ?? "000";
        }
        // Short abbreviation + room, sanitized for the filesystem: BSS103
        final base = '${bldgAbbreviation(bldg)}$room'
            .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '');
        backupFileName = '${base}_old_config.json';
      }
      final backupFilePath = path.join(backupDirectory, backupFileName);

      // Write the exact original string to disk so no formatting is lost
      await File(backupFilePath).writeAsString(originalContents);

      AppLogger.logInfo("Created backup of original config at $backupFilePath");
      // Keep the backup notice at the TOP of the acknowledgement
      systemLogs.insert(0, "BACKUP SAVED: Original file preserved as '$backupFileName'");
      systemLogs.insert(1, "--------------------------------------------------");
    } catch (backupError) {
      AppLogger.logError("Failed to create backup file", backupError);
      systemLogs.insert(0, "WARNING: Failed to generate local backup file.");
    }
    // ------------------------------

    // Check for missing keys and patch them
    _validateAndMigrateConfig();

    // --- BUILDING CODE NORMALIZATION ---
    // gve_bldg holds the building CODE (e.g. 'BSS'). Older configs stored the
    // ALL CAPS full name — convert it via buildings.json and log the change.
    final setupBlock = roomConfig['SYSTEM_SETUP'];
    if (setupBlock is Map) {
      final bldgVal = setupBlock['gve_bldg']?.toString() ?? '';
      if (bldgVal.isNotEmpty && buildings.containsKey(bldgVal)) {
        final code = buildings[bldgVal].toString();
        // Some codes equal their name (e.g. GSCI) — nothing to convert then
        if (code != bldgVal) {
          setupBlock['gve_bldg'] = code;
          systemLogs.add(
              "BUILDING CODE: gve_bldg '$bldgVal' converted to building code '$code' (from buildings.json).");
        }
      }
    }

    // --- DEVICE DEFAULTS FILL (ui_schema.json "device_defaults") ---
    // Optionally ensure every device block carries its type's baseline
    // properties (e.g. a DSP without its audio group numbers). Existing
    // values are never touched; each addition is reported below.
    if (fillDeviceDefaultsOnLoad) {
      final int filled = _fillDeviceDefaults();
      if (filled > 0) {
        systemLogs.add(
            "DEFAULTS: Added $filled missing device propert${filled == 1 ? 'y' : 'ies'} from ui_schema.json device_defaults.");
      }
    }

    // --- MODULE RESOLUTION ---
    // A converted room often arrives with the model but no module. Look the
    // module up by model, and put every module value into the
    // modules.device.<name> form the processor imports.
    await _resolveDeviceModules();

    // --- MODULE VALUE AUDITS ---
    // Every device now has its module, so the family defaults the key map
    // injected can be checked against what that model's driver implements: the
    // keep-alive is corrected from the module, module_states values (a
    // projector's input) are flagged for the tech to decide.
    await validateKeepAliveCommands();
    await validateModuleStateFields();

    // Undo family defaults the resolved model doesn't use (a scaler's group_*
    // audio group numbers). Runs after the audits so the log reads in order:
    // what was corrected, what was flagged, then what was dropped.
    applyModuleOmissions();

    // Undo any opt-in setting the migration steps above added but the loaded
    // file never carried (ENVIRONMENT.traceback_allowed).
    removeUninvitedOptIns(_originalLoadedConfig);

    // Retire the redundant per-outlet '_action' key, carrying a legacy
    // 'Reboot' over to '_reboot_only' so the outlet still cycles. Runs after
    // the companion keys that create '_reboot_only', and reads the loaded file
    // rather than the working config to tell a real setting from that default.
    foldOutletActionIntoRebootOnly(_originalLoadedConfig);

    // Auto-generate the Title Case full room name when gve_bldg (code like
    // 'BSS' OR a legacy full name) resolves against buildings.json — so a
    // converted legacy file lands with 'Behavioral And Social Science 103'
    // instead of the 'Legacy Room Update' placeholder.
    final String? nameBefore =
        roomConfig['SYSTEM_SETUP']?['gui_full_room_name']?.toString();
    if (isKnownBuilding) {
      updateFullRoomName();
      final String? nameAfter =
          roomConfig['SYSTEM_SETUP']?['gui_full_room_name']?.toString();
      if (nameAfter != null && nameAfter != nameBefore) {
        systemLogs.add(
            "AUTO-NAME: gui_full_room_name set to '$nameAfter' (gve_bldg matched buildings.json).");
      }
    }

    // --- CONVERSION PROVENANCE ---
    // Every value-changing step has run by now, so diffing against the parsed
    // original gives the full picture: which values came from the old file
    // (orange), which the conversion wrote (white), and the reversible list
    // the preview offers per change.
    computeConversionProvenance(sectionRenames, conflicts);

    // Warn (never auto-change) when more device blocks exist than the dev_
    // counts allow — extra blocks are hidden in tabs and pruned on export,
    // which is normal for templates but surprising for migrated legacy rooms.
    _auditDeviceCounts();

    // Flag anything in the loaded config that does not exist in the default template
    final template = await _readDefaultTemplate();
    if (template != null) {
      flagUnknownKeys(template);
    } else {
      systemLogs.add("NOTE: No default template available to audit against (set one in App Config).");
    }

    // Persist a permanent record of every change added/flagged during the
    // load so there is an audit trail beyond the in-memory dialog.
    await AppLogger.logMigration(sourceLabel, List<String>.from(systemLogs));

    // --- PER-LOAD CHANGE LOG FILE ---
    // When this load actually changed or flagged anything, write the full
    // acknowledgement next to the backup, named to match it:
    //   SFTP download -> BSS103_backup_log.txt (processor dropdown room)
    //   local open    -> <original file name>_backup_log.txt
    final bool hasChanges = systemLogs.any((l) =>
        l.startsWith('KEY MAPPING') ||
        l.startsWith('KEYMAP') ||
        l.startsWith('->') ||
        l.startsWith('SYSTEM MIGRATION') ||
        l.startsWith('CRITICAL') ||
        l.startsWith('FLAGGED') ||
        l.startsWith('COUNT') ||
        l.startsWith('BUILDING CODE') ||
        l.startsWith('DEFAULTS') ||
        l.startsWith('CONFLICT') ||
        l.startsWith('MODULE') ||
        l.startsWith('AUTO-NAME'));
    // The acknowledgement dialog keys off this: a clean re-load of an
    // already-migrated file (backup + OK lines only) shows no dialog.
    lastLoadHadChanges = hasChanges;
    if (hasChanges) {
      String logBase = changeLogBaseName ?? backupBaseName ?? '';
      if (logBase.isEmpty) {
        // Fall back to the same identifiers the backup name uses
        final bldg = roomConfig['SYSTEM_SETUP']?['gve_bldg']?.toString() ?? 'UNKNOWN';
        final room = roomConfig['SYSTEM_SETUP']?['gve_room']?.toString() ?? '000';
        logBase = '${bldgAbbreviation(bldg)}_$room';
      }
      final changeLogPath = path.join(backupDirectory, '${logBase}_backup_log.txt');
      await AppLogger.writeChangeLog(
          changeLogPath, sourceLabel, List<String>.from(systemLogs));
      systemLogs.add("CHANGE LOG: Details saved to '${logBase}_backup_log.txt'");
    }

    _bumpConfigRevision(); // Repaint every tab with the newly loaded room
    _preloadModulesFromConfig(); // Warm the parser caches for referenced modules
    notifyListeners();
  }

  /// Reads the default template config (the file set via 'Load Template',
  /// falling back to config.json in the root folder / working directory)
  /// without touching state.
  Future<Map<String, dynamic>?> _readDefaultTemplate() async {
    final String tplPath = effectiveTemplateFilePath;
    try {
      final f = File(tplPath);
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e, stack) {
      AppLogger.logError("Failed to read default template for audit", e, stack);
      return null;
    }
  }

  /// Flags any sections/properties in the loaded config that are NOT part of
  /// the default template, so leftovers and custom keys show up in the log.
  @visibleForTesting
  void flagUnknownKeys(Map<String, dynamic> templateConfig) {
    // Strip trailing digits so PROJECTORDEVICE_2 compares against PROJECTORDEVICE_1
    String normalize(String key) => key.replaceFirst(RegExp(r'\d+$'), '');
    final Set<String> templateFamilies = templateConfig.keys.map(normalize).toSet();
    int flagged = 0;

    // 1. Top-level sections unknown to the template
    roomConfig.forEach((key, value) {
      if (uiSchema.isRuntimeWritten(key)) return; // the processor's own
      if (!templateFamilies.contains(normalize(key))) {
        systemLogs.add("FLAGGED: Section '$key' does not exist in the default config template.");
        flagged++;
      }
    });

    // 2. SYSTEM_SETUP properties unknown to the template
    if (roomConfig['SYSTEM_SETUP'] is Map && templateConfig['SYSTEM_SETUP'] is Map) {
      final tplSetup = templateConfig['SYSTEM_SETUP'] as Map;
      (roomConfig['SYSTEM_SETUP'] as Map).forEach((key, value) {
        if (uiSchema.isRuntimeWritten('SYSTEM_SETUP', key.toString())) return;
        if (!tplSetup.containsKey(key)) {
          systemLogs.add("FLAGGED: SYSTEM_SETUP property '$key' is not in the default config template.");
          flagged++;
        }
      });
    }

    // 3. Device block properties unknown to the template's matching device family
    roomConfig.forEach((key, value) {
      if (key == 'SYSTEM_SETUP' || value is! Map) return;
      final family = normalize(key);
      final tplBlockKey = templateConfig.keys.firstWhere(
        (k) => normalize(k) == family && templateConfig[k] is Map,
        orElse: () => '',
      );
      if (tplBlockKey.isEmpty) return; // Whole section already flagged above
      final tplBlock = templateConfig[tplBlockKey] as Map;
      value.forEach((prop, _) {
        if (uiSchema.isRuntimeWritten(key, prop.toString())) return;
        if (!tplBlock.containsKey(prop)) {
          systemLogs.add("FLAGGED: '$key.$prop' is not in the default config template.");
          flagged++;
        }
      });
    });

    if (flagged > 0) {
      systemLogs.add("TEMPLATE AUDIT: $flagged item(s) in this config are not part of the default template.");
    } else {
      systemLogs.add("TEMPLATE AUDIT: All items match the default config template.");
    }
  }

  /// Fills device blocks with any missing properties from the schema's
  /// "device_defaults" section (see UiSchema.defaultsFor). Existing values
  /// always win. Logs one line per added property; returns how many were
  /// added across the whole config.
  int _fillDeviceDefaults() {
    int filled = 0;
    roomConfig.forEach((sectionKey, block) {
      if (sectionKey == 'SYSTEM_SETUP' || block is! Map) return;
      final defaults = uiSchema.defaultsFor(sectionKey);
      defaults.forEach((prop, defaultValue) {
        if (!block.containsKey(prop)) {
          block[prop] = defaultValue;
          systemLogs.add(
              "-> Added missing device property: '$sectionKey.$prop' (Default: '$defaultValue')");
          filled++;
        }
      });
    });
    return filled;
  }

  /// Scans the loaded configuration against baseline defaults and patches missing keys.
  void _validateAndMigrateConfig() {
    // If SYSTEM_SETUP is entirely missing, create it
    if (!roomConfig.containsKey('SYSTEM_SETUP')) {
      roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};
      systemLogs.add("CRITICAL: Added missing 'SYSTEM_SETUP' root block.");
    }

    final systemSetup = roomConfig['SYSTEM_SETUP'] as Map<String, dynamic>;

    // Define the baseline schema needed for the current template to function.
    // Values come from the UI schema's "system_defaults", editable in
    // ui_schema.json without a rebuild. The dev_ count keys are handled
    // separately below — they can't just default to "0".
    final Map<String, dynamic> baselineDefaults = {...uiSchema.systemDefaults};

    int additions = 0;

    // Check existing keys against the baseline
    baselineDefaults.forEach((key, defaultValue) {
      if (!systemSetup.containsKey(key)) {
        systemSetup[key] = defaultValue;
        systemLogs.add("-> Added missing property: '$key' (Default: '$defaultValue')");
        additions++;
      }
    });

    // --- DEVICE COUNTS ---
    // A legacy file can carry device blocks for a family it never declared a
    // count for (AJH125B has a SWITCHERDEVICE but no dev_Switchers). Injecting
    // "0" there silently drops real hardware: the tabs hide the block, the
    // schematic skips it and export prunes it, so the switcher vanishes even
    // though the conversion kept it. Derive the count from the blocks that are
    // actually in the config, which lands on "0" only when there are none.
    for (final t in uiSchema.deviceTypes) {
      if (systemSetup.containsKey(t.countKey)) continue; // the file said so
      final int blocks = roomConfig.keys
          .where((k) =>
              k.startsWith(t.prefix) &&
              int.tryParse(k.substring(t.prefix.length)) != null &&
              roomConfig[k] is Map)
          .length;
      systemSetup[t.countKey] = blocks.toString();
      additions++;
      if (blocks == 0) {
        systemLogs.add("-> Added missing property: '${t.countKey}' (Default: '0')");
      } else {
        systemLogs.add(
            "COUNT RECOVERED: '${t.countKey}' was missing from the file — set to "
            "'$blocks' from the ${t.prefix}* block(s) already present, so the "
            "hardware isn't dropped on export.");
      }
    }

    // Standalone feature blocks from ui_schema.json "section_defaults"
    // (e.g. METRICS_CONFIG): create the section when it is missing entirely,
    // then fill in any properties it doesn't have. Existing values are never
    // touched — the same contract as the SYSTEM_SETUP pass above.
    uiSchema.sectionDefaults.forEach((sectionKey, defaults) {
      final existing = roomConfig[sectionKey];
      if (existing != null && existing is! Map) {
        // Something else lives under that name — never clobber it silently
        systemLogs.add(
            "FLAGGED: '$sectionKey' exists but is not a settings block, so its defaults were skipped.");
        return;
      }
      if (existing == null) {
        roomConfig[sectionKey] = <String, dynamic>{};
        systemLogs.add("-> Added missing section: '$sectionKey'");
      }
      final section = roomConfig[sectionKey] as Map;
      defaults.forEach((key, defaultValue) {
        if (!section.containsKey(key)) {
          section[key] = defaultValue;
          systemLogs.add(
              "-> Added missing property: '$sectionKey.$key' (Default: '$defaultValue')");
          additions++;
        }
      });
    });

    if (additions > 0) {
      String summary = "SYSTEM MIGRATION: Added $additions missing schema properties to match current template standards.";
      systemLogs.insert(2, summary); // Insert summary right below the backup notification
      AppLogger.logInfo(summary);
    } else {
      systemLogs.add("OK: Loaded config already matches the current template schema. No changes required.");
    }
  }

  /// Creates a new config from the default template (set via 'Load Template'),
  /// falling back to config.json in the root folder / working directory.
  /// Devices set to 0. This is the ONLY point where the template file is
  /// actually read into memory.
  Future<bool> createNewConfig() async {
    final String baseConfigPath = effectiveTemplateFilePath;

    try {
      final file = File(baseConfigPath);
      
      if (!await file.exists()) {
        AppLogger.logError(
            "Template config not found at $baseConfigPath. "
            "Place config.json in the root folder or set a Template file in App Config.");
        return false;
      }

      final contents = await file.readAsString();
      roomConfig = jsonDecode(contents);

      // Fresh session: no working file yet, so the raw editor's Apply won't
      // overwrite the previously opened file (or the template) by mistake.
      currentConfigPath = '';

      // Built from the template, not converted — every value is "written",
      // so there is nothing to colour orange.
      _clearConversionProvenance();

      // Default all hardware counts to 0 (families from the UI schema's
      // device_types, so new dev_ keys added there are covered too)
      if (roomConfig.containsKey('SYSTEM_SETUP')) {
        final setup = roomConfig['SYSTEM_SETUP'];
        final deviceKeys =
            uiSchema.deviceTypes.map((t) => t.countKey).toList();

        for (var key in deviceKeys) {
          if (setup.containsKey(key)) {
            setup[key] = "0";
          }
        }
      }

      // Prune existing devices based on the new 0 counts
      roomConfig = _pruneConfig(roomConfig);

      // A brand new room starts with a blank diagram — there is no working
      // file for a sidecar to sit next to yet.
      _resetSchematicLayout();

      _bumpConfigRevision(); // Repaint every tab: this is a different room now
      _preloadModulesFromConfig(); // Warm the parser caches for referenced modules
      notifyListeners();
      AppLogger.logInfo("New config created from template: $baseConfigPath");
      return true;
    } catch (e, stack) {
      AppLogger.logError("Failed to create new config", e, stack);
      return false;
    }
  }

  /// Updates a setting in memory and saves app_config.json simultaneously
  Future<void> updateSetting(String key, String value) async {
    switch (key) {
      case 'modulesPath':
        modulesPath = value;
        // Path changed: stale caches are invalid; rebuild them in the background
        _moduleCommandsCache.clear();
        _moduleInputsCache.clear();
        _moduleStatesCache.clear();
        availableModules = [];
        // ignore: unawaited_futures
        preloadAllModules();
        break;
      case 'processorsFilePath': 
        processorsFilePath = value; 
        // ignore: unawaited_futures
        loadProcessorsList(); // Re-read from the new (or newly-defaulted) location
        break;
      case 'rootFolderPath': 
        rootFolderPath = value; 
        // The root folder is the default base for every other path, so
        // re-resolve everything that may be running on a default:
        // ignore: unawaited_futures
        loadUiSchema();
        // ignore: unawaited_futures
        loadKeyMap();
        // ignore: unawaited_futures
        loadBuildingsList();
        // ignore: unawaited_futures
        loadProcessorsList();
        if (modulesPath.isEmpty) {
          // Default modules folder (<root>/devices) moved with the root
          _moduleCommandsCache.clear();
          _moduleInputsCache.clear();
          _moduleStatesCache.clear();
          availableModules = [];
          // ignore: unawaited_futures
          preloadAllModules();
        }
        break;
      case 'buildingsFilePath': 
        buildingsFilePath = value; 
        // ignore: unawaited_futures
        loadBuildingsList(); // Re-read from the new (or newly-defaulted) location
        break;
      case 'templateFilePath': 
        templateFilePath = value; 
        break;
      case 'uiSchemaPath':
        uiSchemaPath = value;
        // ignore: unawaited_futures
        loadUiSchema(); // Re-resolve the GUI field definitions from the new path
        break;
      case 'keyMapPath':
        keyMapPath = value;
        // ignore: unawaited_futures
        loadKeyMap(); // Re-resolve the legacy key translation rules
        break;
      case 'documentationPath':
        documentationPath = value; // PDFs are resolved on demand — no reload
        break;
      case 'sftpUsername':
        sftpUsername = value.trim().isEmpty ? 'admin' : value.trim();
        break;
      case 'sftpPort':
        sftpPort = value.trim().isEmpty ? '22022' : value.trim();
        break;
      case 'sftpRemoteConfigPath':
        sftpRemoteConfigPath =
            value.trim().isEmpty ? '/config.json' : value.trim();
        break;
      case 'themeStyle':
        themeStyle = value; // 'classic' | 'auris'
        break;
      case 'classicColor':
        classicColor = value; // RRGGBB hex from the color picker
        break;
      case 'aurisColor':
        aurisColor = value; // RRGGBB hex from the Auris swatch picker
        break;
      case 'classicSecondary':
        classicSecondary = value; // RRGGBB hex, or '' = Auto
        break;
      case 'textScale':
        textScale = double.tryParse(value) ?? 1.0;
        break;
    }
    notifyListeners();
    await _persistSettings();
  }

  /// (Re)loads key_map.json — the legacy config key translation rules that
  /// run automatically on every config load. If keyMapPath is empty,
  /// key_map.json is searched for next to the executable / working directory.
  /// With no file (or a broken one), mapping is a no-op and loading behaves
  /// exactly as before.
  Future<void> loadKeyMap() async {
    // Explicit path wins; else <root>/key_map.json when it exists there; else
    // '' so ConfigKeyMap.load runs its own working-dir/executable search.
    keyMap = await ConfigKeyMap.load(
        explicitPath: _resolveOptionalFile(keyMapPath, 'key_map.json'));
    notifyListeners();
  }

  /// (Re)loads ui_schema.json so new/changed field definitions appear in the
  /// editor WITHOUT a rebuild. If uiSchemaPath is empty, ui_schema.json is
  /// searched for next to the executable / working directory. On any failure
  /// the built-in defaults stay active and the error is logged.
  Future<void> loadUiSchema() async {
    // Explicit path wins; else <root>/ui_schema.json when it exists there;
    // else '' so UiSchema.load runs its own working-dir/executable search.
    uiSchema = await UiSchema.load(
        explicitPath: _resolveOptionalFile(uiSchemaPath, 'ui_schema.json'));
    notifyListeners();
  }

  /// Validates the template file and registers it as the default WITHOUT
  /// loading its contents into the active room config. The file is only
  /// actually read when 'Create New Config' is selected.
  Future<bool> validateConfigTemplate(String templatePath) async {
    try {
      final file = File(templatePath);
      if (!await file.exists()) {
        AppLogger.logError("Template file not found at $templatePath");
        return false;
      }
      // Parse once to confirm it's valid JSON, but do NOT assign to roomConfig
      jsonDecode(await file.readAsString());
      await updateSetting('templateFilePath', templatePath); // persists to app_config.json
      AppLogger.logInfo("Template validated and set as default: $templatePath");
      return true;
    } catch (e, stack) {
      AppLogger.logError("Error validating config template (invalid JSON?)", e, stack);
      return false;
    }
  }

  /// Loads the buildings.json file to resolve building names. Falls back to
  /// `<root>/buildings.json` when no explicit path has been chosen.
  Future<void> loadBuildingsList() async {
    final String bPath = effectiveBuildingsFilePath;
    try {
      final file = File(bPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        buildings = jsonDecode(content);
        notifyListeners();
        AppLogger.logInfo("Buildings list loaded from $bPath");
      } else if (buildingsFilePath.isEmpty) {
        // Default location simply doesn't have the file yet — not an error.
        AppLogger.logInfo(
            "buildings.json not found at default location ($bPath). "
            "Place it in the root folder or set the path in App Config.");
      } else {
        AppLogger.logError("Buildings file not found at $bPath");
      }
    } catch (e, stack) {
      AppLogger.logError("Failed to load buildings.json", e, stack);
    }
  }

  /// True when the current gve_bldg matches buildings.json — either as the
  /// ALL CAPS full name (new style) or a legacy abbreviation (old configs).
  /// Drives whether gui_full_room_name is auto-generated or manually typed.
  bool get isKnownBuilding {
    final val = roomConfig['SYSTEM_SETUP']?['gve_bldg']?.toString() ?? '';
    if (val.isEmpty) return false;
    return buildings.containsKey(val) || buildings.values.contains(val);
  }

  /// Resolves a building CODE (e.g. 'BSS') to its Title Case full name from
  /// buildings.json ('Behavioral And Social Science'). Longest name wins when
  /// several names share one code (same dedupe rule as the Setup Wizard).
  /// Returns '' when the code is unknown, so callers can fall back cleanly.
  String fullBuildingNameForCode(String code) {
    if (code.isEmpty) return '';
    String fullName = '';
    buildings.forEach((name, c) {
      if (c.toString() == code && name.length > fullName.length) {
        fullName = name;
      }
    });
    return fullName.isEmpty ? '' : _toTitleCase(fullName);
  }

  /// Resolves a building value to its short abbreviation for FILE NAMES only
  /// (so gve_bldg holding 'ARTS & HUMANITIES BUILDING' still yields
  /// 'ARTS_208_config.json'). Falls back to the raw value when unknown.
  String bldgAbbreviation(String bldgValue) {
    if (buildings.containsKey(bldgValue)) return buildings[bldgValue].toString();
    return bldgValue;
  }

  /// Helper method to convert a string to Title Case (e.g., "ARTS & HUMANITIES" -> "Arts & Humanities")
  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    return text.split(' ').map((word) {
      if (word.isEmpty) return word;
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  /// Automatically updates the gui_full_room_name in SYSTEM_SETUP.
  /// gve_bldg stores the building CODE from buildings.json (e.g. 'BSS'), and
  /// the generated full room name is the Title Case full building name plus
  /// the room number ('Behavioral And Social Science 103').
  /// If the building is not in buildings.json, the name is left untouched so
  /// the user can type the full room name manually in the wizard.
  void updateFullRoomName() {
    if (roomConfig.containsKey('SYSTEM_SETUP')) {
      String bldgValue = roomConfig['SYSTEM_SETUP']['gve_bldg'] ?? '';
      String roomNum = roomConfig['SYSTEM_SETUP']['gve_room'] ?? '';

      // Resolve the ALL CAPS full name: gve_bldg holds the code (new style,
      // e.g. 'BSS') or a legacy full name (older configs). Longest key wins
      // when several names share one code, matching the wizard's dedupe rule.
      String fullBldgName = '';
      if (buildings.containsKey(bldgValue)) {
        fullBldgName = bldgValue;
      } else {
        buildings.forEach((key, value) {
          if (value == bldgValue && key.length > fullBldgName.length) fullBldgName = key;
        });
      }

      if (fullBldgName.isNotEmpty) {
        roomConfig['SYSTEM_SETUP']['gui_full_room_name'] =
            '${_toTitleCase(fullBldgName)} $roomNum'.trim();
      }
      // Unknown building: leave gui_full_room_name for manual entry
      notifyListeners();
    }
  }

  /// Loads the external processors.json file to populate the room selection
  /// dropdown. Runs on boot; falls back to `<root>/processors.json` when no
  /// explicit path has been chosen.
  Future<void> loadProcessorsList() async {
    final String pPath = effectiveProcessorsFilePath;
    try {
      final file = File(pPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        processors = jsonDecode(content);
        notifyListeners();
        AppLogger.logInfo("Processors list loaded from $pPath");
      } else if (processorsFilePath.isEmpty) {
        // Default location simply doesn't have the file yet — not an error.
        AppLogger.logInfo(
            "processors.json not found at default location ($pPath). "
            "Place it in the root folder or set the path in App Config.");
      } else {
        throw Exception("Processors file not found at path.");
      }
    } catch (e, stack) {
      AppLogger.logError("Failed to load processors.json", e, stack);
    }
  }

  // Toggle theme and save it like every other setting
  Future<void> toggleTheme() async {
    isDarkMode = !isDarkMode;
    notifyListeners();
    await _persistSettings();
  }

  /// Sets the active room context
  void selectProcessor(Map<String, dynamic>? processor) { // <-- UPDATED: Allow null
    selectedProcessor = processor;
    notifyListeners();
  }

  /// Resolves the IP/hostname of the Active Deployment Target for SFTP
  /// transfers. Returns '' when no room is selected (UI falls back to prompting).
  String get selectedProcessorIp {
    final p = selectedProcessor;
    if (p == null) return '';
    return (p['ip'] ?? p['ipAddress'] ?? p['ip_address'] ?? p['address'] ?? p['host'] ?? '')
        .toString();
  }
  /// Update a specific nested property for a device (e.g., changing keep_alive_command)
  void updateDeviceValue(String deviceKey, String property, dynamic value) {
    if (roomConfig.containsKey(deviceKey)) {
      // Pasted multiline text can carry real CR control characters — store
      // the two-character backslash+r sequence instead (saved to disk as \\r,
      // e.g. "TLP\\rPoE"), same as every other write path.
      if (value is String && value.contains('\r')) {
        value = value.replaceAll('\r\n', r'\r').replaceAll('\r', r'\r');
      }
      // The config always stores the import path the processor uses —
      // 'modules.device.<file stem>' — however the value arrived (picked from
      // the list, typed by hand, or resolved from a .py file). Normalizing on
      // the way in is what keeps the prefix on a module chosen for a NEW
      // device, not just on one rewritten during a load.
      if (property == 'module' && value is String) {
        value = normalizeModuleName(value);
      }
      roomConfig[deviceKey][property] = value;
      // A new python module was just selected: parse it right away (if it isn't
      // already cached) so its command/input dictionaries are ready instantly.
      if (property == 'module' && value is String && value.isNotEmpty) {
        getCommandsForModule(value);
        getInputsForModule(value);
      }
      notifyListeners();
    }
  }

  /// Removes one property from a section (device block or SYSTEM_SETUP).
  /// The delete buttons on the Devices/System tabs land here; the key can be
  /// re-added later via the Check Defaults dialog.
  void removeConfigKey(String sectionKey, String property) {
    final section = roomConfig[sectionKey];
    if (section is Map && section.containsKey(property)) {
      section.remove(property);
      notifyListeners();
    }
  }

  /// Adds one property to a section (the Check Defaults dialog's "+ Add").
  /// Existing values are never overwritten.
  void addConfigKey(String sectionKey, String property, dynamic value) {
    final section = roomConfig[sectionKey];
    if (section is Map && !section.containsKey(property)) {
      section[property] = value;
      notifyListeners();
    }
  }

  /// Properties the current [sectionKey] block is missing compared to its
  /// defaults, mapped to the default value that would be added. Sources:
  ///   1. the template config's matching block — the exact section name, or
  ///      the family's `<PREFIX>1` block with the index substituted in
  ///   2. ui_schema.json "device_defaults" (devices) or "system_defaults"
  ///      (SYSTEM_SETUP), filling anything the template doesn't cover
  /// Returns {} when the section doesn't exist or nothing is missing.
  Future<Map<String, dynamic>> missingDefaultsFor(String sectionKey) async {
    final current = roomConfig[sectionKey];
    if (current is! Map) return {};

    final Map<String, dynamic> defaults = {};

    // 1. Template block
    try {
      final file = File(effectiveTemplateFilePath);
      if (await file.exists()) {
        final template = jsonDecode(await file.readAsString());
        if (template is Map) {
          dynamic block = template[sectionKey];
          if (block == null && sectionKey != 'SYSTEM_SETUP') {
            final family = uiSchema.deviceTypeForSection(sectionKey);
            if (family != null) block = template['${family.prefix}1'];
          }
          if (block is Map) {
            final copy = block.map((k, v) => MapEntry(k.toString(), v));
            defaults.addAll(sectionKey == 'SYSTEM_SETUP'
                ? copy
                : _indexSubstitute(copy, sectionKey));
          }
        }
      }
    } catch (e) {
      AppLogger.logError(
          'Check Defaults: could not read template $effectiveTemplateFilePath', e);
    }

    // 2. Schema defaults fill any gaps the template leaves
    final schemaDefaults = sectionKey == 'SYSTEM_SETUP'
        ? uiSchema.systemDefaults
        : (uiSchema.sectionDefaults[sectionKey] ??
            uiSchema.defaultsFor(sectionKey));
    schemaDefaults.forEach((k, v) => defaults.putIfAbsent(k, () => v));

    defaults.removeWhere((k, v) => current.containsKey(k));

    // Never offer back a key the device's module lists as unused for this
    // model — otherwise Check Defaults hands the scaler its group_* audio
    // settings again right after the conversion stripped them.
    final omits = moduleOmitsFor(current['module']?.toString() ?? '');
    if (omits.isNotEmpty) {
      defaults.removeWhere((k, v) => keyMatchesOmitPattern(k, omits));
    }
    return defaults;
  }

  /// Parses an Extron Python module file to extract valid keep-alive commands.
  Future<List<String>> getCommandsForModule(String moduleFileName) async {
    // Construct the full local path based on the app settings and the json module string
    final fullPath = modulePyPath(moduleFileName);

    if (_moduleCommandsCache.containsKey(fullPath)) {
      return _moduleCommandsCache[fullPath]!;
    }

    try {
      final file = File(fullPath);
      if (!await file.exists()) return [];
      
      final content = await file.readAsString();
      
      // Regex to find python methods that start with "Update"
      final updateMethodRegExp = RegExp(r"def\s+Update([A-Za-z0-9_]+)\s*\(");
      
      // USE A SET INSTEAD OF A LIST TO PREVENT DUPLICATES
      final Set<String> uniqueCommands = {};

      for (final match in updateMethodRegExp.allMatches(content)) {
        final cmd = match.group(1);
        if (cmd != null) {
          uniqueCommands.add(cmd); // Sets automatically ignore duplicates
        }
      }

      // Convert back to a list and sort alphabetically for a better UI experience
      final commands = uniqueCommands.toList()..sort();

      _moduleCommandsCache[fullPath] = commands;
      return commands;
    } catch (e, stack) {
      AppLogger.logError("Error parsing python module at $fullPath", e, stack);
      return [];
    }
  }

  /// Returns the valid STATES of one command in an Extron Python module, for
  /// the schema-driven "module_states" field type (e.g. ui_schema.json says a
  /// projector's 'input' options come from the module's 'Input' command).
  /// Looks, in order, at:
  ///   1. `self.Commands = { '<command>': { 'AllowedValues': [...] } }`
  ///   2. `def Set<command>:`   the KEYS of its ValueStateValues dict
  ///   3. `def __Match<command>:` the VALUES of its ValueStateValues dict
  ///   4. the `self.<dict>[value]` lookup inside `Set<command>` (per-model
  ///      like self.InputStateValues / self.set_input_states); the union of
  ///      every model's keys is returned
  /// Returns [] when the module file or the command can't be resolved, so the
  /// field falls back to free text entry.
  Future<List<String>> getStatesForModuleCommand(
      String moduleFileName, String command) async {
    if (moduleFileName.isEmpty || command.isEmpty) return [];
    final fullPath = modulePyPath(moduleFileName);
    final cacheKey = '$fullPath::$command';

    if (_moduleStatesCache.containsKey(cacheKey)) {
      return _moduleStatesCache[cacheKey]!;
    }

    try {
      final file = File(fullPath);
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final states = _parseCommandStates(content, command);
      _moduleStatesCache[cacheKey] = states;
      return states;
    } catch (e, stack) {
      AppLogger.logError(
          "Error parsing states for command '$command' in $fullPath", e, stack);
      return [];
    }
  }

  // ---------------------------------------------------------------------
  //  MODEL REGISTRY / DEVICE_INFO PARSING
  //  Each driver .py may declare, at module level (outside any class):
  //
  //    DEVICE_INFO = {
  //        "device_type": "dsp",
  //        "models": ["DMP 64 Plus C", "DMP 64 Plus C V"],
  //        "connection": {
  //            "com_type": "Network",
  //            "protocol": "TCP",
  //            "net_port": 22023
  //        },
  //        "defaults": {
  //            "keep_alive_command": "RefreshMatrix",
  //            "keep_alive_interval": 30
  //        }
  //    }
  //
  //  "device_type" (string or list) restricts which device-family tabs
  //  offer these models: projector, display, camera, switcher, dsp, usb,
  //  power, mediaport, wireless, recorder, screen (matched against the
  //  ui_schema device_types families; omit it to show everywhere).
  //  "models" marks this file as the DEFAULT module for those models;
  //  "connection" and "defaults" keys are config.json device properties
  //  applied when a model is picked (two keys purely for readability).
  //  Files without DEVICE_INFO still contribute the keys of their
  //  self.Models dict so the dropdown is populated everywhere.
  // ---------------------------------------------------------------------

  /// Parses one module's model list + connection defaults into the registry.
  Future<void> _registerModuleModels(String moduleName) async {
    final fullPath = modulePyPath(moduleName);
    try {
      final file = File(fullPath);
      if (!await file.exists()) return;
      final content = await file.readAsString();

      List<String> models = [];
      List<String> deviceTypes = [];
      bool explicit = false;
      final info = parseDeviceInfo(fullPath, content);
      if (info != null) {
        final m = info['models'];
        if (m is List) {
          models = m.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
          explicit = models.isNotEmpty;
        }
        // "device_type": "projector"  or  ["projector", "display"]
        final dt = info['device_type'] ?? info['device_types'];
        if (dt is String && dt.trim().isNotEmpty) deviceTypes = [dt.trim()];
        if (dt is List) {
          deviceTypes = dt
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
        // "connection" + "defaults" are both device properties to apply —
        // merged here; two keys in the file purely for readability.
        final Map<String, dynamic> merged = {};
        for (final section in ['connection', 'defaults']) {
          final d = info[section];
          if (d is Map) {
            merged.addAll(d.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
        // Keyed by the stem so [moduleDefaultsFor] finds it from either the
        // bare name used here or the dotted spelling stored in a config.
        if (merged.isNotEmpty) moduleDefaults[moduleStem(moduleName)] = merged;

        // "omit": key patterns this model does NOT use, even when a family
        // default supplies them (an IN1608 gets no group_* audio settings).
        final omit = info['omit'] ?? info['omit_keys'];
        if (omit is List) {
          final patterns = omit
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (patterns.isNotEmpty) {
            moduleOmits[moduleStem(moduleName)] = patterns;
          }
        }
      }
      // Fallback: the driver's own self.Models dict keys
      if (models.isEmpty) models = parseSelfModels(content);

      for (final model in models) {
        final existing = modelRegistry[model];
        // First module wins unless a later one declares the model EXPLICITLY
        // (DEVICE_INFO) and the current holder was only a fallback match.
        if (existing == null || (explicit && !existing.explicit)) {
          if (existing != null && existing.module != moduleName) {
            AppLogger.logInfo(
                "Model '$model': default module is now $moduleName (DEVICE_INFO) instead of ${existing.module}");
          }
          modelRegistry[model] = ModelEntry(
              model: model,
              module: moduleName,
              explicit: explicit,
              deviceTypes: deviceTypes);
        }
      }
    } catch (e, stack) {
      AppLogger.logError("Error parsing models from $fullPath", e, stack);
    }
  }

  /// Extracts the module-level DEVICE_INFO dict (column 0) as a JSON map.
  /// Tolerates Python syntax: single quotes, trailing commas, # comments,
  /// True/False/None. Returns null when absent or unparsable (logged).
  static Map<String, dynamic>? parseDeviceInfo(String fullPath, String content) {
    final m =
        RegExp(r'^DEVICE_INFO\s*=\s*\{', multiLine: true).firstMatch(content);
    if (m == null) return null;
    final block = _bracedBlockAt(content, m.end - 1);
    if (block == null) {
      AppLogger.logError("DEVICE_INFO in $fullPath never closes its braces");
      return null;
    }
    try {
      final decoded = jsonDecode(pythonLiteralToJson(block));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      AppLogger.logError(
          "DEVICE_INFO in $fullPath is not a valid dict — use JSON-style values (strings, numbers, lists, dicts)", e);
    }
    return null;
  }

  /// Converts a Python dict/list literal to JSON text: strips # comments,
  /// re-quotes single-quoted strings, maps True/False/None, drops trailing
  /// commas. String contents (either quote style) pass through untouched.
  static String pythonLiteralToJson(String src) {
    final out = StringBuffer();
    int i = 0;
    while (i < src.length) {
      final ch = src[i];
      if (ch == '#') {
        // Comment: skip to end of line (we are outside any string here)
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        final quote = ch;
        i++;
        final buf = StringBuffer();
        while (i < src.length && src[i] != quote) {
          if (src[i] == '\\' && i + 1 < src.length) {
            buf.write(src[i]);
            buf.write(src[i + 1]);
            i += 2;
            continue;
          }
          buf.write(src[i]);
          i++;
        }
        i++; // closing quote
        var s = buf.toString();
        if (quote == "'") {
          // Python-escaped apostrophes become literal; bare " needs escaping
          s = s.replaceAll(r"\'", "'").replaceAll('"', r'\"');
        }
        out.write('"$s"');
        continue;
      }
      out.write(ch);
      i++;
    }
    var text = out.toString();
    text = text
        .replaceAll(RegExp(r'\bTrue\b'), 'true')
        .replaceAll(RegExp(r'\bFalse\b'), 'false')
        .replaceAll(RegExp(r'\bNone\b'), 'null');
    // Trailing commas before a closing } or ] are legal Python, not JSON
    text = text.replaceAllMapped(
        RegExp(r',(\s*[}\]])'), (match) => match.group(1)!);
    return text;
  }

  /// Keys of the driver's self.Models = {...} dict (fallback model source).
  static List<String> parseSelfModels(String content) {
    final m = RegExp(r'self\.Models\s*=\s*\{').firstMatch(content);
    if (m == null) return [];
    final block = _bracedBlockAt(content, m.end - 1);
    if (block == null) return [];
    return RegExp("['\"]([^'\"]+)['\"]\\s*:")
        .allMatches(block)
        .map((x) => x.group(1)!)
        .toSet()
        .toList();
  }

  /// Substitutes the device's trailing index into the index-bearing property
  /// values (btn_name, gve_id) of [map], mutating and returning it. e.g. for
  /// deviceKey CAMERADEVICE_3, a btn_name ending in "Cam1" becomes "Cam3".
  /// A trailing "_X" placeholder (the synthesized template, e.g.
  /// Btn_Con_PROJECTORDEVICE_X) becomes the index too. Values with neither
  /// (or an empty value) are left alone.
  Map<String, dynamic> _indexSubstitute(
      Map<String, dynamic> map, String deviceKey) {
    final idxMatch = RegExp(r'(\d+)$').firstMatch(deviceKey);
    if (idxMatch == null) return map;
    final idx = idxMatch.group(1)!;
    for (final key in const ['btn_name', 'gve_id']) {
      final v = map[key];
      if (v != null && v.toString().isNotEmpty) {
        map[key] = v
            .toString()
            .replaceFirst(RegExp(r'\d+$'), idx)
            // Only an X directly after an underscore is a placeholder — a
            // btn_name legitimately ending in X (e.g. "..._MTX") is kept.
            .replaceFirst(RegExp(r'(?<=_)X$'), idx);
      }
    }
    return map;
  }

  /// Treats null and '' as the same "empty" value so a blank module default
  /// (e.g. ip_address: "") doesn't read as different from an absent key.
  static bool _valuesEqual(dynamic a, dynamic b) {
    final na = (a == null || a == '') ? '' : a;
    final nb = (b == null || b == '') ? '' : b;
    return na == nb;
  }

  /// Computes what selecting [model] on [deviceKey] would do, WITHOUT mutating
  /// the config. Feeds the Model-change dialog: whether the module changes, the
  /// module's DEVICE_INFO defaults resolved for this device (trailing index
  /// substituted; site-specific blanks kept), and the fields whose current
  /// value differs from those defaults.
  ModelChangePreview previewModelSelection(String deviceKey, String model) {
    final dev = roomConfig[deviceKey];
    final entry = modelRegistry[model];
    if (dev is! Map || entry == null) {
      return ModelChangePreview(
        known: entry != null,
        newModule: normalizeModuleName(entry?.module ?? ''),
        moduleChanged: false,
        resolvedDefaults: const {},
        diffs: const [],
      );
    }
    // Compare in the stored import form so a device already on this module
    // isn't reported as a switch just because the registry key is the stem.
    final moduleImport = normalizeModuleName(entry.module);
    final currentModule =
        normalizeModuleName(dev['module']?.toString() ?? '');
    final raw = moduleDefaults[entry.module] ?? const <String, dynamic>{};
    final resolved =
        _indexSubstitute(Map<String, dynamic>.from(raw), deviceKey);
    final diffs = <FieldDiff>[];
    resolved.forEach((k, v) {
      if (!_valuesEqual(dev[k], v)) {
        diffs.add(FieldDiff(key: k, current: dev[k], moduleDefault: v));
      }
    });
    return ModelChangePreview(
      known: true,
      newModule: moduleImport,
      moduleChanged: currentModule != moduleImport,
      resolvedDefaults: resolved,
      diffs: diffs,
    );
  }

  /// "Apply module defaults" action (a new/reset device): sets 'model' +
  /// 'module' and writes every resolved DEVICE_INFO default onto the block,
  /// overwriting existing values. Returns the "key = value" strings applied
  /// (for the acknowledgement snackbar). An unknown model only saves the text.
  List<String> applyModuleDefaults(String deviceKey, String model) {
    final List<String> applied = [];
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return applied;
    dev['model'] = model;

    final entry = modelRegistry[model];
    if (entry != null) {
      // The registry is keyed by the bare file stem; the config stores the
      // dotted import path.
      final String moduleImport = normalizeModuleName(entry.module);
      if (dev['module'] != moduleImport) {
        dev['module'] = moduleImport;
        applied.add('module = $moduleImport');
      }
      final raw = moduleDefaults[entry.module];
      if (raw != null) {
        final resolved =
            _indexSubstitute(Map<String, dynamic>.from(raw), deviceKey);
        resolved.forEach((k, v) {
          dev[k] = v;
          applied.add('$k = $v');
        });
      }
      // Parse the newly selected module right away so the keep-alive /
      // input dropdowns are ready the moment the form rebuilds.
      getCommandsForModule(entry.module);
      getInputsForModule(entry.module);
      AppLogger.logInfo(
          "Model '$model' applied to $deviceKey with module defaults: ${applied.isEmpty ? 'no changes needed' : applied.join(', ')}");
    }
    notifyListeners();
    return applied;
  }

  /// "Keep current settings" action (a conversion): sets 'model' + 'module'
  /// only, leaving every other device property untouched. An unknown model
  /// just saves the model text.
  void keepSettingsSwitchModule(String deviceKey, String model) {
    final dev = roomConfig[deviceKey];
    if (dev is! Map) return;
    dev['model'] = model;

    final entry = modelRegistry[model];
    if (entry != null) {
      final String moduleImport = normalizeModuleName(entry.module);
      dev['module'] = moduleImport;
      // Parse the newly selected module right away so the keep-alive /
      // input dropdowns are ready the moment the form rebuilds.
      getCommandsForModule(entry.module);
      getInputsForModule(entry.module);
      AppLogger.logInfo(
          "Model '$model' set on $deviceKey (module $moduleImport); existing settings kept.");
    }
    notifyListeners();
  }

  /// Resolves the PDF manual for [moduleName]: `<module file name>.pdf` in the
  /// Documentation folder (App Config; default `<root>/documentation`). Returns
  /// the file path when it exists, otherwise a user-facing error message (never
  /// both). Pure lookup — used by both the in-app viewer and the external-open
  /// path so the resolution rules stay in one place.
  ({String? path, String? error}) locateModuleManual(String moduleName) {
    if (moduleName.isEmpty) {
      return (path: null, error: 'Select a python module (or model) first.');
    }
    final baseName = moduleName.split('.').last;
    final pdfPath = path.join(effectiveDocumentationPath, '$baseName.pdf');
    if (!File(pdfPath).existsSync()) {
      return (path: null, error: 'No manual found: $pdfPath');
    }
    return (path: pdfPath, error: null);
  }

  /// Opens the PDF manual for [moduleName] in the OS default PDF viewer (the
  /// in-app viewer's "Open externally" fallback). Returns null on success,
  /// else a user-facing error message.
  Future<String?> openModuleDocumentation(String moduleName) async {
    final located = locateModuleManual(moduleName);
    if (located.error != null) return located.error;
    return openInDesktop(located.path!);
  }

  /// Hands [target] (a file or a folder) to the OS to open with whatever is
  /// registered for it. Returns null on success, else a user-facing message.
  Future<String?> openInDesktop(String target) async {
    if (target.isEmpty) return 'Nothing to open.';
    if (!File(target).existsSync() && !Directory(target).existsSync()) {
      return 'No longer there: $target';
    }
    try {
      await Process.start(
          Platform.isWindows
              ? 'explorer.exe'
              : (Platform.isMacOS ? 'open' : 'xdg-open'),
          [target],
          mode: ProcessStartMode.detached);
      AppLogger.logInfo('Opened $target');
      return null;
    } catch (e, stack) {
      AppLogger.logError('Failed to open $target', e, stack);
      return 'Could not open $target';
    }
  }

  /// Opens the folder holding [filePath] with the file itself highlighted where
  /// the platform supports it (Explorer and Finder both do). Falls back to just
  /// opening the folder. Returns null on success, else a user-facing message.
  ///
  /// Explorer exits non-zero even when it worked, so the exit code is ignored —
  /// a launch failure surfaces as an exception instead.
  Future<String?> revealInFileManager(String filePath) async {
    if (filePath.isEmpty) return 'Nothing to show.';
    final folder = path.dirname(filePath);
    if (!File(filePath).existsSync()) {
      // The file moved or was never written — the folder is still useful.
      return Directory(folder).existsSync()
          ? openInDesktop(folder)
          : 'No longer there: $filePath';
    }
    try {
      if (Platform.isWindows) {
        // One argument, comma included: explorer parses "/select,<path>" as a
        // unit and ignores a space-separated path.
        await Process.start('explorer.exe', ['/select,$filePath'],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', ['-R', filePath],
            mode: ProcessStartMode.detached);
      } else {
        // No portable "select the file" on Linux desktops — open the folder.
        return openInDesktop(folder);
      }
      AppLogger.logInfo('Revealed $filePath');
      return null;
    } catch (e, stack) {
      AppLogger.logError('Failed to reveal $filePath', e, stack);
      return 'Could not open $folder';
    }
  }

  /// Extracts the state list for [command] from a module's source text.
  static List<String> _parseCommandStates(String content, String command) {
    final escaped = RegExp.escape(command);

    // 1. self.Commands entry: '<command>': { ... 'AllowedValues': [...] ... }
    final entryMatch =
        RegExp("['\"]$escaped['\"]\\s*:\\s*\\{").firstMatch(content);
    if (entryMatch != null) {
      final block = _bracedBlockAt(content, entryMatch.end - 1);
      if (block != null) {
        final allowedMatch =
            RegExp("['\"]AllowedValues['\"]\\s*:\\s*\\[").firstMatch(block);
        if (allowedMatch != null) {
          final listEnd = block.indexOf(']', allowedMatch.end);
          if (listEnd != -1) {
            final listText = block.substring(allowedMatch.end, listEnd);
            final values = RegExp("['\"]([^'\"]+)['\"]")
                .allMatches(listText)
                .map((m) => m.group(1)!)
                .toList();
            if (values.isNotEmpty) return values;
          }
        }
      }
    }

    // 2. def Set<command>: keys of its ValueStateValues dict are the states
    final setStates = _valueStateValuesIn(content, 'Set$command', keys: true);
    if (setStates.isNotEmpty) return setStates;

    // 3. def __Match<command>: dict is inverted, so the VALUES are the states
    final matchStates =
        _valueStateValuesIn(content, '__Match$command', keys: false);
    if (matchStates.isNotEmpty) return matchStates;

    // 4. Set<command> may index a per-model dict, e.g.
    //    self.InputStateValues[value] / self.set_input_states[value].
    //    Find the attribute(s) it indexes, then union the keys of every
    //    assignment of that attribute in the file (one per supported model).
    final defMatch =
        RegExp('def\\s+Set$escaped\\s*\\(').firstMatch(content);
    if (defMatch != null) {
      final nextDef = content.indexOf(RegExp(r'\n\s*def\s'), defMatch.end);
      final body = content.substring(
          defMatch.end, nextDef == -1 ? content.length : nextDef);
      final attrs = RegExp(r'self\.([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*value\s*\]')
          .allMatches(body)
          .map((m) => m.group(1)!)
          .toSet();
      final Set<String> union = <String>{};
      for (final attr in attrs) {
        for (final m in RegExp('self\\.${RegExp.escape(attr)}\\s*=\\s*\\{')
            .allMatches(content)) {
          final block = _bracedBlockAt(content, m.end - 1);
          if (block == null) continue;
          union.addAll(RegExp("['\"]([^'\"]+)['\"]\\s*:")
              .allMatches(block)
              .map((mm) => mm.group(1)!));
        }
      }
      if (union.isNotEmpty) return union.toList();
    }

    return [];
  }

  /// Finds `def [methodName](` and returns the entries of the first local
  /// `...StateValues = { ... }` dict inside it (usually named
  /// ValueStateValues, sometimes e.g. InputStateValues) — dict keys when
  /// [keys], else dict values. Returns [] when the method or dict is absent.
  static List<String> _valueStateValuesIn(String content, String methodName,
      {required bool keys}) {
    final defMatch =
        RegExp('def\\s+${RegExp.escape(methodName)}\\s*\\(').firstMatch(content);
    if (defMatch == null) return [];

    // Method body: up to the next 'def ' so we never read another method's dict
    final nextDef = content.indexOf(RegExp(r'\n\s*def\s'), defMatch.end);
    final body = content.substring(
        defMatch.end, nextDef == -1 ? content.length : nextDef);

    final dictMatch =
        RegExp(r'[A-Za-z_]*StateValues\s*=\s*\{').firstMatch(body);
    if (dictMatch == null) return [];
    final block = _bracedBlockAt(body, dictMatch.end - 1);
    if (block == null) return [];

    // Entries look like 'Name' : 'code' — capture left or right side
    final pattern = keys
        ? RegExp("['\"]([^'\"]+)['\"]\\s*:")
        : RegExp(":\\s*['\"]([^'\"]+)['\"]");
    return pattern.allMatches(block).map((m) => m.group(1)!).toList();
  }

  /// Returns the text of the balanced {...} block whose opening brace is at
  /// [openIndex] in [text] (braces inside quotes are rare in these dicts and
  /// treated as structural). Null when the block never closes.
  static String? _bracedBlockAt(String text, int openIndex) {
    int depth = 0;
    for (int i = openIndex; i < text.length; i++) {
      final ch = text[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return text.substring(openIndex, i + 1);
      }
    }
    return null;
  }

  /// Attempts to parse raw string JSON and update the global state.
  /// Used by the raw JSON editor view.
  void updateConfigFromRawJson(String rawJson) {
    try {
      final parsed = jsonDecode(rawJson) as Map<String, dynamic>;

      // JSON "\r" escapes decode into REAL control characters — normalize
      // them to the literal two-character \r the processor GUI expects, so
      // preset names etc. stay correct even when edited via the raw editor
      // (the key mapper only covers the file/SFTP load path).
      final fixed = _normalizeCarriageReturnsIn(parsed);
      if (fixed > 0) {
        AppLogger.logInfo(
            "Normalized carriage returns in $fixed value(s) from raw JSON editor.");
      }

      roomConfig = parsed;
      _bumpConfigRevision(); // Hand-edited JSON: rebuild the form fields from it
      _preloadModulesFromConfig(); // Warm the parser caches for referenced modules
      notifyListeners();
      AppLogger.logInfo("Room configuration updated from raw JSON editor.");
    } catch (e, stack) {
      AppLogger.logError("Failed to parse raw JSON from editor", e, stack);
      rethrow; // Pass error to UI for user feedback
    }
  }

  /// Replaces REAL carriage-return control characters (\r\n or \r) in every
  /// string value of [cfg] with the two-character backslash+r sequence used
  /// by the processor GUI. When the config is saved, the JSON encoder escapes
  /// the backslash, so the file ON DISK contains \\r (e.g. gui_preset_name
  /// `Whiteboard<CR>Left` -> "Whiteboard\\rLeft" in config.json). Lone \n is
  /// left untouched. Returns how many values were changed. Mirrors the key
  /// mapper's escape_carriage_returns step so EVERY write path produces the
  /// same on-disk representation.
  int _normalizeCarriageReturnsIn(Map<String, dynamic> cfg) {
    int changed = 0;
    cfg.forEach((sectionName, block) {
      if (block is! Map) return;
      final Map<String, dynamic> section = block as Map<String, dynamic>;
      for (final key in section.keys.toList()) {
        final v = section[key];
        if (v is String && v.contains('\r')) {
          section[key] = v.replaceAll('\r\n', r'\r').replaceAll('\r', r'\r');
          changed++;
        }
      }
    });
    return changed;
  }

  /// Writes the CURRENT in-memory config to the active working file (the file
  /// opened locally, or the working copy chosen during an SFTP download).
  /// Saves the FULL un-pruned config so no device blocks are ever lost on
  /// disk — export and SFTP upload still produce the pruned version.
  /// Returns the path written, or null when no working file is associated
  /// with this session (e.g. 'Create New' that hasn't been exported yet).
  Future<String?> saveCurrentConfigToFile() async {
    if (currentConfigPath.isEmpty) return null;
    try {
      const encoder = JsonEncoder.withIndent('    ');
      await File(currentConfigPath)
          .writeAsString(encoder.convert(_sortJson(roomConfig)));
      AppLogger.logInfo("Saved current config to working file $currentConfigPath");
      return currentConfigPath;
    } catch (e, stack) {
      AppLogger.logError("Failed to save working file $currentConfigPath", e, stack);
      rethrow; // Surface to the UI so the user knows the save failed
    }
  }

  /// Returns a formatted JSON string of the current config for the editor.
  /// Rendered PRUNED: devices beyond the dev_ counts (e.g. a family set to 0
  /// in the wizard) are hidden, so the raw view always matches what export
  /// and SFTP upload will actually write.
  String getPrettyConfigString() {
    if (roomConfig.isEmpty) return "{}";
    final encoder = const JsonEncoder.withIndent('    ');
    return encoder.convert(_sortJson(_pruneConfig(roomConfig)));
  }

  /// Helper to grab a default template for a device if the user increases the count.
  /// Priority: 1) the config's own `<PREFIX>1` block, 2) the family's "template"
  /// from ui_schema.json device_types, 3) a basic synthesized map.
  Map<String, dynamic> getDefaultDeviceBlock(String devicePrefix) {
    // Try to find an existing device of this type to use as a template (e.g. CAMERADEVICE_1)
    final templateKey = '${devicePrefix}1';
    if (roomConfig.containsKey(templateKey)) {
      return jsonDecode(jsonEncode(roomConfig[templateKey])); // Deep copy
    }

    // Schema-defined template for this family (device_types "template")
    final familyTemplate =
        uiSchema.deviceTypeForSection(templateKey)?.template;
    if (familyTemplate != null && familyTemplate.isNotEmpty) {
      return jsonDecode(jsonEncode(familyTemplate)); // Deep copy
    }

    // Synthesize a likely python module path based on the prefix (e.g. PROJECTORDEVICE_ -> modules.projectordevice)
    String cleanPrefix = devicePrefix.replaceAll('_', '').toLowerCase();
    
    // Fallback basic schema if no template is loaded
    return {
      "btn_name": "Btn_Con_${devicePrefix}X",
      "com_type": "Network",
      "host": "processor1",
      "gve_id": "${devicePrefix}X",
      "ip_address": "",
      "keep_alive_command": "",
      "keep_alive_interval": 30,
      "name": "New $devicePrefix",
      "module": "modules.$cleanPrefix", // <-- Triggers instant file loading
    };
  }

  /// Exports the pruned config.json using a user-prompted save dialog
  Future<bool> exportRoomConfig() async { // <-- UPDATED: Returns a bool for UI feedback
    if (roomConfig.isEmpty) {
      AppLogger.logError("Cannot export: Config is empty.");
      return false;
    }

    try {
      // Fetch details to generate a default file name
      final systemSetup = roomConfig['SYSTEM_SETUP'] ?? {};
      final gveBldg = systemSetup['gve_bldg'] ?? 'UNKNOWN_BLDG';
      final gveRoom = systemSetup['gve_room'] ?? 'UNKNOWN_ROOM';
      final defaultFileName = '${bldgAbbreviation(gveBldg.toString())}_${gveRoom}_config.json';

      // Prompt the user for a save location
      String? outputFile = await FilePicker.saveFile(
        dialogTitle: 'Save Room Configuration',
        fileName: defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      // User cancelled the picker
      if (outputFile == null) return false; 

      final targetFile = File(outputFile);
      final encoder = const JsonEncoder.withIndent('    ');
      
      // Clean out unused devices and sort keys before saving
      Map<String, dynamic> exportData = _pruneConfig(roomConfig);

      await targetFile.writeAsString(encoder.convert(_sortJson(exportData)));
      AppLogger.logInfo("Config successfully saved to ${targetFile.path}");

      // ADOPT AS WORKING FILE: exporting ties the saved file to the session
      // (a wizard-built config starts with no path at all), so later saves —
      // and the schematic's Save Layout sidecar — have somewhere to live.
      // The synced-path marker moves with it so the in-memory schematic
      // layout survives instead of being reset as a "different config".
      currentConfigPath = outputFile;
      _schematicSyncedPath = outputFile;
      notifyListeners();
      return true;

    } catch (e, stack) {
      AppLogger.logError("Failed to export room configuration", e, stack);
      return false;
    }
  }

  /// Updates the device count in SYSTEM_SETUP and generates/removes device blocks
  void setDeviceCount(String devKey, String devicePrefix, int count, Map<String, dynamic> defaultTemplateBlock) {
    if (!roomConfig.containsKey('SYSTEM_SETUP')) return;
    
    // Update the integer string in SYSTEM_SETUP (e.g., dev_cameras: "2")
    roomConfig['SYSTEM_SETUP'][devKey] = count.toString();

    // 1. Remove existing devices of this type to ensure a clean slate
    roomConfig.removeWhere((key, value) => key.startsWith(devicePrefix));

    // 2. Generate new blocks based on the count
    final List<String> newKeys = [];
    for (int i = 1; i <= count; i++) {
      String newDeviceKey = '$devicePrefix$i';
      
      // Deep copy the template block so they don't share memory references
      Map<String, dynamic> newDevice = jsonDecode(jsonEncode(defaultTemplateBlock));
      
      // Update specific enumerations inside the newly created block.
      // Guarded so a schema-provided template missing one of these keys
      // (device_types "template") doesn't produce "null" strings.
      _indexSubstitute(newDevice, newDeviceKey); // btn_name, gve_id trailing index
      if (newDevice['name'] != null) {
        newDevice['name'] = '${newDevice['name'].toString().split('-').first.trim()} $i - Custom Model';
      }

      // SCHEMA DEFAULTS (ui_schema.json "device_defaults"): make sure this
      // device type's baseline properties exist — e.g. projectors always
      // get input/relay_host, DSPs their audio group numbers. Values from
      // the template block always win; only missing keys are added.
      int addedDefaults = 0;
      uiSchema.defaultsFor(newDeviceKey).forEach((prop, defaultValue) {
        if (!newDevice.containsKey(prop)) {
          newDevice[prop] = defaultValue;
          addedDefaults++;
        }
      });
      if (addedDefaults > 0) {
        AppLogger.logInfo(
            "Applied $addedDefaults schema default(s) from device_defaults to $newDeviceKey");
      }

      roomConfig[newDeviceKey] = newDevice;
      newKeys.add(newDeviceKey);
    }
    
    notifyListeners();

    // 3. Immediately verify each new device's module against the .py file in
    // the modules folder and load a valid keep-alive command from it.
    // ignore: unawaited_futures
    _applyKeepAliveDefaults(newKeys);
  }

  /// The keep-alive command [deviceKey] should poll on [moduleName], or '' when
  /// the module's .py can't be parsed. Only commands the module actually
  /// defines are ever returned. Sources, in order of authority:
  ///   1. the module's own DEVICE_INFO keep_alive_command — the driver author
  ///      naming the right poll for this hardware (an IN1608 polls
  ///      'Temperature', not the switcher family's 'RefreshMatrix')
  ///   2. the family's schema preference list (device_types
  ///      "keepAlivePreference"), in order
  ///   3. 'Power', then anything containing 'power' (the typical Extron poll),
  ///      else the module's first command
  Future<String> _resolveKeepAliveCommand(
      String deviceKey, String moduleName) async {
    final commands = await getCommandsForModule(moduleName);
    if (commands.isEmpty) return '';

    String pick(String wanted) => commands.firstWhere(
          (c) => c.toLowerCase() == wanted.toLowerCase(),
          orElse: () => '',
        );

    final fromModule =
        moduleDefaultsFor(moduleName)?['keep_alive_command']?.toString() ?? '';
    if (fromModule.isNotEmpty) {
      final match = pick(fromModule);
      if (match.isNotEmpty) return match;
    }

    final family = uiSchema.deviceTypeForSection(deviceKey);
    for (final pref in family?.keepAlivePreference ?? const <String>[]) {
      final match = pick(pref);
      if (match.isNotEmpty) return match;
    }

    return commands.firstWhere(
      (c) => c == 'Power',
      orElse: () => commands.firstWhere(
        (c) => c.toLowerCase().contains('power'),
        orElse: () => commands.first,
      ),
    );
  }

  /// For freshly added devices: parses the module's .py file (instant when
  /// preloaded) and ensures keep_alive_command is a command that actually
  /// exists in that module — see [_resolveKeepAliveCommand] for the order the
  /// default is chosen in.
  Future<void> _applyKeepAliveDefaults(List<String> deviceKeys) async {
    bool changed = false;
    for (final key in deviceKeys) {
      final device = roomConfig[key];
      if (device is! Map) continue;
      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue;

      final commands = await getCommandsForModule(moduleName);
      if (commands.isEmpty) {
        // Module .py not found in the modules folder (or has no Update methods)
        AppLogger.logInfo("No matching .py commands for '$moduleName' on $key; keep-alive left as-is.");
        continue;
      }

      final current = device['keep_alive_command']?.toString() ?? '';
      if (current.isNotEmpty && commands.contains(current)) continue; // Already valid for this module

      final chosen = await _resolveKeepAliveCommand(key, moduleName);
      if (chosen.isEmpty) continue;
      device['keep_alive_command'] = chosen;
      changed = true;
      AppLogger.logInfo("Loaded keep_alive_command '$chosen' for $key from $moduleName.py");
    }
    if (changed) notifyListeners();
  }

  /// Load-time keep-alive audit, run after module resolution so every device
  /// has its .py to check against. A converted room inherits its keep-alive
  /// from the FAMILY default in key_map.json ('RefreshMatrix' for every
  /// switcher), which the specific model's module often doesn't implement — the
  /// device would then poll a command that doesn't exist. Any value the module
  /// doesn't define is replaced with the module's own default; values the
  /// module does define are left alone, so a deliberate site choice survives.
  /// Each change lands in systemLogs for the acknowledgement + change log.
  @visibleForTesting
  Future<void> validateKeepAliveCommands() async {
    for (final sectionKey in roomConfig.keys.toList()) {
      final device = roomConfig[sectionKey];
      if (device is! Map) continue;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) continue;
      if (!device.containsKey('keep_alive_command')) continue;

      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue; // already flagged by module resolution

      final commands = await getCommandsForModule(moduleName);
      if (commands.isEmpty) {
        systemLogs.add(
            "FLAGGED: '$sectionKey.keep_alive_command' could not be checked — "
            "no commands parsed from '$moduleName' (is the .py in the modules folder?).");
        continue;
      }

      final current = device['keep_alive_command']?.toString() ?? '';
      if (current.isNotEmpty && commands.contains(current)) continue;

      final chosen = await _resolveKeepAliveCommand(sectionKey, moduleName);
      if (chosen.isEmpty || chosen == current) continue;
      device['keep_alive_command'] = chosen;
      systemLogs.add(
          "MODULE: '$sectionKey.keep_alive_command' "
          "${current.isEmpty ? 'was empty' : "'$current' is not a command in '$moduleName'"} "
          "— set to '$chosen' from that module.");
    }
  }

  /// Config keys that are OPT-IN per room: the conversion must never turn them
  /// on, and anything that put them there gets undone. Section name -> the
  /// properties inside it.
  ///
  /// ENVIRONMENT.traceback_allowed is the case this exists for: it used to be
  /// injected as `true` into every converted room, which quietly switched full
  /// Python traceback reporting on for rooms nobody asked it for. The schema's
  /// section defaults no longer list that property, and this pass is the
  /// belt-and-braces half — whatever adds it (a stale ui_schema.json in the
  /// field, a template, a later schema edit), a room that didn't ask for it
  /// doesn't get it.
  ///
  /// The ENVIRONMENT block itself is NOT opt-in any more: the conversion adds
  /// it for controlscript_profile, which every room has to declare. Only the
  /// properties named here are stripped, so that injection survives.
  static const Map<String, List<String>> _optInProperties = {
    'ENVIRONMENT': ['traceback_allowed'],
  };

  /// Strips opt-in properties the loaded FILE did not carry, using the
  /// untouched parse in [_originalLoadedConfig] as the authority — so the test
  /// is "was this in the file the tech opened", not "is it in the config now".
  /// A room that really does set traceback_allowed keeps it (either value); the
  /// device report then states which way it is set.
  ///
  /// A section left empty by the strip is removed too, rather than exporting
  /// `"ENVIRONMENT": {}` to the processor. In practice the block now survives
  /// on its controlscript_profile — this only fires if that default is taken
  /// back out of the schema.
  ///
  /// [originalConfig] is the file as parsed; the load pipeline passes
  /// [_originalLoadedConfig].
  @visibleForTesting
  void removeUninvitedOptIns(Map<String, dynamic> originalConfig) {
    _optInProperties.forEach((sectionKey, properties) {
      final section = roomConfig[sectionKey];
      if (section is! Map) return;
      final original = originalConfig[sectionKey];
      final Map originalSection = original is Map ? original : const {};

      for (final key in properties) {
        if (!section.containsKey(key)) continue;
        if (originalSection.containsKey(key)) continue; // the file asked for it
        final removed = section.remove(key);
        systemLogs.add(
            "DEFAULTS: Removed '$sectionKey.$key' (was '$removed') — it is not "
            "in the loaded file and is opt-in per room, so the conversion "
            "leaves it off.");
      }

      if (section.isEmpty && !originalConfig.containsKey(sectionKey)) {
        roomConfig.remove(sectionKey);
        systemLogs.add(
            "DEFAULTS: Removed the now-empty '$sectionKey' section.");
      }
    });
  }

  /// `power<N>_outlet_<M>_action` in SYSTEM_SETUP, matched per outlet.
  static final RegExp _outletActionKey =
      RegExp(r'^(power\d+_outlet_\d+)_action$');

  /// Drops the outlet `_action` key, carrying a legacy 'Reboot' over to
  /// `_reboot_only` first so no outlet quietly stops cycling.
  ///
  /// An outlet's behaviour used to be spread over two keys that said the same
  /// thing from different ends: `_action: "Reboot"` drove the panel button, and
  /// `_reboot_only` drove the remote reboot listener. The processor merged them
  /// onto `_reboot_only` — one key for both callers — which leaves `_action` as
  /// a third spelling of a setting that already has one, and a way for a room
  /// to contradict itself. Two toggles are the whole story now:
  /// `_supports_reboot` and `_reboot_only`.
  ///
  /// The precedence here is the processor's, so a room behaves the same after
  /// the strip as before it: a `_reboot_only` the LOADED FILE declared (true OR
  /// false) wins, and `_action` only decides the outlet when the file left
  /// `_reboot_only` absent or null. A null `_action` is the template's
  /// placeholder rather than a decision, so it is dropped without comment.
  ///
  /// The file has to be the authority rather than [roomConfig], because by the
  /// time this runs the companion_keys rule in key_map.json has already given
  /// every outlet a `_reboot_only: false`. Judging against the working config
  /// would read the conversion's own default as the room's decision and quietly
  /// turn a legacy reboot-only outlet into an ordinary one — the same trap
  /// [removeUninvitedOptIns] takes [_originalLoadedConfig] to avoid.
  ///
  /// [originalConfig] is the file as parsed; the load pipeline passes
  /// [_originalLoadedConfig].
  @visibleForTesting
  void foldOutletActionIntoRebootOnly(Map<String, dynamic> originalConfig) {
    final setup = roomConfig['SYSTEM_SETUP'];
    if (setup is! Map) return;
    final originalSetup = originalConfig['SYSTEM_SETUP'];
    final Map fileSetup = originalSetup is Map ? originalSetup : const {};

    for (final rawKey in setup.keys.map((k) => k.toString()).toList()) {
      final match = _outletActionKey.firstMatch(rawKey);
      if (match == null) continue;

      final outlet = match.group(1)!;
      final action = setup.remove(rawKey);
      final bool wantsReboot =
          action.toString().trim().toLowerCase() == 'reboot';
      if (!wantsReboot) continue; // null / "Off" / anything else said nothing

      final rebootOnlyKey = '${outlet}_reboot_only';
      final declared = fileSetup[rebootOnlyKey];
      if (declared != null) {
        // The room itself already ruled on this outlet; say so when the two
        // disagreed rather than changing behaviour on the way past.
        if (declared != true) {
          systemLogs.add(
              "FLAGGED: '$rawKey' was 'Reboot' but the file also set "
              "'$rebootOnlyKey' to '$declared' — kept '$rebootOnlyKey', which "
              "is the key the processor reads. Removed '$rawKey'.");
        }
        continue;
      }

      setup[rebootOnlyKey] = true;
      systemLogs.add(
          "DEFAULTS: '$rawKey' was 'Reboot' — set '$rebootOnlyKey' to true and "
          "removed '$rawKey'. Reboot-only is one key now, read by both the "
          "panel button and the reboot listener.");
    }
  }

  /// Removes the config keys a device's module says its model doesn't use
  /// (DEVICE_INFO "omit"), run after module resolution so the module is known.
  ///
  /// This exists because the defaults that shape a device block are FAMILY
  /// -wide: key_map.json gives every SWITCHERDEVICE_* the seven `group_*` audio
  /// group numbers, and ui_schema.json does the same. That is right for a
  /// matrix acting as the room's audio hub and wrong for a plain scaler — an
  /// IN1608 ends up carrying audio group numbers nothing reads.
  ///
  /// Capability sniffing can't decide this: the IN1608 driver defines eight
  /// `UpdateGroup*` commands, so "does the module support groups" says yes for
  /// exactly the models that don't use them. Whether a model uses them is a
  /// deployment fact, so the module states it outright.
  ///
  /// Removals are logged (with the value) so they show in the acknowledgement
  /// and the change log rather than happening silently.
  @visibleForTesting
  void applyModuleOmissions() {
    for (final sectionKey in roomConfig.keys.toList()) {
      final device = roomConfig[sectionKey];
      if (device is! Map) continue;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) continue;

      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue;
      final patterns = moduleOmitsFor(moduleName);
      if (patterns.isEmpty) continue;

      for (final key in device.keys.map((k) => k.toString()).toList()) {
        // 'module' itself is what told us to do this — never strip it, and
        // leave the identity keys alone whatever a pattern says.
        if (key == 'module' || key == 'model') continue;
        if (!keyMatchesOmitPattern(key, patterns)) continue;
        final removed = device.remove(key);
        systemLogs.add(
            "DEFAULTS: Removed '$sectionKey.$key' (was '$removed') — "
            "'$moduleName' lists it as unused for this model.");
      }
    }
  }

  /// Load-time audit of every schema "module_states" field (today: a
  /// projector's `input`), run alongside the keep-alive check.
  ///
  /// These carry the same hazard: a converted room inherits the value from the
  /// FAMILY default in key_map.json — `input` = "HDBaseT" for every projector —
  /// and the specific model's module often doesn't implement that state, so the
  /// device would drive a port it doesn't have.
  ///
  /// Unlike the keep-alive, this only FLAGS. Which physical input the device is
  /// wired to is a site fact, not something the driver knows, so replacing it
  /// with the module's first state would be a guess that reads as a real
  /// setting. The tech gets the flag here, the red field on the device tab, and
  /// the choice: pick a state the module has, or add the missing one to it.
  @visibleForTesting
  Future<void> validateModuleStateFields() async {
    for (final sectionKey in roomConfig.keys.toList()) {
      final device = roomConfig[sectionKey];
      if (device is! Map) continue;
      if (uiSchema.deviceTypeForSection(sectionKey) == null) continue;

      final moduleName = device['module']?.toString() ?? '';
      if (moduleName.isEmpty) continue; // already flagged by module resolution

      for (final key in device.keys.map((k) => k.toString()).toList()) {
        final spec = uiSchema.specFor(key, sectionKey: sectionKey);
        if (spec?.type != 'module_states') continue;

        final current = device[key]?.toString() ?? '';
        if (current.isEmpty) continue;

        final command = spec!.moduleCommand ?? key;
        final states = await getStatesForModuleCommand(moduleName, command);
        // No states parsed at all: the module has no such command (or it can't
        // be read). That's a different problem from a wrong value, and the
        // field says so itself — don't cry wolf over every value here.
        if (states.isEmpty) continue;
        if (states.any((s) => s.toLowerCase() == current.toLowerCase())) {
          continue;
        }

        systemLogs.add(
            "FLAGGED: '$sectionKey.$key' is '$current', which is not a "
            "'$command' state in '$moduleName' — pick one of "
            "${states.join(', ')}, or add '$current' to the module.");
      }
    }
  }

  /// Internal helper to remove unused devices based on the `dev_` settings
  /// Logs a warning for every device family where MORE numbered blocks exist
  /// in the loaded config than the SYSTEM_SETUP dev_ count allows. This is
  /// informational only — counts are never changed automatically, because
  /// template files intentionally carry every possible block. It exists so a
  /// migrated legacy room (e.g. dev_projectors "1" with 4 projector blocks)
  /// doesn't silently lose blocks at export time.
  void _auditDeviceCounts() {
    final systemSetup = roomConfig['SYSTEM_SETUP'];
    if (systemSetup is! Map) return;

    // Families come from the UI schema's device_types (built-in list when
    // the file doesn't define any)
    final deviceMap = uiSchema.deviceCountMap;

    bool warned = false;
    deviceMap.forEach((countKey, prefix) {
      // Parse the configured count the same way pruning does
      final raw = systemSetup[countKey]?.toString().toLowerCase() ?? '';
      int count = raw == 'yes' ? 1 : (raw == 'no' ? 0 : (int.tryParse(raw) ?? 0));

      // Highest numbered block actually present in the config
      int highest = 0;
      for (final key in roomConfig.keys) {
        if (key.startsWith(prefix)) {
          final n = int.tryParse(key.substring(prefix.length)) ?? 0;
          if (n > highest) highest = n;
        }
      }

      if (highest > count) {
        systemLogs.add(
            "COUNT WARNING: $highest ${prefix}x blocks exist but $countKey is '$raw'. "
            "Blocks above $count are hidden in the tabs and PRUNED on export — "
            "raise the count in the Setup Wizard if this room really has them.");
        warned = true;
      }
    });
    if (warned) {
      systemLogs.add("--------------------------------------------------");
    }
  }

  /// Returns a copy of [node] with every object's keys sorted alphabetically
  /// (natural order, so PROJECTORDEVICE_2 sorts before PROJECTORDEVICE_10).
  /// Applied to every write/display path — the raw editor, Apply/save,
  /// Export, and SFTP upload — so config.json is always stored sorted.
  static dynamic _sortJson(dynamic node) {
    if (node is Map) {
      final keys = node.keys.map((k) => k.toString()).toList()
        ..sort(_naturalCompare);
      return <String, dynamic>{for (final k in keys) k: _sortJson(node[k])};
    }
    if (node is List) return node.map(_sortJson).toList();
    return node;
  }

  /// Case-insensitive compare that treats digit runs as numbers.
  static int _naturalCompare(String a, String b) {
    final re = RegExp(r'\d+|\D+');
    final aParts = re.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
    final bParts = re.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
    for (int i = 0; i < aParts.length && i < bParts.length; i++) {
      final an = int.tryParse(aParts[i]);
      final bn = int.tryParse(bParts[i]);
      final c = (an != null && bn != null)
          ? an.compareTo(bn)
          : aParts[i].compareTo(bParts[i]);
      if (c != 0) return c;
    }
    return aParts.length.compareTo(bParts.length);
  }

  Map<String, dynamic> _pruneConfig(Map<String, dynamic> configToPrune) {
    Map<String, dynamic> data = Map.from(configToPrune);

    // Families come from the UI schema's device_types (built-in list when
    // the file doesn't define any)
    final deviceMap = uiSchema.deviceCountMap;

    // FIX: the dev_ count keys live inside SYSTEM_SETUP, not at the config
    // root — the old root lookup meant pruning silently never happened.
    final systemSetup = data['SYSTEM_SETUP'];

    deviceMap.forEach((countKey, prefix) {
      // Prefer SYSTEM_SETUP, fall back to root for any legacy config layout
      dynamic countVal;
      if (systemSetup is Map && systemSetup.containsKey(countKey)) {
        countVal = systemSetup[countKey];
      } else if (data.containsKey(countKey)) {
        countVal = data[countKey];
      }

      if (countVal != null) {
        int count = 0;
        
        // Handle values like "Yes" in your dev_wireless setup
        if (countVal.toString().toLowerCase() == 'yes') {
          count = 1;
        } else {
          count = int.tryParse(countVal.toString()) ?? 0;
        }

        final keysToRemove = data.keys.where((k) {
          if (k.startsWith(prefix)) {
            int id = int.tryParse(k.replaceFirst(prefix, '')) ?? 999;
            return id > count; // Delete if the device ID exceeds the permitted count
          }
          return false;
        }).toList();
        for (var k in keysToRemove) {
          data.remove(k);
        }
      }
    });
    return data;
  }
}

/// Where a value in the working config came from. Drives the colouring in the
/// conversion preview and on the Devices / System tabs; the palette itself
/// lives in conversion_colors.dart.
enum ValueOrigin {
  /// Carried over from the file that was loaded, untouched — shown in ORANGE,
  /// because nobody has confirmed it against the current template yet.
  legacy,

  /// The key came from the loaded file but the conversion REWROTE the value:
  /// gve_bldg normalized to its building code, the module resolved from the
  /// model, the generated room name replacing the placeholder. Shown in TEAL —
  /// it is neither purely the old file's value nor purely the template's, and
  /// calling it "from the old file" (which is what the single orange used to
  /// say) points the tech at the wrong thing when they come to check it.
  changed,

  /// Written by the conversion from the template, the schema defaults or a
  /// lookup — shown in the theme's ordinary text colour.
  written,
}

/// What a conversion did to one property, so the preview can show it and the
/// user can reject it individually.
enum ConversionKind { added, removed, changed }

/// A single reversible change the conversion made, as shown in the preview.
///
/// [before] is the value in the loaded file (null when the key is new),
/// [after] the value now (null when the key was removed). Rejecting a change
/// puts [before] back; accepting leaves [after] in place.
class ConversionChange {
  final String section;
  final String key;
  final ConversionKind kind;
  final dynamic before;
  final dynamic after;

  /// Set when the property was dropped as invalid where it sat (an
  /// ip_address on a serial device) rather than merely superseded.
  final String? conflictReason;

  /// False once the user rejects it in the preview.
  bool accepted;

  ConversionChange({
    required this.section,
    required this.key,
    required this.kind,
    this.before,
    this.after,
    this.conflictReason,
    this.accepted = true,
  });

  String get id => '$section.$key';
  bool get isConflict => conflictReason != null;

  /// How the change reads in the preview list: 'SECTION.key', or just the name
  /// for a scalar sitting at the root of the file (which has no key).
  String get label => key.isEmpty ? section : '$section.$key';

  /// One-line summary for the preview list.
  String get description {
    String show(dynamic v) {
      if (v == null) return 'null';
      final s = v.toString();
      if (s.isEmpty) return '""';
      return s.length > 60 ? '${s.substring(0, 57)}...' : s;
    }

    switch (kind) {
      case ConversionKind.added:
        return 'Added — written as ${show(after)}';
      case ConversionKind.removed:
        return conflictReason != null
            ? 'Removed (${conflictReason!}) — was ${show(before)}'
            : 'Removed — was ${show(before)}';
      case ConversionKind.changed:
        return '${show(before)} → ${show(after)}';
    }
  }
}

/// One entry of the model registry: which python module a model name maps
/// to, whether that mapping came from an explicit DEVICE_INFO dict
/// (authoritative) or was only inferred from the driver's self.Models keys,
/// and which device-family tabs offer it (empty = every tab).
class ModelEntry {
  final String model;
  final String module;
  final bool explicit;

  /// Raw "device_type" strings from DEVICE_INFO (e.g. 'projector',
  /// 'display'); matched against the ui_schema families at filter time.
  final List<String> deviceTypes;

  const ModelEntry(
      {required this.model,
      required this.module,
      required this.explicit,
      this.deviceTypes = const []});
}

/// The result of AppStateProvider.previewModelSelection: what selecting a
/// model would do, computed without mutating the config, so the view can ask
/// the user whether to apply the module defaults or keep the current settings.
class ModelChangePreview {
  /// True when the model is claimed by a module in the registry.
  final bool known;

  /// The module the selected model maps to ('' when unknown).
  final String newModule;

  /// True when applying would switch the device to a different module.
  final bool moduleChanged;

  /// The module's DEVICE_INFO defaults resolved for this device (trailing
  /// index substituted; site-specific blanks kept). Excludes model/module.
  final Map<String, dynamic> resolvedDefaults;

  /// Fields whose current value differs from the resolved module default.
  final List<FieldDiff> diffs;

  const ModelChangePreview({
    required this.known,
    required this.newModule,
    required this.moduleChanged,
    required this.resolvedDefaults,
    required this.diffs,
  });
}

/// One field that differs between a device's current value and the module
/// default, listed in the Model-change dialog.
class FieldDiff {
  final String key;
  final dynamic current;
  final dynamic moduleDefault;
  const FieldDiff(
      {required this.key, required this.current, required this.moduleDefault});
}