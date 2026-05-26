import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'app_state.dart';

class DynamicDevicesTabsView extends StatefulWidget {
  const DynamicDevicesTabsView({Key? key}) : super(key: key);

  @override
  State<DynamicDevicesTabsView> createState() => _DynamicDevicesTabsViewState();
}

class _DynamicDevicesTabsViewState extends State<DynamicDevicesTabsView> {
  List<String> getActiveDeviceKeys(Map<String, dynamic> config) {
    List<String> activeKeys = [];
    final systemSetup = config['SYSTEM_SETUP'] ?? {};
    
    // UPDATED: Included all new hardware maps
    final map = {
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

    map.forEach((countKey, prefix) {
      if (systemSetup.containsKey(countKey)) {
        var countVal = systemSetup[countKey];
        int count = (countVal.toString().toLowerCase() == 'yes') ? 1 : (int.tryParse(countVal.toString()) ?? 0);

        for (int i = 1; i <= count; i++) {
          String expectedKey = '$prefix$i';
          if (config.containsKey(expectedKey)) activeKeys.add(expectedKey);
        }
      }
    });
    return activeKeys;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final config = provider.roomConfig;
    if (config.isEmpty) return const Center(child: Text("No configuration template loaded."));

    final activeKeys = getActiveDeviceKeys(config);
    if (activeKeys.isEmpty) return const Center(child: Text("No devices found based on dev_ parameters."));

    return DefaultTabController(
      length: activeKeys.length,
      child: Builder(
        builder: (context) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // MOUSE WHEEL SCROLL LISTENER FOR TABS
              Listener(
                onPointerSignal: (pointerSignal) {
                  if (pointerSignal is PointerScrollEvent) {
                    final tabController = DefaultTabController.of(context);
                    if (pointerSignal.scrollDelta.dy > 0 && tabController.index < tabController.length - 1) {
                      tabController.animateTo(tabController.index + 1);
                    } else if (pointerSignal.scrollDelta.dy < 0 && tabController.index > 0) {
                      tabController.animateTo(tabController.index - 1);
                    }
                  }
                },
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: activeKeys.map((key) => Tab(text: config[key]['name'] ?? key)).toList(),
                ),
              ),
              Expanded(
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(), // Stops drag issues so scroll wheel wins
                  children: activeKeys.map((key) => DeviceConfigurationForm(deviceKey: key)).toList(),
                ),
              )
            ],
          );
        }
      ),
    );
  }
}

class DeviceConfigurationForm extends StatelessWidget {
  final String deviceKey;

  const DeviceConfigurationForm({Key? key, required this.deviceKey}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final deviceData = provider.roomConfig[deviceKey];
    final moduleName = deviceData['module'] as String? ?? '';

    // Elements we render manually (Name, Module, KeepAlive)
    final skipKeys = ['name', 'module', 'keep_alive_command'];
    
    // Auto-generate fields based on the config.json template
    List<Widget> dynamicFormFields = [];
    deviceData.forEach((key, value) {
      if (skipKeys.contains(key)) return;

      dynamicFormFields.add(
        TextFormField(
          initialValue: value?.toString() ?? '',
          decoration: InputDecoration(labelText: key, border: const OutlineInputBorder()),
          onChanged: (val) {
            // Keep types clean based on the original JSON template types
            dynamic parsedVal = val;
            if (value is bool) parsedVal = val.toLowerCase() == 'true';
            else if (value is int) parsedVal = int.tryParse(val) ?? 0;
            provider.updateDeviceValue(deviceKey, key, parsedVal);
          },
        ),
      );
      dynamicFormFields.add(const SizedBox(height: 16));
    });

    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Text(deviceData['name'] ?? deviceKey, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 20),

        // --- PYTHON MODULE SELECTOR ---
        Row(
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(deviceData['module']), // Force rebuild when picker updates it
                initialValue: deviceData['module']?.toString() ?? '',
                decoration: const InputDecoration(labelText: 'Python Module (e.g. modules.device.xyz)', border: OutlineInputBorder()),
                onChanged: (val) => provider.updateDeviceValue(deviceKey, 'module', val),
              ),
            ),
            const SizedBox(width: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.file_open),
              label: const Text('Pick .py File'),
              onPressed: () async {
                FilePickerResult? result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['py']);
                if (result != null) {
                  String fullPath = result.files.single.path!;
                  String modPath = fullPath;
                  
                  // Try to translate the hard path into Extron dot-notation if it's inside modulesPath
                  if (provider.modulesPath.isNotEmpty && fullPath.startsWith(provider.modulesPath)) {
                    modPath = fullPath.replaceFirst(provider.modulesPath, '');
                    modPath = modPath.replaceAll(RegExp(r'^[\\\/]'), ''); 
                    modPath = modPath.replaceAll('.py', '');
                    modPath = modPath.replaceAll(RegExp(r'[\\\/]'), '.'); // slashes to dots
                  } else {
                    modPath = result.files.single.name.replaceAll('.py', '');
                  }
                  provider.updateDeviceValue(deviceKey, 'module', modPath);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 20),

        // --- DYNAMIC KEEP ALIVE DROPDOWN ---
        if (moduleName.isNotEmpty)
          FutureBuilder<List<String>>(
            future: provider.getCommandsForModule(moduleName),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Align(alignment: Alignment.centerLeft, child: CircularProgressIndicator());
              }
              
              // 1. Grab the parsed commands and force a final deduplication pass just in case
              List<String> commands = snapshot.data?.toSet().toList() ?? [];
              String currentValue = deviceData['keep_alive_command']?.toString() ?? '';
              
              // 2. Ensure the current config.json value exists in the dropdown list 
              // so the UI doesn't crash if the template has a command the python file doesn't
              if (currentValue.isNotEmpty && !commands.contains(currentValue)) {
                commands.insert(0, currentValue);
              }

              // 3. Add an empty option at the top so users can clear the keep alive
              if (!commands.contains('')) {
                commands.insert(0, ''); 
              }

              return DropdownButtonFormField<String>(
                value: currentValue, // Using '' instead of null for empty states
                decoration: InputDecoration(
                  labelText: 'Keep Alive Command',
                  helperText: 'Parsed from $moduleName.py',
                  border: const OutlineInputBorder(),
                ),
                items: commands.map((cmd) {
                  return DropdownMenuItem(
                    value: cmd,
                    child: Text(cmd.isEmpty ? '-- None --' : cmd),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    provider.updateDeviceValue(deviceKey, 'keep_alive_command', val);
                  }
                },
              );
            },
          ),
        
        const Divider(height: 50, thickness: 2),
        Text('Standard Configuration', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        // --- AUTO-GENERATED FIELDS ---
        ...dynamicFormFields,
      ],
    );
  }
}