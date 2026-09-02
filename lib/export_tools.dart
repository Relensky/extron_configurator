import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'app_state.dart';
import 'av_flow_report.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'cost_estimate.dart';
import 'report_tools.dart';
import 'room_workbook.dart';
import 'schematic_view.dart' show SchematicModel, reportSections;

/// ============================================================================
///  EXPORT NAMING
/// ============================================================================
///  Every export the app writes — a diagram PNG, a report, the room workbook,
///  the project folder — is named for the room it belongs to, so a folder full
///  of them from a dozen rooms still sorts and reads. The rule lived privately
///  in two tabs and is now one function, because a project folder that spelled
///  the room differently from the files inside it would be its own small
///  puzzle.
/// ============================================================================

/// Anything that isn't safe in a file name on Windows, macOS or Linux.
final RegExp _unsafe = RegExp(r'[^\w\-]+');

/// `<BLDG>_<room>_<suffix>` — e.g. `BSS_103_av_flow`.
String roomFileStem(AppStateProvider provider, String suffix) {
  final setup = provider.roomConfig['SYSTEM_SETUP'] ?? {};
  final bldg = provider.bldgAbbreviation(
    (setup['gve_bldg'] ?? 'ROOM').toString(),
  );
  final room = (setup['gve_room'] ?? '').toString();
  return [
    bldg,
    if (room.isNotEmpty) room,
    suffix,
  ].join('_').replaceAll(_unsafe, '_');
}

/// The folder name a Save All writes into: the room's full name as the wizard
/// set it, falling back to building + number when it was never filled in.
///
/// The wizard's name is used in preference to the codes because it is what
/// the room is CALLED — "Bessey 103 Lecture Hall" is findable a year later in
/// a way "BSS_103" is not.
String roomFolderName(AppStateProvider provider) {
  final setup = provider.roomConfig['SYSTEM_SETUP'] ?? {};
  final full = (setup['gui_full_room_name'] ?? '').toString().trim();
  if (full.isNotEmpty) return full.replaceAll(_unsafe, '_');
  final stem = roomFileStem(provider, '');
  final trimmed = stem.replaceAll(RegExp(r'_+$'), '');
  return trimmed.isEmpty ? 'Room' : trimmed;
}

// ---------------------------------------------------------------------------
//  SAVE ALL — the project folder
// ---------------------------------------------------------------------------

/// What a Save All wrote, and what it could not.
class ProjectExport {
  final String folder;

  /// File names written, in the order they were produced.
  final List<String> written;

  /// Things left out, each with the reason — an unopened diagram tab, a
  /// failed capture. Reported rather than silently omitted: a project folder
  /// that is quietly missing the rack elevation is worse than one that says
  /// it is.
  final List<String> skipped;

  const ProjectExport({
    required this.folder,
    required this.written,
    required this.skipped,
  });
}

