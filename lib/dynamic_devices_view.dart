import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'app_state.dart';
import 'av_flow_swap_dialogs.dart' show syncDrawnDeviceToModel;
import 'config_dictionary.dart';
import 'config_maintenance.dart';
import 'device_info_editor.dart';
import 'model_defaults_dialog.dart';
import 'pdf_viewer_dialog.dart';
import 'schema_field_builder.dart';
import 'search_match.dart';

/// The config's live device blocks, in device-family order: for each dev_
/// count key, the sections that actually exist up to that count.
///
/// Top-level (not a method) because the Devices tab, the Schematic tab and the
/// AV Flow tab all need the same answer — "which devices does this room
/// really have?" — and they must agree.
/// The implementation lives in app_state.dart so the provider can answer the
/// same question about its own config (the missing-module check needs it, and
/// a second copy of this rule is a second answer waiting to disagree).
List<String> getActiveDeviceKeys(
        Map<String, dynamic> config, Map<String, String> map) =>
    activeDeviceKeysIn(config, map);

class DynamicDevicesTabsView extends StatefulWidget {
  const DynamicDevicesTabsView({super.key});

  @override
  State<DynamicDevicesTabsView> createState() => _DynamicDevicesTabsViewState();
}

class _DynamicDevicesTabsViewState extends State<DynamicDevicesTabsView> {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final config = provider.roomConfig;
    if (config.isEmpty) return const Center(child: Text("No configuration template loaded."));

    final activeKeys =
        getActiveDeviceKeys(config, provider.uiSchema.deviceCountMap);
    if (activeKeys.isEmpty) return const Center(child: Text("No devices found based on dev_ parameters."));

    // WHICH TAB THIS OPENS ON. A flag on the project tab, a row on the
    // undriven list, a device on the estimate: all of them name a device, and
    // landing on the first of fourteen tabs threw that away. The controller is
    // keyed on the request, so asking for another device rebuilds it there;
    // moving between tabs by hand does not rebuild it at all.
    final wanted = provider.requestedDeviceKey;
    final at = activeKeys.indexOf(wanted);

