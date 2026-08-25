import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/name_colors.dart';

/// One name, one colour — everywhere, and again tomorrow.
///
/// The failure this guards is a sheet that recolours itself: the responsibility
/// matrix and the equipment list are both read by whose name is on the line, so
/// a colour that moved when a row was sorted, a line was deleted or the app was
/// restarted would be worse than no colour at all.
void main() {
  group('a name always reads in the same colour', () {
    test('case and spacing are not two vendors', () {
      expect(tintForName('CTS Chico'), tintForName('cts  chico'));
      expect(tintForName(' Extron '), tintForName('extron'));
    });

    test('the colour comes off the name, not off the order', () {
      // The same list, shuffled: every name keeps what it had.
      const names = ['Extron', 'Shure', 'Sony', 'Biamp', 'Crestron'];
      final first = {for (final n in names) n: tintForName(n)};
      for (final n in names.reversed) {
        expect(tintForName(n), first[n]);
      }
    });

    test('the hash is pinned, so a colour does not drift with a refactor', () {
      // Locked deliberately. Changing these means every matrix and every quote
      // in the field recolours, which is a decision rather than a side effect.
      expect(tintForName('Extron'), kNameTintWheel[11]);
      expect(tintForName('Shure'), kNameTintWheel[8]);
    });

    test('the parties everybody names are anchored', () {
      expect(tintForName('Owner'), kAnchoredNameTints['owner']);
      expect(tintForName('CONTRACTOR'), kAnchoredNameTints['contractor']);
      expect(tintForName('Integrator'), kAnchoredNameTints['integrator']);
      expect(tintForName('Vendor'), kAnchoredNameTints['vendor']);
      // And they are four different colours, which is the point of them.
      expect(
        {
          for (final p in ['Owner', 'Contractor', 'Integrator', 'Vendor'])
            tintForName(p),
        },
        hasLength(4),
      );
    });

    test('nobody yet is grey, and says so', () {
      for (final unsettled in ['', '  ', 'TBD', 'n/a', 'None']) {
        expect(tintForName(unsettled), kNameTintUnsettled, reason: unsettled);
        expect(nameIsUnsettled(unsettled), isTrue, reason: unsettled);
      }
      expect(nameIsUnsettled('Owner'), isFalse);
    });

    test('a real party is never painted in the unsettled grey', () {
      for (final party in ['Owner', 'Contractor', 'CTS Chico', 'Valley/DPR']) {
        expect(tintForName(party), isNot(kNameTintUnsettled), reason: party);
      }
    });
  });

  group('the colour is readable, and never the only signal', () {
    testWidgets('a chip carries the name as well as the colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: NameTintChip(name: 'CTS Chico')),
        ),
      );
      expect(find.text('CTS Chico'), findsOneWidget);
    });

    testWidgets('a blank name says what it is rather than showing nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: NameTintChip(name: '', emptyLabel: 'NOBODY')),
        ),
      );
      expect(find.text('NOBODY'), findsOneWidget);
    });

    testWidgets('the key names each party once, whatever the sheet does', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NameTintKey(
              names: ['Owner', 'Contractor', 'owner', '', 'Owner'],
            ),
          ),
        ),
      );
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Contractor'), findsOneWidget);
    });
  });
}
