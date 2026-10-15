import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/live_text_field.dart';
import 'package:extron_configurator/print_mode.dart';

/// Prices in a cost-page image or PDF read as money, and a line added under a
/// sort lands in its sorted spot rather than at the bottom.
void main() {
  group('a money box, photographed', () {
    Future<void> pump(
      WidgetTester tester, {
      String initial = '',
      String? hint,
      bool money = true,
    }) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: PrintMode(
              printing: true,
              child: LiveTextField(
                fieldId: 'price',
                initial: initial,
                hint: hint,
                hintIsValue: true,
                prefix: r'$',
                numeric: true,
                money: money,
                onChanged: (_) {},
              ),
            ),
          ),
        ));

    testWidgets('a typed price gets commas, cents and the sign',
        (tester) async {
      await pump(tester, initial: '11948');
      expect(find.text(r'$11,948.00'), findsOneWidget);
    });

    testWidgets('the catalog price behind a blank box does too',
        (tester) async {
      await pump(tester, hint: '1234567.5');
      expect(find.text(r'$1,234,567.50'), findsOneWidget);
    });

    testWidgets('a word prints as the word', (tester) async {
      await pump(tester, hint: 'unpriced');
      expect(find.text('unpriced'), findsOneWidget);
    });

    testWidgets('a box that is not money prints as typed', (tester) async {
      await pump(tester, initial: '11948', money: false);
      expect(find.text(r'$11948'), findsOneWidget);
    });
  });

  group('steadyOrder', () {
    test('a new line goes ahead of the row that follows it', () {
      // Sorted by maker: Crestron, Extron A, Extron C, Shure. "Extron B" is
      // added and belongs between the two Extron rows.
      expect(
        steadyOrder(
          ['crestron', 'extronA', 'extronC', 'shure'],
          ['crestron', 'extronA', 'extronB', 'extronC', 'shure'],
        ),
        ['crestron', 'extronA', 'extronB', 'extronC', 'shure'],
      );
    });

    test('last in the sort goes at the end', () {
      expect(steadyOrder(['a', 'b'], ['a', 'b', 'z']), ['a', 'b', 'z']);
    });

    test('rows already on screen keep their places', () {
      // "b" was renamed and now sorts last; it stays put. The new "c" lands
      // ahead of "d", the row that follows it in the estimate.
      expect(
        steadyOrder(['a', 'b', 'd'], ['a', 'c', 'd', 'b']),
        ['a', 'b', 'c', 'd'],
      );
    });

    test('a removed line drops out', () {
      expect(steadyOrder(['a', 'b', 'c'], ['a', 'c']), ['a', 'c']);
    });
  });
}
