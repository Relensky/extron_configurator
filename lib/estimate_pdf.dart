import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'cost_estimate.dart';

/// ============================================================================
///  THE ESTIMATE AS A PDF
/// ============================================================================
///  The client-facing copy of the Cost tab: logo in a top corner, who prepared it,
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

  /// Logo in the top left corner, title on the right. Default is the reverse.
  final bool logoOnLeft;

  /// Headings, rules and the total band. Null prints [defaultEstimateAccent].
  final PdfColor? accent;

  final String scopeOfWork;
  final String notes;

  /// The heading, e.g. 'CTS Estimate'. Blank prints [kDefaultEstimateTitle].
  final String title;

  /// Extra titled blocks, printed where each one says.
  final List<EstimateSection> sections;

  /// The line under the title. Blank prints [roomName].
  final String subtitle;

  /// Key of [kEstimatePdfWords] -> the word printed instead of the default.
  final Map<String, String> words;

  /// The word for [key]: what was typed, or the default.
  String word(String key) {
    final typed = words[key]?.trim() ?? '';
    return typed.isNotEmpty ? typed : (kEstimatePdfWords[key] ?? key);
  }

  const EstimatePdfInfo({
    this.title = kDefaultEstimateTitle,
    this.sections = const [],
    this.subtitle = '',
    this.words = const {},
    this.roomName = '',
    this.projectName = '',
    this.preparedBy = '',
    this.preparerContact = '',
    required this.date,
    this.logo,
    this.logoOnLeft = false,
    this.accent,
    this.scopeOfWork = '',
    this.notes = '',
  });
}

const _ink = PdfColor.fromInt(0xFF1F2933);
const _muted = PdfColor.fromInt(0xFF616E7C);
const defaultEstimateAccent = PdfColor.fromInt(0xFF1F3A5F);
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

