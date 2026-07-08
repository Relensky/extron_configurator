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
    final FieldSpec? spec = schema.specFor(fieldKey);
    final String type = _resolveType(spec, value);

    if (type == 'hidden') return null;

    final String label = spec?.label ?? fieldKey;
    Widget field;

    switch (type) {
      case 'combo':
        field = _buildCombo(context, provider, sectionKey, fieldKey, spec!, label);
        break;
      case 'dropdown':
        field = _buildDropdown(context, provider, sectionKey, fieldKey, spec!, label, value);
        break;
      case 'bool':
        field = SwitchListTile(
          title: Text(label),
          subtitle: spec?.helperText != null ? Text(spec!.helperText!) : null,
          value: value == true,
          onChanged: (val) => provider.updateDeviceValue(sectionKey, fieldKey, val),
        );
        break;
      case 'int':
      case 'double':
      case 'text':
      default:
        field = _buildTextField(provider, sectionKey, fieldKey, spec, label, type, value);
        break;
    }

    return _wrapWithInfo(context, schema, fieldKey, field);
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
  static Widget _buildTextField(AppStateProvider provider, String sectionKey,
      String fieldKey, FieldSpec? spec, String label, String type, dynamic value) {
    return TextFormField(
      initialValue: value?.toString() ?? '',
      keyboardType: (type == 'int' || type == 'double')
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: spec?.helperText,
        border: const OutlineInputBorder(),
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
    if (current.isNotEmpty && !listed) {
      options.insert(0, OptionSpec(value: current, label: '$current (not in schema)'));
    }

    return DropdownButtonFormField<String>(
      value: current.isNotEmpty ? current : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: spec.helperText,
        border: const OutlineInputBorder(),
      ),
      items: options
          .map((o) => DropdownMenuItem(value: o.value, child: Text(o.label)))
          .toList(),
      onChanged: (val) {
        if (val != null) provider.updateDeviceValue(sectionKey, fieldKey, val);
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
    if (!listed && currentComboKey.replaceAll('_', '').isNotEmpty) {
      options.insert(
          0,
          OptionSpec(
              value: currentComboKey,
              label: '$currentComboKey (not in schema)'));
    }

    return DropdownButtonFormField<String>(
      value: currentComboKey.replaceAll('_', '').isNotEmpty ? currentComboKey : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: spec.helperText,
        border: const OutlineInputBorder(),
      ),
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
  /// schema (falling back to the legacy built-in ConfigDictionary).
  static Widget _wrapWithInfo(
      BuildContext context, UiSchema schema, String key, Widget field) {
    final desc = schema.descriptionFor(key);
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
