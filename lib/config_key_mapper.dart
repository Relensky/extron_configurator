import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;

import 'app_logger.dart';

/// ============================================================================
///  CONFIG KEY MAPPING SYSTEM
/// ============================================================================
///  Loads an external `key_map.json` file that translates LEGACY config.json
///  key names into the current schema, e.g.:
///
///     "CAMERA1DEVICE"        ->  "CAMERADEVICE_1"
///     "SYSTEM"               ->  "SYSTEM_SETUP"
///     "COMTYPE"              ->  "com_type"
///     "gui_TABTYPE"          ->  "gui_tab_type"
///     SYSTEM.GVE_ID_Camera_1 ->  CAMERADEVICE_1.gve_id   (cross-section move)
///
///  It runs automatically whenever a config is loaded (local file or SFTP
///  download), BEFORE the normal template migration, and every change is
///  written to the migration log + audit dialog. Rules live in JSON, so new
///  legacy variants can be supported by editing key_map.json — no rebuild.
///
///  key_map.json structure:
///    "auto_case_normalization": true|false — when true, any property whose
///                  lowercased, underscore-stripped form matches a known
///                  current key is renamed automatically (Output_Proj1 ->
///                  output_proj_1 needs no explicit entry... but
///                  "Active_Notifications" -> "active_notifications" does
///                  match automatically). Explicit "properties" entries
///                  always run first and always win.
///    "sections":   list of { "match": <regex>, "rename_to": <name> } rules
///                  applied to TOP-LEVEL section names. The regex must match
///                  the whole name; $1..$9 insert capture groups.
///    "properties": flat { "OLDNAME": "new_name" } map applied to every
///                  property inside every section.
///    "value_map":  optional { "property": { "OldValue": <new value> } } to
///                  normalize stored values after renaming. New values keep
///                  their JSON type ("True" -> true, "Yes" -> "1", etc).
///    "moves":      list of { "from_section", "key_match", "to_section",
///                  "to_key" } rules relocating a property into another
///                  section (regex capture groups work in to_section), e.g.
///                  GVE_ID_Projector_(\d+) -> PROJECTORDEVICE_$1.gve_id.
///    "defaults":   { "SECTIONPATTERN_*": { "key": <value> } } — after all
///                  of the above, any listed key still MISSING from a
///                  matching section is injected. "{n}" in a string value
///                  becomes the section's trailing device number.
///    "remove_unused_devices" + "device_counts": when true, legacy-named
///                  device blocks whose family count in SYSTEM_SETUP is
///                  No/0 (or below their number) are REMOVED instead of
///                  converted. Never touches blocks that already had
///                  current-style names.
///    "companion_keys": list of { "key_match", "ensure_key", "value",
///                  optional "section" } rules. For every property matching
///                  key_match, the ensure_key (with $1..$9 capture groups)
///                  is created in the same section when missing, e.g.
///                  power1_outlet_(\d+) -> power1_outlet_$1_action = null.
///
///  NOTE on carriage returns: escape_carriage_returns stores the value in
///  memory as the two-character sequence backslash+r. When the config is
///  saved, the JSON encoder escapes the backslash, so the file on disk
///  contains \\r — e.g. "TLP\\rPoE" — which is the form the processor
///  code reads.
///
///  Processing order: sections -> properties -> auto-normalization ->
///  value_map -> moves -> unused-device removal -> carriage-return escaping ->
///  smart device defaults (name/btn/lbl/model matching) -> companion keys ->
///  defaults.
/// ============================================================================

/// One top-level section rename rule ("CAMERA(\d+)DEVICE" -> "CAMERADEVICE_$1").
class SectionRule {
  final RegExp match;
  final String renameTo;
  SectionRule({required String pattern, required this.renameTo})
      : match = RegExp('^(?:$pattern)\$');

