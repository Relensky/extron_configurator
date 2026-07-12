import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'config_dictionary.dart';

/// ============================================================================
///  UI SCHEMA SYSTEM
/// ============================================================================
///  Loads an external `ui_schema.json` file that describes how each config.json
///  key should be rendered in the GUI (label, description, widget type,
///  dropdown options, etc). This lets you add brand-new keys to config.json
///  AND give them a proper editor UI WITHOUT rebuilding the application —
///  just edit ui_schema.json and press "Reload Schema" (or restart).
///
///  Supported field "type" values:
///    "auto"     (default) infer from the JSON value: bool->switch,
///               int->numeric text field, everything else->text field
///    "text"     free text field
///    "int"      text field that parses/stores an integer
///    "double"   text field that parses/stores a double
///    "bool"     on/off switch (stores true/false)
///    "dropdown" fixed list of options ("options" array)
///    "combo"    ONE dropdown that writes to MULTIPLE config keys at once
///               ("writes" array + "options" with a "values" array per option)
///    "hidden"   never render this key (e.g. keys managed by a combo or wizard)
///
///    "module_states" dropdown/autocomplete whose options are parsed LIVE from
///               the device's selected Python module: the states of one
///               command in the module's `self.Commands` dictionary
///               ("moduleCommand" names the command, e.g. "Input")
///
///  Keys may contain a `*` wildcard (e.g. "power1_outlet_*") so one schema
///  entry covers a whole family of config keys. Exact matches always win
///  over wildcard matches.
///
///  DEVICE-TYPE SCOPING: a top-level "device_fields" object holds field
///  definitions that apply ONLY to matching config sections (device blocks),
///  keyed by a section pattern like "PROJECTORDEVICE_*". Scoped entries win
///  over the global "fields" entries for those sections, and entries marked
///  "addIfMissing": true are rendered on the device tab even when the key
///  does not exist in the device block yet (the first edit writes it).
///
///  DEVICE DEFAULTS: a top-level "device_defaults" object maps section
///  patterns to property/value pairs that are merged into every NEWLY
///  CREATED device block of that type (Setup Wizard count changes) — e.g.
///  projectors always get "input"/"relay_host", DSPs get their audio group
///  numbers. Existing values are never overwritten; exact section names
///  (e.g. "SWITCHERDEVICE_1") win over wildcard patterns.
/// ============================================================================

/// A single selectable option for "dropdown" and "combo" fields.
class OptionSpec {
  /// Stored value for a plain dropdown (e.g. "Yes").
  final String value;

  /// Human friendly text shown in the dropdown (falls back to [value]).
  final String label;

  /// For "combo" fields only: the value written to each key in
  /// [FieldSpec.writes], in the same order.
  final List<String>? values;

  const OptionSpec({required this.value, String? label, this.values})
      : label = label ?? value;

  /// Identity used to select a combo option: its values joined with "_"
  /// (matches how gui_inputs / gui_tab_type combine today).
  String get comboKey => (values ?? [value]).join('_');

  factory OptionSpec.fromJson(dynamic json) {
    // Options may be plain strings: "Yes"
    if (json is String) return OptionSpec(value: json);
    if (json is Map) {
      final values = (json['values'] is List)
          ? (json['values'] as List).map((e) => e.toString()).toList()
          : null;
      return OptionSpec(
        value: json['value']?.toString() ?? (values?.join('_') ?? ''),
        label: json['label']?.toString(),
        values: values,
      );
    }
    return OptionSpec(value: json.toString());
  }
}

/// Describes how one config key (or wildcard family of keys) is rendered.
class FieldSpec {
  final String key;               // exact key or wildcard pattern with '*'
  final String type;              // see list at top of file
  final String? label;            // field label (defaults to the raw key)
  final String? description;      // info button text (falls back to ConfigDictionary)
  final String? helperText;       // small grey helper line under the field
  final List<OptionSpec> options; // for dropdown / combo
  final List<String> writes;      // for combo: config keys this field writes
  final String? moduleCommand;    // for module_states: command in self.Commands
  final bool addIfMissing;        // device_fields only: render even when the
                                  // key is absent from the device block

  RegExp? _patternRegex;

  FieldSpec({
    required this.key,
    this.type = 'auto',
    this.label,
    this.description,
    this.helperText,
    this.options = const [],
    this.writes = const [],
    this.moduleCommand,
    this.addIfMissing = false,
  });

