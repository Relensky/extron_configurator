import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

/// A PDF built in memory, shown full screen before it is saved. [onSave],
/// when given, puts a Save button in the bar; the preview closes first.
Future<void> showPdfBytesPreview(
  BuildContext context, {
  required Uint8List bytes,
  required String title,
  String saveLabel = 'Save PDF...',
  Future<void> Function()? onSave,
  Key? key,
}) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (ctx) => Dialog.fullscreen(
    key: key,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(ctx).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onSave != null) ...[
                FilledButton.icon(
                  key: const ValueKey('pdf_preview_save'),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: Text(saveLabel),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    onSave();
                  },
                ),
                const SizedBox(width: 8),
              ],
              IconButton(
                key: const ValueKey('pdf_preview_close'),
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: PdfViewer.data(
            bytes,
            // Unique, so an edited document is not served from cache.
            sourceName: 'preview_${DateTime.now().microsecondsSinceEpoch}.pdf',
            params: const PdfViewerParams(margin: 8),
          ),
        ),
      ],
    ),
  ),
);
