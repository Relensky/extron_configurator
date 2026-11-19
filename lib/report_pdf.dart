import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'estimate_pdf.dart';
import 'report_tools.dart';
import 'xlsx_writer.dart';

/// Report sections as a PDF: a title, then each section as a table. A
/// section whose header is all blank prints as label/value pairs.
///
/// [theme] null uses the built-in Helvetica (Latin-1 only). [compress] is off
/// in tests so the text can be read back.
Future<Uint8List> buildReportSectionsPdf({
  required String title,
  required List<ReportSection> sections,
  DateTime? generated,
  pw.ThemeData? theme,
  bool landscape = true,
  bool compress = true,
}) async {
  final String Function(String) t = theme != null
      ? (s) => s
      : (s) => String.fromCharCodes(
          s
              .replaceAll(RegExp('[–—]'), '-')
              .replaceAll(RegExp('[‘’]'), "'")
              .replaceAll(RegExp('[“”]'), '"')
              .replaceAll('×', 'x')
              .replaceAll('…', '...')
              .runes
              .map((r) => r < 256 ? r : 0x3F),
        );

  const ink = PdfColor.fromInt(0xFF1F2933);
  const muted = PdfColor.fromInt(0xFF616E7C);
  const rule = PdfColor.fromInt(0xFFCBD2D9);
  const band = PdfColor.fromInt(0xFFF0F3F7);
  const accent = defaultEstimateAccent;
  const body = pw.TextStyle(fontSize: 9, color: ink);
  final bold = body.copyWith(fontWeight: pw.FontWeight.bold);

  String cell(dynamic v) {
    if (v == null) return '';
    if (v is double) {
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }
    return v.toString();
  }

  bool numeric(dynamic v) =>
      v is num || v is XlsxMoney || v is XlsxFormula || v is XlsxNumberFormula;

  pw.Widget heading(String text) => pw.Container(
    margin: const pw.EdgeInsets.only(top: 14, bottom: 6),
    padding: const pw.EdgeInsets.only(bottom: 3),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: accent, width: 1.2)),
    ),
    child: pw.Text(
      t(text.toUpperCase()),
      style: pw.TextStyle(
        fontSize: 10.5,
        color: accent,
        fontWeight: pw.FontWeight.bold,
        letterSpacing: 0.6,
      ),
    ),
  );

  pw.Widget pairs(ReportSection s) => pw.Table(
    columnWidths: const {
      0: pw.IntrinsicColumnWidth(),
      1: pw.FlexColumnWidth(),
    },
    children: [
      for (final r in s.rows)
        pw.TableRow(
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.only(right: 14, bottom: 3),
              child: pw.Text(t(cell(r.isNotEmpty ? r[0] : '')), style: bold),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Text(
                t(r.length > 1 ? r.skip(1).map(cell).join(' ') : ''),
                style: body,
              ),
            ),
          ],
        ),
    ],
  );

  pw.Widget table(ReportSection s) {
    final cols = s.header.length;
    final right = <int>{
      for (var c = 0; c < cols; c++)
        if (s.rows.any((r) => c < r.length && numeric(r[c]))) c,
    };
    pw.Widget box(String text, pw.TextStyle style, int c) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        t(text),
        style: style,
        textAlign: right.contains(c) ? pw.TextAlign.right : pw.TextAlign.left,
      ),
    );
    return pw.Table(
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: rule, width: 0.5),
        bottom: pw.BorderSide(color: rule, width: 0.5),
      ),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: band),
          repeat: true,
          children: [
            for (var c = 0; c < cols; c++) box(s.header[c], bold, c),
          ],
        ),
        for (final r in s.rows)
          pw.TableRow(
            children: [
              for (var c = 0; c < cols; c++)
                box(c < r.length ? cell(r[c]) : '', body, c),
            ],
          ),
      ],
    );
  }

  final doc = pw.Document(
    compress: compress,
    title: t(title),
    creator: 'Room Config Builder',
  );
  doc.addPage(
    pw.MultiPage(
      theme: theme,
      pageFormat: landscape ? PdfPageFormat.letter.landscape : PdfPageFormat.letter,
      margin: const pw.EdgeInsets.all(36),
      footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: muted),
        ),
      ),
      build: (_) => [
        pw.Text(
          t(title),
          style: pw.TextStyle(
            fontSize: 18,
            color: ink,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        if (generated != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.Text(
              t(estimateDateLabel(generated)),
              style: const pw.TextStyle(fontSize: 9, color: muted),
            ),
          ),
        for (final s in sections) ...[
          heading(s.title),
          s.header.every((h) => h.trim().isEmpty) ? pairs(s) : table(s),
        ],
      ],
    ),
  );
  return doc.save();
}
