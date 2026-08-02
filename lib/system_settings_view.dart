import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'config_maintenance.dart';
import 'schema_field_builder.dart';

/// SCHEMA-DRIVEN: every field on this tab is now rendered from the loaded
/// UiSchema (ui_schema.json). Add a new key to config.json + an entry in
/// ui_schema.json and it appears here with the right widget, label,
/// description, and dropdown options — no rebuild required.
///
/// Besides SYSTEM_SETUP, this tab also renders every OTHER top-level block
/// that is not a numbered device (e.g. METRICS_CONFIG) as its own group, each
/// with its own "Check Defaults" button. Their fields are described in
/// ui_schema.json under "section_fields", and the group heading comes from the
/// "fields" entry named after the section itself.
class SystemSettingsView extends StatelessWidget {
  const SystemSettingsView({super.key});

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

    // One flat, lazily-built list: the SYSTEM_SETUP heading and its fields,
    // then a heading + fields for each standalone block (METRICS_CONFIG, ...).
    final List<_SettingsRow> rows = [
      const _SettingsRow.header('SYSTEM_SETUP', 'System Settings'),
      for (final key in configKeys) _SettingsRow.field('SYSTEM_SETUP', key),
    ];

    for (final entry in provider.roomConfig.entries) {
      final value = entry.value;
      if (value is! Map || !provider.uiSchema.isExtraSection(entry.key)) continue;
      final sectionKeys = value.keys.map((k) => k.toString()).toList()..sort();
      // Heading text/description come from a "fields" entry named after the
      // section, so a new block can label itself without a rebuild.
      final spec = provider.uiSchema.specFor(entry.key);
      rows.add(_SettingsRow.header(entry.key, spec?.label ?? entry.key));
      rows.addAll(
          sectionKeys.map((k) => _SettingsRow.field(entry.key, k)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(32.0),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];

        if (row.isHeader) {
          return Padding(
            key: ValueKey('sys_settings_title_${row.sectionKey}_$brightness'),
            padding: EdgeInsets.only(bottom: 20.0, top: index == 0 ? 0 : 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    row.title!,
                    // Explicitly derive the color from the ACTIVE theme so the
                    // header stays readable in both light and dark mode.
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                // Diff this block against the template + schema defaults and
                // offer to add anything missing (e.g. a deleted input_).
                OutlinedButton.icon(
                  icon: const Icon(Icons.playlist_add_check),
                  label: const Text('Check Defaults'),
                  onPressed: () => showCheckDefaultsDialog(
                      context, provider, row.sectionKey),
                ),
              ],
            ),
          );
        }

        final section = provider.roomConfig[row.sectionKey];
        final value = section is Map ? section[row.fieldKey] : null;

        // One call handles text/int/double/bool/dropdown/combo/hidden based
        // on the schema entry (or type inference when the key has no entry).
        final Widget? field = SchemaFieldBuilder.buildField(
          context: context,
          provider: provider,
          sectionKey: row.sectionKey,
          fieldKey: row.fieldKey!,
          value: value,
          // Every system setting can be removed (confirmed); Check Defaults
          // above adds it back later if needed.
          onDelete: () => confirmRemoveConfigKey(
              context, provider, row.sectionKey, row.fieldKey!),
        );

        // Schema marked this key "hidden" (e.g. gui_tab_type, written by the
        // gui_inputs combo dropdown)
        if (field == null) return const SizedBox.shrink();

        return Padding(
          // Keyed on the section + config key AND brightness: guarantees a
          // clean rebuild of every row when the theme toggles, and prevents
          // index-based slot reuse from ever displaying a neighboring field's
          // stale state.
          key: ValueKey('${row.sectionKey}.${row.fieldKey}_$brightness'),
          padding: const EdgeInsets.only(bottom: 16.0),
          child: field,
        );
      },
    );
  }
}

/// One line of the tab: either a group heading (with its Check Defaults
/// button) or a single config property to render.
class _SettingsRow {
  final String sectionKey;
  final String? fieldKey; // null for a heading
  final String? title;    // heading text

  const _SettingsRow.header(this.sectionKey, this.title) : fieldKey = null;
  const _SettingsRow.field(this.sectionKey, this.fieldKey) : title = null;

  bool get isHeader => fieldKey == null;
}
