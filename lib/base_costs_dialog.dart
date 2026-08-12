import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_port_editor.dart' show avRowIcon;
import 'base_costs.dart';
import 'cost_estimate.dart' show trimNumber;
import 'live_text_field.dart';

/// ============================================================================
///  BASE COST EDITOR
/// ============================================================================
///  One typical price per device category — what a switcher costs before
///  anybody has decided which switcher. Same shape as the labor rate card, and
///  for the same reason: a typical price is a fact about the year and the
///  supplier, so it belongs in one file every room reads rather than being
///  retyped per estimate.
///
///  These figures are the LAST rung the estimate falls back to. A price typed
///  on the room wins, then the catalog's price for the chosen model, then this.
///  Lines that land here are counted and the total is labeled a budget.
/// ============================================================================

Future<void> showBaseCostsDialog(
  BuildContext context,
  AppStateProvider provider,
) => showDialog<void>(
  context: context,
  builder: (ctx) => const _BaseCostsDialog(),
);

class _BaseCostsDialog extends StatefulWidget {
  const _BaseCostsDialog();

  @override
  State<_BaseCostsDialog> createState() => _BaseCostsDialogState();
}

class _BaseCostsDialogState extends State<_BaseCostsDialog> {
  bool _dirty = false;

  /// Name of a category being added. Held here rather than upserting an empty
  /// row straight away, because a blank category matches nothing and would sit
  /// in the file looking like a mistake.
  final TextEditingController _newCategory = TextEditingController();

  @override
  void dispose() {
    _newCategory.dispose();
    super.dispose();
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final book = provider.baseCosts;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          const Text('Base costs'),
          const SizedBox(width: 12),
          if (_dirty)
            Chip(
              label: const Text('Unsaved'),
              backgroundColor: theme.colorScheme.errorContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        // Wide enough for both tiers plus a readable note column; the single
        // price card fitted in 760 and two do not.
        width: 900,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'One typical unit price per category at each published tier, '
              'used when a device on the diagram has no model chosen or the '
              'catalog does not price the one it has. A price typed on the '
              'room, or a catalog price for the actual model, always wins. '
              'A tier left blank falls back to the other one and the estimate '
              'says so; both blank means "not set", and the line is reported '
              'as unpriced rather than costed at nothing.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 230,
                  child: Text('Category', style: theme.textTheme.labelSmall),
                ),
                SizedBox(
                  width: 148,
                  child: Text(
                    'MSRP (list)',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                SizedBox(
                  width: 148,
                  child: Text(
                    'Education price',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: Text(
                    'What this figure assumes',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 34),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final cost in book.costs)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 230,
                            child: Text(
                              cost.category,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 140,
                            child: LiveTextField(
                              fieldId: 'base_${cost.category}',
                              initial: cost.price == 0
                                  ? ''
                                  : trimNumber(cost.price),
                              prefix: provider.avCost.currency,
                              hint: 'not set',
                              numeric: true,
                              onChanged: (v) => _update(
                                provider,
                                cost.copyWith(
                                  price: double.tryParse(v.trim()) ?? 0,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 140,
                            child: LiveTextField(
                              fieldId: 'baseedu_${cost.category}',
                              initial: cost.educationPrice == 0
                                  ? ''
                                  : trimNumber(cost.educationPrice),
                              prefix: provider.avCost.currency,
                              hint: 'not set',
                              numeric: true,
                              onChanged: (v) => _update(
                                provider,
                                cost.copyWith(
                                  educationPrice:
                                      double.tryParse(v.trim()) ?? 0,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LiveTextField(
                              fieldId: 'basenote_${cost.category}',
                              initial: cost.notes,
                              onChanged: (v) => _update(
                                provider,
                                cost.copyWith(notes: v),
                              ),
                            ),
                          ),
                          avRowIcon(
                            Icons.delete_outline,
                            'Remove category',
                            () {
                              provider.baseCosts.remove(cost.category);
                              setState(() => _dirty = true);
                              provider.baseCostsChanged();
                            },
                            danger: true,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  // The category has to match what the catalog files a device
                  // under, so it is typed rather than generated — and matching
                  // ignores case, which is the only spelling difference worth
                  // forgiving.
                  Row(
                    children: [
                      SizedBox(
                        width: 230,
                        child: TextField(
                          controller: _newCategory,
                          decoration: const InputDecoration(
                            labelText: 'New category',
                            hintText: 'e.g. Video wall processor',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add'),
                        onPressed: () {
                          final name = _newCategory.text.trim();
                          if (name.isEmpty) return;
                          if (provider.baseCosts.byCategory(name) != null) {
                            _snack('$name is already on the list.');
                            return;
                          }
                          provider.baseCosts.upsert(BaseCost(category: name));
                          _newCategory.clear();
                          setState(() => _dirty = true);
                          provider.baseCostsChanged();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    book.source.isEmpty ? 'Not saved yet' : book.source,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${book.setCount} of ${book.costs.length} priced',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('Load...'),
          onPressed: () => _load(provider),
        ),
        TextButton.icon(
          icon: const Icon(Icons.save_as, size: 18),
          label: const Text('Save as...'),
          onPressed: () => _saveAs(provider),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ElevatedButton(
          onPressed: () async {
            final saved = await provider.saveBaseCosts();
            if (saved.isEmpty) {
              _snack('Could not save the base costs.', error: true);
              return;
            }
            setState(() => _dirty = false);
            _snack('Base costs saved to $saved');
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _update(AppStateProvider provider, BaseCost cost) {
    provider.baseCosts.upsert(cost);
    setState(() => _dirty = true);
    provider.baseCostsChanged();
  }

  Future<void> _load(AppStateProvider provider) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Open a base cost card',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    await provider.loadBaseCosts(explicitPath: path);
    if (!mounted) return;
    setState(() => _dirty = false);
    _snack('Loaded ${provider.baseCosts.costs.length} categories from $path');
  }

  Future<void> _saveAs(AppStateProvider provider) async {
    String? output = await FilePicker.saveFile(
      dialogTitle: 'Save the base costs as',
      fileName: 'base_costs.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (output == null) return;
    if (!output.toLowerCase().endsWith('.json')) output += '.json';
    final saved = await provider.baseCosts.save(toPath: output);
    if (!mounted) return;
    if (saved.isEmpty) {
      _snack('Could not write the base costs.', error: true);
      return;
    }
    setState(() => _dirty = false);
    provider.baseCostsChanged();
    showSavedFileSnack(context, provider, 'Base costs', saved);
  }
}
