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
///    "room_sources" dropdown whose options are the sources THIS room has,
///               read off the input_* keys in SYSTEM_SETUP (see
///               [roomSourceNames])
///
///    "module_states" dropdown/autocomplete whose options are parsed LIVE from
///               the device's selected Python module: the states of one
///               command in the module's `self.Commands` dictionary
///               ("moduleCommand" names the command, e.g. "Input")
///
///    "source_map" an OBJECT of source-name pairs, drawn as one row of two
///               [roomSourceNames] dropdowns per entry (with add/remove) —
///               a display's `source_overrides`. The only non-scalar editor
///               here: every other structured key is left to the Raw JSON tab.
///
///  Keys may contain a `*` wildcard (e.g. "power1_outlet_*") so one schema
///  entry covers a whole family of config keys. Exact matches always win
///  over wildcard matches.
///
///  DEVICE-TYPE SCOPING: a top-level "device_fields" object holds field
///  definitions that apply ONLY to matching config sections (device blocks),
///  keyed by a section pattern like "PROJECTORDEVICE_*". Scoped entries win
///  over the global "fields" entries for those sections. Entries marked
///  "addIfMissing": true are rendered on the device tab even when the key
///  does not exist in the device block yet (the first edit writes it) —
///  allowed on a global "fields" entry too, which is how serial_port reaches
///  every family's tab rather than one.
///  "section_fields" is the same thing under a clearer name for NON-device
///  blocks (e.g. "METRICS_CONFIG"); both are parsed into the same list.
///
///  SECTION DEFAULTS: a top-level "section_defaults" object holds whole
///  non-device, non-SYSTEM_SETUP config sections (e.g. "METRICS_CONFIG")
///  with their baseline properties. On load, a missing section is created
///  and missing properties are added, exactly like the SYSTEM_SETUP
///  migration — so a new processor-side feature block reaches every room
///  by editing ui_schema.json alone.
///
///  DEVICE DEFAULTS: a top-level "device_defaults" object maps section
///  patterns to property/value pairs that are merged into every NEWLY
///  CREATED device block of that type (Setup Wizard count changes) — e.g.
///  projectors always get "input"/"relay_host", DSPs get their audio group
///  numbers. Existing values are never overwritten; exact section names
///  (e.g. "SWITCHERDEVICE_1") win over wildcard patterns.
///
///  DEVICE TYPES: a top-level "device_types" object lists the device
///  families the Setup Wizard manages — each SYSTEM_SETUP dev_ count key
///  mapped to its config section prefix and wizard label. Defining it in
///  ui_schema.json REPLACES the built-in list, so a brand-new family (a new
///  dev_ key + section prefix) can be added without recompiling: it gets a
///  wizard count dropdown, device tabs, pruning, count audits, and the
///  "0" migration default automatically.
///
///  CONDITIONAL FIELDS: a field's optional "hideWhen" list names the
///  conditions under which the key means nothing for the block it sits in —
///  ["com_type=Network", "com_type=SerialOverEthernet"] on serial_port. Any
///  one holding and the key is not drawn, not written into a new device, not
///  injected as a SYSTEM_SETUP baseline ("system_defaults"), not offered by
///  Check Defaults, and not copied over by a module's DEVICE_INFO
///  defaults; changing the gating value removes the keys that just became
///  irrelevant. Same condition syntax as "labelWhen".
///
///  CONDITIONAL LABELS: a field's optional "labelWhen" map gives it a
///  different label depending on OTHER values in the same config section —
///  { "gui_usb_or_vga=VGA": "VGA over USB" }. The first matching condition
///  wins; none matching falls back to the plain "label". Conditions are
///  "key=value" (equals), "key!=value" (differs) or "key~text" (contains),
///  all case-insensitive. "key!=value" is what keeps a field out of a room it
///  means nothing in: conf_display_1 is a Conference-mode setting, so it is
///  hidden — and never added — while gui_routing_mode says anything else.
///
///  CONSISTENCY CHECKS: a top-level "consistency" list cross-checks keys that
///  must agree — when one condition holds, another must too. A violation
///  never blocks an edit; it paints the same red mismatch outline the editor
///  already uses for out-of-schema values on every field named in "flag",
///  with "message" as the red helper line ("{key}" inserts a live value).
///  Defining any entries REPLACES the built-in list.
/// ============================================================================

/// Evaluates one condition string against [section]: "key=value" (equals),
/// "key!=value" (differs) or "key~text" (contains), all case-insensitive.
/// Shared by "labelWhen", "hideWhen" and the "consistency" rules.
/// Unparseable conditions are simply false.
bool _conditionHolds(String condition, Map<String, dynamic> section) {
  // '!=' is looked for first: '=' matches inside it, and finding that one
  // would read "a!=b" as the key "a!" equalling "=b".
  final not = condition.indexOf('!=');
  if (not > 0) {
    final key = condition.substring(0, not).trim();
    final want = condition.substring(not + 2).trim().toLowerCase();
    final have = (section[key] ?? '').toString().toLowerCase();
    return have != want;
  }
  for (final op in const ['=', '~']) {
    final i = condition.indexOf(op);
    if (i <= 0) continue;
    final key = condition.substring(0, i).trim();
    final want = condition.substring(i + 1).trim().toLowerCase();
    final have = (section[key] ?? '').toString().toLowerCase();
    return op == '=' ? have == want : (want.isNotEmpty && have.contains(want));
  }
  return false;
}

