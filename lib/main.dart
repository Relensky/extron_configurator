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
            icon: const Icon(Icons.cloud_upload),
            tooltip: 'Upload to Processor (SFTP)',
            onPressed: () {
              showDialog(
                context: context,
                barrierDismissible: false, 
                builder: (context) => const UploadConfigDialog(),
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
                  label: const Text("Create New Config\n(From base config.json)", textAlign: TextAlign.center),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white, // Forces readable text in light mode
                  ),
                  onPressed: () async {
                    if (provider.rootFolderPath.isEmpty) {
                       setState(() => _selectedIndex = 4); // Route to App Config
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Please set the Template Root Path first."), backgroundColor: Colors.red)
                        );
                    } else {
                      bool success = await provider.createNewConfig();
                      if (!success && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Failed to load base config.json from root folder."), backgroundColor: Colors.red)
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
                    color: Colors.black87, // Dark background for terminal feel
                    borderRadius: BorderRadius.circular(4),
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
                            color: isHeader ? Colors.orangeAccent : Colors.greenAccent,
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
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.shade700),
                onPressed: () {
                  if (provider.templateFilePath.isNotEmpty) {
                    provider.loadConfigTemplate(provider.templateFilePath);
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Loading template...'))
                    );
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

/// A dialog that collects network credentials and displays real-time SFTP upload status
class UploadConfigDialog extends StatefulWidget {
  const UploadConfigDialog({Key? key}) : super(key: key);

  @override
  State<UploadConfigDialog> createState() => _UploadConfigDialogState();
}

class _UploadConfigDialogState extends State<UploadConfigDialog> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  
  String _statusText = 'Enter processor details to upload config.json';
  bool _isUploading = false;

  @override
  void dispose() {
    _ipController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _startUpload() async {
    // Basic validation
    if (_ipController.text.isEmpty || _passController.text.isEmpty) {
      setState(() => _statusText = "Error: IP and Password are required.");
      return;
    }

    setState(() {
      _isUploading = true;
      _statusText = "Initializing...";
    });

    final provider = context.read<AppStateProvider>();
    
    // Trigger the upload and pass a callback to update the UI with status strings
    final success = await provider.uploadConfigToProcessor(
      ipAddress: _ipController.text.trim(),
      password: _passController.text,
      onStatusUpdate: (status) {
        // Use setState to reflect the SFTP client's status in the dialog
        setState(() => _statusText = status);
      },
    );

    setState(() => _isUploading = false);

    if (success) {
      // Automatically close the dialog after a brief delay on success
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Direct SFTP Upload'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'Processor IP / Hostname',
                border: OutlineInputBorder(),
              ),
              enabled: !_isUploading,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Admin Password',
                border: OutlineInputBorder(),
              ),
              enabled: !_isUploading,
            ),
            const SizedBox(height: 24),
            
            // Status read-out container
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black26,
              height: 80,
              alignment: Alignment.centerLeft,
              child: _isUploading && _statusText.contains("Connecting")
                  ? Row(
                      children: [
                        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 16),
                        Expanded(child: Text(_statusText, style: const TextStyle(fontFamily: 'monospace'))),
                      ],
                    )
                  : Text(_statusText, style: const TextStyle(fontFamily: 'monospace')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isUploading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.cloud_upload),
          label: const Text('Upload'),
          onPressed: _isUploading ? null : _startUpload,
        ),
      ],
    );
  }
}