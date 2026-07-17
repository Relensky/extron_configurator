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
///  Cells: num -> numeric cell, everything else -> inline string (no shared
///  strings table needed).
///
///  Row styles (see [XlsxRowStyle]): normal, bold, section title (white on
///  dark blue fill), and column header (bold on light blue fill).
///
///  Column widths are computed automatically from the longest value in each
///  column unless an explicit width is given.
///
///  One PNG image per sheet can be anchored to a cell ([XlsxImage]) — used to
///  drop the schematic diagram into the report.
/// ============================================================================

/// Style ids usable in [XlsxSheet.rowStyles] (indexes into cellXfs).
class XlsxRowStyle {
  static const int normal = 0;
  static const int bold = 1;
  static const int title = 2; // bold white on dark blue
  static const int header = 3; // bold on light blue
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

class XlsxSheet {
  final String name;

  /// Row-major cell values. null cells are skipped (blank).
  final List<List<dynamic>> rows;

  /// Row index -> [XlsxRowStyle] id. Rows absent from the map are normal.
  final Map<int, int> rowStyles;

  /// Explicit column widths in characters, by column index. Columns not
  /// listed get an automatic width from their longest value.
  final Map<int, double> columnWidths;

  /// Optional embedded PNG (e.g. the schematic diagram).
  final XlsxImage? image;

  XlsxSheet({
    required this.name,
    required this.rows,
    this.rowStyles = const {0: XlsxRowStyle.header},
    this.columnWidths = const {},
    this.image,
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
  for (int i = 1; i <= sheets.length; i++) {
    contentTypes.write(
        '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
    if (sheets[i - 1].image != null) {
      drawingCount++;
      contentTypes.write(
          '<Override PartName="/xl/drawings/drawing$drawingCount.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>');
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
    // Excel sheet names: max 31 chars, no : \ / ? * [ ]
    final safeName =
        sheets[i].name.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();
    final clipped = safeName.length > 31 ? safeName.substring(0, 31) : safeName;
    sheetTags.write(
        '<sheet name="${esc(clipped.isEmpty ? 'Sheet${i + 1}' : clipped)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>');
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

  // --- xl/styles.xml ---
  // fonts:  0 normal, 1 bold, 2 bold white
  // fills:  0 none, 1 gray125 (Excel convention), 2 dark blue, 3 light blue
  // cellXfs: see XlsxRowStyle
  archive.add(ArchiveFile.string('xl/styles.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="3">'
      '<font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="12"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>'
      '</fonts>'
      '<fills count="4">'
      '<fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/><bgColor indexed="64"/></patternFill></fill>'
      '<fill><patternFill patternType="solid"><fgColor rgb="FFD9E2F3"/><bgColor indexed="64"/></patternFill></fill>'
      '</fills>'
      '<borders count="1"><border/></borders>'
      '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
      '<cellXfs count="4">'
      '<xf xfId="0"/>'
      '<xf fontId="1" applyFont="1" xfId="0"/>'
      '<xf fontId="2" fillId="2" applyFont="1" applyFill="1" xfId="0"/>'
      '<xf fontId="1" fillId="3" applyFont="1" applyFill="1" xfId="0"/>'
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

  int drawingIndex = 0;
  for (int i = 0; i < sheets.length; i++) {
    final sheet = sheets[i];
    final body = StringBuffer();

    // Column widths: explicit overrides win; otherwise size to the longest
    // value in the column (with padding), clamped to a sane range. Section
    // title rows (style 2) span conceptually and are ignored for sizing.
    final Map<int, double> widths = Map.of(sheet.columnWidths);
    final Map<int, int> maxLen = {};
    for (int r = 0; r < sheet.rows.length; r++) {
      if (sheet.rowStyles[r] == XlsxRowStyle.title) continue;
      final cells = sheet.rows[r];
      for (int c = 0; c < cells.length; c++) {
        final len = cells[c]?.toString().length ?? 0;
        if (len > (maxLen[c] ?? 0)) maxLen[c] = len;
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
      body.write('<row r="${r + 1}">');
      final cells = sheet.rows[r];
      for (int c = 0; c < cells.length; c++) {
        final value = cells[c];
        if (value == null) continue;
        final ref = '${colLetter(c)}${r + 1}';
        if (value is num) {
          body.write('<c r="$ref"$styleAttr><v>$value</v></c>');
        } else {
          body.write(
              '<c r="$ref"$styleAttr t="inlineStr"><is><t xml:space="preserve">${esc(value.toString())}</t></is></c>');
        }
      }
      body.write('</row>');
    }
    body.write('</sheetData>');

    String drawingTag = '';
    if (sheet.image != null) {
      drawingIndex++;
      final img = sheet.image!;
      final cx = img.widthPx * 9525; // px -> EMU
      final cy = img.heightPx * 9525;

      archive.add(ArchiveFile('xl/media/image$drawingIndex.png',
          img.pngBytes.length, img.pngBytes));

      archive.add(ArchiveFile.string('xl/drawings/drawing$drawingIndex.xml',
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" '
          'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<xdr:oneCellAnchor>'
          '<xdr:from><xdr:col>${img.anchorCol}</xdr:col><xdr:colOff>0</xdr:colOff>'
          '<xdr:row>${img.anchorRow}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>'
          '<xdr:ext cx="$cx" cy="$cy"/>'
          '<xdr:pic>'
          '<xdr:nvPicPr><xdr:cNvPr id="1" name="Schematic"/><xdr:cNvPicPr/></xdr:nvPicPr>'
          '<xdr:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>'
          '<xdr:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
          '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr>'
          '</xdr:pic>'
          '<xdr:clientData/>'
          '</xdr:oneCellAnchor>'
          '</xdr:wsDr>'));

      archive.add(ArchiveFile.string(
          'xl/drawings/_rels/drawing$drawingIndex.xml.rels',
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image$drawingIndex.png"/>'
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
