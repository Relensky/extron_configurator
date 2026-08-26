import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app_state.dart';
import 'screenshot_tools.dart';

/// ============================================================================
///  THE IN-APP DOCUMENT VIEWER
/// ============================================================================
///  Full-screen viewer for a document this app REFERS to but does not own: a
///  module manual, a building's drawing set. PDFs are rendered with pdfrx
///  (bundled pdfium) and images with an [InteractiveViewer], behind the same
///  chrome either way - screenshot-and-annotate, an "open externally" way out
///  to whatever the machine uses, and Close.
///
///  ONE VIEWER FOR BOTH because the reason for wanting it is the same. Handing
///  a drawing to the machine's default reader puts a second window on top of
///  the app that has to be found again every time it is checked, and the thing
///  somebody is doing with it - reading a plate location off a plan while
///  filling in the field that names it - is a thing they are doing HERE.
/// ============================================================================

class PdfViewerDialog extends StatefulWidget {
  /// Absolute path to the file to display.
  final String filePath;

  /// What the document is called, in the viewer's own title bar.
  final String title;

  /// The stem a screenshot of this document is offered under, with no
  /// extension. Falls back to the file's own name.
  final String screenshotStem;

  /// The way out to the machine's own opener. Null hides the button, which is
  /// right for anything the app cannot hand back to a file on disk.
  final Future<String?> Function()? onOpenExternally;

  const PdfViewerDialog({
    super.key,
    required this.filePath,
    required this.title,
    this.screenshotStem = '',
    this.onOpenExternally,
  });

  /// Resolve the manual for [moduleName] and, if found, show it; otherwise
  /// surface the resolver's error in a snackbar. Keeps the button call sites
  /// tiny.
  static Future<void> open(BuildContext context, AppStateProvider provider,
      String moduleName) async {
    final located = provider.locateModuleManual(moduleName);
    if (located.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(located.error!)));
      return;
    }
    final short = moduleName.split('.').last;
    await showDialog<void>(
      context: context,
      builder: (_) => PdfViewerDialog(
        filePath: located.path!,
        title: '$short.pdf',
        screenshotStem: '${short}_manual',
        onOpenExternally: () => provider.openModuleDocumentation(moduleName),
      ),
    );
  }

  @override
  State<PdfViewerDialog> createState() => _PdfViewerDialogState();
}

class _PdfViewerDialogState extends State<PdfViewerDialog> {
  final PdfViewerController _controller = PdfViewerController();

  /// THE DRAWING SET'S OWN CONTENTS PAGE.
  ///
  /// A building's plan set is forty sheets - levels, ceilings, power, a riser
  /// diagram - and every one of them looks like the last from a scroll thumb.
  /// Whoever drew it already wrote the contents page: PDF bookmarks, which is
  /// what an architect's export carries and what "go to Level 2" means in
  /// every other reader. Read once when the document opens; a set with no
  /// bookmarks in it has none, and the panel lists its sheets instead of
  /// standing there empty.
  List<PdfOutlineNode> _chapters = const [];

  /// How many sheets, for the panel's fallback list.
  int _pages = 0;

  /// Which sheet is on screen, so the panel can mark it.
  int _page = 1;

  /// Whether the contents panel is open. Opened by default on a document that
  /// HAS chapters - a plan set is opened to find a sheet, and a contents page
  /// somebody has to go looking for is one nobody knows is there.
  bool _showChapters = false;

  Future<void> _readOutline(PdfDocument? document) async {
    if (document == null) {
      if (mounted) setState(() => _chapters = const []);
      return;
    }
    List<PdfOutlineNode> outline;
    try {
      outline = await document.loadOutline();
    } catch (_) {
      // A set whose bookmarks cannot be read is still a set to read.
      outline = const [];
    }
    if (!mounted) return;
    setState(() {
      _chapters = outline;
      _pages = document.pages.length;
      _showChapters = outline.isNotEmpty;
    });
  }

  /// Wraps the rendered document so the top-bar camera button can capture it.
  final GlobalKey _captureKey = GlobalKey();

  /// The pan/zoom of an IMAGE document, held here so the toolbar's buttons can
  /// drive it. A PDF's zoom lives in [_controller] instead.
  final TransformationController _imageView = TransformationController();