/// Replaces "{some_key}" in [text] with that key's live value in [section].
/// A missing or empty value becomes "(unset)" so a message never reads as if
/// the key held a blank on purpose.
String _fillPlaceholders(String text, Map<String, dynamic> section) =>
    text.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final v = section[m.group(1)];
      return (v == null || v.toString().isEmpty) ? '(unset)' : v.toString();
    });

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

  /// Condition -> label overrides ("gui_usb_or_vga=VGA" -> "VGA over USB").
  /// Checked against the field's own config section; first match wins.
  final Map<String, String> labelWhen;

  /// Conditions ("com_type=Network") that make this key irrelevant to the
  /// block it sits in. Any one holding and the key is not drawn, not added to
  /// a new device, and not offered by Check Defaults — see [isHiddenIn].
  final List<String> hideWhen;

  final String? description;      // info button text (falls back to ConfigDictionary)
  final String? helperText;       // small gray helper line under the field
  final List<OptionSpec> options; // for dropdown / combo
  final List<String> writes;      // for combo: config keys this field writes
  final String? moduleCommand;    // for module_states: command in self.Commands
  final bool addIfMissing;        // render on a device tab even when the key
                                  // is absent from the device block

  RegExp? _patternRegex;

  FieldSpec({
    required this.key,
    this.type = 'auto',
    this.label,
    this.labelWhen = const {},
    this.hideWhen = const [],
    this.description,
    this.helperText,
    this.options = const [],
    this.writes = const [],
    this.moduleCommand,
    this.addIfMissing = false,
  });

  bool get isPattern => key.contains('*');

  /// The label to show given the current values of [section]: the first
  /// matching [labelWhen] condition, else the plain [label] (null when the
  /// schema gives no label at all and the caller should use the raw key).
  String? labelIn(Map<String, dynamic> section) {
    for (final entry in labelWhen.entries) {
      if (_conditionHolds(entry.key, section)) return entry.value;
    }
    return label;
  }

  /// True when one of this field's [hideWhen] conditions holds in [section] —
  /// the key means nothing for this block as it currently stands (serial_port
  /// on a device whose com_type is Network).
  bool isHiddenIn(Map<String, dynamic> section) {
    for (final condition in hideWhen) {
      if (_conditionHolds(condition, section)) return true;
    }
    return false;
  }

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
      labelWhen: (json['labelWhen'] is Map)
          ? (json['labelWhen'] as Map)
              .map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
      // A single condition may be written as a bare string
      hideWhen: (json['hideWhen'] is List)
          ? (json['hideWhen'] as List).map((e) => e.toString()).toList()
          : (json['hideWhen'] is String)
              ? [json['hideWhen'] as String]
              : const [],
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

/// One wizard-managed device family: the SYSTEM_SETUP count key, the config
/// section prefix its numbered blocks use, and the label shown in the
/// Setup Wizard's count dropdown. Optional extras (all schema-editable):
///   max:                 highest count the wizard dropdown offers (default 8)
///   keepAlivePreference: command names tried in order when auto-picking a
///                        new device's keep_alive_command from its module
///   template:            the full block used for new devices when the
///                        config has no `<PREFIX>1` block to copy (overrides
///                        the built-in synthesized fallback)
class DeviceTypeSpec {
  final String countKey; // e.g. 'dev_projectors'
  final String prefix;   // e.g. 'PROJECTORDEVICE_'
  final String label;    // e.g. 'Projectors / Displays'
  final int maxCount;    // wizard dropdown offers 0..maxCount
  final List<String> keepAlivePreference;
  final Map<String, dynamic>? template;

  /// SYSTEM_SETUP key patterns ('*' wildcard) that only mean anything while
  /// this family has hardware in the room — e.g. the power controller's
  /// `power1_outlet_*` names. Setting the family's count to 0 removes them,
  /// because outlet names with no power controller behind them are dead data
  /// the tech still has to read past on the System tab.
  final List<String> systemKeys;

  const DeviceTypeSpec({
    required this.countKey,
    required this.prefix,
    String? label,
    this.maxCount = 8,
    this.keepAlivePreference = const [],
    this.template,
    this.systemKeys = const [],
  }) : label = label ?? countKey;

  /// True when [key] matches one of this family's [systemKeys] patterns.
  /// Case-insensitive so a legacy block's POWER1_OUTLET_1 is caught too.
  bool ownsSystemKey(String key) {
    for (final pattern in systemKeys) {
      final regex = RegExp(
          '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
          caseSensitive: false);
      if (regex.hasMatch(key)) return true;
    }
    return false;
  }
}

