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
///     "CAMERA1DEVICE"  ->  "CAMERADEVICE_1"
///     "COMTYPE"        ->  "com_type"
///     "IPADDRESS"      ->  "ip_address"
///
///  It runs automatically whenever a config is loaded (local file or SFTP
///  download), BEFORE the normal template migration, and every rename /
///  injected default is written to the migration log + audit dialog like any
///  other migration. Because the rules live in a JSON file, new legacy
///  variants can be supported by editing key_map.json — no rebuild required.
///
///  key_map.json structure:
///    "sections":   list of { "match": <regex>, "rename_to": <name> } rules
///                  applied to TOP-LEVEL section names. The regex must match
///                  the whole name; $1..$9 in rename_to insert capture groups
///                  (e.g. "CAMERA(\\d+)DEVICE" -> "CAMERADEVICE_$1").
///    "properties": flat { "OLDNAME": "new_name" } map applied to every
///                  property inside every section.
///    "value_map":  optional { "property": { "OldValue": "NewValue" } } to
///                  normalize stored values after renaming.
///    "defaults":   { "SECTIONPATTERN_*": { "key": <value> } } — after
///                  mapping, any listed key still MISSING from a matching
///                  section is injected with the given value. "{n}" inside a
///                  string value is replaced by the section's device number
///                  (the digits at the end of the section name).
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
    String out = renameTo;
    for (int i = 1; i <= m.groupCount && i <= 9; i++) {
      out = out.replaceAll('\$$i', m.group(i) ?? '');
    }
    return out;
  }
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
  final Map<String, Map<String, String>> valueMap = {};
  final Map<String, Map<String, dynamic>> defaults = {};

  /// Where this map came from, for display in App Config.
  String source = 'Built-in (no mapping rules)';

  int get ruleCount =>
      sections.length + properties.length + valueMap.length + defaults.length;

  /// The built-in map is intentionally EMPTY: legacy naming is site-specific,
  /// so all rules come from key_map.json. With no file present, loading a
  /// config behaves exactly as before.
  static ConfigKeyMap builtIn() => ConfigKeyMap();

  void _applyJsonMap(Map<String, dynamic> doc) {
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
    // Value normalization map
    if (doc['value_map'] is Map) {
      (doc['value_map'] as Map).forEach((prop, mapping) {
        if (mapping is Map) {
          valueMap[prop.toString()] = mapping
              .map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      });
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
  /// Returns the translated config plus a human-readable change list that the
  /// caller feeds into systemLogs / the migration audit file.
  KeyMapResult apply(Map<String, dynamic> original) {
    final List<String> changes = [];
    // Deep copy so a failed load can never leave a half-mapped config behind
    final Map<String, dynamic> config =
        jsonDecode(jsonEncode(original)) as Map<String, dynamic>;

    // --- 1. Rename top-level sections (preserve original ordering) ---------
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

    // --- 2. Rename properties + normalize values inside every section ------
    config.forEach((sectionName, block) {
      if (block is! Map) return;
      final Map<String, dynamic> section = block as Map<String, dynamic>;

      // Collect renames first: mutating a map while iterating throws in Dart
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

      // Value normalization (runs on the NEW property names)
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

    // --- 3. Inject defaults for keys still missing after mapping -----------
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