/// The stored RRGGBB accent as a PDF color, or null for the default.
PdfColor? estimateAccentColor(String hex) {
  final v = hex.trim().length == 6 ? int.tryParse(hex.trim(), radix: 16) : null;
  return v == null ? null : PdfColor.fromInt(0xFF000000 | v);
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

  final accent = info.accent ?? defaultEstimateAccent;
  final subtitle = info.subtitle.trim().isNotEmpty
      ? info.subtitle.trim()
      : info.roomName.trim();
  final title = info.title.trim().isEmpty
      ? kDefaultEstimateTitle
      : info.title.trim();
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
    title: t('$title - ${info.roomName}'.trim()),
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
    decoration: pw.BoxDecoration(
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

  List<pw.Widget> paragraphs(String text) => [
    for (final line in text.trim().split('\n'))
      line.trim().isEmpty
          ? pw.SizedBox(height: 5)
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Text(t(line), style: body.copyWith(lineSpacing: 2)),
            ),
  ];

  List<pw.Widget> bullets(String text) => [
    for (final line in text.trim().split('\n'))
      if (line.trim().isNotEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 2, left: 4),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Helvetica has no bullet; the middle dot is Latin-1.
              pw.SizedBox(
                width: 10,
                child: pw.Text(theme != null ? '\u2022' : '\u00b7', style: body),
              ),
              pw.Expanded(
                child: pw.Text(
                  t(line.trim()),
                  style: body.copyWith(lineSpacing: 2),
                ),
              ),
            ],
          ),
        ),
  ];

  List<pw.Widget> customSections(EstimateSectionPlace place) => [
    for (final section in info.sections)
      if (section.place == place && !section.isEmpty) ...[
        sectionTitle(
          section.title.trim().isEmpty ? info.word('notes') : section.title,
        ),
        ...(section.bulleted
            ? bullets(section.body)
            : paragraphs(section.body)),
      ],
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

  // A shipping column only on a quote that charges some.
  final shipping = estimate.shippingTotal > 0;

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
        if (shipping)
          cell(
            line.shippingTotal > 0 ? cash(line.shippingTotal) : '',
            right: true,
          ),
        cell(amountLabel(line), right: true),
      ],
  ];

  final partFlex = shipping
      ? const [3.8, 2.4, 0.7, 1.4, 1.3, 1.5]
      : const [4.2, 2.6, 0.8, 1.5, 1.6];
  final partNumeric = shipping ? const {2, 3, 4, 5} : const {2, 3, 4};
  List<String> partHeader(String part) => [
    'Description',
    part,
    'Qty',
    'Unit',
    if (shipping) info.word('shipping'),
    'Amount',
  ];

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
                  row(info.word('equipment'), estimate.equipmentTotal),
                if (estimate.hardware.isNotEmpty)
                  row(info.word('hardware'), estimate.hardwareTotal),
                if (estimate.cabling.isNotEmpty)
                  row(info.word('cabling'), estimate.cablingTotal),
                if (estimate.labor.isNotEmpty) row(info.word('labor'), estimate.laborTotal),
                if (estimate.extras.isNotEmpty)
                  row(info.word('other'), estimate.extrasTotal),
                if (shipping) row(info.word('shipping'), estimate.shippingTotal),
                divider,
                row(info.word('subtotal'), estimate.subtotal, strong: true),
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
            color: accent,
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: pw.Text(
                    t(info.word('total').toUpperCase()),
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

  // The title takes whichever side the logo leaves free.
  final titleAlign = logo != null && info.logoOnLeft
      ? pw.CrossAxisAlignment.end
      : pw.CrossAxisAlignment.start;
  final titleTextAlign = logo != null && info.logoOnLeft
      ? pw.TextAlign.right
      : pw.TextAlign.left;

  pw.Widget logoBox(pw.ImageProvider image) => pw.ConstrainedBox(
    constraints: const pw.BoxConstraints(maxWidth: 170, maxHeight: 64),
    child: pw.Image(image, fit: pw.BoxFit.contain),
  );

  pw.Widget firstPageHeader() => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (logo != null && info.logoOnLeft) logoBox(logo),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: titleAlign,
              children: [
                pw.Text(
                  t(title.toUpperCase()),
                  textAlign: titleTextAlign,
                  style: pw.TextStyle(
                    fontSize: 24,
                    color: accent,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text(
                    t(subtitle),
                    textAlign: titleTextAlign,
                    style: pw.TextStyle(fontSize: 13, color: _ink),
                  ),
                ],
              ],
            ),
          ),
          if (logo != null && !info.logoOnLeft) logoBox(logo),
        ],
      ),
      pw.SizedBox(height: 12),
      pw.Container(height: 2, color: accent),
      pw.SizedBox(height: 10),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (info.projectName.trim().isNotEmpty)
            pw.Expanded(
              flex: 3,
              child: detail(info.word('project'), [info.projectName]),
            ),
          pw.Expanded(
            flex: 2,
            child: detail(info.word('date'), [estimateDateLabel(info.date)]),
          ),
          if ('${info.preparedBy}${info.preparerContact}'.trim().isNotEmpty)
            pw.Expanded(
              flex: 3,
              child: detail(info.word('preparedBy'), [
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
      sectionTitle(info.word('scope')),
      ...paragraphs(info.scopeOfWork),
    ],
    ...customSections(EstimateSectionPlace.beforePricing),
    if (estimate.equipment.isNotEmpty) ...[
      sectionTitle(info.word('equipment')),
      table(
        header: partHeader('Model / Part'),
        flex: partFlex,
        numeric: partNumeric,
        rows: partRows(estimate.equipment),
      ),
    ],
    if (estimate.hardware.isNotEmpty) ...[
      sectionTitle(info.word('hardware')),
      table(
        header: partHeader('Model / Part'),
        flex: partFlex,
        numeric: partNumeric,
        rows: partRows(estimate.hardware),
      ),
    ],
    if (estimate.cabling.isNotEmpty) ...[
      sectionTitle(info.word('cabling')),
      table(
        header: partHeader('Part'),
        flex: partFlex,
        numeric: partNumeric,
        rows: partRows(estimate.cabling, model: false),
      ),
    ],
    if (estimate.labor.isNotEmpty) ...[
      sectionTitle(info.word('labor')),
      table(
        header: const [
          'Description',
          'Crew',
          'Crew hours',
          'Total hours',
          'Rate',
          'Amount',
        ],
        flex: const [3.8, 0.9, 1.2, 1.2, 1.4, 1.6],
        numeric: const {1, 2, 3, 4, 5},
        rows: [
          for (final line in estimate.labor)
            [
              cell(line.roleName, sub: line.description),
              cell(trimNumber(line.techs), right: true),
              cell(trimNumber(line.hours), right: true),
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
      sectionTitle(info.word('other')),
      table(
        header: partHeader('Part'),
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
      sectionTitle(info.word('notes')),
      ...paragraphs(info.notes),
    ],
    ...customSections(EstimateSectionPlace.afterTotals),
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
                      t('$title - ${info.roomName}'.trim()),
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
            // WHICH ROOM THIS IS, not who made it. An estimate is read as
            // loose pages next to three others, and the question asked of
            // page 4 is which room it belongs to. Who prepared it is already
            // on the first page, beside the date.
            pw.Expanded(
              child: pw.Text(
                t(info.roomName.trim().isEmpty
                    ? ''
                    : '$title for ${info.roomName.trim()}'),
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
