import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/search_match.dart';

/// Every search box in the app runs through this. AV naming is inconsistent —
/// "BSS103" or "BSS 103", "PT-FW430U" or "PT FW430U" — so a search must not
/// depend on the user reproducing the separators.
void main() {
  group('searchKey', () {
    test('reduces to lowercase letters and digits', () {
      expect(searchKey('BSS 103'), 'bss103');
      expect(searchKey('BSS103'), 'bss103');
      expect(searchKey('bss-103'), 'bss103');
      expect(searchKey('PT-FW430U'), 'ptfw430u');
      expect(searchKey('PT FW430U'), 'ptfw430u');
      expect(searchKey('extr_scaler_IN1606'), 'extrscalerin1606');
      expect(searchKey('10.248.129.8'), '102481298');
      expect(searchKey(''), '');
    });
  });

  group('searchMatches', () {
    test('the spacing of the room number does not matter', () {
      // The processor line the picker actually shows
      const line = 'BSS 103 — Behavioral And Social Science (10.248.103.8)';
      for (final query in const [
        'BSS103',
        'BSS 103',
        'bss103',
        'bss 103',
        'BSS-103',
        ' bss  103 ',
      ]) {
        expect(searchMatches(line, query), isTrue, reason: 'query "$query"');
      }
    });

    test('matches the full building name and the IP too', () {
      const line = 'AGYM 129 — Acker Gymnasium (10.248.129.8)';
      expect(searchMatches(line, 'acker gym'), isTrue);
      expect(searchMatches(line, 'ackergym'), isTrue);
      expect(searchMatches(line, '10.248.129'), isTrue);
      expect(searchMatches(line, '10248129'), isTrue);
    });

    test('still excludes what genuinely does not match', () {
      const line = 'BSS 103 — Behavioral And Social Science (10.248.103.8)';
      expect(searchMatches(line, 'AJH'), isFalse);
      expect(searchMatches(line, 'BSS104'), isFalse);
      // Order still matters — this is a contains, not a fuzzy match
      expect(searchMatches(line, '103BSS'), isFalse);
    });

    test('a model or module is found however it is punctuated', () {
      expect(searchMatches('PT-FW430U', 'ptfw430'), isTrue);
      expect(searchMatches('DTP CrossPoint 108 4K', 'dtpcrosspoint108'), isTrue);
      expect(searchMatches('extr_scaler_IN1606_IN1608_Series', 'scaler in1606'),
          isTrue);
      expect(searchMatches('IN1608 SA', 'in1608sa'), isTrue);
    });

    test('an all-punctuation query matches everything, like an empty one', () {
      expect(searchMatches('anything', '---'), isTrue);
      expect(searchMatches('anything', ''), isTrue);
    });
  });

  group('searchFilter', () {
    test('keeps the original order', () {
      const rooms = ['BSS 103', 'AJH 125B', 'BSS 104', 'BSS 1030'];
      expect(searchFilter(rooms, 'bss10').toList(),
          ['BSS 103', 'BSS 104', 'BSS 1030']);
      expect(searchFilter(rooms, 'ajh125b').toList(), ['AJH 125B']);
      expect(searchFilter(rooms, 'zzz').toList(), isEmpty);
    });
  });
}
