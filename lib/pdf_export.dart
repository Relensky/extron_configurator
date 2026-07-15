import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Builds a single-page PDF that contains [pngBytes] as a full-bleed image,
/// with the page sized to the image's own aspect ratio. Pure (no Flutter UI),
/// so it runs under a plain `flutter test`. Returns the encoded PDF bytes.
Future<Uint8List> buildPdfFromImage(Uint8List pngBytes) async {
  final doc = pw.Document();
  final image = pw.MemoryImage(pngBytes);

  // Page follows the image aspect ratio at a comfortable base width so the
  // export isn't stretched. Falls back to A4-ish if dimensions are unavailable.
  final double w = image.width?.toDouble() ?? 800;
  final double h = image.height?.toDouble() ?? 1000;
  final pageFormat = PdfPageFormat(w, h);

  doc.addPage(
    pw.Page(
      pageFormat: pageFormat,
      build: (context) => pw.Image(image, fit: pw.BoxFit.contain),
    ),
  );

  return doc.save();
}
