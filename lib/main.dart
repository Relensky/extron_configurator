import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'dynamic_devices_view.dart';
import 'setup_wizard_view.dart';
import 'json_editor_view.dart';
import 'system_settings_view.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppStateProvider(),
      child: const RoomConfigApp(),
    ),
  );
}

class RoomConfigApp extends StatelessWidget {
  const RoomConfigApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();

    return MaterialApp(
      title: 'Deployment Configurator',
      theme: provider.isDarkMode ? ThemeData.dark() : ThemeData.light(),
      home: const MainDashboard(),
    );
  }
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({Key? key}) : super(key: key);

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final hasConfig = provider.roomConfig.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Room Config Builder'),
        actions: [
          IconButton(
            icon: Icon(provider.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            tooltip: 'Toggle Theme',
            onPressed: () => provider.toggleTheme(),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Open Existing Config',
            onPressed: () async {
              bool loaded = await provider.loadExistingConfig();
              if (loaded && provider.systemLogs.isNotEmpty && context.mounted) {
                _showMigrationLogDialog(context, provider.systemLogs);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.cloud_download),
            tooltip: 'Download config.json from Processor (SFTP)',
            onPressed: () async {
              final result = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (context) => const ProcessorSftpDialog(isUpload: false),
              );
              // On a successful download, show the migration/audit log like a local load does
              if (result == true && provider.systemLogs.isNotEmpty && context.mounted) {
                _showMigrationLogDialog(context, provider.systemLogs);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            tooltip: 'Upload to Processor (SFTP)',
            onPressed: () {
              showDialog(
                context: context,
                barrierDismissible: false, 
                builder: (context) => const ProcessorSftpDialog(isUpload: true),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Export Config Locally',
            onPressed: () async {
              bool saved = await provider.exportRoomConfig();
              if (saved && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Config saved successfully!'))
                );
              }
            },
          )
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() => _selectedIndex = index);
            },
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.auto_awesome), label: Text('Wizard')),
              NavigationRailDestination(icon: Icon(Icons.router), label: Text('Devices')),
              NavigationRailDestination(icon: Icon(Icons.settings), label: Text('System')),
              NavigationRailDestination(icon: Icon(Icons.data_object), label: Text('Raw JSON')),
              NavigationRailDestination(icon: Icon(Icons.build_circle), label: Text('App Config')),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: (!hasConfig && _selectedIndex != 4) ? _buildLandingScreen(context, provider) : _buildMainContent(),
          )
        ],
      ),
    );
  }

  Widget _buildLandingScreen(BuildContext context, AppStateProvider provider) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.account_tree, size: 80, color: Theme.of(context).disabledColor),
          const SizedBox(height: 24),
          Text("No Configuration Loaded", style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 60,
                width: 250,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add_box),
                  label: const Text("Create New Config\n(From default template)", textAlign: TextAlign.center),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white, // Forces readable text in light mode
                  ),
                  onPressed: () async {
                    // Needs either a validated template file OR a root folder with config.json
                    if (provider.templateFilePath.isEmpty && provider.rootFolderPath.isEmpty) {
                       setState(() => _selectedIndex = 4); // Route to App Config
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Please set a Template file or Root Path first (App Config tab)."), backgroundColor: Colors.red)
                        );
                    } else {
                      bool success = await provider.createNewConfig();
                      if (!success && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Failed to load the template config.json."), backgroundColor: Colors.red)
                        );
                      }
                    }
                  },
                ),
              ),
              const SizedBox(width: 20),
              SizedBox(
                height: 60,
                width: 250,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text("Open Existing Config"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade700,
                    foregroundColor: Colors.white, // Forces readable text in light mode
                  ),
                  onPressed: () async {
                    bool loaded = await provider.loadExistingConfig();
                    if (loaded && provider.systemLogs.isNotEmpty && context.mounted) {
                      _showMigrationLogDialog(context, provider.systemLogs);
                    }
                  },
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    switch (_selectedIndex) {
      case 0:
        return const SetupWizardView(); 
      case 1:
        return const DynamicDevicesTabsView(); 
      case 2:
        return const SystemSettingsView();
      case 3:
        return const JsonEditorView();
      case 4:
        return const AppSettingsView();
      default:
        return const Center(child: Text("Select a category"));
    }
  }
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
              const Text("The loaded file was missing required fields for the current template. The following defaults were injected into memory:"),
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
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Acknowledge'),
          ),
        ],
      );
    },
  );
}

/// View for mapping application paths and selecting the active deployment room
class AppSettingsView extends StatelessWidget {
  const AppSettingsView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();

    return ListView(
      padding: const EdgeInsets.all(32.0),
      children: [
        Text('Application Configuration', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 30),
        
        // Python Modules Path
        TextFormField(
          key: ValueKey(provider.modulesPath), // Forces UI to refresh when picked via dialog
          decoration: InputDecoration(
            labelText: 'Python Modules Path',
            hintText: r'C:\workspace\modules',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.folder),
              tooltip: 'Select Directory',
              onPressed: () async {
                String? selectedDirectory = await FilePicker.getDirectoryPath();
                if (selectedDirectory != null) {
                  provider.updateSetting('modulesPath', selectedDirectory);
                }
              },
            ),
          ),
          initialValue: provider.modulesPath,
          onChanged: (val) => provider.updateSetting('modulesPath', val),
        ),
        const SizedBox(height: 20),
        
