import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_swap_dialogs.dart' show pickCatalogModel;
import 'base_costs.dart';
import 'campus_lifecycle.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show formatMoney;
import 'equipment_lifecycle.dart' show formatLifecycleMoney;
import 'model_standards.dart';

/// ============================================================================
///  THE CURRENT MODELS TAB
/// ============================================================================
///  The year grid answers WHEN the estate falls due and what that comes to. It
///  is built entirely out of one number per kind of thing - what a projector
///  costs - and that number had no provenance at all: somebody typed it onto
///  the base cost card once, and four hundred positions across twelve buildings
///  were budgeted off it for as long as nobody re-typed it.
///
///  This tab is where that number gets decided, in front of the evidence:
///
///    WHAT THE ESTATE ACTUALLY HOLDS. Forty-one projectors, and here are the
///    models they are - eighteen of one, twelve of another, nine of which the
///    catalog has already retired.
///
///    WHAT IT IS BUDGETED AT NOW, added off the plan's own rows so this figure
///    and the year grid can never disagree.
///
///    WHAT IT WOULD BE AT THIS YEAR'S MODEL. Pick one out of the catalog and
///    the comparison is on screen before anything is committed: the unit price,
///    forty-one of them, and the gap against what the plan assumes. That gap is
///    the whole reading - a budget short by it is a budget that fails at
///    purchase order time.
///
///  SETTING IT WRITES THE BASE CARD, which is the card the room cost page, the
///  project report and the campus report all already price from - so the
///  decision reaches every one of them without any of them knowing this tab
///  exists. The model and the date go on with the figure, so a card set on a
///  2022 projector in 2026 can be SEEN to be four years stale.
/// ============================================================================

/// The Current Models pane for a campus.
class CampusModelStandards extends StatelessWidget {
  final CampusLifecycle campus;

  /// Called once a card has been written, so the sheet behind can be re-read -
  /// every figure on it came from one pass over disk and a card that changed
  /// changes most of them.
  final Future<void> Function() onChanged;

  const CampusModelStandards({
    super.key,
    required this.campus,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final rows = campusModelStandards(
      campus: campus,
      library: provider.avDeviceLibrary,
      baseCosts: provider.baseCosts,
    );

    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Nothing on this estate has a category on it yet.\n\n'
          'A position gets one from the catalog entry for its model, or from '
          'what it does in the room. Draw a room, or put the models into the '
          'catalog, and every kind of thing on the estate is listed here with '
          'what it is budgeted at.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    final attention = rows.where(standardNeedsAttention).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'WHAT WE WOULD BUY THIS YEAR',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Every kind of thing this estate holds, what the plan '
                  'budgets it at, and what the same estate would come to at a '
                  'model chosen out of the catalog today. Setting one writes '
                  'the figure onto the base cost card - the same card the '
                  'room cost page and both reports already price from - along '
                  'with which model it was priced on and when.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (attention > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '$attention of ${rows.length} '
                    '${attention == 1 ? 'is' : 'are'} worth a look: no '
                    'benchmark, one set more than $kStaleStandardYears years '
                    'ago, or positions holding gear the catalog has retired.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final row in rows)
          _StandardCard(
            row: row,
            currency: campus.currency,
            onChanged: onChanged,
          ),
      ],
    );
  }
}

/// One kind of thing on the estate: what is in it, what it costs now, and what
/// this year's model would make it.
class _StandardCard extends StatefulWidget {
  final ModelStandard row;
  final String currency;
  final Future<void> Function() onChanged;

  const _StandardCard({
    required this.row,
    required this.currency,
    required this.onChanged,
  });

  @override
  State<_StandardCard> createState() => _StandardCardState();
}

class _StandardCardState extends State<_StandardCard> {
  /// The model being TRIED, before anybody has committed to it.
  ///
  /// THE COMPARISON COMES FIRST. Writing the card the moment a model is picked
  /// would make the arithmetic - forty-one of these, this much more than the
  /// plan assumes - something somebody reads after the decision instead of
  /// before it, and that arithmetic is the entire reason to open this tab.
  AvDeviceTemplate? _trying;

  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final row = widget.row;
    final muted = theme.colorScheme.onSurfaceVariant;
    final currency = widget.currency;

