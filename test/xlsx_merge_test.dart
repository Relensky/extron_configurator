import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/xlsx_writer.dart';

/// Merged cells are easy to get subtly wrong — Excel reports the whole
/// workbook as corrupt if a merge swallows a cell that still carries a value,
/// and there is no error until someone opens the file. These check the parts
/// that go into the zip directly.
void main() {
  /// The sheet1.xml text out of a built workbook.
  String sheetXml(List<XlsxSheet> sheets) {
    final archive = ZipDecoder().decodeBytes(buildXlsx(sheets));
    final file = archive.files.firstWhere((f) => f.name == 'xl/worksheets/sheet1.xml');
    return utf8.decode(file.content as List<int>);
  }

  group('merged cells', () {
    test('writes the mergeCells block after sheetData', () {
      final xml = sheetXml([
        XlsxSheet(
          name: 'Report',
          rows: [
            ['Room 461', '', '', '', ''],
            ['Setting', 'Value'],
          ],
          rowStyles: const {0: XlsxRowStyle.title},
          merges: const ['A1:E1'],
        ),
      ]);

      expect(xml, contains('<mergeCells count="1">'));
      expect(xml, contains('<mergeCell ref="A1:E1"/>'));
      expect(xml.indexOf('</sheetData>'), lessThan(xml.indexOf('<mergeCells')));
    });

    test('keeps the anchor value and empties the cells the merge swallows', () {
      final xml = sheetXml([
        XlsxSheet(
          name: 'Report',
          rows: [
            ['Room 461', 'B', 'C', 'D', 'E'],
          ],
          rowStyles: const {0: XlsxRowStyle.title},
          merges: const ['A1:E1'],
        ),
      ]);

      // A1 keeps its text...
      expect(xml, contains('Room 461'));
      // ...and B1..E1 are style-only cells with no value at all
      for (final ref in const ['B1', 'C1', 'D1', 'E1']) {
        expect(xml, contains('<c r="$ref" s="${XlsxRowStyle.title}"/>'),
            reason: '$ref must be emitted styled but valueless');
      }
      // None of the swallowed text survives anywhere in the sheet
      for (final swallowed in const ['>B<', '>C<', '>D<', '>E<']) {
        expect(xml, isNot(contains(swallowed)));
      }
    });

    test('drops malformed ranges instead of writing a bad merge', () {
      final xml = sheetXml([
        XlsxSheet(
          name: 'Report',
          rows: [
            ['x', 'y'],
          ],
          merges: const ['not-a-range', 'A1:B1'],
        ),
      ]);

      expect(xml, contains('<mergeCells count="1">'));
      expect(xml, contains('<mergeCell ref="A1:B1"/>'));
      expect(xml, isNot(contains('not-a-range')));
    });

    test('omits the block entirely when nothing is merged', () {
      final xml = sheetXml([
        XlsxSheet(name: 'Report', rows: [
          ['x', 'y'],
        ]),
      ]);
      expect(xml, isNot(contains('mergeCell')));
    });

    test('handles multi-letter columns', () {
      final xml = sheetXml([
        XlsxSheet(
          name: 'Report',
          rows: [List.filled(30, 'v')],
          merges: const ['Z1:AD1'],
        ),
      ]);
      // Z is index 25, AD is index 29 — AA1..AD1 get swallowed. Row 0 carries
      // the default header style, so the blanked cells keep their s= attribute.
      for (final ref in const ['AA1', 'AB1', 'AC1', 'AD1']) {
        expect(xml, contains('<c r="$ref" s="${XlsxRowStyle.header}"/>'),
            reason: '$ref must be blanked');
      }
      // Z1 is the anchor and keeps its value
      expect(xml, contains('<c r="Z1" s="${XlsxRowStyle.header}" t="inlineStr">'));
    });
  });
}
