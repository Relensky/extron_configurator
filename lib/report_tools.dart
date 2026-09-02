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

/// Longer than this and a value is PROSE rather than a field.
///
/// The same figure as [kXlsxMaxColumnWidth], and deliberately so: it is the
/// widest column the writer will draw, so a value that does not fit inside it
/// is by definition one no column can hold.
const int kProseColumnChars = kXlsxMaxColumnWidth;

/// Which of a section's columns hold sentences rather than fields.
///
/// Never column 0. That one names the row - the scope item, the run, the part
/// - and a table whose rows have lost their names is not a table. Numbers are
/// never prose either: a figure is a figure however many digits it has, and
/// lifting one out of its column would take it out of the column somebody
/// totals.
Set<int> proseColumnsOf(ReportSection section) {
  final out = <int>{};
  final width = section.rows.fold(
    section.header.length,
    (m, r) => math.max(m, r.length),
  );
  for (int c = 1; c < width; c++) {
    var longest = 0;
    for (final row in section.rows) {
      if (c >= row.length) continue;
      final cell = row[c];
      if (cell == null || cell is num || cell is XlsxMoney) continue;
      for (final line in cell.toString().split('\n')) {
        if (line.length > longest) longest = line.length;
      }
    }
    if (longest > kProseColumnChars) out.add(c);
  }
  return out;
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
///
/// A SENTENCE IS NOT A COLUMN. Wherever a column holds prose — what the work
/// is, a note, a description that runs to a line and a half — it is lifted out
/// of the grid and written under its row, merged across the sheet and labeled
/// with the heading it came from. The reason is what it does to everything
/// ELSE on the row: a column sized to a hundred-character sentence is a column
/// the two-character quantities beside it are stranded at the left-hand edge
/// of, and the reader is left scrolling sideways past one paragraph to reach
/// the figures the sheet is opened for. Lifted out, the grid is as narrow as
/// its shortest honest width and the sentence is still there, on its own line,
/// where a sentence is legible. See [proseColumnsOf].
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
  // The title band and the stamp under it, both written across the sheet: a
  // caption is not a value in column A, and left as one it set that column's
  // width for every short cell below it.
  final merges = <String>['A1:E1', 'A2:E2'];
  final int reportWidth = sections.fold(1, (w, s) => math.max(w, widthOf(s)));

  /// The columns a lifted sentence is written across. At least two, or the
  /// "merge" would be one cell — which is a sentence back in column A, sizing
  /// it for every short value underneath.
  final int proseSpan = math.max(reportWidth, 2);

  // Row 1 carries the room and nothing else, merged across A:E so the title
  // band reads as one cell instead of a value stuck in column A. Row 2 says
  // when the sheet was produced, plainly, below the band rather than in it.
  rows.add(pad([title], reportWidth));
  rowStyles[0] = XlsxRowStyle.title;
  rows.add(pad(['Generated ${reportTimestamp(generated)}'], reportWidth));

  for (final s in sections) {
    final bool twoColumn = s.header.length == 2;
    final int width = twoColumn ? 2 : widthOf(s);
    // A key/value block is already narrow and already handled: its value
    // overflows right into the empty cells beside it.
    final prose = twoColumn ? const <int>{} : proseColumnsOf(s);
    final kept = [
      for (int c = 0; c < width; c++)
        if (!prose.contains(c)) c,
    ];
    // The band over the section runs the width of everything under it, the
    // lifted sentences included — and every row in the section is padded to
    // it, so the banding does not narrow at the grid and widen again at each
    // lifted line.
    final int band = prose.isEmpty ? width : math.max(kept.length, proseSpan);

    rows.add([]);
    rowStyles[rows.length] = XlsxRowStyle.title;
    // The section's name written across its band, the way the sheet's own
    // title is. Left in column A it is a caption Excel clips at that column's
    // edge, and 'Roles and Responsi' is not the name of anything.
    if (band >= 2) {
      merges.add(
        'A${rows.length + 1}:${xlsxColumnLetter(band - 1)}${rows.length + 1}',
      );
    }
    rows.add(pad([s.title], band));
    rowStyles[rows.length] = XlsxRowStyle.header;
    rows.add(pad(
        [for (final c in kept) c < s.header.length ? s.header[c] : ''], band));
    for (int i = 0; i < s.rows.length; i++) {
      final row = s.rows[i];
      final int style = i.isOdd ? XlsxRowStyle.zebra : XlsxRowStyle.normal;
      if (i.isOdd) rowStyles[rows.length] = XlsxRowStyle.zebra;
      if (twoColumn) overflowRows.add(rows.length);
      rows.add(
          pad([for (final c in kept) c < row.length ? row[c] : ''], band));

      // The sentences, each on its own line under the row it belongs to and
      // labeled with the heading it came from — without the label a merged
      // line of prose under a table is a line of prose from nowhere.
      for (final c in prose) {
        final text = (c < row.length ? row[c] : '')?.toString() ?? '';
        if (text.trim().isEmpty) continue;
        final head = c < s.header.length ? s.header[c].trim() : '';
        // The continuation row takes its parent's banding, so the pair reads
        // as one row rather than as a row and a stray line under it.
        if (style != XlsxRowStyle.normal) rowStyles[rows.length] = style;
        merges.add(
          'A${rows.length + 1}:'
          '${xlsxColumnLetter(proseSpan - 1)}${rows.length + 1}',
        );
        rows.add(pad([head.isEmpty ? text : '$head:  $text'], proseSpan));
      }
    }
  }

  return XlsxSheet(
    name: sheetName,
    rows: rows,
    rowStyles: rowStyles,
    overflowRows: overflowRows,
    merges: merges,
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
    ['$title - ${drawing.caption}', '', '', '', ''],
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
