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

  /// Wraps the rendered document so the top-bar camera button can capture it.
  final GlobalKey _captureKey = GlobalKey();

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
          // for the screenshot action.
          Expanded(
            child: RepaintBoundary(
              key: _captureKey,
              child: _isPdf ? _pdf(context) : _image(context),
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
        maxScale: 12,
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
