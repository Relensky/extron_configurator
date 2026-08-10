import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'diagram_capture.dart';
import 'export_tools.dart';
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
/// ============================================================================

/// Writes the whole job into one .xlsx: control, AV flow, racks, cost — each
/// sheet illustrated with its own diagram.
Future<void> exportRoomWorkbook(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  final Color actionColor =
      theme.snackBarTheme.actionTextColor ?? theme.colorScheme.onInverseSurface;

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
    );
    await File(saved).writeAsBytes(bytes);

    Future<void> run(Future<String?> Function() action) async {
      final error = await action();
      if (error == null) return;
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
    }

    final ButtonStyle actionStyle = TextButton.styleFrom(
      foregroundColor: actionColor,
      textStyle: const TextStyle(fontWeight: FontWeight.bold),
    );
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Row(
          children: [
            Expanded(
              child: Text(
                'Room workbook saved as ${path.basename(saved)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              style: actionStyle,
              onPressed: () => run(() => provider.openInDesktop(saved)),
              child: const Text('OPEN FILE'),
            ),
            TextButton(
              style: actionStyle,
              onPressed: () => run(() => provider.revealInFileManager(saved)),
              child: const Text('OPEN FOLDER'),
            ),
          ],
        ),
      ),
    );
  } catch (e) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Failed to save the workbook: $e'),
        backgroundColor: Colors.red,
      ),
    );
  }
}