    // What is being compared: the model being tried, else the one the card is
    // already benchmarked on. Null until somebody picks something.
    final candidate = _trying ?? row.standard;
    final unit = candidate?.priceForTier(provider.pricingTier).price ?? 0;
    final quote = candidate == null || unit <= 0
        ? null
        : quoteAtStandard(
            positions: row.positions,
            unitPrice: unit,
            budgetedNow: row.budgetedNow,
          );

    return Card(
      key: ValueKey('standard_card_${row.category}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.category,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        [
                          '${row.positions} position'
                              '${row.positions == 1 ? '' : 's'}',
                          if (row.priced < row.positions)
                            '${row.positions - row.priced} with no price at all',
                          if (row.retiredPositions > 0)
                            '${row.retiredPositions} holding retired gear',
                        ].join('  ·  '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // THE FIGURE THE PLAN IS ACTUALLY USING, at the top right
                // where a money column belongs.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatLifecycleMoney(row.budgetedNow, currency),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'budgeted now',
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            _benchmarkLine(theme, row, muted),
            const SizedBox(height: 8),
            // WHAT IT WOULD COST TODAY. The example the tab exists to show.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  key: ValueKey('standard_pick_${row.category}'),
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: Text(
                    candidate == null
                        ? 'Price it on a model...'
                        : 'A different model...',
                  ),
                  onPressed: () => _pick(context, provider),
                ),
                if (quote != null)
                  OutlinedButton.icon(
                    key: ValueKey('standard_apply_${row.category}'),
                    icon: const Icon(Icons.price_check, size: 18),
                    label: const Text('Make this the recommended cost'),
                    onPressed: () => _apply(context, provider, candidate!, unit),
                  ),
                if (row.card?.isSet == true)
                  TextButton(
                    key: ValueKey('standard_clear_${row.category}'),
                    onPressed: () => setState(() => _trying = null),
                    child: const Text('Leave it as it is'),
                  ),
              ],
            ),
            if (candidate != null) ...[
              const SizedBox(height: 8),
              _example(theme, candidate, unit, quote, currency, muted),
            ],
            // WHAT IS ACTUALLY IN THEM. Behind a toggle: on a category with
            // one model it is a line, and on one with thirty it is the longest
            // thing on the page and not what the card is read for.
            if (row.models.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                key: ValueKey('standard_models_${row.category}'),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        _open ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: muted,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _open
                              ? 'What is in them'
                              : 'What is in them: '
                                    '${row.models.take(3).map((m) => '${m.model} (${m.count})').join(', ')}'
                                    '${row.models.length > 3 ? ', and ${row.models.length - 3} more' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_open)
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final m in row.models)
                        _installedRow(theme, provider, m, muted),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// One installed model, and whether the catalog has moved on from it.
  Widget _installedRow(
    ThemeData theme,
    AppStateProvider provider,
    InstalledModel m,
    Color muted,
  ) {
    final library = provider.avDeviceLibrary;
    final template = library.templateForModel(m.model);
    final successor = library.hasSuccessor(m.model)
        ? library.successorFor(m.model)
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        [
          '${m.count} × ${m.model}',
          if (template == null)
            'not in the catalog'
          else if (successor != null)
            'retired - replaced by ${successor.model}'
          else if (template.retired)
            'retired, with nothing named to replace it',
        ].join('  ·  '),
        style: theme.textTheme.bodySmall?.copyWith(
          color: template?.retired == true
              ? errorTextOn(theme.colorScheme, theme.cardColor)
              : muted,
        ),
      ),
    );
  }

  /// Where the category's present figure came from, said plainly.
  Widget _benchmarkLine(ThemeData theme, ModelStandard row, Color muted) {
    final card = row.card;
    final age = row.standardAgeYears;
    final String text;
    if (card == null || !card.isSet) {
      text = 'The base cost card has no figure for this, so every position '
          'with no catalog price of its own is reported as unpriced.';
    } else if (row.standard == null && card.standardModel.trim().isEmpty) {
      text = 'A typed figure with no model behind it. Nobody can say what it '
          'assumes.';
    } else if (row.standard == null) {
      text = 'Benchmarked on "${card.standardModel.trim()}", which is not in '
          'the catalog any more.';
    } else {
      text = 'Benchmarked on ${row.standard!.model}'
          '${age == null ? '' : age == 0 ? ', set this year' : ', set $age year${age == 1 ? '' : 's'} ago'}'
          '${age != null && age >= kStaleStandardYears ? ' - worth re-pricing' : ''}.';
    }

    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: standardNeedsAttention(row)
            ? theme.colorScheme.onSurface
            : muted,
        fontWeight: standardNeedsAttention(row) ? FontWeight.w600 : null,
      ),
    );
  }

  /// THE EXAMPLE: this model, this many of them, and the gap against the plan.
  Widget _example(
    ThemeData theme,
    AvDeviceTemplate candidate,
    double unit,
    StandardQuote? quote,
    String currency,
    Color muted,
  ) {
    if (unit <= 0) {
      return Text(
        '${candidate.model} has no price in the catalog, so there is nothing '
        'to compare. Put a price on the entry and it can be the benchmark.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: errorTextOn(theme.colorScheme, theme.cardColor),
        ),
      );
    }

    final over = quote!.delta > 0.005;
    final under = quote.delta < -0.005;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${candidate.manufacturer.trim().isEmpty ? '' : '${candidate.manufacturer.trim()} '}'
            '${candidate.model}  ·  ${formatMoney(unit, currency)} each',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${quote.positions} × = ${formatLifecycleMoney(quote.total, currency)} '
            'across the estate.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          Text(
            // THE GAP IS THE READING. Over is a problem and under is not, and
            // the sentence says which without relying on a sign or a color.
            !over && !under
                ? 'Exactly what the plan already budgets.'
                : over
                ? '${formatLifecycleMoney(quote.delta, currency)} MORE than the '
                      'plan budgets. A plan left as it is would be short by '
                      'that much.'
                : '${formatLifecycleMoney(-quote.delta, currency)} less than '
                      'the plan budgets.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: over
                  ? errorTextOn(theme.colorScheme, theme.cardColor)
                  : muted,
              fontWeight: over ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, AppStateProvider provider) async {
    final row = widget.row;
    // NARROWED TO THE CATEGORY, because the question is "which projector",
    // never "which of two thousand products". An estate whose catalog files
    // the category under another name still gets the whole list rather than
    // an empty picker.
    final inCategory = [
      for (final t in provider.avDeviceLibrary.active)
        if (t.category.trim().toLowerCase() == row.category.toLowerCase()) t,
    ];
    final picked = await pickCatalogModel(
      context,
      provider,
      title: 'What is this year\'s ${row.category.toLowerCase()}?',
      actionLabel: 'Price it on this',
      currentModel: row.standard?.model,
      note: 'Nothing is saved yet - the comparison against what the plan '
          'budgets comes up first.',
      only: inCategory.isEmpty ? null : inCategory,
    );
    if (picked == null) return;
    setState(() => _trying = picked);
  }

  /// Writes the benchmark onto the base cost card, and says what changed.
  Future<void> _apply(
    BuildContext context,
    AppStateProvider provider,
    AvDeviceTemplate model,
    double unit,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final row = widget.row;
    final existing = provider.baseCosts.byCategory(row.category);

    // BOTH TIERS, off the catalog entry's own two figures. A card with one
    // price on it has every estimate at the other tier reading high or low
    // depending on which way the job went - see [BaseCost].
    provider.baseCosts.upsert(
      (existing ?? BaseCost(category: row.category)).copyWith(
        category: row.category,
        price: model.price,
        educationPrice: model.educationPrice,
        standardModel: model.model,
        standardSetOn: DateTime.now(),
      ),
    );
    final saved = await provider.saveBaseCosts();
    provider.baseCostsChanged();
    setState(() => _trying = null);

    // The sheet is re-read rather than patched: every figure on it came from
    // one pass over disk, and one card changed changes most of them.
    await widget.onChanged();

    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          saved.isEmpty
              ? '${row.category} is now priced on ${model.model} '
                    '(${formatMoney(unit, widget.currency)}). Every room, '
                    'report and plan that has no price of its own uses it.'
              : '${row.category} is now priced on ${model.model}, but the base '
                    'cost card could not be written: $saved',
        ),
      ),
    );
  }
}
