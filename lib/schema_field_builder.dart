import 'package:flutter/material.dart';

import 'app_state.dart';
import 'conversion_colors.dart';
import 'search_match.dart';
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

    // "hideWhen": the key is irrelevant to this block as it currently stands —
    // serial_port on a device whose com_type is Network, which reaches its
    // hardware by ip_address + net_port and never opens a COM port.
    if (spec != null && spec.isHiddenIn(_sectionMap(provider, sectionKey))) {
      return null;
    }

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
      case 'room_sources':
        field = _buildRoomSources(
            context, provider, sectionKey, fieldKey, spec, label, value);
        break;
      case 'source_map':
        field = _buildSourceMap(
            context, provider, sectionKey, fieldKey, spec, label, value);
        break;
      case 'module_states':
        field = _buildModuleStates(
            context, provider, sectionKey, fieldKey, spec!, label, value);
        break;
      case 'bool':
        field = SwitchListTile(
          title: Text(label,
              style: TextStyle(
                  color: _originColor(context, provider, sectionKey, fieldKey))),
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

  /// A dropdown of the sources THIS room has, for pinning one screen to one
  /// of them.
  ///
  /// The options are read off SYSTEM_SETUP's `input_*` keys — see
  /// [roomSourceNames] — so the list is the room's own answer rather than a
  /// fixed menu that is wrong in most rooms. A room that has not filled its
  /// inputs in yet offers nothing, and says so, which is more use than an
  /// empty box.
  ///
  /// A value already in the file that is NOT one of those names is kept and
  /// listed, marked as not being one of this room's sources. It is either a
  /// source somebody has not wired up yet or a typo, and both are things to
  /// see rather than things to silently overwrite the moment the field is
  /// rendered.
  static Widget _buildRoomSources(
    BuildContext context,
    AppStateProvider provider,
    String sectionKey,
    String fieldKey,
    FieldSpec? spec,
    String label,
    dynamic value,
  ) {
    final setup = _sectionMap(provider, 'SYSTEM_SETUP');
    final sources = roomSourceNames(setup);
    final current = value?.toString().trim() ?? '';
    final stray = current.isNotEmpty && !sources.contains(current);

    return DropdownButtonFormField<String>(
      key: ValueKey('room_sources_${sectionKey}_$fieldKey'),
      initialValue: current,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: sources.isEmpty
            ? 'This room has no sources filled in yet — set the input_ keys '
                'on the System tab'
            : spec?.helperText,
        helperMaxLines: 3,
      ),
      items: [
        const DropdownMenuItem(
          value: '',
          child: Text('Not pinned — this screen is not routed'),
        ),
        for (final name in sources)
          DropdownMenuItem(value: name, child: Text(name)),
        if (stray)
          DropdownMenuItem(
            value: current,
            child: Text('$current  (not one of this room\'s sources)'),
          ),
      ],
      onChanged: (v) =>
          provider.updateDeviceValue(sectionKey, fieldKey, v ?? ''),
    );
  }

  /// A source -> source MAP, drawn as one row of dropdowns per substitution.
  ///
  /// This is the projectors' `source_overrides`: while the room is on the
  /// source on the left, this screen is routed the one on the right instead.
  /// The key is an object, so it used to be hidden and left to the Raw JSON
  /// tab — which meant the one screen rule a tech is most likely to want was
  /// the one they had to hand-type braces for.
  ///
  /// Both sides are [roomSourceNames], the same list `source_fixed` offers, so
  /// a substitution can only be written between sources this room actually
  /// has. A name already in the file that is NOT one of them is still listed
  /// and marked, exactly as the pinned-source dropdown does: it is a source
  /// nobody has wired up yet or a typo, and both are things to see.
  ///
  /// Every edit writes the whole map back through the one provider write path
  /// each field shares, so nothing is held in widget state — a row cannot go
  /// missing when the device tab's lazy list scrolls it off screen.
  static Widget _buildSourceMap(
    BuildContext context,
    AppStateProvider provider,
    String sectionKey,
    String fieldKey,
    FieldSpec? spec,
    String label,
    dynamic value,
  ) {
    final sources = roomSourceNames(_sectionMap(provider, 'SYSTEM_SETUP'));

    // Insertion order is kept: the rows stay where the tech put them rather
    // than jumping around as sources are picked. A value that is not an
    // object (null, or a string typed into the raw editor) reads as no rows;
    // the first edit replaces it with a real map.
    final Map<String, String> rows = {};
    if (value is Map) {
      value.forEach((k, v) => rows[k.toString()] = v?.toString() ?? '');
    }

    void write(Map<String, String> next) => provider.updateDeviceValue(
        sectionKey, fieldKey, Map<String, dynamic>.from(next));

    /// Rebuilds the map with [from] renamed to [to], in place, so changing
    /// the left side of a row does not move it to the bottom.
    void renameKey(String from, String to) {
      final next = <String, String>{};
      rows.forEach((k, v) => next[k == from ? to : k] = v);
      write(next);
    }

    final available = [
      for (final name in sources)
        if (!rows.containsKey(name)) name,
    ];

    final labelColor = _originColor(context, provider, sectionKey, fieldKey);
    // A row whose right side is still blank routes this screen to nothing, so
    // it is flagged the same way an out-of-schema value is rather than left
    // looking finished.
    final bool incomplete = rows.values.any((v) => v.trim().isEmpty);

    Widget sideDropdown({
      required String? current,
      required String hint,
      required List<String> options,
      required ValueChanged<String> onPicked,
      bool markBlank = false,
    }) {
      final value = current ?? '';
      final stray = value.isNotEmpty && !options.contains(value);
      return DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          labelText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
          enabledBorder: markBlank && value.isEmpty
              ? OutlineInputBorder(
                  borderSide:
                      BorderSide(color: Colors.red.shade400, width: 1.5))
              : null,
        ),
        items: [
          if (value.isEmpty || markBlank)
            const DropdownMenuItem(value: '', child: Text('— pick a source —')),
          for (final name in options)
            DropdownMenuItem(value: name, child: Text(name)),
          if (stray)
            DropdownMenuItem(
              value: value,
              child: Text('$value  (not one of this room\'s sources)'),
            ),
        ],
        onChanged: (v) => onPicked(v ?? ''),
      );
    }

    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: labelColor == null ? null : TextStyle(color: labelColor),
        floatingLabelStyle:
            labelColor == null ? null : TextStyle(color: labelColor),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        helperText: sources.isEmpty
            ? 'This room has no sources filled in yet — set the input_ keys '
                'on the System tab'
            : incomplete
                ? 'A substitution with no source on the right leaves this '
                    'screen unrouted whenever the room selects the one on '
                    'the left'
                : spec?.helperText,
        helperStyle:
            incomplete ? TextStyle(color: Colors.red.shade400) : null,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'No substitutions — this screen shows whatever the room '
                'selected.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final entry in rows.entries)
            Padding(
              key: ValueKey('source_map_${sectionKey}_${entry.key}'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: sideDropdown(
                      current: entry.key,
                      hint: 'When the room selects',
                      // Its own name plus whatever is still unclaimed: two
                      // rows keyed on the same source would collapse into one.
                      options: [entry.key, ...available]..sort(),
                      onPicked: (v) {
                        if (v.isEmpty || v == entry.key) return;
                        renameKey(entry.key, v);
                      },
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.arrow_forward, size: 18),
                  ),
                  Expanded(
                    child: sideDropdown(
                      current: entry.value,
                      hint: 'this screen shows',
                      options: sources,
                      markBlank: true,
                      onPicked: (v) => write({...rows, entry.key: v}),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Remove this substitution',
                    onPressed: () =>
                        write({...rows}..remove(entry.key)),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add substitution'),
              // Nothing left to key a row on: every source this room has
              // already substitutes, or it has none filled in at all.
              onPressed: available.isEmpty
                  ? null
                  : () => write({...rows, available.first: ''}),
            ),
          ),
        ],
      ),
    );
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
      initialValue: current.isNotEmpty ? current : null,
      decoration: _decoration(label, spec.helperText,
          mismatch: valueMismatch || conflict != null,
          mismatchText: valueMismatch
              ? 'Value "$current" is not in the schema options — pick a valid option'
              : conflict,
          labelColor: _originColor(context, provider, sectionKey, fieldKey)),
      items: options
          .map((o) => DropdownMenuItem(value: o.value, child: Text(o.label)))
          .toList(),
      onChanged: (val) {
        if (val == null) return;
        provider.updateDeviceValue(sectionKey, fieldKey, val);
        // Changing the connection style can pull the driver's own port,
        // protocol and baud in with it. That is the point of the blocks, and
        // it still has to be said out loud — values appearing in fields
        // further down the form with no explanation is how a tool gets
        // blamed for something it was asked to do.
        final loaded = provider.lastComTypeDefaults;
        if (loaded.isEmpty) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            'Loaded the module\'s $val defaults: ${loaded.join(', ')}',
          ),
        ));
      },
    );
  }

  /// The label color for a converted value, from the one palette the
  /// conversion preview also draws with — so a field the preview showed as
  /// rewritten looks rewritten here too. Null for a config with no conversion
  /// history, which leaves the field's normal styling alone.
  static Color? _originColor(
      BuildContext context, AppStateProvider provider, String sectionKey, String fieldKey) {
    return ConversionColors.of(context)
        .forOrigin(provider.originFor(sectionKey, fieldKey));
  }

  /// Shared InputDecoration: normal gray outline, or red in every state (with
  /// a red helper line) when the current value doesn't match the schema.
  /// [labelColor] tints only the label, so provenance coloring never fights
  /// the red mismatch outline.
  static InputDecoration _decoration(String label, String? helperText,
      {bool mismatch = false, String? mismatchText, Color? labelColor}) {
    final OutlineInputBorder? red = mismatch
        ? OutlineInputBorder(
            borderSide: BorderSide(color: Colors.red.shade400, width: 1.5))
        : null;
    return InputDecoration(
      labelText: label,
      labelStyle: labelColor == null ? null : TextStyle(color: labelColor),
      floatingLabelStyle:
          labelColor == null ? null : TextStyle(color: labelColor),
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
    return _ModuleStatesField(
      key: ValueKey('$sectionKey.$fieldKey.states'),
      provider: provider,
      sectionKey: sectionKey,
      fieldKey: fieldKey,
      spec: spec,
      label: label,
      value: value,
      moduleName: moduleName,
    );
  }

  /// The body of the module-states field, once the future it reads has been
  /// parked somewhere that survives a rebuild. See [_ModuleStatesField].
  static Widget _moduleStatesBody(
      BuildContext context,
      AppStateProvider provider,
      String sectionKey,
      String fieldKey,
      FieldSpec spec,
      String label,
      dynamic value,
      String moduleName,
      Future<List<String>> states0) {
    final String command = spec.moduleCommand ?? fieldKey;
    final String current = value?.toString() ?? '';

    return FutureBuilder<List<String>>(
      future: states0,
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

        // MISMATCH: the value isn't a state this module implements — the state
        // a family default injected ('input' = "HDBaseT" for every projector)
        // rather than one this projector actually has. Flagged rather than
        // corrected: which port the device is wired to is a site fact the app
        // can't guess, so the tech either picks a real state or adds the
        // missing one to the module. Only judged once the states have actually
        // been parsed — a module with no '$command' at all (states empty) says
        // so in its helper line instead, and mid-parse never flashes red.
        final bool valueMismatch = current.isNotEmpty &&
            states.isNotEmpty &&
            !states.any((s) => s.toLowerCase() == current.toLowerCase());

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
            return searchFilter(states, text);
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
              decoration: _decoration('$label (type or select)', helper,
                  mismatch: valueMismatch,
                  mismatchText: '"$current" is not a \'$command\' state in '
                      '$moduleName.py — pick one of the '
                      '${states.length} it supports, or add it to the module',
                  labelColor:
                      _originColor(context, provider, sectionKey, fieldKey)),
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
      initialValue: hasValue ? currentComboKey : null,
      decoration: _decoration(label, spec.helperText,
          mismatch: valueMismatch || conflict != null,
          mismatchText: valueMismatch
              ? 'Combined value "$currentComboKey" (${writes.join(' + ')}) is not in the schema options — pick a valid option'
              : conflict,
          labelColor: _originColor(context, provider, sectionKey, fieldKey)),
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

/// The module-states field, with the parse it reads held in State.
///
/// A [FutureBuilder] whose `future:` is CREATED IN BUILD rebuilds forever: the
/// future completes, the builder calls setState, the rebuild makes another
/// future, and round it goes. An `async` method returns a new Future every
/// call even when it answers out of a cache, so the states parse — which is
/// cached, and looks cheap — was spinning a frame per frame for as long as a
/// device with a module_states field (a projector's input) was on screen.
///
/// Nothing looked broken; it just meant the whole device form was rebuilding
/// continuously behind whatever was being typed into it. The future is made
/// once here, and again only when the module or the command it is parsed from
/// actually changes.
class _ModuleStatesField extends StatefulWidget {
  final AppStateProvider provider;
  final String sectionKey;
  final String fieldKey;
  final FieldSpec spec;
  final String label;
  final dynamic value;
  final String moduleName;

  const _ModuleStatesField({
    super.key,
    required this.provider,
    required this.sectionKey,
    required this.fieldKey,
    required this.spec,
    required this.label,
    required this.value,
    required this.moduleName,
  });

  @override
  State<_ModuleStatesField> createState() => _ModuleStatesFieldState();
}

class _ModuleStatesFieldState extends State<_ModuleStatesField> {
  late Future<List<String>> _states;

  String get _command => widget.spec.moduleCommand ?? widget.fieldKey;

  @override
  void initState() {
    super.initState();
    _states = widget.provider
        .getStatesForModuleCommand(widget.moduleName, _command);
  }

  @override
  void didUpdateWidget(covariant _ModuleStatesField old) {
    super.didUpdateWidget(old);
    // Only when there is something new to parse. Re-reading the same module on
    // every rebuild is the loop this class exists to stop.
    if (old.moduleName != widget.moduleName ||
        (old.spec.moduleCommand ?? old.fieldKey) != _command) {
      _states = widget.provider
          .getStatesForModuleCommand(widget.moduleName, _command);
    }
  }

  @override
  Widget build(BuildContext context) => SchemaFieldBuilder._moduleStatesBody(
        context,
        widget.provider,
        widget.sectionKey,
        widget.fieldKey,
        widget.spec,
        widget.label,
        widget.value,
        widget.moduleName,
        _states,
      );
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
    super.key,
    required this.provider,
    required this.sectionKey,
    required this.fieldKey,
    required this.spec,
    required this.label,
    required this.type,
    required this.value,
    required this.isUnknown,
  });

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

    final Color? labelColor = SchemaFieldBuilder._originColor(
        context, widget.provider, widget.sectionKey, widget.fieldKey);

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
        // Orange label = carried over from the loaded file; white = written by
        // the conversion. Null (no conversion) leaves the theme's own color.
        labelStyle: labelColor == null ? null : TextStyle(color: labelColor),
        floatingLabelStyle:
            labelColor == null ? null : TextStyle(color: labelColor),
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
