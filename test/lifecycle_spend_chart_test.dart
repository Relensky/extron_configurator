import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/hover_chart.dart';
import 'package:extron_configurator/lifecycle_spend_chart.dart';
import 'package:extron_configurator/project_view.dart';

/// ============================================================================
///  THE PLAN AS A LINE, AND WHAT IT WOULD COST TO FLATTEN IT
/// ============================================================================
///  The year grid is the document and stays the document. What it cannot do is
///  show a SHAPE - forty rows of cells have to be read across before the one
///  bad year in them is visible - and it cannot answer the question the shape
///  provokes, which is "what is IN that year".
///
///  Held here: that the chart is the same arithmetic as the grid, that it
///  refuses to draw a line out of nothing, and that the level spend - the
///  figure the whole "we cannot do it all at once" conversation turns on - is
///  worked out over the years still in front of the reader rather than over
///  the ones already gone.
/// ============================================================================
void main() {
  SpendYear year(int y, double amount, [List<String> names = const []]) => (
    year: y,
    amount: amount,
    parts: [
      for (final n in names) (name: n, amount: amount / names.length),
    ],
  );

  group('the level spend', () {
    test('spreads the plan evenly over the years still ahead', () {
      // 2026 to 2030 is five years, and 50,000 falling due in them levels to
      // 10,000 a year.
      final plan = [
        year(2026, 10000),
        year(2027, 0),
        year(2028, 40000),
        year(2029, 0),
        year(2030, 0),
      ];
      expect(LifecycleSpendChart.levelSpendFor(plan, 2026), 10000);
    });

    test('ignores the years already gone', () {
      // MONEY THAT FELL DUE IN 2019 CANNOT BE BUDGETED FOR. Counting it, and
      // counting the years it sat in, produces a comfortable figure nobody
      // can actually spend to.
      final plan = [
        year(2019, 999999),
        year(2026, 10000),
        year(2027, 10000),
      ];
      expect(LifecycleSpendChart.levelSpendFor(plan, 2026), 10000);
    });

    test('is nothing at all when there is no future left to spread over', () {
      expect(
        LifecycleSpendChart.levelSpendFor([year(2026, 5000)], 2026),
        isNull,
      );
      expect(
        LifecycleSpendChart.levelSpendFor(
          [year(2026, 0), year(2027, 0)],
          2026,
        ),
        isNull,
      );
    });
  });

  group('the chart', () {
    Future<void> pump(WidgetTester tester, List<SpendYear> plan) async {
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LifecycleSpendChart(
              years: plan,
              currency: r'$',
              asOfYear: 2026,
              levelAmount: LifecycleSpendChart.levelSpendFor(plan, 2026),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('draws the years and says what a level one would cost', (
      tester,
    ) async {
      await pump(tester, [
        year(2026, 10000, ['BSS 101']),
        year(2027, 0),
        year(2028, 40000, ['SCI 200', 'SCI 201']),
        year(2029, 0),
        year(2030, 0),
      ]);
      expect(find.byType(HoverLineChart), findsOneWidget);
      expect(find.text('WHAT FALLS DUE, YEAR BY YEAR'), findsOneWidget);
      // The figure the deferral argument turns on, said out loud rather than
      // left as a dashed line nobody can price.
      expect(
        find.textContaining('spread evenly'),
        findsOneWidget,
      );
    });

    testWidgets('the readout on a year names what is in it', (tester) async {
      // THE WHOLE REASON THE CHART IS HERE. The shape provokes "what is that
      // spike", and the answer has to be on the point rather than back in the
      // grid. fl_chart paints the readout on canvas, so it is checked by
      // asking the chart for the same text it would draw.
      await pump(tester, [
        year(2026, 10000, ['BSS 101']),
        year(2027, 0),
        year(2028, 40000, ['SCI 200', 'SCI 201']),
        year(2029, 0),
        year(2030, 0),
      ]);

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      final bar = chart.data.lineBarsData.single;
      final spike = bar.spots.firstWhere((s) => s.x == 2028);
      final item = chart.data.lineTouchData.touchTooltipData
          .getTooltipItems([LineBarSpot(bar, 0, spike)])
          .single!;
      final readout = [
        item.text,
        for (final span in item.children ?? const <TextSpan>[])
          span.text ?? '',
      ].join();

      expect(readout, contains('2028'));
      expect(readout, contains(r'$40,000'));
      // The rooms, named. A count cannot answer 'which rooms'.
      expect(readout, contains('SCI 200'));
      expect(readout, contains('SCI 201'));
      // And what it has come to by then, which is the second question every
      // time and used to mean adding six columns of a grid in your head.
      expect(readout, contains(r'$50,000'));
    });

    testWidgets('a plan with nothing priced in it is not a chart', (
      tester,
    ) async {
      await pump(tester, [year(2026, 0), year(2027, 0), year(2028, 0)]);
      expect(find.byType(HoverLineChart), findsNothing);
    });

    testWidgets('one year is not a chart either', (tester) async {
      await pump(tester, [year(2026, 10000)]);
      expect(find.byType(HoverLineChart), findsNothing);
    });
  });

  group('on the building plan', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_spend_chart_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('the plan pane carries it under the grid', (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      // Two line items falling due in different years, so the plan has a
      // shape rather than a single spike.
      p.project.addManualRoom(
        name: 'BSS 101',
        installedOn: DateTime(DateTime.now().year - 6, 7),
        lifeYears: 8,
        replacementCost: 24000,
      );
      p.project.addManualRoom(
        name: 'BSS 102',
        installedOn: DateTime(DateTime.now().year - 2, 7),
        lifeYears: 8,
        replacementCost: 18000,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.history_toggle_off));
      await tester.pumpAndSettle();

      // Below the grid, so it has to be scrolled to - the grid is the point
      // of the pane and keeps the first screen. The grid scrolls in a frame of
      // its own, so the pane's own scroll view is named rather than guessed.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('lifecycle_spend_chart')),
        320,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('lifecycle_spend_chart')),
        findsOneWidget,
      );
    });
  });
}
