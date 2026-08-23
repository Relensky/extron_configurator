import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/stepped_date_picker.dart';

/// Picking a date that is nowhere near today.
///
/// Every date this app records is months or years out, and the failure this
/// guards is the one the Material picker has: a shortcut that changes the year
/// and drops back onto the same month, leaving the month to be walked to one
/// arrow-press at a time. Year, then month, then day — three presses, from any
/// date to any other.
void main() {
  DateTime? picked;

  Future<void> open(
    WidgetTester tester, {
    DateTime? initial,
    DateTime? first,
    DateTime? last,
  }) async {
    picked = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showSteppedDatePicker(
                  context,
                  initialDate: initial ?? DateTime(2026, 8, 23),
                  firstDate: first ?? DateTime(2021),
                  lastDate: last ?? DateTime(2036, 12, 31),
                  helpText: 'Delivery deadline',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> stepUp(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('stepped_date_step_up')));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('it opens on the days of the month it was given',
      (tester) async {
    await open(tester);

    expect(find.byKey(const ValueKey('stepped_date_picker')), findsOneWidget);
    // A date inside the month already on screen stays one press away.
    expect(find.text('August 2026'), findsOneWidget);
    expect(find.byKey(const ValueKey('stepped_date_day_23')), findsOneWidget);
    expect(find.text('23 Aug 2026'), findsOneWidget);
  });

  testWidgets('the header goes up a level, days to months to years',
      (tester) async {
    await open(tester);

    await stepUp(tester);
    expect(find.text('2026'), findsOneWidget, reason: 'the months of 2026');
    expect(find.byKey(const ValueKey('stepped_date_month_3')), findsOneWidget);

    await stepUp(tester);
    expect(find.text('2021 - 2036'), findsOneWidget);
    expect(find.byKey(const ValueKey('stepped_date_year_2028')), findsOneWidget);

    // Nowhere further up to go — a range is not inside anything.
    final up = tester.widget<TextButton>(
      find.byKey(const ValueKey('stepped_date_step_up')),
    );
    expect(up.onPressed, isNull);
  });

  testWidgets('year, then month, then day settles a date three years out',
      (tester) async {
    await open(tester);

    await stepUp(tester);
    await stepUp(tester);
    await tapKey(tester, 'stepped_date_year_2029');
    // Picking a year narrows to its months rather than answering.
    expect(find.byKey(const ValueKey('stepped_date_month_3')), findsOneWidget);
    expect(picked, isNull);

    await tapKey(tester, 'stepped_date_month_3');
    expect(find.text('March 2029'), findsOneWidget);
    expect(picked, isNull, reason: 'a month is not a date either');

    await tapKey(tester, 'stepped_date_day_14');
    await tapKey(tester, 'stepped_date_confirm');
    expect(picked, DateTime(2029, 3, 14));
  });

  testWidgets('a short month cannot be landed on out of its own end',
      (tester) async {
    // 31 January, then February. DateTime's own arithmetic would roll this to
    // 3 March; the picker has to hold the month it was asked for.
    await open(tester, initial: DateTime(2026, 1, 31));
    await stepUp(tester);
    await tapKey(tester, 'stepped_date_month_2');

    expect(find.text('February 2026'), findsOneWidget);
    expect(find.text('28 Feb 2026'), findsOneWidget);
  });

  testWidgets('backing out answers nothing at all', (tester) async {
    await open(tester);
    await tapKey(tester, 'stepped_date_day_11');
    await tapKey(tester, 'stepped_date_cancel');

    // Cancel is not "clear" and it is not "keep what I clicked" — it is no
    // answer, which is what the caller relies on to leave a date alone.
    expect(picked, isNull);
  });

  group('the range is enforced at every level', () {
    testWidgets('a year outside it is never offered', (tester) async {
      await open(
        tester,
        initial: DateTime(2026, 8, 23),
        first: DateTime(2026),
        last: DateTime(2027, 12, 31),
      );
      await stepUp(tester);
      await stepUp(tester);

      expect(find.byKey(const ValueKey('stepped_date_year_2026')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('stepped_date_year_2025')), findsNothing);
      expect(find.byKey(const ValueKey('stepped_date_year_2028')), findsNothing);
    });

    testWidgets('a month with no selectable day in it is dead', (tester) async {
      await open(
        tester,
        initial: DateTime(2026, 8, 23),
        first: DateTime(2026, 6, 1),
        last: DateTime(2026, 9, 30),
      );
      await stepUp(tester);

      // May is entirely before the range; pressing it must do nothing rather
      // than open a grid where every day is refused. The months stay up.
      await tapKey(tester, 'stepped_date_month_5');
      expect(find.text('2026'), findsOneWidget);
      expect(find.byKey(const ValueKey('stepped_date_month_5')), findsOneWidget);

      await tapKey(tester, 'stepped_date_month_6');
      expect(find.text('June 2026'), findsOneWidget);
    });

    testWidgets('the month arrows stop at the ends', (tester) async {
      await open(
        tester,
        initial: DateTime(2026, 6, 15),
        first: DateTime(2026, 6, 1),
        last: DateTime(2026, 7, 31),
      );

      final back = tester.widget<IconButton>(
        find.byKey(const ValueKey('stepped_date_prev_month')),
      );
      expect(back.onPressed, isNull, reason: 'June is the first month');

      await tapKey(tester, 'stepped_date_next_month');
      expect(find.text('July 2026'), findsOneWidget);

      final forward = tester.widget<IconButton>(
        find.byKey(const ValueKey('stepped_date_next_month')),
      );
      expect(forward.onPressed, isNull, reason: 'July is the last month');
    });

    testWidgets('a day outside it cannot be pressed', (tester) async {
      await open(
        tester,
        initial: DateTime(2026, 6, 15),
        first: DateTime(2026, 6, 10),
        last: DateTime(2026, 6, 20),
      );

      await tapKey(tester, 'stepped_date_day_3');
      expect(find.text('15 Jun 2026'), findsOneWidget, reason: 'unchanged');

      await tapKey(tester, 'stepped_date_day_12');
      expect(find.text('12 Jun 2026'), findsOneWidget);
    });

    testWidgets('an initial date outside the range is pulled into it',
        (tester) async {
      await open(
        tester,
        initial: DateTime(2019, 4, 2),
        first: DateTime(2026),
        last: DateTime(2027, 12, 31),
      );
      // A caller holding a date from an older job must not be shown a picker
      // sitting on a date it would then refuse to confirm.
      expect(find.text('1 Jan 2026'), findsOneWidget);
    });
  });

  test('a month knows how long it is, leap year included', () {
    expect(daysInMonth(2026, 2), 28);
    expect(daysInMonth(2028, 2), 29);
    expect(daysInMonth(2026, 4), 30);
    expect(daysInMonth(2026, 12), 31);
  });
}
