import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_report.dart' show driverGapSections;
import 'av_flow_routing.dart';
import 'av_flow_swap_dialogs.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'av_port_editor.dart' show avRowIcon, kRowIconWidth;
import 'av_rack_view.dart' show iconForRackItem;
import 'base_costs.dart';
import 'base_costs_dialog.dart';
import 'control_prefill.dart';
import 'control_prefill_dialog.dart';
import 'cost_estimate.dart';
import 'export_tools.dart';
import 'labor_rates.dart';
import 'labor_rates_dialog.dart';
import 'live_text_field.dart';
import 'print_mode.dart';
import 'report_tools.dart';
import 'screenshot_tools.dart';
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

/// What a swap does to the control block behind a drawn box, once the module
/// under it changes: keep what this room has set (a conversion — the IP
/// address and the port are facts about the install) or take the new module's
/// DEVICE_INFO defaults (a device being specified fresh). The same two answers
/// the Devices tab offers when a model is picked there.
enum _SwapControl { keepSettings, applyDefaults }

/// The equipment table's columns. Declared once and read by both the caption
/// row and every data row — see [_CostEstimateViewState._gridRow].
const List<_Col> _kEquipmentCols = [
  // MIXED COLUMNS. A device off the diagram prints its name and its count as
  // plain text; a line added here has a box for both. Both cells carry the
  // box's inset (see [_CellText]), so the caption sits over either kind and
  // the two kinds of row line up with each other.
  _Col.field('Device', flex: 3),
  _Col('Model', flex: 2),
  // DRAWN, SPARES, TOTAL — the same three the cabling table has, for the same
  // reason. The drawing says how many the room has; a job often buys one more
  // than that, and the spare is real money no drawing will ever account for.
  // Wide enough for the box AND the two nudge buttons beside it — see
  // [_CostEstimateViewState._qtyStepper]. Exactly one of these two cells is a
  // stepper on any given row (a drawn line buys spares, a typed line has its
  // own quantity), but the column has to hold one either way.
  _Col.field(
    'Qty',
    width: 56 + 2 * kStepButtonWidth,
    numeric: true,
    stepper: true,
  ),
  _Col.field(
    'Spares',
    gap: 8,
    width: 66 + 2 * kStepButtonWidth,
    numeric: true,
    stepper: true,
  ),
  _Col('Total', gap: 8, width: 52, align: TextAlign.right),
  _Col.field('Unit price', gap: 12, width: 120, numeric: true),
  _Col('Extended', gap: 12, width: 106, align: TextAlign.right),
  _Col('Price from', gap: 8, width: 88),
  // Four row buttons, 40 wide as they render.
  _Col('', width: 160),
];

/// The rack-hardware table's columns — see [_kEquipmentCols].
const List<_Col> _kHardwareCols = [
  _Col('Item', flex: 3),
  _Col('Kind', flex: 2),
  // Mixed, like the equipment table's: placed hardware prints
  // its count, a line added here has a box for it.
  _Col.field('Qty', width: 60, numeric: true),
  _Col.field('Unit price', gap: 12, width: 130, numeric: true),
  _Col('Extended', gap: 12, width: 110, align: TextAlign.right),
  _Col('Price from', gap: 12, width: 92),
  // Three row buttons. They are constrained to 34 and render at
  // 40, which is what the column actually takes.
  _Col('', width: 120),
];

/// The cabling table's columns — see [_kEquipmentCols]. Both kinds of row
/// read it: the runs counted off the diagram, and the miscellaneous cable
/// quoted by hand.
const List<_Col> _kCablingCols = [
  _Col('Cable type', flex: 3),
  _Col('Drawn', width: 66, align: TextAlign.right),
  _Col.field('Spares', gap: 12, width: 80, numeric: true),
  _Col('Total', gap: 12, width: 54, align: TextAlign.right),
  _Col.field('Unit price', gap: 12, width: 130, numeric: true),
  _Col('Extended', gap: 12, width: 110, align: TextAlign.right),
  // Four row buttons. They are constrained to 34 and render at
  // 40, which is what the column actually takes.
  _Col('', width: 160),
];

/// The labor table's columns — see [_kEquipmentCols].
const List<_Col> _kLaborCols = [
  // The picker is a box on the page AND in the photograph, so
  // its caption keeps the box's inset either way.
  _Col.field('Job type', width: 182, keepsBox: true),
  _Col.field('Scope', gap: 8, flex: 3),
  _Col.field('Techs', gap: 8, width: 78, numeric: true),
  _Col.field('Hours ea.', gap: 8, width: 86, numeric: true),
  _Col.field('Rate/hr', gap: 8, width: 76, numeric: true),
  _Col('Extended', gap: 12, width: 110, align: TextAlign.right),
  _Col('Taxable', width: 92, align: TextAlign.center),
  // One row button, 40 wide as it renders.
  _Col('', width: 40),
];

/// The other-items table's columns — see [_kEquipmentCols].
const List<_Col> _kItemsCols = [
  _Col.field('Description', flex: 3),
  _Col.field('Category', gap: 8, flex: 2),
  _Col.field('Qty', gap: 8, width: 70, numeric: true),
  _Col.field('Unit price', gap: 8, width: 130, numeric: true),
  _Col('Extended', gap: 12, width: 110, align: TextAlign.right),
  _Col('Taxable', width: 92, align: TextAlign.center),
  // Two row buttons. They are constrained to 34 and render at
  // 40, which is what the column actually takes.
  _Col('', width: 80),
];

class CostEstimateView extends StatefulWidget {
  /// The diagram to price. Null means "read it from the provider", which is
  /// what the tab does; the parameter is kept so a caller that has already
  /// resolved the model can hand it straight over.
  final AvFlowModel? model;

  /// Builds straight into the capture frame, at this brightness.
  ///
  /// A testing seam, because the real path runs through a native save dialog
  /// and a widget test has no business opening one — and the frame is the part
  /// worth checking: what it hides, how tall it is, what colour it is.
  @visibleForTesting
  final Brightness? debugCaptureBrightness;

  const CostEstimateView({
    super.key,
    this.model,
    this.debugCaptureBrightness,
  });

  @override
  State<CostEstimateView> createState() => _CostEstimateViewState();
}

class _CostEstimateViewState extends State<CostEstimateView> {
  /// Wrapped round the estimate itself, for the screenshot button.
  final GlobalKey _sheetKey = GlobalKey();