  /// Returns the new section name, or null when the rule doesn't apply.
  String? apply(String sectionName) {
    final m = match.firstMatch(sectionName);
    if (m == null) return null;
    return _substituteGroups(renameTo, m);
  }
}

/// One cross-section relocation rule (e.g. the per-device GVE IDs that legacy
/// configs kept inside SYSTEM but the current schema stores on each device).
class MoveRule {
  final String fromSection; // exact section name AFTER section renames
  final RegExp keyMatch;
  final String toSection;   // may contain $1..$9 from keyMatch
  final String toKey;
  MoveRule({
    required this.fromSection,
    required String pattern,
    required this.toSection,
    required this.toKey,
  }) : keyMatch = RegExp('^(?:$pattern)\$');
}

/// One companion-key rule: for every property matching [keyMatch], make sure
/// a partner key (built from capture groups) also exists in the same section,
/// e.g. power1_outlet_(\d+) -> ensure power1_outlet_$1_action (null).
class CompanionRule {
  final RegExp keyMatch;
  final String ensureKey;      // may contain $1..$9 from keyMatch
  final dynamic value;         // injected value (kept as-is, may be null)
  final String? sectionPattern; // optional '*' wildcard section filter
  CompanionRule({
    required String pattern,
    required this.ensureKey,
    this.value,
    this.sectionPattern,
  }) : keyMatch = RegExp('^(?:$pattern)\$');
}

/// Replaces $1..$9 in [template] with the capture groups of [m].
String _substituteGroups(String template, RegExpMatch m) {
  String out = template;
  for (int i = 1; i <= m.groupCount && i <= 9; i++) {
    out = out.replaceAll('\$$i', m.group(i) ?? '');
  }
  return out;
}

/// Result of running the mapper over a config.
class KeyMapResult {
  final Map<String, dynamic> config;
  final List<String> changes;
  KeyMapResult(this.config, this.changes);
  bool get changed => changes.isNotEmpty;
}

class ConfigKeyMap {
  final List<SectionRule> sections = [];
  final Map<String, String> properties = {};
  final Map<String, Map<String, dynamic>> valueMap = {};
  final List<MoveRule> moves = [];
  final Map<String, Map<String, dynamic>> defaults = {};

  /// Companion-key rules ("companion_keys" in key_map.json): for every key
  /// matching a pattern, guarantee a partner key exists in the same section
  /// (e.g. every power1_outlet_N gets a power1_outlet_N_action of null).
  final List<CompanionRule> companions = [];

  bool autoCaseNormalization = false;

  /// When true, LEGACY-named device blocks whose family count in SYSTEM_SETUP
  /// says they're not in use (No / 0 / above the count) are REMOVED instead
  /// of converted. Only blocks renamed by a section rule are eligible, so
  /// new-style template files that intentionally carry every block with low
  /// counts are never stripped.
  bool removeUnusedDevices = false;

  /// SYSTEM_SETUP count key -> device section prefix ("dev_switchers" ->
  /// "SWITCHERDEVICE_"). Used by [removeUnusedDevices].
  final Map<String, String> deviceCounts = {};

  /// When true, real carriage-return control characters inside string values
  /// (\r\n or \r) are converted to the literal two-character sequence \r that
  /// the processor GUI expects (e.g. "Intake<CR><LF>Fans" -> "Intake\rFans").
  bool escapeCarriageReturns = false;

  /// Device prefix -> friendly label used to generate device names
  /// ("CAMERADEVICE_" -> "Camera" -> "Camera 2 - Cam570").
  final Map<String, String> deviceLabels = {};

  /// Reference device blocks from the current template, keyed by section name
  /// ("CAMERADEVICE_2" -> {btn_name, lbl_name, model, module, ...}). Used to
  /// carry over btn/lbl names by device NUMBER and module/keep_alive_trigger
  /// by matching MODEL when converting legacy files.
  final Map<String, Map<String, dynamic>> deviceTemplates = {};

  /// Where this map came from, for display in App Config.
  String source = 'Built-in (no mapping rules)';

