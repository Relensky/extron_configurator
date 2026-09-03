import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart' show AvDeviceTemplate, kPricingTierLabels;
import 'av_flow_swap_dialogs.dart' show pickCatalogModel;
import 'base_costs.dart' show BaseCost;
import 'catalog_standards.dart';
import 'cost_estimate.dart' show formatMoney;

/// ============================================================================
///  THE CARD THE WHOLE ESTATE IS PRICED ON
/// ============================================================================
///  Every figure the project and campus reports fall back to comes off one
///  line of the base-cost card, and each of those lines can name the model it
///  was benchmarked on. Until now they were set one at a time from the campus
///  report, which is the right shape when somebody is reading that report and
///  has an opinion about projectors.
///
///  It is the wrong shape for the job this screen exists for: the start of a
///  budget year, a price list just imported, eighteen categories, and one
///  question - is anything on this card still benchmarked on a product we
///  cannot buy? That question is asked of the CATALOG, so it is asked here.
///
///  EVERY PROPOSAL IS SHOWN BEFORE ANY OF IT IS WRITTEN. Setting eighteen
///  categories re-prices four hundred rooms, and a button that does that
///  without a list in front of it is a button nobody should press twice.
///
///  A LINE ALREADY ON A CURRENT MODEL IS NOT TOUCHED. Re-pricing it because a
///  price list moved is a decision, and it stays a decision: press the line
///  and pick.
/// ============================================================================

Future<void> showCatalogStandards(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const CatalogStandardsDialog(),
);

class CatalogStandardsDialog extends StatefulWidget {
  const CatalogStandardsDialog({super.key});

  @override
  State<CatalogStandardsDialog> createState() => _CatalogStandardsDialogState();
}

class _CatalogStandardsDialogState extends State<CatalogStandardsDialog> {
  /// Set once so every line written in one pass carries the same day. A card
  /// whose eighteen lines are dated a second apart reads as eighteen
  /// decisions.
  final DateTime _asOf = DateTime.now();

  bool _dirty = false;

  void _write(AppStateProvider provider, CategoryStandard row,
      AvDeviceTemplate model) {
    provider.baseCosts.upsert(
      standardApplied(
        row,
        model,
        existing: provider.baseCosts.byCategory(row.category),
        setOn: _asOf,
      ),
    );
    setState(() => _dirty = true);
    provider.baseCostsChanged();
  }

  Future<void> _pick(
    BuildContext context,
    AppStateProvider provider,
    CategoryStandard row,
  ) async {
    // NARROWED TO THE CATEGORY, because the question is "which projector",
    // never "which of two thousand products". A category the catalog files
    // under another name still gets the whole list rather than an empty
    // picker.
    final inCategory = [
      for (final t in provider.avDeviceLibrary.active)
        if (t.category.trim().toLowerCase() == row.category.toLowerCase()) t,
    ];
    final picked = await pickCatalogModel(
      context,
      provider,
      title: 'What is this year\'s ${row.category.toLowerCase()}?',
      actionLabel: 'Price the estate on this',
      currentModel: row.benchmark.isEmpty ? null : row.benchmark,
      note: 'Every room, report and plan with no price of its own uses it.',
      only: inCategory.isEmpty ? null : inCategory,
    );
    if (picked == null) return;
    _write(provider, row, picked);
  }

  Future<void> _applyAll(
    AppStateProvider provider,
    List<CategoryStandard> rows,
  ) async {
    for (final row in rows) {
      final model = row.proposed;
      if (model == null) continue;
      provider.baseCosts.upsert(
        standardApplied(
          row,
          model,
          existing: provider.baseCosts.byCategory(row.category),
          setOn: _asOf,
        ),
      );
    }
    setState(() => _dirty = true);
    provider.baseCostsChanged();
  }

  Future<void> _save(AppStateProvider provider) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await provider.saveBaseCosts();
    if (!mounted) return;
    Navigator.of(context).pop();
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          error.isEmpty
              ? 'The base-cost card is saved. Every room, report and plan with '
                    'no price of its own prices off it.'
              : 'The base cost card could not be written: $error',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final rows = readCategoryStandards(
      card: provider.baseCosts,
      library: provider.avDeviceLibrary,
      asOf: _asOf,
    );
    final proposals = rows.where((r) => r.proposed != null).toList();