  bool get isPattern => key.contains('*');

  /// True when a wildcard spec like "power1_outlet_*" covers [configKey].
  bool matches(String configKey) {
    if (!isPattern) return key == configKey;
    _patternRegex ??= RegExp(
        '^${RegExp.escape(key).replaceAll(r'\*', '.*')}\$');
    return _patternRegex!.hasMatch(configKey);
  }

  factory FieldSpec.fromJson(String key, Map<String, dynamic> json) {
    return FieldSpec(
      key: key,
      type: json['type']?.toString() ?? 'auto',
      label: json['label']?.toString(),
      description: json['description']?.toString(),
      helperText: json['helperText']?.toString(),
      options: (json['options'] is List)
          ? (json['options'] as List).map(OptionSpec.fromJson).toList()
          : const [],
      writes: (json['writes'] is List)
          ? (json['writes'] as List).map((e) => e.toString()).toList()
          : const [],
      // Accept both camelCase (file convention) and snake_case spellings
      moduleCommand:
          (json['moduleCommand'] ?? json['module_command'])?.toString(),
      addIfMissing:
          (json['addIfMissing'] ?? json['add_if_missing']) == true,
    );
  }
}

/// One "device_fields" entry: field specs that apply only to config sections
/// matching [sectionPattern] (e.g. "PROJECTORDEVICE_*").
class DeviceScopedFields {
  final String sectionPattern;
  final Map<String, FieldSpec> _exact = {};
  final List<FieldSpec> _patterns = [];

  RegExp? _sectionRegex;

  DeviceScopedFields(this.sectionPattern);

  bool matchesSection(String sectionKey) {
    if (!sectionPattern.contains('*')) return sectionPattern == sectionKey;
    _sectionRegex ??= RegExp(
        '^${RegExp.escape(sectionPattern).replaceAll(r'\*', '.*')}\$');
    return _sectionRegex!.hasMatch(sectionKey);
  }

  void add(FieldSpec spec) {
    if (spec.isPattern) {
      _patterns.removeWhere((p) => p.key == spec.key);
      _patterns.add(spec);
    } else {
      _exact[spec.key] = spec;
    }
  }

  int get fieldCount => _exact.length + _patterns.length;

  FieldSpec? specFor(String configKey) {
    final exact = _exact[configKey];
    if (exact != null) return exact;
    for (final p in _patterns.reversed) {
      if (p.matches(configKey)) return p;
    }
    return null;
  }

  /// Exact-key specs flagged addIfMissing, for rendering fields the device
  /// block doesn't contain yet (wildcards can't synthesize a concrete key).
  Iterable<FieldSpec> get addIfMissingSpecs =>
      _exact.values.where((s) => s.addIfMissing);
}

/// One "device_defaults" entry: property values merged into newly created
/// device blocks whose section name matches [sectionPattern].
class DeviceDefaults {
  final String sectionPattern;
  final Map<String, dynamic> values;

  RegExp? _sectionRegex;

  DeviceDefaults(this.sectionPattern, this.values);

  bool get isPattern => sectionPattern.contains('*');

  bool matchesSection(String sectionKey) {
    if (!isPattern) return sectionPattern == sectionKey;
    _sectionRegex ??= RegExp(
        '^${RegExp.escape(sectionPattern).replaceAll(r'\*', '.*')}\$');
    return _sectionRegex!.hasMatch(sectionKey);
  }
}

/// The full loaded schema plus lookup helpers used by the views.
class UiSchema {
  final Map<String, FieldSpec> _exact = {};
  final List<FieldSpec> _patterns = [];

  /// Device-type scoped definitions from "device_fields" (later additions —
  /// i.e. the file — override earlier ones with the same section pattern).
  final List<DeviceScopedFields> _deviceScoped = [];

  /// Baseline property values from "device_defaults", merged into newly
  /// created device blocks (Setup Wizard) by AppStateProvider.setDeviceCount.
  final List<DeviceDefaults> _deviceDefaults = [];

  /// Where this schema came from, for display in App Config.
  String source = 'Built-in defaults';

  int get fieldCount =>
      _exact.length +
      _patterns.length +
      _deviceScoped.fold(0, (sum, d) => sum + d.fieldCount);

