import 'dart:typed_data';

import 'package:archive/archive.dart';

/// ============================================================================
///  MINIMAL XLSX WRITER
/// ============================================================================
///  Generates a real Excel .xlsx workbook (a zip of Office Open XML parts)
///  from rows of plain Dart values, using the `archive` package that is
///  already in the dependency tree. The full-featured `excel` package cannot
///  be used here — its xml constraint conflicts with pdfrx — and the report
///  only needs strings/numbers with a bold header row, so this hand-rolled
///  writer covers it.
///
///  Cells: num -> numeric cell, everything else -> inline string (no shared
///  strings table needed). Style 1 = bold, used for header rows.
/// ============================================================================

class XlsxSheet {
  final String name;

  /// Row-major cell values. null cells are skipped (blank).
  final List<List<dynamic>> rows;

  /// Indexes of rows rendered bold (default: the first row = header).
  final Set<int> boldRows;

  /// Optional column widths in characters, by column index.
  final Map<int, double> columnWidths;

  XlsxSheet({
    required this.name,
    required this.rows,
    this.boldRows = const {0},
    this.columnWidths = const {},
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

  // --- [Content_Types].xml ---
  final sheetOverrides = StringBuffer();
  for (int i = 1; i <= sheets.length; i++) {
    sheetOverrides.write(
        '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
  }
  archive.add(ArchiveFile.string('[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '$sheetOverrides'
      '</Types>'));

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
    final safeName = sheets[i]
        .name
        .replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ')
        .trim();
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

  // --- xl/styles.xml (style 0 = normal, style 1 = bold) ---
  archive.add(ArchiveFile.string('xl/styles.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
      '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
      '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
      '<borders count="1"><border/></borders>'
      '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
      '<cellXfs count="2"><xf xfId="0"/><xf fontId="1" applyFont="1" xfId="0"/></cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>'));

  // --- worksheets ---
  String colLetter(int index) {
    var s = '';
    var n = index;
    while (n >= 0) {
      s = String.fromCharCode(65 + (n % 26)) + s;
      n = n ~/ 26 - 1;
    }
    return s;
  }

  for (int i = 0; i < sheets.length; i++) {
    final sheet = sheets[i];
    final body = StringBuffer();

    if (sheet.columnWidths.isNotEmpty) {
      body.write('<cols>');
      final indexes = sheet.columnWidths.keys.toList()..sort();
      for (final c in indexes) {
        body.write(
            '<col min="${c + 1}" max="${c + 1}" width="${sheet.columnWidths[c]}" customWidth="1"/>');
      }
      body.write('</cols>');
    }

    body.write('<sheetData>');
    for (int r = 0; r < sheet.rows.length; r++) {
      final styleAttr = sheet.boldRows.contains(r) ? ' s="1"' : '';
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

    archive.add(ArchiveFile.string('xl/worksheets/sheet${i + 1}.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '$body'
        '</worksheet>'));
  }

  return ZipEncoder().encodeBytes(archive);
}
