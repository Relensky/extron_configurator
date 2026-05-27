import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sftp_client.dart';
import 'package:file_picker/file_picker.dart';

/// Core State Manager for the Room Configuration Application
class AppStateProvider extends ChangeNotifier {
  // --- Application Paths & Settings ---
  String modulesPath = '';
  String processorsFilePath = '';
  String rootFolderPath = ''; 
  String buildingsFilePath = '';
  String templateFilePath = '';
  
  // --- Data State ---
  List<dynamic> processors = [];
  Map<String, dynamic> buildings = {}; // NEW: Store building abbreviations
  Map<String, dynamic>? selectedProcessor;
  Map<String, dynamic> roomConfig = {};
  bool isDarkMode = true;
  List<String> systemLogs = []; // NEW: Store user-facing session logs
  
  // Cache for parsed python module commands to prevent repetitive disk I/O
  final Map<String, List<String>> _moduleCommandsCache = {};

  /// Attempts to find commonly named inputs inside the Python module for the autocomplete field
  Future<List<String>> getInputsForModule(String moduleFileName) async {
    final relativePath = '${moduleFileName.replaceAll('.', path.separator)}.py';
    final fullPath = path.join(modulesPath, relativePath);

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
      
      if (inputs.isEmpty) return ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT', 'DisplayPort'];
      return inputs.toList()..sort();
    } catch (e) {
      return ['HDMI 1', 'HDMI 2', 'VGA', 'HDBaseT'];
    }
  }

  Future<bool> uploadConfigToProcessor({
    required String ipAddress,
    required String password,
    required Function(String) onStatusUpdate,
  }) async {
    if (roomConfig.isEmpty) {
      onStatusUpdate("Error: No configuration loaded to upload.");
      return false;
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
      final success = await sftpClient.uploadFileToProcessor(
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
      isDarkMode = prefs.getBool('isDarkMode') ?? true;

      // Load files into memory safely
      if (buildingsFilePath.isNotEmpty) await loadBuildingsList();
      if (processorsFilePath.isNotEmpty) await loadProcessorsList();

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
        systemLogs.clear(); // Clear old logs on new load

        final file = File(result.files.single.path!);
        final originalContents = await file.readAsString();
        final Map<String, dynamic> parsedConfig = jsonDecode(originalContents);

        // --- AUTOMATIC BACKUP LOGIC ---
        try {
          // Extract identifiers for the filename
          String bldg = "UNKNOWN";
          String room = "000";
          if (parsedConfig.containsKey('SYSTEM_SETUP')) {
            bldg = parsedConfig['SYSTEM_SETUP']['gve_bldg']?.toString() ?? "UNKNOWN";
            room = parsedConfig['SYSTEM_SETUP']['gve_room']?.toString() ?? "000";
          }

          // Build the path: Save it in the exact same folder they opened it from
          final backupFileName = '${bldg}_${room}_old_config.json';
          final directoryPath = file.parent.path;
          final backupFilePath = path.join(directoryPath, backupFileName);
          final backupFile = File(backupFilePath);

          // Write the exact original string to disk so no formatting is lost
          await backupFile.writeAsString(originalContents);
          
          AppLogger.logInfo("Created backup of legacy config at $backupFilePath");
          systemLogs.add("BACKUP SAVED: Original file preserved as '$backupFileName'");
          systemLogs.add("--------------------------------------------------");
          
        } catch (backupError) {
          AppLogger.logError("Failed to create backup file", backupError);
          systemLogs.add("WARNING: Failed to generate local backup file.");
        }
        // ------------------------------

        roomConfig = parsedConfig;
        
        // Check for missing keys and patch them
        _validateAndMigrateConfig();
        
        notifyListeners();
        AppLogger.logInfo("Loaded existing config from ${file.path}");
        return true;
      }
      return false;
    } catch (e, stack) {
      AppLogger.logError("Failed to load existing config", e, stack);
      return false;
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
    }
  }

  /// Creates a new config from the base config.json in the root folder, setting devices to 0.
  Future<bool> createNewConfig() async {
    if (rootFolderPath.isEmpty) {
      AppLogger.logError("Cannot create new config: Root Folder Path is not set.");
      return false;
    }

    try {
      final baseConfigPath = path.join(rootFolderPath, 'config.json');
      final file = File(baseConfigPath);
      
      if (!await file.exists()) {
        AppLogger.logError("Base config.json not found in $rootFolderPath");
        return false;
      }

      final contents = await file.readAsString();
      roomConfig = jsonDecode(contents);

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
      
      notifyListeners();
      AppLogger.logInfo("New config created from base template.");
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
        break;
      case 'processorsFilePath': 
        processorsFilePath = value; 
        break;
      case 'rootFolderPath': 
        rootFolderPath = value; 
        break;
      case 'buildingsFilePath': 
        buildingsFilePath = value; 
        break;
      case 'templateFilePath': 
        templateFilePath = value; 
        break;
    }
    notifyListeners();
  }

  /// Loads the initial config.json template into memory
  Future<void> loadConfigTemplate(String templatePath) async {
    try {
      final file = File(templatePath);
      if (await file.exists()) {
        final contents = await file.readAsString();
        roomConfig = jsonDecode(contents);
        notifyListeners();
        AppLogger.logInfo("Template loaded from $templatePath");
      }
    } catch (e, stack) {
      AppLogger.logError("Error loading config template", e, stack);
    }
  }

  /// Loads the buildings.json file to resolve building names
  Future<void> loadBuildingsList() async {
    if (buildingsFilePath.isEmpty) return;
    try {
      final file = File(buildingsFilePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        buildings = jsonDecode(content);
        notifyListeners();
        AppLogger.logInfo("Buildings list loaded from $buildingsFilePath");
      }
    } catch (e, stack) {
      AppLogger.logError("Failed to load buildings.json", e, stack);
    }
  }

  /// Helper method to convert a string to Title Case (e.g., "arts and humanities" -> "Arts And Humanities")
  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    return text.split(' ').map((word) {
      if (word.isEmpty) return word;
      // You can expand this logic to skip small words like 'and', 'the', 'of' if preferred
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  /// Automatically updates the gui_full_room_name in SYSTEM_SETUP
  void updateFullRoomName() {
    if (roomConfig.containsKey('SYSTEM_SETUP')) {
      String bldgCode = roomConfig['SYSTEM_SETUP']['gve_bldg'] ?? '';
      String roomNum = roomConfig['SYSTEM_SETUP']['gve_room'] ?? '';
      
      // Find the full building name from the JSON keys matching the value
      String fullBldgName = bldgCode;
      buildings.forEach((key, value) {
        if (value == bldgCode) fullBldgName = key;
      });

      // Apply the Title Case formatting
      String titleCaseBldgName = _toTitleCase(fullBldgName);

      roomConfig['SYSTEM_SETUP']['gui_full_room_name'] = '$titleCaseBldgName $roomNum'.trim();
      notifyListeners();
    }
  }

  /// Loads the external processors.json file to populate the room selection dropdown
  Future<void> loadProcessorsList() async {
    if (processorsFilePath.isEmpty) return;
    try {
      final file = File(processorsFilePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        processors = jsonDecode(content);
        notifyListeners();
        AppLogger.logInfo("Processors list loaded from $processorsFilePath");
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
  /// Update a specific nested property for a device (e.g., changing keep_alive_command)
  void updateDeviceValue(String deviceKey, String property, dynamic value) {
    if (roomConfig.containsKey(deviceKey)) {
      roomConfig[deviceKey][property] = value;
      notifyListeners();
    }
  }

  /// Parses an Extron Python module file to extract valid keep-alive commands.
  Future<List<String>> getCommandsForModule(String moduleFileName) async {
    // Construct the full local path based on the app settings and the json module string
    final relativePath = '${moduleFileName.replaceAll('.', path.separator)}.py';
    final fullPath = path.join(modulesPath, relativePath);

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
      roomConfig = parsed;
      notifyListeners();
      AppLogger.logInfo("Room configuration updated from raw JSON editor.");
    } catch (e, stack) {
      AppLogger.logError("Failed to parse raw JSON from editor", e, stack);
      rethrow; // Pass error to UI for user feedback
    }
  }

  /// Returns a formatted JSON string of the current config for the editor
  String getPrettyConfigString() {
    if (roomConfig.isEmpty) return "{}";
    final encoder = const JsonEncoder.withIndent('    ');
    return encoder.convert(roomConfig);
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
      final defaultFileName = '${gveBldg}_${gveRoom}_config.json';

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
    for (int i = 1; i <= count; i++) {
      String newDeviceKey = '$devicePrefix$i';
      
      // Deep copy the template block so they don't share memory references
      Map<String, dynamic> newDevice = jsonDecode(jsonEncode(defaultTemplateBlock));
      
      // Update specific enumerations inside the newly created block
      newDevice['btn_name'] = newDevice['btn_name'].toString().replaceFirst(RegExp(r'\d+$'), '$i');
      newDevice['gve_id'] = newDevice['gve_id'].toString().replaceFirst(RegExp(r'\d+$'), '$i');
      newDevice['name'] = '${newDevice['name'].split('-').first.trim()} $i - Custom Model';
      
      roomConfig[newDeviceKey] = newDevice;
    }
    
    notifyListeners();
  }

  /// Internal helper to remove unused devices based on the `dev_` settings
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

    deviceMap.forEach((countKey, prefix) {
      if (data.containsKey(countKey)) {
        var countVal = data[countKey];
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