  int get ruleCount =>
      sections.length + properties.length + valueMap.length + moves.length +
      defaults.length + deviceCounts.length + companions.length;

  /// The built-in map is intentionally EMPTY: legacy naming is site-specific,
  /// so all rules come from key_map.json. With no file present, loading a
  /// config behaves exactly as before.
  static ConfigKeyMap builtIn() => ConfigKeyMap();

  void _applyJsonMap(Map<String, dynamic> doc) {
    autoCaseNormalization = doc['auto_case_normalization'] == true;
    removeUnusedDevices = doc['remove_unused_devices'] == true;

    // Count key -> section prefix mapping for unused-device removal
    if (doc['device_counts'] is Map) {
      (doc['device_counts'] as Map).forEach((k, v) {
        if (k.toString().startsWith('__')) return;
        deviceCounts[k.toString()] = v.toString();
      });
    }

    escapeCarriageReturns = doc['escape_carriage_returns'] == true;

    // Prefix -> friendly label for generated device names
    if (doc['device_labels'] is Map) {
      (doc['device_labels'] as Map).forEach((k, v) {
        if (k.toString().startsWith('__')) return;
        deviceLabels[k.toString()] = v.toString();
      });
    }

    // Template reference blocks for number/model matched carry-over
    if (doc['device_templates'] is Map) {
      (doc['device_templates'] as Map).forEach((k, v) {
        if (k.toString().startsWith('__')) return;
        if (v is Map) {
          deviceTemplates[k.toString()] =
              v.map((key, value) => MapEntry(key.toString(), value));
        }
      });
    }

    // Section rename rules
    if (doc['sections'] is List) {
      for (final item in doc['sections'] as List) {
        if (item is Map && item['match'] != null && item['rename_to'] != null) {
          sections.add(SectionRule(
            pattern: item['match'].toString(),
            renameTo: item['rename_to'].toString(),
          ));
        }
      }
    }
    // Property rename map
    if (doc['properties'] is Map) {
      (doc['properties'] as Map).forEach((k, v) {
        if (k.toString().startsWith('__')) return; // comment keys
        properties[k.toString()] = v.toString();
      });
    }
    // Value normalization map (values keep their JSON type)
    if (doc['value_map'] is Map) {
      (doc['value_map'] as Map).forEach((prop, mapping) {
        if (prop.toString().startsWith('__')) return;
        if (mapping is Map) {
          valueMap[prop.toString()] =
              mapping.map((k, v) => MapEntry(k.toString(), v));
        }
      });
    }
    // Cross-section moves
    if (doc['moves'] is List) {
      for (final item in doc['moves'] as List) {
        if (item is Map &&
            item['from_section'] != null &&
            item['key_match'] != null &&
            item['to_section'] != null &&
            item['to_key'] != null) {
          moves.add(MoveRule(
            fromSection: item['from_section'].toString(),
            pattern: item['key_match'].toString(),
            toSection: item['to_section'].toString(),
            toKey: item['to_key'].toString(),
          ));
        }
      }
    }
    // Companion keys (ensure a partner key exists per matching property)
    if (doc['companion_keys'] is List) {
      for (final item in doc['companion_keys'] as List) {
        if (item is Map &&
            item['key_match'] != null &&
            item['ensure_key'] != null) {
          companions.add(CompanionRule(
            pattern: item['key_match'].toString(),
            ensureKey: item['ensure_key'].toString(),
            value: item['value'], // absent -> null, which is a valid injected value
            sectionPattern: item['section']?.toString(),
          ));
        }
      }
    }
    // Missing-key defaults per section family
    if (doc['defaults'] is Map) {
      (doc['defaults'] as Map).forEach((pattern, block) {
        if (block is Map) {
          defaults[pattern.toString()] =
              block.map((k, v) => MapEntry(k.toString(), v));
        }
      });
    }
  }

