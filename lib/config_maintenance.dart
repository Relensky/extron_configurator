import 'package:flutter/material.dart';

import 'app_state.dart';

/// ============================================================================
///  CONFIG MAINTENANCE DIALOGS
/// ============================================================================
///  Shared by the Devices and System tabs:
///    * confirmRemoveConfigKey — the confirmation behind every field's trash
///      button; removal is in-memory until the config is exported.
///    * showCheckDefaultsDialog — diffs the current block against its
///      defaults (template config + ui_schema defaults) and lets the user
///      add missing keys back one at a time or all at once.
/// ============================================================================

/// Asks, then removes [fieldKey] from [sectionKey]. Returns true if removed.
Future<bool> confirmRemoveConfigKey(BuildContext context,
    AppStateProvider provider, String sectionKey, String fieldKey) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove "$fieldKey"?'),
      content: Text(
          'This removes "$fieldKey" from $sectionKey in the working config '
          '(saved on the next export/upload).\n\n'
          'Use "Check Defaults" on this tab to add it back later.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Remove'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade700,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    provider.removeConfigKey(sectionKey, fieldKey);
    return true;
  }
  return false;
}

/// The "Check Defaults" button target: shows every key the section is
/// missing compared to the template config / schema defaults, each with its
/// default value and a + button, plus "Add All".
Future<void> showCheckDefaultsDialog(BuildContext context,
    AppStateProvider provider, String sectionKey) async {
  final Map<String, dynamic> missing =
      await provider.missingDefaultsFor(sectionKey);
  if (!context.mounted) return;

  if (missing.isEmpty) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: const [
          Icon(Icons.check_circle, color: Colors.green),
          SizedBox(width: 10),
          Text('Nothing Missing'),
        ]),
        content: Text(
            '$sectionKey has every property found in the template config and '
            'the schema defaults.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close')),
        ],
      ),
    );
    return;
  }

  // Sorted for a stable list; entries disappear as they are added.
  final List<MapEntry<String, dynamic>> entries = missing.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        void addOne(MapEntry<String, dynamic> e) {
          provider.addConfigKey(sectionKey, e.key, e.value);
          setDialogState(() => entries.remove(e));
          if (entries.isEmpty) Navigator.of(ctx).pop();
        }

        return AlertDialog(
          title: Row(children: [
            const Icon(Icons.playlist_add_check, color: Colors.orange),
            const SizedBox(width: 10),
            Expanded(child: Text('Missing Defaults — $sectionKey')),
          ]),
          content: SizedBox(
            width: 560,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entries.length == 1
                      ? '1 property exists in the defaults (template config / '
                          'ui_schema.json) but not in this section. Add it '
                          'below; the value can be edited normally afterwards.'
                      : '${entries.length} properties exist in the defaults '
                          '(template config / ui_schema.json) but not in this '
                          'section. Add them individually or all at once; '
                          'values can be edited normally afterwards.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (ctx, i) {
                      final e = entries[i];
                      final String valueText = e.value == null
                          ? 'null'
                          : (e.value.toString().isEmpty
                              ? '""'
                              : e.value.toString());
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(e.key,
                            style:
                                const TextStyle(fontFamily: 'monospace')),
                        subtitle: Text('default: $valueText',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: OutlinedButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add'),
                          onPressed: () => addOne(e),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.playlist_add, size: 18),
              label: Text('Add All (${entries.length})'),
              onPressed: () {
                for (final e in List.of(entries)) {
                  provider.addConfigKey(sectionKey, e.key, e.value);
                }
                Navigator.of(ctx).pop();
              },
            ),
          ],
        );
      },
    ),
  );
}