/// One "consistency" entry: a cross-key sanity check inside a single config
/// section. When [whenCondition] holds, [expectCondition] must hold too —
/// e.g. a gui_tab_type carrying a VGA source requires gui_usb_or_vga "VGA".
///
/// A violation never blocks an edit or a save: it paints the red mismatch
/// outline (the one already used for out-of-schema values) on every field
/// named in [flag], with [message] as the red helper line. Rules whose
/// [whenCondition] doesn't hold are silent, so tab types that pin neither
/// USB nor VGA (the Wireless-only ones) are never flagged.
class ConsistencyRule {
  final String sectionPattern;  // '*' wildcard; SYSTEM_SETUP by default
  final String whenCondition;   // e.g. 'gui_tab_type~VGA'
  final String expectCondition; // e.g. 'gui_usb_or_vga=VGA'
  final String message;         // '{key}' inserts that key's live value
  final List<String> flag;      // field keys that show the warning

  RegExp? _sectionRegex;

  ConsistencyRule({
    this.sectionPattern = 'SYSTEM_SETUP',
    required this.whenCondition,
    required this.expectCondition,
    this.message = '',
    this.flag = const [],
  });

  bool matchesSection(String sectionKey) {
    if (!sectionPattern.contains('*')) return sectionPattern == sectionKey;
    _sectionRegex ??=
        RegExp('^${RegExp.escape(sectionPattern).replaceAll(r'\*', '.*')}\$');
    return _sectionRegex!.hasMatch(sectionKey);
  }

  /// The violation message for [section], or null when this rule doesn't
  /// apply to [sectionKey], doesn't fire, or is satisfied.
  String? violation(String sectionKey, Map<String, dynamic> section) {
    if (!matchesSection(sectionKey)) return null;
    if (!_conditionHolds(whenCondition, section)) return null;
    if (_conditionHolds(expectCondition, section)) return null;
    return _fillPlaceholders(
        message.isEmpty
            ? 'Schema check: with $whenCondition, $expectCondition is required.'
            : message,
        section);
  }
}

/// The panel source names this room actually has, for a screen that is pinned
/// to one instead of following the room.
///
/// The room already states this, twice over: every source it carries has an
/// `input_*` key in SYSTEM_SETUP holding the switcher input it is wired to. A
/// key with a value is a source the room has; a blank one is a source it does
/// not. So the list of things a display could be pinned to is not a judgment
/// call, it is a read — which is the whole point, because typing 'doccam' into
/// a room whose panel calls it 'doc_cam' produces a display that is never
/// routed and nothing that says why.
///
/// The name is the key without its `input_` prefix, which is what the panel
/// and the processor call it: `input_pc_extended` is 'pc_extended'. Two
/// exceptions, both real:
///
///   * the plate that is USB in a new room and VGA in an old one is one key
///     with two names, and `gui_usb_or_vga` says which;
///   * `input_sub_switcher` and the `input_station_*` keys are left out —
///     a sub switcher is a box, not a source button, and a station's own feed
///     belongs to that station rather than to the room.
List<String> roomSourceNames(Map<String, dynamic> setup) {
  const notASource = {'input_sub_switcher'};
  final names = <String>{};

  setup.forEach((key, value) {
    if (!key.startsWith('input_')) return;
    if (notASource.contains(key)) return;
    if (key.startsWith('input_station_')) return;
    if (value == null || value.toString().trim().isEmpty) return;

    if (key == 'input_usb') {
      final vga = (setup['gui_usb_or_vga']?.toString().trim().toUpperCase() ??
              'USB') ==
          'VGA';
      names.add(vga ? 'vga' : 'usb');
      return;
    }
    names.add(key.substring('input_'.length));
  });

  return names.toList()..sort();
}

/// Which `input_*` keys a room is entitled to, given the sources it has.
///
/// A room's source list is spelled twice: `gui_inputs` counts them and
/// `gui_tab_type` names them ("DOC_USB_WL"). The switcher input each source
/// is wired to then lives in its own SYSTEM_SETUP key. Nothing kept the two
/// in step, so a room whose sources were retyped from six down to four still
/// shipped `input_blu_ray` and `input_dvd` — inputs the panel has no button
/// for, on a switcher that has something else plugged into those numbers.
/// That is not merely untidy: the next person to read the file believes it.
///
/// [tokens] maps one piece of a tab type to the key it entitles the room to;
/// [always] are the keys every layout has regardless (the PC and the room's
/// HDMI plate) plus the ones some OTHER setting governs (the sub switcher's
/// input, the extended-desktop input); [cameras] are the ones that exist only
/// while the room has cameras, so `dev_cameras` 0 takes them with it.
///
/// Only keys named here are ever removed — an `input_` key the schema does
/// not know about is left exactly where it is.
class SourceInputRules {
  /// Source token (a piece of gui_tab_type) -> the input key it entitles.
  final Map<String, String> tokens;

  /// Keys every sources layout carries, or that another setting governs.
  final List<String> always;

  /// Keys that only mean anything while the room has at least one camera.
  final List<String> cameras;

  const SourceInputRules({
    this.tokens = const {},
    this.always = const [],
    this.cameras = const [],
  });

