import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/name_colors.dart';
import 'package:extron_configurator/responsibility_matrix.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// A COLOUR PER PARTY, ALL THE WAY OUT TO THE FILE.
///
/// The matrix is read by whose name is on the line. On screen every party
/// carries its own colour; the copy that goes to the contractor was black on
/// white, which sent the reader back to reading every cell. These check that
/// the colours survive the export - and that they are the SAME colours, since
/// a spreadsheet that picked its own would disagree with the screen it was
/// exported from.
void main() {
  String partOf(List<int> bytes, String name) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final file = archive.files.firstWhere((f) => f.name == name);
    return utf8.decode(file.content as List<int>);
  }

  group('a tinted cell', () {
    test('writes one fill, one font and one style per distinct colour', () {
      final bytes = buildXlsx([
        XlsxSheet(
          name: 'Responsibility',
          rows: [
            const ['Scope', 'Furnished by'],
            [
              'Screens',
              const XlsxTint(
                text: 'Owner',
                fillHex: 'D2E7FA',
                inkHex: '0D47A1',
              ),
            ],
            // The same party again: one style, not two.
            [
              'Speakers',
              const XlsxTint(
                text: 'Owner',
                fillHex: 'D2E7FA',
                inkHex: '0D47A1',
              ),
            ],
            [
              'Cameras',
              const XlsxTint(
                text: 'Contractor',
                fillHex: 'FBE3D0',
                inkHex: 'A64100',
              ),
            ],
          ],
        ),
      ]);
      final styles = partOf(bytes, 'xl/styles.xml');

      expect(styles, contains('<fgColor rgb="FFD2E7FA"/>'));
      expect(styles, contains('<fgColor rgb="FFFBE3D0"/>'));
      expect(styles, contains('<color rgb="FF0D47A1"/>'));
      expect(styles, contains('<color rgb="FFA64100"/>'));
      // Two parties, two fills on top of the five the writer always has.
      expect(styles, contains('<fills count="7">'));
      expect(styles, contains('<fonts count="5">'));
    });

    test('the cell still says the name, so a mono print still reads', () {
      final bytes = buildXlsx([
        XlsxSheet(
          name: 'Responsibility',
          rows: [
            const ['Scope', 'Furnished by'],
            [
              'Screens',
              const XlsxTint(
                text: 'CTS Chico',
                fillHex: 'D2E7FA',
                inkHex: '0D47A1',
              ),
            ],
          ],
        ),
      ]);
      expect(
        partOf(bytes, 'xl/worksheets/sheet1.xml'),
        contains('<t xml:space="preserve">CTS Chico</t>'),
      );
    });

    test('a book with no tint on it keeps the styles it always had', () {
      final styles = partOf(
        buildXlsx([
          XlsxSheet(name: 'Report', rows: [
            const ['Setting', 'Value'],
          ]),
        ]),
        'xl/styles.xml',
      );
      expect(styles, contains('<fills count="5">'));
      expect(styles, contains('<fonts count="3">'));
    });
  });

  group('the responsibility sheet', () {
    BuildingProject job() {
      final project = BuildingProject(name: 'Bessey refresh', building: 'BSS');
      project.rooms.add(
        ProjectRoomRef(
          id: project.nextRoomId(),
          configPath: 'C:/rooms/BSS_101_config.json',
          label: 'BSS 101',
        ),
      );
      return project;
    }

    ReportSection gridOf(BuildingProject project) =>
        responsibilityMatrixSections(
          project.responsibility,
          roomNames: project.responsibilityRoomColumns(),
        ).firstWhere((s) => s.title == 'Roles and Responsibilities');

    test('every party carries the colour it reads in on screen', () {
      final project = job();
      project.addResponsibilityItem(
        'Screens',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
      );

      final row = gridOf(project).rows.first;
      final furnished = row[1] as XlsxTint;
      final installed = row[2] as XlsxTint;

      // The SAME source the screen and the picture use. A second answer to
      // "what colour is the contractor" is a document that disagrees with the
      // app it came out of.
      expect(furnished.fillHex, nameSheetTint('Owner').fill);
      expect(furnished.inkHex, nameSheetTint('Owner').ink);
      expect(installed.fillHex, nameSheetTint('Contractor').fill);
      // ...and two different parties are two different colours.
      expect(furnished.fillHex, isNot(installed.fillHex));
    });

    test('the same party is the same colour on every line', () {
      final project = job();
      project.addResponsibilityItem('Screens', furnishedBy: 'CTS Chico');
      project.addResponsibilityItem('Speakers', furnishedBy: 'cts  chico');

      final rows = gridOf(project).rows;
      // Case and spacing are not two parties - see [normalisedName].
      expect(
        (rows[0][1] as XlsxTint).fillHex,
        (rows[1][1] as XlsxTint).fillHex,
      );
    });

    test('a party nobody has named is red, not one more quiet grey', () {
      final project = job();
      project.addResponsibilityItem('Screens', furnishedBy: 'Owner');

      final row = gridOf(project).rows.first;
      final installed = row[2] as XlsxTint;

      // 'N/A' on the install column is a real answer - a desk monitor is hung
      // by nobody - and a blank is not. In the same grey, the one that needs
      // chasing hides among the ones that do not.
      expect(installed.text, 'NOBODY');
      expect(installed.fillHex, kResponsibilityMissingFill);
      expect(installed.inkHex, kResponsibilityMissingInk);
      expect(
        installed.fillHex,
        isNot(responsibilityPartyCell('N/A').fillHex),
      );
    });

    test('the totals row is not a party and carries no colour', () {
      final project = job();
      project.addResponsibilityItem(
        'Screens',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
      );
      final rows = gridOf(project).rows;
      expect(rows.last.first, 'Totals');
      expect(rows.last[1], isNot(isA<XlsxTint>()));
    });
  });
}
