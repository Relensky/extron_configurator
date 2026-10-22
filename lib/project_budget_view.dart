import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'cost_estimate.dart'
    show formatMoney, inKindSourceLabel, InKindLine, trimNumber;
import 'live_text_field.dart';
import 'project_budget.dart';
import 'project_estimate.dart' show ProjectRoomCost;

/// ============================================================================
///  THE BUDGET CARD ON THE PROJECT TAB
/// ============================================================================
///  The number the job has to come in under, the lines spent against it as
///  the job goes, and - beside them - what the rooms' estimates come to. See
///  project_budget.dart.
/// ============================================================================
class ProjectBudgetCard extends StatefulWidget {
  /// What the rooms' estimates add up to.
  final double estimateTotal;
  final String currency;

  /// What the optional upgrades the project counts come to, and whether any
  /// room has some. See [BuildingProject.optionsCounted].
  final double optionalTotal;
  final bool hasOptional;

  /// The rooms with optional upgrades, for the switches room by room and
  /// option by option.
  final List<ProjectRoomCost> optionRooms;

  /// Every line the rooms are given in kind, with its room.
  final List<({String room, InKindLine line})> inKind;

  const ProjectBudgetCard({
    super.key,
    required this.estimateTotal,
    required this.currency,
    this.optionalTotal = 0,
    this.hasOptional = false,
    this.optionRooms = const [],
    this.inKind = const [],
  });

  @override
  State<ProjectBudgetCard> createState() => _ProjectBudgetCardState();
}

class _ProjectBudgetCardState extends State<ProjectBudgetCard> {
  bool _expanded = true;