  /// Loads key_map.json using the same resolution strategy as the UI schema:
  /// explicit path first, otherwise look beside the working directory and the
  /// executable. Any failure logs the error and returns the (empty) built-in
  /// map so a broken file can never block loading configs.
  static Future<ConfigKeyMap> load({String explicitPath = ''}) async {
    final map = ConfigKeyMap.builtIn();

    final List<String> candidates = [];
    if (explicitPath.isNotEmpty) {
      candidates.add(explicitPath);
    } else {
      candidates.add(path.join(Directory.current.path, 'key_map.json'));
      candidates.add(path.join(
          File(Platform.resolvedExecutable).parent.path, 'key_map.json'));
    }

    for (final candidate in candidates) {
      try {
        final file = File(candidate);
        if (!await file.exists()) continue;

        final doc = jsonDecode(await file.readAsString());
        if (doc is! Map<String, dynamic>) {
          throw const FormatException('Root of key_map.json must be an object.');
        }
        map._applyJsonMap(doc);
        map.source = candidate;
        AppLogger.logInfo(
            'Key map loaded from $candidate (${map.ruleCount} rules).');
        return map;
      } catch (e, stack) {
        AppLogger.logError(
            'Failed to load key_map.json from $candidate — legacy key mapping disabled.',
            e,
            stack);
        map.source = 'Built-in (failed to load $candidate: $e)';
        return map;
      }
    }

    if (explicitPath.isNotEmpty) {
      map.source = 'Built-in (file not found: $explicitPath)';
    }
    return map;
  }

  /// Simple '*' wildcard match for defaults patterns like "CAMERADEVICE_*".
  bool _wildcardMatch(String pattern, String value) {
    final regex =
        RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$');
    return regex.hasMatch(value);
  }

