import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'av_port_editor.dart' show avRowIcon;
import 'av_rack_view.dart' show iconForRackItem;
import 'base_costs_dialog.dart';
import 'cost_estimate.dart';
import 'export_tools.dart';
import 'labor_rates_dialog.dart';
import 'live_text_field.dart';
import 'report_tools.dart';
import 'xlsx_writer.dart';

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
///  flat lines for labor and materials, and one tax rate applied to the
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
      baseCosts: provider.baseCosts,
      tier: provider.pricingTier,
    );
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _header(context, provider, estimate, model),
        const SizedBox(height: 12),
        _equipmentCard(context, provider, estimate),
        const SizedBox(height: 12),
        _hardwareCard(context, provider, estimate),
        const SizedBox(height: 12),
        _cablingCard(context, provider, estimate, model),
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
                  icon: const Icon(Icons.price_change_outlined, size: 18),
                  label: const Text('Base costs'),
                  onPressed: () => showBaseCostsDialog(context, provider),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Save AV Setup'),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final saved = await provider.saveAvFlow();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          saved.isEmpty
                              ? 'Failed to save the estimate.'
                              : 'Estimate saved with the AV setup: $saved',
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                // Three ways out, because an estimate gets read in three
                // places: a spreadsheet somebody sums, a text file that goes
                // in a ticket, and a paste into an email.
                PopupMenuButton<String>(
                  tooltip: 'Export the estimate',
                  onSelected: (v) =>
                      _exportEstimate(context, provider, estimate, model, v),
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(
                      value: 'xlsx',
                      child: Text('Excel workbook (.xlsx)'),
                    ),
                    PopupMenuItem(
                      value: 'txt',
                      child: Text('Plain text (.txt)'),
                    ),
                    PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy text to clipboard'),
                    ),
                  ],
                  child: IgnorePointer(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('Export'),
                      onPressed: () {},
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Quantities are the devices on the AV diagram; unit prices come '
              'from the device catalog at the '
              '${kPricingTierLabels[provider.pricingTier]?.toLowerCase()}. '
              'A price typed here applies to this room only. The currency '
              'symbol is set in App Config.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                // Which of the catalog's two published prices this estimate is
                // costed from. On the page rather than only in App Config
                // because it is a question about THIS quote, and the answer
                // changes every figure below it.
                SegmentedButton<PricingTier>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    for (final t in PricingTier.values)
                      ButtonSegment(
                        value: t,
                        label: Text(kPricingTierShort[t] ?? t.name),
                      ),
                  ],
                  selected: {provider.pricingTier},
                  onSelectionChanged: (s) => provider.setPricingTier(s.first),
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
                        // The box holds THIS ROOM'S price and nothing else.
                        // Showing the catalog figure in it made every line
                        // look like it had been quoted by hand, and left the
                        // box disagreeing with the row when the catalog or
                        // the base cost changed underneath it. Blank means
                        // "use whatever the row resolved to" — which the
                        // hint spells out.
                        initial: _roomPriceText(provider, line),
                        prefix: currency,
                        numeric: true,
                        hint: _resolvedPriceHint(line),
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

  // --- rack hardware -------------------------------------------------------

  /// The plates, shelves and drawers in the racks. Read-only here: they are
  /// placed on the Racks tab, because where a blank goes is a rack decision,
  /// not a pricing one. What IS editable here is the price this job paid.
  Widget _hardwareCard(
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
            Row(
              children: [
                Text('Rack hardware', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  'plates, shelves and drawers placed on the Racks tab',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
              ],
            ),
            if (estimate.hardware.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'None yet. A rack of gear also has blanks, vents and a shelf '
                  'or two in it — add them on the Racks tab and they are '
                  'quoted here.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...[
              const SizedBox(height: 8),
              _headerRow(theme, const [
                (width: 0.0, flex: 3, text: 'Item'),
                (width: 0.0, flex: 2, text: 'Kind'),
                (width: 60.0, flex: 0, text: 'Qty'),
                (width: 142.0, flex: 0, text: 'Unit price'),
                (width: 122.0, flex: 0, text: 'Extended'),
                (width: 104.0, flex: 0, text: 'Price from'),
                (width: 34.0, flex: 0, text: ''),
              ]),
              const Divider(height: 12),
              for (final line in estimate.hardware)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Row(
                          children: [
                            Icon(
                              iconForRackItem(line.category),
                              size: 15,
                              color: theme.disabledColor,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                line.description,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          line.category.isEmpty ? '—' : line.category,
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
                          initial: _roomPriceText(provider, line),
                          prefix: currency,
                          numeric: true,
                          hint: _resolvedPriceHint(line),
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
                        'Back to the parts list price',
                        line.source == PriceSource.override
                            ? () => provider.setAvCostPrice(line.key, null)
                            : null,
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // --- cabling -------------------------------------------------------------

  /// Cable, counted off the diagram rather than guessed. Every run drawn on
  /// the Signal Flow page is one lead of its signal type; spares are typed in
  /// on top, because "three more HDMI leads" is a decision and not something
  /// the drawing can be read to imply.
  Widget _cablingCard(
    BuildContext context,
    AppStateProvider provider,
    CostEstimate estimate,
    AvFlowModel model,
  ) {
    final theme = Theme.of(context);
    final currency = estimate.currency;
    final settings = provider.avCost;
    final drawn = countCableRuns(model);
    final library = provider.avDeviceLibrary;

    // Types with runs on the diagram, plus any that only have spares — a
    // spare for a type you didn't draw is still cable somebody is buying.
    final types = <SignalType>{
      ...drawn.keys,
      for (final name in settings.cableSpares.keys) signalFromName(name),
    }.toList()..sort((a, b) => a.index.compareTo(b.index));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Cabling', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  'one lead per run on the signal flow diagram',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
                const Spacer(),
                Switch(
                  value: settings.includeCabling,
                  onChanged: (v) => provider.setAvCostIncludeCabling(v),
                ),
                const Text('Include', style: TextStyle(fontSize: 12)),
              ],
            ),
            if (!settings.includeCabling)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Cabling is left out of this estimate. Turn it back on to '
                  'quote the runs on the diagram.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else if (types.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No cables drawn yet. Draw the runs on the Signal Flow page '
                  'and they are counted and priced here; prices per cable type '
                  'live on the Catalog tab under "Cable".',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...[
              const SizedBox(height: 8),
              _headerRow(theme, const [
                (width: 0.0, flex: 3, text: 'Cable type'),
                (width: 66.0, flex: 0, text: 'Drawn'),
                (width: 92.0, flex: 0, text: 'Spares'),
                (width: 66.0, flex: 0, text: 'Total'),
                (width: 142.0, flex: 0, text: 'Unit price'),
                (width: 122.0, flex: 0, text: 'Extended'),
                (width: 34.0, flex: 0, text: ''),
              ]),
              const Divider(height: 12),
              for (final signal in types)
                Builder(
                  builder: (context) {
                    final key = 'cable:${signal.name}';
                    final line = estimate.cabling
                        .where((l) => l.key == key)
                        .firstOrNull;
                    final catalog = library.cableForSignal(signal);
                    final runs = (drawn[signal] ?? 0).toDouble();
                    final spares = provider.avCableSpares(signal);
                    final unit = line?.unitPrice ?? catalog?.price ?? 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: provider.avSignalColor(signal),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    catalog?.model.trim().isNotEmpty == true
                                        ? catalog!.model
                                        : '${kSignalLabels[signal] ??
                                              signal.name} cable',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 66,
                            child: Text(
                              trimNumber(runs),
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 80,
                            child: LiveTextField(
                              fieldId: 'spare_${signal.name}',
                              initial: spares == 0 ? '' : trimNumber(spares),
                              numeric: true,
                              hint: '0',
                              onChanged: (v) => provider.setAvCableSpares(
                                signal,
                                double.tryParse(v) ?? 0,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 54,
                            child: Text(
                              trimNumber(runs + spares),
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 130,
                            child: LiveTextField(
                              fieldId: 'cableprice_${signal.name}',
                              initial: line == null
                                  ? ''
                                  : _roomPriceText(provider, line),
                              prefix: currency,
                              numeric: true,
                              hint: unit > 0
                                  ? trimNumber(unit)
                                  : 'unpriced',
                              onChanged: (v) {
                                final parsed = double.tryParse(v);
                                provider.setAvCostPrice(
                                  key,
                                  v.trim().isEmpty ? null : (parsed ?? 0),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 110,
                            child: Text(
                              formatMoney(line?.total ?? 0, currency),
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          avRowIcon(
                            Icons.restart_alt,
                            'Back to the catalog price',
                            line?.source == PriceSource.override
                                ? () => provider.setAvCostPrice(key, null)
                                : null,
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// The price typed on THIS room for [line], or '' when it is taking the
  /// catalog / base-cost figure.
  String _roomPriceText(AppStateProvider provider, CostLine line) {
    final override = provider.avCost.priceOverrides[line.key];
    return override == null ? '' : trimNumber(override);
  }

  /// What the line costs when nothing is typed over it, shown as the box's
  /// placeholder so the resolved figure is still visible.
  String _resolvedPriceHint(CostLine line) =>
      line.source == PriceSource.none || line.unitPrice <= 0
      ? 'unpriced'
      : trimNumber(line.unitPrice);

  // --- export --------------------------------------------------------------

  /// Writes the estimate as a spreadsheet or a text file, or puts the text on
  /// the clipboard. [what] is 'xlsx' | 'txt' | 'copy'.
  Future<void> _exportEstimate(
    BuildContext context,
    AppStateProvider provider,
    CostEstimate estimate,
    AvFlowModel model,
    String what,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final title = model.roomTitle.isEmpty ? 'Cost estimate' : model.roomTitle;
    final sections = costReportSections(estimate);

    if (sections.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Nothing priced yet — there is no estimate to export.'),
        ),
      );
      return;
    }

    if (what == 'copy') {
      await Clipboard.setData(
        ClipboardData(text: renderTextReport(title, sections)),
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Cost estimate copied to clipboard.')),
      );
      return;
    }

    final ext = what == 'xlsx' ? 'xlsx' : 'txt';
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save Cost Estimate',
      fileName: '${roomFileStem(provider, 'cost_estimate')}.$ext',
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.$ext')) outputFile += '.$ext';

    try {
      if (ext == 'xlsx') {
        // The same banded, auto-sized sheet the other reports use, so a
        // folder of exports reads as one set of documents.
        final bytes = buildXlsx([
          buildStackedReportSheet(
            sheetName: 'Cost Estimate',
            title: title,
            sections: sections,
          ),
        ]);
        await File(outputFile).writeAsBytes(bytes);
      } else {
        await File(outputFile).writeAsString(renderTextReport(title, sections));
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Cost estimate saved to $outputFile')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save the estimate: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
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
                  'labor, cable, mounts — anything not a device on the canvas',
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
                        hint: 'e.g. Installation labor',
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
                        hint: 'Labor',
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
            if (estimate.hardware.isNotEmpty)
              row('Rack hardware', estimate.hardwareTotal),
            if (estimate.cabling.isNotEmpty)
              row('Cabling', estimate.cablingTotal),
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
            // A total built partly on category averages is a budget. Saying so
            // here is the difference between a planning figure and a number
            // somebody quotes a customer.
            if (estimate.otherTierLines > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${estimate.otherTierLines} line'
                  '${estimate.otherTierLines == 1 ? '' : 's'} had no '
                  '${estimate.tierLabel} price in the catalog and '
                  '${estimate.otherTierLines == 1 ? 'was' : 'were'} costed at '
                  'the other tier — worth a look before this goes on a quote.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (estimate.isBudgetary)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Budget figure: ${estimate.estimatedLines} line'
                  '${estimate.estimatedLines == 1 ? '' : 's'} priced from the '
                  'base cost for the category rather than a chosen model.',
                  style: theme.textTheme.bodySmall,
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
