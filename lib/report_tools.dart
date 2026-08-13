import 'dart:math' as math;
import 'dart:typed_data';

import 'xlsx_writer.dart';

/// ============================================================================
///  SHARED REPORT RENDERING
/// ============================================================================
///  Both diagram tabs export the same shape of report: a stack of titled
///  sections, each with a header row and data rows, rendered three ways —
///  a banded .xlsx sheet, a fixed-width .txt file, and a clipboard copy.
///
///  The rendering used to live inside the Schematic tab's widget state. It is
///  here so the AV Flow tab's cable schedule comes out looking identical
///  without a second copy of the column-width and banding rules.
/// ============================================================================

/// One report section: a title, a header row, and data rows.
typedef ReportSection = ({
  String title,
  List<String> header,
  List<List<dynamic>> rows,
});

/// When a report was produced, as it is stamped on every one of them.
///
/// A report with no date on it is a report nobody can tell is out of date —
/// and these get printed, mailed and filed next to older ones for the same
/// room. Sortable and unambiguous rather than pretty, and local time because
/// that is the clock the person reading it was working to.
String reportTimestamp([DateTime? at]) {
  final t = (at ?? DateTime.now()).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}

/// Fixed-width plain-text rendering — the .txt export and the clipboard copy.
///
/// [generated] is the stamp under the title; it defaults to now and is passed
/// in only by tests and by callers writing several documents that should all
/// carry the same moment.
String renderTextReport(
  String title,
  List<ReportSection> sections, {
  DateTime? generated,
}) {
  final buffer = StringBuffer();
  buffer.writeln(title); // the room and nothing else, like the xlsx
  buffer.writeln('Generated ${reportTimestamp(generated)}');
  buffer.writeln();
  for (final s in sections) {
    buffer.writeln(s.title);
    buffer.writeln('=' * s.title.length);
    // A cell listing several things carries them one per LINE — the same cell
    // the .xlsx writes wrapped. Here that means one row can occupy several
    // physical lines, with the other columns blank underneath, so the columns
    // still line up instead of a newline blowing the whole table apart.
    final all = [
      for (final row in [s.header, ...s.rows])
        [for (final cell in row) cell.toString().split('\n')],
    ];
    final widths = <int>[];
    for (final row in all) {
      for (int c = 0; c < row.length; c++) {
        final len = row[c].fold<int>(0, (m, line) => math.max(m, line.length));
        if (c >= widths.length) {
          widths.add(len);
        } else if (len > widths[c]) {
          widths[c] = len;
        }
      }
    }
    for (int r = 0; r < all.length; r++) {
      final row = all[r];
      final height = row.fold<int>(1, (m, lines) => math.max(m, lines.length));
      for (int line = 0; line < height; line++) {
        buffer.writeln([
          for (int c = 0; c < row.length; c++)
            (line < row[c].length ? row[c][line] : '').padRight(widths[c]),
        ].join('  ').trimRight());
      }
      if (r == 0) buffer.writeln(widths.map((w) => '-' * w).join('  '));
    }
    buffer.writeln();
  }
  return buffer.toString();
}