  static const SourceInputRules builtIn = SourceInputRules(
    tokens: {
      'DOC': 'input_doc_cam',
      'DVD': 'input_dvd',
      'BR': 'input_blu_ray',
      'WL': 'input_wireless',
      // One physical input, labeled USB or VGA by gui_usb_or_vga — the key
      // name stays input_usb either way, so both tokens claim it.
      'USB': 'input_usb',
      'VGA': 'input_usb',
    },
    always: [
      'input_pc',
      'input_hdmi',
      // Governed by gui_routing_mode "Extended", not by the sources list.
      'input_pc_extended',
      // Governed by sub_switch_sources.
      'input_sub_switcher',
    ],
    cameras: ['input_inst_cam', 'input_aud_cam'],
  );

  /// True when this ruleset says nothing at all, so the caller leaves the
  /// config alone rather than stripping every input key in it.
  bool get isEmpty => tokens.isEmpty && always.isEmpty && cameras.isEmpty;

  /// Every key these rules are willing to take responsibility for.
  Set<String> get managedKeys => {...always, ...tokens.values, ...cameras};

  /// The keys a room with this [tabType] and [cameraCount] should carry.
  Set<String> expectedKeys({required String tabType, required int cameraCount}) {
    final out = <String>{...always};
    for (final piece in tabType.split('_')) {
      final key = tokens[piece.trim().toUpperCase()];
      if (key != null) out.add(key);
    }
    if (cameraCount > 0) out.addAll(cameras);
    return out;
  }

  /// The keys [setup] holds that this room is not entitled to: managed by
  /// these rules, present in the block, and not expected. Sorted so the log
  /// line reads the same way twice.
  ///
  /// A setting the room does not state is a question, not a No. A legacy file
  /// with no `gui_tab_type` at all has not told us it has no doc cam — it has
  /// told us nothing — so the token-driven keys are left exactly where they
  /// are, and the same goes for the camera inputs when `dev_cameras` is
  /// missing. Removing them on a silence would delete real site data on the
  /// first load of exactly the oldest, least reproducible configs.
  List<String> staleKeysIn(Map<String, dynamic> setup) {
    if (isEmpty) return const [];

    final String tabType = setup['gui_tab_type']?.toString().trim() ?? '';
    final bool knowsSources = tabType.isNotEmpty;
    final bool knowsCameras = setup.containsKey('dev_cameras');

    final expected = expectedKeys(
      tabType: tabType,
      cameraCount: int.tryParse(setup['dev_cameras']?.toString() ?? '') ?? 0,
    );

    // What this room has actually answered for.
    final managed = <String>{
      ...always,
      if (knowsSources) ...tokens.values,
      if (knowsCameras) ...cameras,
    };

    return [
      for (final key in setup.keys)
        if (managed.contains(key) && !expected.contains(key)) key,
    ]..sort();
  }
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

  /// Cross-key sanity checks from "consistency", surfaced as the red mismatch
  /// outline on the fields each rule flags. Defining any in ui_schema.json
  /// replaces the built-in list.
  final List<ConsistencyRule> _consistency = [];

  List<ConsistencyRule> get consistencyRules => List.unmodifiable(_consistency);

  /// Which `input_*` keys the room's sources entitle it to — see
  /// [SourceInputRules]. A "source_inputs" section in ui_schema.json replaces
  /// the built-in ruleset entirely.
  SourceInputRules _sourceInputs = SourceInputRules.builtIn;

  SourceInputRules get sourceInputs => _sourceInputs;

  /// The device families the Setup Wizard manages, in display order. Starts
  /// as the built-in list (the previously hardcoded ten); a "device_types"
  /// section in ui_schema.json replaces it entirely.
  List<DeviceTypeSpec> _deviceTypes = List.of(_builtInDeviceTypes);

