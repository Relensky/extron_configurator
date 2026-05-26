import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';

class SetupWizardView extends StatelessWidget {
  const SetupWizardView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final config = provider.roomConfig;

    if (config.isEmpty || !config.containsKey('SYSTEM_SETUP')) {
      return const Center(child: Text("Please load a template config first in the App Config tab."));
    }

    final systemSetup = config['SYSTEM_SETUP'];

    return ListView(
      padding: const EdgeInsets.all(32.0),
      children: [
        Text('Room Setup Wizard', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 10),
        const Text("Set your core room identifiers and hardware counts here. Generating these will reset the specific device tabs."),
        const Divider(height: 40, thickness: 2),

        // --- Room Identification ---
        Text('Room Identification', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        Row(
          children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Building (gve_bldg)', border: OutlineInputBorder()),
                value: provider.buildings.containsValue(systemSetup['gve_bldg']) 
                    ? systemSetup['gve_bldg'] 
                    : null,
                items: () {
                  // 1. Deduplicate the buildings to prevent Flutter crash
                  final Map<String, String> uniqueBuildings = {};
                  provider.buildings.forEach((key, value) {
                    // Keep the entry with the longest key name (Full name over abbreviation)
                    if (!uniqueBuildings.containsKey(value) || key.length > uniqueBuildings[value]!.length) {
                      uniqueBuildings[value] = key; 
                    }
                  });

                  // 2. Map the deduplicated list to DropdownMenuItems
                  return uniqueBuildings.entries.map((entry) {
                    return DropdownMenuItem<String>(
                      value: entry.key, // The abbreviation (e.g., "AJH")
                      child: Text("${entry.value} (${entry.key})"),
                    );
                  }).toList();
                }(),
                onChanged: (val) {
                  if (val != null) {
                    systemSetup['gve_bldg'] = val;
                    provider.updateFullRoomName();
                  }
                },
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              flex: 1,
              child: TextFormField(
                initialValue: systemSetup['gve_room'] ?? '',
                decoration: const InputDecoration(labelText: 'Room Number', border: OutlineInputBorder()),
                onChanged: (val) {
                  systemSetup['gve_room'] = val;
                  provider.updateFullRoomName(); // Recalculate full name
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        
        TextFormField(
          key: ValueKey(systemSetup['gui_full_room_name']), // Forces rebuild when updated via code
          initialValue: systemSetup['gui_full_room_name'] ?? '',
          decoration: const InputDecoration(
            labelText: 'Generated Full Room Name', 
            border: OutlineInputBorder(),
            filled: true,
          ),
          readOnly: true, // Let the app handle this based on Building + Room
        ),

        const Divider(height: 60, thickness: 2),

        // --- Hardware Counts ---
        Text('Hardware Quantities', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        _buildCountDropdown(context, provider, 'Projectors / Displays', 'dev_projectors', 'PROJECTORDEVICE_'),
        _buildCountDropdown(context, provider, 'Cameras', 'dev_cameras', 'CAMERADEVICE_'),
        _buildCountDropdown(context, provider, 'Switchers', 'dev_switchers', 'SWITCHERDEVICE_'),
        _buildCountDropdown(context, provider, 'DSPs', 'dev_dsps', 'DSPDEVICE_'),
        _buildCountDropdown(context, provider, 'USB Switchers', 'dev_usb_switchers', 'USBDEVICE_'),
        _buildCountDropdown(context, provider, 'Power Controllers', 'dev_power_controllers', 'POWERDEVICE_'),
        
      ],
    );
  }

  Widget _buildCountDropdown(BuildContext context, AppStateProvider provider, String label, String systemKey, String devicePrefix) {
    final systemSetup = provider.roomConfig['SYSTEM_SETUP'];
    String currentValue = systemSetup[systemKey]?.toString() ?? '0';
    
    // Safety check: if current value isn't a simple int string 0-10, default to 0 in UI
    if (int.tryParse(currentValue) == null) currentValue = '0';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: DropdownButtonFormField<String>(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        value: currentValue,
        items: List.generate(9, (index) => index.toString()).map((count) {
          return DropdownMenuItem(value: count, child: Text(count));
        }).toList(),
        onChanged: (val) {
          if (val != null) {
            int count = int.parse(val);
            // This calls the method we created in the previous step
            provider.setDeviceCount(systemKey, devicePrefix, count, provider.getDefaultDeviceBlock(devicePrefix));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('$label updated to $count. Device tabs reset.'),
              duration: const Duration(seconds: 2),
            ));
          }
        },
      ),
    );
  }
}