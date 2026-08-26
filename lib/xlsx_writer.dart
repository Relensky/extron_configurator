import 'dart:typed_data';

import 'package:archive/archive.dart';

/// ============================================================================
///  MINIMAL XLSX WRITER
/// ============================================================================
///  Generates a real Excel .xlsx workbook (a zip of Office Open XML parts)
///  from rows of plain Dart values, using the `archive` package that is
///  already in the dependency tree. The full-featured `excel` package cannot
///  be used here — its xml constraint conflicts with pdfrx — and the report
///  only needs styled rows plus one embedded image, so this hand-rolled
///  writer covers it.
///
///  Cells: num -> numeric cell, [XlsxMoney] -> numeric cell carrying a
///  currency format, everything else -> inline string (no shared strings
///  table needed).
///
///  Row styles (see [XlsxRowStyle]): normal, bold, section title (white on
///  dark blue fill), and column header (bold on light blue fill).
///
///  A string cell containing newlines is written WRAPPED, and its row is given
///  a height that fits the lines — so a cell listing four pull boxes shows
///  four lines rather than one long line clipped at the column edge. Callers
///  produce those cells simply by joining a list with '\n'.
///
///  Column widths are computed automatically from the longest LINE in each
///  column unless an explicit width is given.
///
///  One PNG image per sheet can be anchored to a cell ([XlsxImage]) — used to
///  drop the schematic diagram into the report.
///
///  A sheet can also carry native Excel charts ([XlsxChart]), bound to the
///  cells printed under them rather than drawn as a picture: a refresh plan is
///  argued with by dragging a figure, and a chart that does not move when the
///  figure does is a chart that gets ignored.
/// ============================================================================

/// Style ids usable in [XlsxSheet.rowStyles] (indexes into cellXfs).
class XlsxRowStyle {
  static const int normal = 0;
  static const int bold = 1;
  static const int title = 2; // bold white on dark blue
  static const int header = 3; // bold on light blue
  static const int zebra = 4; // normal on light gray (alternating data rows)
}

/// A money value in a cell.
///
/// Written as a NUMBER so Excel can sum it, with a currency number format
/// applied so it READS as money — a totals column of bare `2860` invites the
/// question of what unit it is in. [text] is the same figure already formatted
/// for a plain-text report, and is what [toString] (and therefore the column
/// width calculation) uses.
class XlsxMoney {
  final double value;
  final String text;

  /// The currency symbol the cell format is built around. One per workbook in
  /// practice; a book carrying two gets a number format for each.
  final String symbol;

  const XlsxMoney({
    required this.value,
    required this.text,
    this.symbol = r'$',
  });

  @override
  String toString() => text;
}

/// A cell whose FILL says whose it is.
///
/// The responsibility matrix is read by WHOSE NAME IS ON THE LINE, and on
/// screen every party carries its own colour so the contractor's rows can be
/// told from the owner's without reading a cell. Exported, that document was
/// black text on white and the reader was back to reading every line.
///
/// The colour is passed in already resolved rather than derived here: the app
/// has one place that decides what a name reads in - see `name_colors.dart` -
/// and a spreadsheet that picked its own hues would be a second answer to the
/// same question, disagreeing with the screen and with the picture export.
///
/// [text] is what the cell says, and what a plain-text report prints, so a
/// tinted cell degrades to exactly the string it replaced.
class XlsxTint {
  final String text;

  /// The wash behind the text, 'RRGGBB'.
  final String fillHex;

  /// The ink on top of it, 'RRGGBB', already chosen to be legible on [fillHex].
  final String inkHex;

  const XlsxTint({
    required this.text,
    required this.fillHex,
    required this.inkHex,
  });

  /// What sorts the column widths, and what a text report prints.
  @override
  String toString() => text;
}

/// A PNG image anchored with its top-left corner at (anchorCol, anchorRow),
/// displayed at widthPx x heightPx (96-dpi pixels).
class XlsxImage {
  final Uint8List pngBytes;
  final int anchorCol;
  final int anchorRow;
  final int widthPx;
  final int heightPx;

  const XlsxImage({
    required this.pngBytes,
    required this.anchorCol,
    required this.anchorRow,
    required this.widthPx,
    required this.heightPx,
  });

  /// Reads the pixel size from a PNG's IHDR chunk (bytes 16..24), returning
  /// (width, height) — or null when the bytes aren't a valid PNG.
  static (int, int)? pngSize(Uint8List png) {
    if (png.length < 24) return null;
    if (png[0] != 0x89 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47) {
      return null;
    }
    final data = ByteData.sublistView(png);
    return (data.getUint32(16), data.getUint32(20));
  }
}

