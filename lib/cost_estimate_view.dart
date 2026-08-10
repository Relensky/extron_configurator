import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'av_port_editor.dart' show avRowIcon;
import 'cost_estimate.dart';
import 'labor_rates_dialog.dart';
import 'live_text_field.dart';
import 'report_tools.dart';

/// ============================================================================
///  COST ESTIMATE TAB
/// ============================================================================
///  Prices the room that is drawn on the AV canvas. Quantities are not typed
///  in — they are the devices on the diagram, grouped exactly as the pack list
///  groups them — so the estimate cannot drift from the equipment order.
///
///  Unit prices come from the device catalog (the Device Editor tab). A price
///  typed HERE is a room override: what this job was quoted, kept in the
///  room's sidecar and never written back over the catalog's list price.
///
///  On top of that: any number of percentage fees on the pre-tax subtotal,
///  flat lines for labour and materials, and one tax rate applied to the
///  taxable part.
/// ============================================================================

class CostEstimateView extends StatefulWidget {
  /// The diagram to price. Null means "read it from the provider", which is
  /// what the tab does; the parameter is kept so a caller that has already
  /// resolved the model can hand it straight over.
  final AvFlowModel? model;

  const CostEstimateView({super.key, this.model});

  @override
  State<CostEstimateView> createState() => _CostEstimateViewState();
}

