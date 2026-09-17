import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'cost_estimate.dart';

/// ============================================================================
///  THE ESTIMATE AS A PDF
/// ============================================================================
///  The client-facing copy of the Cost tab: logo top right, who prepared it,
///  the scope of work, the priced lines, the totals and the notes. Only what
///  the reader of a quote needs - no pricing sources or app wording.
/// ============================================================================

/// Everything on the PDF that is not in the [CostEstimate].
class EstimatePdfInfo {
  /// The room, e.g. 'Bessey Hall 103'.
  final String roomName;

  /// The job the room belongs to, or ''.
  final String projectName;

  final String preparedBy;
  final String preparerContact;
  final DateTime date;

  /// PNG or JPEG bytes, or null for no logo.
  final Uint8List? logo;

  final String scopeOfWork;
  final String notes;

  const EstimatePdfInfo({
    this.roomName = '',
    this.projectName = '',
    this.preparedBy = '',
    this.preparerContact = '',
    required this.date,
    this.logo,
    this.scopeOfWork = '',
    this.notes = '',
  });
}

const _ink = PdfColor.fromInt(0xFF1F2933);
const _muted = PdfColor.fromInt(0xFF616E7C);
const _accent = PdfColor.fromInt(0xFF1F3A5F);
const _rule = PdfColor.fromInt(0xFFCBD2D9);
const _band = PdfColor.fromInt(0xFFF0F3F7);

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

String estimateDateLabel(DateTime d) =>
    '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// Segoe UI (or Arial) off the Windows font folder, so dashes, bullets and