  /// All exact (non-wildcard) config keys the schema knows about. Used by the
  /// key mapper's auto-case-normalization as the canonical vocabulary.
  List<String> get exactKeys => _exact.keys.toList();

  void _add(FieldSpec spec) {
    if (spec.isPattern) {
      // Later additions override earlier ones (file overrides built-in)
      _patterns.removeWhere((p) => p.key == spec.key);
      _patterns.add(spec);
    } else {
      _exact[spec.key] = spec;
    }
  }

  /// Find the spec for a config key. When [sectionKey] is given (a device
  /// block like 'PROJECTORDEVICE_1'), matching "device_fields" entries win
  /// over the global "fields" entries. Exact match beats wildcard either way.
  FieldSpec? specFor(String configKey, {String? sectionKey}) {
    final scoped = deviceSpecFor(sectionKey, configKey);
    if (scoped != null) return scoped;
    final exact = _exact[configKey];
    if (exact != null) return exact;
    for (final p in _patterns.reversed) { // last added (file) wins
      if (p.matches(configKey)) return p;
    }
    return null;
  }

  /// ONLY the device-scoped spec for [configKey] in [sectionKey] (null when
  /// no "device_fields" entry covers it). Lets views detect that a device
  /// type explicitly overrides a field (e.g. projector 'input').
  FieldSpec? deviceSpecFor(String? sectionKey, String configKey) {
    if (sectionKey == null) return null;
    for (final scoped in _deviceScoped.reversed) { // last added (file) wins
      if (!scoped.matchesSection(sectionKey)) continue;
      final spec = scoped.specFor(configKey);
      if (spec != null) return spec;
    }
    return null;
  }

  /// Device-scoped specs marked addIfMissing for [sectionKey] whose keys are
  /// NOT in [existingKeys] — the device tab renders these as extra fields so
  /// a device-type-only setting appears before it exists in config.json.
  List<FieldSpec> missingFieldsFor(
      String sectionKey, Iterable<String> existingKeys) {
    final existing = existingKeys.toSet();
    final Map<String, FieldSpec> result = {};
    for (final scoped in _deviceScoped) { // later (file) entries override
      if (!scoped.matchesSection(sectionKey)) continue;
      for (final spec in scoped.addIfMissingSpecs) {
        if (!existing.contains(spec.key)) result[spec.key] = spec;
      }
    }
    return result.values.toList();
  }

  /// Baseline property values for a newly created device block: the merge
  /// of every matching "device_defaults" entry. Wildcard patterns apply
  /// first, then exact section names (so "SWITCHERDEVICE_1" can override
  /// "SWITCHERDEVICE_*" per property). The caller only fills keys that the
  /// block doesn't already have, so template values always win.
  Map<String, dynamic> defaultsFor(String sectionKey) {
    final Map<String, dynamic> merged = {};
    for (final d in _deviceDefaults) {
      if (d.isPattern && d.matchesSection(sectionKey)) merged.addAll(d.values);
    }
    for (final d in _deviceDefaults) {
      if (!d.isPattern && d.matchesSection(sectionKey)) merged.addAll(d.values);
    }
    return merged;
  }

  /// Description for the info (i) button: schema first, then the legacy
  /// built-in ConfigDictionary so nothing that worked before goes blank.
  String? descriptionFor(String configKey, {String? sectionKey}) {
    final desc = specFor(configKey, sectionKey: sectionKey)?.description;
    if (desc != null && desc.isNotEmpty) return desc;
    return ConfigDictionary.descriptions[configKey];
  }

