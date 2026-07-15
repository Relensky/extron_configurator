import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:extron_configurator/pdf_export.dart';

void main() {
  test('buildPdfFromImage wraps a PNG into a valid PDF', () async {
    // Encode a small solid PNG with the same library the pdf package decodes
    // with, so the round-trip is deterministic.
    final image = img.Image(width: 8, height: 8);
    img.fill(image, color: img.ColorRgb8(200, 30, 30));
    final png = Uint8List.fromList(img.encodePng(image));

    final pdf = await buildPdfFromImage(png);

    expect(pdf, isNotEmpty);
    // Every PDF file starts with the "%PDF-" signature.
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
  });
}
