import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/report_tools.dart';

/// The location report is a sheet per drawing — every plan in the room, every
/// cable layer on each — so the sheet names are generated rather than written
/// by hand. Excel will not open a book whose sheet names it refuses or that
/// holds the same name twice, so getting this wrong does not produce a slightly
/// wrong workbook: it produces one nobody can open at all.
void main() {
  group('a sheet name Excel will take', () {
    test('drops the punctuation Excel refuses', () {
      expect(xlsxSheetName('Fiber [OS2]/OM4'), 'Fiber  OS2  OM4');
      expect(xlsxSheetName('Level 1: ceiling'), 'Level 1  ceiling');
    });

    test('stops at 31 characters', () {
      final long = xlsxSheetName('Reflected ceiling plan - north wing runs');
      expect(long.length, 31);
    });
  });

  group('two drawings that would share a name', () {
    test('the second one is numbered', () {
      final taken = <String>{};
      expect(uniqueXlsxSheetName('All runs', taken), 'All runs');
      expect(uniqueXlsxSheetName('All runs', taken), 'All runs (2)');
      expect(uniqueXlsxSheetName('All runs', taken), 'All runs (3)');
    });

    test('case does not make two sheets - Excel says it does not', () {
      final taken = <String>{};
      expect(uniqueXlsxSheetName('Level 1', taken), 'Level 1');
      expect(uniqueXlsxSheetName('level 1', taken), 'level 1 (2)');
    });

    test('the number fits inside the 31 characters rather than past them', () {
      final taken = <String>{};
      const name = 'Reflected ceiling plan - all runs';
      final first = uniqueXlsxSheetName(name, taken);
      final second = uniqueXlsxSheetName(name, taken);
      expect(first.length, 31);
      expect(second.length, lessThanOrEqualTo(31));
      expect(second, endsWith(' (2)'));
      expect(second, isNot(first));
    });

    test('a name the tables already used cannot be claimed by a drawing', () {
      // The report's own sheet is called Locations before any drawing is
      // added, so a plan named the same thing has to give way.
      final taken = <String>{'locations'};
      expect(uniqueXlsxSheetName('Locations', taken), 'Locations (2)');
    });

    test('a name that is nothing but punctuation still gets one', () {
      final taken = <String>{};
      expect(uniqueXlsxSheetName('///', taken), 'Sheet');
    });
  });
}