    return DefaultTabController(
      key: ValueKey('devices_tabs_${at < 0 ? '' : wanted}_${activeKeys.length}'),
      initialIndex: at < 0 ? 0 : at,
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
    // What the block says it is now — the needle for the rename below, read
    // before anything writes over it.
    final was =
        (provider.roomConfig[deviceKey] as Map?)?['model']?.toString().trim() ??
            '';
    final preview = provider.previewModelSelection(deviceKey, model);

    /// The rest of the room. The estimate counts the boxes on the DIAGRAM and
    /// the schematic draws them, so a model that stopped at the config block
    /// left the room describing two different products at once. Returns the
    /// sentence to add to the acknowledgement, or '' when there was nothing
    /// drawn to move.
    String syncTheRoom() {
      // The name follows the product it names — "Projector 1 - PowerLite
      // L630U" — on the block and on the box, and only the model part of it.
      provider.renameDeviceForModel(deviceKey, was, model);
      final drawn = syncDrawnDeviceToModel(provider, deviceKey, model);
      if (drawn == null) return '';
      return [
        ' The box on the diagram is a $model now',
        if (drawn.full && drawn.carried > 0)
          ', with ${drawn.carried} cable'
              '${drawn.carried == 1 ? '' : 's'} carried across',
        if (drawn.full && drawn.dropped > 0)
          '; ${drawn.dropped} cable${drawn.dropped == 1 ? '' : 's'} had no '
              'matching connector and ${drawn.dropped == 1 ? 'was' : 'were'} '
              'removed',
        if (!drawn.full)
          ' - its connectors are unchanged, because the AV catalog has no '
              'entry for this model',
        '.',
      ].join();
    }

    // Unknown model: no module claims it — just save the text.
    if (!preview.known) {
      provider.keepSettingsSwitchModule(deviceKey, model);
      moduleController?.text =
          provider.roomConfig[deviceKey]?['module']?.toString() ?? '';
      final also = syncTheRoom();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              "Model saved - no module claims this model, so the control side "
              "still needs one.$also")));
      return;
    }

    // Module already matches: nothing to decide, keep everything as-is.
    if (!preview.moduleChanged) {
      provider.keepSettingsSwitchModule(deviceKey, model);
      moduleController?.text = preview.newModule;
      final also = syncTheRoom();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              "Model '$model' set - already using module "
              "${preview.newModule}.$also")));
      return;
    }

    // Module changes: ask apply-defaults (new) vs keep-settings (conversion).
    final applyDefaults = await _showModelChangeDialog(context, model, preview);
    if (applyDefaults == null || !context.mounted) return; // canceled

    moduleController?.text = preview.newModule;
    if (applyDefaults) {
      final applied = provider.applyModuleDefaults(deviceKey, model);
      final also = syncTheRoom();
      if (!context.mounted) return;
      final msg = applied.isEmpty
          ? "Model '$model' saved - module defaults already in place.$also"
          : "Model '$model': set ${applied.join(', ')}.$also";
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } else {
      provider.keepSettingsSwitchModule(deviceKey, model);
      final n = preview.diffs.length;
      final also = syncTheRoom();
      if (!context.mounted) return;
      final msg = n == 0
          ? "Kept current settings - switched to module "
              "${preview.newModule}.$also"
          : "Kept current settings - $n field${n == 1 ? '' : 's'} differ from "
              "${preview.newModule} defaults.$also";
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Prompt shown when a model pick switches the device to a different module.
  /// Lists the fields that differ from the new module's defaults and lets the
  /// user apply the module defaults or keep the current settings.
  /// Returns true = apply defaults, false = keep settings, null = canceled.
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
  //
  // [onDelete] adds the same trash button the auto-generated fields carry.
  // The fields with a slot of their own — model, module, keep alive, input —
  // were the ones it was missing from, which made a handful of perfectly
  // ordinary keys look permanent.
  Widget _wrapWithInfo(BuildContext context, String key, Widget field,
      {VoidCallback? onDelete}) {
    final desc = context.read<AppStateProvider>().uiSchema.descriptionFor(key)
        ?? ConfigDictionary.descriptions[key];
    if (desc == null && onDelete == null) return field;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        if (desc != null)
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
          ),
        if (onDelete != null)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove "$key" from the config',
            onPressed: onDelete,
          ),
      ],
    );
  }

  /// THE MODEL/MODULE BANNER.
  ///
  /// A device block names a product and names the driver that talks to it, and
  /// nothing kept the two together: retype the model, or swap the box from the
  /// Cost tab, and the module underneath went on naming a driver for the
  /// product that used to be there. Every field is filled in, so the block
  /// reads as finished — and a room gets commissioned as a device it does not
  /// contain.
  ///
  /// Red, at the top of the device, above the two fields that fix it. It is
  /// derived from the config rather than from anything this page remembers, so
  /// it survives leaving the tab, saving, and reopening the room — and it goes
  /// away the moment a module is chosen, which is the only thing that actually
  /// resolves it.
  Widget? _modelModuleBanner(BuildContext context, AppStateProvider provider) {
    final fault = provider.deviceModelModuleFault(deviceKey);
    if (fault == null) return null;
    final theme = Theme.of(context);
    // ALREADY ANSWERED. The catalog says this product never needs a driver, so
    // the block is finished and the page says which decision made it finished
    // - it does not ask for a module in red. Same slot, same key, different
    // sentence: somebody checking the room file against the rack still wants
    // to SEE that the laptop plate is deliberately driverless.
    if (fault.fault == ModelModuleFault.noModuleNeeded) {
      return Container(
        key: ValueKey('model_module_banner_$deviceKey'),
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.block,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No module needed for "${fault.model}"',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'The catalog says this product has no control interface, '
                    'so nothing drives it anywhere and this block is finished '
                    'without one. It is not on the room\'s missing-module '
                    'list. Change that on the Catalog tab if the product does '
                    'need a driver after all.',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final noModule = fault.fault == ModelModuleFault.noModule;
    return Container(
      key: ValueKey('model_module_banner_$deviceKey'),
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: theme.colorScheme.error),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  noModule
                      ? 'No python module for model "${fault.model}"'
                      : '"${fault.model}" is not a model '
                            '${AppStateProvider.moduleStem(fault.module)} '
                            'drives',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  noModule
                      ? 'The processor has nothing to talk to this device '
                            'with, so the room will not commission. Pick a '
                            'module below - or set the model back to one a '
                            'driver claims.'
                      : 'That driver covers ${_claimList(fault.claims)}. The '
                            'block would be commissioned as one of those, not '
                            'as a ${fault.model}. Pick the right module below, '
                            'or correct the model.',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The models a driver names, as prose — trimmed, because a family driver
  /// can list a dozen and the point is made by three.
  static String _claimList(List<String> claims) {
    if (claims.length <= 3) return claims.join(', ');
    return '${claims.take(3).join(', ')} and ${claims.length - 3} more';
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
    // Deleted in this session and not since typed back in — the same rule the
    // placeholder pass below follows, applied to the one field that has a slot
    // of its own.
    final bool inputOmitted =
        !deviceData.containsKey('input') &&
        provider.isConfigKeyOmitted(deviceKey, 'input');
    final bool inputHasSchemaOverride =
        !inputOmitted &&
        provider.uiSchema.deviceSpecFor(deviceKey, 'input') != null;
    // 'model' renders in its own dedicated slot at the top (Model dropdown),
    // like 'module' — never in the auto-generated list below.
    final skipKeys = ['module', 'keep_alive_command', 'input', 'model'];

    // Alphabetical, matching how the config is sorted on save — so a field's
    // position doesn't move after Apply Changes / export re-orders the JSON.
    final List<String> sortedKeys =
        (deviceData as Map).keys.map((k) => k.toString()).toList()..sort();

    // DEVICE-TYPE-ONLY FIELDS: "device_fields" entries flagged addIfMissing
    // render even before the key exists in this device block — the first
    // edit writes the key into config.json. Lets a new device-type setting
    // (e.g. a projector-only option) ship via ui_schema.json alone. ('input'
    // is handled by its own dedicated slot above and is skipped here.)
    final List<String> placeholderKeys = [
      for (final spec in provider.uiSchema.missingFieldsFor(
        deviceKey,
        sortedKeys,
        section: deviceData.map((k, v) => MapEntry(k.toString(), v)),
      ))
        // Deleted in this session: the schema is offering the key back, and
        // the user has already said no. Putting the placeholder up again is
        // what made these look undeletable — the trash button worked and the
        // field reappeared, so nothing seemed to happen.
        if (!provider.isConfigKeyOmitted(deviceKey, spec.key)) spec.key,
    ];

    // ONE LIST, ONE ORDER. A placeholder sits exactly where the key will sit
    // once it has a value, rather than in a group of its own after the real
    // fields.
    //
    // That is not a tidiness question. The first keystroke in a placeholder
    // WRITES the key, so a converted device typing a baud rate into a field
    // parked at the bottom had that field jump to its alphabetical position
    // near the top on the very next frame — off the visible part of a lazy
    // ListView, which threw its state away and took the caret with it. One
    // sorted list means nothing moves, so the field keeps the focus and the
    // rest of the number can be typed.
    final List<String> formKeys = [
      ...sortedKeys,
      ...placeholderKeys,
    ]..sort();

    List<Widget> dynamicFormFields = [];
    for (final key in formKeys) {
      if (skipKeys.contains(key)) continue;

      // SCHEMA-DRIVEN: labels, descriptions, dropdowns, and widget types
      // come from ui_schema.json (with type inference as the fallback), so a
      // new device property can get a full editor UI without a rebuild.
      final Widget? field = SchemaFieldBuilder.buildField(
        context: context,
        provider: provider,
        sectionKey: deviceKey,
        fieldKey: key,
        // Null for a placeholder — the key is not in the block yet.
        value: deviceData[key],
        // Any property can be removed (confirmed); the Check Defaults
        // button in the header adds it back later if needed. A placeholder is
        // deletable too — declining the offer is the whole point of the button
        // on a device whose connection has no use for it.
        onDelete: () =>
            confirmRemoveConfigKey(context, provider, deviceKey, key),
      );
      if (field == null) continue; // Schema marked the key "hidden"

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
            const SizedBox(width: 8),
            // The other half of the question. "Check Defaults" is about keys
            // this block is MISSING; this is about keys it has FILLED IN
            // DIFFERENTLY from what the model's own python driver says — the
            // device converted to SSH because its family is SSH, while its
            // driver states TCP on a port of its own. Same review the
            // conversion offers, put to one device on demand.
            OutlinedButton.icon(
              icon: const Icon(Icons.rule),
              label: const Text('Check Module Defaults'),
              onPressed: () => offerModelDefaults(
                context,
                provider,
                silentWhenClean: false,
                onlySection: deviceKey,
              ),
            ),
            // THE SAME CHECK, AGAINST THE FILE AS IT IS NOW. Drivers are
            // parsed once and kept - see [AppStateProvider.reloadModules] -
            // so somebody who has just edited one in the next window is
            // looking at an app that still believes the old copy. This
            // re-reads the folder first. Icon-only: it is the rarer of the
            // two and the row is already three controls wide.
            IconButton(
              key: const ValueKey('recheck_module_defaults'),
              icon: const Icon(Icons.sync),
              tooltip: 'Re-read the python modules from disk, then check '
                  'this device against them',
              onPressed: () => offerModuleRecheck(
                context,
                provider,
                onlySection: deviceKey,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Above the two fields that fix it, so the sentence and the
        // answer are on screen together.
        ?_modelModuleBanner(context, provider),

        // --- MODEL SELECTOR (aggregated from every module's model dict) ---
        // Picking a model switches 'module' to that model's default .py and
        // applies the module's DEVICE_INFO connection defaults.
        _wrapWithInfo(context, 'model',
          onDelete: deviceData.containsKey('model')
              ? () => confirmRemoveConfigKey(context, provider, deviceKey, 'model')
              : null,
          Row(
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
                          ? 'No models found - add DEVICE_INFO dicts to the python modules'
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
        _wrapWithInfo(context, 'module',
          onDelete: deviceData.containsKey('module')
              ? () => confirmRemoveConfigKey(context, provider, deviceKey, 'module')
              : null,
          Row(
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
                          ? 'No modules found in ${provider.effectiveModulesPath} - check the Python Modules Path in App Config'
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
            const SizedBox(width: 8),
            // WHAT THIS DRIVER SAYS ABOUT ITSELF, editable. A model typed in
            // by hand on a device whose driver declares no models is the
            // symptom this answers: open the driver, give it a DEVICE_INFO,
            // and the model is on the dropdown from then on.
            IconButton(
              key: const ValueKey('edit_module_device_info'),
              icon: const Icon(Icons.description),
              tooltip: 'Edit what this python module declares - its models, '
                  'device family and connection defaults',
              onPressed: () => showDeviceInfoEditor(
                context,
                module: moduleName.isEmpty ? null : moduleName,
              ),
            ),
          ],
        )),
        const SizedBox(height: 20),

        // --- DYNAMIC KEEP ALIVE DROPDOWN ---
        if (moduleName.isNotEmpty)
          _wrapWithInfo(context, 'keep_alive_command',
            onDelete: deviceData.containsKey('keep_alive_command')
                ? () => confirmRemoveConfigKey(
                    context, provider, deviceKey, 'keep_alive_command')
                : null,
            FutureBuilder<List<String>>(
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
                onDelete: () =>
                    confirmRemoveConfigKey(context, provider, deviceKey, 'input'),
              ) ??
              const SizedBox.shrink()
        else if (deviceData.containsKey('input'))
          _wrapWithInfo(context, 'input',
            onDelete: () =>
                confirmRemoveConfigKey(context, provider, deviceKey, 'input'),
            FutureBuilder<List<String>>(
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