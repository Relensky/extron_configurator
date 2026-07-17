import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'config_maintenance.dart';
import 'schema_field_builder.dart';

/// SCHEMA-DRIVEN: every field on this tab is now rendered from the loaded
/// UiSchema (ui_schema.json). Add a new key to config.json + an entry in
/// ui_schema.json and it appears here with the right widget, label,
/// description, and dropdown options — no rebuild required.
class SystemSettingsView extends StatelessWidget {
  const SystemSettingsView({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final systemSetup = provider.roomConfig['SYSTEM_SETUP'] as Map<String, dynamic>?;

    if (systemSetup == null || systemSetup.isEmpty) {
      return const Center(child: Text("No SYSTEM_SETUP found in the current config."));
    }

    // Used in widget keys so every row (and the title) is rebuilt fresh when
    // the theme flips; otherwise Flutter reuses keyless element slots and the
    // header/fields can render with stale styling after a light<->dark toggle.
    final theme = Theme.of(context);
    final brightness = theme.brightness;

    // dev_ hardware counts stay owned by the Setup Wizard tab
    final List<String> configKeys =
        systemSetup.keys.where((k) => !k.startsWith('dev_')).toList();
    configKeys.sort();

    return ListView.builder(
      padding: const EdgeInsets.all(32.0),
      itemCount: configKeys.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            key: ValueKey('sys_settings_title_$brightness'),
            padding: const EdgeInsets.only(bottom: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'System Settings',
                  // Explicitly derive the color from the ACTIVE theme so the
                  // header stays readable in both light and dark mode.
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                // Diff SYSTEM_SETUP against the template + schema defaults
                // and offer to add anything missing (e.g. a deleted input_).
                OutlinedButton.icon(
                  icon: const Icon(Icons.playlist_add_check),
                  label: const Text('Check Defaults'),
                  onPressed: () => showCheckDefaultsDialog(
                      context, provider, 'SYSTEM_SETUP'),
                ),
              ],
            ),
          );
        }

        final key = configKeys[index - 1];
        final value = systemSetup[key];

        // One call handles text/int/double/bool/dropdown/combo/hidden based
        // on the schema entry (or type inference when the key has no entry).
        final Widget? field = SchemaFieldBuilder.buildField(
          context: context,
          provider: provider,
          sectionKey: 'SYSTEM_SETUP',
          fieldKey: key,
          value: value,
          // Every system setting can be removed (confirmed); Check Defaults
          // above adds it back later if needed.
          onDelete: () => confirmRemoveConfigKey(
              context, provider, 'SYSTEM_SETUP', key),
        );

        // Schema marked this key "hidden" (e.g. gui_tab_type, written by the
        // gui_inputs combo dropdown)
        if (field == null) return const SizedBox.shrink();

        return Padding(
          // Keyed on the config key AND brightness: guarantees a clean rebuild
          // of every row when the theme toggles, and prevents index-based slot
          // reuse from ever displaying a neighboring field's stale state.
          key: ValueKey('${key}_$brightness'),
          padding: const EdgeInsets.only(bottom: 16.0),
          child: field,
        );
      },
    );
  }
}
