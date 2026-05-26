import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';

class DynamicDevicesTabsView extends StatefulWidget {
  const DynamicDevicesTabsView({Key? key}) : super(key: key);

  @override
  State<DynamicDevicesTabsView> createState() => _DynamicDevicesTabsViewState();
}

class _DynamicDevicesTabsViewState extends State<DynamicDevicesTabsView> {
  
  /// Determines which device blocks should be rendered as tabs based on counts
  List<String> getActiveDeviceKeys(Map<String, dynamic> config) {
    List<String> activeKeys = [];
    
    final map = {
      'dev_projectors': 'PROJECTORDEVICE_',
      'dev_cameras': 'CAMERADEVICE_',
      'dev_switchers': 'SWITCHERDEVICE_',
      'dev_dsps': 'DSPDEVICE_',
      'dev_usb_switchers': 'USBDEVICE_',
    };

    map.forEach((countKey, prefix) {
      if (config.containsKey(countKey)) {
        var countVal = config[countKey];
        int count = 0;
        
        // Convert "Yes" to 1, or parse integer strings
        if (countVal.toString().toLowerCase() == 'yes') {
          count = 1;
        } else {
          count = int.tryParse(countVal.toString()) ?? 0;
        }

        // Add valid keys (e.g. CAMERADEVICE_1, CAMERADEVICE_2)
        for (int i = 1; i <= count; i++) {
          String expectedKey = '$prefix$i';
          if (config.containsKey(expectedKey)) {
            activeKeys.add(expectedKey);
          }
        }
      }
    });

    return activeKeys;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final config = provider.roomConfig;
    
    if (config.isEmpty) {
      return const Center(child: Text("No configuration template loaded.\nPlease load a file or select a room."));
    }

    final activeKeys = getActiveDeviceKeys(config);

    if (activeKeys.isEmpty) {
      return const Center(child: Text("No devices found based on dev_ parameters."));
    }

    return DefaultTabController(
      length: activeKeys.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TabBar(
            isScrollable: true,
            tabs: activeKeys.map((key) {
              String tabName = config[key]['name'] ?? key;
              return Tab(text: tabName);
            }).toList(),
          ),
          Expanded(
            child: TabBarView(
              children: activeKeys.map((key) {
                return DeviceConfigurationForm(deviceKey: key);
              }).toList(),
            ),
          )
        ],
      ),
    );
  }
}

/// The specific form rendered inside the dynamically generated device tabs
class DeviceConfigurationForm extends StatelessWidget {
  final String deviceKey;

  const DeviceConfigurationForm({Key? key, required this.deviceKey}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final deviceData = provider.roomConfig[deviceKey];
    final moduleName = deviceData['module'] as String? ?? '';

    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Text(
          deviceData['name'] ?? deviceKey,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 20),
        
        // Basic configuration properties
        TextFormField(
          initialValue: deviceData['ip_address']?.toString() ?? '',
          decoration: const InputDecoration(
            labelText: 'IP Address',
            border: OutlineInputBorder(),
          ),
          onChanged: (val) {
            provider.updateDeviceValue(deviceKey, 'ip_address', val);
          },
        ),
        const SizedBox(height: 20),

        TextFormField(
          initialValue: deviceData['gve_id']?.toString() ?? '',
          decoration: const InputDecoration(
            labelText: 'GlobalViewer Enterprise ID',
            border: OutlineInputBorder(),
          ),
          onChanged: (val) {
            provider.updateDeviceValue(deviceKey, 'gve_id', val);
          },
        ),
        const SizedBox(height: 20),

        // Dynamic Keep-Alive dropdown parsed directly from the Python file
        if (moduleName.isNotEmpty)
          FutureBuilder<List<String>>(
            future: provider.getCommandsForModule(moduleName),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Align(
                  alignment: Alignment.centerLeft,
                  child: CircularProgressIndicator(),
                );
              }
              
              List<String> commands = snapshot.data ?? [];
              String currentValue = deviceData['keep_alive_command'] ?? '';
              
              // Ensure the current value exists in the dropdown list to avoid UI errors
              if (currentValue.isNotEmpty && !commands.contains(currentValue)) {
                commands.insert(0, currentValue);
              }

              return DropdownButtonFormField<String>(
                value: currentValue.isEmpty ? null : currentValue,
                decoration: InputDecoration(
                  labelText: 'Keep Alive Command',
                  helperText: 'Parsed from $moduleName.py',
                  border: const OutlineInputBorder(),
                ),
                items: commands.map((cmd) {
                  return DropdownMenuItem(
                    value: cmd,
                    child: Text(cmd),
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

        const SizedBox(height: 20),
        
        SwitchListTile(
          title: const Text('Manual Disconnect (Temporarily removed)'),
          value: deviceData['manual_disconnect'] ?? false,
          onChanged: (val) {
            provider.updateDeviceValue(deviceKey, 'manual_disconnect', val);
          },
        )
      ],
    );
  }
}