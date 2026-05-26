import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'app_state.dart';
import 'config_dictionary.dart';

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

  // Helper method to wrap fields with Info buttons
  Widget _wrapWithInfo(BuildContext context, String key, Widget field) {
    final desc = ConfigDictionary.descriptions[key];
    if (desc == null) return field;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        IconButton(
          icon: const Icon(Icons.info_outline, color: Colors.blueAccent),
          tooltip: desc,
          onPressed: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(key),
                content: Text(desc),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
              )
            );
          },
        )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final deviceData = provider.roomConfig[deviceKey];
    final moduleName = deviceData['module'] as String? ?? '';

    // Notice we REMOVED 'name' from this list, so it will now generate as a field you can edit!
    final skipKeys = ['module', 'keep_alive_command', 'input'];
    
    List<Widget> dynamicFormFields = [];
    deviceData.forEach((key, value) {
      if (skipKeys.contains(key)) return;

      Widget field;
      if (value is bool) {
        field = SwitchListTile(
          title: Text(key),
          value: value,
          onChanged: (val) => provider.updateDeviceValue(deviceKey, key, val),
        );
      } else {
        field = TextFormField(
          initialValue: value?.toString() ?? '',
          decoration: InputDecoration(labelText: key, border: const OutlineInputBorder()),
          onChanged: (val) {
            dynamic parsedVal = val;
            if (value is int) parsedVal = int.tryParse(val) ?? 0;
            provider.updateDeviceValue(deviceKey, key, parsedVal);
          },
        );
      }

      dynamicFormFields.add(_wrapWithInfo(context, key, field));
      dynamicFormFields.add(const SizedBox(height: 16));
    });

    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Text(deviceData['name'] ?? deviceKey, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 20),

        // --- PYTHON MODULE SELECTOR ---
        _wrapWithInfo(context, 'module', Row(
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(deviceData['module']), 
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
                  if (provider.modulesPath.isNotEmpty && fullPath.startsWith(provider.modulesPath)) {
                    modPath = fullPath.replaceFirst(provider.modulesPath, '');
                    modPath = modPath.replaceAll(RegExp(r'^[\\\/]'), ''); 
                    modPath = modPath.replaceAll('.py', '');
                    modPath = modPath.replaceAll(RegExp(r'[\\\/]'), '.'); 
                  } else {
                    modPath = result.files.single.name.replaceAll('.py', '');
                  }
                  provider.updateDeviceValue(deviceKey, 'module', modPath);
                }
              },
            ),
          ],
        )),
        const SizedBox(height: 20),

        // --- DYNAMIC KEEP ALIVE DROPDOWN ---
        if (moduleName.isNotEmpty)
          _wrapWithInfo(context, 'keep_alive_command', FutureBuilder<List<String>>(
            future: provider.getCommandsForModule(moduleName),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const CircularProgressIndicator();
              List<String> commands = snapshot.data?.toSet().toList() ?? [];
              String currentValue = deviceData['keep_alive_command']?.toString() ?? '';
              
              if (currentValue.isNotEmpty && !commands.contains(currentValue)) commands.insert(0, currentValue);
              if (!commands.contains('')) commands.insert(0, ''); 

              return DropdownButtonFormField<String>(
                value: currentValue, 
                decoration: InputDecoration(
                  labelText: 'Keep Alive Command',
                  helperText: 'Parsed from $moduleName.py',
                  border: const OutlineInputBorder(),
                ),
                items: commands.map((cmd) => DropdownMenuItem(value: cmd, child: Text(cmd.isEmpty ? '-- None --' : cmd))).toList(),
                onChanged: (val) {
                  if (val != null) provider.updateDeviceValue(deviceKey, 'keep_alive_command', val);
                },
              );
            },
          )),
        const SizedBox(height: 20),

        // --- DYNAMIC INPUT AUTOCOMPLETE ---
        if (deviceData.containsKey('input'))
          _wrapWithInfo(context, 'input', FutureBuilder<List<String>>(
            future: provider.getInputsForModule(moduleName),
            builder: (context, snapshot) {
              List<String> inputs = snapshot.data ?? [];
              String currentValue = deviceData['input']?.toString() ?? '';

              return Autocomplete<String>(
                initialValue: TextEditingValue(text: currentValue),
                optionsBuilder: (TextEditingValue textEditingValue) {
                  if (textEditingValue.text == '') return inputs;
                  return inputs.where((String option) => option.toLowerCase().contains(textEditingValue.text.toLowerCase()));
                },
                onSelected: (String selection) {
                  provider.updateDeviceValue(deviceKey, 'input', selection);
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  return TextFormField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: 'Input (Type manually or select)',
                      helperText: 'Parsed hints from $moduleName.py',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      // Allows manual typing to be saved to state even if not selected from dropdown
                      provider.updateDeviceValue(deviceKey, 'input', val);
                    },
                  );
                },
              );
            },
          )),

        const Divider(height: 50, thickness: 2),
        Text('Standard Configuration', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        // --- AUTO-GENERATED FIELDS ---
        ...dynamicFormFields,
      ],
    );
  }
}