  /// Parses the "fields" map of a ui_schema.json document into this schema.
  void applyJsonMap(Map<String, dynamic> doc) {
    final fields = doc['fields'];
    if (fields is! Map) {
      throw const FormatException(
          'ui_schema.json must contain a top-level "fields" object.');
    }
    fields.forEach((key, value) {
      if (key.toString().startsWith('__')) return; // allow "__comment" keys
      if (value is Map) {
        _add(FieldSpec.fromJson(key.toString(),
            value.map((k, v) => MapEntry(k.toString(), v))));
      }
    });

    // Optional "device_fields": { "PROJECTORDEVICE_*": { "input": {...} } }
    final deviceFields = doc['device_fields'];
    if (deviceFields is Map) {
      deviceFields.forEach((sectionPattern, fieldMap) {
        if (sectionPattern.toString().startsWith('__')) return;
        if (fieldMap is! Map) return;
        // File entries replace any earlier definition of the same pattern
        _deviceScoped
            .removeWhere((d) => d.sectionPattern == sectionPattern.toString());
        final scoped = DeviceScopedFields(sectionPattern.toString());
        fieldMap.forEach((key, value) {
          if (key.toString().startsWith('__')) return;
          if (value is Map) {
            scoped.add(FieldSpec.fromJson(key.toString(),
                value.map((k, v) => MapEntry(k.toString(), v))));
          }
        });
        if (scoped.fieldCount > 0) _deviceScoped.add(scoped);
      });
    }

    // Optional "device_defaults": { "DSPDEVICE_*": { "group_prog_gain": "1" } }
    final deviceDefaults = doc['device_defaults'];
    if (deviceDefaults is Map) {
      deviceDefaults.forEach((sectionPattern, valueMap) {
        if (sectionPattern.toString().startsWith('__')) return;
        if (valueMap is! Map) return;
        // File entries replace any earlier definition of the same pattern
        _deviceDefaults
            .removeWhere((d) => d.sectionPattern == sectionPattern.toString());
        final Map<String, dynamic> values = {};
        valueMap.forEach((key, value) {
          if (key.toString().startsWith('__')) return;
          values[key.toString()] = value;
        });
        if (values.isNotEmpty) {
          _deviceDefaults
              .add(DeviceDefaults(sectionPattern.toString(), values));
        }
      });
    }
  }

  /// The defaults that replicate the app's previous hardcoded behavior, so
  /// the editor works exactly as before even when no ui_schema.json exists.
  static UiSchema builtIn() {
    final s = UiSchema();

    // --- Previously hardcoded in SystemSettingsView._standardDropdowns ---
    s._add(FieldSpec(key: 'gui_mic_mix', type: 'dropdown', options: const [
      OptionSpec(value: 'Yes', label: 'Yes (Single Mic w/ Ducking)'),
      OptionSpec(value: 'No', label: 'No (Single Mic w/ Mute)'),
      OptionSpec(value: 'Ceiling', label: 'Ceiling (Voicelift & Mute)'),
    ]));
    s._add(FieldSpec(key: 'gui_routing_available', type: 'dropdown',
        options: const [OptionSpec(value: 'Yes'), OptionSpec(value: 'No')]));
    s._add(FieldSpec(key: 'gui_routing_mode', type: 'dropdown', options: const [
      OptionSpec(value: 'Normal'),
      OptionSpec(value: 'Conference'),
      OptionSpec(value: 'Extended'),
    ]));
    s._add(FieldSpec(key: 'gui_tab', type: 'dropdown', options: const [
      OptionSpec(value: '2_Cam_Dev'),
      OptionSpec(value: '2_Mic_Dev'),
      OptionSpec(value: '3_Cam_Mic_Dev'),
      OptionSpec(value: '3_Cams_Dev'),
      OptionSpec(value: '4_Cams_Mic_Dev'),
      OptionSpec(value: 'Conference'),
    ]));
    s._add(FieldSpec(key: 'gui_capture_source_available', type: 'dropdown',
        options: const [OptionSpec(value: 'Yes'), OptionSpec(value: 'No')]));
    s._add(FieldSpec(key: 'gui_usb_or_vga', type: 'dropdown',
        options: const [OptionSpec(value: 'USB'), OptionSpec(value: 'VGA')]));

    // --- Previously hardcoded combined dropdown (gui_inputs + gui_tab_type) ---
    s._add(FieldSpec(
      key: 'gui_inputs',
      type: 'combo',
      label: 'Sources & Routing Config (gui_inputs + gui_tab_type)',
      writes: const ['gui_inputs', 'gui_tab_type'],
      options: const [
        OptionSpec(value: '3_WL', values: ['3', 'WL'], label: '3 Sources: PC, HDMI, & Wireless'),
        OptionSpec(value: '4_DOC_USB', values: ['4', 'DOC_USB'], label: '4 Sources: PC, HDMI, Doc Cam, & USB'),
        OptionSpec(value: '4_DOC_VGA', values: ['4', 'DOC_VGA'], label: '4 Sources: PC, HDMI, Doc Cam, & VGA'),
        OptionSpec(value: '4_DOC_WL', values: ['4', 'DOC_WL'], label: '4 Sources: PC, HDMI, Doc Cam, & Wireless'),
        OptionSpec(value: '4_DVD_USB', values: ['4', 'DVD_USB'], label: '4 Sources: PC, HDMI, DVD, & USB'),
        OptionSpec(value: '4_DVD_VGA', values: ['4', 'DVD_VGA'], label: '4 Sources: PC, HDMI, DVD, & VGA'),
        OptionSpec(value: '5_BR_DOC_USB', values: ['5', 'BR_DOC_USB'], label: '5 Sources: PC, HDMI, Doc Cam, BluRay, & USB'),
        OptionSpec(value: '5_BR_DOC_VGA', values: ['5', 'BR_DOC_VGA'], label: '5 Sources: PC, HDMI, Doc Cam, BluRay, & VGA'),
        OptionSpec(value: '5_DOC_DVD_USB', values: ['5', 'DOC_DVD_USB'], label: '5 Sources: PC, HDMI, Doc Cam, DVD, & USB'),
        OptionSpec(value: '5_DOC_DVD_VGA', values: ['5', 'DOC_DVD_VGA'], label: '5 Sources: PC, HDMI, Doc Cam, DVD, & VGA'),
        OptionSpec(value: '5_DOC_USB_WL', values: ['5', 'DOC_USB_WL'], label: '5 Sources: PC, HDMI, Doc Cam, USB, & Wireless'),
        OptionSpec(value: '5_DOC_VGA_WL', values: ['5', 'DOC_VGA_WL'], label: '5 Sources: PC, HDMI, Doc Cam, VGA, & Wireless'),
        OptionSpec(value: '6_BR_DOC_USB_WL', values: ['6', 'BR_DOC_USB_WL'], label: '6 Sources: PC, HDMI, BluRay, Doc Cam, USB, & Wireless'),
        OptionSpec(value: '6_BR_DOC_VGA_WL', values: ['6', 'BR_DOC_VGA_WL'], label: '6 Sources: PC, HDMI, BluRay, Doc Cam, VGA, & Wireless'),
        OptionSpec(value: '6_DOC_DVD_USB_WL', values: ['6', 'DOC_DVD_USB_WL'], label: '6 Sources: PC, HDMI, DVD, Doc Cam, USB, & Wireless'),
        OptionSpec(value: '6_DOC_DVD_VGA_WL', values: ['6', 'DOC_DVD_VGA_WL'], label: '6 Sources: PC, HDMI, DVD, Doc Cam, VGA, & Wireless'),
      ],
    ));

    // gui_tab_type is written by the combo above, never rendered directly
    s._add(FieldSpec(key: 'gui_tab_type', type: 'hidden'));

    return s;
  }

