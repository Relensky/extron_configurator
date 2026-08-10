import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'av_port_editor.dart' show avRowIcon;
import 'av_rack_view.dart' show iconForRackItem;
import 'base_costs_dialog.dart';
import 'cost_estimate.dart';
import 'export_tools.dart';
import 'labor_rates.dart';
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

/// What the "add a part that isn't on the drawing" picker is being opened for.
/// The four differ in which slice of the catalog they offer and which list on
/// the estimate the result lands on, and nothing else.
enum _ExtraPart { equipment, cable, hardware, misc }

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
            Row(
              children: [
                Text(
                  'Equipment (${estimate.equipment.length} line'
                  '${estimate.equipment.length == 1 ? '' : 's'})',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'counted off the signal flow diagram, plus anything added '
                    'here that is quoted without being drawn',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Two ways on, the same pair the "Other items" card offers:
                // off the catalog, so the price follows a revision; or a plain
                // line for the box that has no catalog entry and a figure
                // somebody was quoted over the phone.
                TextButton.icon(
                  icon: const Icon(Icons.playlist_add, size: 16),
                  label: const Text('Add from catalog'),
                  onPressed: () => _addExtraPart(context, provider,
                      kind: _ExtraPart.equipment),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add line'),
                  onPressed: () => provider.addAvCostExtraEquipment(),
                ),
              ],
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
                  'Signal Flow page and they appear here, or add a line for '
                  'something being quoted that nobody has drawn.',
                ),
              ),
            for (final line in estimate.equipment)
              Builder(
                builder: (context) {
                  // Lines added here keep an editable name and quantity and a
                  // way out; a device on the diagram takes both from the
                  // drawing, which is the whole point of counting them there.
                  final extra = provider.avCost.extraEquipment
                      .where((i) => i.id == line.key)
                      .firstOrNull;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: extra == null
                              ? Text(
                                  line.description,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                )
                              : LiveTextField(
                                  fieldId: 'eqpdesc_${extra.id}',
                                  initial: extra.description,
                                  hint: 'e.g. Owner-furnished display',
                                  onChanged: (v) =>
                                      provider.updateAvCostExtraEquipment(
                                    extra.copyWith(description: v),
                                  ),
                                ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            extra == null
                                ? (line.model.isEmpty ? '—' : line.model)
                                : (line.model.isEmpty
                                      ? 'not on the diagram'
                                      : '${line.model} · not on the diagram'),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.disabledColor,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 60,
                          child: extra == null
                              ? Text(
                                  '×${line.qty.toStringAsFixed(0)}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 13),
                                )
                              : LiveTextField(
                                  fieldId: 'eqpqty_${extra.id}',
                                  initial: trimNumber(extra.qty),
                                  numeric: true,
                                  onChanged: (v) =>
                                      provider.updateAvCostExtraEquipment(
                                    extra.copyWith(
                                      qty: double.tryParse(v) ?? 0,
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 130,
                          child: LiveTextField(
                            fieldId: 'price_${line.key}',
                            // The box holds THIS ROOM'S price and nothing
                            // else. Showing the catalog figure in it made
                            // every line look like it had been quoted by
                            // hand, and left the box disagreeing with the row
                            // when the catalog or the base cost changed
                            // underneath it. Blank means "use whatever the row
                            // resolved to" — which the hint spells out.
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
                        if (extra == null)
                          avRowIcon(
                            Icons.restart_alt,
                            'Back to the catalog price',
                            line.source == PriceSource.override
                                ? () => provider.setAvCostPrice(line.key, null)
                                : null,
                          )
                        else
                          avRowIcon(
                            Icons.delete_outline,
                            'Remove this line',
                            () => provider
                                .removeAvCostExtraEquipment(extra.id),
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
                Expanded(
                  child: Text(
                    'placed on the Racks tab, plus anything added here that '
                    'is bought but not racked',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add hardware'),
                  onPressed: () => _addExtraPart(context, provider,
                      kind: _ExtraPart.hardware),
                ),
              ],
            ),
            if (estimate.hardware.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'None yet. A rack of gear also has blanks, vents and a shelf '
                  'or two in it — add them on the Racks tab, or add one '
                  'here when it is bought without going in a frame.',
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
                Builder(
                  builder: (context) {
                    // Lines added here (rather than placed in a frame) keep an
                    // editable quantity and a way out; a racked one takes both
                    // from the elevation.
                    final extra = provider.avCost.extraHardware
                        .where((i) => i.id == line.key)
                        .firstOrNull;
                    return Padding(
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
                          extra == null
                              ? (line.category.isEmpty
                                    ? '—'
                                    : line.category)
                              : '${line.category.isEmpty ? 'Hardware'
                                    : line.category} · not racked',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.disabledColor,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 60,
                        child: extra == null
                            ? Text(
                                '×${line.qty.toStringAsFixed(0)}',
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontSize: 13),
                              )
                            : LiveTextField(
                                fieldId: 'hwqty_${extra.id}',
                                initial: trimNumber(extra.qty),
                                numeric: true,
                                onChanged: (v) =>
                                    provider.updateAvCostExtraHardware(
                                  extra.copyWith(
                                    qty: double.tryParse(v) ?? 0,
                                  ),
                                ),
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
                      if (extra == null)
                        avRowIcon(
                          Icons.restart_alt,
                          'Back to the parts list price',
                          line.source == PriceSource.override
                              ? () => provider.setAvCostPrice(line.key, null)
                              : null,
                        )
                      else
                        avRowIcon(
                          Icons.delete_outline,
                          'Remove this line',
                          () => provider
                              .removeAvCostExtraHardware(extra.id),
                          danger: true,
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
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add cable'),
                  onPressed: () => _addExtraPart(context, provider,
                      kind: _ExtraPart.cable),
                ),
                const SizedBox(width: 8),
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
            else if (types.isEmpty && settings.extraCables.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No cables drawn yet. Draw the runs on the Signal Flow page '
                  'and they are counted and priced here; prices per cable type '
                  'live on the Catalog tab under "Cable". Cable that is not a '
                  'run on the drawing — a spool, a bag of patch leads — '
                  'goes in with "Add cable".',
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
              // Cable bought for the job that no run on the diagram accounts
              // for. Listed under the counted runs so the two are read
              // together, and labeled so nobody looks for it on the drawing.
              for (final item in settings.extraCables)
                Builder(
                  builder: (context) {
                    final line = estimate.cabling
                        .where((l) => l.key == item.id)
                        .firstOrNull;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Row(
                              children: [
                                Icon(Icons.shopping_bag_outlined,
                                    size: 15, color: theme.disabledColor),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: LiveTextField(
                                    fieldId: 'cbldesc_${item.id}',
                                    initial: item.description,
                                    hint: 'e.g. Cat6A spool, 1000 ft',
                                    onChanged: (v) =>
                                        provider.updateAvCostExtraCable(
                                      item.copyWith(description: v),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 66,
                            child: Text(
                              'misc',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.disabledColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 80,
                            child: LiveTextField(
                              fieldId: 'cblqty_${item.id}',
                              initial: trimNumber(item.qty),
                              numeric: true,
                              onChanged: (v) =>
                                  provider.updateAvCostExtraCable(
                                item.copyWith(qty: double.tryParse(v) ?? 0),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 54,
                            child: Text(
                              trimNumber(item.qty),
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
                              fieldId: 'cblprice_${item.id}',
                              initial: line == null
                                  ? ''
                                  : _roomPriceText(provider, line),
                              prefix: currency,
                              numeric: true,
                              hint: line == null || line.unitPrice <= 0
                                  ? 'unpriced'
                                  : trimNumber(line.unitPrice),
                              onChanged: (v) {
                                final parsed = double.tryParse(v);
                                provider.setAvCostPrice(
                                  item.id,
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
                            Icons.delete_outline,
                            'Remove this line',
                            () => provider.removeAvCostExtraCable(item.id),
                            danger: true,
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

  // --- adding a part that is not on the drawing ----------------------------

  /// Picks a catalog part and adds it to the estimate without it appearing on
  /// any drawing.
  ///
  /// Both cards need this for the same reason: not everything on an order is
  /// on a diagram. A spare shelf, a box of blanks, a spool of Cat6A and the
  /// bag of patch leads are all real money, and none of them is a rack slot or
  /// a run between two ports. Before this they had to go in "Other items",
  /// divorced from the parts list and invisible to anyone reading the hardware
  /// or cabling totals.
  Future<void> _addExtraPart(
    BuildContext context,
    AppStateProvider provider, {
    required _ExtraPart kind,
  }) async {
    final library = provider.avDeviceLibrary;
    final parts = switch (kind) {
      _ExtraPart.equipment => library.equipment,
      _ExtraPart.cable => library.cables,
      _ExtraPart.hardware => library.rackHardware,
      _ExtraPart.misc => library.miscItems,
    };
    final searchController = TextEditingController();
    final qtyController = TextEditingController(text: '1');
    final nameController = TextEditingController();
    String? selectedModel;

    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final matches =
              searchCatalog(parts, searchController.text, limit: parts.length);
          return AlertDialog(
            title: Text(switch (kind) {
              _ExtraPart.equipment => 'Add equipment',
              _ExtraPart.cable => 'Add cable',
              _ExtraPart.hardware => 'Add rack hardware',
              _ExtraPart.misc => 'Add a cost item',
            }),
            content: SizedBox(
              width: 560,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    switch (kind) {
                      _ExtraPart.equipment =>
                        'A box on the quote that is not on the diagram — '
                            'something somebody else is installing, a spare, '
                            'or a stand-in for a decision not yet made. It is '
                            'quoted with the drawn devices and marked as not '
                            'on the diagram. Pick nothing and it goes on as a '
                            'plain line at whatever price you type.',
                      _ExtraPart.cable =>
                        'Cable that is not a run on the diagram — a spool, '
                            'a bag of patch leads, a drop somebody else is '
                            'pulling. Quoted with the counted runs and '
                            'marked as miscellaneous.',
                      _ExtraPart.hardware =>
                        'Hardware bought for the job without going into a '
                            'frame here. Quoted with the racked hardware and '
                            'marked as not racked.',
                      _ExtraPart.misc =>
                        'A billable line off the catalog — a licence, a '
                            'mount, a rental, a trip charge. It keeps its '
                            'catalog price, so a revision reaches every '
                            'estimate that uses it. Add them on the Device '
                            'Editor with "New cost item".',
                    },
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: switch (kind) {
                        _ExtraPart.equipment => 'Search the device catalog',
                        _ExtraPart.cable => 'Search the cable types',
                        _ExtraPart.hardware => 'Search the parts list',
                        _ExtraPart.misc => 'Search the cost items',
                      },
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: matches.isEmpty
                        ? Center(
                            child: Text(
                              'Nothing in the catalog matches. Name it below '
                              'and type its price on the line instead.',
                              textAlign: TextAlign.center,
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          )
                        : ListView.builder(
                            itemCount: matches.length,
                            itemBuilder: (ctx, i) {
                              final t = matches[i];
                              final price =
                                  t.priceForTier(provider.pricingTier);
                              return ListTile(
                                dense: true,
                                selected: t.model == selectedModel,
                                leading: Icon(
                                  switch (kind) {
                                    _ExtraPart.equipment => Icons.developer_board,
                                    _ExtraPart.cable => Icons.cable,
                                    _ExtraPart.hardware =>
                                      iconForRackItem(t.category),
                                    _ExtraPart.misc => Icons.receipt_long,
                                  },
                                  size: 20,
                                ),
                                title: Text(
                                  t.model,
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  [
                                    if (t.category.isNotEmpty) t.category,
                                    if (t.rackUnits > 0) '${t.rackUnits}U',
                                    price.price > 0
                                        ? formatMoney(price.price,
                                            provider.currencySymbol)
                                        : 'not priced',
                                  ].join(' · '),
                                  style: const TextStyle(fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => setLocal(() {
                                  selectedModel = t.model;
                                  nameController.text = t.model;
                                }),
                              );
                            },
                          ),
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: nameController,
                          decoration: InputDecoration(
                            labelText: 'Name on the estimate',
                            hintText: switch (kind) {
                              _ExtraPart.equipment =>
                                'e.g. Owner-furnished 86" display',
                              _ExtraPart.cable => 'e.g. Cat6A spool, 1000 ft',
                              _ExtraPart.hardware => 'e.g. Spare 2U shelf',
                              _ExtraPart.misc => 'e.g. Display mount',
                            },
                            isDense: true,
                          ),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: qtyController,
                          decoration: const InputDecoration(
                            labelText: 'Qty',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]')),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    selectedModel == null
                        ? 'Nothing picked — it goes on by name, and you type '
                              'its price on the line.'
                        : 'Priced from the catalog: $selectedModel',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed:
                    selectedModel == null && nameController.text.trim().isEmpty
                        ? null
                        : () => Navigator.of(ctx).pop(true),
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );

    if (added != true) return;
    final typed = double.tryParse(qtyController.text.trim()) ?? 1;
    final qty = typed <= 0 ? 1.0 : typed;
    final name = nameController.text.trim().isEmpty
        ? (selectedModel ?? '')
        : nameController.text.trim();
    final template = library.templateForModel(selectedModel ?? '');

    switch (kind) {
      case _ExtraPart.equipment:
        provider.addAvCostExtraEquipment(
          catalogModel: selectedModel ?? '',
          description: name,
          category: template?.category ?? '',
          qty: qty,
        );
      case _ExtraPart.cable:
        provider.addAvCostExtraCable(
          catalogModel: selectedModel ?? '',
          description: name,
          qty: qty,
        );
      case _ExtraPart.hardware:
        provider.addAvCostExtraHardware(
          catalogModel: selectedModel ?? '',
          description: name,
          category: template?.category ?? '',
          qty: qty,
        );
      case _ExtraPart.misc:
        provider.addAvCostItem(
          catalogModel: selectedModel ?? '',
          description: name,
          category: template?.category ?? '',
          qty: qty,
        );
    }
  }

  // --- export --------------------------------------------------------------
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
      // OPEN rather than just a path: the point of writing a workbook is to
      // look at it, and hunting the folder down afterwards is the one step
      // between saving an estimate and reading it.
      final saved = outputFile;
      showTimedSnackBar(
        messenger,
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('Cost estimate saved to $saved'),
          action: SnackBarAction(
            label: 'OPEN',
            onPressed: () async {
              if (!await launchUrl(
                Uri.file(saved),
                mode: LaunchMode.externalApplication,
              )) {
                messenger.showSnackBar(
                  SnackBar(content: Text('Could not open $saved')),
                );
              }
            },
          ),
        ),
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
                          child: _JobTypeField(
                            book: book,
                            rateId: line.rateId,
                            currency: currency,
                            onChanged: (v) => provider.updateAvCostLabor(
                              line.copyWith(rateId: v),
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
                // Two ways on: off the catalog, so a price agreed once is not
                // retyped per room and follows a revision; or a blank line for
                // the one-off nobody will ever quote again.
                TextButton.icon(
                  icon: const Icon(Icons.playlist_add, size: 16),
                  label: const Text('Add from catalog'),
                  onPressed: () => _addExtraPart(
                    context,
                    provider,
                    kind: _ExtraPart.misc,
                  ),
                ),
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
            // Short on purpose is still short: said plainly, and in the plain
            // text colour rather than the error one, because this one is a
            // decision somebody made rather than something missing.
            if (estimate.excludedDevices > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Not quoted: ${estimate.excludedDevices} device'
                  '${estimate.excludedDevices == 1 ? '' : 's'} on the diagram '
                  '${estimate.excludedDevices == 1 ? 'is' : 'are'} marked as '
                  'existing, owner-furnished or by others.',
                  style: theme.textTheme.bodySmall,
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

// ---------------------------------------------------------------------------
//  JOB TYPE PICKER
// ---------------------------------------------------------------------------

/// The job-type cell on a labor row.
///
/// No longer a [DropdownButtonFormField]. A dense dropdown clamps its closed
/// button to the height of one line and clips what does not fit, so any rate
/// named more than a few characters wrapped inside the box and had its second
/// line sliced through the middle — which is what the cell looked broken
/// doing. A published billing schedule is also far too long to find anything
/// in by scrolling a menu, so this opens a searchable list instead and shows
/// one ellipsized line when it is closed.
///
/// The hourly figure is deliberately not repeated here: the Rate/hr box two
/// columns over already shows what this line costs at, and the name needs
/// every pixel of a 182-wide cell.
class _JobTypeField extends StatelessWidget {
  final LaborRateBook book;

  /// The selected [LaborRate.id]; '' when the line carries its own rate.
  final String rateId;
  final String currency;

  /// Called with the chosen id, or '' when the job type is cleared. Not called
  /// at all when the picker is dismissed.
  final ValueChanged<String> onChanged;

  const _JobTypeField({
    required this.book,
    required this.rateId,
    required this.currency,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = book.byId(rateId);
    // The cell is 182 wide and a published job title is not; the full name,
    // its shorthand and the rate live on the tooltip so the row can still be
    // identified without opening the picker.
    final tip = rate == null
        ? 'No job type picked'
        : [
            if (rate.initialism.isNotEmpty) '${rate.initialism} — ${rate.name}'
            else rate.name,
            rate.isSet
                ? '${formatMoney(rate.hourlyRate, currency)}/hr'
                : 'no rate set',
            if (rate.notes.isNotEmpty) rate.notes,
          ].join('\n');
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
      onTap: () async {
        final picked = await _pickJobType(context, book, currency, rateId);
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.fromLTRB(8, 9, 4, 9),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                rate?.name ?? (rateId.isEmpty ? 'Pick a job type' : rateId),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  // An id with no rate behind it means the card no longer has
                  // that job type — worth seeing rather than showing blank.
                  color: rate == null
                      ? (rateId.isEmpty
                            ? theme.hintColor
                            : theme.colorScheme.error)
                      : null,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 20, color: theme.hintColor),
          ],
        ),
      ),
      ),
    );
  }
}

/// Picks a job type off the rate card. Returns the chosen id, '' to clear it,
/// or null when the dialog is dismissed.
Future<String?> _pickJobType(
  BuildContext context,
  LaborRateBook book,
  String currency,
  String current,
) {
  final search = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);
        // Name, notes and shorthand all match — see [LaborRate.matches]. The
        // shorthand is the one that matters in practice: "tss" and "tssIII"
        // are what people type for a Technology Support Specialist III.
        final needle = search.text;
        final matches = [
          for (final r in book.rates)
            if (r.matches(needle)) r,
        ];
        return AlertDialog(
          title: const Text('Job type'),
          content: SizedBox(
            width: 620,
            height: 500,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The rate this crew is billed at. Rates live on the shared '
                  'card, so revising one re-costs every room that uses it — '
                  'open "Labor rates" to edit them.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Search the rate card',
                    hintText: 'name, class number, or shorthand — "tss", '
                        '"tssIII", "electrician"',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: matches.isEmpty
                      ? Center(
                          child: Text(
                            'No job type on the card matches.',
                            style: theme.textTheme.bodySmall,
                          ),
                        )
                      : ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (ctx, i) {
                            final r = matches[i];
                            final short = r.initialism;
                            return ListTile(
                              dense: true,
                              selected: r.id == current,
                              // The shorthand is shown, not just matched: a
                              // card of sixty-odd published job titles is
                              // read by people who know them as TSS III and
                              // ITC, and seeing the letters is what tells you
                              // they are the ones to type.
                              leading: short.isEmpty
                                  ? null
                                  : SizedBox(
                                      width: 62,
                                      child: Text(
                                        short,
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
                              title: Text(
                                r.name,
                                style: const TextStyle(fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: r.notes.isEmpty
                                  ? null
                                  : Text(
                                      r.notes,
                                      style: const TextStyle(fontSize: 11),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: Text(
                                r.isSet
                                    ? '${formatMoney(r.hourlyRate, currency)}'
                                          '/hr'
                                    : 'no rate',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: r.isSet
                                      ? null
                                      : theme.colorScheme.error,
                                ),
                              ),
                              onTap: () => Navigator.of(ctx).pop(r.id),
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
              child: const Text('Cancel'),
            ),
            // A line with no job type still costs, off the rate typed on the
            // row itself — that is how a one-off subcontract gets recorded.
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('No job type'),
            ),
          ],
        );
      },
    ),
  );
}
