import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'building_project.dart';
import 'project_estimate.dart';
import 'room_sidecar.dart';

/// ============================================================================
///  PUTTING A PRICE ON A PART FROM THE PROJECT TAB
/// ============================================================================
///  A job with three unpriced parts on it has a total that is short by an
///  unknown amount, and until now the only way to fix that was to open each
///  room in turn, find the line, and type the figure — for every room the part
///  appears in. The parts list is where the problem is visible, so it is where
///  the fix belongs.
///
///  THERE ARE TWO ANSWERS AND THEY ARE NOT THE SAME, which is why this offers
///  both rather than picking one:
///
///    * THE CATALOG is right when the part simply had no price on file. The
///      figure is a fact about the product, every room prices from it on the
///      next refresh, and the next job gets it too. Nothing in any room file
///      changes.
///    * THIS JOB ONLY is right when the figure is a negotiated one — a
///      discount for the quantity, a price this customer was quoted. It is
///      written as a per-room override, so the catalog keeps saying list price
///      and this job says what was agreed.
///
///  THE ROOM FILES ARE WRITTEN, and the header of project_view.dart says the
///  Project tab does not do that. This is the deliberate exception, and it
///  earns the exception the same way [applyProjectSwap] does: one part, one
///  figure, every room named in the result, and the OPEN room never written
///  behind the editor's back — its override goes into memory so the user saves
///  it themselves and can see what changed first.
/// ============================================================================

/// What a job-wide price actually did.
typedef ProjectPriceResult = ({
  /// Room files written.
  int roomsWritten,

  /// True when the open room was changed in memory instead of on disk.
  bool openRoomChanged,

  /// Rooms that could not be written, with the reason.
  List<String> failures,
});

/// Writes [price] as this job's price for [line], room by room.
///
/// Only the rooms the part is actually in, and only the keys those rooms file
/// it under — see [MasterPartLine.lineKeysByRoom]. Rooms excluded from the
/// total are written too: an alternate that is being priced is still being
/// priced, and leaving it out would make choosing it later reintroduce the
/// blank.
Future<ProjectPriceResult> priceAcrossProject({
  required AppStateProvider provider,
  required MasterPartLine line,
  required double price,
}) async {
  var written = 0;
  var openRoomChanged = false;
  final failures = <String>[];

  for (final ref in provider.project.rooms) {
    final keys = line.lineKeysByRoom[ref.id];
    if (keys == null || keys.isEmpty) continue; // not in this room

    final absolute = BuildingProject.resolvePath(
      ref.configPath,
      provider.currentProjectPath,
    );

    // THE OPEN ROOM IS NOT A FILE, it is what somebody is looking at. Writing
    // its file underneath the editor would be overwritten by the next save and
    // would make the screen disagree with the disk in between.
    if (provider.openProjectRoom?.id == ref.id) {
      for (final key in keys) {
        provider.setAvCostPrice(key, price);
      }
      openRoomChanged = true;
      continue;
    }

    try {
      _writeOverrides(absolute, keys, price);
      written++;
      AppLogger.logInfo(
        'Project price: ${ref.fallbackName} — ${line.description} set to '
        '$price on ${keys.length} line(s).',
      );
    } catch (e, stack) {
      AppLogger.logError('Could not price ${line.description} in $absolute', e,
          stack);
      failures.add('${ref.fallbackName} — $e');
    }
  }

  // Whatever those rooms said a moment ago is not what they say now.
  provider.refreshProjectRooms();
  return (
    roomsWritten: written,
    openRoomChanged: openRoomChanged,
    failures: failures,
  );
}

/// Adds [price] under every key in [keys] to the room's cost sidecar.
///
/// Read-modify-write of that one file, so nothing else about the room is
/// touched — not the config, not the drawing, not the racks. A room whose cost
/// lives in an old single-file document gets a companion `_cost.json`, which is
/// what the merge on the way back in already prefers.
void _writeOverrides(String configPath, Set<String> keys, double price) {
  if (configPath.isEmpty) throw StateError('this room has no file');
  if (!File(configPath).existsSync()) {
    throw StateError('the config is not at $configPath');
  }

  // What the room says now, through the same reader the estimate uses, so an
  // old-format room is understood exactly as it is elsewhere.
  final loaded = readRoomFromDisk(configPath);
  if (loaded.error.isNotEmpty) throw StateError(loaded.error);

  final settings = loaded.settings;
  for (final key in keys) {
    settings.priceOverrides[key] = price;
  }

  final target = roomSidecarPath(configPath, RoomSidecarPart.cost);
  const encoder = JsonEncoder.withIndent('  ');
  File(target)
    ..createSync(recursive: true)
    ..writeAsStringSync(encoder.convert({
      '__readme': 'This room\'s cost estimate: tax, fees, labor, quoted prices '
          'and the lines added by hand. The rates and base costs it draws on '
          'are shared files in the Root Folder, not here.',
      'cost': settings.toJson(),
    }));
}

/// Writes [price] into the catalog entry for [line]'s model, creating the
/// entry when the catalog has never heard of it.
///
/// Returns the file written, or a message beginning with 'Error'.
///
/// An UPSERT that keeps what is already there: a part number somebody found,
/// the rack height, the ports, the education price. The bug this avoids is the
/// obvious one — writing a fresh entry with one field filled in over an entry
/// that had six.
Future<String> priceInCatalog({
  required AppStateProvider provider,
  required MasterPartLine line,
  required double price,
}) async {
  final model = line.model.trim();
  if (model.isEmpty) {
    return 'Error: this part has no model, so there is nothing for the '
        'catalog to file a price under. Price it on this job instead.';
  }

  final existing = provider.avDeviceLibrary.templateForModel(model);
  provider.avDeviceLibrary.upsert(
    existing != null
        ? existing.copyWith(price: price)
        : AvDeviceTemplate(
            model: model,
            manufacturer: line.manufacturer.trim(),
            partNumber: line.partNumber.trim(),
            category: line.category.trim(),
            price: price,
            ports: const [],
          ),
  );

  final saved = await provider.saveAvDeviceLibrary();
  if (saved.isEmpty) {
    return 'Error: the catalog could not be written — check the Catalog tab.';
  }
  // Every room prices from the catalog, so every room's figure just moved.
  provider.refreshProjectRooms();
  AppLogger.logInfo(
    'Catalog price: "$model" set to $price from the project parts list '
    '(${existing == null ? 'new entry' : 'existing entry updated'}).',
  );
  return saved;
}

/// The rooms on this project that carry [line], by name — what the confirm
/// dialog lists before anything is written.
List<String> roomsCarrying(AppStateProvider provider, MasterPartLine line) => [
      for (final ref in provider.project.rooms)
        if ((line.lineKeysByRoom[ref.id] ?? const <String>{}).isNotEmpty)
          ref.label.trim().isNotEmpty
              ? ref.label.trim()
              : path.basenameWithoutExtension(ref.configPath),
    ];
