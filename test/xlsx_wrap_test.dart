import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// A cell that lists several things — the pull boxes a run is routed through,
/// the sheets a location is drawn on, the four names behind one pack-list line
/// — carries them ONE PER LINE.
///
/// Excel does not auto-fit a file it did not write, so a newline on its own
/// buys nothing: without wrapText the first line shows and the rest hide
/// behind the next column, and without a row height the extra lines are
/// clipped. Both have to be written, which is what these check. The plain-text
/// report has the same job to do and a different way of doing it.
void main() {
  String sheetXml(List<XlsxSheet> sheets) {
    final archive = ZipDecoder().decodeBytes(buildXlsx(sheets));
    final file = archive.files.firstWhere(
      (f) => f.name == 'xl/worksheets/sheet1.xml',
    );
    return utf8.decode(file.content as List<int>);
  }

  String stylesXml(List<XlsxSheet> sheets) {
    final archive = ZipDecoder().decodeBytes(buildXlsx(sheets));
    final file = archive.files.firstWhere((f) => f.name == 'xl/styles.xml');
    return utf8.decode(file.content as List<int>);
  }

  XlsxSheet withVia() => XlsxSheet(
    name: 'Runs',
    rows: [
      ['Run', 'Routed through'],
      ['SCRSW_1', 'AV pull box\nCeiling pull box\nEquipment rack'],
      ['SCRSW_2', 'Equipment rack'],
    ],
  );

  group('the workbook', () {
    test('a multi-line cell is written wrapped', () {
      final xml = sheetXml([withVia()]);
      // The wrapped styles are appended after the five row styles (and any
      // money formats), so the first of them is id 5 with no currency in the
      // book. The plain cell beside it keeps the row style.
      expect(xml, contains('AV pull box\nCeiling pull box\nEquipment rack'));
      expect(xml, contains('<c r="B2" s="5"'));
      expect(xml, contains('<c r="A2" t="inlineStr"'),
          reason: 'a single-line cell is not given a wrap style');
    });

    test('the wrapped styles are actually declared', () {
      final xml = stylesXml([withVia()]);
      expect(xml, contains('wrapText="1"'));
      expect(xml, contains('<cellXfs count="10">'),
          reason: 'five row styles plus one wrapped variant of each');
    });

    test('its row is given a height that fits the lines', () {
      final xml = sheetXml([withVia()]);
      expect(xml, contains('<row r="2" ht="42" customHeight="1">'));
      expect(xml, contains('<row r="3">'),
          reason: 'a row with nothing wrapped keeps the default height');
    });

    test('the column is sized to the longest LINE, not the whole cell', () {
      final xml = sheetXml([withVia()]);
      // "Ceiling pull box" is 16 characters; the whole cell is 45. Sizing to
      // the cell would make the column three times wider than anything in it.
      expect(xml, contains('<col min="2" max="2" width="19.0"'));
    });

    test('a money cell in a book with wrapped cells still gets its format', () {
      final xml = sheetXml([
        XlsxSheet(
          name: 'Costs',
          rows: [
            ['Item', 'Where', 'Cost'],
            [
              'Ceiling mic',
              'Ceiling row 1\nCeiling row 2',
              const XlsxMoney(value: 1200, text: r'$1,200.00'),
            ],
          ],
        ),
      ]);
      // Money styles come first (5,6,7), so the wrapped ones start at 8.
      expect(xml, contains('<c r="C2" s="5"><v>1200.0</v></c>'));
      expect(xml, contains('<c r="B2" s="8"'));
    });
  });

  group('the plain-text report', () {
    test('a multi-line cell becomes several lines, columns still aligned', () {
      final text = renderTextReport(
        'Test Room',
        [
          (
            title: 'Runs',
            header: ['Run', 'Routed through', 'Cable'],
            rows: [
              ['SCRSW_1', 'AV pull box\nCeiling pull box', 'Cat 6a'],
              ['SCRSW_2', 'Equipment rack', 'Cat 5e'],
            ],
          ),
        ],
        generated: DateTime(2026, 1, 2, 3, 4),
      );
      final lines = text.split('\n').map((l) => l.trimRight()).toList();

      expect(lines, contains('SCRSW_1  AV pull box       Cat 6a'));
      // The continuation line carries only the cell that spilled, indented to
      // its own column.
      expect(lines, contains('         Ceiling pull box'));
      expect(lines, contains('SCRSW_2  Equipment rack    Cat 5e'));
    });

    test('a report with nothing wrapped reads exactly as it always did', () {
      final text = renderTextReport(
        'Test Room',
        [
          (
            title: 'Runs',
            header: ['Run', 'Cable'],
            rows: [
              ['SCRSW_1', 'Cat 6a'],
            ],
          ),
        ],
        generated: DateTime(2026, 1, 2, 3, 4),
      );
      expect(text, contains('Run      Cable'));
      expect(text, contains('-------  ------'));
      expect(text, contains('SCRSW_1  Cat 6a'));
    });
  });
}
