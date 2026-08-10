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
    final all = [s.header, ...s.rows];
    final widths = <int>[];
    for (final row in all) {
      for (int c = 0; c < row.length; c++) {
        final len = row[c].toString().length;
        if (c >= widths.length) {
          widths.add(len);
        } else if (len > widths[c]) {
          widths[c] = len;
        }
      }
    }
    for (int r = 0; r < all.length; r++) {
      buffer.writeln([
        for (int c = 0; c < all[r].length; c++)
          all[r][c].toString().padRight(widths[c]),
      ].join('  '));
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
