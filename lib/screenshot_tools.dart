import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'contrast.dart';
import 'app_logger.dart';
import 'app_snack.dart';
import 'app_state.dart';

// ============================================================================
// [FEATURE - SCREENSHOTS + ANNOTATION]
// Shared screenshot tooling for every view in the app:
//   * captureBoundary()      - renders a RepaintBoundary (by GlobalKey) to PNG
//                              bytes, including content that is scrolled out
//                              of view inside a SingleChildScrollView.
//   * showAnnotationEditor() - full annotation editor (pen, highlighter,
//                              arrow, rectangle, text) over the captured
//                              image, with undo/clear and Save-as-PNG.
//   * copyImageToClipboard() - puts a PNG on the system clipboard as an
//                              IMAGE, so a picture can go straight into an
//                              email without becoming a file first.
//   * ZoomablePicturePreview - a preview that can be read: scroll bars down
//                              both edges and zoom over the top, for
//                              documents wider or taller than the dialog.
//   * showCapturedPicture()  - the one "here is the picture" dialog every
//                              Save-as-PNG button in the app comes through.
// ============================================================================

/// True while a drawing is being rendered to an image.
///
/// Some of what is on a diagram tab is there to WORK with rather than to
/// issue — the alignment grid is drawn for somebody placing boxes, and has no
/// business on a sheet that goes to a contractor. Those pieces listen here and
/// take themselves off the page for the shot; see `diagram_grid.dart`.
///
/// One flag rather than a parameter threaded through every export: the
/// workbook, the Save All folder and the per-tab PNG buttons all come through
/// [captureBoundary], so covering it here covers every way a picture leaves
/// the app, including the ones added later.
final ValueNotifier<bool> capturingDiagram = ValueNotifier<bool>(false);

/// Renders the RepaintBoundary identified by [boundaryKey] into PNG bytes.
/// Returns null when the boundary isn't mounted or the capture fails.
Future<Uint8List?> captureBoundary(GlobalKey boundaryKey,
    {double pixelRatio = 2.0}) async {
  capturingDiagram.value = true;
  try {
    // The flag has to reach the SCREEN before the photograph is taken: setting
    // it marks the grid dirty, and the boundary is rendered from the last
    // frame that was painted. The timeout is a safety line — a capture must
    // never be the thing that hangs the app if no frame is coming.
    await WidgetsBinding.instance.endOfFrame
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    final ctx = boundaryKey.currentContext;
    // The frame we waited for could have taken the tab off screen.
    if (ctx == null || !ctx.mounted) return null;
    final boundary = ctx.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;

    final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    capturingDiagram.value = false;
  }
}

/// Wraps a drawing so it renders the way it should PRINT: light theme,
/// no color.
///
/// A cabling sheet is a working document. It gets printed, photocopied, marked
/// up on a clipboard and faxed back, and none of that survives a drawing whose
/// only distinction between six Cat 6a and five Cat 5e is that one line is
/// blue. Forcing the light theme as well as dropping the color matters
/// separately: a dark-mode capture converted to grey is a black page with pale
/// lines on it, which a printer renders as a black page.
///
/// This is why the runs carry a dash pattern as well as a color — see
/// `run_painting.dart`. Take the color away and the pattern is what is left.
///
/// [enabled] false returns [child] untouched, so the normal on-screen path
/// costs nothing.
Widget printSkin({required bool enabled, required Widget child}) {
  if (!enabled) return child;
  return Theme(
    // The drawings ask the theme whether they are in dark mode and pick their
    // label and backing-plate colors off the answer.
    data: ThemeData(brightness: Brightness.light, useMaterial3: true),
    child: ColorFiltered(colorFilter: kGreyscaleFilter, child: child),
  );
}

/// Rec. 709 luminance — the same weighting a printer's own color conversion
/// uses, so what comes out of the app matches what comes out of the printer.
const ColorFilter kGreyscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Captures [boundaryKey] and opens the annotation editor over the result.
/// Shows a snackbar when the capture fails.
Future<void> captureAndAnnotate(BuildContext context, GlobalKey boundaryKey,
    {String defaultFileName = 'screenshot.png',
    double pixelRatio = 2.0}) async {
  final bytes = await captureBoundary(boundaryKey, pixelRatio: pixelRatio);
  if (bytes == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Screenshot capture failed.')));
    }
    return;
  }
  if (!context.mounted) return;
  await showAnnotationEditor(context, bytes, defaultFileName: defaultFileName);
}

/// Opens the annotation editor dialog over [pngBytes].
Future<void> showAnnotationEditor(BuildContext context, Uint8List pngBytes,
    {String defaultFileName = 'screenshot.png'}) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24.0),
      child: AnnotationEditor(
        pngBytes: pngBytes,
        defaultFileName: defaultFileName,
      ),
    ),
  );
}

/// The tools on the annotation toolbar.
///
/// Two of them draw nothing:
///
///   * [pan] is the hand. With a drawing tool selected the canvas claims the
///     drag so a stroke is a stroke, which leaves no way to move a picture
///     bigger than the window - see [_AnnotationEditorState.build].
///   * [select] is the pointer, and it is what makes the marks EDITABLE rather
///     than final. Everything on this canvas is a mark until Save turns it
///     into pixels; until then a mark can be picked up, moved, recolored,
///     retyped or thrown away, however many other marks have been made since.
///     See [_AnnotationEditorState._selected].
enum AnnotationTool { pen, highlighter, arrow, rect, text, pan, select }

/// One mark on the picture.
///
/// MUTABLE, deliberately. It used to be write-once - drawn, appended, and
/// beyond reach except by undoing everything after it - which meant a typo in
/// a label was fixed by deleting the three arrows that came after it. The
/// fields that a reader can change after the fact are the ones that can be
/// changed here; [points] was always mutated in place while a stroke was being
/// drawn, and moving a finished mark is the same operation later on.
class _Annotation {
  final AnnotationTool tool;
  Color color;
  double strokeWidth;
  final List<Offset> points; // In IMAGE pixel coordinates.
  String? text;

  _Annotation({
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.points,
    this.text,
  });

  /// Shifts the whole mark by [delta], in image pixels.
  void move(Offset delta) {
    for (var i = 0; i < points.length; i++) {
      points[i] = points[i] + delta;
    }
  }
}

/// How a text mark is set, in one place.
///
/// Shared by the painter and by the hit test, because a label somebody cannot
/// click is a label that is not really editable - and a hit box worked out
/// from a second, slightly different font is exactly how that happens.
TextPainter _textPainterFor(_Annotation a) => TextPainter(
  text: TextSpan(
    text: a.text,
    style: TextStyle(
      color: a.color,
      fontSize: (a.strokeWidth * 4).clamp(16.0, 96.0),
      fontWeight: FontWeight.bold,
      shadows: const [Shadow(blurRadius: 3, color: Colors.black54)],
    ),
  ),
  textDirection: TextDirection.ltr,
)..layout();

