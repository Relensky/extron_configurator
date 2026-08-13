import 'dart:typed_data';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_report.dart';
import 'cost_estimate.dart';
import 'report_tools.dart';
import 'schematic_view.dart' show SchematicModel, reportSections;
import 'xlsx_writer.dart';

/// ============================================================================
///  THE ROOM WORKBOOK
/// ============================================================================
///  One .xlsx for the whole job, a sheet per question somebody asks about it:
///
///    Control       — the control system as configured, and what the room is
///                    estimated to draw (the two things a facilities review
///                    asks for in the same breath)
///    AV Flow       — cable schedule, pack list, jack schedule, connector use,
///                    with the signal-flow diagram underneath
///    Locations     — where everything is, jacks and cable runs counted per
///                    place and grouped by mounting surface, the cable runs
///                    between places, and the floor plan's callouts
///    Racks         — how full and how hot each frame is, and what sits on
///                    which U
///    Cost Estimate — equipment at catalog or quoted prices, other items,
///                    percentage fees, tax, total
///
///  Every sheet is dealt from the SAME section builders the single-sheet
///  exports use ([reportSections], [avFlowSections], [rackSections],
///  [powerSections], [costReportSections]), so a figure cannot come out
///  different depending on which button was pressed.
///
///  Diagram images are passed in rather than captured here: only the widget
///  that is currently on screen can be rendered to a PNG, so the caller hands
///  over whichever ones it has and the sheets it can't illustrate simply come
///  out as tables.
/// ============================================================================

/// The sheet names, in workbook order — used for the "saved N sheets" message
/// and by the tests that guard the tab set.
const List<String> kRoomWorkbookSheets = [
  'Control',
  'AV Flow',
  'Locations',
  // The drawing the trades are handed, and the run schedule under it. Its own
  // sheet for the same reason Locations has one: it is read by different
  // people at a different time — rough-in, by whoever is pulling cable — and
  // a callout can point at it by name.
  'Cabling',
  'Racks',
  'Cost Estimate',
];

/// Builds the workbook. [av] is the resolved AV diagram (buildAvFlowModel);
/// the control schematic and the cost estimate are derived here so both
/// export buttons produce byte-identical books.
Uint8List buildRoomWorkbookBytes({
  required AppStateProvider provider,
  required AvFlowModel av,
  Uint8List? controlPng,
  Uint8List? avFlowPng,
  Uint8List? rackPng,
  Uint8List? floorPlanPng,
  Uint8List? cablingPng,
  /// Stamped on every sheet. One moment for the whole book — four tabs of the
  /// same export dated a minute apart would read as four documents.
  DateTime? generated,
}) {
  final stamp = generated ?? DateTime.now();
  final control = SchematicModel.build(provider);
  final estimate = computeRoomCost(
    model: av,
    library: provider.avDeviceLibrary,
    settings: provider.avCost,
    // Without these the workbook costs labor at the built-in (unset) rates
    // and skips the base costs entirely — the same room, two totals,
    // depending on which button produced the document.
    rates: provider.laborRates,
    baseCosts: provider.baseCosts,
    tier: provider.pricingTier,
  );

  final title = av.roomTitle.isNotEmpty ? av.roomTitle : control.roomTitle;

  XlsxImage? Function(int)? image(Uint8List? png) =>
      png == null ? null : (anchorRow) => scaledSheetImage(png, anchorRow);

  return buildXlsx([
    buildStackedReportSheet(
      sheetName: kRoomWorkbookSheets[0],
      title: title,
      sections: [
        ...reportSections(provider, control),
        ...powerSections(av),
      ],
      imageBuilder: image(controlPng),
      generated: stamp,
    ),
    buildStackedReportSheet(
      sheetName: kRoomWorkbookSheets[1],
      title: title,
      sections: avFlowSections(provider, av),
      imageBuilder: image(avFlowPng),
      generated: stamp,
    ),
    // Where things are, and the counts that get ordered against them. Its own
    // sheet because it is read by different people at a different time —
    // rough-in, before anything is racked or cabled — and because the floor
    // plan's callouts point at a sheet by NAME, so it has to have one.
    buildStackedReportSheet(
      sheetName: kRoomWorkbookSheets[2],
      title: title,
      sections: _orPlaceholder(
        locationSections(av),
        'Locations',
        'No locations have been recorded for this room.',
      ),
      imageBuilder: image(floorPlanPng),
      generated: stamp,
    ),
    buildStackedReportSheet(
      sheetName: kRoomWorkbookSheets[3],
      title: title,
      sections: _orPlaceholder(
        cablingSections(av),
        'Cabling',
        'No cabling drawing for this room yet. It builds itself from where '
            'things are: name the places in the room, say which place each '
            'device is in, and the runs between them are counted off the '
            'signal flow.',
      ),
      imageBuilder: image(cablingPng),
      generated: stamp,
    ),
    buildStackedReportSheet(
      sheetName: kRoomWorkbookSheets[4],
      title: title,
      sections: _orPlaceholder(
        rackSections(av),
        'Racks',
        'No rack frames have been drawn for this room.',
      ),
      imageBuilder: image(rackPng),
      generated: stamp,
    ),
    buildStackedReportSheet(
      sheetName: kRoomWorkbookSheets[5],
      title: title,
      sections: [
        ..._orPlaceholder(
          costReportSections(estimate),
          'Cost Estimate',
          'No devices on the diagram to price.',
        ),
        // The devices the control system cannot drive, under the money. The
        // Cost sheet is the one that gets printed and signed on its own, and a
        // room quoted without anybody noticing three undriven boxes is a room
        // that cannot be commissioned when it arrives.
        ...driverGapSections(provider, av),
      ],
      generated: stamp,
    ),
  ]);
}

/// A sheet with no rows would come out as a bare title band, which reads like
/// the export failed. An empty section says so instead.
List<ReportSection> _orPlaceholder(
  List<ReportSection> sections,
  String title,
  String message,
) => sections.isNotEmpty
    ? sections
    : [
        (
          title: title,
          header: const ['Item', 'Value'],
          rows: [
            ['Nothing to report', message],
          ],
        ),
      ];