/// One bar on a chart: a column of numbers already written on the sheet.
///
/// The chart never carries its own copy of the figures. It points at the cells
/// the reader can see, so changing one in Excel redraws the bar — a chart whose
/// numbers were stored separately from the table under it is a chart that goes
/// out of date the first time somebody edits the sheet.
class XlsxChartSeries {
  /// What the legend calls it.
  final String name;

  /// 0-based column on the same sheet holding this series' values.
  final int column;

  /// 'RRGGBB'. Explicit rather than left to the theme: this writer produces no
  /// theme part, and a series with no colour of its own comes out black.
  final String colorHex;

  const XlsxChartSeries({
    required this.name,
    required this.column,
    required this.colorHex,
  });
}

/// A bar chart over a block of cells on the sheet it sits on.
///
/// WHY A REAL CHART AND NOT A PICTURE OF ONE. A budget meeting argues with the
/// shape of the spike — it drags a year, drops a building, and asks what the
/// bar does. A PNG pasted into a sheet cannot answer that; a chart bound to the
/// cells can, and it re-scales itself when somebody widens it to fit a slide.
class XlsxChart {
  /// The heading over the plot.
  final String title;

  /// 0-based column holding the category labels — the years.
  final int categoryColumn;

  /// The data rows, 0-based and INCLUSIVE. The header row is not one of them.
  final int firstRow;
  final int lastRow;

  final List<XlsxChartSeries> series;

  /// True to stack the series on one bar per year rather than clustering them
  /// side by side. What makes a campus chart answer "which building is driving
  /// that year" instead of just "which year is worst".
  final bool stacked;

  /// The value axis' number format, e.g. `"$"#,##0`.
  final String numberFormat;

  /// What the axes are called. Null leaves the axis unlabelled.
  final String? valueAxisTitle;
  final String? categoryAxisTitle;

  /// Where it sits, and how big it is drawn (96-dpi pixels).
  final int anchorCol;
  final int anchorRow;
  final int widthPx;
  final int heightPx;

  const XlsxChart({
    required this.title,
    required this.categoryColumn,
    required this.firstRow,
    required this.lastRow,
    required this.series,
    this.stacked = false,
    this.numberFormat = '#,##0',
    this.valueAxisTitle,
    this.categoryAxisTitle,
    this.anchorCol = 0,
    this.anchorRow = 0,
    this.widthPx = 900,
    this.heightPx = 420,
  });
}

class XlsxSheet {
  final String name;

  /// Row-major cell values. null cells are skipped (blank).
  final List<List<dynamic>> rows;

  /// Row index -> [XlsxRowStyle] id. Rows absent from the map are normal.
  final Map<int, int> rowStyles;

  /// Explicit column widths in characters, by column index. Columns not
  /// listed get an automatic width from their longest value.
  final Map<int, double> columnWidths;

  /// Rows whose LAST cell is excluded from the automatic column-width
  /// computation: that value overflows into the empty cells to its right
  /// instead of stretching the shared column — used for long free-text
  /// values (room/building names) that would otherwise blow up a column
  /// other sections also use. The row's other cells still size normally, and
  /// a NUMBER in that position is sized anyway — it has nowhere to overflow
  /// to and would come out as ###.
  final Set<int> overflowRows;

  /// Cell ranges to merge, in A1 notation ("A1:E1"). The merged block takes
  /// the style and value of its top-left cell; the cells it swallows must be
  /// blank or Excel reports the file as corrupt.
  final List<String> merges;

  /// Optional embedded PNG (e.g. the schematic diagram).
  final XlsxImage? image;

  /// Charts drawn from this sheet's own cells. Empty on a sheet of tables.
  final List<XlsxChart> charts;

  XlsxSheet({
    required this.name,
    required this.rows,
    this.rowStyles = const {0: XlsxRowStyle.header},
    this.columnWidths = const {},
    this.overflowRows = const {},
    this.merges = const [],
    this.image,
    this.charts = const [],
  });
}