  /// How far one press of the zoom buttons moves an image. The PDF side has
  /// its own zoom stops (pdfrx doubles and halves), and this is the closest
  /// equivalent for the other half of the viewer, so the two buttons feel like
  /// one control whichever kind of document is open.
  static const double _imageZoomStep = 1.5;
  static const double _imageMinZoom = 0.2;
  static const double _imageMaxZoom = 12;

  @override
  void dispose() {
    _imageView.dispose();
    super.dispose();
  }

  /// Zooms the document on screen, whichever kind it is.
  ///
  /// A DIALOG IS NOT A DESK. The reason to open a plan here rather than in the
  /// machine's own reader is to read it beside the field being filled in, and
  /// that means going in close on one corner of a forty-sheet set. A wheel
  /// does it on a mouse and a pinch does it on a trackpad, but neither is
  /// discoverable and neither is available to somebody driving the app from a
  /// laptop keyboard — so the two presses that every other reader has are on
  /// the toolbar as buttons.
  ///
  /// Zoom about the CENTRE of the view, which is the part being read: zooming
  /// about the top-left corner walks whatever is on screen off the edge of it,
  /// and the next press then has to be undone by dragging.
  void _zoom({required bool inwards}) {
    if (_isPdf) {
      // Before the document is laid out there is nothing to zoom, and asking
      // anyway throws rather than doing nothing.
      if (!_controller.isReady) return;
      if (inwards) {
        _controller.zoomUp();
      } else {
        _controller.zoomDown();
      }
      return;
    }
    final current = _imageView.value.getMaxScaleOnAxis();
    final wanted = inwards
        ? current * _imageZoomStep
        : current / _imageZoomStep;
    final next = wanted.clamp(_imageMinZoom, _imageMaxZoom);
    if (next == current) return;

    // Keep the middle of the viewport over the same point of the image: scale
    // about the centre rather than about the matrix origin.
    final box = _captureKey.currentContext?.findRenderObject();
    final size = box is RenderBox ? box.size : Size.zero;
    final centre = Offset(size.width / 2, size.height / 2);
    final factor = next / current;
    setState(() {
      _imageView.value = Matrix4.identity()
        ..translateByDouble(centre.dx, centre.dy, 0, 1)
        ..scaleByDouble(factor, factor, 1, 1)
        ..translateByDouble(-centre.dx, -centre.dy, 0, 1)
        ..multiply(_imageView.value);
    });
  }

  /// Whether this is a PDF, decided on the file name rather than on a sniff of
  /// the bytes: the extension is what every other part of this app routes on,
  /// and a mislabelled file fails with a readable error either way.
  bool get _isPdf => widget.filePath.toLowerCase().endsWith('.pdf');