/// ONE sheet with the sections stacked like the text report, and [image]
/// (usually the diagram) dropped in underneath.
///
/// Title/header rows are padded with blank cells to the section's widest row,
/// so their background band runs the full width of the data beneath them —
/// auto column widths already size each column to its longest value — and
/// data rows are padded the same way and zebra-striped.
///
/// 2-column sections (key/value blocks) sit in columns A and B with their
/// VALUE cell excluded from auto-sizing, so a long room or building name
/// overflows right into the empty cells instead of stretching a column that
/// a wide table below also uses.
XlsxSheet buildStackedReportSheet({
  required String sheetName,
  required String title,
  required List<ReportSection> sections,
  /// Called once the row count is known, so the diagram lands below the
  /// tables. Returning null (unreadable PNG) simply omits the image.
  XlsxImage? Function(int anchorRow)? imageBuilder,
  /// The stamp under the title band. Defaults to now; passed in when a whole
  /// book of sheets should agree on the moment it was produced.
  DateTime? generated,
}) {
  List<dynamic> pad(List<dynamic> row, int width) =>
      [...row, ...List.filled(math.max(0, width - row.length), '')];
  int widthOf(ReportSection s) =>
      s.rows.fold(s.header.length, (m, r) => math.max(m, r.length));

  final rows = <List<dynamic>>[];
  final rowStyles = <int, int>{};
  final overflowRows = <int>{};
  final int reportWidth = sections.fold(1, (w, s) => math.max(w, widthOf(s)));

  // Row 1 carries the room and nothing else, merged across A:E so the title
  // band reads as one cell instead of a value stuck in column A. Row 2 says
  // when the sheet was produced, plainly, below the band rather than in it.
  rows.add(pad([title], reportWidth));
  rowStyles[0] = XlsxRowStyle.title;
  rows.add(pad(['Generated ${reportTimestamp(generated)}'], reportWidth));

  for (final s in sections) {
    final bool twoColumn = s.header.length == 2;
    final int width = twoColumn ? 2 : widthOf(s);
    rows.add([]);
    rowStyles[rows.length] = XlsxRowStyle.title;
    rows.add(pad([s.title], width));
    rowStyles[rows.length] = XlsxRowStyle.header;
    rows.add(pad(s.header, width));
    for (int i = 0; i < s.rows.length; i++) {
      if (i.isOdd) rowStyles[rows.length] = XlsxRowStyle.zebra;
      if (twoColumn) overflowRows.add(rows.length);
      rows.add(pad(s.rows[i], width));
    }
  }

  return XlsxSheet(
    name: sheetName,
    rows: rows,
    rowStyles: rowStyles,
    overflowRows: overflowRows,
    merges: const ['A1:E1'],
    image: imageBuilder?.call(rows.length + 1),
  );
}

/// One workbook sheet holding one captured drawing and nothing else.
///
/// The tables are on the report's own sheet; repeating them under every
/// drawing would be five copies of one schedule with a different picture over
/// each. [drawing] is a [PlanDrawing] — taken structurally so this stays below
/// the capture code rather than depending on it.
XlsxSheet drawingSheet(
  String title,
  ({String name, String caption, Uint8List bytes}) drawing,
  DateTime generated,
) {
  final rows = <List<dynamic>>[
    ['$title — ${drawing.caption}', '', '', '', ''],
    ['Generated ${reportTimestamp(generated)}'],
    [],
  ];
  return XlsxSheet(
    name: drawing.name,
    rows: rows,
    rowStyles: const {0: XlsxRowStyle.title},
    merges: const ['A1:E1'],
    image: scaledSheetImage(drawing.bytes, rows.length + 1),
  );
}

/// A name Excel will take for a worksheet: it refuses `: \ / ? * [ ]` and
/// stops at 31 characters, and "Fiber (OS2)" is a real cable type.
String xlsxSheetName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();
  return cleaned.length > 31 ? cleaned.substring(0, 31) : cleaned;
}

/// [xlsxSheetName], plus a number when the book already holds that name.
///
/// Excel refuses to open a workbook with two sheets called the same thing, so
/// a book built a sheet per drawing has to settle collisions before it is
/// written: two plans named alike, or two names that only differ past the 31st
/// character, is a real room rather than a hypothetical one. The name settled
/// on is added to [taken], folded to lower case — Excel treats "Level 1" and
/// "level 1" as the same sheet.
String uniqueXlsxSheetName(String proposed, Set<String> taken) {
  var base = xlsxSheetName(proposed);
  if (base.isEmpty) base = 'Sheet';
  var name = base;
  var n = 2;
  while (!taken.add(name.toLowerCase())) {
    final suffix = ' ($n)';
    final head = base.length + suffix.length > 31
        ? base.substring(0, 31 - suffix.length)
        : base;
    name = '$head$suffix';
    n++;
  }
  return name;
}

/// Scales a captured PNG to [targetWidth] px and anchors it at [anchorRow],
/// preserving its aspect ratio. Returns null when the bytes aren't a readable
/// PNG, which is the caller's cue to write the sheet without a diagram.
XlsxImage? scaledSheetImage(
  Uint8List pngBytes,
  int anchorRow, {
  int targetWidth = 900,
}) {
  final size = XlsxImage.pngSize(pngBytes);
  if (size == null) return null;
  return XlsxImage(
    pngBytes: pngBytes,
    anchorCol: 0,
    anchorRow: anchorRow,
    widthPx: targetWidth,
    heightPx: (size.$2 * targetWidth / size.$1).round(),
  );
}
