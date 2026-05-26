import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path; // Add 'path: ^1.8.3' to pubspec.yaml
import 'app_logger.dart';

/// Core State Manager for the Room Configuration Application
class AppStateProvider extends ChangeNotifier {
  // --- Application Paths & Settings ---
  String modulesPath = '';
  String processorsFilePath = '';
  String rootFolderPath = ''; 
  String buildingsFilePath = '';
  
  // --- Data State ---
  List<dynamic> processors = [];
  Map<String, dynamic> buildings = {}; // NEW: Store building abbreviations
  Map<String, dynamic>? selectedProcessor;
  Map<String, dynamic> roomConfig = {};
  
  // Cache for parsed python module commands to prevent repetitive disk I/O
  final Map<String, List<String>> _moduleCommandsCache = {};

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

      roomConfig['SYSTEM_SETUP']['gui_full_room_name'] = '$fullBldgName $roomNum'.trim();
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

  /// Sets the active room context
  void selectProcessor(Map<String, dynamic> processor) {
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
    // e.g., 'modules.device.epsn_vp_Powerlite' -> 'modules/device/epsn_vp_Powerlite.py'
    final relativePath = '${moduleFileName.replaceAll('.', path.separator)}.py';
    final fullPath = path.join(modulesPath, relativePath);

    if (_moduleCommandsCache.containsKey(fullPath)) {
      return _moduleCommandsCache[fullPath]!;
    }

    try {
      final file = File(fullPath);
      if (!await file.exists()) return [];
      
      final content = await file.readAsString();
      
      // Regex to find python methods that start with "Update" (e.g., def UpdatePower(self...))
      final updateMethodRegExp = RegExp(r"def\s+Update([A-Za-z0-9_]+)\s*\(");
      final commands = <String>[];

      for (final match in updateMethodRegExp.allMatches(content)) {
        final cmd = match.group(1);
        if (cmd != null) {
          commands.add(cmd); // e.g., grabs 'Power' from 'def UpdatePower'
        }
      }

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
  Map<String, dynamic> getDefaultDeviceBlock(String devicePrefix) {
    // Try to find an existing device of this type to use as a template (e.g. CAMERADEVICE_1)
    final templateKey = '${devicePrefix}1';
    if (roomConfig.containsKey(templateKey)) {
      return jsonDecode(jsonEncode(roomConfig[templateKey])); // Deep copy
    }
    
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
    };
  }

  /// Exports the pruned config.json to the correct folder structure
  Future<void> exportRoomConfig() async {
    if (selectedProcessor == null || rootFolderPath.isEmpty) {
      AppLogger.logError("Cannot export: Missing processor selection or root folder path.");
      return;
    }

    try {
      // Fetch details directly from SYSTEM_SETUP
      final systemSetup = roomConfig['SYSTEM_SETUP'] ?? {};
      final gveBldg = systemSetup['gve_bldg'] ?? 'UNKNOWN_BLDG';
      final gveRoom = systemSetup['gve_room'] ?? 'UNKNOWN_ROOM';

      // Construct output path: Root\rooms\gve_bldg\gve_room\code\
      final targetDirectory = Directory(path.join(rootFolderPath, 'rooms', gveBldg, gveRoom, 'code'));

      if (!await targetDirectory.exists()) {
        await targetDirectory.create(recursive: true);
      }

      final targetFile = File(path.join(targetDirectory.path, 'config.json'));
      final encoder = JsonEncoder.withIndent('    ');
      
      // Clean out unused devices before saving
      Map<String, dynamic> exportData = _pruneConfig(roomConfig);
      
      await targetFile.writeAsString(encoder.convert(exportData));
      AppLogger.logInfo("Config successfully saved to ${targetFile.path}");

    } catch (e, stack) {
      AppLogger.logError("Failed to export room configuration", e, stack);
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
    final deviceMap = {
      'dev_projectors': 'PROJECTORDEVICE_',
      'dev_cameras': 'CAMERADEVICE_',
      'dev_switchers': 'SWITCHERDEVICE_',
      'dev_dsps': 'DSPDEVICE_',
      'dev_usb_switchers': 'USBDEVICE_',
    };

    deviceMap.forEach((countKey, prefix) {
      if (data.containsKey(countKey)) {
        int count = int.tryParse(data[countKey].toString()) ?? 0;
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