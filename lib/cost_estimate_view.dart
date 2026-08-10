import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_port_editor.dart' show avRowIcon;
import 'cost_estimate.dart';
import 'live_text_field.dart';
import 'report_tools.dart';

/// ============================================================================
///  COST ESTIMATE PAGE  (AV Flow tab -> "Cost")
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

class CostEstimateView extends StatelessWidget {
  final AvFlowModel model;

  const CostEstimateView({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final settings = provider.avCost;
    final estimate = computeRoomCost(
      model: model,
      library: provider.avDeviceLibrary,
      settings: settings,
    );
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _header(context, provider, estimate),
        const SizedBox(height: 12),
        _equipmentCard(context, provider, estimate),
        const SizedBox(height: 12),
        _itemsCard(context, provider, estimate),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _feesCard(context, provider, settings)),
            const SizedBox(width: 12),
            SizedBox(
              width: 380,
              child: _totalsCard(context, estimate, theme),
            ),
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
                Text('Room cost estimate', style: theme.textTheme.titleMedium),
                const Spacer(),
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
                    onChanged: (v) => provider.setAvCostTax(
                      percent: double.tryParse(v) ?? 0,
                    ),
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

    Widget row(String label, double value, {bool bold = false, bool big = false}) {
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
            if (!estimate.isComplete)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Excludes ${estimate.unpricedDevices} device'
                  '${estimate.unpricedDevices == 1 ? '' : 's'} with no price. '
                  'Set prices in the table above, or once in the Device '
                  'Editor tab so every room gets them.',
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
            Expanded(flex: c.flex, child: Text(c.text, style: style))
          else
            SizedBox(width: c.width, child: Text(c.text, style: style)),
      ],
    );
  }
}