    return AlertDialog(
      key: const ValueKey('catalog_standards_dialog'),
      title: Row(
        children: [
          const Expanded(child: Text('What the estate is priced on')),
          if (_dirty)
            Chip(
              label: const Text('Unsaved'),
              backgroundColor: theme.colorScheme.secondaryContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 900,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'One line per kind of thing. Where a room, a report or a plan '
              'has no price of its own, this is the figure it uses - and the '
              'model beside it is what that figure is a figure FOR. '
              '${describeCategoryStandards(rows, _asOf)}.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('catalog_standards_apply_all'),
                  onPressed: proposals.isEmpty
                      ? null
                      : () => _applyAll(provider, proposals),
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: Text(
                    proposals.isEmpty
                        ? 'Nothing to set'
                        : proposals.length == 1
                        ? 'Set the 1 line below'
                        : 'Set the ${proposals.length} lines below',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    proposals.isEmpty
                        ? 'Every line is benchmarked on a model the catalog '
                              'still carries. A line already on a current '
                              'model is never changed for you - press it and '
                              'pick.'
                        : 'A benchmark the catalog has retired follows its own '
                              'successor; a line with nothing set takes the '
                              'dearest current model in its category. Lines '
                              'already on a current model are left alone.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(),
            _StandardsHeaderRow(tier: provider.pricingTier),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, i) => _StandardRow(
                  key: ValueKey('catalog_standard_${rows[i].category}'),
                  row: rows[i],
                  card: provider.baseCosts.byCategory(rows[i].category),
                  currency: provider.project.currency,
                  asOf: _asOf,
                  onPick: () => _pick(context, provider, rows[i]),
                  onTake: rows[i].proposed == null
                      ? null
                      : () => _write(provider, rows[i], rows[i].proposed!),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('catalog_standards_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_dirty ? 'Cancel' : 'Close'),
        ),
        FilledButton(
          key: const ValueKey('catalog_standards_save'),
          onPressed: _dirty ? () => _save(provider) : null,
          child: const Text('Save the card'),
        ),
      ],
    );
  }
}

const double _kCategoryWidth = 170;
const double _kMoneyWidth = 110;
const double _kActionWidth = 96;

class _StandardsHeaderRow extends StatelessWidget {
  final dynamic tier;

  const _StandardsHeaderRow({required this.tier});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: _kCategoryWidth, child: Text('CATEGORY', style: style)),
          Expanded(child: Text('PRICED ON', style: style)),
          SizedBox(
            width: _kMoneyWidth,
            child: Text(
              (kPricingTierLabels[tier] ?? '').toUpperCase(),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 12),
          const SizedBox(width: _kActionWidth),
        ],
      ),
    );
  }
}

/// One category: what it is priced on, and the way to change it.
class _StandardRow extends StatelessWidget {
  final CategoryStandard row;
  final BaseCost? card;
  final String currency;
  final DateTime asOf;
  final VoidCallback onPick;

  /// Takes the catalog's proposal for this line. Null when there is none.
  final VoidCallback? onTake;

  const _StandardRow({
    super.key,
    required this.row,
    required this.card,
    required this.currency,
    required this.asOf,
    required this.onPick,
    this.onTake,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final wants = standardNeedsLooking(row, asOf);
    final price = card?.price ?? 0;
    final age = card?.standardAgeYears(asOf);

    return InkWell(
      onTap: onPick,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _kCategoryWidth,
              child: Row(
                children: [
                  if (wants)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.error_outline,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  Expanded(
                    child: Text(row.category, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.benchmark.isEmpty
                        ? 'nothing set - the figure is somebody typed number'
                        : row.benchmark,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: row.benchmark.isEmpty ? muted : null,
                    ),
                  ),
                  Text(
                    [
                      if (age != null)
                        age == 0 ? 'set this year' : 'set $age years ago',
                      if (row.stale && row.because.isNotEmpty) row.because,
                      if (row.proposed != null)
                        'catalog offers ${row.proposed!.model}',
                    ].join('  ·  '),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: _kMoneyWidth,
              child: Text(
                price > 0 ? formatMoney(price, currency) : 'not set',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: price > 0 ? null : muted,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: _kActionWidth,
              child: onTake == null
                  ? TextButton(
                      key: ValueKey('catalog_standard_pick_${row.category}'),
                      onPressed: onPick,
                      child: const Text('Change'),
                    )
                  : TextButton(
                      key: ValueKey('catalog_standard_take_${row.category}'),
                      onPressed: onTake,
                      child: const Text('Take it'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