/// Writes the whole job into `<parent>/<room name>/`.
///
/// One folder per room, named from the wizard's room name, holding everything
/// that took work to produce: the config, both diagram sidecars (the AV one
/// carries the cost estimate), the room workbook, the plain-text reports, the
/// diagram images, and a copy of the custom catalog and rate card so the
/// figures behind the numbers travel with them.
///
/// Diagram images are passed IN because only a widget currently on screen can
/// be rendered; the caller cycles the tabs and hands over what it managed to
/// capture.
Future<ProjectExport> saveProjectFolder({
  required AppStateProvider provider,
  required String parentFolder,
  Uint8List? schematicPng,
  Uint8List? avFlowPng,
  Uint8List? rackPng,
  /// Every plan sheet in the room, one PNG each. A folder that carries the
  /// story that happened to be open is a folder somebody has to come back
  /// for.
  List<({String name, String caption, Uint8List bytes})> floorPlanSheets =
      const [],
  Uint8List? cablingPng,
}) async {
  final folder = Directory(path.join(parentFolder, roomFolderName(provider)));
  await folder.create(recursive: true);

  // One moment for the whole folder: every document in it is the same export,
  // and stamps a few seconds apart would read as documents from two of them.
  final generated = DateTime.now();

  final written = <String>[];
  final skipped = <String>[];
  final stem = roomFileStem(provider, '').replaceAll(RegExp(r'_+$'), '');
  String named(String suffix) => '${stem.isEmpty ? 'room' : stem}_$suffix';

  Future<void> write(String name, FutureOr<void> Function(File) body) async {
    try {
      final file = File(path.join(folder.path, name));
      await body(file);
      written.add(name);
    } catch (e) {
      skipped.add('$name - $e');
      AppLogger.logError('Save All could not write $name', e);
    }
  }

  // --- the config itself ---------------------------------------------------
  const encoder = JsonEncoder.withIndent('    ');
  await write('${named('config')}.json', (f) async {
    await f.writeAsString(encoder.convert(provider.roomConfig));
  });

  // --- the diagrams and the estimate, as data ------------------------------
  final av = buildAvFlowModel(provider);
  await write('${named('av_flow')}.json', (f) async {
    await f.writeAsString(encoder.convert(provider.avFlowAsJson()));
  });

  // --- the workbook --------------------------------------------------------
  await write('${named('room_workbook')}.xlsx', (f) async {
    await f.writeAsBytes(
      buildRoomWorkbookBytes(
        provider: provider,
        av: av,
        controlPng: schematicPng,
        avFlowPng: avFlowPng,
        rackPng: rackPng,
        floorPlanSheets: floorPlanSheets,
        cablingPng: cablingPng,
        generated: generated,
      ),
    );
  });

  // --- the reports, as text ------------------------------------------------
  final control = SchematicModel.build(provider);
  final title = av.roomTitle.isNotEmpty ? av.roomTitle : control.roomTitle;

  await write('${named('device_report')}.txt', (f) async {
    await f.writeAsString(renderTextReport(
      title,
      reportSections(provider, control),
      generated: generated,
    ));
  });
  await write('${named('av_report')}.txt', (f) async {
    await f.writeAsString(renderTextReport(
      title,
      avReportSections(provider, av),
      generated: generated,
    ));
  });

  final estimate = computeRoomCost(
    model: av,
    library: provider.avDeviceLibrary,
    settings: provider.avCost,
    rates: provider.laborRates,
    baseCosts: provider.baseCosts,
    tier: provider.pricingTier,
  );
  final costSections = costReportSections(estimate);
  if (costSections.isEmpty) {
    skipped.add('${named('cost_estimate')}.txt - nothing priced yet');
  } else {
    await write('${named('cost_estimate')}.txt', (f) async {
      await f.writeAsString(
        renderTextReport(
          title,
          // The estimate, then the devices the control system cannot drive. A
          // quote gets signed off on its own, so the warning has to travel
          // with it rather than living only on an AV report nobody opened.
          [...costSections, ...driverGapSections(provider, av)],
          generated: generated,
        ),
      );
    });
  }

  // --- the diagram images --------------------------------------------------
  Future<void> image(String suffix, Uint8List? bytes, String what) async {
    if (bytes == null) {
      skipped.add('${named(suffix)}.png - $what could not be captured');
      return;
    }
    await write('${named(suffix)}.png', (f) async => f.writeAsBytes(bytes));
  }

  await image('control_schematic', schematicPng, 'the control schematic');
  await image('av_flow', avFlowPng, 'the signal flow diagram');
  await image('racks', rackPng, 'the rack elevation');
  // One marked-up drawing per plan sheet. A room with one sheet writes
  // `<room>_floor_plan.png` exactly as it always did; a room with several
  // names each after the sheet it is, so the folder can be read without
  // opening all of them.
  if (floorPlanSheets.isEmpty) {
    skipped.add('${named('floor_plan')}.png - the floor plan '
        'could not be captured');
  }
  for (final sheet in floorPlanSheets) {
    final suffix = floorPlanSheets.length == 1
        ? 'floor_plan'
        : 'floor_plan_'
              '${sheet.caption.replaceAll(_unsafe, '_').toLowerCase()}';
    await image(suffix, sheet.bytes, 'the ${sheet.caption} drawing');
  }
  await image('cabling', cablingPng, 'the cabling drawing');

  // The plan image itself, so the marked-up drawing and the drawing it was
  // marked up on both travel with the room. The sidecar names the file by
  // its bare name, and a folder that carries the reference without the file
  // is a room that opens with a broken plan on somebody else's machine.
  //
  // Every sheet, not just the one that happened to be open: a room with a
  // furniture plan and a reflected ceiling plan is a room whose folder needs
  // both drawings in it, and copying one of them is how the other goes missing
  // on somebody else's machine.
  final sheets = provider.floorPlanSheetsWithImages;
  if (sheets.isEmpty) {
    skipped.add('the floor plan drawings - no sheet has an image');
  }
  final copied = <String>{};
  for (final sheet in sheets) {
    final source = File(provider.resolveFloorPlanImage(sheet.imageFile));
    final name = path.basename(source.path);
    // Two sheets can point at the same drawing; copy it once.
    if (!copied.add(name)) continue;
    if (!source.existsSync()) {
      skipped.add(
        '$name - the drawing for "${sheet.name}" is not where the room says',
      );
    } else {
      await write(name, (f) async => source.copy(f.path));
    }
  }

  // --- a backup of anything custom ----------------------------------------
  // The catalog entries and rate card the figures came from. Without them a
  // folder full of prices is unauditable a year later.
  final customEntries = provider.avDeviceLibrary.all
      .where((e) => e.custom)
      .toList();
  if (customEntries.isEmpty) {
    skipped.add('av_devices.json - no custom catalog entries to back up');
  } else {
    await write('av_devices.json', (f) async {
      await f.writeAsString(
        encoder.convert({
          '__readme':
              'The device catalog entries this room was priced and drawn '
              'from, copied here so the estimate can be audited even after '
              'the shared catalog moves on.',
          'devices': [for (final e in customEntries) e.toJson()],
        }),
      );
    });
  }

  await write('labor_rates.json', (f) async {
    await f.writeAsString(encoder.convert(provider.laborRates.toJson()));
  });

  // The category prices behind any budget lines. Without them a total that
  // was partly a budget looks like a quote a year later.
  if (provider.baseCosts.allUnset) {
    skipped.add('base_costs.json - no base costs are set');
  } else {
    await write('base_costs.json', (f) async {
      await f.writeAsString(encoder.convert(provider.baseCosts.toJson()));
    });
  }

  // --- what is in the folder ----------------------------------------------
  await write('README.txt', (f) async {
    final buffer = StringBuffer()
      ..writeln(title.isEmpty ? 'Room project' : title)
      ..writeln('=' * (title.isEmpty ? 12 : title.length))
      ..writeln()
      ..writeln('Saved ${reportTimestamp(generated)} '
          'by the Room Config Builder.')
      ..writeln()
      ..writeln('Files')
      ..writeln('-----');
    for (final name in written) {
      buffer.writeln('  $name');
    }
    if (skipped.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Not included')
        ..writeln('------------');
      for (final note in skipped) {
        buffer.writeln('  $note');
      }
    }
    await f.writeAsString(buffer.toString());
  });

  AppLogger.logInfo(
    'Save All wrote ${written.length} files to ${folder.path}'
    '${skipped.isEmpty ? '' : ' (${skipped.length} skipped)'}.',
  );
  return ProjectExport(
    folder: folder.path,
    written: written,
    skipped: skipped,
  );
}