  /// The previously hardcoded families, kept as the no-schema-file baseline.
  static const List<DeviceTypeSpec> _builtInDeviceTypes = [
    DeviceTypeSpec(countKey: 'dev_projectors', prefix: 'PROJECTORDEVICE_', label: 'Projectors / Displays'),
    DeviceTypeSpec(countKey: 'dev_cameras', prefix: 'CAMERADEVICE_', label: 'Cameras'),
    DeviceTypeSpec(countKey: 'dev_switchers', prefix: 'SWITCHERDEVICE_', label: 'Switchers'),
    DeviceTypeSpec(countKey: 'dev_dsps', prefix: 'DSPDEVICE_', label: 'DSPs'),
    DeviceTypeSpec(countKey: 'dev_usb_switchers', prefix: 'USBDEVICE_', label: 'USB Switchers'),
    DeviceTypeSpec(
        countKey: 'dev_power_controllers',
        prefix: 'POWERDEVICE_',
        label: 'Power Controllers',
        // No controller, no outlets — see [DeviceTypeSpec.systemKeys]. Mirrors
        // the key_map.json removal that already does this on load.
        systemKeys: ['power*_outlet_*']),
    DeviceTypeSpec(countKey: 'dev_media_ports', prefix: 'MEDIAPORTDEVICE_', label: 'MediaPorts'),
    DeviceTypeSpec(countKey: 'dev_wireless', prefix: 'WIRELESSDEVICE_', label: 'Wireless'),
    DeviceTypeSpec(countKey: 'dev_recorders', prefix: 'RECORDERDEVICE_', label: 'Recorders'),
    DeviceTypeSpec(countKey: 'dev_screens', prefix: 'SCREENDEVICE_', label: 'Screens / Network'),
    // The NAV share room's two families. A NAVigator is not a room switcher —
    // SwitcherManager sends its handlers Set("Input", ...) and a NAVigator
    // answers none of that — so it has its own count key, and the stations
    // hanging off it have theirs. Both carry SYSTEM_SETUP keys that mean
    // nothing without the hardware, so a room that is not a share room drops
    // them the same way a room with no power controller drops its outlets.
    DeviceTypeSpec(
        countKey: 'dev_nav_switchers',
        prefix: 'NAVDEVICE_',
        label: 'NAV Stream Managers',
        maxCount: 4,
        systemKeys: [
          'share_nav_device',
          'share_room_outputs',
          'share_stop_ties',
          'share_stop_ties_wireless',
          'share_preview_*',
          'share_instructor_*',
          'share_usb_*',
          'share_audio_*',
        ]),
    DeviceTypeSpec(
        countKey: 'dev_share_stations',
        prefix: 'STATIONDEVICE_',
        label: 'Share Stations',
        maxCount: 13,
        systemKeys: [
          'input_station_*',
          'output_station_*',
          'share_station_*',
        ]),
    // The one family with no connection at all: a button panel is a UI device
    // on the AV LAN, addressed by its GC alias, and DeviceHandler skips it by
    // name rather than looking for a module.
    DeviceTypeSpec(
        countKey: 'dev_nbps', prefix: 'NBPDEVICE_', label: 'Button Panels (NBP)'),
  ];

  /// Wizard display order (file order when "device_types" is defined).
  List<DeviceTypeSpec> get deviceTypes => List.unmodifiable(_deviceTypes);

  /// countKey -> section prefix, for tab building / pruning / audits.
  Map<String, String> get deviceCountMap =>
      {for (final t in _deviceTypes) t.countKey: t.prefix};

  /// The device family whose section prefix [sectionKey] starts with
  /// (e.g. 'PROJECTORDEVICE_2' -> the dev_projectors family), or null.
  DeviceTypeSpec? deviceTypeForSection(String sectionKey) {
    for (final t in _deviceTypes) {
      if (sectionKey.startsWith(t.prefix)) return t;
    }
    return null;
  }

  /// Baseline SYSTEM_SETUP values injected into loaded configs that are
  /// missing them (the migration step). Starts as the previously hardcoded
  /// set; a "system_defaults" section in ui_schema.json replaces it.
  /// The dev_ count keys are NOT included here — they always come from
  /// device_types so the two stay in sync.
  Map<String, dynamic> _systemDefaults = Map.of(_builtInSystemDefaults);

  static const Map<String, dynamic> _builtInSystemDefaults = {
    "gve_bldg": "UNKNOWN",
    "gve_room": "000",
    "gui_full_room_name": "Legacy Room Update",
    "gui_mic_mix": "No",
    "gui_routing_available": "No",
    "gui_routing_mode": "Normal",
    "gui_tab": "2_Cam_Dev",
    "gui_capture_source_available": "No",
    "gui_usb_or_vga": "USB",
  };

  Map<String, dynamic> get systemDefaults => Map.unmodifiable(_systemDefaults);

  /// Whole non-device config sections and their baseline properties, from
  /// "section_defaults" (e.g. "METRICS_CONFIG"). Injected into loaded configs
  /// that are missing the section or any of its properties. Empty unless the
  /// schema file defines it — nothing is built in.
  /// "SECTION" or "SECTION.key" entries (with '*' wildcards) naming config
  /// items the PROCESSOR writes while the room runs — see [isRuntimeWritten].
  final Set<String> _runtimeWritten = {};

  final Map<String, Map<String, dynamic>> _sectionDefaults = {};

  Map<String, Map<String, dynamic>> get sectionDefaults =>
      Map.unmodifiable(_sectionDefaults);

  /// The raw "runtime_written" entries, for display/tests.
  Set<String> get runtimeWritten => Set.unmodifiable(_runtimeWritten);

  /// True when the processor maintains this config item itself, so finding it
  /// in a downloaded file is expected rather than a problem.
  ///
  /// A room's config.json is written back by the processor while it runs:
  /// ENVIRONMENT.traceback_allowed and the SYSTEM_SETUP power schedule times
  /// are set on the fly. They are legitimately absent from the template, so the
  /// template audit must not report them and the System tab must not draw them
  /// as unknown keys.
  ///
  /// [propertyKey] null asks about the section itself. Entries are
  /// "SECTION" or "SECTION.key", with '*' matching any run of characters.
  bool isRuntimeWritten(String sectionKey, [String? propertyKey]) {
    final target = propertyKey == null ? sectionKey : '$sectionKey.$propertyKey';
    for (final pattern in _runtimeWritten) {
      final regex = RegExp(
          '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
          caseSensitive: false);
      if (regex.hasMatch(target)) return true;
    }
    return false;
  }