  /// Applies all mapping rules to [original] WITHOUT mutating it.
  /// [canonicalKeys] is the list of CURRENT known property names (from the
  /// UI schema + built-in dictionary) used by auto-case-normalization.
  /// Returns the translated config plus a human-readable change list that the
  /// caller feeds into systemLogs / the migration audit file.
  KeyMapResult apply(Map<String, dynamic> original,
      {List<String> canonicalKeys = const []}) {
    final List<String> changes = [];
    // Deep copy so a failed load can never leave a half-mapped config behind
    final Map<String, dynamic> config =
        jsonDecode(jsonEncode(original)) as Map<String, dynamic>;

    // --- 1. Rename top-level sections (preserve original ordering) ---------
    // Track the NEW names of renamed sections: only these legacy-origin
    // blocks are eligible for unused-device removal in step 4.
    final Set<String> legacyRenamedSections = {};
    final Map<String, dynamic> renamed = {};
    config.forEach((sectionName, block) {
      String newName = sectionName;
      for (final rule in sections) {
        final candidate = rule.apply(sectionName);
        if (candidate != null && candidate != sectionName) {
          if (config.containsKey(candidate) || renamed.containsKey(candidate)) {
            changes.add(
                "KEYMAP SKIPPED: section '$sectionName' maps to '$candidate' which already exists.");
          } else {
            newName = candidate;
            legacyRenamedSections.add(newName);
            changes.add("KEYMAP: renamed section '$sectionName' -> '$newName'");
          }
          break; // first matching rule wins
        }
      }
      renamed[newName] = block;
    });
    config
      ..clear()
      ..addAll(renamed);

    // Pre-compute the normalization lookup once (lowercase, no underscores)
    String norm(String s) => s.toLowerCase().replaceAll('_', '');
    final Set<String> canonicalSet = canonicalKeys.toSet();
    final Map<String, String> canonicalByNorm = {};
    if (autoCaseNormalization) {
      for (final k in canonicalKeys) {
        canonicalByNorm.putIfAbsent(norm(k), () => k);
      }
    }

    // --- 2. Rename properties (explicit map, then auto-normalization) ------
    config.forEach((sectionName, block) {
      if (block is! Map) return;
      final Map<String, dynamic> section = block as Map<String, dynamic>;

      // 2a. Explicit renames. Collect first: mutating while iterating throws.
      final List<MapEntry<String, String>> renames = [];
      for (final prop in section.keys) {
        final target = properties[prop];
        if (target != null && target != prop) {
          if (section.containsKey(target)) {
            changes.add(
                "KEYMAP SKIPPED: '$sectionName.$prop' maps to '$target' which already exists in that section.");
          } else {
            renames.add(MapEntry(prop, target));
          }
        }
      }
      for (final r in renames) {
        section[r.value] = section.remove(r.key);
        changes.add("KEYMAP: renamed '$sectionName.${r.key}' -> '${r.value}'");
      }

      // 2b. Auto-normalization: catch legacy case/underscore variants of any
      // known current key without needing an explicit entry for each one
      // (e.g. 'Active_Notifications' -> 'active_notifications').
      if (autoCaseNormalization && canonicalByNorm.isNotEmpty) {
        final List<MapEntry<String, String>> autoRenames = [];
        for (final prop in section.keys) {
          if (canonicalSet.contains(prop)) continue; // already canonical
          final target = canonicalByNorm[norm(prop)];
          if (target != null && target != prop && !section.containsKey(target)) {
            autoRenames.add(MapEntry(prop, target));
          }
        }
        for (final r in autoRenames) {
          section[r.value] = section.remove(r.key);
          changes.add(
              "KEYMAP: auto-normalized '$sectionName.${r.key}' -> '${r.value}'");
        }
      }

      // 2c. Value normalization (runs on the NEW property names). The mapped
      // value keeps its JSON type, so "True" -> true and "Yes" -> "1" work.
      valueMap.forEach((prop, mapping) {
        if (section.containsKey(prop)) {
          final current = section[prop]?.toString();
          if (current != null && mapping.containsKey(current)) {
            section[prop] = mapping[current];
            changes.add(
                "KEYMAP: normalized '$sectionName.$prop' value '$current' -> '${mapping[current]}'");
          }
        }
      });
    });

    // --- 3. Cross-section moves (e.g. SYSTEM GVE IDs -> device blocks) -----
    for (final rule in moves) {
      final src = config[rule.fromSection];
      if (src is! Map) continue;
      final Map<String, dynamic> srcSection = src as Map<String, dynamic>;

      for (final key in srcSection.keys.toList()) {
        final m = rule.keyMatch.firstMatch(key);
        if (m == null) continue;

        final targetSectionName = _substituteGroups(rule.toSection, m);
        final target = config[targetSectionName];
        if (target is! Map) {
          changes.add(
              "KEYMAP SKIPPED: cannot move '${rule.fromSection}.$key' — target section '$targetSectionName' not found.");
          continue;
        }
        final Map<String, dynamic> targetSection = target as Map<String, dynamic>;
        if (targetSection.containsKey(rule.toKey)) {
          changes.add(
              "KEYMAP SKIPPED: cannot move '${rule.fromSection}.$key' — '$targetSectionName.${rule.toKey}' already exists.");
          continue;
        }
        targetSection[rule.toKey] = srcSection.remove(key);
        changes.add(
            "KEYMAP: moved '${rule.fromSection}.$key' -> '$targetSectionName.${rule.toKey}'");
      }
    }

    // --- 4. Remove LEGACY device blocks that are not in use ----------------
    // A legacy room declares its hardware via the dev_ counts, so blocks
    // above the count (or families set to No/0) are dead data and should be
    // dropped rather than converted. Runs AFTER value_map (so 'Yes'/'No'
    // counts are already normalized) and AFTER moves (so a GVE ID moved into
    // an unused block is removed along with it). Only sections renamed from
    // legacy names in step 1 are eligible — new-style files keep every block.
    if (removeUnusedDevices && deviceCounts.isNotEmpty) {
      final setup = config['SYSTEM_SETUP'];
      if (setup is Map) {
        deviceCounts.forEach((countKey, prefix) {
          final raw = setup[countKey]?.toString().toLowerCase() ?? '';
          // Parse counts the same way pruning does; unknown -> never remove
          int count;
          if (raw == 'yes') {
            count = 1;
          } else if (raw == 'no') {
            count = 0;
          } else {
            count = int.tryParse(raw) ?? -1;
          }
          if (count < 0) return; // count missing/unparseable: leave blocks alone

          for (final key in config.keys.toList()) {
            if (!key.startsWith(prefix)) continue;
            if (!legacyRenamedSections.contains(key)) continue;
            final n = int.tryParse(key.substring(prefix.length)) ?? 0;
            if (n > count) {
              config.remove(key);
              changes.add(
                  "KEYMAP: removed unused legacy device block '$key' ($countKey is '${setup[countKey]}').");
            }
          }
        });
      }
    }

    // --- 5. Escape carriage returns in string values ------------------------
    // Legacy files contain REAL \r\n / \r control characters inside GUI names
    // (e.g. "Intake<CR><LF>Fans"); the new style stores the two-character
    // sequence backslash+r in memory. On save, the JSON encoder escapes the
    // backslash so the config.json ON DISK contains \\r — "TLP\\rPoE" — the
    // form the processor code reads. CRLF collapses to one marker; lone \n is
    // left untouched.
    if (escapeCarriageReturns) {
      config.forEach((sectionName, block) {
        if (block is! Map) return;
        final Map<String, dynamic> section = block as Map<String, dynamic>;
        for (final key in section.keys.toList()) {
          final v = section[key];
          if (v is String && v.contains('\r')) {
            final cleaned = v.replaceAll('\r\n', r'\r').replaceAll('\r', r'\r');
            section[key] = cleaned;
            // Show the value as it will appear in the SAVED file (\\r), so the
            // audit log matches what you see when you open config.json.
            changes.add(
                "KEYMAP: escaped carriage return(s) in '$sectionName.$key' -> "
                "'${cleaned.replaceAll(r'\', r'\\')}' (as saved on disk)");
          }
        }
      });
    }

    // --- 6. Smart device defaults (name / btn / lbl / model matching) ------
    // (a) Generates 'name' as '<Label> - <model>', numbered ONLY when the
    //     family has multiple units after removal: 'Camera 2 - Cam570' vs
    //     'Camera - Cam570'.
    // (b) btn_name / lbl_name carry over from the SAME-NUMBER template block.
    // (c) When the legacy model matches a template block's model in the same
    //     family, module and keep_alive_trigger carry over from it.
    // All of these only fill keys that are missing — never overwrite.
    if (deviceLabels.isNotEmpty || deviceTemplates.isNotEmpty) {
      config.forEach((sectionName, block) {
        if (block is! Map) return;
        final Map<String, dynamic> section = block as Map<String, dynamic>;

        // Resolve the device family prefix ('CAMERADEVICE_') and number ('2')
        String? matchedPrefix;
        for (final p in deviceLabels.keys) {
          if (sectionName.startsWith(p) &&
              int.tryParse(sectionName.substring(p.length)) != null) {
            matchedPrefix = p;
            break;
          }
        }
        if (matchedPrefix == null) return;
        final String pfx = matchedPrefix;
        final String n = sectionName.substring(pfx.length);

        // (a) Friendly generated name
        if (!section.containsKey('name')) {
          final String label = deviceLabels[pfx]!;
          final int familyCount = config.keys
              .where((k) =>
                  k.startsWith(pfx) &&
                  int.tryParse(k.substring(pfx.length)) != null)
              .length;
          final String model = section['model']?.toString().trim() ?? '';
          String name = label;
          if (familyCount > 1) name += ' $n';
          if (model.isNotEmpty) name += ' - $model';
          section['name'] = name;
          changes.add("KEYMAP: generated '$sectionName.name' = '$name'");
        }

        // (b) btn_name / lbl_name from the template block with the SAME number
        final Map<String, dynamic>? exactTmpl = deviceTemplates['$pfx$n'];
        if (exactTmpl != null) {
          for (final key in const ['btn_name', 'lbl_name']) {
            if (!section.containsKey(key) && exactTmpl.containsKey(key)) {
              section[key] = exactTmpl[key];
              changes.add(
                  "KEYMAP: set '$sectionName.$key' = '${exactTmpl[key]}' (from template $pfx$n)");
            }
          }
        }

        // (c) module + keep_alive_trigger from a MODEL-matched template block
        final String model =
            section['model']?.toString().trim().toLowerCase() ?? '';
        if (model.isNotEmpty) {
          Map<String, dynamic>? modelTmpl;
          String modelTmplName = '';
          for (final entry in deviceTemplates.entries) {
            if (!entry.key.startsWith(pfx)) continue;
            final tModel =
                entry.value['model']?.toString().trim().toLowerCase() ?? '';
            if (tModel.isNotEmpty && tModel == model) {
              modelTmpl = entry.value;
              modelTmplName = entry.key;
              break;
            }
          }
          if (modelTmpl != null) {
            for (final key in const ['module', 'keep_alive_trigger']) {
              if (!section.containsKey(key) && modelTmpl.containsKey(key)) {
                section[key] = modelTmpl[key];
                changes.add(
                    "KEYMAP: set '$sectionName.$key' = '${modelTmpl[key]}' (model '${section['model']}' matched template $modelTmplName)");
              }
            }
          }
        }
      });
    }

    // --- 7. Companion keys ---------------------------------------------------
    // For every property matching a companion rule, guarantee its partner key
    // exists in the same section. The partner name is built from the matched
    // capture groups, so "power1_outlet_(\d+)" -> "power1_outlet_$1_action"
    // creates power1_outlet_4_action ONLY when power1_outlet_4 exists — the
    // number always matches the outlet that is actually present. Existing
    // values are never overwritten.
    if (companions.isNotEmpty) {
      config.forEach((sectionName, block) {
        if (block is! Map) return;
        final Map<String, dynamic> section = block as Map<String, dynamic>;
        for (final rule in companions) {
          if (rule.sectionPattern != null &&
              !_wildcardMatch(rule.sectionPattern!, sectionName)) {
            continue;
          }
          for (final key in section.keys.toList()) {
            final m = rule.keyMatch.firstMatch(key);
            if (m == null) continue;
            final targetKey = _substituteGroups(rule.ensureKey, m);
            if (targetKey == key || section.containsKey(targetKey)) continue;
            section[targetKey] = rule.value;
            changes.add(
                "KEYMAP: added companion '$sectionName.$targetKey' = ${jsonEncode(rule.value)} (for '$key')");
          }
        }
      });
    }

    // --- 8. Inject defaults for keys still missing after mapping -----------
    config.forEach((sectionName, block) {
      if (block is! Map) return;
      final Map<String, dynamic> section = block as Map<String, dynamic>;

      // Device number = trailing digits of the section name ("...DEVICE_3" -> "3")
      final numMatch = RegExp(r'(\d+)$').firstMatch(sectionName);
      final String n = numMatch?.group(1) ?? '1';

      defaults.forEach((pattern, defaultBlock) {
        if (!_wildcardMatch(pattern, sectionName)) return;
        defaultBlock.forEach((key, value) {
          if (key.startsWith('__')) return; // comment keys
          if (section.containsKey(key)) return; // never overwrite real data
          dynamic resolved = value;
          if (resolved is String) resolved = resolved.replaceAll('{n}', n);
          section[key] = resolved;
          changes.add(
              "KEYMAP: added missing '$sectionName.$key' (default: '$resolved')");
        });
      });
    });

    return KeyMapResult(config, changes);
  }
}
