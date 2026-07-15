import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screenshot_tools.dart';

/// Full-screen in-app viewer for a module manual PDF. Rendered with pdfrx
/// (bundled pdfium), with a draggable scroll thumb down the right edge. The top
/// bar offers a screenshot-and-annotate action, an "Open externally" fallback
/// (via [AppStateProvider.openModuleDocumentation]) and Close.
class PdfViewerDialog extends StatefulWidget {
  /// Absolute path to the .pdf file to display.
  final String filePath;

  /// The module name (e.g. 'device.avr_TR311') — shown in the title and used
  /// for the external-open fallback.
  final String moduleName;

  const PdfViewerDialog({
    Key? key,
    required this.filePath,
    required this.moduleName,
  }) : super(key: key);

  /// Convenience: resolve the manual for [moduleName] and, if found, show the
  /// dialog; otherwise surface the resolver's error in a snackbar. Keeps the
  /// button call sites tiny.
  static Future<void> open(
      BuildContext context, AppStateProvider provider, String moduleName) async {
    final located = provider.locateModuleManual(moduleName);
    if (located.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(located.error!)));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => PdfViewerDialog(
        filePath: located.path!,
        moduleName: moduleName,
      ),
    );
  }

  @override
  State<PdfViewerDialog> createState() => _PdfViewerDialogState();
}

class _PdfViewerDialogState extends State<PdfViewerDialog> {
  final PdfViewerController _controller = PdfViewerController();

  /// Wraps the rendered PDF so the top-bar camera button can capture it.
  final GlobalKey _captureKey = GlobalKey();

  void _screenshot() {
    final base = widget.moduleName.split('.').last;
    final dateToken = DateTime.now().toLocal().toIso8601String().split('T').first;
    captureAndAnnotate(context, _captureKey,
        defaultFileName: '${base}_manual_$dateToken.png');
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.moduleName.split('.').last}.pdf';
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
                const Icon(Icons.picture_as_pdf),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.photo_camera),
                  tooltip: 'Screenshot & annotate this page',
                  onPressed: _screenshot,
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new),
                  tooltip: 'Open in external PDF viewer',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final error = await context
                        .read<AppStateProvider>()
                        .openModuleDocumentation(widget.moduleName);
                    if (error != null) {
                      messenger.showSnackBar(SnackBar(content: Text(error)));
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // The PDF itself, filling the rest of the dialog, captured for the
          // screenshot action and overlaid with a draggable scroll thumb.
          Expanded(
            child: RepaintBoundary(
              key: _captureKey,
              child: PdfViewer.file(
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
                      thumbBuilder:
                          (context, thumbSize, pageNumber, controller) =>
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}
