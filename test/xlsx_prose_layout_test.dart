import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/online_roundtrip.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// What an exported sheet looks like when a column holds a SENTENCE.
///
/// The failure this guards is the commonest complaint about these workbooks:
/// one column of prose sets its own width, every short value on the sheet ends
/// up marooned at the left-hand edge of a column three feet wide, and the
/// figures the sheet is opened for are off the right of the screen. The
/// sentence still has to be there and still has to be readable - it is what
/// the document says - so it is lifted onto a row of its own instead.
void main() {
  String sheetXml(List<XlsxSheet> sheets) {
    final archive = ZipDecoder().decodeBytes(buildXlsx(sheets));
    final file = archive.files.firstWhere(
      (f) => f.name == 'xl/worksheets/sheet1.xml',
    );
    return utf8.decode(file.content as List<int>);
  }

  const work =
      'Install the motorized screen and run control cable back to the '
      'control processor, leaving slack for seismic bracing at each end.';

  ReportSection matrix() => (
    title: 'Roles and Responsibilities',
    header: const ['Scope', 'Furnished by', 'Qty', 'What the work is'],
    rows: <List<dynamic>>[
      ['Projection screen', 'Owner', 2, work],
      ['Ceiling speakers', 'Contractor', 14, 'Install in the ceiling grid.'],
    ],
  );

  XlsxSheet sheetOf(List<ReportSection> sections) => buildStackedReportSheet(
    sheetName: 'Responsibility',
    title: 'Bessey Hall',
    sections: sections,
    generated: DateTime(2026, 1, 2, 3, 4),
  );

  group('a column of prose', () {
    test('is lifted off the grid, under the row it belongs to', () {
      final rows = sheetOf([matrix()]).rows;
      // The header keeps the three fields and loses the sentence.
      final header = rows.firstWhere((r) => r.isNotEmpty && r[0] == 'Scope');
      expect(header.take(3), ['Scope', 'Furnished by', 'Qty']);
      expect(header, isNot(contains('What the work is')));

      // The sentence is on the line under its own row, and says which column
      // it came out of - a merged line of prose under a table is a line of
      // prose from nowhere.
      final at = rows.indexWhere((r) => r.isNotEmpty && r[0] == 'Projection screen');
      expect(rows[at].take(3), ['Projection screen', 'Owner', 2]);
      expect(rows[at + 1][0], 'What the work is:  $work');
    });

    test('is written across the sheet rather than down one column', () {
      final sheet = sheetOf([matrix()]);
      final at = sheet.rows.indexWhere(
        (r) => r.isNotEmpty && r[0].toString().startsWith('What the work is:'),
      );
      expect(sheet.merges, contains('A${at + 1}:D${at + 1}'));
    });

    // The whole point: the columns left behind are the width of what is in
    // them. 'Projection screen' is 17 characters, so its column is 20 - not
    // the 130-odd the sentence would have made it.
    test('leaves the short columns short', () {
      final xml = sheetXml([sheetOf([matrix()])]);
      expect(xml, contains('<col min="1" max="1" width="20.0"'));
      // ...and no column on the sheet is anywhere near the sentence's length.
      for (final m
          in RegExp(r'width="([0-9.]+)"').allMatches(xml)) {
        expect(double.parse(m.group(1)!), lessThan(40));
      }
    });

    test('and the lifted row is tall enough to show every line of it', () {
      final xml = sheetXml([sheetOf([matrix()])]);
      final sheet = sheetOf([matrix()]);
      final at = sheet.rows.indexWhere(
        (r) => r.isNotEmpty && r[0].toString().startsWith('What the work is:'),
      );
      // Wrapped, and given the height its wrapped lines need: Excel does not
      // auto-fit a file it did not write, so without both the sentence is one
      // clipped line.
      expect(xml, contains('<row r="${at + 1}" ht='));
    });

    test('a short column is left exactly where it was', () {
      final rows = sheetOf([
        (
          title: 'Runs',
          header: const ['Run', 'Cable', 'Length'],
          rows: <List<dynamic>>[
            ['SCRSW_1', 'Cat 6a', 40],
          ],
        ),
      ]).rows;
      expect(rows.firstWhere((r) => r.isNotEmpty && r[0] == 'SCRSW_1'), [
        'SCRSW_1',
        'Cat 6a',
        40,
      ]);
      // Nothing lifted means nothing merged but the captions: the sheet's
      // title, its stamp, and the section's own name over its band.
      expect(sheetOf([
        (
          title: 'Runs',
          header: const ['Run', 'Cable', 'Length'],
          rows: <List<dynamic>>[
            ['SCRSW_1', 'Cat 6a', 40],
          ],
        ),
      ]).merges, ['A1:E1', 'A2:E2', 'A4:C4']);
    });

    // A row is named by its first column. Lifting that one out would leave a
    // table of anonymous rows with a stack of sentences under it.
    test('never takes the column that names the row', () {
      final rows = sheetOf([
        (
          title: 'Notes',
          header: const ['What was said', 'By'],
          rows: <List<dynamic>>[
            [work, 'Owner'],
          ],
        ),
      ]).rows;
      expect(rows.any((r) => r.isNotEmpty && r[0] == work), isTrue);
    });
  });

  group('a page of instructions', () {
    // The editable sheets open with a title and a paragraph telling somebody
    // what to type over. Left as values in column A they sized it, so the
    // first thing anybody saw was a column of six-character row ids in a field
    // wide enough for a paragraph.
    test('does not set the width of the column it starts in', () {
      final xml = sheetXml([
        buildEditableDeliveriesSheet(
          BuildingProject(name: 'Bessey Hall'),
          roomNames: const {},
        ),
      ]);
      expect(xml, contains('<col min="1" max="1" width="9.0"'));
      expect(xml, contains('<mergeCell ref="A2:J2"/>'));
    });
  });

  group('a column of fields', () {
    test('is as wide as the longest thing in it, not clipped at 55', () {
      // A part description of 70 characters used to come out cut off, which is
      // a workbook the reader has to widen before they can read it.
      const long =
          'Extron DTP3 T 231 transmitter for HDMI, 4K/60, with audio de-embed';
      final xml = sheetXml([
        sheetOf([
          (
            title: 'Parts',
            header: const ['Part', 'Qty'],
            rows: <List<dynamic>>[
              [long, 2],
            ],
          ),
        ]),
      ]);
      expect(xml, contains('width="${long.length + 3}.0"'));
    });
  });
}
