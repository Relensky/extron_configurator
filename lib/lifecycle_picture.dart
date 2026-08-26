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

/// The longest edge a captured image is allowed to reach, in device pixels.
///
/// A replacement plan that covers every year an estate touches is a WIDE
/// document - thirty years across and forty rooms down is normal - and doubling
/// it for print can put it past what the rasteriser will hand back, which comes
/// out as a capture that simply fails. Rather than trimming the document to fit
/// the photograph, the photograph is taken at whatever density fits: a slightly
/// softer picture of the whole plan beats a crisp one of two thirds of it.
const double kMaxCapturePixels = 7800;

/// The density to photograph a boundary of [size] at.
///
/// [preferred] on anything of a normal size - two device pixels per logical
/// one, because these go into budget papers and get read on paper, where a
/// screen-resolution capture of a grid of small figures is unreadable. Wound
/// back only as far as it has to be, and never below one.
double captureRatioFor(Size? size, {double preferred = 2.0}) {
  if (size == null) return preferred;
  final longest = size.width > size.height ? size.width : size.height;
  if (longest <= 0 || longest * preferred <= kMaxCapturePixels) return preferred;
  final fitted = kMaxCapturePixels / longest;
  return fitted < 1 ? 1 : fitted;
}

/// A row of a plan sheet with the alternating wash behind it.
///
/// A PLAN SEVENTY YEARS ACROSS IS READ BY RUNNING A FINGER ALONG A ROW, and on
/// paper there is no pointer to follow: four feet of white between the name on
/// the left and the figure on the right is where the eye changes rows. The
/// wash is what a ruled ledger did about it.
///
/// The shade is the one the estimate's tables already stripe with, so the two
/// documents look like they came from the same office - and it is a tint of
/// the text colour rather than a grey of its own, so it follows the theme and
/// comes through the mono treatment as a lighter band rather than as a flat
/// grey plate.
class SheetBand extends StatelessWidget {
  final bool shaded;
  final Widget child;

  const SheetBand({super.key, required this.shaded, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!shaded) return child;
    return ColoredBox(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.045),
      child: child,
    );
  }
}

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
    return await captureBoundary(
      key,
      // Asked AFTER the layout, because the whole point of this render is that
      // nothing knew how big the sheet was until it was laid out.
      pixelRatio: captureRatioFor(
        key.currentContext?.size,
        preferred: pixelRatio,
      ),
    );
  } catch (_) {
    return null;
  } finally {
    // In a finally: an overlay entry left in the tree is a copy of the sheet
    // sitting off the edge of the app for the rest of the session.
    entry.remove();
  }
}