/// The box a mark occupies, in image pixels - what the selection halo is drawn
/// round, and what a click on a text label is measured against.
Rect _annotationBounds(_Annotation a) {
  if (a.tool == AnnotationTool.text) {
    if (a.points.isEmpty || a.text == null) return Rect.zero;
    final painter = _textPainterFor(a);
    final rect = a.points.first & painter.size;
    painter.dispose();
    return rect;
  }
  if (a.points.isEmpty) return Rect.zero;
  var rect = Rect.fromPoints(a.points.first, a.points.first);
  for (final point in a.points.skip(1)) {
    rect = rect.expandToInclude(Rect.fromPoints(point, point));
  }
  // The ink is as wide as the pen, and an arrowhead reaches past the last
  // point it was drawn to.
  final width = a.tool == AnnotationTool.highlighter
      ? a.strokeWidth * 3
      : a.strokeWidth;
  return rect.inflate(width);
}

/// How far [point] is from the segment [a]-[b]. The whole of the hit test for
/// anything drawn as a line.
double _distanceToSegment(Offset point, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (point - a).distance;
  final t = (((point - a).dx * ab.dx + (point - a).dy * ab.dy) / lengthSquared)
      .clamp(0.0, 1.0);
  return (point - (a + ab * t)).distance;
}

/// True when [point] (image pixels) lands on [a], within [tolerance].
///
/// MEASURED AGAINST THE SHAPE, not against its bounding box. A rectangle is
/// four lines and not a filled panel: grabbing it by the middle would make
/// every mark underneath a large box unreachable, which on a screenshot of a
/// table is most of them.
bool _annotationHit(_Annotation a, Offset point, double tolerance) {
  final reach =
      tolerance +
      (a.tool == AnnotationTool.highlighter
          ? a.strokeWidth * 1.5
          : a.strokeWidth / 2);
  switch (a.tool) {
    case AnnotationTool.pan:
    case AnnotationTool.select:
      return false;
    case AnnotationTool.text:
      return _annotationBounds(a).inflate(tolerance).contains(point);
    case AnnotationTool.rect:
      if (a.points.length < 2) return false;
      final rect = Rect.fromPoints(a.points.first, a.points.last);
      // On the frame: inside the outer edge and outside the inner one.
      return rect.inflate(reach).contains(point) &&
          !rect.deflate(reach).contains(point);
    case AnnotationTool.arrow:
      if (a.points.length < 2) return false;
      return _distanceToSegment(point, a.points.first, a.points.last) <= reach;
    case AnnotationTool.pen:
    case AnnotationTool.highlighter:
      for (var i = 0; i + 1 < a.points.length; i++) {
        if (_distanceToSegment(point, a.points[i], a.points[i + 1]) <= reach) {
          return true;
        }
      }
      return a.points.length == 1 && (point - a.points.first).distance <= reach;
  }
}

class AnnotationEditor extends StatefulWidget {
  final Uint8List pngBytes;
  final String defaultFileName;

  const AnnotationEditor({
    super.key,
    required this.pngBytes,
    required this.defaultFileName,
  });

  @override
  State<AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends State<AnnotationEditor> {
  ui.Image? _image;
  final List<_Annotation> _annotations = [];

  /// Marks taken off by Undo, so Redo can put them back.
  ///
  /// EMPTIED BY THE NEXT MARK, like every redo in this app: something undone
  /// and then drawn over is gone. This editor was the last place left where an
  /// undo could not be reconsidered, which is what makes people stop pressing
  /// it — and on a screenshot somebody is annotating for a report, a stroke
  /// taken back by mistake means drawing it again by hand.
  final List<_Annotation> _undoneAnnotations = [];

  /// Takes the last mark off and keeps it.
  void _undoAnnotation() => setState(() {
        final gone = _annotations.removeLast();
        if (identical(gone, _selected)) _selected = null;
        _undoneAnnotations.add(gone);
      });

  /// Puts back the mark the last Undo took.
  void _redoAnnotation() =>
      setState(() => _annotations.add(_undoneAnnotations.removeLast()));
  _Annotation? _active; // The annotation being drawn right now.

  /// The mark the pointer has hold of, or null.
  ///
  /// NOTHING HERE IS FINAL UNTIL SAVE. The marks are a list right up to the
  /// moment [_flatten] turns them into pixels, so one made ten marks ago is as
  /// editable as the one just drawn - picked up with the pointer tool, moved,
  /// recolored, retyped, deleted. Before this, the only way back to a mark
  /// was Undo, which meant a typo in the first label cost every arrow drawn
  /// since.
  _Annotation? _selected;

  /// Where the pointer was, in image pixels, on the last drag frame - so a
  /// mark moves BY the pointer rather than jumping its top-left corner to it.
  Offset? _dragFrom;

  /// Where a double-click landed. [GestureDetector.onDoubleTap] is not told a
  /// position, so the down event that preceded it has to remember one.
  Offset? _doubleTapAt;

  /// Keyboard focus for the canvas, so Delete removes what is selected.
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'annotation canvas');

  AnnotationTool _tool = AnnotationTool.pen;
  Color _color = Colors.red;
  double _strokeWidth = 6.0;
  bool _saving = false;

  /// The two axes of the canvas, held rather than left to the scroll views so
  /// the bars have something to attach to and the wheel has something to move.
  final ScrollController _across = ScrollController();
  final ScrollController _down = ScrollController();

  /// null means "fit the whole picture in the window"; a number is that scale.
  ///
  /// Fitted to start with, which is what this canvas has always done - and for
  /// a screenshot of a whole cost estimate that is a picture too small to draw
  /// on accurately, which is the reason the rest of this exists. A mark is
  /// stored in IMAGE coordinates whatever the canvas is showing, so a circle
  /// drawn at 300% lands in the file exactly where it was put.
  double? _zoom;

  static const double _minZoom = 0.1;
  static const double _maxZoom = 8.0;