  /// Loads the schema for the app:
  ///   1. Start from the built-in defaults (guaranteed to work).
  ///   2. Overlay ui_schema.json from [explicitPath] if set, otherwise look
  ///      for "ui_schema.json" beside the executable / working directory.
  ///   3. File entries override built-in entries with the same key.
  /// Any failure is logged and the built-in schema is returned, so a broken
  /// schema file can never take the editor down.
  static Future<UiSchema> load({String explicitPath = ''}) async {
    final schema = UiSchema.builtIn();

    // Resolve candidate file locations
    final List<String> candidates = [];
    if (explicitPath.isNotEmpty) {
      candidates.add(explicitPath);
    } else {
      candidates.add(path.join(Directory.current.path, 'ui_schema.json'));
      candidates.add(path.join(
          File(Platform.resolvedExecutable).parent.path, 'ui_schema.json'));
    }

    for (final candidate in candidates) {
      try {
        final file = File(candidate);
        if (!await file.exists()) continue;

        final doc = jsonDecode(await file.readAsString());
        if (doc is! Map<String, dynamic>) {
          throw const FormatException('Root of ui_schema.json must be an object.');
        }
        schema.applyJsonMap(doc);
        schema.source = candidate;
        AppLogger.logInfo(
            'UI schema loaded from $candidate (${schema.fieldCount} field definitions).');
        return schema;
      } catch (e, stack) {
        AppLogger.logError(
            'Failed to load ui_schema.json from $candidate — using built-in defaults.',
            e,
            stack);
        schema.source = 'Built-in defaults (failed to load $candidate: $e)';
        return schema;
      }
    }

    if (explicitPath.isNotEmpty) {
      schema.source = 'Built-in defaults (file not found: $explicitPath)';
    }
    return schema;
  }
}