class _CostEstimateViewState extends State<CostEstimateView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The estimate lives in the AV sidecar, which is only read on the first
      // visit to whichever tab gets there first.
      context.read<AppStateProvider>().ensureAvFlowForCurrentConfig();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (provider.roomConfig.isEmpty) {
      return const Center(child: Text('No configuration loaded.'));
    }
    final model = widget.model ?? buildAvFlowModel(provider);
    final settings = provider.avCost;
    final estimate = computeRoomCost(
      model: model,
      library: provider.avDeviceLibrary,
      settings: settings,
      rates: provider.laborRates,
    );
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _header(context, provider, estimate, model),
        const SizedBox(height: 12),
        _equipmentCard(context, provider, estimate),
        const SizedBox(height: 12),
        _laborCard(context, provider, estimate),
        const SizedBox(height: 12),
        _itemsCard(context, provider, estimate),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _feesCard(context, provider, settings)),
            const SizedBox(width: 12),
            SizedBox(width: 380, child: _totalsCard(context, estimate, theme)),
          ],
        ),
      ],
    );
  }

  // --- header: currency, tax, and the copy button --------------------------
  Widget _header(
    BuildContext context,
    AppStateProvider provider,
    CostEstimate estimate,
    AvFlowModel model,
  ) {
    final theme = Theme.of(context);
    final settings = provider.avCost;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Room Cost Estimate', style: theme.textTheme.titleLarge),
                const Spacer(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.engineering, size: 18),
                  label: const Text('Labor rates'),
                  onPressed: () => showLaborRatesDialog(context, provider),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Save'),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final saved = await provider.saveAvFlow();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          saved.isEmpty
                              ? 'Failed to save the estimate.'
                              : 'Estimate saved with the AV flow: $saved',
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: const Text('Copy estimate'),
                  onPressed: () async {
                    final text = renderTextReport(
                      model.roomTitle.isEmpty
                          ? 'Cost estimate'
                          : model.roomTitle,
                      costReportSections(estimate),
                    );
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cost estimate copied to clipboard.'),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Quantities are the devices on the AV diagram; unit prices come '
              'from the device catalog. A price typed here applies to this '
              'room only.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: LiveTextField(
                    fieldId: 'currency',
                    initial: settings.currency,
                    label: 'Currency',
                    onChanged: (v) => provider.setAvCostTax(currency: v),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 200,
                  child: LiveTextField(
                    fieldId: 'taxLabel',
                    initial: settings.taxLabel,
                    label: 'Tax name',
                    onChanged: (v) => provider.setAvCostTax(label: v),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 130,
                  child: LiveTextField(
                    fieldId: 'taxPercent',
                    initial: settings.taxPercent == 0
                        ? ''
                        : trimNumber(settings.taxPercent),
                    label: 'Tax rate',
                    suffix: '%',
                    numeric: true,
                    onChanged: (v) =>
                        provider.setAvCostTax(percent: double.tryParse(v) ?? 0),
                  ),
                ),
                const SizedBox(width: 16),
                if (!estimate.isComplete)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${estimate.unpricedDevices} device'
                            '${estimate.unpricedDevices == 1 ? '' : 's'} have '
                            'no price — the total below is short by whatever '
                            'they cost.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- equipment -----------------------------------------------------------
  Widget _equipmentCard(
    BuildContext context,
    AppStateProvider provider,
    CostEstimate estimate,
  ) {
    final theme = Theme.of(context);
    final currency = estimate.currency;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Equipment (${estimate.equipment.length} line'
              '${estimate.equipment.length == 1 ? '' : 's'})',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            _headerRow(theme, const [
              (width: 0.0, flex: 3, text: 'Device'),
              (width: 0.0, flex: 2, text: 'Model'),
              (width: 60.0, flex: 0, text: 'Qty'),
              (width: 142.0, flex: 0, text: 'Unit price'),
              (width: 122.0, flex: 0, text: 'Extended'),
              (width: 104.0, flex: 0, text: 'Price from'),
              (width: 34.0, flex: 0, text: ''),
            ]),
            const Divider(height: 12),
            if (estimate.equipment.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No devices on the AV diagram yet — place some on the '
                  'Signal Flow page and they appear here.',
                ),
              ),
            for (final line in estimate.equipment)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        line.description,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        line.model.isEmpty ? '—' : line.model,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.disabledColor,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(
                        '×${line.qty.toStringAsFixed(0)}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 130,
                      child: LiveTextField(
                        fieldId: 'price_${line.key}',
                        initial: line.unitPrice == 0
                            ? ''
                            : trimNumber(line.unitPrice),
                        prefix: currency,
                        numeric: true,
                        hint: 'unpriced',
                        onChanged: (v) {
                          final parsed = double.tryParse(v);
                          provider.setAvCostPrice(
                            line.key,
                            v.trim().isEmpty ? null : (parsed ?? 0),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: Text(
                        formatMoney(line.total, currency),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 92,
                      child: Text(
                        kPriceSourceLabels[line.source] ?? '',
                        style: TextStyle(
                          fontSize: 11,
                          color: line.source == PriceSource.none
                              ? theme.colorScheme.error
                              : theme.disabledColor,
                        ),
                      ),
                    ),
                    avRowIcon(
                      Icons.restart_alt,
                      'Back to the catalog price',
                      line.source == PriceSource.override
                          ? () => provider.setAvCostPrice(line.key, null)
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- labor ---------------------------------------------------------------

  /// Crews, priced as rate x techs x hours. The head count and the hours stay
  /// visible next to the money because that is what gets checked: "two CTS III
  /// for three days" is arguable, a lump sum is not.
  Widget _laborCard(
    BuildContext context,
    AppStateProvider provider,
    CostEstimate estimate,
  ) {
    final theme = Theme.of(context);
    final currency = estimate.currency;
    final book = provider.laborRates;
    final lines = provider.avCost.labor;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Labor', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  estimate.labor.isEmpty
                      ? 'rate x techs x hours, off the shared rate card'
                      : '${trimNumber(estimate.laborHours)} tech-hours',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add crew'),
                  onPressed: () => provider.addAvCostLabor(),
                ),
              ],
            ),
            if (book.allUnset)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'No job type has an hourly rate yet — open '
                        '"Labor rates" and set them once, and every room '
                        'costs from the same card.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 4),
              _headerRow(theme, const [
                (width: 190.0, flex: 0, text: 'Job type'),
                (width: 0.0, flex: 3, text: 'Scope'),
                (width: 86.0, flex: 0, text: 'Techs'),
                (width: 94.0, flex: 0, text: 'Hours ea.'),
                (width: 84.0, flex: 0, text: 'Rate/hr'),
                (width: 122.0, flex: 0, text: 'Extended'),
                (width: 92.0, flex: 0, text: 'Taxable'),
                (width: 34.0, flex: 0, text: ''),
              ]),
              const Divider(height: 12),
            ],
            for (final line in lines)
              Builder(
                builder: (context) {
                  final costed = estimate.labor.firstWhere(
                    (l) => l.id == line.id,
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 182,
                          child: DropdownButtonFormField<String>(
                            initialValue: book.byId(line.rateId) == null
                                ? null
                                : line.rateId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final r in book.rates)
                                DropdownMenuItem(
                                  value: r.id,
                                  child: Text(
                                    r.isSet
                                        ? '${r.name} '
                                              '(${formatMoney(r.hourlyRate, currency)})'
                                        : '${r.name} (no rate)',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                            onChanged: (v) => provider.updateAvCostLabor(
                              line.copyWith(rateId: v ?? ''),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: LiveTextField(
                            fieldId: 'labor_desc_${line.id}',
                            initial: line.description,
                            hint: 'e.g. Rack build and termination',
                            onChanged: (v) => provider.updateAvCostLabor(
                              line.copyWith(description: v),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 78,
                          child: LiveTextField(
                            fieldId: 'labor_techs_${line.id}',
                            initial: trimNumber(line.techs),
                            numeric: true,
                            onChanged: (v) => provider.updateAvCostLabor(
                              line.copyWith(techs: double.tryParse(v) ?? 0),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 86,
                          child: LiveTextField(
                            fieldId: 'labor_hours_${line.id}',
                            initial: line.hours == 0
                                ? ''
                                : trimNumber(line.hours),
                            numeric: true,
                            onChanged: (v) => provider.updateAvCostLabor(
                              line.copyWith(hours: double.tryParse(v) ?? 0),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 76,
                          child: LiveTextField(
                            // Blank follows the card; a figure here is what
                            // THIS job pays, which is how overtime and a
                            // one-off subcontract rate get recorded.
                            fieldId: 'labor_rate_${line.id}',
                            initial: line.customRate == 0
                                ? ''
                                : trimNumber(line.customRate),
                            hint: costed.unrated
                                ? 'set'
                                : trimNumber(costed.hourlyRate),
                            numeric: true,
                            onChanged: (v) => provider.updateAvCostLabor(
                              line.copyWith(
                                customRate: double.tryParse(v) ?? 0,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 110,
                          child: Text(
                            costed.unrated
                                ? 'no rate'
                                : formatMoney(costed.total, currency),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: costed.unrated
                                  ? theme.colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 92,
                          child: Checkbox(
                            value: line.taxable,
                            onChanged: (v) => provider.updateAvCostLabor(
                              line.copyWith(taxable: v ?? false),
                            ),
                          ),
                        ),
                        avRowIcon(
                          Icons.delete_outline,
                          'Remove crew',
                          () => provider.removeAvCostLabor(line.id),
                          danger: true,
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  // --- other items ---------------------------------------------------------
  Widget _itemsCard(
    BuildContext context,
    AppStateProvider provider,
    CostEstimate estimate,
  ) {
    final theme = Theme.of(context);
    final currency = estimate.currency;
    final items = provider.avCost.items;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Other items', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  'labour, cable, mounts — anything not a device on the canvas',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add item'),
                  onPressed: () => provider.addAvCostItem(),
                ),
              ],
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 4),
              _headerRow(theme, const [
                (width: 0.0, flex: 3, text: 'Description'),
                (width: 0.0, flex: 2, text: 'Category'),
                (width: 78.0, flex: 0, text: 'Qty'),
                (width: 138.0, flex: 0, text: 'Unit price'),
                (width: 122.0, flex: 0, text: 'Extended'),
                (width: 92.0, flex: 0, text: 'Taxable'),
                (width: 34.0, flex: 0, text: ''),
              ]),
              const Divider(height: 12),
            ],
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: LiveTextField(
                        fieldId: 'desc_${item.id}',
                        initial: item.description,
                        hint: 'e.g. Installation labour',
                        onChanged: (v) => provider.updateAvCostItem(
                          item.copyWith(description: v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: LiveTextField(
                        fieldId: 'cat_${item.id}',
                        initial: item.category,
                        hint: 'Labour',
                        onChanged: (v) => provider.updateAvCostItem(
                          item.copyWith(category: v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 70,
                      child: LiveTextField(
                        fieldId: 'qty_${item.id}',
                        initial: trimNumber(item.qty),
                        numeric: true,
                        onChanged: (v) => provider.updateAvCostItem(
                          item.copyWith(qty: double.tryParse(v) ?? 0),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 130,
                      child: LiveTextField(
                        fieldId: 'unit_${item.id}',
                        initial: item.unitPrice == 0
                            ? ''
                            : trimNumber(item.unitPrice),
                        prefix: currency,
                        numeric: true,
                        onChanged: (v) => provider.updateAvCostItem(
                          item.copyWith(unitPrice: double.tryParse(v) ?? 0),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: Text(
                        formatMoney(item.total, currency),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 92,
                      child: Checkbox(
                        value: item.taxable,
                        onChanged: (v) => provider.updateAvCostItem(
                          item.copyWith(taxable: v ?? true),
                        ),
                      ),
                    ),
                    avRowIcon(
                      Icons.delete_outline,
                      'Remove item',
                      () => provider.removeAvCostItem(item.id),
                      danger: true,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- fees ----------------------------------------------------------------
  Widget _feesCard(
    BuildContext context,
    AppStateProvider provider,
    RoomCostSettings settings,
  ) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Fees', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  'each a percentage of the subtotal before tax',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add fee'),
                  onPressed: () => provider.addAvCostFee(),
                ),
              ],
            ),
            if (settings.fees.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No fees. Add one for freight, installation, contingency or '
                  'overhead — several are fine, and each is worked out on the '
                  'same pre-tax subtotal rather than on top of each other.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            for (final fee in settings.fees)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: LiveTextField(
                        fieldId: 'fee_name_${fee.id}',
                        initial: fee.name,
                        hint: 'e.g. Freight',
                        onChanged: (v) =>
                            provider.updateAvCostFee(fee.copyWith(name: v)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 110,
                      child: LiveTextField(
                        fieldId: 'fee_pct_${fee.id}',
                        initial: fee.percent == 0
                            ? ''
                            : trimNumber(fee.percent),
                        suffix: '%',
                        numeric: true,
                        onChanged: (v) => provider.updateAvCostFee(
                          fee.copyWith(percent: double.tryParse(v) ?? 0),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Compact and shrink-wrapped: the stock 48px tap target
                    // plus the caption overflowed this row once the totals
                    // card took its width out of the card.
                    SizedBox(
                      width: 96,
                      child: Row(
                        children: [
                          Checkbox(
                            value: fee.taxable,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (v) => provider.updateAvCostFee(
                              fee.copyWith(taxable: v ?? true),
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Flexible(
                            child: Text(
                              'Taxed',
                              style: TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    avRowIcon(
                      Icons.delete_outline,
                      'Remove fee',
                      () => provider.removeAvCostFee(fee.id),
                      danger: true,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- totals --------------------------------------------------------------
  Widget _totalsCard(
    BuildContext context,
    CostEstimate estimate,
    ThemeData theme,
  ) {
    final currency = estimate.currency;
    Widget row(
      String label,
      double value, {
      bool bold = false,
      bool big = false,
    }) {
      final style = TextStyle(
        fontSize: big ? 16 : 13,
        fontWeight: bold || big ? FontWeight.bold : FontWeight.normal,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: style)),
            Text(formatMoney(value, currency), style: style),
          ],
        ),
      );
    }

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Totals', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            row('Equipment', estimate.equipmentTotal),
            if (estimate.labor.isNotEmpty)
              row(
                'Labor (${trimNumber(estimate.laborHours)} h)',
                estimate.laborTotal,
              ),
            if (estimate.extras.isNotEmpty)
              row('Other items', estimate.extrasTotal),
            const Divider(),
            row('Subtotal before tax', estimate.subtotal, bold: true),
            for (final f in estimate.fees)
              row(
                '${f.fee.name.trim().isEmpty ? 'Fee' : f.fee.name} '
                '(${formatPercent(f.fee.percent)})',
                f.amount,
              ),
            if (estimate.taxPercent > 0) ...[
              const Divider(),
              row('Taxable amount', estimate.taxableBase),
              row(
                '${estimate.taxLabel} (${formatPercent(estimate.taxPercent)})',
                estimate.tax,
              ),
            ],
            const Divider(),
            row('TOTAL', estimate.grandTotal, big: true),
            if (estimate.unpricedLines > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Excludes ${estimate.unpricedDevices} device'
                  '${estimate.unpricedDevices == 1 ? '' : 's'} with no price. '
                  'Set prices in the table above, or once in the Catalog tab '
                  'so every room gets them.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (estimate.unratedLabor > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Excludes ${estimate.unratedLabor} labor line'
                  '${estimate.unratedLabor == 1 ? '' : 's'} whose job type '
                  'has no hourly rate set.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Column captions over a table. [width] is the data row's cell width plus
  /// the gap in front of it, so a caption stays over its column — the rows
  /// below are Rows of SizedBoxes, not a Table, and nothing else lines them
  /// up.
  Widget _headerRow(
    ThemeData theme,
    List<({double width, int flex, String text})> columns,
  ) {
    final style = theme.textTheme.labelSmall;
    return Row(
      children: [
        for (final c in columns)
          if (c.flex > 0)
            Expanded(
              flex: c.flex,
              child: Text(c.text, style: style),
            )
          else
            SizedBox(
              width: c.width,
              child: Text(c.text, style: style),
            ),
      ],
    );
  }
}
