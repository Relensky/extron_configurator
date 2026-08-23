import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/config_dictionary.dart';

/// ConfigDictionary is the compiled-in FALLBACK for the (i) info buttons —
/// it only answers for a key ui_schema.json has nothing to say about. Because
/// the two hold the same text for most keys, they drift silently: the schema
/// gets corrected, the dictionary keeps the old wording, and a run without
/// ui_schema.json quietly shows the stale description.
///
/// So: every dictionary entry the schema also describes must match it word for
/// word. Fixing a failure is a copy from ui_schema.json into
/// lib/config_dictionary.dart — or deleting the entry there and letting the
/// schema answer alone.
void main() {
  test('every duplicated description matches ui_schema.json', () async {
    final provider = AppStateProvider(autoLoadSettings: false);
    await provider.loadUiSchema();
    final schema = provider.uiSchema;

    final List<String> drifted = [];
    int compared = 0;

    ConfigDictionary.descriptions.forEach((key, text) {
      // Exact entries and '*' patterns both count: power1_outlet_3 is
      // described by the schema's power1_outlet_* entry.
      final schemaText = schema.specFor(key)?.description;
      // Keys the schema doesn't cover are what this map is FOR (the retired
      // api_proxy_server) — nothing to compare them against.
      if (schemaText == null) return;
      compared++;
      if (schemaText != text) drifted.add(key);
    });

    expect(compared, greaterThan(50),
        reason: 'the schema should be describing most of these keys - a tiny '
            'number here means ui_schema.json failed to load');
    expect(drifted, isEmpty,
        reason: 'these descriptions no longer match ui_schema.json: $drifted');
  });
}
