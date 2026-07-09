import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'config_dictionary.dart';
import 'config_key_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  // ---------------------------------------------------------------------
  //  DEFAULT PATH RESOLUTION
  //  Every external file falls back to the Root Folder when no explicit
  //  path has been chosen in App Config. The Root Folder itself falls back
  //  to the app's working directory. Python modules default to the
  //  "devices" sub-folder of the root. The UI should always read these
  //  effective* getters instead of the raw fields.
  // ---------------------------------------------------------------------

  /// Root Folder setting, falling back to the app's working directory.
  String get effectiveRootFolder =>
      rootFolderPath.isNotEmpty ? rootFolderPath : Directory.current.path;

  /// Python modules folder: explicit choice, else "<root>/devices".
  String get effectiveModulesPath => modulesPath.isNotEmpty
      ? modulesPath
      : path.join(effectiveRootFolder, 'devices');

  /// processors.json: explicit choice, else "<root>/processors.json".
  String get effectiveProcessorsFilePath => processorsFilePath.isNotEmpty
      ? processorsFilePath
      : path.join(effectiveRootFolder, 'processors.json');

  /// buildings.json: explicit choice, else "<root>/buildings.json".
  String get effectiveBuildingsFilePath => buildingsFilePath.isNotEmpty
      ? buildingsFilePath
      : path.join(effectiveRootFolder, 'buildings.json');

  /// Template config: explicit choice, else "<root>/config.json".
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
  bool isDarkMode = true;
  List<String> systemLogs = []; // NEW: Store user-facing session logs
  
  // Cache for parsed python module commands to prevent repetitive disk I/O
  final Map<String, List<String>> _moduleCommandsCache = {};
  // Cache for parsed python module inputs (previously re-read from disk on every rebuild)
  final Map<String, List<String>> _moduleInputsCache = {};
  // All python modules discovered under modulesPath (dot notation), for the
  // module selection dropdown/autocomplete on device tabs.
  List<String> availableModules = [];

  /// Attempts to find commonly named inputs inside the Python module for the autocomplete field
  Future<List<String>> getInputsForModule(String moduleFileName) async {
    final relativePath = '${moduleFileName.replaceAll('.', path.separator)}.py';
    final fullPath = path.join(effectiveModulesPath, relativePath);

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
      final RegExp inputRegex = RegExp(r"['""](HDMI\s*\d*|HDBaseT|VGA|DisplayPort|DVI|SDI|Composite|Component|Video\s*\d*|RGB|Type-C|USB-C)['""]", caseSensitive: false);
      
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

      // 1. Clean out unused devices and format as a clean JSON string
      Map<String, dynamic> exportData = _pruneConfig(roomConfig);
      final encoder = const JsonEncoder.withIndent('    ');
      final jsonString = encoder.convert(exportData);

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
        remoteFilename: '/config.json', // The target path on the Extron processor
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
  AppStateProvider() {
    _loadSavedSettings();
  }

  /// Loads saved paths from the OS. No longer auto-loads the config.
  Future<void> _loadSavedSettings() async {
    await Future.delayed(const Duration(milliseconds: 200));

    try {
      final prefs = await SharedPreferences.getInstance();
      
      modulesPath = prefs.getString('modulesPath') ?? '';
      processorsFilePath = prefs.getString('processorsFilePath') ?? '';
      rootFolderPath = prefs.getString('rootFolderPath') ?? '';
      buildingsFilePath = prefs.getString('buildingsFilePath') ?? '';
      templateFilePath = prefs.getString('templateFilePath') ?? ''; // FIX: was never restored, so the default config path reset on every restart
      uiSchemaPath = prefs.getString('uiSchemaPath') ?? '';
      keyMapPath = prefs.getString('keyMapPath') ?? '';
      isDarkMode = prefs.getBool('isDarkMode') ?? true;

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
        remoteFilename: '/config.json',
        outputPath: tempPath,
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

    // Auto-generate the Title Case full room name when gve_bldg (full name OR
    // legacy abbreviation like 'BSS') resolves against buildings.json — so a
    // converted legacy file lands with 'Behavioral and Social Sciences 103'
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

    // Warn (never auto-change) when more device blocks exist than the dev_
    // counts allow — extra blocks are hidden in tabs and pruned on export,
    // which is normal for templates but surprising for migrated legacy rooms.
    _auditDeviceCounts();

    // Flag anything in the loaded config that does not exist in the default template
    final template = await _readDefaultTemplate();
    if (template != null) {
      _flagUnknownKeys(template);
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
        l.startsWith('COUNT WARNING') ||
        l.startsWith('AUTO-NAME'));
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
  void _flagUnknownKeys(Map<String, dynamic> templateConfig) {
    // Strip trailing digits so PROJECTORDEVICE_2 compares against PROJECTORDEVICE_1
    String normalize(String key) => key.replaceFirst(RegExp(r'\d+$'), '');
    final Set<String> templateFamilies = templateConfig.keys.map(normalize).toSet();
    int flagged = 0;

    // 1. Top-level sections unknown to the template
    roomConfig.forEach((key, value) {
      if (!templateFamilies.contains(normalize(key))) {
        systemLogs.add("FLAGGED: Section '$key' does not exist in the default config template.");
        flagged++;
      }
    });

    // 2. SYSTEM_SETUP properties unknown to the template
    if (roomConfig['SYSTEM_SETUP'] is Map && templateConfig['SYSTEM_SETUP'] is Map) {
      final tplSetup = templateConfig['SYSTEM_SETUP'] as Map;
      (roomConfig['SYSTEM_SETUP'] as Map).forEach((key, value) {
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

  /// Scans the loaded configuration against baseline defaults and patches missing keys.
  void _validateAndMigrateConfig() {
    // If SYSTEM_SETUP is entirely missing, create it
    if (!roomConfig.containsKey('SYSTEM_SETUP')) {
      roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};
      systemLogs.add("CRITICAL: Added missing 'SYSTEM_SETUP' root block.");
    }

    final systemSetup = roomConfig['SYSTEM_SETUP'] as Map<String, dynamic>;

    // Define the baseline schema needed for the current template to function
    final Map<String, dynamic> baselineDefaults = {
      "gve_bldg": "UNKNOWN",
      "gve_room": "000",
      "gui_full_room_name": "Legacy Room Update",
      "dev_projectors": "0",
      "dev_cameras": "0",
      "dev_switchers": "0",
      "dev_dsps": "0",
      "dev_usb_switchers": "0",
      "dev_media_ports": "0",
      "dev_wireless": "0",
      "dev_recorders": "0",
      "dev_screens": "0",
      "dev_power_controllers": "0",
      "gui_mic_mix": "No",
      "gui_routing_available": "No",
      "gui_routing_mode": "Normal",
      "gui_tab": "2_Cam_Dev",
      "gui_capture_source_available": "No",
      "gui_usb_or_vga": "USB",
    };

    int additions = 0;

    // Check existing keys against the baseline
    baselineDefaults.forEach((key, defaultValue) {
      if (!systemSetup.containsKey(key)) {
        systemSetup[key] = defaultValue;
        systemLogs.add("-> Added missing property: '$key' (Default: '$defaultValue')");
        additions++;
      }
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

      // Default all hardware counts to 0
      if (roomConfig.containsKey('SYSTEM_SETUP')) {
        final setup = roomConfig['SYSTEM_SETUP'];
        final deviceKeys = [
          'dev_projectors', 'dev_cameras', 'dev_switchers', 'dev_dsps', 
          'dev_usb_switchers', 'dev_media_ports', 'dev_wireless', 
          'dev_recorders', 'dev_screens', 'dev_power_controllers'
        ];
        
        for (var key in deviceKeys) {
          if (setup.containsKey(key)) {
            setup[key] = "0";
          }
        }
      }

      // Prune existing devices based on the new 0 counts
      roomConfig = _pruneConfig(roomConfig);
      
      _preloadModulesFromConfig(); // Warm the parser caches for referenced modules
      notifyListeners();
      AppLogger.logInfo("New config created from template: $baseConfigPath");
      return true;
    } catch (e, stack) {
      AppLogger.logError("Failed to create new config", e, stack);
      return false;
    }
  }

  /// Updates a setting in memory and saves it to the OS simultaneously
  Future<void> updateSetting(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);

    switch (key) {
      case 'modulesPath': 
        modulesPath = value; 
        // Path changed: stale caches are invalid; rebuild them in the background
        _moduleCommandsCache.clear();
        _moduleInputsCache.clear();
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
    }
    notifyListeners();
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
      await updateSetting('templateFilePath', templatePath); // persists to SharedPreferences
      AppLogger.logInfo("Template validated and set as default: $templatePath");
      return true;
    } catch (e, stack) {
      AppLogger.logError("Error validating config template (invalid JSON?)", e, stack);
      return false;
    }
  }

  /// Loads the buildings.json file to resolve building names. Falls back to
  /// "<root>/buildings.json" when no explicit path has been chosen.
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
  /// gve_bldg stores the ALL CAPS building name from buildings.json, while the
  /// generated full room name is Title Case ('Arts & Humanities Building 208').
  /// If the building is not in buildings.json, the name is left untouched so
  /// the user can type the full room name manually in the wizard.
  void updateFullRoomName() {
    if (roomConfig.containsKey('SYSTEM_SETUP')) {
      String bldgValue = roomConfig['SYSTEM_SETUP']['gve_bldg'] ?? '';
      String roomNum = roomConfig['SYSTEM_SETUP']['gve_room'] ?? '';
      
      // Resolve the ALL CAPS full name: gve_bldg may hold the full name (new
      // style) or a legacy abbreviation (older configs). Longest key wins when
      // several names share one code, matching the wizard's dedupe rule.
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
  /// dropdown. Runs on boot; falls back to "<root>/processors.json" when no
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

  // Toggle theme and save to OS preferences
  Future<void> toggleTheme() async {
    isDarkMode = !isDarkMode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', isDarkMode);
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

  /// Parses an Extron Python module file to extract valid keep-alive commands.
  Future<List<String>> getCommandsForModule(String moduleFileName) async {
    // Construct the full local path based on the app settings and the json module string
    final relativePath = '${moduleFileName.replaceAll('.', path.separator)}.py';
    final fullPath = path.join(effectiveModulesPath, relativePath);

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
  /// "Whiteboard<CR>Left" -> "Whiteboard\\rLeft" in config.json). Lone \n is
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
      await File(currentConfigPath).writeAsString(encoder.convert(roomConfig));
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
    return encoder.convert(_pruneConfig(roomConfig));
  }

  /// Helper to grab a default template for a device if the user increases the count
  /// Falls back to a basic map if a template (like PROJECTORDEVICE_1) isn't loaded.
  /// Synthesizes a module path to instantly trigger Python parsing.
  Map<String, dynamic> getDefaultDeviceBlock(String devicePrefix) {
    // Try to find an existing device of this type to use as a template (e.g. CAMERADEVICE_1)
    final templateKey = '${devicePrefix}1';
    if (roomConfig.containsKey(templateKey)) {
      return jsonDecode(jsonEncode(roomConfig[templateKey])); // Deep copy
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
      
      // Clean out unused devices before saving
      Map<String, dynamic> exportData = _pruneConfig(roomConfig);
      
      await targetFile.writeAsString(encoder.convert(exportData));
      AppLogger.logInfo("Config successfully saved to ${targetFile.path}");
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
      
      // Update specific enumerations inside the newly created block
      newDevice['btn_name'] = newDevice['btn_name'].toString().replaceFirst(RegExp(r'\d+$'), '$i');
      newDevice['gve_id'] = newDevice['gve_id'].toString().replaceFirst(RegExp(r'\d+$'), '$i');
      newDevice['name'] = '${newDevice['name'].split('-').first.trim()} $i - Custom Model';
      
      roomConfig[newDeviceKey] = newDevice;
      newKeys.add(newDeviceKey);
    }
    
    notifyListeners();

    // 3. Immediately verify each new device's module against the .py file in
    // the modules folder and load a valid keep-alive command from it.
    // ignore: unawaited_futures
    _applyKeepAliveDefaults(newKeys);
  }

  /// For freshly added devices: parses the module's .py file (instant when
  /// preloaded) and ensures keep_alive_command is a command that actually
  /// exists in that module. Prefers 'Power'-style commands as the default.
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

      // Load a sensible default from the module: 'Power' if it exists, then
      // anything containing 'power' (typical Extron poll), else the first command.
      final chosen = commands.firstWhere(
        (c) => c == 'Power',
        orElse: () => commands.firstWhere(
          (c) => c.toLowerCase().contains('power'),
          orElse: () => commands.first,
        ),
      );
      device['keep_alive_command'] = chosen;
      changed = true;
      AppLogger.logInfo("Loaded keep_alive_command '$chosen' for $key from $moduleName.py");
    }
    if (changed) notifyListeners();
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

    final deviceMap = {
      'dev_projectors': 'PROJECTORDEVICE_',
      'dev_cameras': 'CAMERADEVICE_',
      'dev_switchers': 'SWITCHERDEVICE_',
      'dev_dsps': 'DSPDEVICE_',
      'dev_usb_switchers': 'USBDEVICE_',
      'dev_media_ports': 'MEDIAPORTDEVICE_',
      'dev_wireless': 'WIRELESSDEVICE_',
      'dev_recorders': 'RECORDERDEVICE_',
      'dev_screens': 'SCREENDEVICE_',
      'dev_power_controllers': 'POWERDEVICE_',
    };

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

  Map<String, dynamic> _pruneConfig(Map<String, dynamic> configToPrune) {
    Map<String, dynamic> data = Map.from(configToPrune);
    
    // Add requested hardware prefixes based on the config.json template if new devices added
    final deviceMap = {
      'dev_projectors': 'PROJECTORDEVICE_',
      'dev_cameras': 'CAMERADEVICE_',
      'dev_switchers': 'SWITCHERDEVICE_',
      'dev_dsps': 'DSPDEVICE_',
      'dev_usb_switchers': 'USBDEVICE_',
      'dev_media_ports': 'MEDIAPORTDEVICE_',
      'dev_wireless': 'WIRELESSDEVICE_',
      'dev_recorders': 'RECORDERDEVICE_',
      'dev_screens': 'SCREENDEVICE_',
      'dev_power_controllers': 'POWERDEVICE_',
    };

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
        for (var k in keysToRemove) data.remove(k);
      }
    });
    return data;
  }
}