/// accented names print. Null when neither is there; the PDF then falls back
/// to Helvetica and the text is reduced to Latin-1.
pw.ThemeData? loadEstimatePdfTheme({String? fontsFolder}) {
  final folder = fontsFolder ??
      path.join(Platform.environment['WINDIR'] ?? r'C:\Windows', 'Fonts');
  for (final pair in const [
    ('segoeui.ttf', 'segoeuib.ttf'),
    ('arial.ttf', 'arialbd.ttf'),
  ]) {
    final regular = File(path.join(folder, pair.$1));
    final bold = File(path.join(folder, pair.$2));
    try {
      if (!regular.existsSync() || !bold.existsSync()) continue;
      final base = pw.Font.ttf(ByteData.sublistView(regular.readAsBytesSync()));
      final heavy = pw.Font.ttf(ByteData.sublistView(bold.readAsBytesSync()));
      return pw.ThemeData.withFont(
        base: base,
        bold: heavy,
        italic: base,
        boldItalic: heavy,
      );
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// Reads the logo file, or null when there is none or it cannot be read.
Uint8List? readEstimateLogo(String filePath) {
  if (filePath.trim().isEmpty) return null;
  try {
    final file = File(filePath);
    return file.existsSync() ? file.readAsBytesSync() : null;
  } catch (_) {
    return null;
  }
}

/// Builds the estimate PDF.
///
/// [theme] null uses the built-in Helvetica. [compress] is off in tests so the
/// text can be found in the bytes.
Future<Uint8List> buildEstimatePdf(
  CostEstimate estimate,
  EstimatePdfInfo info, {
  pw.ThemeData? theme,
  bool compress = true,
}) async {
  // Helvetica only has Latin-1.
  final String Function(String) t = theme != null
      ? (s) => s
      : (s) => String.fromCharCodes(
          s
              .replaceAll(RegExp('[\u2013\u2014]'), '-')
              .replaceAll(RegExp('[\u2018\u2019]'), "'")
              .replaceAll(RegExp('[\u201C\u201D]'), '"')
              .replaceAll('\u2026', '...')
              .runes
              .map((r) => r < 256 ? r : 0x3F),
        );

  final currency = estimate.currency;
  String cash(double v) => t(formatMoney(v, currency));

  pw.ImageProvider? logo;
  if (info.logo != null) {
    try {
      logo = pw.MemoryImage(info.logo!);
    } catch (_) {
      logo = null; // not an image the PDF can embed
    }
  }

  final doc = pw.Document(
    compress: compress,
    title: t('Estimate - ${info.roomName}'.trim()),
    author: t(info.preparedBy),
    creator: 'Room Config Builder',
  );

  const small = pw.TextStyle(fontSize: 8.5, color: _muted);
  const body = pw.TextStyle(fontSize: 9.5, color: _ink);
  final bold = pw.TextStyle(
    fontSize: 9.5,
    color: _ink,
    fontWeight: pw.FontWeight.bold,
  );

  pw.Widget sectionTitle(String text) => pw.Container(
    margin: const pw.EdgeInsets.only(top: 16, bottom: 6),
    padding: const pw.EdgeInsets.only(bottom: 3),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _accent, width: 1.2)),
    ),
    child: pw.Text(
      t(text.toUpperCase()),
      style: pw.TextStyle(
        fontSize: 10.5,
        color: _accent,
        fontWeight: pw.FontWeight.bold,
        letterSpacing: 0.6,
      ),
    ),
  );

  List<pw.Widget> paragraphs(String text) => [
    for (final line in text.trim().split('\n'))
      line.trim().isEmpty
          ? pw.SizedBox(height: 5)
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Text(t(line), style: body.copyWith(lineSpacing: 2)),
            ),
  ];

  pw.Widget cell(
    String text, {
    bool right = false,
    pw.TextStyle? style,
    String sub = '',
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    child: pw.Column(
      crossAxisAlignment: right
          ? pw.CrossAxisAlignment.end
          : pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          t(text),
          style: style ?? body,
          textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
        ),
        if (sub.trim().isNotEmpty) pw.Text(t(sub), style: small),
      ],
    ),
  );

  /// One priced table. [numeric] marks right-aligned columns.
  pw.Widget table({
    required List<String> header,
    required List<double> flex,
    required Set<int> numeric,
    required List<List<pw.Widget>> rows,
  }) {
    return pw.Table(
      columnWidths: {
        for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i]),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
        bottom: pw.BorderSide(color: _rule, width: 0.5),
      ),
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _band),
          children: [
            for (var i = 0; i < header.length; i++)
              cell(
                header[i],
                right: numeric.contains(i),
                style: pw.TextStyle(
                  fontSize: 8.5,
                  color: _muted,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
          ],
        ),
        for (final row in rows) pw.TableRow(children: row),
      ],
    );
  }

  String qtyLabel(CostLine line) => trimNumber(line.qty);

  String priceLabel(CostLine line) =>
      line.unitPrice <= 0 && !line.furnished ? 'TBD' : cash(line.unitPrice);

  String amountLabel(CostLine line) {
    if (line.furnished) return t('By others');
    if (line.unitPrice <= 0) return 'TBD';
    return cash(line.total);
  }

  String lineNote(CostLine line) {
    final note = [
      if (line.spareQty > 0) 'Includes ${trimNumber(line.spareQty)} spare',
      if (line.furnished) furnishedNote(line),
    ].join(' - ');
    return note.isEmpty ? '' : note[0].toUpperCase() + note.substring(1);
  }

  List<List<pw.Widget>> partRows(List<CostLine> lines, {bool model = true}) => [
    for (final line in lines)
      [
        cell(line.description, sub: lineNote(line)),
        cell(
          model && line.model.isNotEmpty ? line.model : line.partNumber,
          sub: model && line.model.isNotEmpty && line.partNumber != line.model
              ? line.partNumber
              : '',
        ),
        cell(qtyLabel(line), right: true),
        cell(priceLabel(line), right: true),
        cell(amountLabel(line), right: true),
      ],
  ];

  const partFlex = [4.2, 2.6, 0.8, 1.5, 1.6];
  const partNumeric = {2, 3, 4};

  pw.Widget totalsBox() {
    pw.Widget row(String label, double value, {bool strong = false}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
          child: pw.Row(
            children: [
              pw.Expanded(
                child: pw.Text(t(label), style: strong ? bold : body),
              ),
              pw.Text(cash(value), style: strong ? bold : body),
            ],
          ),
        );
    final divider = pw.Divider(color: _rule, thickness: 0.5, height: 8);
    return pw.Container(
      width: 250,
      decoration: const pw.BoxDecoration(
        border: pw.Border.fromBorderSide(
          pw.BorderSide(color: _rule, width: 0.5),
        ),
      ),
      child: pw.Column(
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: pw.Column(
              children: [
                if (estimate.equipment.isNotEmpty)
                  row('Equipment', estimate.equipmentTotal),
                if (estimate.hardware.isNotEmpty)
                  row('Rack hardware', estimate.hardwareTotal),
                if (estimate.cabling.isNotEmpty)
                  row('Cabling', estimate.cablingTotal),
                if (estimate.labor.isNotEmpty) row('Labor', estimate.laborTotal),
                if (estimate.extras.isNotEmpty)
                  row('Other items', estimate.extrasTotal),
                divider,
                row('Subtotal', estimate.subtotal, strong: true),
                for (final f in estimate.fees)
                  row(
                    '${f.fee.name.trim().isEmpty ? 'Fee' : f.fee.name} '
                    '(${formatPercent(f.fee.percent)})',
                    f.amount,
                  ),
                if (estimate.taxPercent > 0)
                  row(
                    '${estimate.taxLabel} '
                    '(${formatPercent(estimate.taxPercent)})',
                    estimate.tax,
                  ),
              ],
            ),
          ),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            color: _accent,
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: pw.Text(
                    'TOTAL',
                    style: pw.TextStyle(
                      fontSize: 11,
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.Text(
                  cash(estimate.grandTotal),
                  style: pw.TextStyle(
                    fontSize: 12,
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget detail(String label, List<String> lines) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        t(label.toUpperCase()),
        style: pw.TextStyle(
          fontSize: 7.5,
          color: _muted,
          fontWeight: pw.FontWeight.bold,
          letterSpacing: 0.6,
        ),
      ),
      pw.SizedBox(height: 2),
      for (final (i, line) in lines.where((l) => l.trim().isNotEmpty).indexed)
        pw.Text(t(line), style: i == 0 ? bold : small),
    ],
  );

  pw.Widget firstPageHeader() => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'ESTIMATE',
                  style: pw.TextStyle(
                    fontSize: 24,
                    color: _accent,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                if (info.roomName.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text(
                    t(info.roomName),
                    style: pw.TextStyle(fontSize: 13, color: _ink),
                  ),
                ],
              ],
            ),
          ),
          if (logo != null)
            pw.ConstrainedBox(
              constraints: const pw.BoxConstraints(
                maxWidth: 170,
                maxHeight: 64,
              ),
              child: pw.Image(logo, fit: pw.BoxFit.contain),
            ),
        ],
      ),
      pw.SizedBox(height: 12),
      pw.Container(height: 2, color: _accent),
      pw.SizedBox(height: 10),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (info.projectName.trim().isNotEmpty)
            pw.Expanded(
              flex: 3,
              child: detail('Project', [info.projectName]),
            ),
          pw.Expanded(
            flex: 2,
            child: detail('Date', [estimateDateLabel(info.date)]),
          ),
          if ('${info.preparedBy}${info.preparerContact}'.trim().isNotEmpty)
            pw.Expanded(
              flex: 3,
              child: detail('Prepared by', [
                info.preparedBy,
                info.preparerContact,
              ]),
            )
          else
            pw.Spacer(flex: 3),
        ],
      ),
    ],
  );

  final content = <pw.Widget>[
    if (info.scopeOfWork.trim().isNotEmpty) ...[
      sectionTitle('Scope of Work'),
      ...paragraphs(info.scopeOfWork),
    ],
    if (estimate.equipment.isNotEmpty) ...[
      sectionTitle('Equipment'),
      table(
        header: const ['Description', 'Model / Part', 'Qty', 'Unit', 'Amount'],
        flex: partFlex,
        numeric: partNumeric,
        rows: partRows(estimate.equipment),
      ),
    ],
    if (estimate.hardware.isNotEmpty) ...[
      sectionTitle('Rack Hardware'),
      table(
        header: const ['Description', 'Model / Part', 'Qty', 'Unit', 'Amount'],
        flex: partFlex,
        numeric: partNumeric,
        rows: partRows(estimate.hardware),
      ),
    ],
    if (estimate.cabling.isNotEmpty) ...[
      sectionTitle('Cabling'),
      table(
        header: const ['Description', 'Part', 'Qty', 'Unit', 'Amount'],
        flex: partFlex,
        numeric: partNumeric,
        rows: partRows(estimate.cabling, model: false),
      ),
    ],
    if (estimate.labor.isNotEmpty) ...[
      sectionTitle('Labor'),
      table(
        header: const ['Description', 'Crew', 'Hours', 'Rate', 'Amount'],
        flex: partFlex,
        numeric: partNumeric,
        rows: [
          for (final line in estimate.labor)
            [
              cell(line.roleName, sub: line.description),
              cell(
                '${trimNumber(line.techs)} x ${trimNumber(line.hours)} h',
              ),
              cell(trimNumber(line.totalHours), right: true),
              cell(
                line.unrated ? 'TBD' : cash(line.hourlyRate),
                right: true,
              ),
              cell(line.unrated ? 'TBD' : cash(line.total), right: true),
            ],
        ],
      ),
    ],
    if (estimate.extras.isNotEmpty) ...[
      sectionTitle('Other Items'),
      table(
        header: const ['Description', 'Part', 'Qty', 'Unit', 'Amount'],
        flex: partFlex,
        numeric: partNumeric,
        rows: partRows(estimate.extras, model: false),
      ),
    ],
    pw.SizedBox(height: 16),
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: [totalsBox()],
    ),
    if (info.notes.trim().isNotEmpty) ...[
      sectionTitle('Notes'),
      ...paragraphs(info.notes),
    ],
  ];

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.fromLTRB(44, 40, 44, 36),
      theme: theme,
      maxPages: 60,
      header: (context) => context.pageNumber == 1
          ? firstPageHeader()
          : pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 8),
              padding: const pw.EdgeInsets.only(bottom: 4),
              decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(color: _rule)),
              ),
              child: pw.Row(
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      t('Estimate - ${info.roomName}'.trim()),
                      style: small,
                    ),
                  ),
                  pw.Text(estimateDateLabel(info.date), style: small),
                ],
              ),
            ),
      footer: (context) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 10),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(
                t(
                  info.preparedBy.trim().isEmpty
                      ? ''
                      : 'Prepared by ${info.preparedBy.trim()}',
                ),
                style: small,
              ),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: small,
            ),
          ],
        ),
      ),
      build: (context) => content,
    ),
  );

  return doc.save();
}
