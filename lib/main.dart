import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'dynamic_devices_view.dart';
import 'setup_wizard_view.dart';
import 'json_editor_view.dart';

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
    return MaterialApp(
      title: 'Deployment Configurator',
      theme: ThemeData.dark(), // Fits developer environments like VS Code
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Room Config Builder'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Export Config to Tree',
            onPressed: () {
              context.read<AppStateProvider>().exportRoomConfig();
              ScaffoldMessenger.of(context).showSnackBar(
                 const SnackBar(content: Text('Building and saving config.json...'))
              );
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
              NavigationRailDestination(
                icon: Icon(Icons.auto_awesome),
                label: Text('Wizard'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.router),
                label: Text('Devices'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.data_object),
                label: Text('Raw JSON'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.build_circle),
                label: Text('App Config'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: _buildMainContent(),
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
        return const JsonEditorView();
      case 3:
        return const AppSettingsView();
      default:
        return const Center(child: Text("Select a category"));
    }
  }
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
        
        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Python Modules Path',
            hintText: r'C:\workspace\modules',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.folder),
          ),
          initialValue: provider.modulesPath,
          onChanged: (val) => provider.modulesPath = val,
        ),
        const SizedBox(height: 20),
        
        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Buildings JSON File Path',
            hintText: r'C:\workspace\buildings.json',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.location_city),
          ),
          initialValue: provider.buildingsFilePath,
          onChanged: (val) {
            provider.buildingsFilePath = val;
            provider.loadBuildingsList(); // Load on change
          },
        ),
        const SizedBox(height: 20),

        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Default config.json Template Path',
            hintText: r'C:\workspace\ControlScript-Template\config.json',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.file_open),
            helperText: 'Press Enter to load this template into memory',
          ),
          onFieldSubmitted: (val) {
            if (val.isNotEmpty) {
              provider.loadConfigTemplate(val);
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Attempting to load template from $val...'))
              );
            }
          },
        ),
        const SizedBox(height: 20),

        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Processors JSON File Path',
            hintText: r'C:\workspace\processors.json',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.file_present),
          ),
          initialValue: provider.processorsFilePath,
          onChanged: (val) => provider.processorsFilePath = val,
        ),
        const SizedBox(height: 10),
        
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.sync),
            label: const Text('Load Processors Data'),
            onPressed: () => provider.loadProcessorsList(),
          ),
        ),
        const SizedBox(height: 20),

        TextFormField(
          decoration: const InputDecoration(
            labelText: 'Template Output Root Path',
            hintText: r'C:\workspace\ControlScript-Template',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.account_tree),
          ),
          initialValue: provider.rootFolderPath,
          onChanged: (val) => provider.rootFolderPath = val,
        ),
        const Divider(height: 60, thickness: 2),

        Text('Active Deployment Target', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        
        DropdownButtonFormField<String>(
          decoration: const InputDecoration(
            labelText: 'Select Room Deployment',
            border: OutlineInputBorder(),
          ),
          // Use the roomId string as the unique identifier
          value: provider.selectedProcessor?['roomId']?.toString(),
          items: provider.processors.map((proc) {
            return DropdownMenuItem<String>(
              value: proc['roomId']?.toString(),
              child: Text("${proc['roomName']} (ID: ${proc['roomId']})"),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              // Look up the full map based on the selected ID
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
      ],
    );
  }
}