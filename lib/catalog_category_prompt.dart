import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';

/// Before a catalog save: asks for a category on every entry added or
/// changed since the catalog was read that has none. Returns false when the
/// save should not go ahead.
Future<bool> confirmCatalogCategories(
  BuildContext context,
  AppStateProvider provider,
) async {
  final library = provider.avDeviceLibrary;
  final missing = [
    for (final t in library.editedSinceRead())
      if (t.category.trim().isEmpty) t,
  ]..sort((a, b) => a.model.toLowerCase().compareTo(b.model.toLowerCase()));
  if (missing.isEmpty) return true;

  final picked = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _MissingCategoryDialog(
      entries: missing,
      untracked: [
        ...kUntrackedEquipmentCategories,
        ...library.addedCategories,
      ],
    ),
  );
  if (picked == null) return false;
  for (final t in missing) {
    final c = picked[t.model] ?? '';
    if (c.isEmpty) continue;
    library.upsert(t.copyWith(
      category: c,
      // A cable is priced against runs of its signal type, as the editor's
      // own picker sets it.
      cableSignal: c == kCategoryCable ? (t.cableSignal ?? SignalType.hdmi) : null,
      clearCableSignal: c != kCategoryCable,
    ));
  }
  return true;
}

class _MissingCategoryDialog extends StatefulWidget {
  final List<AvDeviceTemplate> entries;

  /// Equipment kinds no config section maps onto, added ones included.
  final List<String> untracked;
  const _MissingCategoryDialog({required this.entries, this.untracked = const []});

  @override
  State<_MissingCategoryDialog> createState() => _MissingCategoryDialogState();
}

class _MissingCategoryDialogState extends State<_MissingCategoryDialog> {
  final Map<String, String> _picked = {};

  List<DropdownMenuItem<String>> _items(ThemeData theme) {
    DropdownMenuItem<String> heading(String text) => DropdownMenuItem<String>(
      enabled: false,
      value: '#$text',
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    DropdownMenuItem<String> item(String c) =>
        DropdownMenuItem<String>(value: c, child: Text(c));
    return [
      const DropdownMenuItem<String>(value: '', child: Text('(none)')),
      heading('Equipment, budgeted at its base cost'),
      for (final c in kTrackedCategories) item(c),
      if (widget.untracked.isNotEmpty) ...[
        heading('Equipment, not tied to a config section'),
        for (final c in widget.untracked) item(c),
      ],
      heading('Rack parts'),
      for (final c in kRackItemCategories) item(c),
      heading('Billed, not drawn'),
      for (final c in const [kCategoryConsumable, kCategoryCable, kCategoryMisc])
        item(c),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.entries.length;
    final anyPicked = _picked.values.any((c) => c.isNotEmpty);
    return AlertDialog(
      title: Text(n == 1
          ? '${widget.entries.single.model} has no category'
          : '$n catalog entries have no category'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The category decides where an entry is offered and how it is '
              'priced. ${categoryLimits('')}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: n,
                separatorBuilder: (_, _) => const Divider(height: 16),
                itemBuilder: (ctx, i) {
                  final t = widget.entries[i];
                  final c = _picked[t.model] ?? '';
                  return Column(
                    key: ValueKey('missing_category_${t.model}'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              [
                                t.model,
                                if (t.manufacturer.isNotEmpty) t.manufacturer,
                                if (t.partNumber.isNotEmpty) t.partNumber,
                              ].join(' · '),
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          SizedBox(
                            width: 230,
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('missing_category_pick_${t.model}'),
                              initialValue: c,
                              isExpanded: true,
                              isDense: true,
                              decoration: const InputDecoration(
                                labelText: 'Category',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: _items(theme),
                              onChanged: (v) =>
                                  setState(() => _picked[t.model] = v ?? ''),
                            ),
                          ),
                        ],
                      ),
                      if (c.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          categoryLimits(c, hasPorts: t.ports.isNotEmpty),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('missing_category_skip'),
          onPressed: () => Navigator.pop(context, const <String, String>{}),
          child: const Text('Save without'),
        ),
        FilledButton(
          key: const ValueKey('missing_category_save'),
          onPressed: anyPicked ? () => Navigator.pop(context, _picked) : null,
          child: const Text('Save with categories'),
        ),
      ],
    );
  }
}
