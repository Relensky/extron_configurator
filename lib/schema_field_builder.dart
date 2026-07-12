import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui_schema.dart';

/// ============================================================================
///  SCHEMA-DRIVEN FIELD BUILDER
/// ============================================================================
///  Single place that turns (config key, current value) into the right editor
///  widget, using the loaded UiSchema. Used by both SystemSettingsView and
///  DynamicDevicesView, so any key added to ui_schema.json instantly gets the
///  same treatment on every tab — no rebuild required.
/// ============================================================================
class SchemaFieldBuilder {
  /// Builds the editor widget for one config property.
  /// Returns null when the schema marks the key "hidden" (caller skips it).
  ///
  /// [sectionKey] is the top-level config block (e.g. 'SYSTEM_SETUP' or
  /// 'PROJECTORDEVICE_1'); writes go through provider.updateDeviceValue.
  static Widget? buildField({
    required BuildContext context,
    required AppStateProvider provider,
    required String sectionKey,
    required String fieldKey,
    required dynamic value,
  }) {
    final schema = provider.uiSchema;
    // Device-scoped entries (ui_schema.json "device_fields") win for keys
    // inside a matching device block, then the global "fields" entries.
    final FieldSpec? spec = schema.specFor(fieldKey, sectionKey: sectionKey);
    final String type = _resolveType(spec, value);

    if (type == 'hidden') return null;

    // UNKNOWN KEY: no schema entry (exact or wildcard) AND no legacy
    // dictionary description. Rendered with a red outline + warning icon so
    // unrecognized config items stand out for schema maintenance.
    final bool isUnknown = spec == null &&
        schema.descriptionFor(fieldKey, sectionKey: sectionKey) == null;

    final String label = spec?.label ?? fieldKey;
    Widget field;

    switch (type) {
      case 'combo':
        field = _buildCombo(context, provider, sectionKey, fieldKey, spec!, label);
        break;
      case 'dropdown':
        field = _buildDropdown(context, provider, sectionKey, fieldKey, spec!, label, value);
        break;
      case 'module_states':
        field = _buildModuleStates(
            context, provider, sectionKey, fieldKey, spec!, label, value);
        break;
      case 'bool':
        field = SwitchListTile(
          title: Text(label),
          subtitle: spec?.helperText != null ? Text(spec!.helperText!) : null,
          value: value == true,
          onChanged: (val) => provider.updateDeviceValue(sectionKey, fieldKey, val),
        );
        if (isUnknown) {
          // Switches have no InputDecoration, so outline the whole tile
          field = Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.red.shade400, width: 1.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: field,
          );
        }
        break;
      case 'int':
      case 'double':
      case 'text':
      default:
        field = _buildTextField(
            provider, sectionKey, fieldKey, spec, label, type, value, isUnknown);
        break;
    }

