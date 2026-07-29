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
  /// [onDelete], when given, adds a trash button after the field that lets
  /// the user remove the key from the config block entirely (the caller
  /// confirms and performs the removal). Check Defaults can re-add it later.
  static Widget? buildField({
    required BuildContext context,
    required AppStateProvider provider,
    required String sectionKey,
    required String fieldKey,
    required dynamic value,
    VoidCallback? onDelete,
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

    // "labelWhen" lets the label follow other values in the same block, so
    // input_usb reads "VGA over USB" in a VGA room and keeps its plain label
    // otherwise.
    final String label =
        schema.labelFor(fieldKey, _sectionMap(provider, sectionKey),
                sectionKey: sectionKey) ??
            fieldKey;
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
        isUnknown: isUnknown, sectionKey: sectionKey, onDelete: onDelete);
  }

  /// The config block [sectionKey] names, as a plain string-keyed map (empty
  /// when the section is missing). Feeds the schema's "labelWhen" conditions
  /// and "consistency" checks, which both read sibling keys.
  static Map<String, dynamic> _sectionMap(
      AppStateProvider provider, String sectionKey) {
    final section = provider.roomConfig[sectionKey];
    if (section is! Map) return const {};
    return section.map((k, v) => MapEntry(k.toString(), v));
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
  // Controller-backed so a value written programmatically (e.g. "Apply module
  // defaults") shows up immediately, instead of the field keeping its stale
  // mount-time text until a forced remount.
  static Widget _buildTextField(
      AppStateProvider provider,
      String sectionKey,
      String fieldKey,
      FieldSpec? spec,
      String label,
      String type,
      dynamic value,
      bool isUnknown) {
    return _SyncedTextField(
      // Remount when the field's identity changes (switching device tabs), so
      // a fresh controller is seeded from the new device's value.
      key: ValueKey('$sectionKey.$fieldKey'),
      provider: provider,
      sectionKey: sectionKey,
      fieldKey: fieldKey,
      spec: spec,
      label: label,
      type: type,
      value: value,
      isUnknown: isUnknown,
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

    // A schema "consistency" rule this field is flagged by (e.g. gui_usb_or_vga
    // disagreeing with the VGA/USB source in gui_tab_type). The value is still
    // a legal option, so this only warns — an out-of-schema value wins the
    // helper line because it's the more basic problem.
    final String? conflict = provider.uiSchema.consistencyMessageFor(
        fieldKey, sectionKey, _sectionMap(provider, sectionKey));

    return DropdownButtonFormField<String>(
      value: current.isNotEmpty ? current : null,
      decoration: _decoration(label, spec.helperText,
          mismatch: valueMismatch || conflict != null,
          mismatchText: valueMismatch
              ? 'Value "$current" is not in the schema options — pick a valid option'
              : conflict),
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

        FocusNode? fieldFocus;
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
          onSelected: (String selection) {
            fieldFocus?.unfocus(); // Close the options overlay
            provider.updateDeviceValue(sectionKey, fieldKey, selection);
          },
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            fieldFocus = focusNode;
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

    // Same consistency check the plain dropdowns run, so a VGA/USB
    // disagreement is visible from the sources side too, not just on
    // gui_usb_or_vga.
    final String? conflict = provider.uiSchema.consistencyMessageFor(
        fieldKey, sectionKey, _sectionMap(provider, sectionKey));

    return DropdownButtonFormField<String>(
      value: hasValue ? currentComboKey : null,
      decoration: _decoration(label, spec.helperText,
          mismatch: valueMismatch || conflict != null,
          mismatchText: valueMismatch
              ? 'Combined value "$currentComboKey" (${writes.join(' + ')}) is not in the schema options — pick a valid option'
              : conflict),
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

  // --- INFO (i) / DELETE BUTTONS ---------------------------------------------
  /// Wraps a field with its trailing buttons: the info button when a
  /// description exists (falling back to the legacy built-in
  /// ConfigDictionary), a red warning icon for unknown keys, and — when the
  /// caller provides [onDelete] — a trash button that removes the key from
  /// the config block.
  static Widget _wrapWithInfo(
      BuildContext context, UiSchema schema, String key, Widget field,
      {bool isUnknown = false, String? sectionKey, VoidCallback? onDelete}) {
    final List<Widget> trailing = [];

    if (isUnknown) {
      trailing.add(IconButton(
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
      ));
    } else {
      final desc = schema.descriptionFor(key, sectionKey: sectionKey);
      if (desc != null) {
        trailing.add(IconButton(
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
        ));
      }
    }

    if (onDelete != null) {
      trailing.add(IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove "$key" from the config',
        onPressed: onDelete,
      ));
    }

    if (trailing.isEmpty) return field;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [Expanded(child: field), ...trailing],
    );
  }
}

/// The text/int/double editor. Holds its own TextEditingController and keeps
/// it in sync with the stored value: when the value changes EXTERNALLY (an
/// applied module default, a raw-JSON edit) the field updates right away, but
/// the user's own typing never resets the cursor (the controller already
/// holds that text, so no sync fires).
class _SyncedTextField extends StatefulWidget {
  final AppStateProvider provider;
  final String sectionKey;
  final String fieldKey;
  final FieldSpec? spec;
  final String label;
  final String type;
  final dynamic value;
  final bool isUnknown;

  const _SyncedTextField({
    Key? key,
    required this.provider,
    required this.sectionKey,
    required this.fieldKey,
    required this.spec,
    required this.label,
    required this.type,
    required this.value,
    required this.isUnknown,
  }) : super(key: key);

  @override
  State<_SyncedTextField> createState() => _SyncedTextFieldState();
}

class _SyncedTextFieldState extends State<_SyncedTextField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  bool get _isNumeric =>
      widget.type == 'int' ||
      widget.type == 'double' ||
      widget.value is int ||
      widget.value is double;

  // TOUCH-PANEL LINE BREAKS: config values store panel line breaks as the
  // two-character sequence \r (written to disk as \\r). Show them as REAL line
  // breaks so the field reads the way the panel will render it.
  String _display(dynamic v) {
    final raw = v?.toString() ?? '';
    return _isNumeric ? raw : raw.replaceAll(r'\r', '\n');
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _display(widget.value));
  }

  @override
  void didUpdateWidget(covariant _SyncedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Adopt an external write (an applied module default, a raw-JSON edit) as
    // soon as it lands — but only while the user isn't editing this field, so
    // their own typing (including a transient invalid numeric entry) is never
    // reset out from under the cursor. Cursor goes to the end on adoption.
    final incoming = _display(widget.value);
    if (!_focusNode.hasFocus && incoming != _controller.text) {
      _controller.value = TextEditingValue(
        text: incoming,
        selection: TextSelection.collapsed(offset: incoming.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Unknown keys get a red outline in every state + a red helper line
    final OutlineInputBorder? redBorder = widget.isUnknown
        ? OutlineInputBorder(
            borderSide: BorderSide(color: Colors.red.shade400, width: 1.5))
        : null;

    final String displayValue = _display(widget.value);
    String? helper = widget.isUnknown
        ? 'Not in UI schema — add "${widget.fieldKey}" to ui_schema.json'
        : widget.spec?.helperText;
    if (!widget.isUnknown && displayValue.contains('\n')) {
      helper = helper == null
          ? r'Line breaks are converted for the touch panel'
          : '$helper — line breaks are saved as \\r';
    }

    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      // Text fields grow to show every \r line; numeric fields stay one line
      maxLines: _isNumeric ? 1 : null,
      keyboardType: _isNumeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.multiline,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: helper,
        helperStyle:
            widget.isUnknown ? TextStyle(color: Colors.red.shade400) : null,
        border: redBorder ?? const OutlineInputBorder(),
        enabledBorder: redBorder,
        focusedBorder: widget.isUnknown
            ? OutlineInputBorder(
                borderSide: BorderSide(color: Colors.red.shade400, width: 2))
            : null,
      ),
      onChanged: (val) {
        dynamic parsedVal;
        // Respect the declared schema type first, then the live value's type,
        // so config.json keeps clean numeric types either way.
        if (widget.type == 'int' || widget.value is int) {
          parsedVal = int.tryParse(val) ?? 0;
        } else if (widget.type == 'double' || widget.value is double) {
          parsedVal = double.tryParse(val) ?? 0.0;
        } else {
          // Store visual line breaks as the literal \r the processor expects
          parsedVal = val
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n')
              .replaceAll('\n', r'\r');
        }
        widget.provider
            .updateDeviceValue(widget.sectionKey, widget.fieldKey, parsedVal);
      },
    );
  }
}
