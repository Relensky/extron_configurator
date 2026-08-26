import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'screenshot_tools.dart';

/// ============================================================================
///  A PICTURE OF THE PLAN
/// ============================================================================
///  The replacement plan is a WIDE, TALL sheet - twenty years across, forty
///  rooms down - and the two places it is read (the Project tab's Lifecycle
///  pane and the campus view) both show it through a window a fraction of its
///  size, scrolling in its own frame. That is right for reading it and useless
///  for handing it over: a screenshot of the window is the eight rooms and six
///  years that happened to be showing.
///
///  So the picture is not a screenshot. The sheet is laid out again at its FULL
///  natural size, with nothing scrolling and nothing clipped, and photographed
///  whole. Two ways in, depending on whether anybody is looking:
///
///    * [showLifecycleSheetPicture] - a preview somebody confirms and saves,
///      which is also where the choice of colour or greyscale is made.
///    * [captureOffscreenSheet] - the same render with nobody watching, for
///      the spreadsheet to drop under its tables.
/// ============================================================================

/// Renders [sheet] at its natural size off the side of the screen and
/// photographs it.
///
/// HOW IT ESCAPES THE WINDOW. An overlay entry is laid into a one-pixel box
/// parked far off the left edge, and an [OverflowBox] hands its child infinite
/// constraints - so the sheet lays out at whatever size it actually wants
/// rather than at the size of the screen, the [RepaintBoundary] is that size,
/// and `toImage` gets the lot. It is on screen for the two frames this takes
/// and nobody sees it, because it is a hundred thousand pixels to the left.
///
/// [OverflowBox] rather than [UnconstrainedBox]: the latter does the same job
/// and prints an overflow warning for every frame of it, which would bury the
/// console every time somebody exports.
///
/// Returns null when the capture fails, which is the caller's cue to write the
/// document without the picture rather than to refuse to write it.
Future<Uint8List?> captureOffscreenSheet(
  BuildContext context,
  Widget sheet, {
  double pixelRatio = 2.0,
}) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  final key = GlobalKey();
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -100000,
      top: 0,
      width: 1,
      height: 1,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: 0,
        maxHeight: double.infinity,
        child: RepaintBoundary(key: key, child: sheet),
      ),
    ),
  );
  overlay.insert(entry);
  try {
    // One frame to build and lay it out, one to paint it. A boundary that has
    // never been painted has no layer to photograph.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    return await captureBoundary(key, pixelRatio: pixelRatio);
  } catch (_) {
    return null;
  } finally {
    // In a finally: an overlay entry left in the tree is a copy of the sheet
    // sitting off the edge of the app for the rest of the session.
    entry.remove();
  }
}

/// Shows [sheet] the way it will be PICTURED, and offers to save the picture.
///
/// The preview is what gets photographed - not a smaller stand-in - so what
/// somebody looked at is exactly what lands in the file, greyscale switch and
/// all. Nested scroll views give it unbounded constraints both ways, which is
/// what lets the boundary be the whole sheet rather than the window over it.
Future<void> showLifecycleSheetPicture(
  BuildContext context, {
  required String dialogTitle,

  /// What the file is called, before `.png`.
  required String fileStem,

  /// What the "saved" message calls it.
  required String what,
  required Widget sheet,
}) => showDialog<void>(
  context: context,
  builder: (_) => _LifecyclePictureDialog(
    dialogTitle: dialogTitle,
    fileStem: fileStem,
    what: what,
    sheet: sheet,
  ),
);

class _LifecyclePictureDialog extends StatefulWidget {
  final String dialogTitle;
  final String fileStem;
  final String what;
  final Widget sheet;

  const _LifecyclePictureDialog({
    required this.dialogTitle,
    required this.fileStem,
    required this.what,
    required this.sheet,
  });

  @override
  State<_LifecyclePictureDialog> createState() =>
      _LifecyclePictureDialogState();
}

class _LifecyclePictureDialogState extends State<_LifecyclePictureDialog> {
  final GlobalKey _boundary = GlobalKey();
  bool _saving = false;

  /// Whether the picture keeps the red-yellow-green.
  ///
  /// ON, because on this particular sheet the colour IS the document: the
  /// whole thing replaces a spreadsheet whose meaning was carried in six
  /// pencils. The mono treatment is one press away for the copy that is going
  /// to be photocopied - and the cells carry their figures as well as their
  /// fill, so a grey one still reads.
  bool _colour = true;

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final provider = context.read<AppStateProvider>();
    setState(() => _saving = true);
    Uint8List? bytes;
    try {
      // Two pixels per logical one: this goes into a budget paper and is read
      // on paper, where a screen-resolution capture of a grid of small figures
      // is unreadable.
      bytes = await captureBoundary(_boundary, pixelRatio: 2.0);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (bytes == null) {
      showTimedSnackBar(
        messenger,
        const SnackBar(content: Text('The plan could not be captured.')),
      );
      return;
    }

    final picked = await FilePicker.saveFile(
      dialogTitle: 'Save ${widget.what.toLowerCase()}',
      fileName: '${widget.fileStem}${_colour ? '' : '_mono'}.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (picked == null) return;
    final target =
        picked.toLowerCase().endsWith('.png') ? picked : '$picked.png';
    try {
      await File(target).writeAsBytes(bytes);
      if (!mounted) return;
      showSavedFileSnack(context, provider, widget.what, target);
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text('The picture could not be written: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return AlertDialog(
      key: const ValueKey('lifecycle_picture_dialog'),
      title: Text(widget.dialogTitle),
      content: SizedBox(
        width: media.size.width * 0.9,
        height: media.size.height * 0.7,
        // Both ways, and both unbounded: the sheet is wider AND taller than
        // any window it is read in, and the boundary has to be the sheet
        // rather than the frame over it.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: RepaintBoundary(
              key: _boundary,
              child: printSkin(enabled: !_colour, child: widget.sheet),
            ),
          ),
        ),
      ),
      actions: [
        // A switch rather than two save buttons: it changes the preview, so
        // what is saved is what was looked at.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              key: const ValueKey('lifecycle_picture_colour'),
              value: _colour,
              onChanged: (v) => setState(() => _colour = v),
            ),
            const SizedBox(width: 4),
            const Text('Plan colours'),
          ],
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('lifecycle_picture_save'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.download, size: 18),
          label: Text(_saving ? 'Capturing…' : 'Save as PNG'),
        ),
      ],
    );
  }
}

/// Writes [bytes] to a file the user picks, and says where it went.
///
/// The one place the two spreadsheet buttons on the two lifecycle screens both
/// come through, so the dialog title, the extension check and the "saved"
/// message cannot drift apart between them.
Future<void> saveLifecycleWorkbook(
  BuildContext context, {
  required String fileStem,
  required String what,
  required Uint8List bytes,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final provider = context.read<AppStateProvider>();

  String? picked = await FilePicker.saveFile(
    dialogTitle: 'Save ${what.toLowerCase()}',
    fileName: '$fileStem.xlsx',
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );
  if (picked == null) return;
  if (!picked.toLowerCase().endsWith('.xlsx')) picked = '$picked.xlsx';

  try {
    await File(picked).writeAsBytes(bytes);
    if (!context.mounted) return;
    showSavedFileSnack(context, provider, what, picked);
  } catch (e) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text('Could not save ${path.basename(picked)}: $e'),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
  }
}