    return _wrapWithInfo(context, schema, fieldKey, field,
        isUnknown: isUnknown, sectionKey: sectionKey);
  }

  /// Schema type wins; 'auto' (or no spec) falls back to inferring from the
  /// live JSON value — the same behavior the views had before.
  static String _resolveType(FieldSpec? spec, dynamic value) {
    final t = spec?.type ?? 'auto';
    if (t != 'auto') return t;
    if (value is bool) return 'bool';
    if (value is int) return 'int';
    if (value is double) return 'double';
    return 'text';
  }

  // --- TEXT / INT / DOUBLE -------------------------------------------------
  static Widget _buildTextField(
      AppStateProvider provider,
      String sectionKey,
      String fieldKey,
      FieldSpec? spec,
      String label,
      String type,
      dynamic value,
      bool isUnknown) {
    // Unknown keys get a red outline in every state + a red helper line
    final OutlineInputBorder? redBorder = isUnknown
        ? OutlineInputBorder(
            borderSide: BorderSide(color: Colors.red.shade400, width: 1.5))
        : null;

    return TextFormField(
      initialValue: value?.toString() ?? '',
      keyboardType: (type == 'int' || type == 'double')
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: isUnknown
            ? 'Not in UI schema — add "$fieldKey" to ui_schema.json'
            : spec?.helperText,
        helperStyle: isUnknown ? TextStyle(color: Colors.red.shade400) : null,
        border: redBorder ?? const OutlineInputBorder(),
        enabledBorder: redBorder,
        focusedBorder: isUnknown
            ? OutlineInputBorder(
                borderSide: BorderSide(color: Colors.red.shade400, width: 2))
            : null,
      ),
      onChanged: (val) {
        dynamic parsedVal = val;
        // Respect the declared schema type first, then the live value's type,
        // so config.json keeps clean numeric types either way.
        if (type == 'int' || value is int) {
          parsedVal = int.tryParse(val) ?? 0;
        } else if (type == 'double' || value is double) {
          parsedVal = double.tryParse(val) ?? 0.0;
        }
        provider.updateDeviceValue(sectionKey, fieldKey, parsedVal);
      },
    );
  }

  // --- DROPDOWN --------------------------------------------------------------
  static Widget _buildDropdown(BuildContext context, AppStateProvider provider,
      String sectionKey, String fieldKey, FieldSpec spec, String label, dynamic value) {
    final String current = value?.toString() ?? '';
    final List<OptionSpec> options = List.of(spec.options);

    // SAFETY: if the config holds a value the schema doesn't list, show it
    // (marked) instead of blanking the field — no silent data loss.
    final bool listed = options.any((o) => o.value == current);
    final bool valueMismatch = current.isNotEmpty && !listed;
    if (valueMismatch) {
      options.insert(0, OptionSpec(value: current, label: '$current (not in schema)'));
    }

    return DropdownButtonFormField<String>(
      value: current.isNotEmpty ? current : null,
      decoration: _decoration(label, spec.helperText,
          mismatch: valueMismatch,
          mismatchText: 'Value "$current" is not in the schema options — pick a valid option'),
      items: options
          .map((o) => DropdownMenuItem(value: o.value, child: Text(o.label)))
          .toList(),
      onChanged: (val) {
        if (val != null) provider.updateDeviceValue(sectionKey, fieldKey, val);
      },
    );
  }

  /// Shared InputDecoration: normal grey outline, or red in every state (with
  /// a red helper line) when the current value doesn't match the schema.
  static InputDecoration _decoration(String label, String? helperText,
      {bool mismatch = false, String? mismatchText}) {
    final OutlineInputBorder? red = mismatch
        ? OutlineInputBorder(
            borderSide: BorderSide(color: Colors.red.shade400, width: 1.5))
        : null;
    return InputDecoration(
      labelText: label,
      helperText: mismatch ? mismatchText : helperText,
      helperStyle: mismatch ? TextStyle(color: Colors.red.shade400) : null,
      helperMaxLines: 2,
      border: red ?? const OutlineInputBorder(),
      enabledBorder: red,
      focusedBorder: mismatch
          ? OutlineInputBorder(
              borderSide: BorderSide(color: Colors.red.shade400, width: 2))
          : null,
    );
  }

  // --- MODULE STATES (options parsed live from the device's .py module) ------
  /// Autocomplete whose options are the states of ONE command in the device's
  /// selected Python module (spec.moduleCommand, e.g. 'Input'), parsed from
  /// self.Commands' AllowedValues / the Set method's ValueStateValues dict.
  /// Manual typing is always allowed, so an unlisted state is never blocked.
  static Widget _buildModuleStates(
      BuildContext context,
      AppStateProvider provider,
      String sectionKey,
      String fieldKey,
      FieldSpec spec,
      String label,
      dynamic value) {
    final section = provider.roomConfig[sectionKey];
    final String moduleName =
        (section is Map ? section['module'] : null)?.toString() ?? '';
    final String command = spec.moduleCommand ?? fieldKey;
    final String current = value?.toString() ?? '';

    return FutureBuilder<List<String>>(
      future: provider.getStatesForModuleCommand(moduleName, command),
      builder: (context, snapshot) {
        final List<String> states = snapshot.data ?? [];
        final String helper;
        if (moduleName.isEmpty) {
          helper = "Select a Python module first — options come from its '$command' command";
        } else if (states.isNotEmpty) {
          helper = "${states.length} states from '$command' in $moduleName.py";
        } else if (snapshot.connectionState == ConnectionState.waiting) {
          helper = 'Parsing $moduleName.py...';
        } else {
          helper = "Command '$command' not found in $moduleName.py — type the value manually";
        }

        return Autocomplete<String>(
          // Remount when the module changes so initialValue re-applies; a
          // stable key while typing keeps the cursor from resetting.
          key: ValueKey('$sectionKey.$fieldKey.$moduleName'),
          initialValue: TextEditingValue(text: current),
          optionsBuilder: (TextEditingValue textEditingValue) {
            // Show the FULL list while the field still holds the saved value,
            // otherwise it filters itself down to one entry (same pattern as
            // the module picker).
            final text = textEditingValue.text;
            if (text.isEmpty || text == current) return states;
            return states.where(
                (s) => s.toLowerCase().contains(text.toLowerCase()));
          },
          onSelected: (String selection) =>
              provider.updateDeviceValue(sectionKey, fieldKey, selection),
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            return TextFormField(
              controller: controller,
              focusNode: focusNode,
              decoration: _decoration('$label (type or select)', helper),
              onChanged: (val) =>
                  provider.updateDeviceValue(sectionKey, fieldKey, val),
            );
          },
        );
      },
    );
  }

  // --- COMBO (one dropdown -> multiple config keys) --------------------------
  static Widget _buildCombo(BuildContext context, AppStateProvider provider,
      String sectionKey, String fieldKey, FieldSpec spec, String label) {
    final section = provider.roomConfig[sectionKey];
    final List<String> writes =
        spec.writes.isNotEmpty ? spec.writes : [fieldKey];

    // Current combo identity = the written keys' values joined with "_"
    // (e.g. gui_inputs "5" + gui_tab_type "DOC_USB_WL" -> "5_DOC_USB_WL")
    final String currentComboKey = writes
        .map((k) => (section is Map ? section[k] : null)?.toString() ?? '')
        .join('_');

    final List<OptionSpec> options = List.of(spec.options);
    final bool listed = options.any((o) => o.comboKey == currentComboKey);
    final bool hasValue = currentComboKey.replaceAll('_', '').isNotEmpty;
    final bool valueMismatch = hasValue && !listed;
    if (valueMismatch) {
      options.insert(
          0,
          OptionSpec(
              value: currentComboKey,
              label: '$currentComboKey (not in schema)'));
    }

    return DropdownButtonFormField<String>(
      value: hasValue ? currentComboKey : null,
      decoration: _decoration(label, spec.helperText,
          mismatch: valueMismatch,
          mismatchText:
              'Combined value "$currentComboKey" (${writes.join(' + ')}) is not in the schema options — pick a valid option'),
      items: options
          .map((o) => DropdownMenuItem(value: o.comboKey, child: Text(o.label)))
          .toList(),
      onChanged: (val) {
        if (val == null) return;
        final chosen = spec.options.firstWhere(
          (o) => o.comboKey == val,
          orElse: () => OptionSpec(value: val),
        );
        if (chosen.values != null && chosen.values!.length == writes.length) {
          // Preferred path: explicit per-key values from the schema
          for (int i = 0; i < writes.length; i++) {
            provider.updateDeviceValue(sectionKey, writes[i], chosen.values![i]);
          }
        } else if (writes.length == 2) {
          // Legacy fallback: split at the first underscore (old behavior)
          final splitIdx = val.indexOf('_');
          if (splitIdx != -1) {
            provider.updateDeviceValue(sectionKey, writes[0], val.substring(0, splitIdx));
            provider.updateDeviceValue(sectionKey, writes[1], val.substring(splitIdx + 1));
          }
        }
      },
    );
  }

  // --- INFO (i) BUTTON --------------------------------------------------------
  /// Wraps a field with the info button when a description exists in the
  /// schema (falling back to the legacy built-in ConfigDictionary). Unknown
  /// keys get a red warning icon instead, explaining how to add them.
  static Widget _wrapWithInfo(
      BuildContext context, UiSchema schema, String key, Widget field,
      {bool isUnknown = false, String? sectionKey}) {
    if (isUnknown) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: field),
          IconButton(
            icon: Icon(Icons.warning_amber_rounded, color: Colors.red.shade400),
            tooltip: 'This key is not defined in the UI schema',
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Row(children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red.shade400),
                    const SizedBox(width: 8),
                    Expanded(child: Text(key)),
                  ]),
                  content: Text(
                      'The key "$key" is not defined in ui_schema.json (or the '
                      'built-in dictionary), so it is rendered as a plain field '
                      'with no description or validation.\n\n'
                      'To fix: add an entry for "$key" under "fields" in '
                      'ui_schema.json (label, description, type, options...), '
                      'then press Reload Schema in the App Config tab.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Close'))
                  ],
                ),
              );
            },
          ),
        ],
      );
    }

    final desc = schema.descriptionFor(key, sectionKey: sectionKey);
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
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'))
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