  void _screenshot() {
    final stem = widget.screenshotStem.trim().isNotEmpty
        ? widget.screenshotStem.trim()
        : widget.filePath.split(Platform.pathSeparator).last.split('.').first;
    final dateToken =
        DateTime.now().toLocal().toIso8601String().split('T').first;
    captureAndAnnotate(context, _captureKey,
        defaultFileName: '${stem}_$dateToken.png');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Title bar
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Icon(_isPdf ? Icons.picture_as_pdf : Icons.image_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(widget.title,
                      key: const ValueKey('document_viewer_title'),
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  key: const ValueKey('document_viewer_zoom_out'),
                  icon: const Icon(Icons.zoom_out),
                  tooltip: 'Zoom out',
                  onPressed: () => _zoom(inwards: false),
                ),
                IconButton(
                  key: const ValueKey('document_viewer_zoom_in'),
                  icon: const Icon(Icons.zoom_in),
                  tooltip: 'Zoom in',
                  onPressed: () => _zoom(inwards: true),
                ),
                // THE WAY INTO A FORTY-SHEET SET.
                if (_isPdf)
                  IconButton(
                    key: const ValueKey('document_viewer_chapters'),
                    icon: const Icon(Icons.toc),
                    isSelected: _showChapters,
                    tooltip: _chapters.isEmpty
                        ? 'Sheets - this document carries no chapters'
                        : 'Chapters',
                    onPressed: () =>
                        setState(() => _showChapters = !_showChapters),
                  ),
                IconButton(
                  icon: const Icon(Icons.photo_camera),
                  tooltip: 'Screenshot & annotate this page',
                  onPressed: _screenshot,
                ),
                if (widget.onOpenExternally != null)
                  IconButton(
                    key: const ValueKey('document_viewer_external'),
                    icon: const Icon(Icons.open_in_new),
                    tooltip: 'Open in the viewer this machine uses',
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final error = await widget.onOpenExternally!();
                      if (error != null) {
                        messenger.showSnackBar(SnackBar(content: Text(error)));
                      }
                    },
                  ),
                IconButton(
                  key: const ValueKey('document_viewer_close'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // The document itself, filling the rest of the dialog and captured
          // for the screenshot action. The contents panel is OUTSIDE the
          // capture boundary: a screenshot of a drawing is the drawing, not
          // the drawing with a table of contents down the side of it.
          Expanded(
            child: Row(
              children: [
                if (_isPdf && _showChapters) ...[
                  SizedBox(
                    width: 260,
                    child: PdfChapterList(
                      chapters: _chapters,
                      pages: _pages,
                      page: _page,
                      onGoToDest: (dest) => _controller.goToDest(dest),
                      onGoToPage: (n) => _controller.goToPage(pageNumber: n),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: RepaintBoundary(
                    key: _captureKey,
                    child: _isPdf ? _pdf(context) : _image(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pdf(BuildContext context) => PdfViewer.file(
        widget.filePath,
        controller: _controller,
        params: PdfViewerParams(
          margin: 8,
          onDocumentChanged: _readOutline,
          onPageChanged: (n) {
            if (n != null && mounted) setState(() => _page = n);
          },
          // A visible, draggable scroll thumb down the right edge.
          viewerOverlayBuilder: (context, size, handleLinkTap) => [
            PdfViewerScrollThumb(
              controller: _controller,
              orientation: ScrollbarOrientation.right,
              thumbSize: const Size(12, 48),
              thumbBuilder: (context, thumbSize, pageNumber, controller) =>
                  Container(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ],
        ),
      );

  /// A scanned or exported sheet. Pan and zoom rather than fit-to-window: a
  /// plan is read by going in close on one corner of it, and a drawing scaled
  /// to a dialog is a grey rectangle.
  Widget _image(BuildContext context) => InteractiveViewer(
        transformationController: _imageView,
        minScale: _imageMinZoom,
        maxScale: _imageMaxZoom,
        child: Center(
          child: Image.file(
            File(widget.filePath),
            errorBuilder: (context, error, stack) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'That file could not be drawn: $error',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ),
      );
}

/// A plan set's contents page: its chapters, or its sheets when it has none.
///
/// Public so it can be tested without pdfium: the nesting, the selection and
/// the fallback to a sheet list are the whole of it, and none of them need a
/// real document to be wrong.
///
/// NESTED, because a drawing set's bookmarks are: "Architectural" over
/// "Level 1" over "Reflected ceiling". Flattening it would turn the one piece
/// of structure the person who drew the set left behind into a list of forty
/// similar names.
class PdfChapterList extends StatelessWidget {
  final List<PdfOutlineNode> chapters;
  final int pages;
  final int page;
  final ValueChanged<PdfDest?> onGoToDest;
  final ValueChanged<int> onGoToPage;

  const PdfChapterList({
    super.key,
    required this.chapters,
    required this.pages,
    required this.page,
    required this.onGoToDest,
    required this.onGoToPage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text(
              chapters.isEmpty ? 'SHEETS' : 'CHAPTERS',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (chapters.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                'This set carries no bookmarks, so there is no contents page '
                'to read off it. Its sheets are listed instead.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: chapters.isEmpty
                  ? [
                      for (var n = 1; n <= pages; n++)
                        _row(
                          context,
                          title: 'Sheet $n',
                          depth: 0,
                          selected: n == page,
                          onTap: () => onGoToPage(n),
                        ),
                    ]
                  : [
                      for (final node in chapters) ..._nodes(context, node, 0),
                    ],
            ),
          ),
        ],
      ),
    );
  }

  /// One bookmark and everything under it, indented by how deep it sits.
  List<Widget> _nodes(BuildContext context, PdfOutlineNode node, int depth) => [
    _row(
      context,
      title: node.title.trim().isEmpty ? 'Untitled' : node.title.trim(),
      depth: depth,
      selected: node.dest?.pageNumber == page,
      onTap: node.dest == null ? null : () => onGoToDest(node.dest),
    ),
    for (final child in node.children) ..._nodes(context, child, depth + 1),
  ];

  Widget _row(
    BuildContext context, {
    required String title,
    required int depth,
    required bool selected,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : null,
        padding: EdgeInsets.fromLTRB(12.0 + depth * 14, 6, 12, 6),
        child: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: selected ? FontWeight.bold : null,
            color: onTap == null
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
