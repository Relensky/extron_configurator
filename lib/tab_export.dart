import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_report.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'cost_estimate.dart';
import 'diagram_capture.dart';
import 'export_tools.dart';
import 'report_tools.dart';
import 'schematic_view.dart' show SchematicModel, reportSections;
import 'xlsx_writer.dart';

/// ============================================================================
///  EXPORTING ONE TAB
/// ============================================================================
///  The room workbook is the whole job in one book, and it is the wrong thing
///  to send four times out of five: the electrician wants the run schedule, the
///  purchasing office wants the estimate, and neither wants the other four
///  sheets. Some tabs grew their own export button over time and some never
///  did, so "can I get this as a spreadsheet" depended on which page you were
///  standing on.
///
///  This gives EVERY tab the same three answers, dealt from the same section
///  builders the workbook deals from — so a figure cannot come out different
///  depending on which button produced the document:
///
///    * a spreadsheet (.xlsx), illustrated with the tab's own drawing when it
///      has one on screen;
///    * a plain-text file (.txt), which is what goes in a ticket;
///    * the same text on the clipboard, which is what goes in an email.
///
///  The tab's OWN buttons are left where they are. This is the floor under
///  them, on the toolbar beside the workbook button, so the answer is in the
///  same place on every page.
/// ============================================================================

/// The three ways one tab's tables come out. 'copy' touches no disk.
const List<String> kTabExportFormats = ['xlsx', 'txt', 'copy'];

/// True when [tab] has tables worth exporting at all. The Wizard and App
/// Config are settings pages, not documents.
bool tabCanExport(AppTab tab) => switch (tab) {
  AppTab.wizard || AppTab.appConfig => false,
  _ => true,
};

/// What the export button calls this tab's document.
String tabExportLabel(AppTab tab) => switch (tab) {
  AppTab.devices => 'Devices',
  AppTab.system => 'System',
  AppTab.rawJson => 'Config JSON',
  AppTab.schematic => 'Control report',
  AppTab.avFlow => 'AV report',
  AppTab.floorPlan => 'Locations',
  AppTab.cabling => 'Run schedule',
  AppTab.racks => 'Rack elevations',
  AppTab.cost => 'Cost estimate',
  AppTab.deviceEditor => 'Catalog',
  AppTab.wizard || AppTab.appConfig => 'This tab',
};

/// The file-name stem, under the room's own name.
String _stem(AppTab tab) => switch (tab) {
  AppTab.devices => 'devices',
  AppTab.system => 'system',
  AppTab.rawJson => 'config',
  AppTab.schematic => 'control_report',
  AppTab.avFlow => 'av_report',
  AppTab.floorPlan => 'locations',
  AppTab.cabling => 'run_schedule',
  AppTab.racks => 'racks',
  AppTab.cost => 'cost_estimate',
  AppTab.deviceEditor => 'device_catalog',
  AppTab.wizard || AppTab.appConfig => 'room',
};

/// The tables [tab] is a view of.
///
/// Every one of these is a call the workbook or that tab's own report already
/// makes. Nothing new is computed here — this only decides which of them
/// belongs to which page.
List<ReportSection> tabReportSections(
  AppStateProvider provider,
  AppTab tab, {
  /// Passed when the caller already has it; built otherwise. Not built at all
  /// for the catalog, which is not about a room.
  AvFlowModel? model,
}) {
  if (tab == AppTab.deviceEditor) return _catalogSections(provider);
  final av = model ?? buildAvFlowModel(provider);
  switch (tab) {
    case AppTab.devices:
    case AppTab.system:
    case AppTab.rawJson:
    case AppTab.schematic:
      // One document: the control system as configured. The Devices, System
      // and Raw JSON tabs are three views of that same file, and a "devices
      // only" sheet that leaves out which processor they are wired to is a
      // sheet somebody has to ask a follow-up question about.
      return [
        ...reportSections(provider, SchematicModel.build(provider)),
        if (tab == AppTab.schematic) ...powerSections(av),
      ];
    case AppTab.avFlow:
      return avReportSections(provider, av);
    case AppTab.floorPlan:
      return locationSections(av);
    case AppTab.cabling:
      return cablingSections(av);
    case AppTab.racks:
      return [...rackSections(av), ...powerSections(av)];
    case AppTab.cost:
      return [
        ...costReportSections(
          computeRoomCost(
            model: av,
            library: provider.avDeviceLibrary,
            settings: provider.avCost,
            rates: provider.laborRates,
            baseCosts: provider.baseCosts,
            tier: provider.pricingTier,
          ),
        ),
        // The devices no control module claims, under the money — the same
        // warning the Cost sheet of the workbook carries, for the same reason:
        // this is the page that gets printed and signed on its own.
        ...driverGapSections(provider, av),
      ];
    case AppTab.deviceEditor:
      return _catalogSections(provider);
    case AppTab.wizard:
    case AppTab.appConfig:
      return const [];
  }
}

