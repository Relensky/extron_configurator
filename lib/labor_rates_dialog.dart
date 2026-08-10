import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_port_editor.dart' show avRowIcon;
import 'cost_estimate.dart' show trimNumber;
import 'labor_rates.dart';
import 'live_text_field.dart';

/// ============================================================================
///  RATE CARD EDITOR
/// ============================================================================
///  The hourly rates every estimate costs its labor from — CTS III, CTS IV,
///  TSRV, FMS and whatever else this shop bills. Kept in one file so revising
///  a rate re-costs every room that uses it, instead of leaving last year's
///  number in a dozen sidecars.
///
///  Load and Save As exist because rate cards are per contract as often as
///  they are per year: a job under a different agreement gets its own file.
/// ============================================================================

Future<void> showLaborRatesDialog(
  BuildContext context,
  AppStateProvider provider,
) => showDialog<void>(
  context: context,
  builder: (ctx) => const _LaborRatesDialog(),
);

class _LaborRatesDialog extends StatefulWidget {
  const _LaborRatesDialog();

  @override
  State<_LaborRatesDialog> createState() => _LaborRatesDialogState();
}

class _LaborRatesDialogState extends State<_LaborRatesDialog> {
  bool _dirty = false;

  /// A card off a published schedule runs to a couple of hundred rows, and
  /// scrolling one to check a single rate is how a rate card stops being
  /// checked. Matches names, notes and the role's shorthand — see
  /// [LaborRate.matches].
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
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
    final book = provider.laborRates;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          const Text('Labor rates'),
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
        width: 760,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'One rate per job type. A room stores its own techs and hours '
              'and references the job type, so changing a rate here re-costs '
              'every estimate that uses it. A rate of 0 is reported as "not '
              'set" rather than costing the work at nothing.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              decoration: InputDecoration(
                labelText: 'Search',
                hintText: 'name, class number, or shorthand — "tss", '
                    '"tssIII", "electrician"',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: 'Show every job type',
                        onPressed: () => setState(_search.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 62,
                  child: Text('Short', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 200,
                  child: Text('Job type', style: theme.textTheme.labelSmall),
                ),
                SizedBox(
                  width: 130,
                  child: Text(
                    'Rate (per hour)',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Text('Taxable', style: theme.textTheme.labelSmall),
                ),
                Expanded(
                  child: Text('Notes', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 34),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final rate in book.rates)
                    if (rate.matches(_search.text))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          // Derived from the name, so it follows a rename
                          // rather than going stale beside it.
                          SizedBox(
                            width: 62,
                            child: Text(
                              rate.initialism,
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 200,
                            child: LiveTextField(
                              fieldId: 'name_${rate.id}',
                              initial: rate.name,
                              onChanged: (v) => _update(
                                provider,
                                rate.copyWith(name: v),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 130,
                            child: LiveTextField(
                              fieldId: 'rate_${rate.id}',
                              initial: rate.hourlyRate == 0
                                  ? ''
                                  : trimNumber(rate.hourlyRate),
                              prefix: provider.avCost.currency,
                              hint: 'not set',
                              numeric: true,
                              onChanged: (v) => _update(
                                provider,
                                rate.copyWith(
                                  hourlyRate: double.tryParse(v.trim()) ?? 0,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 90,
                            child: Checkbox(
                              value: rate.taxable,
                              onChanged: (v) => _update(
                                provider,
                                rate.copyWith(taxable: v ?? false),
                              ),
                            ),
                          ),
                          Expanded(
                            child: LiveTextField(
                              fieldId: 'notes_${rate.id}',
                              initial: rate.notes,
                              onChanged: (v) => _update(
                                provider,
                                rate.copyWith(notes: v),
                              ),
                            ),
                          ),
                          avRowIcon(
                            Icons.delete_outline,
                            'Remove job type',
                            () {
                              provider.laborRates.remove(rate.id);
                              setState(() => _dirty = true);
                              provider.laborRatesChanged();
                            },
                            danger: true,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add job type'),
                      onPressed: () {
                        final book = provider.laborRates;
                        book.upsert(
                          LaborRate(id: book.newId('rate'), name: 'New role'),
                        );
                        setState(() => _dirty = true);
                        provider.laborRatesChanged();
                      },
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            Text(
              book.source.isEmpty ? 'Not saved yet' : book.source,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.disabledColor,
              ),
              overflow: TextOverflow.ellipsis,
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
            final saved = await provider.saveLaborRates();
            if (saved.isEmpty) {
              _snack('Could not save the rate card.', error: true);
              return;
            }
            setState(() => _dirty = false);
            _snack('Labor rates saved to $saved');
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _update(AppStateProvider provider, LaborRate rate) {
    provider.laborRates.upsert(rate);
    setState(() => _dirty = true);
    provider.laborRatesChanged();
  }

  Future<void> _load(AppStateProvider provider) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Open a rate card',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    await provider.loadLaborRates(explicitPath: path);
    if (!mounted) return;
    setState(() => _dirty = false);
    _snack('Loaded ${provider.laborRates.rates.length} job types from $path');
  }

  Future<void> _saveAs(AppStateProvider provider) async {
    String? output = await FilePicker.saveFile(
      dialogTitle: 'Save the rate card as',
      fileName: 'labor_rates.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (output == null) return;
    if (!output.toLowerCase().endsWith('.json')) output += '.json';
    final saved = await provider.laborRates.save(toPath: output);
    if (!mounted) return;
    if (saved.isEmpty) {
      _snack('Could not write the rate card.', error: true);
      return;
    }
    setState(() => _dirty = false);
    provider.laborRatesChanged();
    _snack('Rate card saved to $saved');
  }
}