  /// True for a top-level config section that is neither SYSTEM_SETUP nor a
  /// numbered device block — i.e. a standalone settings block like
  /// METRICS_CONFIG, which the System tab renders as its own group.
  bool isExtraSection(String sectionKey) =>
      sectionKey != 'SYSTEM_SETUP' && deviceTypeForSection(sectionKey) == null;

  /// Where this schema came from, for display in App Config.
  String source = 'Built-in defaults';

  /// The document this schema was read from, kept verbatim.
  ///
  /// The Schema Editor edits THIS and hands it back, rather than
  /// reassembling a file out of the parsed structures. Two reasons, and both
  /// of them are somebody's afternoon: a key this build does not understand
  /// yet survives a round trip instead of being silently dropped, and so do
  /// the "__comment" entries the file uses to explain itself. Empty when the
  /// schema is the built-in one — nothing has been read.
  Map<String, dynamic> rawDoc = {};

  /// Builds a schema from a document in memory: the built-ins with the
  /// document laid over them, which is exactly what [load] does with a file.
  static UiSchema fromDoc(Map<String, dynamic> doc) {
    final schema = UiSchema.builtIn();
    schema.applyJsonMap(doc);
    schema.rawDoc = jsonDecode(jsonEncode(doc)) as Map<String, dynamic>;
    return schema;
  }

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

