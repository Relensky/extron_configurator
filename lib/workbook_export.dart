import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'diagram_capture.dart';
import 'building_project.dart';
import 'export_tools.dart';
import 'project_workbook.dart';
import 'room_workbook.dart';

/// ============================================================================
///  EXPORTING THE ROOM WORKBOOK
/// ============================================================================
///  One flow, called from every page that offers the export, because the book
///  it writes is the same book: the tab you happened to press it on should not
///  decide which of the drawings the report ends up illustrated with.
///
///  Getting all three drawings means visiting all three tabs — only a page on
///  screen can be rendered — so this walks them, captures each canvas and puts
///  the user back. That disposes the page the export was started from, which
///  is why the messenger is taken up front and every message afterwards goes
///  through it rather than through a BuildContext that no longer exists.
///
///  TWO BOOKS, AND THE BUTTON ASKS WHICH. A session with a job open has two
///  documents somebody could mean by "the workbook" — this room, and the
///  building it is part of — and the button used to answer that question by
///  itself, always in favour of the room. Which meant the project workbook was
///  reachable only from the Project tab, and somebody standing on a drawing
///  who pressed Export got the wrong book without being told there was another
///  one. See [exportWorkbook].
/// ============================================================================

/// Writes the whole job into one .xlsx: control, AV flow, racks, cost — each
/// sheet illustrated with its own diagram.
Future<void> exportRoomWorkbook(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);

  // The AV data lives in the provider whether or not that tab has been opened
  // this session, but the sidecar is only read on the tab's first visit — so
  // make sure it has been.
  provider.ensureAvFlowForCurrentConfig();

  String? outputFile = await FilePicker.saveFile(
    dialogTitle: 'Save Room Workbook',
    fileName: '${roomFileStem(provider, 'room_workbook')}.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (outputFile == null) return;
  if (!outputFile.toLowerCase().endsWith('.xlsx')) outputFile += '.xlsx';
  final String saved = outputFile;

  // Said before the tabs start moving: a page that flicks through three views
  // on its own looks like a fault unless it says what it is doing.
  showTimedSnackBar(
    messenger,
    const SnackBar(
      duration: Duration(seconds: 3),
      content: Text('Capturing the diagrams for the workbook...'),
    ),
  );

  try {
    final shots = await captureDiagramTabs(provider);
    final bytes = buildRoomWorkbookBytes(
      provider: provider,
      av: buildAvFlowModel(provider),
      controlPng: shots.schematic,
      avFlowPng: shots.avFlow,
      rackPng: shots.racks,
      floorPlanSheets: shots.floorPlanSheets,
      cablingPng: shots.cabling,
    );
    await File(saved).writeAsBytes(bytes);

    showSavedSnackBar(
      messenger: messenger,
      theme: theme,
      provider: provider,
      message: 'Room workbook saved as ${path.basename(saved)}',
      savedPath: saved,
    );
  } catch (e) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Failed to save the workbook: $e'),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  WHICH BOOK
// ---------------------------------------------------------------------------

/// The two documents the workbook button can mean.
enum WorkbookScope {
  /// The open room: every tab of it, illustrated with its drawings.
  room,

  /// The open job: the building total, the equipment list, a tab per vendor
  /// and a tab per room.
  project,
}

/// Writes a workbook, asking which one when the session has both.
///
/// ASKED, NOT INFERRED. A room open inside a job is the ordinary case, and
/// there is no reading of "export the workbook" from a drawing tab that picks
/// one of the two correctly every time — the room while you are drawing it,
/// the building when the quote is going out, and the button cannot tell those
/// apart. With only one of them open there is nothing to ask, and it is
/// written straight off.
Future<void> exportWorkbook(
  BuildContext context,
  AppStateProvider provider,
) async {
  final hasRoom = provider.roomConfig.isNotEmpty;
  final hasProject = provider.hasOpenProject;

  if (!hasProject) return exportRoomWorkbook(context, provider);
  if (!hasRoom) return exportProjectWorkbook(context, provider);

  final scope = await showDialog<WorkbookScope>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('workbook_scope_dialog'),
      title: const Text('Which workbook?'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const ValueKey('workbook_scope_room'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.meeting_room),
              title: Text(
                roomFolderName(provider).replaceAll('_', ' '),
              ),
              subtitle: const Text(
                'This room on its own: control, signal flow, locations, '
                'cabling, racks, the estimate and the replacement plan, each '
                'sheet illustrated with its own drawing.',
              ),
              onTap: () => Navigator.of(ctx).pop(WorkbookScope.room),
            ),
            const Divider(),
            ListTile(
              key: const ValueKey('workbook_scope_project'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.domain),
              title: Text(
                provider.project.name.trim().isEmpty
                    ? 'This project'
                    : provider.project.name.trim(),
              ),
              subtitle: Text(
                'The whole job: the building total, the equipment list, a tab '
                'per vendor and a tab for each of its '
                '${provider.project.rooms.length} room'
                '${provider.project.rooms.length == 1 ? '' : 's'}.',
              ),
              onTap: () => Navigator.of(ctx).pop(WorkbookScope.project),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('workbook_scope_cancel'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );

  if (scope == null || !context.mounted) return;
  return scope == WorkbookScope.room
      ? exportRoomWorkbook(context, provider)
      : exportProjectWorkbook(context, provider);
}

/// The building as one .xlsx.
///
/// Here rather than on the Project tab so the toolbar can write it from
/// anywhere — the same argument the room workbook's own move up here was made
/// on. The tab's button calls this too, so there is one flow and one file
/// name.
Future<void> exportProjectWorkbook(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  final estimate = provider.priceProject();

  if (estimate.rooms.isEmpty) {
    showTimedSnackBar(
      messenger,
      const SnackBar(
        content: Text('Add some rooms first - there is nothing to write.'),
      ),
    );
    return;
  }

  final picked = await FilePicker.saveFile(
    dialogTitle: 'Save the project workbook',
    fileName: '${projectFileStem(provider.project)}_project.xlsx',
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );
  if (picked == null) return;
  final target =
      picked.toLowerCase().endsWith('.xlsx') ? picked : '$picked.xlsx';

  try {
    await File(target).writeAsBytes(
      buildProjectWorkbookBytes(
        estimate: estimate,
        // The catalog prices the replacement plan's sheet. The estimate does
        // not carry one, so it is handed over here where there is a provider.
        library: provider.avDeviceLibrary,
        tier: provider.pricingTier,
      ),
    );
    showSavedSnackBar(
      messenger: messenger,
      theme: theme,
      provider: provider,
      message: 'Project workbook saved as ${path.basename(target)}',
      savedPath: target,
    );
  } catch (e) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('The workbook could not be written: $e'),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
  }
}

/// A project's name as a file name — `Bessey_Hall`.
///
/// Public and here rather than private to the Project tab, because two places
/// now write a file named after the job and a book that came out under two
/// different names depending on which button produced it would be its own
/// small puzzle.
String projectFileStem(BuildingProject project) {
  final raw = project.name.trim().isNotEmpty
      ? project.name
      : project.building.trim().isNotEmpty
          ? project.building
          : 'project';
  return raw
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
}