/// Builds the .xlsx file bytes for [sheets].
Uint8List buildXlsx(List<XlsxSheet> sheets) {
  final archive = Archive();

  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  final bool anyImage = sheets.any((s) => s.image != null);

  /// The name each sheet ends up carrying in the book, settled once.
  ///
  /// Settled HERE rather than where workbook.xml is written, because a chart's
  /// cell references name the sheet they read — and a reference to a name the
  /// workbook clipped differently is a chart Excel opens empty.
  final sheetNames = <String>[
    for (int i = 0; i < sheets.length; i++)
      () {
        // Excel sheet names: max 31 chars, no : \ / ? * [ ]
        final safe = sheets[i].name.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();
        final clipped = safe.length > 31 ? safe.substring(0, 31) : safe;
        return clipped.isEmpty ? 'Sheet${i + 1}' : clipped;
      }(),
  ];

  // --- [Content_Types].xml ---
  final contentTypes = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>');
  if (anyImage) {
    contentTypes.write('<Default Extension="png" ContentType="image/png"/>');
  }
  contentTypes.write(
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>');
  int drawingCount = 0;
  int chartCount = 0;
  for (int i = 1; i <= sheets.length; i++) {
    contentTypes.write(
        '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
    final sheet = sheets[i - 1];
    // One drawing part per sheet that has anything to draw — a picture, a
    // chart, or both on the same page.
    if (sheet.image != null || sheet.charts.isNotEmpty) {
      drawingCount++;
      contentTypes.write(
          '<Override PartName="/xl/drawings/drawing$drawingCount.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>');
    }
    for (var c = 0; c < sheet.charts.length; c++) {
      chartCount++;
      contentTypes.write(
          '<Override PartName="/xl/charts/chart$chartCount.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>');
    }
  }
  contentTypes.write('</Types>');
  archive.add(ArchiveFile.string('[Content_Types].xml', contentTypes.toString()));

  // --- _rels/.rels ---
  archive.add(ArchiveFile.string('_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>'));

  // --- xl/workbook.xml ---
  final sheetTags = StringBuffer();
  for (int i = 0; i < sheets.length; i++) {
    sheetTags.write(
        '<sheet name="${esc(sheetNames[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>');
  }
  archive.add(ArchiveFile.string('xl/workbook.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>$sheetTags</sheets>'
      '</workbook>'));

  // --- xl/_rels/workbook.xml.rels ---
  final relTags = StringBuffer();
  for (int i = 1; i <= sheets.length; i++) {
    relTags.write(
        '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>');
  }
  relTags.write(
      '<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>');
  archive.add(ArchiveFile.string('xl/_rels/workbook.xml.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '$relTags'
      '</Relationships>'));

  // --- currency formats ---
  // One number format per distinct currency in the book, so a money cell can
  // be a number Excel sums AND show its symbol. The three cellXfs per symbol
  // are the row styles a money cell can land in: plain, zebra, bold.
  final currencies = <String>[];
  for (final sheet in sheets) {
    for (final row in sheet.rows) {
      for (final value in row) {
        if (value is XlsxMoney && !currencies.contains(value.symbol)) {
          currencies.add(value.symbol);
        }
      }
    }
  }
  const int firstMoneyStyle = 5; // cellXfs index after the XlsxRowStyle block
  const int firstNumFmtId = 164; // 0..163 are Excel's built-in formats

  /// The cellXfs index for a money cell sitting in a [rowStyle] row.
  int moneyStyle(String symbol, int rowStyle) {
    final base = firstMoneyStyle + currencies.indexOf(symbol) * 3;
    if (rowStyle == XlsxRowStyle.zebra) return base + 1;
    if (rowStyle == XlsxRowStyle.bold) return base + 2;
    return base;
  }

  final numFmts = StringBuffer();
  final moneyXfs = StringBuffer();
  if (currencies.isNotEmpty) {
    numFmts.write('<numFmts count="${currencies.length}">');
    for (int i = 0; i < currencies.length; i++) {
      final id = firstNumFmtId + i;
      final code = '&quot;${esc(currencies[i])}&quot;#,##0.00';
      numFmts.write('<numFmt numFmtId="$id" formatCode="$code"/>');
      moneyXfs.write(
          '<xf numFmtId="$id" applyNumberFormat="1" xfId="0"/>'
          '<xf numFmtId="$id" fillId="4" applyNumberFormat="1" applyFill="1" xfId="0"/>'
          '<xf numFmtId="$id" fontId="1" applyNumberFormat="1" applyFont="1" xfId="0"/>');
    }
    numFmts.write('</numFmts>');
  }
  final int firstWrapStyle = firstMoneyStyle + currencies.length * 3;

  /// The cellXfs index for a WRAPPED cell sitting in a [rowStyle] row.
  ///
  /// A string with newlines in it needs wrapText or Excel shows the first line
  /// and hides the rest behind the next column — which is the whole point of
  /// putting each item on its own line in the first place. One variant per row
  /// style, appended after the money formats so the plain ids (which are also
  /// the row style ids) keep their meaning.
  int wrapStyle(int rowStyle) => firstWrapStyle + rowStyle;

  /// True when [value] is text that should be written wrapped.
  bool wraps(dynamic value) =>
      value != null &&
      value is! num &&
      value is! XlsxMoney &&
      value is! XlsxTint &&
      value.toString().contains('\n');

  // --- the party and vendor colours ---
  // One font and one fill per distinct pair in the book, so a name that
  // appears on nine rows and two sheets costs one style rather than eleven.
  final tints = <String>[];
  String tintKey(XlsxTint t) => '${t.fillHex}|${t.inkHex}';
  for (final sheet in sheets) {
    for (final row in sheet.rows) {
      for (final value in row) {
        if (value is XlsxTint && !tints.contains(tintKey(value))) {
          tints.add(tintKey(value));
        }
      }
    }
  }
  final int firstTintStyle = firstWrapStyle + 5;

  /// The cellXfs index for a tinted cell. Its own fill IS the point, so it
  /// ignores the row's banding rather than being washed over by it.
  int tintStyle(XlsxTint t) => firstTintStyle + tints.indexOf(tintKey(t));

  final tintFonts = StringBuffer();
  final tintFills = StringBuffer();
  final tintXfs = StringBuffer();
  for (final key in tints) {
    final parts = key.split('|');
    tintFills.write('<fill><patternFill patternType="solid">'
        '<fgColor rgb="FF${parts[0]}"/><bgColor indexed="64"/>'
        '</patternFill></fill>');
    tintFonts.write('<font><sz val="11"/><color rgb="FF${parts[1]}"/>'
        '<name val="Calibri"/></font>');
    tintXfs.write(
        '<xf fontId="${3 + tints.indexOf(key)}" fillId="${5 + tints.indexOf(key)}" '
        'applyFont="1" applyFill="1" xfId="0"/>');
  }

  /// The five wrapped variants: the same fonts and fills as [XlsxRowStyle],
  /// plus top-aligned wrapText so a two-line cell sits against the top of its
  /// row rather than floating in the middle of it.
  const String wrapAlign =
      '<alignment wrapText="1" vertical="top"/>';
  final String wrapXfs =
      '<xf applyAlignment="1" xfId="0">$wrapAlign</xf>'
      '<xf fontId="1" applyFont="1" applyAlignment="1" xfId="0">$wrapAlign</xf>'
      '<xf fontId="2" fillId="2" applyFont="1" applyFill="1" applyAlignment="1" xfId="0">$wrapAlign</xf>'
      '<xf fontId="1" fillId="3" applyFont="1" applyFill="1" applyAlignment="1" xfId="0">$wrapAlign</xf>'
      '<xf fillId="4" applyFill="1" applyAlignment="1" xfId="0">$wrapAlign</xf>';

  final int cellXfCount = firstTintStyle + tints.length;

  // --- xl/styles.xml ---
  // fonts:  0 normal, 1 bold, 2 bold white
  // fills:  0 none, 1 gray125 (Excel convention), 2 dark blue, 3 light blue
  // cellXfs: see XlsxRowStyle, three per currency (see moneyStyle), then one
  //          wrapped variant per row style (see wrapStyle)
  archive.add(ArchiveFile.string('xl/styles.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '$numFmts'
      '<fonts count="${3 + tints.length}">'
      '<font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="12"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
      '$tintFonts'
      '</fonts>'
      '<fills count="${5 + tints.length}">'
      '<fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/><bgColor indexed="64"/></patternFill></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFD9E2F3"/><bgColor indexed="64"/></patternFill></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFEFEFEF"/><bgColor indexed="64"/></patternFill></fill>'
      '$tintFills'
      '</fills>'
      '<borders count="1"><border/></borders>'
      '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
      '<cellXfs count="$cellXfCount">'
      '<xf xfId="0"/>'
      '<xf fontId="1" applyFont="1" xfId="0"/>'
      '<xf fontId="2" fillId="2" applyFont="1" applyFill="1" xfId="0"/>'
      '<xf fontId="1" fillId="3" applyFont="1" applyFill="1" xfId="0"/>'
      '<xf fillId="4" applyFill="1" xfId="0"/>'
      '$moneyXfs'
      '$wrapXfs'
      '$tintXfs'
      '</cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>'));

  // --- worksheets (+ optional drawing parts) ---
  String colLetter(int index) {
    var s = '';
    var n = index;
    while (n >= 0) {
      s = String.fromCharCode(65 + (n % 26)) + s;
      n = n ~/ 26 - 1;
    }
    return s;
  }

  /// Parses "A1:E1" into 0-based (firstCol, firstRow, lastCol, lastRow).
  /// Null for anything malformed, which the caller drops rather than writing
  /// a merge Excel would reject.
  (int, int, int, int)? parseRange(String range) {
    final m = RegExp(r'^([A-Z]+)(\d+):([A-Z]+)(\d+)$')
        .firstMatch(range.toUpperCase());
    if (m == null) return null;
    int colIndex(String letters) {
      var n = 0;
      for (final unit in letters.codeUnits) {
        n = n * 26 + (unit - 64); // 'A' is 65
      }
      return n - 1;
    }
    return (
      colIndex(m.group(1)!),
      int.parse(m.group(2)!) - 1,
      colIndex(m.group(3)!),
      int.parse(m.group(4)!) - 1,
    );
  }

  // -------------------------------------------------------------------------
  //  CHARTS
  // -------------------------------------------------------------------------

  /// An A1 reference to a column of cells on [sheetName], for a chart to read.
  ///
  /// The sheet name is quoted whether or not it needs to be: "Refresh by Year"
  /// has a space in it, and an unquoted reference to it is a chart Excel
  /// reports as broken.
  String cellRange(String sheetName, int col, int firstRow, int lastRow) {
    final quoted = sheetName.replaceAll("'", "''");
    final letter = colLetter(col);
    return esc(
        "'$quoted'!\$$letter\$${firstRow + 1}:\$$letter\$${lastRow + 1}");
  }

  /// The chart part: a bar per year, bound to the cells under it.
  String chartXml(XlsxSheet sheet, String sheetName, XlsxChart chart) {
    /// One cell as a number, or null when it is blank or text.
    double? numberAt(int row, int col) {
      if (row < 0 || row >= sheet.rows.length) return null;
      final cells = sheet.rows[row];
      if (col < 0 || col >= cells.length) return null;
      final value = cells[col];
      if (value is XlsxMoney) return value.value;
      if (value is num) return value.toDouble();
      return null;
    }

    String textAt(int row, int col) {
      if (row < 0 || row >= sheet.rows.length) return '';
      final cells = sheet.rows[row];
      if (col < 0 || col >= cells.length) return '';
      return cells[col]?.toString() ?? '';
    }

    final rows = [
      for (var r = chart.firstRow; r <= chart.lastRow; r++) r,
    ];

    // THE FIGURES TRAVEL WITH THE CHART AS WELL AS BEING POINTED AT.
    //
    // Excel recalculates a chart from its references the moment the file
    // opens, so the cache is redundant there. Everything else that reads an
    // .xlsx — a preview pane, a viewer on a phone, the thing that turns it
    // into a PDF for the packet — draws the cache and nothing else, and a
    // chart that is blank everywhere except in Excel is a chart nobody trusts.
    String numCache(String formatCode, List<double?> values) {
      final buffer = StringBuffer()
        ..write('<c:numCache><c:formatCode>${esc(formatCode)}</c:formatCode>'
            '<c:ptCount val="${values.length}"/>');
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        if (v != null) buffer.write('<c:pt idx="$i"><c:v>$v</c:v></c:pt>');
      }
      return (buffer..write('</c:numCache>')).toString();
    }

    // The years. Numbers when they are numbers — which keeps the axis labels
    // as "2031" rather than as a string Excel right-aligns oddly.
    final catNumbers = [for (final r in rows) numberAt(r, chart.categoryColumn)];
    final catRef = cellRange(
        sheetName, chart.categoryColumn, chart.firstRow, chart.lastRow);
    final String cat;
    if (catNumbers.every((v) => v != null)) {
      cat = '<c:numRef><c:f>$catRef</c:f>'
          '${numCache('General', catNumbers)}</c:numRef>';
    } else {
      final buffer = StringBuffer()
        ..write('<c:strRef><c:f>$catRef</c:f><c:strCache>'
            '<c:ptCount val="${rows.length}"/>');
      for (var i = 0; i < rows.length; i++) {
        buffer.write(
            '<c:pt idx="$i"><c:v>${esc(textAt(rows[i], chart.categoryColumn))}'
            '</c:v></c:pt>');
      }
      cat = (buffer..write('</c:strCache></c:strRef>')).toString();
    }

    final series = StringBuffer();
    for (var s = 0; s < chart.series.length; s++) {
      final spec = chart.series[s];
      final values = [for (final r in rows) numberAt(r, spec.column)];
      series.write(
          '<c:ser><c:idx val="$s"/><c:order val="$s"/>'
          '<c:tx><c:v>${esc(spec.name)}</c:v></c:tx>'
          '<c:spPr><a:solidFill><a:srgbClr val="${spec.colorHex}"/></a:solidFill>'
          '<a:ln><a:noFill/></a:ln></c:spPr>'
          '<c:invertIfNegative val="0"/>'
          '<c:cat>$cat</c:cat>'
          '<c:val><c:numRef><c:f>'
          '${cellRange(sheetName, spec.column, chart.firstRow, chart.lastRow)}'
          '</c:f>${numCache(chart.numberFormat, values)}</c:numRef></c:val>'
          '</c:ser>');
    }

    /// An axis label, laid on its side on the value axis.
    String axisTitle(String? text, {required bool rotated}) => text == null
        ? ''
        : '<c:title><c:tx><c:rich>'
            '<a:bodyPr${rotated ? ' rot="-5400000" vert="horz"' : ''}/>'
            '<a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="900"/>'
            '<a:t>${esc(text)}</a:t></a:r></a:p>'
            '</c:rich></c:tx><c:overlay val="0"/></c:title>';

    const catAxId = 411000001;
    const valAxId = 411000002;

    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<c:chartSpace '
        'xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<c:chart>'
        '<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/>'
        '<a:p><a:pPr><a:defRPr sz="1200" b="1"/></a:pPr>'
        '<a:r><a:rPr lang="en-US" sz="1200" b="1"/>'
        '<a:t>${esc(chart.title)}</a:t></a:r></a:p>'
        '</c:rich></c:tx><c:overlay val="0"/></c:title>'
        '<c:autoTitleDeleted val="0"/>'
        '<c:plotArea><c:layout/>'
        '<c:barChart><c:barDir val="col"/>'
        '<c:grouping val="${chart.stacked ? 'stacked' : 'clustered'}"/>'
        '<c:varyColors val="0"/>'
        '$series'
        '<c:gapWidth val="${chart.stacked ? 40 : 60}"/>'
        '<c:overlap val="${chart.stacked ? 100 : -20}"/>'
        '<c:axId val="$catAxId"/><c:axId val="$valAxId"/>'
        '</c:barChart>'
        '<c:catAx><c:axId val="$catAxId"/>'
        '<c:scaling><c:orientation val="minMax"/></c:scaling>'
        '<c:delete val="0"/><c:axPos val="b"/>'
        '${axisTitle(chart.categoryAxisTitle, rotated: false)}'
        '<c:numFmt formatCode="General" sourceLinked="0"/>'
        '<c:majorTickMark val="none"/><c:minorTickMark val="none"/>'
        '<c:tickLblPos val="nextTo"/>'
        '<c:crossAx val="$valAxId"/><c:crosses val="autoZero"/>'
        '<c:auto val="1"/><c:lblAlgn val="ctr"/><c:lblOffset val="100"/>'
        '<c:noMultiLvlLbl val="0"/></c:catAx>'
        '<c:valAx><c:axId val="$valAxId"/>'
        '<c:scaling><c:orientation val="minMax"/></c:scaling>'
        '<c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/>'
        '${axisTitle(chart.valueAxisTitle, rotated: true)}'
        '<c:numFmt formatCode="${esc(chart.numberFormat)}" sourceLinked="0"/>'
        '<c:majorTickMark val="none"/><c:minorTickMark val="none"/>'
        '<c:tickLblPos val="nextTo"/>'
        '<c:crossAx val="$catAxId"/><c:crosses val="autoZero"/>'
        '<c:crossBetween val="between"/></c:valAx>'
        '</c:plotArea>'
        // One series needs no legend: the title already says what the bars
        // are, and a key naming the only thing on the chart is furniture.
        '${chart.series.length > 1 ? '<c:legend><c:legendPos val="b"/><c:overlay val="0"/></c:legend>' : ''}'
        '<c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/>'
        '</c:chart>'
        '</c:chartSpace>';
  }

  int drawingIndex = 0;
  int chartPart = 0;
  for (int i = 0; i < sheets.length; i++) {
    final sheet = sheets[i];
    final body = StringBuffer();

    // Cells a merge swallows: written with their row style but NO value, so
    // the styled band runs the full width of the merge and Excel doesn't
    // complain about content hidden under a merged block.
    final List<String> merges =
        sheet.merges.where((m) => parseRange(m) != null).toList();
    final Set<String> swallowed = {};
    for (final range in merges) {
      final (firstCol, firstRow, lastCol, lastRow) = parseRange(range)!;
      for (int row = firstRow; row <= lastRow; row++) {
        for (int col = firstCol; col <= lastCol; col++) {
          if (row == firstRow && col == firstCol) continue; // anchor keeps it
          swallowed.add('${colLetter(col)}${row + 1}');
        }
      }
    }

    // Column widths: explicit overrides win; otherwise size to the longest
    // value in the column (with padding), clamped to a sane range. Section
    // title rows (style 2) span conceptually and are ignored for sizing.
    //
    // The longest LINE, not the longest value: a wrapped cell listing four
    // pull boxes is as wide as its widest one, and sizing it to the whole
    // string would make the column four times wider than anything in it.
    final Map<int, double> widths = Map.of(sheet.columnWidths);
    final Map<int, int> maxLen = {};
    // Row index -> how many lines its tallest wrapped cell needs.
    final Map<int, int> rowLines = {};
    for (int r = 0; r < sheet.rows.length; r++) {
      final cells = sheet.rows[r];
      final bool overflow = sheet.overflowRows.contains(r);
      for (int c = 0; c < cells.length; c++) {
        final cell = cells[c];
        final lines = cell?.toString().split('\n') ?? const <String>[];
        if (lines.length > (rowLines[r] ?? 1)) rowLines[r] = lines.length;
        if (sheet.rowStyles[r] == XlsxRowStyle.title) continue;
        // The excluded cell of an overflow row is only excused when it is
        // TEXT: text spills into the empty cells to its right, but a number
        // too wide for its column comes out as ###, so figures always size.
        if (overflow &&
            c == cells.length - 1 &&
            cell is! num &&
            cell is! XlsxMoney) {
          continue;
        }
        for (final line in lines) {
          if (line.length > (maxLen[c] ?? 0)) maxLen[c] = line.length;
        }
      }
    }
    maxLen.forEach((c, len) {
      widths.putIfAbsent(c, () => (len + 3).clamp(9, 55).toDouble());
    });

    if (widths.isNotEmpty) {
      body.write('<cols>');
      final indexes = widths.keys.toList()..sort();
      for (final c in indexes) {
        body.write(
            '<col min="${c + 1}" max="${c + 1}" width="${widths[c]}" customWidth="1"/>');
      }
      body.write('</cols>');
    }

    body.write('<sheetData>');
    for (int r = 0; r < sheet.rows.length; r++) {
      final int style = sheet.rowStyles[r] ?? XlsxRowStyle.normal;
      final styleAttr = style == XlsxRowStyle.normal ? '' : ' s="$style"';
      // A row carrying a wrapped cell is given the height its lines need.
      // Excel's own auto-fit does not run on a file it did not write, so
      // without this the extra lines are simply hidden — which is the same
      // thing as not having put them on their own lines at all.
      final int lines = rowLines[r] ?? 1;
      final String heightAttr = lines > 1
          ? ' ht="${(lines * 14).clamp(15, 409)}" customHeight="1"'
          : '';
      body.write('<row r="${r + 1}"$heightAttr>');
      final cells = sheet.rows[r];
      for (int c = 0; c < cells.length; c++) {
        final value = cells[c];
        final ref = '${colLetter(c)}${r + 1}';
        if (swallowed.contains(ref)) {
          body.write('<c r="$ref"$styleAttr/>');
          continue;
        }
        if (value == null) continue;
        if (value is XlsxTint) {
          // Its own fill and its own ink, whatever band the row is in.
          body.write(
              '<c r="$ref" s="${tintStyle(value)}" t="inlineStr">'
              '<is><t xml:space="preserve">${esc(value.text)}</t></is></c>');
        } else if (value is XlsxMoney) {
          // Its own style id: the row's banding plus the currency format.
          body.write(
              '<c r="$ref" s="${moneyStyle(value.symbol, style)}"><v>${value.value}</v></c>');
        } else if (value is num) {
          body.write('<c r="$ref"$styleAttr><v>$value</v></c>');
        } else {
          final String cellStyle =
              wraps(value) ? ' s="${wrapStyle(style)}"' : styleAttr;
          body.write(
              '<c r="$ref"$cellStyle t="inlineStr"><is><t xml:space="preserve">${esc(value.toString())}</t></is></c>');
        }
      }
      body.write('</row>');
    }
    body.write('</sheetData>');

    // mergeCells belongs after sheetData and before drawing in CT_Worksheet
    if (merges.isNotEmpty) {
      body.write('<mergeCells count="${merges.length}">');
      for (final range in merges) {
        body.write('<mergeCell ref="${range.toUpperCase()}"/>');
      }
      body.write('</mergeCells>');
    }

    String drawingTag = '';
    if (sheet.image != null || sheet.charts.isNotEmpty) {
      drawingIndex++;
      // One drawing part holds everything on the page. The picture, when there
      // is one, keeps rId1 so a book written before charts existed lays out
      // byte for byte the way it always did.
      final anchors = StringBuffer();
      final drawingRels = StringBuffer();
      var relId = 0;
      var shapeId = 0;

      if (sheet.image != null) {
        final img = sheet.image!;
        final cx = img.widthPx * 9525; // px -> EMU
        final cy = img.heightPx * 9525;
        relId++;
        shapeId++;

        archive.add(ArchiveFile('xl/media/image$drawingIndex.png',
            img.pngBytes.length, img.pngBytes));

        anchors.write(
            '<xdr:oneCellAnchor>'
            '<xdr:from><xdr:col>${img.anchorCol}</xdr:col><xdr:colOff>0</xdr:colOff>'
            '<xdr:row>${img.anchorRow}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>'
            '<xdr:ext cx="$cx" cy="$cy"/>'
            '<xdr:pic>'
            '<xdr:nvPicPr><xdr:cNvPr id="$shapeId" name="Schematic"/><xdr:cNvPicPr/></xdr:nvPicPr>'
            '<xdr:blipFill><a:blip r:embed="rId$relId"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>'
            '<xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr>'
            '</xdr:pic>'
            '<xdr:clientData/>'
            '</xdr:oneCellAnchor>');
        drawingRels.write(
            '<Relationship Id="rId$relId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image$drawingIndex.png"/>');
      }

      for (final chart in sheet.charts) {
        chartPart++;
        relId++;
        shapeId++;
        final cx = chart.widthPx * 9525;
        final cy = chart.heightPx * 9525;

        archive.add(ArchiveFile.string('xl/charts/chart$chartPart.xml',
            chartXml(sheet, sheetNames[i], chart)));

        anchors.write(
            '<xdr:oneCellAnchor>'
            '<xdr:from><xdr:col>${chart.anchorCol}</xdr:col><xdr:colOff>0</xdr:colOff>'
            '<xdr:row>${chart.anchorRow}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>'
            '<xdr:ext cx="$cx" cy="$cy"/>'
            '<xdr:graphicFrame macro="">'
            '<xdr:nvGraphicFramePr>'
            '<xdr:cNvPr id="$shapeId" name="Chart $chartPart"/>'
            '<xdr:cNvGraphicFramePr/>'
            '</xdr:nvGraphicFramePr>'
            '<xdr:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></xdr:xfrm>'
            '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">'
            '<c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
            'r:id="rId$relId"/>'
            '</a:graphicData></a:graphic>'
            '</xdr:graphicFrame>'
            '<xdr:clientData/>'
            '</xdr:oneCellAnchor>');
        drawingRels.write(
            '<Relationship Id="rId$relId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart$chartPart.xml"/>');
      }

      archive.add(ArchiveFile.string('xl/drawings/drawing$drawingIndex.xml',
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" '
          'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '$anchors'
          '</xdr:wsDr>'));

      archive.add(ArchiveFile.string(
          'xl/drawings/_rels/drawing$drawingIndex.xml.rels',
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '$drawingRels'
          '</Relationships>'));

      archive.add(ArchiveFile.string('xl/worksheets/_rels/sheet${i + 1}.xml.rels',
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing$drawingIndex.xml"/>'
          '</Relationships>'));

      drawingTag = '<drawing r:id="rId1"/>';
    }

    archive.add(ArchiveFile.string('xl/worksheets/sheet${i + 1}.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '$body'
        '$drawingTag'
        '</worksheet>'));
  }

  return ZipEncoder().encodeBytes(archive);
}
