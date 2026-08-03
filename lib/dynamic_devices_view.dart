import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'app_state.dart';
import 'config_dictionary.dart';
import 'config_maintenance.dart';
import 'pdf_viewer_dialog.dart';
import 'schema_field_builder.dart';
import 'search_match.dart';

class DynamicDevicesTabsView extends StatefulWidget {
  const DynamicDevicesTabsView({super.key});

  @override
  State<DynamicDevicesTabsView> createState() => _DynamicDevicesTabsViewState();
}

class _DynamicDevicesTabsViewState extends State<DynamicDevicesTabsView> {
  List<String> getActiveDeviceKeys(
      Map<String, dynamic> config, Map<String, String> map) {
    List<String> activeKeys = [];
    final systemSetup = config['SYSTEM_SETUP'] ?? {};

    // hardware map comes from the UI schema's "device_types" so families
    // added in ui_schema.json get their tabs without a recompile
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

    final activeKeys =
        getActiveDeviceKeys(config, provider.uiSchema.deviceCountMap);
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

  const DeviceConfigurationForm({super.key, required this.deviceKey});

  /// Searchable dialog of the models aggregated across the python modules
  /// (DEVICE_INFO "models" lists, falling back to each driver's self.Models
  /// keys), pre-filtered to this device's family via DEVICE_INFO
  /// "device_type" — with a toggle to list every model regardless of type.
  /// The subtitle shows which module a model will switch the device to.
  Future<String?> _showModelPicker(
      BuildContext context, AppStateProvider provider) {
    final allModels = provider.availableModels;
    final typedModels = provider.availableModelsFor(deviceKey);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String filter = '';
        bool showAllTypes = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final models = showAllTypes ? allModels : typedModels;
            final visible = filter.isEmpty
                ? models
                : searchFilter(models, filter).toList();
            return AlertDialog(
              title: const Text('Select Device Model'),
              content: SizedBox(
                width: 500,
                height: 440,
                child: Column(
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Search models',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) => setDialogState(() => filter = val),
                    ),
                    // Escape hatch: only offered when the device_type filter
                    // is actually hiding something.
                    if (typedModels.length != allModels.length)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                            'Show all device types (${allModels.length} models)'),
                        value: showAllTypes,
                        onChanged: (val) =>
                            setDialogState(() => showAllTypes = val ?? false),
                      ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: models.isEmpty
                          ? const Center(child: Text('No models found for this device type.\nAdd a DEVICE_INFO dict (with "device_type" and "models") to the .py files,\nor tick "Show all device types".', textAlign: TextAlign.center))
                          : ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (ctx, i) {
                                final entry = provider.modelRegistry[visible[i]];
                                return ListTile(
                                  dense: true,
                                  title: Text(visible[i]),
                                  subtitle: entry == null
                                      ? null
                                      : Text(entry.explicit
                                          ? entry.module
                                          : '${entry.module} (from self.Models)'),
                                  onTap: () => Navigator.of(ctx).pop(visible[i]),
                                );
                              },
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

  /// Writes a Model selection through the provider. When the pick switches the
  /// device to a different module, the user is asked whether to apply the
  /// module's DEVICE_INFO defaults (a new device) or keep the current settings
  /// (a conversion), with the differing fields shown. The result is
  /// acknowledged in a snackbar.
  Future<void> _applyModel(BuildContext context, AppStateProvider provider,
      String model, TextEditingController? moduleController) async {
    final preview = provider.previewModelSelection(deviceKey, model);

    // Unknown model: no module claims it — just save the text.
    if (!preview.known) {
      provider.keepSettingsSwitchModule(deviceKey, model);
      moduleController?.text =
          provider.roomConfig[deviceKey]?['module']?.toString() ?? '';
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Model saved — no module claims this model, so nothing else changed.")));
      return;
    }

    // Module already matches: nothing to decide, keep everything as-is.
    if (!preview.moduleChanged) {
      provider.keepSettingsSwitchModule(deviceKey, model);
      moduleController?.text = preview.newModule;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              "Model '$model' set — already using module ${preview.newModule}.")));
      return;
    }

    // Module changes: ask apply-defaults (new) vs keep-settings (conversion).
    final applyDefaults = await _showModelChangeDialog(context, model, preview);
    if (applyDefaults == null || !context.mounted) return; // cancelled

    moduleController?.text = preview.newModule;
    if (applyDefaults) {
      final applied = provider.applyModuleDefaults(deviceKey, model);
      final msg = applied.isEmpty
          ? "Model '$model' saved — module defaults already in place."
          : "Model '$model': set ${applied.join(', ')}";
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } else {
      provider.keepSettingsSwitchModule(deviceKey, model);
      final n = preview.diffs.length;
      final msg = n == 0
          ? "Kept current settings — switched to module ${preview.newModule}."
          : "Kept current settings — $n field${n == 1 ? '' : 's'} differ from ${preview.newModule} defaults.";
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Prompt shown when a model pick switches the device to a different module.
  /// Lists the fields that differ from the new module's defaults and lets the
  /// user apply the module defaults or keep the current settings.
  /// Returns true = apply defaults, false = keep settings, null = cancelled.
  Future<bool?> _showModelChangeDialog(
      BuildContext context, String model, ModelChangePreview preview) {
    String fmt(dynamic v) => (v == null || v == '') ? '(blank)' : v.toString();
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Apply ${preview.newModule} defaults?'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    "Switching $deviceKey to model '$model' (module ${preview.newModule})."),
                const SizedBox(height: 12),
                if (preview.diffs.isEmpty)
                  const Text(
                      "This device's settings already match the module defaults.")
                else ...[
                  Text(
                      "${preview.diffs.length} field${preview.diffs.length == 1 ? '' : 's'} differ from the module defaults "
                      "(current → module default):"),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final d in preview.diffs)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                  '${d.key}:  ${fmt(d.current)}  →  ${fmt(d.moduleDefault)}'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Keep current settings')),
            ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Apply module defaults')),
          ],
        );
      },
    );
  }

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
                : searchFilter(modules, filter).toList();
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
    // Captured so onSelected can unfocus the field — the optionsBuilders
    // below return the full list while the text matches the saved value, so
    // without dropping focus the options overlay stays open after a pick.
    FocusNode? modelFieldFocus;
    FocusNode? moduleFieldFocus;

    // 'input' always renders in its own slot near the top (under Keep
    // Alive): the schema-driven field when a "device_fields" entry overrides
    // it for this device type (e.g. projector input -> module_states),
    // otherwise the legacy autocomplete block. Never in the list below —
    // that kept it visible only after a save re-sorted the keys.
    final bool inputHasSchemaOverride =
        provider.uiSchema.deviceSpecFor(deviceKey, 'input') != null;
    // 'model' renders in its own dedicated slot at the top (Model dropdown),
    // like 'module' — never in the auto-generated list below.
    final skipKeys = ['module', 'keep_alive_command', 'input', 'model'];

    // Alphabetical, matching how the config is sorted on save — so a field's
    // position doesn't move after Apply Changes / export re-orders the JSON.
    final List<String> sortedKeys =
        (deviceData as Map).keys.map((k) => k.toString()).toList()..sort();

    List<Widget> dynamicFormFields = [];
    for (final key in sortedKeys) {
      if (skipKeys.contains(key)) continue;

      // SCHEMA-DRIVEN: labels, descriptions, dropdowns, and widget types
      // come from ui_schema.json (with type inference as the fallback), so a
      // new device property can get a full editor UI without a rebuild.
      final Widget? field = SchemaFieldBuilder.buildField(
        context: context,
        provider: provider,
        sectionKey: deviceKey,
        fieldKey: key,
        value: deviceData[key],
        // Any property can be removed (confirmed); the Check Defaults
        // button in the header adds it back later if needed.
        onDelete: () =>
            confirmRemoveConfigKey(context, provider, deviceKey, key),
      );
      if (field == null) continue; // Schema marked the key "hidden"

      dynamicFormFields.add(field);
      dynamicFormFields.add(const SizedBox(height: 16));
    }

    // DEVICE-TYPE-ONLY FIELDS: "device_fields" entries flagged addIfMissing
    // render even before the key exists in this device block — the first
    // edit writes the key into config.json. Lets a new device-type setting
    // (e.g. a projector-only option) ship via ui_schema.json alone. ('input'
    // is handled by its own dedicated slot above and is skipped here.)
    for (final spec
        in provider.uiSchema.missingFieldsFor(deviceKey, sortedKeys)) {
      if (skipKeys.contains(spec.key)) continue;
      final Widget? field = SchemaFieldBuilder.buildField(
        context: context,
        provider: provider,
        sectionKey: deviceKey,
        fieldKey: spec.key,
        value: null,
      );
      if (field == null) continue;
      dynamicFormFields.add(field);
      dynamicFormFields.add(const SizedBox(height: 16));
    }

    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(deviceData['name'] ?? deviceKey,
                  style: Theme.of(context).textTheme.headlineMedium),
            ),
            // Diff this device block against the template + schema defaults
            // and offer to add anything missing (e.g. a deleted property).
            OutlinedButton.icon(
              icon: const Icon(Icons.playlist_add_check),
              label: const Text('Check Defaults'),
              onPressed: () =>
                  showCheckDefaultsDialog(context, provider, deviceKey),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // --- MODEL SELECTOR (aggregated from every module's model dict) ---
        // Picking a model switches 'module' to that model's default .py and
        // applies the module's DEVICE_INFO connection defaults.
        _wrapWithInfo(context, 'model', Row(
          children: [
            Expanded(
              child: Autocomplete<String>(
                initialValue: TextEditingValue(text: deviceData['model']?.toString() ?? ''),
                optionsBuilder: (TextEditingValue textEditingValue) {
                  // Only models whose DEVICE_INFO "device_type" matches this
                  // tab's family; untyped (self.Models-only) models are hidden
                  // here. The dialog behind the dropdown arrow can still list
                  // every model via its "Show all device types" checkbox.
                  final models = provider.availableModelsFor(deviceKey);
                  final text = textEditingValue.text;
                  // Full list while the field is empty or unchanged (see the
                  // module autocomplete below for why).
                  if (text.isEmpty || text == deviceData['model']?.toString()) return models;
                  return searchFilter(models, text);
                },
                onSelected: (String selection) {
                  modelFieldFocus?.unfocus(); // Close the options overlay
                  _applyModel(context, provider, selection, moduleFieldController);
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  modelFieldFocus = focusNode;
                  return TextFormField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: 'Model (type or select)',
                      helperText: provider.availableModels.isEmpty
                          ? 'No models found — add DEVICE_INFO dicts to the python modules'
                          : '${provider.availableModelsFor(deviceKey).length} models for this device type '
                              '(${provider.availableModels.length} total); picking one sets the module + defaults',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_drop_down),
                        tooltip: 'Browse models',
                        onPressed: () async {
                          final selected = await _showModelPicker(context, provider);
                          if (selected != null && context.mounted) {
                            controller.text = selected; // Keep the visible field in sync
                            _applyModel(context, provider, selected, moduleFieldController);
                          }
                        },
                      ),
                    ),
                    // Manual fill-in still saves, without touching the module
                    onChanged: (val) => provider.updateDeviceValue(deviceKey, 'model', val),
                  );
                },
              ),
            ),
            const SizedBox(width: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Manual (PDF)'),
              onPressed: () {
                final currentModule =
                    provider.roomConfig[deviceKey]?['module']?.toString() ?? '';
                // Opens the manual in the in-app viewer (or a snackbar if it
                // can't be resolved). The viewer itself offers "Open externally".
                PdfViewerDialog.open(context, provider, currentModule);
              },
            ),
          ],
        )),
        const SizedBox(height: 20),

        // --- PYTHON MODULE SELECTOR (fill-in or pick from modules path) ---
        _wrapWithInfo(context, 'module', Row(
          children: [
            Expanded(
              child: Autocomplete<String>(
                initialValue: TextEditingValue(text: deviceData['module']?.toString() ?? ''),
                optionsBuilder: (TextEditingValue textEditingValue) {
                  // Offered (and therefore stored) as the 'modules.device.<x>'
                  // import path the processor needs, never the bare file stem.
                  final modules = provider.availableModuleImports;
                  final text = textEditingValue.text;
                  // Show the FULL list when the field is empty or still holds the
                  // saved value — otherwise a pre-filled field filters itself down
                  // to one entry and the dropdown appears to do nothing.
                  if (text.isEmpty || text == deviceData['module']?.toString()) return modules;
                  return searchFilter(modules, text);
                },
                onSelected: (String selection) {
                  moduleFieldFocus?.unfocus(); // Close the options overlay
                  provider.updateDeviceValue(deviceKey, 'module', selection);
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  moduleFieldController = controller; // Expose to the picker button & dialog
                  moduleFieldFocus = focusNode;
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
                          final selected = await _showModulePicker(
                              context, provider.availableModuleImports);
                          if (selected != null) {
                            provider.updateDeviceValue(deviceKey, 'module', selected);
                            // Show whatever was actually stored, so the prefix
                            // the provider adds is visible in the field.
                            controller.text =
                                provider.roomConfig[deviceKey]?['module']
                                        ?.toString() ??
                                    selected;
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
                  // Keep the visible field in sync with the stored (prefixed)
                  // import path rather than the raw relative name.
                  moduleFieldController?.text =
                      provider.roomConfig[deviceKey]?['module']?.toString() ??
                          modPath;
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
                initialValue: currentValue, 
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

        // --- INPUT (fixed slot, under Keep Alive) ---
        // Rendered here so it appears the instant a device is created and
        // never shifts position when Apply Changes re-sorts the JSON keys.
        //  - device_fields override (e.g. projector -> module_states): the
        //    schema-driven field, shown even before 'input' exists in the
        //    block (addIfMissing) so a new projector has it right away.
        //  - otherwise: the legacy autocomplete, when the block has 'input'.
        if (inputHasSchemaOverride)
          SchemaFieldBuilder.buildField(
                context: context,
                provider: provider,
                sectionKey: deviceKey,
                fieldKey: 'input',
                value: deviceData['input'], // may be null before first edit
              ) ??
              const SizedBox.shrink()
        else if (deviceData.containsKey('input'))
          _wrapWithInfo(context, 'input', FutureBuilder<List<String>>(
            future: provider.getInputsForModule(moduleName),
            builder: (context, snapshot) {
              List<String> inputs = snapshot.data ?? [];
              String currentValue = deviceData['input']?.toString() ?? '';
              FocusNode? inputFieldFocus;

              return Autocomplete<String>(
                initialValue: TextEditingValue(text: currentValue),
                optionsBuilder: (TextEditingValue textEditingValue) {
                  if (textEditingValue.text == '') return inputs;
                  return searchFilter(inputs, textEditingValue.text);
                },
                onSelected: (String selection) {
                  inputFieldFocus?.unfocus(); // Close the options overlay
                  provider.updateDeviceValue(deviceKey, 'input', selection);
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  inputFieldFocus = focusNode;
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
        if (inputHasSchemaOverride || deviceData.containsKey('input'))
          const SizedBox(height: 20),

        const Divider(height: 50, thickness: 2),
        Text('Standard Configuration', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        // --- AUTO-GENERATED FIELDS ---
        ...dynamicFormFields,
      ],
    );
  }
}