/// The equipment catalog as a table. Not a room document at all — it is the
/// price list — which is exactly why it is worth being able to hand over: a
/// catalog somebody can only read inside this app is a catalog nobody checks.
List<ReportSection> _catalogSections(AppStateProvider provider) {
  final entries = [...provider.avDeviceLibrary.all]..sort((a, b) {
    final byCategory = a.category.toLowerCase().compareTo(
      b.category.toLowerCase(),
    );
    return byCategory != 0
        ? byCategory
        : a.model.toLowerCase().compareTo(b.model.toLowerCase());
  });
  if (entries.isEmpty) return const [];
  return [
    (
      title: 'Device catalog (${entries.length} models)',
      header: const [
        'Model',
        'Manufacturer',
        'Part number',
        'Category',
        'Rack U',
        'Clear above/below',
        'Cable length (ft)',
        'Power (W)',
        'MSRP',
        'Education',
        'Status',
      ],
      rows: [
        for (final e in entries)
          [
            e.model,
            e.manufacturer,
            e.partNumber,
            e.category,
            e.rackUnits == 0 ? '' : '${e.rackUnits}U',
            e.clearanceAboveU == 0 && e.clearanceBelowU == 0
                ? ''
                : '${e.clearanceAboveU} / ${e.clearanceBelowU}',
            e.cableLengthFt == 0 ? '' : trimNumber(e.cableLengthFt),
            e.powerWatts == 0 ? '' : trimNumber(e.powerWatts),
            e.price == 0 ? '' : trimNumber(e.price),
            e.educationPrice == 0 ? '' : trimNumber(e.educationPrice),
            [
              if (e.retired) 'retired',
              if (e.custom) 'local',
            ].join(', '),
          ],
      ],
    ),
  ];
}

/// Writes [tab]'s tables as a spreadsheet or a text file, or puts the text on
/// the clipboard. [what] is one of [kTabExportFormats].
///
/// The caller may be disposed by the time this finishes (a save dialog is a
/// long time), so the messenger is taken up front and every message afterwards
/// goes through it.
Future<void> exportTabReport(
  BuildContext context,
  AppStateProvider provider,
  AppTab tab,
  String what,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  // The catalog is the app's price list rather than a room document, so it is
  // exportable with no room loaded — and building a diagram for a room that
  // isn't there is both pointless and slow.
  final model = tab == AppTab.deviceEditor ? null : buildAvFlowModel(provider);
  final sections = tabReportSections(provider, tab, model: model);
  final label = tabExportLabel(tab);
  final title = (model?.roomTitle ?? '').isEmpty ? label : model!.roomTitle;

  if (sections.isEmpty) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Nothing on the $label tab to export yet — it has no tables until '
          'the room has something on it.',
        ),
      ),
    );
    return;
  }

  if (what == 'copy') {
    await Clipboard.setData(
      ClipboardData(text: renderTextReport(title, sections)),
    );
    messenger.showSnackBar(
      SnackBar(content: Text('$label copied to the clipboard.')),
    );
    return;
  }

  final ext = what == 'xlsx' ? 'xlsx' : 'txt';
  String? outputFile = await FilePicker.saveFile(
    dialogTitle: 'Save $label',
    fileName: '${roomFileStem(provider, _stem(tab))}.$ext',
    type: FileType.custom,
    allowedExtensions: [ext],
  );
  if (outputFile == null) return;
  if (!outputFile.toLowerCase().endsWith('.$ext')) outputFile += '.$ext';
  final saved = outputFile;

  try {
    if (ext == 'xlsx') {
      // One moment for the whole book: sheets stamped seconds apart read as
      // documents from two different exports.
      final generated = DateTime.now();
      // The Locations tab holds a drawing per sheet in the room rather than
      // one drawing, and a set issued with the ceiling plan missing is a set
      // somebody has to ask for again — so that tab hands over all of them,
      // the first under the tables and the rest a tab apiece.
      final drawings = tab == AppTab.floorPlan
          ? await capturePlanSheets(perLayer: true)
          // Every other drawing tab has exactly one, on screen by definition,
          // so there is nothing to visit and nothing to put back.
          : [
              if (await captureCurrentDiagram(tab) case final png?)
                (name: label, caption: label, bytes: png),
            ];
      final first = drawings.isEmpty ? null : drawings.first;
      await File(saved).writeAsBytes(
        buildXlsx([
          buildStackedReportSheet(
            sheetName: label,
            title: title,
            sections: sections,
            generated: generated,
            imageBuilder: first == null
                ? null
                : (anchorRow) => scaledSheetImage(first.bytes, anchorRow),
          ),
          for (final drawing in drawings.skip(1))
            drawingSheet(title, drawing, generated),
        ]),
      );
    } else {
      await File(saved).writeAsString(renderTextReport(title, sections));
    }
    showSavedSnackBar(
      messenger: messenger,
      theme: theme,
      provider: provider,
      message: '$label saved as ${saved.split(Platform.pathSeparator).last}',
      savedPath: saved,
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('Could not save the $label: $e'),
        backgroundColor: Colors.orange.shade800,
      ),
    );
  }
}
