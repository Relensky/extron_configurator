import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'app_state.dart';
import 'config_dictionary.dart';
import 'schema_field_builder.dart';

class DynamicDevicesTabsView extends StatefulWidget {
  const DynamicDevicesTabsView({Key? key}) : super(key: key);

  @override
  State<DynamicDevicesTabsView> createState() => _DynamicDevicesTabsViewState();
}

class _DynamicDevicesTabsViewState extends State<DynamicDevicesTabsView> {
  List<String> getActiveDeviceKeys(Map<String, dynamic> config) {
    List<String> activeKeys = [];
    final systemSetup = config['SYSTEM_SETUP'] ?? {};
    
    //hardware maps
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

  /// A guaranteed-working dropdown: a searchable dialog listing every python
  /// module discovered under the Python Modules Path.
  Future<String?> _showModulePicker(BuildContext context, List<String> modules) {
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String filter = '';
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final visible = filter.isEmpty
                ? modules
                : modules.where((m) => m.toLowerCase().contains(filter.toLowerCase())).toList();
            return AlertDialog(
              title: const Text('Select Python Module'),
              content: SizedBox(
                width: 500,
                height: 400,
                child: Column(
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Search modules',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) => setDialogState(() => filter = val),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: modules.isEmpty
                          ? const Center(child: Text('No modules found.\nDefault location is the "devices" sub-folder of the Root Folder.\nCheck the Python Modules Path in App Config.', textAlign: TextAlign.center))
                          : ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (ctx, i) => ListTile(
                                dense: true,
                                title: Text(visible[i]),
                                onTap: () => Navigator.of(ctx).pop(visible[i]),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
              ],
            );
          },
        );
      },
    );
  }

  // Helper method to wrap fields with Info buttons.
  // Descriptions come from the loaded ui_schema.json first, then fall back to
  // the legacy built-in ConfigDictionary.
  Widget _wrapWithInfo(BuildContext context, String key, Widget field) {
    final desc = context.read<AppStateProvider>().uiSchema.descriptionFor(key)
        ?? ConfigDictionary.descriptions[key];
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

    // Captured from the module Autocomplete so 'Pick .py File' can push text into it
    TextEditingController? moduleFieldController;

    final skipKeys = ['module', 'keep_alive_command', 'input'];
    
    List<Widget> dynamicFormFields = [];
    deviceData.forEach((key, value) {
      if (skipKeys.contains(key)) return;

      // SCHEMA-DRIVEN: labels, descriptions, dropdowns, and widget types 
      // come from ui_schema.json (with type inference as the fallback), so a
      // new device property can get a full editor UI without a rebuild.
      final Widget? field = SchemaFieldBuilder.buildField(
        context: context,
        provider: provider,
        sectionKey: deviceKey,
        fieldKey: key,
        value: value,
      );
      if (field == null) return; // Schema marked the key "hidden"

      dynamicFormFields.add(field);
      dynamicFormFields.add(const SizedBox(height: 16));
    });

    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Text(deviceData['name'] ?? deviceKey, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 20),

        // --- PYTHON MODULE SELECTOR (fill-in or pick from modules path) ---
        _wrapWithInfo(context, 'module', Row(
          children: [
            Expanded(
              child: Autocomplete<String>(
                initialValue: TextEditingValue(text: deviceData['module']?.toString() ?? ''),
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final modules = provider.availableModules;
                  final text = textEditingValue.text;
                  // Show the FULL list when the field is empty or still holds the
                  // saved value — otherwise a pre-filled field filters itself down
                  // to one entry and the dropdown appears to do nothing.
                  if (text.isEmpty || text == deviceData['module']?.toString()) return modules;
                  return modules.where((m) => m.toLowerCase().contains(text.toLowerCase()));
                },
                onSelected: (String selection) {
                  provider.updateDeviceValue(deviceKey, 'module', selection);
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  moduleFieldController = controller; // Expose to the picker button & dialog
                  return TextFormField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: 'Python Module (type or select)',
                      helperText: provider.availableModules.isEmpty
                          ? 'No modules found in ${provider.effectiveModulesPath} — check the Python Modules Path in App Config'
                          : '${provider.availableModules.length} modules found under ${provider.effectiveModulesPath}',
                      border: const OutlineInputBorder(),
                      // A real button: opens a searchable list of every module
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_drop_down),
                        tooltip: 'Browse modules',
                        onPressed: () async {
                          final selected = await _showModulePicker(context, provider.availableModules);
                          if (selected != null) {
                            provider.updateDeviceValue(deviceKey, 'module', selected);
                            controller.text = selected; // Keep the visible field in sync
                          }
                        },
                      ),
                    ),
                    // Allows manual fill-in to be saved even if not selected from the list
                    onChanged: (val) => provider.updateDeviceValue(deviceKey, 'module', val),
                  );
                },
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
                  // Use the EFFECTIVE modules path so files picked from the
                  // default "<root>/devices" folder (Modules Path left blank
                  // in App Config) still convert to dot notation correctly.
                  final String modulesBase = provider.effectiveModulesPath;
                  if (fullPath.startsWith(modulesBase)) {
                    modPath = fullPath.replaceFirst(modulesBase, '');
                    modPath = modPath.replaceAll(RegExp(r'^[\\\/]'), ''); 
                    modPath = modPath.replaceAll('.py', '');
                    modPath = modPath.replaceAll(RegExp(r'[\\\/]'), '.'); 
                  } else {
                    modPath = result.files.single.name.replaceAll('.py', '');
                  }
                  provider.updateDeviceValue(deviceKey, 'module', modPath);
                  moduleFieldController?.text = modPath; // Keep the visible field in sync
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