  /// Specs marked addIfMissing whose keys are NOT in [existingKeys] — the
  /// device tab renders these as extra fields so a setting appears before it
  /// exists in config.json. Global "fields" entries count as well as
  /// device-scoped ones: serial_port belongs to every family, not one, and a
  /// device switched to Serial needs somewhere to type the port.
  ///
  /// [section] is the live block, so a spec its "hideWhen" rules out is left
  /// off too: a placeholder field is still a field, and offering one the
  /// connection can't use is the thing hideWhen exists to stop.
  List<FieldSpec> missingFieldsFor(
      String sectionKey, Iterable<String> existingKeys,
      {Map<String, dynamic> section = const {}}) {
    final existing = existingKeys.toSet();
    final Map<String, FieldSpec> result = {};

    void offer(FieldSpec spec) {
      if (existing.contains(spec.key)) return;
      if (spec.isHiddenIn(section)) return;
      result[spec.key] = spec;
    }

    // Global entries first, so a device-scoped one of the same name wins.
    for (final spec in _exact.values) {
      if (spec.addIfMissing) offer(spec);
    }
    for (final scoped in _deviceScoped) { // later (file) entries override
      if (!scoped.matchesSection(sectionKey)) continue;
      scoped.addIfMissingSpecs.forEach(offer);
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

  /// The label for [configKey] as it should read given the current values of
  /// [section] (its own config block) — honors "labelWhen", so input_usb can
  /// read "VGA over USB" in a VGA room. Null when the schema gives the key no
  /// label at all; callers fall back to the raw key or their own formatting.
  String? labelFor(String configKey, Map<String, dynamic> section,
          {String? sectionKey}) =>
      specFor(configKey, sectionKey: sectionKey)?.labelIn(section);

  /// True when [configKey]'s schema entry says the key means nothing for
  /// [section] as it currently stands — "hideWhen". The one question every
  /// path asks before drawing, adding, offering or copying in a property, so
  /// a Network device never acquires a serial_port from any direction.
  bool isHiddenFor(String configKey, Map<String, dynamic> section,
          {String? sectionKey}) =>
      specFor(configKey, sectionKey: sectionKey)?.isHiddenIn(section) ?? false;

  /// The keys [section] currently holds that [isHiddenFor] rejects — what a
  /// com_type change leaves behind. Callers remove them and log what went.
  List<String> staleKeysIn(String sectionKey, Map<String, dynamic> section) =>
      section.keys
          .where((k) => isHiddenFor(k, section, sectionKey: sectionKey))
          .toList();

  /// The friendly label a dropdown gives [value] (e.g. gui_tab "3_Cams_Dev" ->
  /// "Menu Tabs: 3 - Cameras & Devices"). Falls back to [value] itself when the
  /// key isn't a dropdown or the value isn't one of its options, so a report
  /// never blanks out a value it doesn't recognize.
  String optionLabelFor(String configKey, String value, {String? sectionKey}) {
    final spec = specFor(configKey, sectionKey: sectionKey);
    for (final option in spec?.options ?? const <OptionSpec>[]) {
      if (option.value == value) return option.label;
    }
    return value;
  }

  /// The friendly label of the "combo" field [configKey] given the current
  /// values of [section] — the combo's written keys joined with "_" and looked
  /// up in its options (gui_inputs "5" + gui_tab_type "DOC_USB_WL" ->
  /// "5 Sources: PC, HDMI, Doc Cam, USB, & Wireless"). Null when the key isn't
  /// a combo, or when the live combination isn't one of its options.
  String? comboLabelFor(String configKey, Map<String, dynamic> section,
      {String? sectionKey}) {
    final spec = specFor(configKey, sectionKey: sectionKey);
    if (spec == null || spec.type != 'combo') return null;
    final writes = spec.writes.isNotEmpty ? spec.writes : [configKey];
    final key = writes.map((k) => (section[k] ?? '').toString()).join('_');
    for (final option in spec.options) {
      if (option.comboKey == key) return option.label;
    }
    return null;
  }

  /// The first "consistency" violation that names [fieldKey] in its flag list,
  /// or null when every cross-checked key in [section] agrees.
  String? consistencyMessageFor(
      String fieldKey, String sectionKey, Map<String, dynamic> section) {
    for (final rule in _consistency) {
      if (!rule.flag.contains(fieldKey)) continue;
      final message = rule.violation(sectionKey, section);
      if (message != null) return message;
    }
    return null;
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
    // and its alias "section_fields" for non-device blocks (METRICS_CONFIG).
    for (final key in const ['device_fields', 'section_fields']) {
      final scopedFields = doc[key];
      if (scopedFields is! Map) continue;
      scopedFields.forEach((sectionPattern, fieldMap) {
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

    // Optional "device_types": { "dev_projectors": { "prefix": ..., "label": ... } }
    // Defining ANY entries replaces the built-in family list entirely, so the
    // file controls order and can add/remove/rename families.
    final deviceTypes = doc['device_types'];
    if (deviceTypes is Map) {
      final List<DeviceTypeSpec> parsed = [];
      deviceTypes.forEach((countKey, spec) {
        if (countKey.toString().startsWith('__')) return;
        if (spec is! Map) return;
        final prefix = spec['prefix']?.toString();
        if (prefix == null || prefix.isEmpty) return; // prefix is required
        parsed.add(DeviceTypeSpec(
          countKey: countKey.toString(),
          prefix: prefix,
          label: spec['label']?.toString(),
          maxCount: (spec['max'] is num)
              ? (spec['max'] as num).toInt()
              : int.tryParse(spec['max']?.toString() ?? '') ?? 8,
          keepAlivePreference: (spec['keepAlivePreference'] is List)
              ? (spec['keepAlivePreference'] as List)
                  .map((e) => e.toString())
                  .toList()
              : const [],
          template: (spec['template'] is Map)
              ? (spec['template'] as Map)
                  .map((k, v) => MapEntry(k.toString(), v))
              : null,
          systemKeys: (spec['systemKeys'] is List)
              ? (spec['systemKeys'] as List)
                  .map((e) => e.toString())
                  .where((s) => s.isNotEmpty)
                  .toList()
              : const [],
        ));
      });
      if (parsed.isNotEmpty) _deviceTypes = parsed;
    }

    // Optional "system_defaults": SYSTEM_SETUP values injected on load when
    // missing. Defining ANY entries replaces the built-in set entirely.
    final systemDefaults = doc['system_defaults'];
    if (systemDefaults is Map) {
      final Map<String, dynamic> parsedDefaults = {};
      systemDefaults.forEach((key, value) {
        if (key.toString().startsWith('__')) return;
        parsedDefaults[key.toString()] = value;
      });
      if (parsedDefaults.isNotEmpty) _systemDefaults = parsedDefaults;
    }

    // Optional "section_defaults": whole non-device blocks injected on load
    // when missing, e.g. { "METRICS_CONFIG": { "enabled": false, ... } }.
    final sectionDefaults = doc['section_defaults'];
    if (sectionDefaults is Map) {
      sectionDefaults.forEach((sectionKey, valueMap) {
        if (sectionKey.toString().startsWith('__')) return;
        if (valueMap is! Map) return;
        final Map<String, dynamic> values = {};
        valueMap.forEach((key, value) {
          if (key.toString().startsWith('__')) return;
          values[key.toString()] = value;
        });
        // File entries replace any earlier definition of the same section
        if (values.isNotEmpty) _sectionDefaults[sectionKey.toString()] = values;
      });
    }

    // Optional "runtime_written": keys the PROCESSOR maintains at run time, so
    // a downloaded config legitimately carries things the template never had.
    final runtimeWritten = doc['runtime_written'];
    if (runtimeWritten is List) {
      for (final entry in runtimeWritten) {
        final text = entry.toString().trim();
        if (text.isEmpty || text.startsWith('__')) continue;
        _runtimeWritten.add(text);
      }
    }

    // Optional "source_inputs": which input_* keys each source token entitles
    // the room to. Defining ANY of the three lists replaces the built-in
    // ruleset entirely, so the file owns the whole vocabulary rather than
    // half of it merged with a stale built-in half.
    final sourceInputs = doc['source_inputs'];
    if (sourceInputs is Map) {
      List<String> stringList(String key) => (sourceInputs[key] is List)
          ? [
              for (final e in sourceInputs[key] as List)
                if (e.toString().trim().isNotEmpty) e.toString().trim(),
            ]
          : const [];
      final Map<String, String> tokens = {};
      final rawTokens = sourceInputs['tokens'];
      if (rawTokens is Map) {
        rawTokens.forEach((token, key) {
          if (token.toString().startsWith('__')) return;
          final name = key?.toString().trim() ?? '';
          if (name.isEmpty) return;
          tokens[token.toString().trim().toUpperCase()] = name;
        });
      }
      final always = stringList('always');
      final cameras = stringList('cameras');
      if (tokens.isNotEmpty || always.isNotEmpty || cameras.isNotEmpty) {
        _sourceInputs = SourceInputRules(
          tokens: tokens,
          always: always,
          cameras: cameras,
        );
      }
    }

    // Optional "consistency": [{ "when": ..., "expect": ..., "flag": [...] }]
    // Defining ANY valid entries replaces the built-in list, so the file owns
    // the full set. Entries missing "when"/"expect" are skipped, which is what
    // lets a leading { "__readme": [...] } item document the list in place.
    final consistency = doc['consistency'];
    if (consistency is List) {
      final List<ConsistencyRule> parsed = [];
      for (final item in consistency) {
        if (item is! Map) continue;
        final when = item['when']?.toString();
        final expect = item['expect']?.toString();
        if (when == null || when.isEmpty) continue;
        if (expect == null || expect.isEmpty) continue;
        parsed.add(ConsistencyRule(
          sectionPattern: item['section']?.toString() ?? 'SYSTEM_SETUP',
          whenCondition: when,
          expectCondition: expect,
          message: item['message']?.toString() ?? '',
          flag: (item['flag'] is List)
              ? (item['flag'] as List).map((e) => e.toString()).toList()
              : const [],
        ));
      }
      if (parsed.isNotEmpty) {
        _consistency
          ..clear()
          ..addAll(parsed);
      }
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
      OptionSpec(value: '2_Cam_Dev', label: 'Menu Tabs: 2 - Camera & Devices'),
      OptionSpec(value: '2_Mic_Dev', label: 'Menu Tabs: 2 - Mic & Devices'),
      OptionSpec(
          value: '3_Cam_Mic_Dev',
          label: 'Menu Tabs: 3 - Camera, Mic, & Devices'),
      OptionSpec(value: '3_Cams_Dev', label: 'Menu Tabs: 3 - Cameras & Devices'),
      OptionSpec(
          value: '4_Cams_Mic_Dev',
          label: 'Menu Tabs: 4 - Cameras, Mic, & Devices'),
      // Conference draws the same two tabs, but with no instructor camera it
      // substitutes the Camera2Handler.
      OptionSpec(
          value: 'Conference',
          label: 'Menu Tabs: 2 - Camera & Devices '
              '(subs the Camera2Handler - no instructor camera)'),
    ]));
    s._add(FieldSpec(key: 'gui_capture_source_available', type: 'dropdown',
        options: const [OptionSpec(value: 'Yes'), OptionSpec(value: 'No')]));
    s._add(FieldSpec(key: 'gui_usb_or_vga', type: 'dropdown',
        options: const [OptionSpec(value: 'USB'), OptionSpec(value: 'VGA')]));

    // One physical input, switched between USB and VGA by gui_usb_or_vga; the
    // report and the field label follow the toggle instead of always saying
    // "USB".
    s._add(FieldSpec(key: 'input_usb', labelWhen: const {
      'gui_usb_or_vga=VGA': 'VGA',
    }));

    // gui_tab_type's USB/VGA source and gui_usb_or_vga describe the same
    // choice from two angles, so a config where they disagree is a mistake.
    // Neither is forced: both fields are flagged and the tech picks. Tab
    // types that name neither (the Wireless-only ones) never fire a rule.
    s._consistency.addAll([
      ConsistencyRule(
        whenCondition: 'gui_tab_type~VGA',
        expectCondition: 'gui_usb_or_vga=VGA',
        flag: const ['gui_usb_or_vga', 'gui_inputs'],
        message: 'Sources include VGA (gui_tab_type is "{gui_tab_type}") but '
            'gui_usb_or_vga is "{gui_usb_or_vga}" - set it to VGA, or pick a '
            'USB sources option.',
      ),
      ConsistencyRule(
        whenCondition: 'gui_tab_type~USB',
        expectCondition: 'gui_usb_or_vga=USB',
        flag: const ['gui_usb_or_vga', 'gui_inputs'],
        message: 'Sources include USB (gui_tab_type is "{gui_tab_type}") but '
            'gui_usb_or_vga is "{gui_usb_or_vga}" - set it to USB, or pick a '
            'VGA sources option.',
      ),
    ]);

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
        schema.rawDoc = jsonDecode(jsonEncode(doc)) as Map<String, dynamic>;
        schema.source = candidate;
        AppLogger.logInfo(
            'UI schema loaded from $candidate (${schema.fieldCount} field definitions).');
        return schema;
      } catch (e, stack) {
        AppLogger.logError(
            'Failed to load ui_schema.json from $candidate - using built-in defaults.',
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