  double _parse(String v) =>
      double.tryParse(v.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0;

  /// One room's options: a switch for the room, and one for each option
  /// under it when it has more than one.
  Widget _optionRoom(
    BuildContext context,
    AppStateProvider provider,
    ProjectRoomCost room,
    String Function(double) money,
  ) {
    final theme = Theme.of(context);
    final ref = room.ref;
    final counted = provider.project.optionsCounted(ref);
    final lines = room.optionLines;
    final allKeys = {for (final l in lines) l.key};
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      key: ValueKey('project_budget_options_${ref.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: ValueKey('project_budget_options_room_${ref.id}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(room.name),
          subtitle: Text(
            counted
                ? '${money(room.optionsCounted)} of '
                      '${money(room.grandWithOptions - room.grandWithoutOptions)}'
                      ' in the estimate'
                : 'Left out - '
                      '${money(room.grandWithOptions - room.grandWithoutOptions)}',
            style: small,
          ),
          value: counted,
          onChanged: (v) => provider.setProjectRoomOptionsCounted(ref.id, v),
        ),
        if (lines.length > 1)
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: SwitchListTile(
                key: ValueKey('project_budget_option_${ref.id}_${l.key}'),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
                title: Text(l.name, style: theme.textTheme.bodyMedium),
                secondary: Text(money(l.amount), style: small),
                controlAffinity: ListTileControlAffinity.trailing,
                value: counted && !ref.optionalLinesOff.contains(l.key),
                onChanged: (v) => provider.setProjectRoomOptionLine(
                  ref.id,
                  l.key,
                  v,
                  allKeys: allKeys,
                ),
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final project = provider.project;
    final theme = Theme.of(context);
    final cur = widget.currency;
    final summary = BudgetSummary.of(
      project.budget,
      project.budgetLines,
      estimate: widget.estimateTotal,
    );
    String money(double v) => formatMoney(v, cur);
    final over = summary.hasBudget && summary.remaining < 0;
    final forecastOver = summary.hasBudget && summary.forecastRemaining < 0;

    Widget figure(String label, double value, {Color? color, String? key}) =>
        Padding(
          padding: const EdgeInsets.only(right: 24, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelSmall),
              Text(
                money(value),
                key: key == null ? null : ValueKey(key),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        );

    return Card(
      key: const ValueKey('project_budget_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet_outlined),
                const SizedBox(width: 8),
                Text('Budget', style: theme.textTheme.titleMedium),
                const Spacer(),
                // The fixed maximum - unlocked on Priorities and funding.
                if (project.budgetLocked)
                  Tooltip(
                    message: 'Locked. Unlock it on Priorities and funding',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          money(project.budget),
                          key: const ValueKey('project_budget_locked'),
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  )
                else
                SizedBox(
                  width: 200,
                  child: LiveTextField(
                    key: const ValueKey('project_budget_amount'),
                    fieldId: 'project_budget_amount',
                    initial: project.budget == 0
                        ? ''
                        : project.budget.toStringAsFixed(2),
                    label: 'Total budget ($cur)',
                    hint: 'e.g. 250000',
                    onChanged: (v) => provider.setProjectBudget(_parse(v)),
                  ),
                ),
                IconButton(
                  tooltip: _expanded ? 'Hide the lines' : 'Show the lines',
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              children: [
                figure('Budget', summary.budget),
                figure('Rooms estimate', summary.estimate),
                if (widget.hasOptional)
                  figure('Options counted', widget.optionalTotal,
                      key: 'project_budget_optional'),
                if (widget.inKind.isNotEmpty)
                  figure(
                    'In kind (not in the total)',
                    widget.inKind.fold(0.0, (s, e) => s + e.line.value),
                    key: 'project_budget_in_kind',
                  ),
                figure('Committed', summary.committed),
                figure('Spent', summary.spent),
                figure('Planned', summary.planned),
                figure(
                  'Remaining',
                  summary.remaining,
                  key: 'project_budget_remaining',
                  color: over ? theme.colorScheme.error : null,
                ),
                figure(
                  'Remaining after planned',
                  summary.forecastRemaining,
                  color: forecastOver ? theme.colorScheme.error : null,
                ),
                // What is left once the rooms are bought as estimated.
                if (summary.hasBudget)
                  figure(
                    'Remaining after rooms estimate',
                    summary.estimateHeadroom,
                    key: 'project_budget_after_estimate',
                    color: summary.estimateHeadroom < 0
                        ? theme.colorScheme.error
                        : null,
                  ),
              ],
            ),
            if (widget.hasOptional || project.includeOptional)
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  key: const ValueKey('project_budget_with_options'),
                  label: const Text('Rooms estimate with options'),
                  tooltip: 'Every room\'s options in the estimate, or none. '
                      'Each room and option below can go its own way.',
                  selected: project.includeOptional,
                  onSelected: provider.setProjectIncludeOptional,
                ),
              ),
            // Each room's options, and each option, in the estimate or out.
            if (widget.optionRooms.isNotEmpty)
              ExpansionTile(
                key: const ValueKey('project_budget_options_list'),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Options by room - ${widget.optionRooms.length} '
                  'room${widget.optionRooms.length == 1 ? '' : 's'}',
                  style: theme.textTheme.titleSmall,
                ),
                children: [
                  for (final room in widget.optionRooms)
                    _optionRoom(context, provider, room, money),
                ],
              ),
            // Everything the job is given rather than buys, room by room.
            if (widget.inKind.isNotEmpty)
              ExpansionTile(
                key: const ValueKey('project_budget_in_kind_list'),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'In kind - ${widget.inKind.length} '
                  'item${widget.inKind.length == 1 ? '' : 's'}',
                  style: theme.textTheme.titleSmall,
                ),
                children: [
                  for (final e in widget.inKind)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        SizedBox(
                          width: 120,
                          child: Text(e.room,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall),
                        ),
                        Expanded(
                          child: Text(
                            '${e.line.name} (${e.line.section})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: 170,
                          child: Text(inKindSourceLabel(e.line.by),
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall),
                        ),
                        SizedBox(
                          width: 60,
                          child: Text(trimNumber(e.line.qty),
                              textAlign: TextAlign.right,
                              style: theme.textTheme.bodySmall),
                        ),
                        SizedBox(
                          width: 110,
                          child: Text(money(e.line.value),
                              textAlign: TextAlign.right),
                        ),
                      ]),
                    ),
                ],
              ),
            if (summary.hasBudget) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  children: [
                    LinearProgressIndicator(
                      value: summary.forecastFraction.clamp(0.0, 1.0),
                      minHeight: 10,
                      color: theme.colorScheme.primary.withValues(alpha: 0.35),
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                    LinearProgressIndicator(
                      value: summary.usedFraction.clamp(0.0, 1.0),
                      minHeight: 10,
                      color: over
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      backgroundColor: Colors.transparent,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${(summary.usedFraction * 100).toStringAsFixed(0)}% committed '
                'or spent, ${(summary.forecastFraction * 100).toStringAsFixed(0)}% '
                'with the planned lines. The rooms estimate is '
                '${summary.estimateHeadroom >= 0 ? '${money(summary.estimateHeadroom)} under' : '${money(-summary.estimateHeadroom)} over'} '
                'the budget.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: summary.estimateHeadroom < 0
                      ? theme.colorScheme.error
                      : null,
                ),
              ),
            ],
            if (_expanded) ...[
              const Divider(height: 24),
              for (final line in project.budgetLines)
                _BudgetLineRow(
                  key: ValueKey('budget_line_${line.id}'),
                  line: line,
                  currency: cur,
                ),
              if (project.budgetLines.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'No lines yet. Add them as the job goes - a quote that came '
                    'back, a PO raised, an invoice paid.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('budget_add_line'),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add line'),
                    onPressed: () => provider.addBudgetLine(),
                  ),
                  if (widget.estimateTotal > 0)
                    OutlinedButton.icon(
                      key: const ValueKey('budget_add_estimate'),
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: const Text('Add the rooms estimate as planned'),
                      onPressed: () => provider.addBudgetLine(
                        BudgetLine.create(
                          item: 'Rooms estimate',
                          category: 'Equipment',
                          amount: widget.estimateTotal,
                          date: DateTime.now(),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BudgetLineRow extends StatelessWidget {
  final BudgetLine line;
  final String currency;

  const _BudgetLineRow({super.key, required this.line, required this.currency});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    void put(BudgetLine next) => provider.updateBudgetLine(next);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            flex: 4,
            child: LiveTextField(
              fieldId: 'budget_item_${line.id}',
              initial: line.item,
              label: 'Item',
              onChanged: (v) => put(line.copyWith(item: v)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Autocomplete<String>(
              initialValue: TextEditingValue(text: line.category),
              optionsBuilder: (v) => kBudgetCategories.where(
                (c) => c.toLowerCase().contains(v.text.toLowerCase()),
              ),
              onSelected: (v) => put(line.copyWith(category: v)),
              fieldViewBuilder: (context, controller, focus, onSubmit) =>
                  TextField(
                controller: controller,
                focusNode: focus,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  isDense: true,
                ),
                onChanged: (v) => put(line.copyWith(category: v)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: LiveTextField(
              fieldId: 'budget_vendor_${line.id}',
              initial: line.vendor,
              label: 'Vendor',
              onChanged: (v) => put(line.copyWith(vendor: v)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 130,
            child: LiveTextField(
              fieldId: 'budget_amount_${line.id}',
              initial: line.amount == 0 ? '' : line.amount.toStringAsFixed(2),
              label: 'Amount ($currency)',
              onChanged: (v) => put(line.copyWith(
                amount:
                    double.tryParse(v.replaceAll(RegExp(r'[^0-9.\-]'), '')) ??
                        0,
              )),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<BudgetStatus>(
            value: line.status,
            items: [
              for (final s in BudgetStatus.values)
                DropdownMenuItem(
                  value: s,
                  child: Text(kBudgetStatusLabels[s]!),
                ),
            ],
            onChanged: (s) {
              if (s != null) put(line.copyWith(status: s));
            },
          ),
          IconButton(
            tooltip: 'Remove this line',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => provider.removeBudgetLine(line.id),
          ),
        ],
      ),
    );
  }
}