  static const List<Color> _palette = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.purple,
    Colors.black,
    Colors.white,
  ];

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.pngBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _image = frame.image);
    } else {
      frame.image.dispose();
    }
  }

  @override
  void dispose() {
    _across.dispose();
    _down.dispose();
    _canvasFocus.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// The scale that puts the whole picture inside a [viewW] x [viewH] window.
  ///
  /// Never above 1: a small capture is left at its own size rather than blown
  /// up into a poster of six pixels.
  double _fitScale(ui.Image image, double viewW, double viewH) {
    if (image.width <= 0 || image.height <= 0) return 1;
    final double fit = [
      viewW / image.width,
      viewH / image.height,
      1.0,
    ].reduce((a, b) => a < b ? a : b);
    return fit.clamp(_minZoom, 1.0);
  }

  // --------------------------------------------------------------------------
  // Gestures — local positions are divided by the display scale so every
  // annotation is stored in image-pixel coordinates (resolution independent).
  // --------------------------------------------------------------------------

  /// Moves [controller] by [delta], clamped to what there is to scroll.
  ///
  /// [ScrollController.jumpTo] rather than a drag, because the scroll views
  /// are refusing drags whenever a drawing tool is selected - see the physics
  /// in [build] - and the wheel has to keep working regardless.
  void _wheel(ScrollController controller, double delta) {
    if (delta == 0 || !controller.hasClients) return;
    final position = controller.position;
    if (position.maxScrollExtent <= 0) return;
    controller.jumpTo(
      (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
    );
  }

  /// True while the selected tool is one that makes marks. The pointer and the
  /// hand are the two that do not.
  bool get _drawing =>
      _tool != AnnotationTool.pan && _tool != AnnotationTool.select;

  void _onPanStart(Offset imagePos) {
    if (_tool == AnnotationTool.text || !_drawing) return;
    setState(() {
      _active = _Annotation(
        tool: _tool,
        color: _color,
        strokeWidth: _strokeWidth,
        points: [imagePos, imagePos],
      );
    });
  }

  void _onPanUpdate(Offset imagePos) {
    final active = _active;
    if (active == null) return;
    setState(() {
      if (active.tool == AnnotationTool.pen ||
          active.tool == AnnotationTool.highlighter) {
        active.points.add(imagePos);
      } else {
        // Arrow / rectangle: only the end point moves.
        active.points[active.points.length - 1] = imagePos;
      }
    });
  }

  void _onPanEnd() {
    if (_active == null) return;
    setState(() {
      _undoneAnnotations.clear();
      _annotations.add(_active!);
      _active = null;
    });
  }

  /// Asks for the words on a label. [existing] prefills it, which is what
  /// makes the difference between adding one and correcting one.
  Future<String?> _askText({String existing = ''}) async {
    final controller = TextEditingController(text: existing);
    final adding = existing.isEmpty;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('annotation_text_dialog'),
        title: Text(adding ? 'Add Text' : 'Edit Text'),
        content: TextField(
          key: const ValueKey('annotation_text_field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Annotation text', border: OutlineInputBorder()),
          onSubmitted: (val) => Navigator.of(context).pop(val),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel')),
          ElevatedButton(
              key: const ValueKey('annotation_text_ok'),
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(adding ? 'Add' : 'Save')),
        ],
      ),
    );
  }

  Future<void> _onTapForText(Offset imagePos) async {
    if (_tool != AnnotationTool.text) return;
    final text = await _askText();
    if (text == null || text.trim().isEmpty) return;
    setState(() {
      final added = _Annotation(
        tool: AnnotationTool.text,
        color: _color,
        strokeWidth: _strokeWidth,
        points: [imagePos],
        text: text.trim(),
      );
      _undoneAnnotations.clear();
      _annotations.add(added);
      // Left selected, so the label just placed is the one the next color or
      // size change lands on - and so it is obvious it can still be moved.
      _selected = added;
    });
  }

  /// The topmost mark under [imagePos], or null.
  ///
  /// LAST DRAWN WINS. The list is painted in order, so the mark on top is the
  /// one at the end - and picking anything else would hand back a mark the
  /// reader cannot see under the one they clicked.
  _Annotation? _markAt(Offset imagePos, double scale) {
    // A tolerance in SCREEN pixels, converted: eight pixels of slack is eight
    // pixels of slack whether the picture is at 30% or 300%.
    final tolerance = 8 / (scale <= 0 ? 1 : scale);
    for (final a in _annotations.reversed) {
      if (_annotationHit(a, imagePos, tolerance)) return a;
    }
    return null;
  }

  /// Picks up whatever is under the pointer, or drops what was held.
  void _selectAt(Offset imagePos, double scale) {
    _canvasFocus.requestFocus();
    setState(() => _selected = _markAt(imagePos, scale));
  }

  /// Retypes the label under the pointer - the double-click.
  Future<void> _editTextAt(Offset imagePos, double scale) async {
    final mark = _markAt(imagePos, scale);
    if (mark == null || mark.tool != AnnotationTool.text) return;
    setState(() => _selected = mark);
    await _editSelectedText();
  }

  /// Retypes the label in hand. The reason the pointer tool exists at all:
  /// reached by double-clicking a label, or by the button on the bar.
  Future<void> _editSelectedText() async {
    final mark = _selected;
    if (mark == null || mark.tool != AnnotationTool.text) return;
    final text = await _askText(existing: mark.text ?? '');
    if (text == null) return;
    setState(() {
      if (text.trim().isEmpty) {
        // Emptied means deleted: a label with nothing on it is an invisible
        // mark that still catches clicks.
        _annotations.remove(mark);
        _selected = null;
      } else {
        mark.text = text.trim();
      }
    });
  }

  void _deleteSelected() {
    final mark = _selected;
    if (mark == null) return;
    setState(() {
      _annotations.remove(mark);
      _selected = null;
    });
  }

  /// Drags the held mark by [delta] image pixels.
  void _moveSelected(Offset imagePos) {
    final mark = _selected;
    final from = _dragFrom;
    if (mark == null || from == null) return;
    setState(() {
      mark.move(imagePos - from);
      _dragFrom = imagePos;
    });
  }

  // --------------------------------------------------------------------------
  // THE HAND
  // --------------------------------------------------------------------------
  //  It did nothing at all, and the reason is a Flutter default rather than
  //  anything on this screen: a SingleChildScrollView on desktop does not
  //  accept drags from a MOUSE - only from touch and stylus - so handing the
  //  drag back to the scroll views handed it to something that was never going
  //  to take it. The bars and the wheel worked, which is why it looked like
  //  the tool was simply inert.
  //
  //  So the hand moves the picture itself, through the same controllers the
  //  wheel already uses. The scroll views now refuse drags whatever tool is
  //  selected, which also settles the arena question outright: no drag on this
  //  canvas is ever contested.

  /// Moves the picture under the pointer. [delta] is in SCREEN pixels, which is
  /// what the scroll offsets are in - so this one does not get converted.
  void _dragPicture(Offset delta) {
    _wheel(_across, -delta.dx);
    _wheel(_down, -delta.dy);
  }

  // --------------------------------------------------------------------------
  // Save — composes the original image + annotations at full resolution.
  // --------------------------------------------------------------------------

  /// The screenshot with the marks burnt into it, at full resolution.
  ///
  /// The one place the annotations become pixels: Save writes these bytes to a
  /// file and Copy hands the same bytes to the clipboard, so what gets pasted
  /// and what gets filed can never be two different pictures.
  Future<Uint8List?> _flatten() async {
    final image = _image;
    if (image == null) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());
    // Image space, at full resolution: this is the file, and a mark is stored
    // in image pixels, so there is nothing to convert.
    _paintAnnotationsOnCanvas(canvas, _annotations);
    final picture = recorder.endRecording();
    final ui.Image outImage = await picture.toImage(image.width, image.height);
    final byteData = await outImage.toByteData(format: ui.ImageByteFormat.png);
    outImage.dispose();
    return byteData?.buffer.asUint8List();
  }

  /// The marked-up screenshot straight onto the clipboard.
  ///
  /// The dialog stays open afterwards: a paste that went somewhere wrong is
  /// one Ctrl-V away from being redone, and closing the editor would have
  /// thrown the marks away to find out.
  Future<void> _copy() async {
    if (_image == null || _saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await _flatten();
      if (!mounted) return;
      await copyPictureToClipboard(context, bytes, what: 'The screenshot');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final image = _image;
    if (image == null || _saving) return;
    // Taken before anything is popped: the "saved" bar outlives this dialog,
    // so it cannot be built from a BuildContext that has gone with it.
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    setState(() => _saving = true);

    try {
      final bytes = await _flatten();
      if (bytes == null) throw Exception('PNG encode failed');

      String? outputFile = await FilePicker.saveFile(
        dialogTitle: 'Save Screenshot',
        fileName: widget.defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (outputFile == null) return;
      if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
      await File(outputFile).writeAsBytes(bytes);

      final saved = outputFile;
      if (mounted) Navigator.of(context).pop();
      showSavedSnackBar(
        messenger: messenger,
        theme: theme,
        provider: provider,
        message: 'Screenshot saved as ${p.basename(saved)}',
        savedPath: saved,
      );
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text('Failed to save screenshot: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  Widget _toolButton(AnnotationTool tool, IconData icon, String tooltip) {
    final bool selected = _tool == tool;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _tool = tool),
          child: Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon,
                size: 20,
                // The selected tool's chip is filled with the accent, so its
                // icon is measured against that fill — an icon that carries
                // meaning, so the large-text threshold.
                color: selected
                    ? readableOn(
                        Theme.of(context).colorScheme.primaryContainer,
                        prefer: [
                          Theme.of(context).colorScheme.onPrimaryContainer,
                          Theme.of(context).colorScheme.onSurface,
                        ],
                        minRatio: kContrastLarge,
                      )
                    : null),
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(Color color) {
    final bool selected = _color == color;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: InkWell(
        // A color is both a setting for the next mark and an edit to the one
        // in hand. Picking one while a mark is held recolors it, which is the
        // obvious reading of pressing red with something selected.
        onTap: () => setState(() {
          _color = color;
          _selected?.color = color;
        }),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
                color: selected
                    ? (Theme.of(context).brightness == Brightness.dark
                        ? Colors.white
                        : Colors.black87)
                    : Colors.grey.withValues(alpha: 0.5),
                width: selected ? 2.5 : 1),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Column(
      children: [
        // ----- Toolbar -----
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black26
                : Colors.grey[200],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          // NOTHING FALLS OFF THE EDGE; THE BAR GETS TALLER INSTEAD.
          //
          // This bar was a plain Row of everything, and it had no slack left:
          // narrow the window and Save and Close went off the right-hand edge
          // behind a yellow-and-black overflow bar, where they could not be
          // pressed. Giving the tools a horizontal scroller fixed the buttons
          // and cost the colors instead - a palette somebody has to drag
          // sideways to see is a palette they do not know is there, and the
          // color they want is the one that scrolled away.
          //
          // A screenshot editor is shrunk all the time, because it is opened
          // over whatever it is annotating. So the bar wraps: it is a [Wrap]
          // of GROUPS, each an unbreakable Row, and a group that will not fit
          // beside the one before it drops to the next line. Two lines at a
          // typical dialog width, three when it is really squeezed, one when
          // there is room - and every tool, color and button stays on screen
          // and stays pressable at all of them.
          //
          // Keep the groups small. The widest one sets the narrowest window
          // this bar survives, which is why the drawing tools and the two
          // that move things about are separate groups rather than one row of
          // seven, and why the ways out sit together at the end where they
          // are looked for.
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.photo_camera_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Annotate Screenshot',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              // The five that leave a mark.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _toolButton(AnnotationTool.pen, Icons.edit, 'Pen'),
                  _toolButton(AnnotationTool.highlighter, Icons.border_color,
                      'Highlighter'),
                  _toolButton(AnnotationTool.arrow, Icons.north_east, 'Arrow'),
                  _toolButton(AnnotationTool.rect,
                      Icons.check_box_outline_blank, 'Rectangle'),
                  _toolButton(AnnotationTool.text, Icons.text_fields,
                      'Text (click to place)'),
                ],
              ),
              // The two that draw nothing and move things instead.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // THE POINTER. Nothing here is final until Save, and this
                  // is how that is reached: click a mark to pick it up, drag
                  // to move it, double-click a label to retype it. See
                  // [_selected].
                  _toolButton(AnnotationTool.select, Icons.near_me_outlined,
                      'Select - move, recolor or retype a mark'),
                  // THE HAND. Moves the picture under the pointer, itself -
                  // see [_dragPicture] for why it cannot leave that to the
                  // scroll views.
                  _toolButton(AnnotationTool.pan, Icons.pan_tool_outlined,
                      'Move the picture'),
                ],
              ),
              // THE WHOLE PALETTE, ALWAYS. It is one group so the eight
              // colors are never split across two lines, which would read as
              // two palettes.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: _palette.map(_colorSwatch).toList(),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.line_weight, size: 16),
                  SizedBox(
                    width: 110,
                    child: Slider(
                      value: _strokeWidth,
                      min: 2,
                      max: 20,
                      // Resizes the held mark as well - see [_colorSwatch].
                      onChanged: (val) => setState(() {
                        _strokeWidth = val;
                        _selected?.strokeWidth = val;
                      }),
                    ),
                  ),
                  // STARTING OVER LIVES WITH THE TOOLS, not with the ways
                  // out: it is destructive, and it does not belong next to
                  // the button somebody is aiming for when they want to
                  // finish.
                  IconButton(
                    key: const ValueKey('annotation_clear'),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Clear all annotations',
                    onPressed: _annotations.isEmpty
                        ? null
                        : () => setState(() {
                              _annotations.clear();
                              _undoneAnnotations.clear();
                              _selected = null;
                            }),
                  ),
                ],
              ),
              // BACK AND FORWARD, AND THE ONE MARK IN HAND. Undo is what
              // somebody grabs the instant a stroke goes wrong, and Redo
              // earns its place beside it for the same reason the rest of the
              // app has one - an undo that cannot be reconsidered is an undo
              // people are wary of pressing.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('annotation_undo'),
                    icon: const Icon(Icons.undo, size: 20),
                    tooltip: _annotations.isEmpty
                        ? 'Nothing to undo - no marks on this picture yet'
                        : 'Undo the last mark drawn on this picture',
                    onPressed: _annotations.isEmpty ? null : _undoAnnotation,
                  ),
                  IconButton(
                    key: const ValueKey('annotation_redo'),
                    icon: const Icon(Icons.redo, size: 20),
                    tooltip: _undoneAnnotations.isEmpty
                        ? 'Nothing to redo - nothing has been undone'
                        : 'Redo the mark that was undone',
                    onPressed:
                        _undoneAnnotations.isEmpty ? null : _redoAnnotation,
                  ),
                  // RETYPING, SAID OUT LOUD. Double-clicking the label does
                  // the same thing and is quicker, but a gesture is not an
                  // affordance: somebody who has just clicked a label and can
                  // see it is held needs to be told that its words can be
                  // changed. Lit only for a label, because it is the only
                  // mark that has any.
                  IconButton(
                    key: const ValueKey('annotation_edit_text'),
                    icon: const Icon(Icons.edit_note, size: 20),
                    tooltip: 'Edit the selected text',
                    onPressed: _selected?.tool == AnnotationTool.text
                        ? () => _editSelectedText()
                        : null,
                  ),
                  // The one mark in hand, thrown away without touching the
                  // others - the counterpart of the pointer tool, and what
                  // the Delete key does. Undo only ever reaches the LAST
                  // mark, which is no use for the label three arrows ago.
                  IconButton(
                    key: const ValueKey('annotation_delete_selected'),
                    icon: const Icon(Icons.backspace_outlined, size: 18),
                    tooltip: 'Delete the selected mark',
                    onPressed: _selected == null ? null : _deleteSelected,
                  ),
                ],
              ),
              // THE WAYS OUT, TOGETHER AND LAST. Whichever line they land on,
              // they land on it as a set, in the order somebody reads them.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('annotation_copy'),
                    onPressed: _saving ? null : _copy,
                    icon: const Icon(Icons.copy_all_outlined, size: 16),
                    label: const Text('Copy'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save, size: 16),
                    label: const Text('Save PNG'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close without saving',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
        // ----- Canvas -----
        Expanded(
          child: Container(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black45
                : Colors.grey[350],
            padding: const EdgeInsets.all(12.0),
            child: image == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(builder: (context, constraints) {
                    final double viewW =
                        (constraints.maxWidth - _kBarRoom).clamp(0.0, 1 / 0);
                    final double viewH =
                        (constraints.maxHeight - _kBarRoom).clamp(0.0, 1 / 0);
                    final double scale =
                        _zoom ?? _fitScale(image, viewW, viewH);
                    final double dispW = image.width * scale;
                    final double dispH = image.height * scale;

                    // A MARK IS STORED IN IMAGE PIXELS, always. The canvas is
                    // whatever size the zoom says; dividing by that scale is
                    // what makes a stroke drawn at 300% land in the file where
                    // it was actually put, and survive being drawn again at a
                    // different zoom.
                    Offset toImage(Offset local) => Offset(
                        (local.dx / scale).clamp(0, image.width.toDouble()),
                        (local.dy / scale).clamp(0, image.height.toDouble()));

                    // WHO GETS THE DRAG. There is only one, and the pen, the
                    // pointer, the hand and the scroll views all want it.
                    // Rather than put them in a gesture arena and hope - which
                    // is how a stroke turns into a scroll halfway through a
                    // circle - the canvas takes every drag and decides what it
                    // meant. The scroll views never take one; the bars, the
                    // wheel and the hand move the picture instead.
                    const physics = NeverScrollableScrollPhysics();

                    final Widget plate = SizedBox(
                      key: const ValueKey('annotation_canvas'),
                      width: dispW,
                      height: dispH,
                      child: MouseRegion(
                        cursor: switch (_tool) {
                          AnnotationTool.pan => _dragFrom == null
                              ? SystemMouseCursors.grab
                              : SystemMouseCursors.grabbing,
                          AnnotationTool.select => SystemMouseCursors.click,
                          AnnotationTool.text => SystemMouseCursors.text,
                          _ => SystemMouseCursors.precise,
                        },
                        child: GestureDetector(
                          onTapUp: switch (_tool) {
                            AnnotationTool.select => (d) =>
                                _selectAt(toImage(d.localPosition), scale),
                            AnnotationTool.pan => null,
                            _ => (d) => _onTapForText(toImage(d.localPosition)),
                          },
                          // RETYPING A LABEL, which is the whole of "still
                          // editable until you save". Only on the pointer, so
                          // a fast pair of pen strokes is never mistaken for
                          // it.
                          onDoubleTapDown: _tool == AnnotationTool.select
                              ? (d) => _doubleTapAt = toImage(d.localPosition)
                              : null,
                          onDoubleTap: _tool == AnnotationTool.select
                              ? () {
                                  final at = _doubleTapAt;
                                  if (at != null) _editTextAt(at, scale);
                                }
                              : null,
                          onPanStart: (d) {
                            final at = toImage(d.localPosition);
                            switch (_tool) {
                              case AnnotationTool.pan:
                                // Only so the cursor can say it is holding on.
                                setState(() => _dragFrom = at);
                              case AnnotationTool.select:
                                _selectAt(at, scale);
                                if (_selected != null) _dragFrom = at;
                              default:
                                _onPanStart(at);
                            }
                          },
                          onPanUpdate: (d) {
                            switch (_tool) {
                              case AnnotationTool.pan:
                                _dragPicture(d.delta);
                              case AnnotationTool.select:
                                _moveSelected(toImage(d.localPosition));
                              default:
                                _onPanUpdate(toImage(d.localPosition));
                            }
                          },
                          onPanEnd: (_) {
                            switch (_tool) {
                              case AnnotationTool.pan:
                              case AnnotationTool.select:
                                setState(() => _dragFrom = null);
                              default:
                                _onPanEnd();
                            }
                          },
                          child: CustomPaint(
                            painter: _AnnotationPainter(
                              image: image,
                              annotations: _annotations,
                              active: _active,
                              selected: _selected,
                              scale: scale,
                            ),
                          ),
                        ),
                      ),
                    );

                    return Focus(
                      focusNode: _canvasFocus,
                      // Delete throws away the mark in hand. The button beside
                      // Undo does the same thing for anybody who does not
                      // think to try the key.
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent || _selected == null) {
                          return KeyEventResult.ignored;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.delete ||
                            event.logicalKey == LogicalKeyboardKey.backspace) {
                          _deleteSelected();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Stack(
                      key: const ValueKey('annotation_canvas_area'),
                      children: [
                        Positioned.fill(
                          child: Listener(
                            // The wheel, through the controllers rather than
                            // through the scroll views - so it keeps working
                            // while the views are refusing drags for the pen.
                            onPointerSignal: (event) {
                              if (event is! PointerScrollEvent) return;
                              _wheel(_down, event.scrollDelta.dy);
                              _wheel(_across, event.scrollDelta.dx);
                            },
                            child: Scrollbar(
                              controller: _down,
                              thumbVisibility: true,
                              // The vertical bar watches a scroll view one
                              // level DOWN inside the horizontal one, which
                              // the default predicate - depth zero only -
                              // would never hear from.
                              notificationPredicate: (n) => n.depth <= 1,
                              child: Scrollbar(
                                controller: _across,
                                thumbVisibility: true,
                                notificationPredicate: (n) => n.depth <= 1,
                                child: SingleChildScrollView(
                                  controller: _across,
                                  scrollDirection: Axis.horizontal,
                                  physics: physics,
                                  padding: const EdgeInsets.only(
                                    right: _kBarRoom,
                                    bottom: _kBarRoom,
                                  ),
                                  child: SingleChildScrollView(
                                    controller: _down,
                                    physics: physics,
                                    child: Container(
                                      // Centred while it fits, hard against
                                      // the top-left once it does not: nested
                                      // scroll views hand their child
                                      // unbounded space and would otherwise
                                      // park a small capture in the corner.
                                      constraints: BoxConstraints(
                                        minWidth: viewW,
                                        minHeight: viewH,
                                      ),
                                      alignment: Alignment.center,
                                      child: plate,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Over the picture, in the same corner the preview
                        // dialog puts it - this is the same furniture around
                        // the same kind of picture.
                        Positioned(
                          top: 6,
                          right: _kBarRoom + 6,
                          child: _ZoomBar(
                            keyPrefix: 'annotation',
                            scale: scale,
                            fitted: _zoom == null,
                            onOut: () => setState(
                              () => _zoom =
                                  (scale / 1.25).clamp(_minZoom, _maxZoom),
                            ),
                            onIn: () => setState(
                              () => _zoom =
                                  (scale * 1.25).clamp(_minZoom, _maxZoom),
                            ),
                            onFit: () => setState(() {
                              _zoom = null;
                              // The whole picture is about to be on screen, so
                              // an offset into a version of it three times the
                              // size is not a place to be left looking at.
                              if (_across.hasClients) _across.jumpTo(0);
                              if (_down.hasClients) _down.jumpTo(0);
                            }),
                            onActual: () => setState(() => _zoom = 1.0),
                          ),
                        ),
                      ],
                      ),
                    );
                  }),
          ),
        ),
      ],
    );
  }
}

/// Paints [annotations] on [canvas], in IMAGE coordinates.
///
/// IT DOES NOT TOUCH THE TRANSFORM. It used to take a scale and apply it - and
/// never put it back, so the canvas came out of here still scaled. Anything
/// drawn afterwards was then scaled a second time, which is exactly what
/// happened to the selection halo: right at 100% and adrift at every other
/// zoom, drifting towards the top-left corner the further out you went.
///
/// So the scaling belongs to the CALLER, which is the only one that knows
/// which space it wants to be in - see [_AnnotationPainter.paint], which
/// scales inside a save/restore for the marks and then draws the halo in
/// screen space, and [_AnnotationEditorState._flatten], which wants image
/// space and so scales nothing at all.
void _paintAnnotationsOnCanvas(Canvas canvas, List<_Annotation> annotations) {
  for (final a in annotations) {
    final paint = Paint()
      ..color = a.tool == AnnotationTool.highlighter
          ? a.color.withValues(alpha: 0.35)
          : a.color
      ..strokeWidth =
          a.tool == AnnotationTool.highlighter ? a.strokeWidth * 3 : a.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = a.tool == AnnotationTool.highlighter
          ? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (a.tool) {
      // Never reaches here: neither the hand nor the pointer draws anything,
      // so no annotation is ever recorded carrying one. Named rather than left
      // to a default, so adding a real tool later is a compile error here
      // instead of a silent no-op.
      case AnnotationTool.pan:
      case AnnotationTool.select:
        break;

      case AnnotationTool.pen:
      case AnnotationTool.highlighter:
        if (a.points.length < 2) break;
        final path = Path()..moveTo(a.points.first.dx, a.points.first.dy);
        for (final p in a.points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, paint);
        break;

      case AnnotationTool.arrow:
        if (a.points.length < 2) break;
        final start = a.points.first;
        final end = a.points.last;
        canvas.drawLine(start, end, paint);
        // Arrowhead: two short lines back from the tip.
        final direction = (end - start);
        if (direction.distance > 1) {
          final unit = direction / direction.distance;
          final normal = Offset(-unit.dy, unit.dx);
          final double headLen = (a.strokeWidth * 3).clamp(10.0, 40.0);
          final base = end - unit * headLen;
          canvas.drawLine(end, base + normal * (headLen / 2), paint);
          canvas.drawLine(end, base - normal * (headLen / 2), paint);
        }
        break;

      case AnnotationTool.rect:
        if (a.points.length < 2) break;
        canvas.drawRect(Rect.fromPoints(a.points.first, a.points.last), paint);
        break;

      case AnnotationTool.text:
        if (a.points.isEmpty || a.text == null) break;
        final textPainter = TextPainter(
          text: TextSpan(
            text: a.text,
            style: TextStyle(
              color: a.color,
              fontSize: (a.strokeWidth * 4).clamp(16.0, 96.0),
              fontWeight: FontWeight.bold,
              shadows: const [
                Shadow(blurRadius: 3, color: Colors.black54),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        textPainter.paint(canvas, a.points.first);
        break;
    }
  }
}

class _AnnotationPainter extends CustomPainter {
  final ui.Image image;
  final List<_Annotation> annotations;
  final _Annotation? active;

  /// The mark in hand, drawn with a halo round it. ON SCREEN ONLY - see
  /// [paint]: this is furniture for editing, and burning it into the saved
  /// picture would put a dashed box round whichever mark happened to be
  /// selected when somebody pressed Save.
  final _Annotation? selected;

  final double scale;

  _AnnotationPainter({
    required this.image,
    required this.annotations,
    required this.active,
    required this.selected,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the screenshot scaled to the display size.
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
    // THE MARKS, IN IMAGE SPACE. Saved and restored around, so the canvas
    // comes back in screen space for the halo below - see
    // [_paintAnnotationsOnCanvas], which no longer does this for itself.
    canvas.save();
    canvas.scale(scale);
    _paintAnnotationsOnCanvas(canvas, [...annotations, ?active]);
    canvas.restore();

    final held = selected;
    if (held == null) return;
    // THE HALO, IN SCREEN SPACE. Converted once, here, so it lands on the mark
    // at any zoom - and so its stroke and its margin stay the same weight
    // however far out the picture is: it is a handle, not part of the picture.
    final box = _annotationBounds(held);
    if (box.isEmpty) return;
    final rect = Rect.fromLTRB(
      box.left * scale,
      box.top * scale,
      box.right * scale,
      box.bottom * scale,
    ).inflate(4);
    // Two strokes, light over dark, so the halo is visible on a screenshot of
    // anything - a white dialog or a black diagram.
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => true;
}

// ============================================================================
// [FEATURE - COPY THE PICTURE]
// Every screenshot in this app ends up in one of two places: a file somebody
// attaches, and a paste into an email, a ticket or a chat. Only the first of
// those had a button, so the second one meant saving a PNG nobody wanted to
// keep, pasting it, and then remembering to go and delete it.
// ============================================================================

/// The PowerShell that hands a PNG to the Windows clipboard.
///
/// Two formats go on at once deliberately. Anything modern - Outlook, Word,
/// Teams, a browser - asks for `PNG` and gets the transparency; everything
/// older asks for the bitmap, which has no alpha at all, so the bitmap copy is
/// flattened onto white first. Without that a drawing with a transparent
/// background pastes as a black rectangle.
const String _windowsClipboardScript = r'''
param([Parameter(Mandatory = $true)][string]$Path)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bytes = [System.IO.File]::ReadAllBytes($Path)
$stream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (,$bytes)
$source = [System.Drawing.Image]::FromStream($stream)
$flat = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $source.Width, $source.Height
$canvas = [System.Drawing.Graphics]::FromImage($flat)
$canvas.Clear([System.Drawing.Color]::White)
$canvas.DrawImage($source, 0, 0, $source.Width, $source.Height)
$canvas.Dispose()
$data = New-Object System.Windows.Forms.DataObject
$data.SetData('PNG', $false, $stream)
$data.SetImage($flat)
# $true: the picture has to outlive this process, which exits a line later.
# The 10 x 100ms retry is not optional on Windows - the clipboard is a single
# global lock, and any app that happens to be reading it at this instant makes
# the first attempt throw "Requested Clipboard operation did not succeed".
[System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
''';

/// Puts [png] on the system clipboard as an IMAGE.
///
/// Flutter's own [Clipboard] only carries text, so this goes out to the tool
/// every desktop already ships with rather than adding a plugin: the bytes are
/// written to a scratch file and the platform is asked to read it back.
///
/// Returns null when it worked, else a message fit to show somebody.
Future<String?> copyImageToClipboard(Uint8List png) async {
  Directory? scratch;
  try {
    scratch = await Directory.systemTemp.createTemp('rcb_clipboard');
    final picture = File(p.join(scratch.path, 'clipboard.png'));
    await picture.writeAsBytes(png);

    if (Platform.isWindows) {
      // A script FILE rather than -Command: the script has quotes, backticks
      // and dollars in it, and every one of them would otherwise have to
      // survive two levels of escaping on the way through a command line.
      final script = File(p.join(scratch.path, 'clipboard.ps1'));
      await script.writeAsString(_windowsClipboardScript);
      final run = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        // The Windows clipboard is a single-threaded-apartment API and throws
        // outright when it is called from anywhere else.
        '-STA',
        '-File',
        script.path,
        '-Path',
        picture.path,
      ]);
      if (run.exitCode != 0) return _clipboardFailure(run.stderr.toString());
      return null;
    }

    if (Platform.isMacOS) {
      final run = await Process.run('osascript', [
        '-e',
        'set the clipboard to '
            '(read (POSIX file "${picture.path}") as «class PNGf»)',
      ]);
      if (run.exitCode != 0) return _clipboardFailure(run.stderr.toString());
      return null;
    }

    // Linux has two display servers and one clipboard tool for each. Try
    // Wayland's first, then X11's, and only complain when neither is there.
    String trouble = '';
    for (final tool in const [
      ('wl-copy', ['--type', 'image/png']),
      ('xclip', ['-selection', 'clipboard', '-t', 'image/png', '-i']),
    ]) {
      try {
        final process = await Process.start(tool.$1, tool.$2);
        process.stdin.add(png);
        await process.stdin.close();
        if (await process.exitCode == 0) return null;
        trouble = '${tool.$1} failed';
      } catch (_) {
        trouble = '${tool.$1} is not installed';
      }
    }
    AppLogger.logInfo('Clipboard image copy failed on Linux: $trouble');
    return 'Copying a picture needs wl-copy or xclip installed.';
  } catch (e, stack) {
    AppLogger.logError('Could not copy a picture to the clipboard', e, stack);
    return 'The picture could not be copied to the clipboard.';
  } finally {
    // The scratch file is a copy of something that may be commercially
    // sensitive; it does not get left behind in the temp folder.
    try {
      await scratch?.delete(recursive: true);
    } catch (_) {}
  }
}

/// Turns whatever the platform tool complained about into one line on screen,
/// and the whole of it into the log.
String _clipboardFailure(String stderr) {
  final trimmed = stderr.trim();
  AppLogger.logInfo(
    'Clipboard image copy failed: '
    '${trimmed.isEmpty ? '(no output)' : trimmed}',
  );
  return 'The picture could not be copied to the clipboard.';
}

/// Copies [png] and says so, in the one wording every screenshot uses.
///
/// [what] names the picture in the message - "The estimate", "The matrix".
Future<void> copyPictureToClipboard(
  BuildContext context,
  Uint8List? png, {
  String what = 'The picture',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (png == null) {
    showTimedSnackBar(
      messenger,
      SnackBar(content: Text('$what could not be captured.')),
    );
    return;
  }
  final failure = await copyImageToClipboard(png);
  showTimedSnackBar(
    messenger,
    SnackBar(
      content: Text(failure ?? '$what is on the clipboard - paste it in.'),
    ),
  );
}

// ============================================================================
// [FEATURE - LOOK AT THE PICTURE BEFORE IT GOES]
// A preview is only a preview if it can actually be read. A responsibility
// matrix is wider than the dialog, a cost estimate is taller than the screen,
// and a preview that silently clips either one is a preview that lies about
// what is in the file.
// ============================================================================

/// Room kept clear along the two edges the scroll bars run down, so neither
/// one sits on top of the last column of the document under it.
///
/// One figure for both the preview and the annotation canvas: they are the
/// same furniture around the same kind of picture, and a reader moving between
/// them should not find the bars in two different places.
const double _kBarRoom = 16;

/// [child] at whatever size it wants to be, inside bars, with zoom over it.
///
/// The child is always LAID OUT at its natural size and only ever DRAWN
/// scaled, which is the whole point: a [RepaintBoundary] inside it photographs
/// the full-size document however the preview happens to be showing it, so the
/// zoom changes the view and never the picture.
class ZoomablePicturePreview extends StatefulWidget {
  final Widget child;

  /// Prefixes the widget keys on the zoom controls, so a test can reach the
  /// ones belonging to a particular dialog.
  final String keyPrefix;

  /// The color behind the picture. The plate is white or near-black
  /// depending on the capture, and it needs something to sit ON for its edges
  /// to be visible.
  final Color? backdrop;

  const ZoomablePicturePreview({
    super.key,
    required this.child,
    this.keyPrefix = 'picture',
    this.backdrop,
  });

  @override
  State<ZoomablePicturePreview> createState() => _ZoomablePicturePreviewState();
}

class _ZoomablePicturePreviewState extends State<ZoomablePicturePreview> {
  /// Held rather than left to the scroll views, so the bars have something to
  /// attach to - a document wider than the window with no bar down its edge
  /// is a document that LOOKS like it stops at the frame.
  final ScrollController _across = ScrollController();
  final ScrollController _down = ScrollController();

  /// The child's own size, learned from the first layout. Null until then.
  Size? _natural;

  /// null means "fit the whole thing in the window"; a number is that scale.
  ///
  /// Fitted to start with. Most of what comes through here is wider or taller
  /// than the dialog, and opening on the top-left corner of a document reads
  /// as a picture that got cut off rather than one that needs scrolling.
  double? _zoom;

  static const double _minZoom = 0.1;
  static const double _maxZoom = 6.0;

  static const double _barRoom = _kBarRoom;

  @override
  void dispose() {
    _across.dispose();
    _down.dispose();
    super.dispose();
  }

  /// The scale that puts the whole picture inside [box].
  ///
  /// Never above 1: a small picture is left at its own size rather than blown
  /// up into a poster of six cells.
  double _fitScale(BoxConstraints box) {
    final natural = _natural;
    if (natural == null || natural.width <= 0 || natural.height <= 0) return 1;
    final double wide = (box.maxWidth - _barRoom) / natural.width;
    final double tall = (box.maxHeight - _barRoom) / natural.height;
    final double fit = wide < tall ? wide : tall;
    return fit.clamp(_minZoom, 1.0);
  }

  void _step(double factor, BoxConstraints box) {
    final double from = _zoom ?? _fitScale(box);
    setState(() => _zoom = (from * factor).clamp(_minZoom, _maxZoom));
  }

  void _measured(Size size) {
    if (!mounted || size == _natural) return;
    setState(() => _natural = size);
  }

  Widget _plate(BoxConstraints box) {
    final natural = _natural;
    // First frame: nothing knows how big the child is yet, so it is laid out
    // unconstrained inside the scroll views and measured on the way past.
    if (natural == null || natural.width <= 0 || natural.height <= 0) {
      return _MeasureSize(onChange: _measured, child: widget.child);
    }
    final double scale = _zoom ?? _fitScale(box);
    return SizedBox(
      width: natural.width * scale,
      height: natural.height * scale,
      // FittedBox rather than Transform: a Transform is DRAWN scaled but is
      // still MEASURED at full size, so the scroll views would go on offering
      // to scroll a picture that already fits.
      child: FittedBox(
        fit: BoxFit.fill,
        child: _MeasureSize(onChange: _measured, child: widget.child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final double scale = _zoom ?? _fitScale(box);
        return Stack(
          children: [
            Positioned.fill(
              child: Container(
                color: widget.backdrop,
                child: Scrollbar(
                  controller: _down,
                  thumbVisibility: true,
                  // The vertical bar watches a scroll view one level DOWN
                  // inside the horizontal one, which the default predicate -
                  // depth zero only - would never hear from.
                  notificationPredicate: (n) => n.depth <= 1,
                  child: Scrollbar(
                    controller: _across,
                    thumbVisibility: true,
                    notificationPredicate: (n) => n.depth <= 1,
                    child: SingleChildScrollView(
                      controller: _across,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(
                        right: _barRoom,
                        bottom: _barRoom,
                      ),
                      child: SingleChildScrollView(
                        controller: _down,
                        child: _plate(box),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Over the picture rather than beside it: the dialogs this sits in
            // have their button row spoken for already, and a control that
            // moves the view belongs on the view.
            Positioned(
              top: 6,
              right: _barRoom + 6,
              child: _ZoomBar(
                keyPrefix: widget.keyPrefix,
                scale: scale,
                fitted: _zoom == null,
                onOut: () => _step(1 / 1.25, box),
                onIn: () => _step(1.25, box),
                onFit: () => setState(() => _zoom = null),
                onActual: () => setState(() => _zoom = 1.0),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Zoom out / the percentage / zoom in / fit / actual size.
class _ZoomBar extends StatelessWidget {
  final String keyPrefix;
  final double scale;
  final bool fitted;
  final VoidCallback onOut;
  final VoidCallback onIn;
  final VoidCallback onFit;
  final VoidCallback onActual;

  const _ZoomBar({
    required this.keyPrefix,
    required this.scale,
    required this.fitted,
    required this.onOut,
    required this.onIn,
    required this.onFit,
    required this.onActual,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget button(String suffix, IconData icon, String tip, VoidCallback tap) =>
        IconButton(
          key: ValueKey('${keyPrefix}_zoom_$suffix'),
          icon: Icon(icon, size: 18),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: tap,
        );

    return Material(
      elevation: 2,
      // Opaque: this floats over the document, and a translucent bar with
      // table rules showing through it is unreadable.
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button('out', Icons.zoom_out, 'Zoom out', onOut),
            SizedBox(
              width: 46,
              child: Text(
                '${(scale * 100).round()}%',
                key: ValueKey('${keyPrefix}_zoom_level'),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall,
              ),
            ),
            button('in', Icons.zoom_in, 'Zoom in', onIn),
            const SizedBox(width: 2),
            button(
              'fit',
              fitted ? Icons.fit_screen : Icons.fit_screen_outlined,
              'Fit the whole picture in the window',
              onFit,
            ),
            button('actual', Icons.crop_free, 'Actual size', onActual),
          ],
        ),
      ),
    );
  }
}

/// Reports its child's laid-out size, once, and again whenever it changes.
class _MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;

  const _MeasureSize({required this.onChange, required Widget child})
    : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasureSize renderObject,
  ) => renderObject.onChange = onChange;
}

class _RenderMeasureSize extends RenderProxyBox {
  ValueChanged<Size> onChange;
  Size? _last;

  _RenderMeasureSize(this.onChange);

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    // After the frame, not during it: telling a State to rebuild in the middle
    // of a layout is the "setState() called during build" crash.
    final reported = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(reported));
  }
}

// ============================================================================
// [FEATURE - THE CAPTURED PICTURE, BEFORE IT LANDS ANYWHERE]
// One dialog for "here is the picture that was just taken - keep it, copy it,
// or think better of it". Every Save-as-PNG button in the app comes through
// it, so the zoom, the bars and the Copy button cannot drift apart between
// one tab and the next.
// ============================================================================

/// Shows [png] full size, and offers to save it or copy it.
///
/// [what] names the picture in the messages ("The cabling drawing"), and
/// [fileName] is what the save dialog offers. Returns true when a file was
/// actually written, for a caller that wants to know.
Future<bool> showCapturedPicture(
  BuildContext context,
  Uint8List png, {
  required String title,
  required String fileName,
  required String what,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _CapturedPictureDialog(
      png: png,
      title: title,
      fileName: fileName,
      what: what,
    ),
  );
  return saved ?? false;
}

class _CapturedPictureDialog extends StatefulWidget {
  final Uint8List png;
  final String title;
  final String fileName;
  final String what;

  const _CapturedPictureDialog({
    required this.png,
    required this.title,
    required this.fileName,
    required this.what,
  });

  @override
  State<_CapturedPictureDialog> createState() => _CapturedPictureDialogState();
}

class _CapturedPictureDialogState extends State<_CapturedPictureDialog> {
  bool _busy = false;

  Future<void> _copy() async {
    setState(() => _busy = true);
    try {
      await copyPictureToClipboard(context, widget.png, what: widget.what);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The pen, the highlighter, the arrow and the callout, over this picture.
  ///
  /// Opened OVER the preview rather than instead of it, so closing the editor
  /// puts somebody back where they were rather than at nothing. The editor
  /// carries its own Save and Copy, because a marked-up picture is a different
  /// picture from the one underneath it and is usually the one that was
  /// wanted: "the fee card is the line I am asking about" is the whole reason
  /// the screenshot is being sent.
  Future<void> _annotate() async {
    setState(() => _busy = true);
    try {
      await showAnnotationEditor(
        context,
        widget.png,
        defaultFileName: widget.fileName,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    // Read before the first await: a provider looked up after one is a
    // BuildContext used across an async gap.
    final provider = context.read<AppStateProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      String? picked = await FilePicker.saveFile(
        dialogTitle: 'Save ${widget.what.toLowerCase()}',
        fileName: widget.fileName,
        type: FileType.custom,
        allowedExtensions: const ['png'],
      );
      if (picked == null) return;
      if (!picked.toLowerCase().endsWith('.png')) picked += '.png';
      await File(picked).writeAsBytes(widget.png);
      if (!mounted) return;
      showSavedFileSnack(context, provider, widget.what, picked);
      Navigator.of(context).pop(true);
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text('The picture could not be written: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return AlertDialog(
      key: const ValueKey('captured_picture_dialog'),
      title: Text(widget.title),
      content: SizedBox(
        width: media.size.width * 0.9,
        height: media.size.height * 0.72,
        child: ZoomablePicturePreview(
          keyPrefix: 'captured_picture',
          backdrop: Theme.of(context).brightness == Brightness.dark
              ? Colors.black45
              : Colors.grey[350],
          child: Image.memory(widget.png, filterQuality: FilterQuality.medium),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('captured_picture_annotate'),
          onPressed: _busy ? null : _annotate,
          icon: const Icon(Icons.draw_outlined, size: 18),
          label: const Text('Annotate'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('captured_picture_copy'),
          onPressed: _busy ? null : _copy,
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy to clipboard'),
        ),
        FilledButton.icon(
          key: const ValueKey('captured_picture_save'),
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Save as PNG'),
        ),
      ],
    );
  }
}