  /// True while a screenshot is being taken. Every control on the page reads
  /// this and stands down for the one frame that gets captured.
  ///
  /// A rendered PNG is what goes in an email or a ticket, and a picture of a
  /// quote with an "Export" button and a row of delete icons on it is a
  /// picture somebody has to apologize for. Hiding them rather than cropping
  /// keeps the numbers laid out exactly as they are on screen.
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    if (widget.debugCaptureBrightness != null) {
      _capturing = true;
      _captureBrightness = widget.debugCaptureBrightness!;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The estimate lives in the AV sidecar, which is only read on the first
      // visit to whichever tab gets there first.
      final provider = context.read<AppStateProvider>();
      provider.ensureAvFlowForCurrentConfig();
      // The estimate counts the boxes on the diagram, so the ones the config
      // names but has no block for — the PC, the doc cam, the DTP receiver
      // each DTP-to-HDMI run needs — have to be on it or the quote is for a
      // room without them. Drawing it here as well as on the AV Flow tab means
      // the number is right whichever tab was opened first. A no-op in a room
      // whose diagram has not been drawn yet.
      autoDrawRoutingFromConfig(provider);
    });
  }

  /// Which way round the captured image is rendered. Independent of the app's
  /// theme: a quote pasted into a document usually wants to be white whatever
  /// the person making it has the app set to, and sometimes has to match a
  /// dark deck instead.
  Brightness _captureBrightness = Brightness.light;

  /// The paper the image is printed on. Not [Colors.black] for the dark one —
  /// a pure black sheet with hairline table rules on it loses the rules.
  Color get _capturePaper => _captureBrightness == Brightness.dark
      ? const Color(0xFF16191D)
      : Colors.white;

  /// Renders the estimate to a PNG with the controls out of the way.
  Future<void> _screenshot(
    AppStateProvider provider, {
    required Brightness brightness,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    setState(() {
      _captureBrightness = brightness;
      _capturing = true;
    });
    // Two frames: one to lay the page out without the buttons, one to paint
    // it. Without the second the capture can catch the frame that still has
    // them.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;

    Uint8List? bytes;
    try {
      bytes = await captureBoundary(_sheetKey, pixelRatio: 2.0);
    } finally {
      // In a finally, because a page left permanently without its buttons is
      // a far worse outcome than a failed screenshot.
      if (mounted) setState(() => _capturing = false);
    }

    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not render the estimate to an image.'),
          backgroundColor: snackErrorFillOn(messenger),
        ),
      );
      return;
    }

    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save the cost estimate image',
      fileName: '${roomFileStem(provider, 'cost_estimate')}'
          '${brightness == Brightness.dark ? '_dark' : ''}.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
    try {
      await File(outputFile).writeAsBytes(bytes);
      showSavedSnackBar(
        messenger: messenger,
        theme: theme,
        provider: provider,
        message: 'Cost estimate image saved as ${path.basename(outputFile)}',
        savedPath: outputFile,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save the image: $e'),
          backgroundColor: snackErrorFillOn(messenger),
        ),
      );
    }
  }

  /// True when this room has priced equipment that no control block backs.
  ///
  /// Restricted to rooms that are AV-only or have no control devices at all,
  /// because in a finished room a box on the diagram without a block is
  /// usually deliberate — a display, a laptop input, a speaker — and prompting
  /// about those every visit is how a prompt becomes wallpaper.
  static bool _needsControlSide(AppStateProvider provider) {
    if (provider.avDevicesWithoutControl.isEmpty) return false;
    if (provider.isAvOnlyRoom) return true;
    return activeDeviceKeysIn(
      provider.roomConfig,
      provider.uiSchema.deviceCountMap,
    ).isEmpty;
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
    final cards = <Widget>[
              _header(context, provider, estimate, model),
              const SizedBox(height: 12),
              _equipmentCard(context, provider, estimate, model),
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
                  SizedBox(
                    width: 380,
                    child: _totalsCard(context, estimate, theme),
                  ),
                ],
              ),
    ];

    // --- the frame that gets photographed ---------------------------------
    //  Not the ListView. A ListView is a viewport, and a viewport is exactly
    //  as tall as the window however it is configured — shrinkWrap only sizes
    //  a list to its content when the incoming constraint is UNBOUNDED, and
    //  inside a tab body it never is. The capture came out cut off at the
    //  bottom of the screen because of it.
    //
    //  OverflowBox is what makes the height unbounded: it sizes itself to the
    //  tab and hands its child infinity, so the Column below lays out at its
    //  full natural height, the RepaintBoundary is that tall, and toImage gets
    //  the whole estimate. On screen it overruns for the two frames the
    //  capture takes, and nobody sees it.
    if (_capturing) {
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: RepaintBoundary(
            key: _sheetKey,
            child: Container(
              color: _capturePaper,
              child: Theme(
                data: ThemeData(
                  brightness: _captureBrightness,
                  useMaterial3: true,
                ),
                // Everything below asks this on the way past: the price boxes
                // print their figure instead of an input outline, and the
                // reset and delete icons print as empty space.
                child: PrintMode(
                  printing: true,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: cards,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      key: _sheetKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: cards,
      ),
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
            _CardHeading(
              title: 'Room Cost Estimate',
              titleStyle: theme.textTheme.titleLarge,
              actions: [
                // Every control drops out for the frame the screenshot
                // catches, so the image is the quote and nothing else.
                if (!_capturing) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.engineering, size: 18),
                    label: const Text('Labor rates'),
                    onPressed: () => showLaborRatesDialog(context, provider),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.price_change_outlined, size: 18),
                    label: const Text('Base costs'),
                    onPressed: () => showBaseCostsDialog(context, provider),
                  ),
                  // Two ways round, because the image lands in two kinds of
                  // document: white for a quote that gets printed or pasted
                  // into a Word file, dark to sit in a dark deck without a
                  // slab of white in the middle of it.
                  PopupMenuButton<Brightness>(
                    tooltip: 'Save the estimate as an image',
                    onSelected: (b) => _screenshot(provider, brightness: b),
                    itemBuilder: (ctx) => const [
                      PopupMenuItem(
                        value: Brightness.light,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.light_mode, size: 18),
                          title: Text('Light image'),
                        ),
                      ),
                      PopupMenuItem(
                        value: Brightness.dark,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.dark_mode, size: 18),
                          title: Text('Dark image'),
                        ),
                      ),
                    ],
                    child: IgnorePointer(
                      child: OutlinedButton.icon(
                        icon: const Icon(
                          Icons.photo_camera_outlined,
                          size: 18,
                        ),
                        label: const Text('Screenshot'),
                        onPressed: () {},
                      ),
                    ),
                  ),
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
                ] else
                  // The image needs a date on it: a quote nobody can tell the
                  // age of is a quote somebody quotes back at you next year.
                  Text(
                    reportTimestamp(),
                    style: theme.textTheme.bodySmall,
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
            // A budgeted room is the one that has gear on the diagram and no
            // control blocks behind it, and this is the page somebody is on
            // when they decide to go and build them. Offering it here rather
            // than only on the System tab saves the trip to a tab that is
            // switched off in exactly the room that needs this.
            if (!_capturing && _needsControlSide(provider)) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const BuildControlSideButton(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${provider.avDevicesWithoutControl.length} device'
                      '${provider.avDevicesWithoutControl.length == 1 ? '' : 's'} '
                      'on this estimate have no control block yet. This '
                      'creates one each, prefilled from the application '
                      'defaults and named in order, and flags any the module '
                      'library does not claim.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                // On the image these three are settings, not figures — the
                // tier and the tax rate both say themselves again down in the
                // totals. One line of prose instead of a button and two boxes.
                if (_capturing)
                  Text(
                    [
                      'Priced at '
                          '${kPricingTierLabels[provider.pricingTier] ?? ''}',
                      if (settings.taxPercent > 0)
                        '${settings.taxLabel} '
                            '${formatPercent(settings.taxPercent)}',
                    ].join('  ·  '),
                    style: theme.textTheme.bodySmall,
                  ),
                // Which of the catalog's two published prices this estimate is
                // costed from. On the page rather than only in App Config
                // because it is a question about THIS quote, and the answer
                // changes every figure below it.
                if (!_capturing) ...[
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
                ],
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
                            '${estimate.unpricedDevices == 1 ? ' has' : 's have'} '
                            'no price - the total below is short by whatever '
                            '${estimate.unpricedDevices == 1 ? 'it costs' : 'they cost'}.',
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

  /// What the equipment table is sorted by, and the four words it takes to
  /// change it. A menu rather than a row of chips because it sits in a card
  /// heading that already wraps on a laptop.
  Widget _sortMenu(BuildContext context, AppStateProvider provider) {
    final theme = Theme.of(context);
    final current = provider.avCost.equipmentSort;
    return PopupMenuButton<CostEquipmentSort>(
      tooltip: 'What order the equipment is listed in',
      initialValue: current,
      onSelected: provider.setAvCostEquipmentSort,
      itemBuilder: (_) => [
        for (final sort in CostEquipmentSort.values)
          PopupMenuItem(
            value: sort,
            child: Text(kCostEquipmentSortLabels[sort] ?? sort.name),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort, size: 16),
            const SizedBox(width: 6),
            Text(
              'Sort: ${kCostEquipmentSortLabels[current] ?? current.name}',
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }

  /// Who makes what is on a line, for the headings the maker sort draws.
  /// A line off a catalog entry nobody has filled the maker in on says so,
  /// rather than joining whoever sorts next to it.
  static String _makerOf(CostLine line) {
    final maker = line.manufacturer.trim();
    return maker.isEmpty ? 'No manufacturer on the catalog entry' : maker;
  }

  /// The rule and the name over one vendor's block of the equipment table.
  Widget _makerHeading(BuildContext context, String maker) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Row(
        children: [
          Text(
            maker,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(height: 1, color: theme.dividerColor)),
        ],
      ),
    );
  }

  // --- equipment -----------------------------------------------------------
  Widget _equipmentCard(
    BuildContext context,
    AppStateProvider provider,
    CostEstimate estimate,
    AvFlowModel model,
  ) {
    final theme = Theme.of(context);
    final currency = estimate.currency;
    final byMaker =
        provider.avCost.equipmentSort == CostEquipmentSort.manufacturer;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A HEADING THAT WRAPS, like every other card's. It was a Row
            // with an Expanded sentence in it, which held while the card had
            // two buttons on it; the sort picker was the third, and on a
            // laptop the row went over the edge of the card.
            _CardHeading(
              title: 'Equipment (${estimate.equipment.length} line'
                  '${estimate.equipment.length == 1 ? '' : 's'})',
              subtitle: 'counted off the signal flow diagram, plus anything '
                  'added here that is quoted without being drawn',
              actions: [
                // WHAT ORDER THE QUOTE IS IN. Kept with the estimate, not
                // with the window: an order is placed one vendor at a time,
                // and the person who sorted the quote that way wants the
                // screenshot and the workbook to agree with the screen.
                PrintHide(child: _sortMenu(context, provider)),
                // Two ways on, the same pair the "Other items" card offers:
                // off the catalog, so the price follows a revision; or a plain
                // line for the box that has no catalog entry and a figure
                // somebody was quoted over the phone.
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.playlist_add, size: 16),
                  label: const Text('Add from catalog'),
                  onPressed: () => _addExtraPart(context, provider,
                      kind: _ExtraPart.equipment),
                )),
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add line'),
                  onPressed: () => provider.addAvCostExtraEquipment(),
                )),
              ],
            ),
            const SizedBox(height: 8),
            _headerRow(context, _kEquipmentCols),
            const Divider(height: 12),
            if (estimate.equipment.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No devices on the AV diagram yet - place some on the '
                  'Signal Flow page and they appear here, or add a line for '
                  'something being quoted that nobody has drawn.',
                ),
              ),
            for (int i = 0; i < estimate.equipment.length; i++) ...[
              // ONE HEADING PER MAKER, while the table is sorted by one. The
              // Model column names the product, never who makes it, so a list
              // silently grouped by vendor would look like a list in no order
              // at all.
              if (byMaker &&
                  (i == 0 ||
                      _makerOf(estimate.equipment[i - 1]) !=
                          _makerOf(estimate.equipment[i])))
                _makerHeading(context, _makerOf(estimate.equipment[i])),
              Builder(
                builder: (context) {
                  final line = estimate.equipment[i];
                  // Lines added here keep an editable name and quantity and a
                  // way out; a device on the diagram takes both from the
                  // drawing, which is the whole point of counting them there.
                  final extra = provider.avCost.extraEquipment
                      .where((i) => i.id == line.key)
                      .firstOrNull;
                  // The catalog entry this row is priced from, or '' when it
                  // is not priced from one — which is what decides whether
                  // the library button adds a part or edits one.
                  final catalogPart = extra != null
                      ? extra.catalogModel.trim()
                      : (isCatalogSource(line.source) ? line.model.trim() : '');
                  return _stripe(
                    context,
                    i,
                    Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: _gridRow(_kEquipmentCols, [
                      // Device
                      extra == null
                          ? _CellText(line.description)
                          : LiveTextField(
                              fieldId: 'eqpdesc_${extra.id}',
                              initial: extra.description,
                              hint: 'e.g. Owner-furnished display',
                              onChanged: (v) =>
                                  provider.updateAvCostExtraEquipment(
                                extra.copyWith(description: v),
                              ),
                            ),
                      // Model
                      Text(
                        extra == null
                            ? (line.model.isEmpty ? '-' : line.model)
                            : [
                                if (line.model.isNotEmpty) line.model,
                                if (extra.spare)
                                  'spare'
                                else if (extra.noControl)
                                  'not in the config'
                                else
                                  'not on the diagram',
                              ].join(' · '),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.disabledColor,
                        ),
                      ),
                      // Qty: what the diagram counts, or the quantity typed
                      // on a line that is not drawn. Only the typed one can be
                      // nudged — the drawn count is the drawing's to say, and
                      // the row buys more of it through Spares.
                      extra == null
                          ? _CellText(
                              '×${trimNumber(line.drawnQty)}',
                              numeric: true,
                              stepper: true,
                            )
                          : _qtyStepper(
                              value: extra.qty,
                              what: extra.description.trim().isEmpty
                                  ? 'this line'
                                  : extra.description.trim(),
                              onChanged: (qty) =>
                                  provider.updateAvCostExtraEquipment(
                                extra.copyWith(qty: qty),
                              ),
                              field: LiveTextField(
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
                      // Spares. Only against a line the DIAGRAM counts: a
                      // quoted line already has an editable quantity of its
                      // own, and two boxes meaning the same thing on one row
                      // is how a number gets typed into the wrong one.
                      //
                      // The + and − beside it are how the quantity on a DRAWN
                      // line moves: the drawing says the room has three, and
                      // buying a fourth is a decision about the order rather
                      // than an edit to the room, so it lands here and the
                      // Total beside it follows.
                      extra == null
                          ? _qtyStepper(
                              value: line.spareQty,
                              what: line.description.trim().isEmpty
                                  ? 'this line'
                                  : line.description.trim(),
                              onChanged: (qty) =>
                                  provider.setAvEquipmentSpares(line.key, qty),
                              field: LiveTextField(
                                fieldId: 'eqpspare_${line.key}',
                                initial: line.spareQty == 0
                                    ? ''
                                    : trimNumber(line.spareQty),
                                hintIsValue: true,
                                numeric: true,
                                hint: '0',
                                onChanged: (v) => provider.setAvEquipmentSpares(
                                  line.key,
                                  double.tryParse(v) ?? 0,
                                ),
                              ),
                            )
                          : const _CellText(
                              '-',
                              numeric: true,
                              stepper: true,
                            ),
                      // Total
                      Text(
                        trimNumber(line.qty),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // Unit price. The box holds THIS ROOM'S price and
                      // nothing else. Showing the catalog figure in it made
                      // every line look like it had been quoted by hand, and
                      // left the box disagreeing with the row when the catalog
                      // or the base cost changed underneath it. Blank means
                      // "use whatever the row resolved to" — which the hint
                      // spells out.
                      LiveTextField(
                        fieldId: 'price_${line.key}',
                        initial: _roomPriceText(provider, line),
                        prefix: currency,
                        numeric: true,
                        hint: _resolvedPriceHint(line),
                        hintIsValue: true,
                        onChanged: (v) {
                          final parsed = double.tryParse(v);
                          provider.setAvCostPrice(
                            line.key,
                            v.trim().isEmpty ? null : (parsed ?? 0),
                          );
                        },
                      ),
                      // Extended
                      Text(
                        formatMoney(line.total, currency),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // Price from
                      Text(
                        kPriceSourceLabels[line.source] ?? '',
                        style: TextStyle(
                          fontSize: 11,
                          color: line.source == PriceSource.none
                              ? theme.colorScheme.error
                              : theme.disabledColor,
                        ),
                      ),
                      // The row's buttons, as ONE cell: the grid reserves the
                      // column, and what goes in it is this row's business.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _configFlag(
                            context,
                            provider,
                            line,
                            model,
                            extra: extra,
                          ),
                          // WRONG BOX ON THE QUOTE. The commonest edit an
                          // estimate gets and the one that had to be made
                          // somewhere else: a display comes back at the wrong
                          // size, a switcher is one input short, the stakeholder
                          // asks what the cheaper matrix costs. Swapping here
                          // puts the new product under the drawn box — its
                          // connectors, its rack height, its power and its
                          // price — so the diagram, the rack and the total all
                          // move together instead of the quote quietly
                          // disagreeing with the drawing.
                          KeyedSubtree(
                            key: ValueKey('eqp_swap_${line.key}'),
                            child: avRowIcon(
                              Icons.find_replace,
                              extra != null
                                  ? 'Quote a different part on this line'
                                  : line.qty > 1
                                  ? 'Replace all '
                                        '${line.qty.toStringAsFixed(0)} with '
                                        'another model'
                                  : 'Replace this with another model',
                              () => _swapUnit(
                                context,
                                provider,
                                line,
                                model,
                                extra: extra,
                              ),
                            ),
                          ),
                          // Anything on this row can become a catalog entry —
                          // the box on the drawing as readily as the line
                          // somebody typed — and a row that already IS one
                          // opens it for editing instead. A price rise, a part
                          // number somebody finally found, a rack height that
                          // was guessed: all of it gets noticed while looking
                          // at a quote, and going to the Catalog tab to fix it
                          // means losing your place.
                          avRowIcon(
                            catalogPart.isEmpty
                                ? Icons.library_add_outlined
                                : Icons.edit_note,
                            catalogPart.isEmpty
                                ? 'Add this line to the device catalog'
                                : 'Edit $catalogPart in the catalog',
                            catalogPart.isNotEmpty
                                ? () => _addToCatalog(
                                    context,
                                    provider,
                                    suggestedModel: catalogPart,
                                  )
                                : extra != null
                                ? () => _addLineToCatalog(
                                    context,
                                    provider,
                                    extra,
                                    kind: _ExtraPart.equipment,
                                  )
                                : () => _addToCatalog(
                                    context,
                                    provider,
                                    suggestedModel: line.model.isNotEmpty
                                        ? line.model
                                        : line.description,
                                    partNumber: line.partNumber,
                                    category: line.category,
                                    price:
                                        provider.avCost
                                                .priceOverrides[line.key] ??
                                            line.unitPrice,
                                    priceKey: line.key,
                                    // A device with no model has nothing for
                                    // the estimate to match the new entry
                                    // against.
                                    unlinkedNote: line.model.isEmpty
                                        ? 'This device has no model, so the '
                                              'row cannot pick the entry up on '
                                              'its own - set the model on the '
                                              'Devices tab to the name below '
                                              'and it will.'
                                        : null,
                                  ),
                          ),
                          if (extra == null)
                            avRowIcon(
                              Icons.restart_alt,
                              'Back to the catalog price',
                              line.source == PriceSource.override
                                  ? () =>
                                      provider.setAvCostPrice(line.key, null)
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
                    ], rowKey: ValueKey('gridrow_eqp_${line.key}')),
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
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add hardware'),
                  onPressed: () => _addExtraPart(context, provider,
                      kind: _ExtraPart.hardware),
                )),
              ],
            ),
            if (estimate.hardware.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'None yet. A rack of gear also has blanks, vents and a shelf '
                  'or two in it - add them on the Racks tab, or add one '
                  'here when it is bought without going in a frame.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...[
              const SizedBox(height: 8),
              _headerRow(context, _kHardwareCols),
              const Divider(height: 12),
              for (final (i, line) in estimate.hardware.indexed)
                Builder(
                  builder: (context) {
                    // Lines added here (rather than placed in a frame) keep an
                    // editable quantity and a way out; a racked one takes both
                    // from the elevation.
                    final extra = provider.avCost.extraHardware
                        .where((i) => i.id == line.key)
                        .firstOrNull;
                    // The parts-list entry this row is priced from, or '' —
                    // see the equipment table's row for what it decides.
                    final catalogPart = extra != null
                        ? extra.catalogModel.trim()
                        : (isCatalogSource(line.source)
                              ? (line.model.trim().isNotEmpty
                                    ? line.model.trim()
                                    : line.description.trim())
                              : '');
                    return _stripe(
                      context,
                      i,
                      Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: _gridRow(_kHardwareCols, [
                      // Item
                      Row(
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
                      // Kind
                      Text(
                        extra == null
                            ? (line.category.isEmpty ? '-' : line.category)
                            : '${line.category.isEmpty ? 'Hardware'
                                  : line.category} · not racked',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.disabledColor,
                        ),
                      ),
                      // Qty
                      extra == null
                          ? _CellText(
                              '×${line.qty.toStringAsFixed(0)}',
                              numeric: true,
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
                      // Unit price
                      LiveTextField(
                        fieldId: 'price_${line.key}',
                        initial: _roomPriceText(provider, line),
                        prefix: currency,
                        numeric: true,
                        hint: _resolvedPriceHint(line),
                        hintIsValue: true,
                        onChanged: (v) {
                          final parsed = double.tryParse(v);
                          provider.setAvCostPrice(
                            line.key,
                            v.trim().isEmpty ? null : (parsed ?? 0),
                          );
                        },
                      ),
                      // Extended
                      Text(
                        formatMoney(line.total, currency),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // Price from
                      Text(
                        kPriceSourceLabels[line.source] ?? '',
                        style: TextStyle(
                          fontSize: 11,
                          color: line.source == PriceSource.none
                              ? theme.colorScheme.error
                              : theme.disabledColor,
                        ),
                      ),
                      // The row's buttons, as one cell.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // THE WRONG PLATE. A vent where a blank should be, a
                          // 1U shelf that has to be 2U, a plate from the maker
                          // the stakeholder will not have: the same edit the
                          // equipment table has, made where the money is. It
                          // reaches every item in the frames the row counts,
                          // so the elevation and the quote move together.
                          KeyedSubtree(
                            key: ValueKey('hw_swap_${line.key}'),
                            child: avRowIcon(
                              Icons.find_replace,
                              extra != null
                                  ? 'Quote a different part on this line'
                                  : line.qty > 1
                                  ? 'Replace all '
                                        '${line.qty.toStringAsFixed(0)} in the '
                                        'racks with another part'
                                  : 'Replace this with another part',
                              () => _swapHardware(
                                context,
                                provider,
                                line,
                                extra: extra,
                              ),
                            ),
                          ),
                          // Placed hardware is promoted the same way a typed
                          // line is, and the items in the frames are stamped
                          // with the new entry so the elevation and the quote
                          // agree.
                          avRowIcon(
                            catalogPart.isEmpty
                                ? Icons.library_add_outlined
                                : Icons.edit_note,
                            catalogPart.isEmpty
                                ? 'Add this line to the parts list'
                                : 'Edit $catalogPart in the parts list',
                            catalogPart.isNotEmpty
                                ? () => _addToCatalog(
                                    context,
                                    provider,
                                    suggestedModel: catalogPart,
                                  )
                                : extra != null
                                ? () => _addLineToCatalog(
                                    context,
                                    provider,
                                    extra,
                                    kind: _ExtraPart.hardware,
                                  )
                                : () => _addToCatalog(
                                    context,
                                    provider,
                                    suggestedModel: line.description,
                                    partNumber: line.partNumber,
                                    category: line.category.isEmpty
                                        ? kCategoryRackHardware
                                        : line.category,
                                    rackUnits: provider.avRackItems
                                            .where((i) =>
                                                i.label.trim().toLowerCase() ==
                                                line.description
                                                    .trim()
                                                    .toLowerCase())
                                            .firstOrNull
                                            ?.rackUnits ??
                                        1,
                                    price: provider.avCost
                                            .priceOverrides[line.key] ??
                                        line.unitPrice,
                                    rackItemLabel: line.description,
                                    priceKey: line.key,
                                  ),
                          ),
                          if (extra == null)
                            avRowIcon(
                              Icons.restart_alt,
                              'Back to the parts list price',
                              line.source == PriceSource.override
                                  ? () =>
                                      provider.setAvCostPrice(line.key, null)
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
                    ], rowKey: ValueKey('gridrow_hw_${line.key}')),
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

    // The runs the table actually draws a row for. Held here rather than
    // filtered inside the list, so the zebra counts rows on the sheet rather
    // than entries it walked past — a stripe that skipped an entry would put
    // two washed rows together and stop reading as an alternation at all.
    final countedCabling = [
      for (final line in estimate.cabling)
        if (cableSignalOfKey(line.key) != null) line,
    ];

    // Types with runs on the diagram, plus any that only have spares — a
    // spare for a type you didn't draw is still cable somebody is buying.
    final types = <SignalType>{
      ...drawn.keys,
      for (final key in settings.cableSpares.keys)
        if (cableSignalOfKey(key) != null) cableSignalOfKey(key)!,
    }.toList()..sort((a, b) => a.index.compareTo(b.index));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardHeading(
              title: 'Cabling',
              subtitle: 'one lead per run on the signal flow diagram',
              actions: [
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add cable'),
                  onPressed: () => _addExtraPart(context, provider,
                      kind: _ExtraPart.cable),
                )),
                // The switch and the word it belongs to are one control, so
                // they wrap as one rather than ending up on separate lines.
                PrintHide(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: settings.includeCabling,
                        onChanged: (v) => provider.setAvCostIncludeCabling(v),
                      ),
                      const SizedBox(width: 4),
                      const Text('Include', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
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
                  'run on the drawing - a spool, a bag of patch leads - '
                  'goes in with "Add cable".',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else ...[
              const SizedBox(height: 8),
              _headerRow(context, _kCablingCols),
              const Divider(height: 12),
              // ONE ROW PER LINE THE ESTIMATE MADE, not one per signal type.
              // A room whose HDMI is stocked at 3 ft, 6 ft and 25 ft buys
              // three different things at three different prices, and a single
              // row for "HDMI" is a row that is wrong in both directions at
              // once. A type with one entry (or none) still comes out as the
              // one row it always did.
              for (final (i, line) in countedCabling.indexed)
                  Builder(
                    builder: (context) {
                      final signal = cableSignalOfKey(line.key)!;
                      // EVERY LENGTH GETS ITS OWN SPARES BOX. A length is
                      // what gets ordered — two spare 3 ft patch leads and
                      // two spare 50 ft runs are two decisions at two prices
                      // — so one box against "HDMI" could only ever record
                      // one of them.
                      final spares = provider.avCableSpares(line.key);
                      final runs = line.qty - spares;
                      final catalog =
                          library.templateForModel(line.model) ??
                              library.cableForSignal(signal);
                      return _stripe(
                        context,
                        i,
                        Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: _gridRow(_kCablingCols, [
                          // Cable type
                          Row(
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
                                  line.description,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                          // Drawn
                          Text(
                            trimNumber(runs),
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 13),
                          ),
                          // Spares
                          LiveTextField(
                            fieldId: 'spare_${line.key}',
                            initial: spares == 0 ? '' : trimNumber(spares),
                            numeric: true,
                            hint: '0',
                            hintIsValue: true,
                            onChanged: (v) => provider.setAvCableSpares(
                              line.key,
                              double.tryParse(v) ?? 0,
                            ),
                          ),
                          // Total
                          Text(
                            trimNumber(line.qty),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // Unit price
                          LiveTextField(
                            fieldId: 'cableprice_${line.key}',
                            initial: _roomPriceText(provider, line),
                            prefix: currency,
                            numeric: true,
                            hint: _resolvedPriceHint(line),
                            hintIsValue: true,
                            onChanged: (v) {
                              final parsed = double.tryParse(v);
                              provider.setAvCostPrice(
                                line.key,
                                v.trim().isEmpty ? null : (parsed ?? 0),
                              );
                            },
                          ),
                          // Extended
                          Text(
                            formatMoney(line.total, currency),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // The row's buttons, as one cell.
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // WHICH LEAD THIS LENGTH IS BOUGHT AS. The
                              // estimate picks the shortest stock lead that
                              // reaches the run, which is right until the job
                              // is plenum, or the stakeholder takes one brand
                              // only. The runs and the spares stay counted off
                              // the drawing — only the product changes.
                              KeyedSubtree(
                                key: ValueKey('cbl_swap_${line.key}'),
                                child: avRowIcon(
                                  Icons.find_replace,
                                  catalog == null
                                      ? 'Buy this run as a catalog cable'
                                      : 'Buy this run as a different cable',
                                  () => _swapCable(
                                    context,
                                    provider,
                                    line,
                                    signal: signal,
                                  ),
                                ),
                              ),
                              // A counted run is priced off the cable TYPE.
                              // When that type has an entry there is nothing
                              // to promote; when it has none, this is where
                              // the room's cable finally gets one, tagged with
                              // the signal so every future room's runs price
                              // themselves off it.
                              avRowIcon(
                                catalog == null
                                    ? Icons.library_add_outlined
                                    : Icons.edit_note,
                                catalog == null
                                    ? 'Add this cable type to the catalog'
                                    : 'Edit ${catalog.model} in the catalog',
                                catalog != null
                                    ? () => _addToCatalog(
                                          context,
                                          provider,
                                          suggestedModel: catalog.model,
                                        )
                                    : () => _addToCatalog(
                                          context,
                                          provider,
                                          suggestedModel:
                                              '${kSignalLabels[signal] ?? signal.name} cable',
                                          category: kCategoryCable,
                                          cableSignal: signal,
                                          price: provider.avCost
                                                  .priceOverrides[line.key] ??
                                              line.unitPrice,
                                          priceKey: line.key,
                                        ),
                              ),
                              // The shop's typical figure for a lead of this
                              // type and length, on the shared card rather
                              // than on this room — see [_setCableBaseCost].
                              avRowIcon(
                                Icons.price_change_outlined,
                                line.source == PriceSource.baseCost
                                    ? 'Priced off the base-cost card - edit '
                                          'that figure'
                                    : 'Set a base cost for this cable length',
                                () => _setCableBaseCost(
                                  context,
                                  provider,
                                  signal: signal,
                                  lengthFt: (catalog?.cableLengthFt ?? 0) > 0
                                      ? catalog!.cableLengthFt
                                      : cableKeyParts(line.key).lengthFt,
                                ),
                              ),
                              avRowIcon(
                                Icons.restart_alt,
                                'Back to the catalog price',
                                line.source == PriceSource.override
                                    ? () =>
                                        provider.setAvCostPrice(line.key, null)
                                    : null,
                              ),
                            ],
                          ),
                        ], rowKey: ValueKey('gridrow_cbl_${line.key}')),
                      ),
                      );
                    },
                  ),
              // Cable bought for the job that no run on the diagram accounts
              // for. Listed under the counted runs so the two are read
              // together, and labeled so nobody looks for it on the drawing.
              for (final (i, item) in settings.extraCables.indexed)
                Builder(
                  builder: (context) {
                    final line = estimate.cabling
                        .where((l) => l.key == item.id)
                        .firstOrNull;
                    // Carries on from the counted runs above rather than
                    // restarting: the two loops are one table to read.
                    return _stripe(
                      context,
                      countedCabling.length + i,
                      Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: _gridRow(_kCablingCols, [
                          // Cable type
                          Row(
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
                          // Drawn — none of it is, which is the point.
                          Text(
                            'misc',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.disabledColor,
                            ),
                          ),
                          // Spares column: for a quoted line this IS the
                          // quantity, and it is the only box on the row that
                          // can hold one.
                          LiveTextField(
                            fieldId: 'cblqty_${item.id}',
                            initial: trimNumber(item.qty),
                            numeric: true,
                            onChanged: (v) => provider.updateAvCostExtraCable(
                              item.copyWith(qty: double.tryParse(v) ?? 0),
                            ),
                          ),
                          // Total
                          Text(
                            trimNumber(item.qty),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // Unit price
                          LiveTextField(
                            fieldId: 'cblprice_${item.id}',
                            initial:
                                line == null ? '' : _roomPriceText(provider, line),
                            prefix: currency,
                            numeric: true,
                            hint: line == null || line.unitPrice <= 0
                                ? 'unpriced'
                                : trimNumber(line.unitPrice),
                            hintIsValue: true,
                            onChanged: (v) {
                              final parsed = double.tryParse(v);
                              provider.setAvCostPrice(
                                item.id,
                                v.trim().isEmpty ? null : (parsed ?? 0),
                              );
                            },
                          ),
                          // Extended
                          Text(
                            formatMoney(line?.total ?? 0, currency),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // The row's buttons. A miscellaneous line is not a
                          // length of anything, so it has no base cost to set
                          // — the empty slot keeps the column square.
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              avRowIcon(
                                item.catalogModel.isEmpty
                                    ? Icons.library_add_outlined
                                    : Icons.edit_note,
                                item.catalogModel.isEmpty
                                    ? 'Add this line to the device catalog'
                                    : 'Edit ${item.catalogModel} in the '
                                          'catalog',
                                item.catalogModel.isNotEmpty
                                    ? () => _addToCatalog(
                                          context,
                                          provider,
                                          suggestedModel: item.catalogModel,
                                        )
                                    : () => _addLineToCatalog(
                                          context,
                                          provider,
                                          item,
                                          kind: _ExtraPart.cable,
                                        ),
                              ),
                              KeyedSubtree(
                                key: ValueKey('cbl_swap_${item.id}'),
                                child: avRowIcon(
                                  Icons.find_replace,
                                  'Quote a different cable on this line',
                                  () => _swapExtraLine(
                                    context,
                                    provider,
                                    item,
                                    kind: _ExtraPart.cable,
                                  ),
                                ),
                              ),
                              const SizedBox(width: kRowIconWidth),
                              avRowIcon(
                                Icons.delete_outline,
                                'Remove this line',
                                () =>
                                    provider.removeAvCostExtraCable(item.id),
                                danger: true,
                              ),
                            ],
                          ),
                        ], rowKey: ValueKey('gridrow_cbl_${item.id}')),
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
                        'A box on the quote that is not on the diagram - '
                            'something somebody else is installing, a spare, '
                            'or a stand-in for a decision not yet made. It is '
                            'quoted with the drawn devices and marked as not '
                            'on the diagram. Pick nothing and it goes on as a '
                            'plain line at whatever price you type.',
                      _ExtraPart.cable =>
                        'Cable that is not a run on the diagram - a spool, '
                            'a bag of patch leads, a drop somebody else is '
                            'pulling. Quoted with the counted runs and '
                            'marked as miscellaneous.',
                      _ExtraPart.hardware =>
                        'Hardware bought for the job without going into a '
                            'frame here. Quoted with the racked hardware and '
                            'marked as not racked.',
                      _ExtraPart.misc =>
                        'A billable line off the catalog - a licence, a '
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
                        ? 'Nothing picked - it goes on by name, and you type '
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

  // --- is this line in the room config? ------------------------------------

  /// The control block behind an equipment line, or '' when there is none.
  ///
  /// A device drawn from the config carries the config's own section key as
  /// its node id, so the two line up without anything being stored to link
  /// them. A line typed on this page, and a box added to the canvas by hand,
  /// have no block at all.
  String _configKeyFor(
    AppStateProvider provider,
    CostLine line,
    AvFlowModel model,
  ) {
    final group = groupDevices(model).where((g) => g.key == line.key).firstOrNull;
    if (group == null) return '';
    final configured = activeDeviceKeysIn(
      provider.roomConfig,
      provider.uiSchema.deviceCountMap,
    ).toSet();
    for (final node in group.nodes) {
      if (configured.contains(node.id)) return node.id;
    }
    return '';
  }

  /// The orange flag: quoted, but the room config has never heard of it.
  ///
  /// THE GAP THIS CLOSES. The estimate is where a room gets specified — parts
  /// are picked here with quantities and a total — and the control side is
  /// built weeks later from whatever somebody remembers. A line that never
  /// makes it into a device block is a box that gets ordered, delivered,
  /// racked and then has nothing to drive it, and the first anybody knows is
  /// at commissioning.
  ///
  /// Three states, one slot:
  ///
  ///   * IN THE CONFIG — a quiet tick naming the block. Nothing to do.
  ///   * A SPARE — bought for the shelf, never installed here at all.
  ///   * NOT DRIVEN BY THIS SYSTEM — in the room and on the diagram, and the
  ///     processor has no business talking to it: the building's network
  ///     switch, somebody else's codec, an owner-furnished display, a passive
  ///     splitter. It stays exactly as selectable, cabled and priced as it
  ///     was; it just stops being reported as missing.
  ///   * NONE OF THOSE — orange, with the button that fixes it.
  ///
  /// The last two are the escape hatches that keep the flag meaningful. Every
  /// room has boxes whose honest answer to "why is this not in the config" is
  /// "it never will be", and a warning nobody can clear is a warning everybody
  /// learns to ignore.
  Widget _configFlag(
    BuildContext context,
    AppStateProvider provider,
    CostLine line,
    AvFlowModel model, {
    CostLineItem? extra,
  }) {
    // The key is on the SLOT rather than on whatever is in it, so the state
    // of this cell can be read whichever of the three it is showing.
    final slot = ValueKey('cfgflag_${line.key}');

    // In the capture it is an empty slot like every other row button — a
    // photograph of a quote does not carry the app's to-do list.
    if (PrintMode.of(context)) {
      return KeyedSubtree(
        key: slot,
        child: const SizedBox(width: kRowIconWidth, height: 34),
      );
    }
    final theme = Theme.of(context);
    final spare = extra?.spare ?? false;
    final configKey = extra != null ? '' : _configKeyFor(provider, line, model);
    // Every box behind a drawn line, so the choice can be made once for a row
    // of quantity three.
    final nodes = extra != null
        ? const <AvNode>[]
        : (groupDevices(model).where((g) => g.key == line.key).firstOrNull
                  ?.nodes ??
              const <AvNode>[]);
    // Said about the boxes when the line is drawn, and about the line itself
    // when it is not. A line quoted here can be a box the room has and this
    // system does not drive just as easily as a drawn one can — an
    // owner-furnished display is usually quoted before anybody draws it.
    final uncontrolled = extra != null
        ? (extra.noControl ||
              provider.avModelNeverControlled(extra.catalogModel))
        : (nodes.isNotEmpty &&
              nodes.every((n) => provider.avNodeIsUncontrolled(n)));

    // The CATALOG's verdict, on its own. [uncontrolled] above folds it
    // together with this room's own exclusion, which is right for the icon and
    // wrong for the menu: "this box is not ours to drive" and "no example of
    // this product is ever driven" are two decisions at two scopes, and the
    // menu has to offer each of them in its own state.
    final catalogModel = extra != null ? extra.catalogModel : line.model;
    final neverControlled = provider.avModelNeverControlled(catalogModel);

    if (configKey.isNotEmpty) {
      return KeyedSubtree(
        key: slot,
        child: avRowIcon(
          Icons.check_circle_outline,
          'In the room config as $configKey',
          null,
        ),
      );
    }

    // Pinned to the width one row icon takes. A PopupMenuButton lays itself
    // out at the 48-pixel minimum tap target whatever it is told, and the
    // caption row reserves these by hand — eight pixels of disagreement here
    // walked every caption on the row out of place.
    return SizedBox(
      key: slot,
      width: kRowIconWidth,
      child: Tooltip(
      message: spare
          ? 'A spare - quoted, and deliberately not part of the room config'
          : uncontrolled
          ? 'In the room, and not driven by this control system'
          : 'Not in the room config. The processor has nothing to drive it.',
      child: PopupMenuButton<String>(
        icon: Icon(
          spare
              ? Icons.inventory_2_outlined
              : uncontrolled
              ? Icons.link_off
              : Icons.flag,
          size: 18,
          // Orange rather than red: this is a thing to do, not a thing that is
          // broken. A quote written before the control side exists is the
          // normal case, and half these rows are legitimately flagged all the
          // way to the day somebody builds it.
          color: spare || uncontrolled
              ? theme.disabledColor
              : Colors.orange.shade700,
        ),
        padding: EdgeInsets.zero,
        // These size the MENU, not the button — the button is pinned by the
        // SizedBox above. Wide enough for the two lines each choice needs to
        // explain itself, and no wider than a dialog.
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 460),
        itemBuilder: (ctx) => [
          PopupMenuItem(
            value: 'add',
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.playlist_add_check, size: 18),
              title: Text('Add to the room config'),
              subtitle: Text(
                'Creates the device block for its family, with this room’s '
                'defaults and the driver that claims the model.',
              ),
            ),
          ),
          PopupMenuItem(
            value: 'nocontrol',
            enabled: extra != null || nodes.isNotEmpty,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                uncontrolled ? Icons.link : Icons.link_off,
                size: 18,
              ),
              title: Text(
                uncontrolled
                    ? 'Driven by this system after all'
                    : 'Not part of the room config',
              ),
              subtitle: Text(
                uncontrolled
                    ? 'Put it back on the list of devices the config is '
                          'missing.'
                    : 'The building’s switch, somebody else’s codec, an '
                          'owner-furnished display. It stays on the quote, and '
                          'on the diagram if it is drawn - it just stops being '
                          'reported as missing a device block.',
              ),
            ),
          ),
          PopupMenuItem(
            value: 'nevercontrol',
            enabled: catalogModel.trim().isNotEmpty,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                neverControlled ? Icons.settings_remote : Icons.block,
                size: 18,
              ),
              title: Text(
                neverControlled
                    ? 'This product does need a module'
                    : 'This product never needs a module',
              ),
              subtitle: Text(
                catalogModel.trim().isEmpty
                    ? 'Only a line with a catalog model can be marked - add '
                          'it to the catalog first.'
                    : neverControlled
                    ? 'Saved to the catalog: every room that draws a '
                          '$catalogModel starts reporting it again when it '
                          'has no driver.'
                    // Said plainly, because it is the one choice on this menu
                    // that reaches outside the room in front of you.
                    : 'A passive splitter, a plate, a USB stick - nothing can '
                          'drive it anywhere. Saved to the CATALOG, so every '
                          'room that draws a $catalogModel stops asking for a '
                          'module, not just this one.',
              ),
            ),
          ),
          PopupMenuItem(
            value: 'spare',
            enabled: extra != null,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                spare ? Icons.inventory_2 : Icons.inventory_2_outlined,
                size: 18,
              ),
              title: Text(spare ? 'Not a spare' : 'Mark as a spare'),
              subtitle: Text(
                extra == null
                    ? 'A box on the diagram is in the room, so it cannot be a '
                          'shelf spare.'
                    : 'Quoted for the shelf. It keeps its place on the '
                          'estimate and stops being flagged.',
              ),
            ),
          ),
        ],
        onSelected: (choice) async {
          if (choice == 'nevercontrol') {
            final messenger = ScaffoldMessenger.of(context);
            final result = await provider.setModelNeverControlled(
              catalogModel,
              !neverControlled,
            );
            messenger.showSnackBar(
              SnackBar(
                content: Text(result.message),
                backgroundColor: result.ok ? null : snackErrorFillOn(messenger),
              ),
            );
            return;
          }
          if (choice == 'spare' && extra != null) {
            provider.updateAvCostExtraEquipment(
              extra.copyWith(spare: !extra.spare),
            );
            return;
          }
          if (choice == 'nocontrol' && extra != null) {
            provider.updateAvCostExtraEquipment(
              extra.copyWith(noControl: !extra.noControl),
            );
            return;
          }
          if (choice == 'nocontrol') {
            // Every box behind the row, and the first press records the undo
            // snapshot the rest ride on — the same bargain the swap makes.
            var first = true;
            for (final node in nodes) {
              provider.updateAvNode(
                node.copyWith(excludeFromControl: !uncontrolled),
                recordUndo: first,
              );
              first = false;
            }
            return;
          }
          _addLineToConfig(context, provider, line, model, extra: extra);
        },
      ),
      ),
    );
  }

  /// Gives one equipment line a device block on the control side.
  ///
  /// Two routes in, one destination, because the two kinds of line are at
  /// different distances from being a device:
  ///
  ///   * A BOX ON THE DIAGRAM is already a device; it just has no block. The
  ///     room's own prefill builds one — right family, this app's defaults for
  ///     that family, the driver that claims the model — and re-keys the node
  ///     onto it so the drawing and the config are one device rather than two
  ///     records of it.
  ///   * A LINE TYPED HERE is a price, not a device. It becomes boxes on the
  ///     diagram first (one per unit, carrying any price typed on it), and
  ///     those go through the same prefill. The cost line goes, because the
  ///     diagram is priced and leaving both would quote the room twice.
  ///
  /// A hand-typed line with no catalog model cannot make the trip — there is
  /// nothing to build a device out of — and says so instead of half-doing it.
  Future<void> _addLineToConfig(
    BuildContext context,
    AppStateProvider provider,
    CostLine line,
    AvFlowModel model, {
    CostLineItem? extra,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final label = line.model.trim().isEmpty ? line.description : line.model;

    var nodeIds = <String>[];
    if (extra != null) {
      if (extra.catalogModel.trim().isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '"${line.description}" was typed by hand, so there is no part to '
              'build a device from. Add it to the catalog first - the '
              'library button on this row - and it can go in.',
            ),
            duration: const Duration(seconds: 7),
          ),
        );
        return;
      }
      final added = provider.promoteAvCostEquipmentToDiagram(
        extra.id,
        at: const Offset(40, 60),
      );
      if (added.isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Could not put $label on the diagram.'),
          ),
        );
        return;
      }
      nodeIds = [for (final n in added) n.id];
    } else {
      final group =
          groupDevices(model).where((g) => g.key == line.key).firstOrNull;
      if (group == null) return;
      nodeIds = [for (final n in group.nodes) n.id];
    }

    final plan = planControlSide(provider, nodeIds: nodeIds);
    if (plan.creatable.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            plan.unplaceable.isEmpty
                ? '$label is already in the room config.'
                : 'No device family fits $label, so there is nowhere to put a '
                      'block for it. The Wizard tab is where families are '
                      'turned on.',
          ),
          duration: const Duration(seconds: 7),
        ),
      );
      return;
    }

    final result = applyControlSide(provider, plan);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          [
            '${result.created} device block'
                '${result.created == 1 ? '' : 's'} created '
                '(${result.sectionKeys.join(', ')})',
            if (result.withoutModule > 0)
              '${result.withoutModule} of them with no python module - the '
                  'Devices tab shows those in red',
            'fill in the address on the Devices tab',
          ].join('. '),
        ),
        duration: const Duration(seconds: 7),
      ),
    );
  }

  // --- a shop price for a length of cable ----------------------------------

  /// Types the shop's own figure for one length of one cable type onto the
  /// base-cost card.
  ///
  /// CABLE IS THE HOLE IN EVERY EARLY ESTIMATE. The runs are counted off the
  /// diagram exactly and then priced at nothing, because the catalog ships
  /// made-up leads for a handful of types while a real order is "a 25 ft HDMI
  /// and a 50 ft HDMI". The only answer before this was to type a price on the
  /// row — but that is a fact about the shop's supplier, not about this room,
  /// so it was retyped on every job and drifted between them.
  ///
  /// This writes it where a typical price belongs: `base_costs.json`, beside
  /// the device figures, read by every room. The row's own price box still
  /// wins for the job that was quoted something different.
  Future<void> _setCableBaseCost(
    BuildContext context,
    AppStateProvider provider, {
    required SignalType signal,
    required double lengthFt,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final signalName = kSignalLabels[signal] ?? signal.name;
    final category = cableBaseCategory(signalName, lengthFt);
    final existing = provider.baseCosts.byCategory(category);
    final msrp = TextEditingController(
      text: existing == null || existing.price == 0
          ? ''
          : trimNumber(existing.price),
    );
    final edu = TextEditingController(
      text: existing == null || existing.educationPrice == 0
          ? ''
          : trimNumber(existing.educationPrice),
    );
    final notes = TextEditingController(text: existing?.notes ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Base cost for $category'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                lengthFt > 0
                    ? 'What a ${formatCableLength(lengthFt)} $signalName lead '
                          'typically costs. Saved to the base-cost card, so '
                          'every room prices this length off it - not just '
                          'this one.'
                    : 'What a $signalName lead typically costs, for any '
                          'length with no figure of its own. Saved to the '
                          'base-cost card, so every room reads it.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('cable_base_msrp'),
                      controller: msrp,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'List price (MSRP)',
                        prefixText: provider.avCost.currency,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('cable_base_edu'),
                      controller: edu,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Education price',
                        prefixText: provider.avCost.currency,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: notes,
                decoration: const InputDecoration(
                  labelText: 'What this figure assumes',
                  hintText: 'e.g. plenum, terminated both ends',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'A tier left blank falls back to the other one and the line '
                'says so. Both blank removes the figure. A price typed on this '
                'room still wins over it.',
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
            key: const ValueKey('cable_base_save'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save to the card'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final list = double.tryParse(msrp.text.trim()) ?? 0;
    final education = double.tryParse(edu.text.trim()) ?? 0;
    if (list <= 0 && education <= 0) {
      provider.baseCosts.remove(category);
    } else {
      provider.baseCosts.upsert(
        BaseCost(
          category: category,
          price: list,
          educationPrice: education,
          notes: notes.text.trim(),
        ),
      );
    }
    provider.baseCostsChanged();
    final saved = await provider.saveBaseCosts();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved.isEmpty
              ? 'Could not write the base-cost file - the figure is in memory '
                    'for this session only.'
              : list <= 0 && education <= 0
              ? '$category removed from the base-cost card.'
              : '$category saved to the base-cost card. Every room prices '
                    'this length off it until the catalog has an entry.',
        ),
      ),
    );
  }

  // --- swapping the product on a line --------------------------------------

  /// Replaces the part quoted on one equipment line with another catalog
  /// model, everywhere the room records it.
  ///
  /// The estimate is where the wrong box usually gets noticed — the total is
  /// what somebody looks at, and "that display is too dear" is a pricing
  /// sentence. Until now the fix lived on the Signal Flow tab: find the box on
  /// the canvas, open it, swap it, come back. So people retyped a price over
  /// the row instead, and the quote said one product while the drawing,
  /// the rack elevation and the cable schedule said another.
  ///
  /// ONE SWAP, FOUR PLACES. A model is not a fact about the estimate, it is a
  /// fact about the room, and every view of the room has to agree:
  ///
  ///   * THE COST LINE reprices off the new entry.
  ///   * THE SIGNAL FLOW gets the new product under every box the line counts
  ///     — connectors, rack height, power and heat — with the runs already
  ///     drawn carried onto the matching connectors ([applyModelSwap]).
  ///   * THE CABLING SCHEMATIC follows, because it is built from the flow
  ///     rather than stored: the runs it draws are the runs that survived.
  ///   * THE CONTROL SIDE — the config block the box came from — gets the
  ///     model, and the Python module that claims it. A drawing that says
  ///     IN1804 over a config block still holding the SW4's driver is a room
  ///     that gets built one way and commissioned another.
  ///
  /// Either way the room price typed on the old line goes. A figure negotiated
  /// for a DTP CrossPoint 84 is not the price of a 108, and carrying it across
  /// would leave the new product silently quoted at the old product's price —
  /// the one mistake this button exists to stop.
  Future<void> _swapUnit(
    BuildContext context,
    AppStateProvider provider,
    CostLine line,
    AvFlowModel model, {
    CostLineItem? extra,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    // The boxes on the drawing this row counts. Regrouped rather than carried
    // on the line: the estimate reduces a group to a quantity, and a swap has
    // to reach every device behind it.
    final group = extra == null
        ? groupDevices(model).where((g) => g.key == line.key).firstOrNull
        : null;
    if (extra == null && group == null) return;

    final qty = group?.qty ?? 1;
    final picked = await pickCatalogModel(
      context,
      provider,
      title: 'Replace ${line.description}',
      actionLabel: 'Replace',
      currentModel: line.model,
      only: provider.avDeviceLibrary.equipment,
      note: extra != null
          ? 'This line is quoted but not drawn, so only the line changes - '
                'its name, its part number and its price.'
          : qty > 1
          ? 'All $qty of these are replaced, on the drawing and in the room '
                'config. Cables are carried over to the matching connector '
                'wherever there is one.'
          : 'The connectors come with it, the room config follows, and cables '
                'are carried over to the matching connector wherever there is '
                'one.',
    );
    if (picked == null) return;
    if (picked.model.trim().toLowerCase() == line.model.trim().toLowerCase()) {
      return;
    }

    // The Python driver that claims the new model, and '' when none does —
    // the warning the confirmation below exists for.
    final module = provider.moduleForModel(picked.model);

    // The price typed on the old part, dropped either way — see above. Held
    // on to only so the message can say it happened.
    final hadOverride = provider.avCost.priceOverrides[line.key] != null;

    if (extra != null) {
      provider.setAvCostPrice(line.key, null);
      provider.updateAvCostExtraEquipment(
        extra.copyWith(
          catalogModel: picked.model,
          category: picked.category,
          // The name follows the part unless somebody wrote their own on the
          // line — "Owner-furnished display in 2201" is about the room, and
          // survives the part under it changing.
          description:
              extra.description.trim().isEmpty ||
                  extra.description.trim().toLowerCase() ==
                      extra.catalogModel.trim().toLowerCase()
              ? picked.model
              : extra.description,
          // A figure typed against the OLD part, in the line's own fallback
          // slot. Same reasoning as the override.
          unitPrice: 0,
        ),
      );
      // No box and no config block, so nothing to drive and nothing to
      // rewrite — but a quote for a model no driver claims is still worth
      // hearing about before it turns into a purchase order.
      final said = [
        'Line now quotes ${picked.model}',
        if (hadOverride) 'the price typed on the old part was for the old part',
        if (module.isEmpty)
          'no control module claims it - it can be quoted, but nothing can '
              'drive it yet',
      ].join('. ');
      messenger.showSnackBar(
        SnackBar(
          content: Text('$said.'),
          duration: module.isEmpty
              ? const Duration(seconds: 8)
              : const Duration(seconds: 4),
        ),
      );
      return;
    }

    // --- the control side ---------------------------------------------------
    //  Which of these boxes the control system actually knows about. A node
    //  seeded from the config carries the config's own section key as its id,
    //  so the two line up without anything having to be stored to link them.
    final configured = activeDeviceKeysIn(
      provider.roomConfig,
      provider.uiSchema.deviceCountMap,
    ).toSet();
    final controlKeys = [
      for (final node in group!.nodes)
        if (configured.contains(node.id)) node.id,
    ];
    // What picking this model would do to the first of those blocks: which
    // module it lands on, and which of its settings disagree with that
    // module's defaults. The same question the Devices tab asks, asked here so
    // the answer is the same one.
    final preview = controlKeys.isEmpty
        ? null
        : provider.previewModelSelection(controlKeys.first, picked.model);

    // Silent when there is nothing to decide and nothing to warn about. It
    // opens when the answer matters: no driver claims the new model, or the
    // device moves to a different module whose defaults disagree with what
    // this room has set.
    var choice = _SwapControl.keepSettings;
    if (module.isEmpty ||
        (preview != null &&
            preview.moduleChanged &&
            preview.diffs.isNotEmpty)) {
      if (!context.mounted) return;
      final answer = await _confirmSwapEffects(
        context,
        fromModel: line.model.isEmpty ? line.description : line.model,
        toModel: picked.model,
        boxes: qty,
        controlKeys: controlKeys,
        module: module,
        preview: preview,
      );
      // Nothing has been written yet, so cancel really does mean nothing
      // happened — the price override is cleared below, after this.
      if (answer == null) return;
      choice = answer;
    }

    provider.setAvCostPrice(line.key, null);

    // The control side, by the same rules wherever a swap is made — the Racks
    // tab's replace goes through this too.
    applyControlSwap(
      provider,
      controlKeys,
      picked.model,
      applyDefaults: choice == _SwapControl.applyDefaults,
    );

    // --- the drawing --------------------------------------------------------
    //  Every box behind the row. The first press records the undo snapshot and
    //  the rest ride on it, so the whole swap comes back in one Undo.
    var carried = 0;
    var dropped = 0;
    var first = true;
    for (final node in group.nodes) {
      final result = applyModelSwap(provider, node, picked, recordUndo: first);
      first = false;
      carried += result.carried;
      dropped += result.dropped;
    }

    final said = [
      qty > 1
          ? '$qty × ${line.model.isEmpty ? line.description : line.model} '
                'replaced with ${picked.model}'
          : '${line.description} is now a ${picked.model}',
      if (carried > 0) '$carried cable${carried == 1 ? '' : 's'} carried across',
      if (dropped > 0)
        '$dropped cable${dropped == 1 ? '' : 's'} dropped - the new model has '
            'no matching connector, so draw '
            '${dropped == 1 ? 'it' : 'them'} again on the Signal Flow page',
      if (controlKeys.isNotEmpty && module.isNotEmpty)
        '${controlKeys.length} control block'
            '${controlKeys.length == 1 ? '' : 's'} moved to $module'
            '${choice == _SwapControl.applyDefaults ? ' with its defaults' : ''}',
      if (controlKeys.isNotEmpty && module.isEmpty)
        'no module claims ${picked.model}, so the module was cleared - the '
            'Devices tab is showing '
            '${controlKeys.length == 1 ? 'it' : 'them'} in red until one is '
            'picked',
      if (hadOverride) 'the room price typed on the old model was cleared',
    ].join('. ');

    messenger.showSnackBar(
      SnackBar(
        content: Text('$said.'),
        duration: dropped > 0 || module.isEmpty
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
      ),
    );
  }

  /// Quotes a different part on a line that was TYPED here rather than drawn.
  ///
  /// Nothing but the line changes — there is no box on the diagram and no item
  /// in a frame behind it — so this is the whole edit for a hand-added line,
  /// whichever card it sits on.
  Future<void> _swapExtraLine(
    BuildContext context,
    AppStateProvider provider,
    CostLineItem item, {
    required _ExtraPart kind,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final library = provider.avDeviceLibrary;
    final name = item.description.trim().isEmpty
        ? (item.catalogModel.trim().isEmpty ? 'this line' : item.catalogModel)
        : item.description.trim();
    final picked = await pickCatalogModel(
      context,
      provider,
      title: 'Replace $name',
      actionLabel: 'Replace',
      currentModel: item.catalogModel,
      only: switch (kind) {
        _ExtraPart.equipment => library.equipment,
        _ExtraPart.cable => library.cables,
        _ExtraPart.hardware => library.rackHardware,
        _ExtraPart.misc => library.miscItems,
      },
      note: 'This line is quoted but not drawn, so only the line changes - '
          'its name, its part number and its price.',
    );
    if (picked == null) return;

    // A price typed against the OLD part, in both the places one can be: the
    // room override and the line's own fallback figure. Same rule the device
    // swap follows — the figure was for the part that is being replaced.
    provider.setAvCostPrice(item.id, null);
    final swapped = item.copyWith(
      catalogModel: picked.model,
      category: picked.category.trim().isEmpty
          ? item.category
          : picked.category.trim(),
      // The name follows the part unless somebody wrote their own on the line
      // — "patch leads for the credenza" is about the job, and survives the
      // part under it changing.
      description:
          item.description.trim().isEmpty ||
              item.description.trim().toLowerCase() ==
                  item.catalogModel.trim().toLowerCase()
          ? picked.model
          : item.description,
      unitPrice: 0,
    );
    switch (kind) {
      case _ExtraPart.equipment:
        provider.updateAvCostExtraEquipment(swapped);
      case _ExtraPart.cable:
        provider.updateAvCostExtraCable(swapped);
      case _ExtraPart.hardware:
        provider.updateAvCostExtraHardware(swapped);
      case _ExtraPart.misc:
        provider.updateAvCostItem(swapped);
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Line now quotes ${picked.model}.')),
    );
  }

  /// Puts a different part under a rack-hardware row.
  ///
  /// The row is a GROUP of identical items in the frames, so the swap has to
  /// reach every one of them or the elevation and the quote stop agreeing
  /// about what the same plate is. An item whose new height no longer fits
  /// where it was comes off its rail rather than overlapping its neighbour —
  /// [AppStateProvider.swapAvRackItem] decides which, and the message says how
  /// many so nobody has to go looking for them.
  Future<void> _swapHardware(
    BuildContext context,
    AppStateProvider provider,
    CostLine line, {
    CostLineItem? extra,
  }) async {
    if (extra != null) {
      return _swapExtraLine(
        context,
        provider,
        extra,
        kind: _ExtraPart.hardware,
      );
    }
    final messenger = ScaffoldMessenger.of(context);
    final items = provider.avRackItems
        .where((i) => rackItemKey(i) == line.key)
        .toList();
    if (items.isEmpty) return;

    final was = line.model.isEmpty ? line.description : line.model;
    final picked = await pickCatalogModel(
      context,
      provider,
      title: 'Replace ${line.description}',
      actionLabel: 'Replace',
      currentModel: was,
      only: provider.avDeviceLibrary.rackHardware,
      note: items.length > 1
          ? 'All ${items.length} of these in the racks become the new part - '
                'its name, its category, its rack height and its price. Each '
                'one keeps its rail if the new part still fits on it.'
          : 'It keeps its rail if the new part still fits on it, and comes '
                'off it if it does not.',
    );
    if (picked == null) return;
    if (picked.model.trim().toLowerCase() == was.trim().toLowerCase()) return;

    final hadOverride = provider.avCost.priceOverrides[line.key] != null;
    provider.setAvCostPrice(line.key, null);
    var unracked = 0;
    for (final item in items) {
      if (!provider.swapAvRackItem(item, picked)) unracked++;
    }

    final said = [
      items.length > 1
          ? '${items.length} × ${line.description} replaced with '
                '${picked.model}'
          : '${line.description} is now a ${picked.model}',
      if (unracked > 0)
        '$unracked came off '
            '${unracked == 1 ? 'its rail' : 'their rails'} - the new part does '
            'not fit where the old one was, so place '
            '${unracked == 1 ? 'it' : 'them'} on the Racks tab',
      if (hadOverride) 'the room price typed on the old part was cleared',
    ].join('. ');
    messenger.showSnackBar(
      SnackBar(
        content: Text('$said.'),
        duration: unracked > 0
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
      ),
    );
  }

  /// Buys one counted cabling line as a different catalog lead.
  ///
  /// The DRAWING still says how many runs there are and how long they are —
  /// that is the whole point of counting them there — so only the product
  /// changes: this length of this signal is bought as the picked entry from
  /// now on, in this room.
  ///
  /// The line key is built out of the entry, so it moves when the entry does.
  /// The estimate is rebuilt here to find where the row went, and the room's
  /// spares are carried over to it: "two spare 25 ft leads" is a decision
  /// about the order, and it survives a change of which lead is ordered.
  Future<void> _swapCable(
    BuildContext context,
    AppStateProvider provider,
    CostLine line, {
    required SignalType signal,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final library = provider.avDeviceLibrary;
    final lengthFt = cableKeyParts(line.key).lengthFt;
    final forSignal = library.cablesForSignal(signal);
    final picked = await pickCatalogModel(
      context,
      provider,
      title: 'Replace ${line.description}',
      actionLabel: 'Use this lead',
      currentModel: line.model,
      // This signal's leads first, then every other cable in the catalog: an
      // entry nobody has tagged with a signal yet is still the lead somebody
      // means to buy, and refusing to offer it would send them to the Catalog
      // tab in the middle of pricing a room.
      only: [
        ...forSignal,
        ...library.cables.where((t) => !forSignal.contains(t)),
      ],
      note: lengthFt > 0
          ? 'Every ${formatCableLength(lengthFt)} run of this signal is quoted '
                'as this lead from now on, in this room. The runs and the '
                'spares stay as they are - they are counted off the drawing.'
          : 'Runs of this signal with no length on them are quoted as this '
                'lead from now on, in this room. The runs and the spares stay '
                'as they are - they are counted off the drawing.',
    );
    if (picked == null) return;
    if (picked.model.trim().toLowerCase() == line.model.trim().toLowerCase()) {
      return;
    }

    provider.setAvCableEntry(signal, lengthFt, picked.model);

    // WHERE THE ROW WENT. Rebuilt rather than guessed: the key is assembled
    // from the entry and the length by the estimate itself, and a second copy
    // of that rule here would be one more thing to keep in step.
    final after = computeRoomCost(
      model: widget.model ?? buildAvFlowModel(provider),
      library: library,
      settings: provider.avCost,
      rates: provider.laborRates,
      baseCosts: provider.baseCosts,
      tier: provider.pricingTier,
    );
    final moved = after.cabling
        .where(
          (l) =>
              cableSignalOfKey(l.key) == signal &&
              cableKeyParts(l.key).lengthFt == lengthFt,
        )
        .firstOrNull;
    provider.moveAvCableLine(from: line.key, to: moved?.key ?? line.key);

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${lengthFt > 0 ? '${formatCableLength(lengthFt)} runs' : 'Runs'} of '
          '${kSignalLabels[signal] ?? signal.name} are now quoted as '
          '${picked.model}.',
        ),
      ),
    );
  }

  /// Says what a swap is about to change, and asks the one question that has
  /// an answer worth having.
  ///
  /// Two reasons it opens, and they are the two that cost money:
  ///
  ///   * NO MODULE CLAIMS THE NEW MODEL. The room can be quoted and drawn
  ///     around a box the control system cannot drive, and it should be
  ///     possible — a part often arrives before its driver does — but not by
  ///     accident. Worse when the block already HAS a module: it keeps the old
  ///     one, which now names a driver for a device that is no longer there,
  ///     and a config that looks complete is the one nobody re-checks.
  ///   * THE MODULE CHANGES AND THE SETTINGS DISAGREE WITH IT. Exactly the
  ///     question the Devices tab asks when a model is picked there, asked the
  ///     same way and answered by the same two provider calls, so a swap made
  ///     here and a model picked there leave the config in the same state.
  ///
  /// Null means cancel, and cancel means nothing has happened yet — this is
  /// asked before the first write.
  Future<_SwapControl?> _confirmSwapEffects(
    BuildContext context, {
    required String fromModel,
    required String toModel,
    required int boxes,
    required List<String> controlKeys,
    required String module,
    required ModelChangePreview? preview,
  }) {
    final theme = Theme.of(context);
    final asking =
        preview != null && preview.moduleChanged && preview.diffs.isNotEmpty;

    Widget bullet(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: theme.disabledColor),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );

    return showDialog<_SwapControl>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Replace $fromModel with $toModel'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bullet(
                  Icons.developer_board,
                  '$boxes box${boxes == 1 ? '' : 'es'} on the signal flow take '
                      "$toModel's connectors, rack height, power and heat. "
                      'Cables move to the matching connectors; any with no '
                      'counterpart are removed.',
                ),
                bullet(
                  Icons.cable,
                  'The cabling schematic and the cable schedule are built from '
                      'the flow, so they redraw from what is left.',
                ),
                if (controlKeys.isNotEmpty)
                  bullet(
                    Icons.settings_input_component,
                    '${controlKeys.length} control block'
                        '${controlKeys.length == 1 ? '' : 's'} '
                        '(${controlKeys.join(', ')}) '
                        '${controlKeys.length == 1 ? 'is' : 'are'} set to '
                        '$toModel${module.isEmpty ? '' : ', on $module'}.',
                  )
                else
                  bullet(
                    Icons.settings_input_component,
                    'Nothing on the control side: '
                        '${boxes == 1 ? 'this box was' : 'these boxes were'} '
                        'added to the drawing by hand rather than coming from '
                        'the room config.',
                  ),
                if (module.isEmpty) ...[
                  const SizedBox(height: 10),
                  // THE WARNING. Its own panel rather than another bullet:
                  // this is the one thing on the dialog somebody has to have
                  // read before pressing the button.
                  Container(
                    key: const ValueKey('swap_no_module_warning'),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 20,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'No control module claims $toModel',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                controlKeys.isEmpty
                                    ? 'It can be quoted and drawn, but no '
                                          'Python driver under the modules '
                                          'path drives it - so nothing can '
                                          'control it until one does.'
                                    : 'The module on the block is cleared '
                                          'rather than left naming a driver '
                                          'for the old box, and the Devices '
                                          'tab shows the device in red until '
                                          'a module is picked for it. The '
                                          'room will not commission before '
                                          'then.',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (asking) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${preview.diffs.length} setting'
                    '${preview.diffs.length == 1 ? '' : 's'} on '
                    '${controlKeys.first} differ from '
                    "${preview.newModule}'s defaults"
                    '${controlKeys.length > 1 ? ' — the same answer is applied to all ${controlKeys.length}' : ''}:',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final d in preview.diffs)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '${d.key}:  ${_shownValue(d.current)}'
                                '  →  ${_shownValue(d.moduleDefault)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('swap_cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          if (asking)
            TextButton(
              key: const ValueKey('swap_keep_settings'),
              onPressed: () => Navigator.of(ctx).pop(_SwapControl.keepSettings),
              child: const Text('Keep room settings'),
            ),
          ElevatedButton(
            key: const ValueKey('swap_apply'),
            onPressed: () => Navigator.of(ctx).pop(
              asking ? _SwapControl.applyDefaults : _SwapControl.keepSettings,
            ),
            child: Text(asking ? 'Apply module defaults' : 'Replace'),
          ),
        ],
      ),
    );
  }

  /// A config value as the swap dialog prints it, with the empty ones named
  /// rather than left as a gap somebody has to interpret.
  static String _shownValue(dynamic v) =>
      (v == null || v == '') ? '(blank)' : v.toString();

  // --- turning a typed line into a catalog entry ---------------------------

  /// Promotes a hand-typed estimate line into a device catalog entry.
  ///
  /// The reverse trip of [_addExtraPart], and the one that was missing. A line
  /// typed by hand is how a part enters the building — somebody is quoted a
  /// figure over the phone and types it on the job in front of them — and
  /// until now that was where it stopped: the next room typed the same box in
  /// again, at whatever price that person remembered. This writes it to
  /// av_devices.json once, points the line at the new entry and drops the
  /// typed price, so from here the line is priced like everything else and a
  /// revision reaches every room that uses it.
  ///
  /// Offered on a line with no [CostLineItem.catalogModel]: a line that is
  /// already off the catalog has nothing to promote.
  Future<void> _addLineToCatalog(
    BuildContext context,
    AppStateProvider provider,
    CostLineItem item, {
    required _ExtraPart kind,
  }) =>
      _addToCatalog(
        context,
        provider,
        suggestedModel: item.description,
        category: item.category,
        // The figure typed in the Unit price box, else the one on the line —
        // the same order the estimate itself resolves the price in.
        price: provider.avCost.priceOverrides[item.id] ?? item.unitPrice,
        link: item,
        linkKind: kind,
      );

  /// Writes a catalog entry for ANYTHING on the estimate, and wires whatever
  /// can be wired to it.
  ///
  /// The generalization of the line-item promotion above, and the answer to the
  /// obvious next question: a device on the drawing, a plate in a frame or a
  /// cable type with no catalog entry is exactly as much "a part the shop now
  /// knows about" as a line somebody typed, and it was the only one of them
  /// that could not be recorded. Everything on the page can now be recorded
  /// from the row it is on.
  ///
  /// What happens after the write depends on what the line IS:
  ///
  ///   * a typed line ([link]) is pointed at the entry and loses its typed
  ///     price, so a revision reaches it;
  ///   * placed rack hardware ([rackItemLabel]) is stamped with the model, so
  ///     the frame and the quote agree;
  ///   * a device on the drawing needs nothing: the estimate prices it by
  ///     model, so an entry under that model is picked up on the next build.
  ///     When the device has no model to match, [unlinkedNote] says so before
  ///     the entry is written rather than leaving somebody to wonder why the
  ///     row did not change.
  Future<void> _addToCatalog(
    BuildContext context,
    AppStateProvider provider, {
    required String suggestedModel,
    String partNumber = '',
    String category = '',
    int rackUnits = 0,
    double price = 0,
    SignalType? cableSignal,
    CostLineItem? link,
    _ExtraPart? linkKind,
    String? rackItemLabel,
    /// The room override to clear once the catalog is the source of the price.
    String? priceKey,
    /// Said in the dialog when the entry cannot be tied to this row.
    String? unlinkedNote,
  }) async {
    final library = provider.avDeviceLibrary;
    final messenger = ScaffoldMessenger.of(context);

    // EDITING, when the catalog already has this part.
    //
    // Two things come out of prefilling from it. The obvious one is the
    // feature: a price rise, a part number somebody finally found, a rack
    // height that was guessed — all of that gets noticed while looking at a
    // quote, and going to the Catalog tab to fix it means losing your place.
    //
    // The other is a bug this closes. The save below UPSERTS, so opening this
    // on a model the catalog already had and pressing Save wrote an entry with
    // an empty maker, no education price and no notes over the top of one that
    // had them. It kept the ports and the cable fields and silently dropped
    // the rest.
    final current = library.templateForModel(suggestedModel.trim());
    final editing = current != null;

    final modelController =
        TextEditingController(text: suggestedModel.trim());
    final makerController =
        TextEditingController(text: current?.manufacturer ?? '');
    final partController = TextEditingController(
      text: partNumber.trim().isNotEmpty
          ? partNumber.trim()
          : (current?.partNumber ?? ''),
    );
    final uController = TextEditingController(
      text: (rackUnits > 0 ? rackUnits : (current?.rackUnits ?? 0)).toString(),
    );
    // Only asked about for a cable: the length it is bought in, which is what
    // makes "HDMI 6 ft" a different line on a quote from "HDMI 25 ft".
    final lengthController = TextEditingController(
      text: (current?.cableLengthFt ?? 0) > 0
          ? trimNumber(current!.cableLengthFt)
          : '',
    );
    final priceController = TextEditingController(
      text: price > 0
          ? trimNumber(price)
          : ((current?.price ?? 0) > 0 ? trimNumber(current!.price) : ''),
    );
    final eduController = TextEditingController(
      text: (current?.educationPrice ?? 0) > 0
          ? trimNumber(current!.educationPrice)
          : '',
    );
    final notesController = TextEditingController(text: current?.notes ?? '');
    // Reassigned rather than shadowed: everything below reads `category` as
    // the live value of the dropdown.
    category = category.trim().isNotEmpty
        ? category.trim()
        : (current?.category.trim().isNotEmpty ?? false)
        ? current!.category.trim()
        : switch (linkKind) {
            _ExtraPart.equipment => '',
            _ExtraPart.cable => kCategoryCable,
            _ExtraPart.hardware => kCategoryRackHardware,
            _ExtraPart.misc => kCategoryMisc,
            null => cableSignal != null ? kCategoryCable : '',
          };

    // RENAMING, not just editing. Typing a new name over an entry that is open
    // for editing is the commonest way a part gets renamed — "1RU vent plate"
    // turns out to be a fan panel while somebody is looking at the quote — and
    // it used to leave BOTH entries in the catalog and every rack item, box and
    // line still naming the old one. Ticked by default because the other
    // reading ("add a second, similar part") is the rarer one, and because the
    // untidy half of it is invisible until a price goes missing.
    var replaceEverywhere = true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final model = modelController.text.trim();
          // The entry this dialog was opened on, being given a different name.
          final renaming = editing &&
              model.isNotEmpty &&
              AvDeviceLibrary.normalizeModel(model) !=
                  AvDeviceLibrary.normalizeModel(current.model);
          // Typing the name of something already in the catalog is nearly
          // always "I did not know it was there" rather than "replace it", so
          // it is said out loud before the button is pressed rather than
          // reported afterwards.
          final existing = model.isEmpty
              ? null
              : library.templateForModel(model);
          final categories = <String>{
            ...library.categories,
            if (category.isNotEmpty) category,
          }.toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          return AlertDialog(
            title: Text(
              editing
                  ? 'Edit ${suggestedModel.trim()} in the catalog'
                  : 'Add this line to the catalog',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      editing
                          ? 'Edits the catalog entry this line is priced from, '
                                'and saves it back to the catalog file - so '
                                'the correction reaches every room that quotes '
                                'this part, not just this one. The connectors '
                                'on the entry are left alone; they are edited '
                                'on the Catalog tab.'
                          : 'Writes a catalog entry and points this line at '
                                'it, so the price comes from the catalog from '
                                'now on and every other room can quote the '
                                'same part. The quantity stays on the line - '
                                'it is about this job, not about the part.',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                    if (unlinkedNote != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        unlinkedNote,
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: modelController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Model',
                        helperText: 'How the catalog will list it',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setLocal(() {}),
                    ),
                    if (existing != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'The catalog already has "${existing.model}" - saving '
                        'replaces its entry.',
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                      ),
                    ],
                    if (renaming) ...[
                      const SizedBox(height: 4),
                      CheckboxListTile(
                        key: const ValueKey('catalog_replace_everywhere'),
                        value: replaceEverywhere,
                        onChanged: (v) =>
                            setLocal(() => replaceEverywhere = v ?? false),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text('Replace "${current.model}" with this'),
                        subtitle: Text(
                          '"${current.model}" comes out of the catalog, and '
                          'everything in this room that uses it - this quote, '
                          'the racks, the diagram and the config - becomes '
                          'the new part. Untick to leave "${current.model}" '
                          'alone and add this as a second entry.',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: makerController,
                            decoration: const InputDecoration(
                              labelText: 'Manufacturer',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: partController,
                            decoration: const InputDecoration(
                              labelText: 'Part number',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue:
                                categories.contains(category) ? category : null,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Category',
                              isDense: true,
                            ),
                            items: [
                              for (final c in categories)
                                DropdownMenuItem(value: c, child: Text(c)),
                            ],
                            onChanged: (v) =>
                                setLocal(() => category = v ?? category),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 120,
                          child: TextField(
                            controller: uController,
                            decoration: const InputDecoration(
                              labelText: 'Rack U',
                              helperText: '0 = not racked',
                              isDense: true,
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (cableSignal != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SizedBox(
                            width: 150,
                            child: TextField(
                              controller: lengthController,
                              decoration: const InputDecoration(
                                labelText: 'Length (ft)',
                                helperText: 'blank = bulk',
                                isDense: true,
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'One entry per length - 3 ft, 6 ft, 25 ft - each '
                              'with its own price. The estimate buys every '
                              'drawn run the shortest one that reaches it.',
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: priceController,
                            decoration: InputDecoration(
                              labelText:
                                  'List price (${provider.currencySymbol})',
                              isDense: true,
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.]')),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: eduController,
                            decoration: InputDecoration(
                              labelText:
                                  'Education price (${provider.currencySymbol})',
                              helperText: 'optional',
                              isDense: true,
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.]')),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesController,
                      decoration: const InputDecoration(
                        labelText: 'Note',
                        helperText: 'e.g. where the price came from',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Connectors, power draw and heat are left blank - fill '
                      'them in on the Device Editor tab if this part ends up '
                      'on a diagram.',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: model.isEmpty
                    ? null
                    : () => Navigator.of(ctx).pop(true),
                // "Replace" is the honest word for a name TYPED over an
                // entry that already existed. It is the wrong one when the
                // dialog was opened on that entry to edit it.
                child: Text(
                  editing
                      ? 'Save to catalog'
                      : existing == null
                      ? 'Add to catalog'
                      : 'Replace',
                ),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return;
    final model = modelController.text.trim();
    if (model.isEmpty) return;

    // Renaming the entry this was opened on, rather than writing a new one.
    // Both halves of it are the checkbox's: the OLD ENTRY GOES (upsert is told
    // what it is replacing) and the room follows it (below).
    final renamedFrom =
        current != null &&
            replaceEverywhere &&
            AvDeviceLibrary.normalizeModel(model) !=
                AvDeviceLibrary.normalizeModel(current.model)
        ? current.model
        : '';

    final existing = library.templateForModel(model);
    // What the connectors and the cable facts come off when the name changed:
    // the entry being renamed, since nothing is stored under the new name yet.
    // Without this a rename dropped the port list it never showed.
    final keepFrom = existing ?? (renamedFrom.isEmpty ? null : current);
    library.upsert(
      AvDeviceTemplate(
        model: model,
        manufacturer: makerController.text.trim(),
        partNumber: partController.text.trim(),
        category: category,
        rackUnits: int.tryParse(uController.text.trim()) ?? 0,
        price: double.tryParse(priceController.text.trim()) ?? 0,
        educationPrice: double.tryParse(eduController.text.trim()) ?? 0,
        notes: notesController.text.trim(),
        // What signal a CABLE entry carries, so the counted runs of that type
        // find it. Kept from the old entry when one is being replaced.
        cableSignal: cableSignal ?? keepFrom?.cableSignal,
        cableLengthFt: double.tryParse(lengthController.text.trim()) ??
            keepFrom?.cableLengthFt ??
            0,
        // Replacing keeps whatever connectors the old entry had: this dialog
        // knows about money, not about ports, and dropping a port list it
        // never showed would be a silent edit.
        ports: keepFrom?.ports ?? const [],
      ),
      previousModel: renamedFrom.isNotEmpty
          ? renamedFrom
          : (existing?.model ?? ''),
    );
    // THE ROOM FIRST, THE FILE AFTER. Everything below is a change to what is
    // open in front of somebody; the write is a trip to a network share that
    // can be slow and can fail, and a room left half-repointed while it is in
    // flight is a room whose quote and racks disagree.
    //
    // The line now points at the entry. The typed price and the room override
    // both go, or they would keep winning over the catalog figure and the
    // promotion would look like it had done nothing.
    if (link != null && linkKind != null) {
      final linked = link.copyWith(catalogModel: model, unitPrice: 0);
      switch (linkKind) {
        case _ExtraPart.equipment:
          provider.updateAvCostExtraEquipment(linked);
        case _ExtraPart.cable:
          provider.updateAvCostExtraCable(linked);
        case _ExtraPart.hardware:
          provider.updateAvCostExtraHardware(linked);
        case _ExtraPart.misc:
          provider.updateAvCostItem(linked);
      }
    }
    // THE ROOM FOLLOWS THE RENAME. Everything that records a model does it by
    // NAME — the boxes on the diagram, the items in the racks, the lines typed
    // on the quote, the blocks in the config — so without this the entry moves
    // and every one of them is left naming a part the catalog no longer has.
    final moved = renamedFrom.isEmpty
        ? (nodes: 0, rackItems: 0, costLines: 0, blocks: 0)
        : provider.renameAvCatalogModel(renamedFrom, model);

    // Hardware already in a frame is stamped with the model instead: the item
    // in the rack and the line on the quote are the same part, and only the
    // rack knows how many of them there are. A rename has already been through
    // them by name, so this is only for the ones it did not cover.
    final stamped = rackItemLabel == null
        ? 0
        : provider.linkAvRackItemsToCatalog(
            label: rackItemLabel,
            catalogModel: model,
          );
    final key = priceKey ?? link?.id;
    if (key != null) provider.setAvCostPrice(key, null);

    final file = await provider.saveAvDeviceLibrary();
    // The catalog is a plain object rather than a listenable, so the page it
    // is being edited from has to be told. Without this an edited price sat
    // in the file and in memory while the row went on showing the old figure
    // until something else happened to rebuild it.
    provider.avDeviceLibraryChanged();

    final followed = [
      if (moved.rackItems > 0)
        '${moved.rackItems} in the racks'
      else if (stamped > 1)
        'all $stamped of them in the racks',
      if (moved.nodes > 0)
        '${moved.nodes} on the diagram',
      if (moved.blocks > 0)
        '${moved.blocks} config block${moved.blocks == 1 ? '' : 's'}',
      if (moved.costLines > 0)
        '${moved.costLines} quote line${moved.costLines == 1 ? '' : 's'}',
    ];

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          file.isEmpty
              ? '"$model" saved to the catalog in memory, but the catalog file '
                    'could not be written - check the Device Editor tab.'
              : renamedFrom.isNotEmpty
              ? '"$renamedFrom" is now "$model" ($file)'
                    '${followed.isEmpty ? ' — nothing in this room was using '
                        'it yet' : ', and so ${followed.join(', ')}'}.'
              : followed.isNotEmpty
              ? '"$model" saved to the catalog ($file). ${followed.join(', ')} '
                    'now take their price from it.'
              : '"$model" saved to the catalog ($file). This line now takes '
                    'its price from it.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
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
    final theme = Theme.of(context);
    final title = model.roomTitle.isEmpty ? 'Cost estimate' : model.roomTitle;
    final priced = costReportSections(estimate);

    if (priced.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Nothing priced yet - there is no estimate to export.'),
        ),
      );
      return;
    }

    // The estimate, then the devices no control module claims. A cost-only
    // document is one somebody signs off without opening the AV report, so the
    // warning has to be on it — a room quoted with three undriven boxes in it
    // is a room that cannot be commissioned when it arrives.
    final sections = [
      ...priced,
      ...driverGapSections(provider, model),
    ];

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
      showSavedSnackBar(
        messenger: messenger,
        theme: theme,
        provider: provider,
        message: 'Cost estimate saved as ${path.basename(outputFile)}',
        savedPath: outputFile,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save the estimate: $e'),
          backgroundColor: snackErrorFillOn(messenger),
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
            _CardHeading(
              title: 'Labor',
              subtitle: estimate.labor.isEmpty
                  ? 'rate x techs x hours, off the shared rate card'
                  : '${trimNumber(estimate.laborHours)} tech-hours',
              actions: [
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add crew'),
                  onPressed: () => provider.addAvCostLabor(),
                )),
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
                        'No job type has an hourly rate yet - open '
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
              _headerRow(context, _kLaborCols),
              const Divider(height: 12),
            ],
            for (final (i, line) in lines.indexed)
              Builder(
                builder: (context) {
                  final costed = estimate.labor.firstWhere(
                    (l) => l.id == line.id,
                  );
                  return _stripe(
                    context,
                    i,
                    Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: _gridRow(_kLaborCols, [
                      // Job type
                      _JobTypeField(
                        book: book,
                        rateId: line.rateId,
                        currency: currency,
                        onChanged: (v) => provider.updateAvCostLabor(
                          line.copyWith(rateId: v),
                        ),
                      ),
                      // Scope
                      LiveTextField(
                        fieldId: 'labor_desc_${line.id}',
                        initial: line.description,
                        hint: 'e.g. Rack build and termination',
                        onChanged: (v) => provider.updateAvCostLabor(
                          line.copyWith(description: v),
                        ),
                      ),
                      // Techs
                      LiveTextField(
                        fieldId: 'labor_techs_${line.id}',
                        initial: trimNumber(line.techs),
                        numeric: true,
                        onChanged: (v) => provider.updateAvCostLabor(
                          line.copyWith(techs: double.tryParse(v) ?? 0),
                        ),
                      ),
                      // Hours each
                      LiveTextField(
                        fieldId: 'labor_hours_${line.id}',
                        initial:
                            line.hours == 0 ? '' : trimNumber(line.hours),
                        numeric: true,
                        onChanged: (v) => provider.updateAvCostLabor(
                          line.copyWith(hours: double.tryParse(v) ?? 0),
                        ),
                      ),
                      // Rate. Blank follows the card; a figure here is what
                      // THIS job pays, which is how overtime and a one-off
                      // subcontract rate get recorded.
                      LiveTextField(
                        fieldId: 'labor_rate_${line.id}',
                        initial: line.customRate == 0
                            ? ''
                            : trimNumber(line.customRate),
                        hint: costed.unrated
                            ? 'set'
                            : trimNumber(costed.hourlyRate),
                        hintIsValue: !costed.unrated,
                        numeric: true,
                        onChanged: (v) => provider.updateAvCostLabor(
                          line.copyWith(
                            customRate: double.tryParse(v) ?? 0,
                          ),
                        ),
                      ),
                      // Extended
                      Text(
                        costed.unrated
                            ? 'no rate'
                            : formatMoney(costed.total, currency),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color:
                              costed.unrated ? theme.colorScheme.error : null,
                        ),
                      ),
                      // Taxable
                      PrintableCheckbox(
                        value: line.taxable,
                        onChanged: (v) => provider.updateAvCostLabor(
                          line.copyWith(taxable: v ?? false),
                        ),
                      ),
                      // The row's one button.
                      avRowIcon(
                        Icons.delete_outline,
                        'Remove crew',
                        () => provider.removeAvCostLabor(line.id),
                        danger: true,
                      ),
                    ], rowKey: ValueKey('gridrow_labor_${line.id}')),
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
    final currency = estimate.currency;
    final items = provider.avCost.items;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardHeading(
              title: 'Other items',
              subtitle:
                  'labor, cable, mounts - anything not a device on the canvas',
              actions: [
                // Two ways on: off the catalog, so a price agreed once is not
                // retyped per room and follows a revision; or a blank line for
                // the one-off nobody will ever quote again.
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.playlist_add, size: 16),
                  label: const Text('Add from catalog'),
                  onPressed: () => _addExtraPart(
                    context,
                    provider,
                    kind: _ExtraPart.misc,
                  ),
                )),
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add item'),
                  onPressed: () => provider.addAvCostItem(),
                )),
              ],
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 4),
              _headerRow(context, _kItemsCols),
              const Divider(height: 12),
            ],
            for (final (i, item) in items.indexed)
              _stripe(
                context,
                i,
                Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: _gridRow(_kItemsCols, [
                    // Description
                    LiveTextField(
                      fieldId: 'desc_${item.id}',
                      initial: item.description,
                      hint: 'e.g. Installation labor',
                      onChanged: (v) => provider.updateAvCostItem(
                        item.copyWith(description: v),
                      ),
                    ),
                    // Category
                    LiveTextField(
                      fieldId: 'cat_${item.id}',
                      initial: item.category,
                      hint: 'Labor',
                      onChanged: (v) => provider.updateAvCostItem(
                        item.copyWith(category: v),
                      ),
                    ),
                    // Qty
                    LiveTextField(
                      fieldId: 'qty_${item.id}',
                      initial: trimNumber(item.qty),
                      numeric: true,
                      onChanged: (v) => provider.updateAvCostItem(
                        item.copyWith(qty: double.tryParse(v) ?? 0),
                      ),
                    ),
                    // Unit price
                    LiveTextField(
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
                    // Extended
                    Text(
                      formatMoney(item.total, currency),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // Taxable
                    PrintableCheckbox(
                      value: item.taxable,
                      onChanged: (v) => provider.updateAvCostItem(
                        item.copyWith(taxable: v ?? true),
                      ),
                    ),
                    // The row's buttons, as one cell.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        avRowIcon(
                          item.catalogModel.isEmpty
                              ? Icons.library_add_outlined
                              : Icons.edit_note,
                          item.catalogModel.isEmpty
                              ? 'Add this item to the device catalog'
                              : 'Edit ${item.catalogModel} in the catalog',
                          item.catalogModel.isNotEmpty
                              ? () => _addToCatalog(
                                    context,
                                    provider,
                                    suggestedModel: item.catalogModel,
                                  )
                              : () => _addLineToCatalog(
                                    context,
                                    provider,
                                    item,
                                    kind: _ExtraPart.misc,
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
                  ], rowKey: ValueKey('gridrow_item_${item.id}')),
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
            _CardHeading(
              title: 'Fees',
              subtitle: 'each a percentage of the subtotal before tax',
              actions: [
                PrintHide(child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add fee'),
                  onPressed: () => provider.addAvCostFee(),
                )),
              ],
            ),
            if (settings.fees.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No fees. Add one for freight, installation, contingency or '
                  'overhead - several are fine, and each is worked out on the '
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
                          PrintableCheckbox(
                            dense: true,
                            value: fee.taxable,
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
            // somebody quotes a stakeholder.
            if (estimate.otherTierLines > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${estimate.otherTierLines} line'
                  '${estimate.otherTierLines == 1 ? '' : 's'} had no '
                  '${estimate.tierLabel} price in the catalog and '
                  '${estimate.otherTierLines == 1 ? 'was' : 'were'} costed at '
                  'the other tier - worth a look before this goes on a quote.',
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

  /// Column captions over a table.
  ///
  /// The rows below are Rows of SizedBoxes, not a Table, so nothing lines a
  /// caption up with its column except this — which means it has to mirror the
  /// row it captions EXACTLY: the same [_Col.gap] in front of each cell, the
  /// same [_Col.width] or [_Col.flex] for the cell itself, and the same
  /// alignment and inset the value in it is drawn with.
  ///
  /// It used to fold the gap into the width and left-align every caption,
  /// which put "Drawn", "Total" and "Extended" a gap-and-a-bit to the left of
  /// the right-aligned figures they name. On the cabling table, where the
  /// cells are narrow and the gaps many, they read as belonging to the column
  /// before.
  ///
  /// The cells then came out right and the captions inside them still did not,
  /// because half the columns are input boxes: a box right-aligns its figure
  /// and holds it 16 pixels off its own border, so "Unit price" sat hard left
  /// over a number hard right, and "Techs" and "Hours ea." the same. Which
  /// cells are boxes is therefore part of the column spec — see [_Col.field].
  ///
  /// Built through a [Builder] so the print skin is read from INSIDE the
  /// captured tree: the cards are built before the [PrintMode] that wraps
  /// them, and a caption that asked from out here would always be told the
  /// page is on screen.
  Widget _headerRow(BuildContext context, List<_Col> columns) {
    return Builder(
      builder: (ctx) {
        final style = Theme.of(ctx).textTheme.labelSmall;
        final printing = PrintMode.of(ctx);
        // EVERY CAPTION THE SAME HEIGHT, sitting on the same bottom edge.
        //
        // Narrow columns wrap their caption — "Unit price" over a 130-pixel
        // column is two lines, "Qty" over a 60-pixel one is not — and a Row
        // centres what it is given, so the tall ones rode 8 pixels higher than
        // the short ones and the whole caption row read as crooked. A fixed
        // box with the text against the bottom of it puts one line and two on
        // the same rule, which is the line the divider under them draws.
        Widget caption(_Col c) => SizedBox(
          height: kHeaderRowHeight,
          child: Padding(
            padding: c.padding(printing),
            child: Align(
              alignment: c.align == TextAlign.right
                  ? Alignment.bottomRight
                  : c.align == TextAlign.center
                  ? Alignment.bottomCenter
                  : Alignment.bottomLeft,
              child: Text(c.text, style: style, textAlign: c.align),
            ),
          ),
        );
        return _gridRow(columns, [for (final c in columns) caption(c)]);
      },
    );
  }

  /// A quantity cell that can be NUDGED as well as typed in.
  ///
  /// "Make that two" is the commonest edit an estimate gets, and typing it
  /// meant clicking into a box, selecting a digit and replacing it — three
  /// motions for one more display. The box stays: a line that buys eleven is
  /// still typed, not clicked eleven times.
  ///
  /// [value] is what the row currently buys and [onChanged] takes the new
  /// figure, so this works the same against a typed line's own quantity and
  /// against the spares beside a count the diagram owns. Never below zero — a
  /// quote cannot buy minus one of anything.
  static Widget _qtyStepper({
    required Widget field,
    required double value,
    required String what,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        _stepButton(
          Icons.remove,
          'One fewer $what',
          value <= 0 ? null : () => onChanged(value - 1 < 0 ? 0 : value - 1),
        ),
        Expanded(child: field),
        _stepButton(Icons.add, 'One more $what', () => onChanged(value + 1)),
      ],
    );
  }

  /// THE INVISIBLE GRID.
  ///
  /// Lays [cells] out on exactly the geometry [columns] describes — the gap in
  /// front of each cell, then its fixed width or its flex — so a caption row
  /// and the rows under it cannot disagree about where a column is. One cell
  /// per column, in order.
  ///
  /// Every table on this page used to build its rows by hand, repeating the
  /// same widths and `SizedBox(width: 12)` spacers that the caption row
  /// declared separately. That is two descriptions of one table, and they
  /// drifted every time a column was added: a button column declared 12
  /// pixels narrower than the buttons render walks every caption on the row
  /// out of place, and nothing says so until somebody looks hard at a
  /// screenshot. Now there is one description, and the row is built from it.
  /// Every other row on a table, washed.
  ///
  /// THE TABLES ON THIS PAGE ARE TWELVE COLUMNS WIDE and read across: a
  /// quantity on the left, a spares box, a price typed into the middle, an
  /// extended figure on the right. Losing the line halfway is how a figure
  /// gets typed onto the wrong row, and the only thing that was holding the
  /// eye on one was three pixels of padding.
  ///
  /// A NEUTRAL WASH, not a colour. The stripe is here to keep a line together,
  /// so it must not look like it MEANS anything — the coloured things on this
  /// page (the signal dot on a cable row, the red on an unpriced source) are
  /// saying something, and a row tinted by its vendor would be a third
  /// vocabulary competing with both.
  ///
  /// Painted BEHIND the row rather than around it: a border or a pad would
  /// move every cell off the caption above it, and the captions on these
  /// tables are measured against the rows they head — see
  /// cost_header_alignment_test.dart.
  static Widget _stripe(BuildContext context, int index, Widget child) {
    if (index.isEven) return child;
    return ColoredBox(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.045),
      child: child,
    );
  }

  static Widget _gridRow(
    List<_Col> columns,
    List<Widget> cells, {
    CrossAxisAlignment align = CrossAxisAlignment.center,

    /// Names the row for the alignment test, which measures a data row
    /// against the caption row above it and has to be able to tell one from
    /// the other. Cheap here, and the invariant is worth being able to check.
    Key? rowKey,
  }) {
    assert(
      cells.length == columns.length,
      'the grid needs one cell per column: ${cells.length} for '
      '${columns.length}',
    );
    return Row(
      key: rowKey,
      crossAxisAlignment: align,
      children: [
        for (int i = 0; i < columns.length; i++) ...[
          if (columns[i].gap > 0) SizedBox(width: columns[i].gap),
          if (columns[i].flex > 0)
            Expanded(flex: columns[i].flex, child: cells[i])
          else
            SizedBox(width: columns[i].width, child: cells[i]),
        ],
      ],
    );
  }
}

/// One column of a table caption, mirroring the cell under it.
///
/// See [_CostEstimateViewState._headerRow] for why every one of these has to
/// match the row below by hand.
class _Col {
  /// The blank the row puts in FRONT of this cell — the `SizedBox(width: n)`
  /// between two cells, repeated here so the caption starts where the cell
  /// does.
  final double gap;

  /// The cell's fixed width, or 0 when [flex] carries it instead.
  final double width;

  /// The cell's `Expanded` flex, or 0 when [width] is fixed.
  final int flex;

  final String text;
  final TextAlign align;

  /// How far the value under this caption is held off the cell's edge.
  ///
  /// A plain Text cell paints right at the edge, so nothing. An input box
  /// paints its text [kFieldTextInset] in from its border, and a caption flush
  /// against the cell edge is a caption that far from the thing it names.
  final double inset;

  /// True when the cell stays an input box in the captured estimate. The text
  /// fields print their bare value instead ([LiveTextField]), which sits much
  /// closer to the edge; the job-type picker keeps its box either way.
  final bool keepsBox;

  /// True when the box in this column has a + button beside it — see
  /// [_CostEstimateViewState._qtyStepper]. The button is part of the COLUMN
  /// but not part of the value, so the caption has to clear it as well as the
  /// box's own inset or it sits a stepper-width right of the figure it names.
  final bool stepper;

  /// A caption over a plain cell — a figure, a name, a checkbox.
  const _Col(
    this.text, {
    this.gap = 0,
    this.width = 0,
    this.flex = 0,
    this.align = TextAlign.left,
  }) : inset = 0,
       keepsBox = false,
       stepper = false;

  /// A caption over an input box. [numeric] right-aligns it, because that is
  /// where a numeric field puts its figure.
  const _Col.field(
    this.text, {
    this.gap = 0,
    this.width = 0,
    this.flex = 0,
    bool numeric = false,
    this.keepsBox = false,
    this.stepper = false,
  }) : align = numeric ? TextAlign.right : TextAlign.left,
       inset = kFieldTextInset;

  /// The inset as padding on whichever side the caption is drawn against.
  EdgeInsets padding(bool printing) {
    var gap = inset == 0
        ? 0.0
        : (printing && !keepsBox ? kPrintValueInset : inset);
    // The nudge button keeps its width in the photograph too, so this is the
    // same either way.
    if (stepper) gap += kStepButtonWidth;
    if (gap == 0) return EdgeInsets.zero;
    return align == TextAlign.right
        ? EdgeInsets.only(right: gap)
        : EdgeInsets.only(left: gap);
  }
}

/// A plain-text cell in a column that ALSO holds input boxes.
///
/// Half the columns on this page are a box on one row and a printed value on
/// the next — a device off the diagram prints "×3" where a line typed here has
/// a quantity box, and the same for the name beside it. A bare [Text] paints
/// at the cell's own edge and a box paints [kFieldTextInset] in from it, so
/// those two rows disagreed with each other by 16 pixels and the caption over
/// them could only ever line up with one. This is the [Text] with the box's
/// own inset on it, which lines up all three.
///
/// It follows the box into the capture, where a [LiveTextField] prints its
/// value at [kPrintValueInset] instead — so the photograph is as square as the
/// screen.
class _CellText extends StatelessWidget {
  final String text;

  /// Right-aligned and inset from the right, the way a numeric field puts its
  /// figure.
  final bool numeric;

  /// True in a column whose boxes have a + beside them — see [_Col.stepper].
  /// The printed row has no buttons of its own, so it has to stand off the
  /// cell edge by the width of the one on the row above.
  final bool stepper;

  const _CellText(this.text, {this.numeric = false, this.stepper = false});

  @override
  Widget build(BuildContext context) {
    final inset =
        (PrintMode.of(context) ? kPrintValueInset : kFieldTextInset) +
        (stepper ? kStepButtonWidth : 0);
    return Padding(
      padding: numeric
          ? EdgeInsets.only(right: inset)
          : EdgeInsets.only(left: inset),
      child: Text(
        text,
        textAlign: numeric ? TextAlign.right : TextAlign.left,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }
}

/// What one nudge button beside a quantity box takes across a row.
///
/// Deliberately tighter than [kRowIconWidth]: these come in pairs and there
/// are two quantity columns on the equipment table, so the stock row icon
/// would have cost the device and model names 160 pixels between them.
const double kStepButtonWidth = 24.0;

/// The − or + beside a quantity. Null [onPressed] greys it out — which is what
/// − does at zero, since a quote cannot buy minus one of anything.
///
/// Gone from the photographed estimate, like every other control: the column
/// keeps its width, so the number under the caption stays where it was.
Widget _stepButton(IconData icon, String tooltip, VoidCallback? onPressed) {
  return Builder(
    builder: (context) {
      if (PrintMode.of(context)) {
        return const SizedBox(width: kStepButtonWidth, height: 34);
      }
      return SizedBox(
        width: kStepButtonWidth,
        child: IconButton(
          icon: Icon(icon, size: 16),
          onPressed: onPressed,
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(
            width: kStepButtonWidth,
            height: 32,
          ),
        ),
      );
    },
  );
}

/// How tall a caption cell is, whether its text takes one line or two.
///
/// Two lines of [TextTheme.labelSmall] plus the space a single line would have
/// been given anyway — measured, like [kFieldTextInset], because the caption
/// row is laid out by hand and something has to say what "the same height"
/// means. See `test/cost_header_alignment_test.dart`.
const double kHeaderRowHeight = 32.0;

/// How far a dense outlined text field holds its text off its own border.
/// Measured rather than assumed — see `test/cost_header_alignment_test.dart`,
/// which fails if the framework's padding ever changes underneath this.
const double kFieldTextInset = 16.0;

/// The same, for a [LiveTextField] printing its value instead of its box.
const double kPrintValueInset = 2.0;

// ---------------------------------------------------------------------------
//  CARD HEADINGS
// ---------------------------------------------------------------------------

/// The heading of one card on the estimate: what the card is, a sentence
/// saying what belongs on it, and the buttons that add to it.
///
/// A [Wrap] rather than a Row with a Spacer in it, because a Row of that shape
/// is a Row that overflows. The sentence takes whatever width it wants and the
/// buttons are three or four wide, so on anything narrower than a maximized
/// window — a laptop, or a maximized window with the side panes open — the
/// buttons were painted past the edge of the card under a yellow-and-black
/// bar, and the last one could not be clicked at all.
///
/// Wrapping puts the buttons on a line of their own instead. That is also a
/// layout the screenshot can carry: the estimate is captured as a picture of
/// this page, so nothing here may depend on the window being wide.
class _CardHeading extends StatelessWidget {
  final String title;

  /// The line under the title, in the muted style every card uses for it.
  /// Shrinks and ellipsizes before anything else does — it is the one part of
  /// a heading that can be read from the section below it.
  final String? subtitle;

  /// Null uses the card style; the estimate's own heading passes titleLarge.
  final TextStyle? titleStyle;

  /// Laid out in one group so they wrap together rather than one at a time.
  final List<Widget> actions;

  const _CardHeading({
    required this.title,
    this.subtitle,
    this.titleStyle,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      // Title left, buttons right, exactly as the Spacer had them — until
      // they stop fitting on one line, when the buttons drop below.
      alignment: WrapAlignment.spaceBetween,
      spacing: 12,
      runSpacing: 6,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(title, style: titleStyle ?? theme.textTheme.titleSmall),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  subtitle!,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
              ),
            ],
          ],
        ),
        if (actions.isNotEmpty)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: actions,
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
            if (rate.initialism.isNotEmpty) '${rate.initialism} - ${rate.name}'
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
                  'card, so revising one re-costs every room that uses it - '
                  'open "Labor rates" to edit them.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Search the rate card',
                    hintText: 'name, class number, or shorthand - "tss", '
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