        // Buildings JSON Path
        TextFormField(
          key: ValueKey(provider.buildingsFilePath),
          decoration: InputDecoration(
            labelText: 'Buildings JSON File Path',
            hintText: r'C:\workspace\buildings.json',
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
                  provider.updateSetting('buildingsFilePath', result.files.single.path!);
                  provider.loadBuildingsList(); 
                }
              },
            ),
          ),
          initialValue: provider.buildingsFilePath,
          onChanged: (val) {
            provider.updateSetting('buildingsFilePath', val);
            provider.loadBuildingsList(); 
          },
        ),
        const SizedBox(height: 20),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Default config.json Template Path
            Expanded(
              child: TextFormField(
                key: ValueKey(provider.templateFilePath),
                decoration: InputDecoration(
                  labelText: 'Default config.json Template Path',
                  hintText: r'C:\workspace\ControlScript-Template\config.json',
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
            SizedBox(
              height: 56, // Matches the height of the TextFormField
              child: ElevatedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text('Load Template'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white, // FIX: label/icon were unreadable in light mode
                ),
                onPressed: () async {
                  if (provider.templateFilePath.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Set a template file path first.'), backgroundColor: Colors.red),
                    );
                    return;
                  }
                  // Validates & registers the template only. The file is not
                  // opened into the editor until 'Create New Config' is pressed.
                  bool valid = await provider.validateConfigTemplate(provider.templateFilePath);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(valid
                          ? 'Template validated & saved as default. Use "Create New Config" to start from it.'
                          : 'Template file is missing or contains invalid JSON.'),
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
                key: ValueKey(provider.uiSchemaPath),
                decoration: InputDecoration(
                  labelText: 'UI Schema File Path (ui_schema.json)',
                  hintText: r'C:\workspace\ui_schema.json  (blank = look next to the app)',
                  helperText: 'Active schema: ${provider.uiSchema.source} — ${provider.uiSchema.fieldCount} field definitions',
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
            SizedBox(
              height: 56, // Matches the height of the TextFormField
              child: ElevatedButton.icon(
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

        // Legacy Key Map (key_map.json) Path
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(provider.keyMapPath),
                decoration: InputDecoration(
                  labelText: 'Legacy Key Map File Path (key_map.json)',
                  hintText: r'C:\workspace\key_map.json  (blank = look next to the app)',
                  helperText: 'Active map: ${provider.keyMap.source} — ${provider.keyMap.ruleCount} rules. '
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
            SizedBox(
              height: 56, // Matches the height of the TextFormField
              child: ElevatedButton.icon(
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
          key: ValueKey(provider.processorsFilePath),
          decoration: InputDecoration(
            labelText: 'Processors JSON File Path',
            hintText: r'C:\workspace\processors.json',
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
                  provider.updateSetting('processorsFilePath', result.files.single.path!);
                  provider.loadProcessorsList();
                }
              },
            ),
          ),
          initialValue: provider.processorsFilePath,
          onChanged: (val) {
              provider.updateSetting('processorsFilePath', val);
              provider.loadProcessorsList();
          },
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
          key: ValueKey(provider.rootFolderPath),
          decoration: InputDecoration(
            labelText: 'Template Output Root Path',
            hintText: r'C:\workspace\ControlScript-Template',
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

        Text('Active Deployment Target', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(
                  labelText: 'Select Room Deployment',
                  border: OutlineInputBorder(),
                ),
                value: provider.selectedProcessor?['roomId']?.toString(),
                items: provider.processors.map((proc) {
                  return DropdownMenuItem<String>(
                    value: proc['roomId']?.toString(),
                    child: Text("${proc['roomName']} (ID: ${proc['roomId']})"),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    final selected = provider.processors.firstWhere(
                      (p) => p['roomId']?.toString() == val,
                      orElse: () => <String, dynamic>{},
                    );
                    if (selected.isNotEmpty) {
                      provider.selectProcessor(selected);
                    }
                  }
                },
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
      ],
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
  const ProcessorSftpDialog({Key? key, required this.isUpload}) : super(key: key);

  @override
  State<ProcessorSftpDialog> createState() => _ProcessorSftpDialogState();
}

class _ProcessorSftpDialogState extends State<ProcessorSftpDialog> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  
  String _statusText = '';
  bool _isBusy = false;
  String _targetRoomName = '';

  /// Optional additional file to push alongside config.json (upload mode
  /// only). Stays blank unless the user picks one — e.g. Whereused.csv.
  String _extraFilePath = '';

  @override
  void initState() {
    super.initState();
    // Pre-fill from the Active Deployment Target if one is selected
    final provider = context.read<AppStateProvider>();
    final ip = provider.selectedProcessorIp;
    if (ip.isNotEmpty) {
      _ipController.text = ip;
      _targetRoomName = provider.selectedProcessor?['roomName']?.toString() ?? '';
    }
    _statusText = widget.isUpload
        ? 'Enter processor details to upload config.json'
        : 'Enter processor details to download config.json';
  }

  @override
  void dispose() {
    _ipController.dispose();
    _passController.dispose();
    super.dispose();
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
        // Automatically close the dialog after a brief delay on success
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).pop();
        });
      } else {
        // Close immediately and signal success so the audit dialog can be shown
        Navigator.of(context).pop(true);
      }
    }
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
                          ? 'None selected — only config.json will be uploaded.'
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