/// Photographs [boundary] and writes it where somebody says.
///
/// The one place a lifecycle picture becomes a file: the preview dialog's Save
/// button and the walkthrough's both come through here, so the extension
/// check, the "saved" message and the failure message cannot drift apart
/// between them.
///
/// Returns true when a file was written. False covers both halves of "no file"
/// - a capture that failed, which says so, and a save somebody cancelled,
/// which says nothing.
Future<bool> saveSheetPicture(
  BuildContext context, {
  required GlobalKey boundary,
  required String fileStem,
  required String what,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final provider = context.read<AppStateProvider>();
  final bytes = await captureBoundary(
    boundary,
    // Asked of the boundary itself: the caller knows what it drew, not how
    // big it came out.
    pixelRatio: captureRatioFor(boundary.currentContext?.size),
  );
  if (bytes == null) {
    showTimedSnackBar(
      messenger,
      const SnackBar(content: Text('The plan could not be captured.')),
    );
    return false;
  }

  final picked = await FilePicker.saveFile(
    dialogTitle: 'Save ${what.toLowerCase()}',
    fileName: '$fileStem.png',
    type: FileType.custom,
    allowedExtensions: const ['png'],
  );
  if (picked == null) return false;
  final target = picked.toLowerCase().endsWith('.png') ? picked : '$picked.png';
  try {
    await File(target).writeAsBytes(bytes);
    if (context.mounted) showSavedFileSnack(context, provider, what, target);
    return true;
  } catch (e) {
    showTimedSnackBar(
      messenger,
      SnackBar(content: Text('The picture could not be written: $e')),
    );
    return false;
  }
}

/// Shows [sheet] the way it will be PICTURED, and offers to save the picture.
///
/// The preview is what gets photographed - not a smaller stand-in - so what
/// somebody looked at is exactly what lands in the file, greyscale switch and
/// all. The sheet is laid out at its FULL size either way, which is what lets
/// the boundary be the whole sheet rather than the window over it; the fit
/// switch only changes how that full sheet is drawn on the screen.
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

  /// The two axes of the 1:1 view, held rather than left to the scroll views
  /// so the bars have something to attach to - a sheet thirty years wide with
  /// no bar down its edge is a sheet that LOOKS like it stops at the window.
  final ScrollController _across = ScrollController();
  final ScrollController _down = ScrollController();
  bool _saving = false;

  /// Whether the preview is scaled down to show the WHOLE sheet at once.
  ///
  /// ON. A replacement plan is thirty to seventy years across, the dialog is
  /// one screen wide, and at 1:1 the preview opens on the first dozen years
  /// with the rest of the document off to the right - which reads as a picture
  /// that stops in 2004, not as a picture that needs scrolling. Fitted, the
  /// whole span is on screen the moment it opens and the figures are one
  /// switch away. Either way the sheet is laid out at its full size and the
  /// saved PNG is the full-size one: this changes the view, not the picture.
  bool _fit = true;

  /// Whether the picture keeps the red-yellow-green.
  ///
  /// ON, because on this particular sheet the colour IS the document: the
  /// whole thing replaces a spreadsheet whose meaning was carried in six
  /// pencils. The mono treatment is one press away for the copy that is going
  /// to be photocopied - and the cells carry their figures as well as their
  /// fill, so a grey one still reads.
  bool _colour = true;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await saveSheetPicture(
        context,
        boundary: _boundary,
        // The mono copy is a different document from the colour one and is
        // filed as such.
        fileStem: '${widget.fileStem}${_colour ? '' : '_mono'}',
        what: widget.what,
      );
    } finally {
      // In a finally: a button left spinning is worse than a picture nobody
      // saved, and the dialog stays open either way.
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The sheet itself, at its natural size, inside the boundary that gets
  /// photographed. The same widget in both views - the fit switch scales what
  /// is DRAWN and never what is laid out, so [_save] photographs the full-size
  /// sheet whichever way the preview happens to be showing it.
  Widget get _plate => RepaintBoundary(
    key: _boundary,
    child: printSkin(enabled: !_colour, child: widget.sheet),
  );

  /// The whole sheet, scaled down to the window.
  ///
  /// [BoxFit.scaleDown] rather than contain: a small plan - three rooms and
  /// eight years - is left at its own size rather than blown up into a poster
  /// of six cells.
  Widget get _fitted => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.topLeft,
    child: _plate,
  );

  /// The sheet at 1:1, scrolling both ways with a bar on each.
  ///
  /// Both scroll views are unbounded in their own axis, which is what lets the
  /// boundary be the sheet rather than the frame over it. The bars are always
  /// visible: this is a document somebody is checking before they save it, and
  /// a bar that only appears once you have already found the drag is no help
  /// to somebody who thinks the picture ends at the edge of the window.
  Widget get _actualSize => Scrollbar(
    controller: _down,
    thumbVisibility: true,
    // The vertical bar is watching a scroll view one level DOWN inside the
    // horizontal one, which the default predicate - depth zero only - would
    // never hear from.
    notificationPredicate: (n) => n.depth <= 1,
    child: Scrollbar(
      controller: _across,
      thumbVisibility: true,
      notificationPredicate: (n) => n.depth <= 1,
      child: SingleChildScrollView(
        controller: _across,
        scrollDirection: Axis.horizontal,
        // Room for the bars themselves, so neither one sits on top of the
        // last year column or the bottom row.
        padding: const EdgeInsets.only(right: 14, bottom: 14),
        child: SingleChildScrollView(controller: _down, child: _plate),
      ),
    ),
  );

  @override
  void dispose() {
    _across.dispose();
    _down.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return AlertDialog(
      key: const ValueKey('lifecycle_picture_dialog'),
      title: Text(widget.dialogTitle),
      // Fitted, the box is a CEILING rather than a size: the sheet keeps its
      // proportions on the way down, so a plan seventy years across and eight
      // rooms deep comes out as a wide strip - and the dialog closes up to it
      // instead of standing a screen tall around a band of drawing.
      content: _fit
          ? ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: media.size.width * 0.9,
                maxHeight: media.size.height * 0.7,
              ),
              child: _fitted,
            )
          : SizedBox(
              width: media.size.width * 0.9,
              height: media.size.height * 0.7,
              child: _actualSize,
            ),
      actions: [
        // A switch rather than two save buttons: it changes the preview, so
        // what is saved is what was looked at.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              key: const ValueKey('lifecycle_picture_fit'),
              value: _fit,
              onChanged: (v) => setState(() => _fit = v),
            ),
            const SizedBox(width: 4),
            const Text('Whole sheet'),
            const SizedBox(width: 16),
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
