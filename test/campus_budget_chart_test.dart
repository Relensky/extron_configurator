import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_file.dart';
import 'package:extron_configurator/campus_lifecycle_view.dart';
import 'package:extron_configurator/hover_chart.dart';
import 'package:extron_configurator/lifecycle_spend_chart.dart';

/// ============================================================================
///  THE BUDGET LINE, AND WHAT IT WOULD COST TO STOP HAVING PEAKS
/// ============================================================================
///  The campus calendar is the document a budget meeting is sent. What the
///  meeting actually argues about is the shape of it - which year is the bad
///  one, and what the estate would cost a year if that year were pushed off
///  and the whole plan spread evenly instead.
///
///  Both figures were derivable from the grid and neither was drawn. Held
///  here: that the chart is on the campus screen above the calendar, and that
///  the level figure it prints is the plan divided by the years still ahead.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_campus_budget_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A building with money on the plan and no config files to read, so the
  /// sheet can be assembled without any room I/O.
  String job(String stem, {required int lifeYears, required double cost}) {
    final project = BuildingProject(name: stem, building: stem);
    project.addManualRoom(
      name: '$stem 101',
      installedOn: DateTime(2018, 7),
      lifeYears: lifeYears,
      replacementCost: cost,
    );
    final file = path.join(dir.path, '${stem}_project.json');
    File(file).writeAsStringSync(jsonEncode(project.toJson()));
    return file;
  }

  /// Pumps frames on the real clock until [done], or until it gives up. The
  /// campus read is real file I/O and does not happen on a fake clock.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
  }

  bool shown(Finder f) => f.evaluate().isNotEmpty;

  Future<void> pumpCampus(WidgetTester tester, List<String> jobs) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = AppStateProvider(autoLoadSettings: false);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCampusLifecycleFile(
                context,
                CampusFile(name: 'Chico', projects: jobs),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await until(
      tester,
      () => shown(find.byKey(const ValueKey('campus_budget_chart'))),
    );
  }

  testWidgets('the estate carries its budget as a line, above the calendar', (
    tester,
  ) async {
    // Two buildings falling due in different years, so the plan has peaks to
    // argue about rather than one spike.
    await pumpCampus(tester, [
      job('SCI', lifeYears: 8, cost: 24000),
      job('BSS', lifeYears: 12, cost: 60000),
    ]);

    expect(
      find.byKey(const ValueKey('campus_budget_chart')),
      findsOneWidget,
    );
    expect(find.byType(HoverLineChart), findsOneWidget);
    expect(find.text('THE BUDGET, YEAR BY YEAR'), findsOneWidget);
    // The deferral figure is said in words, not left as a dashed line nobody
    // can price.
    expect(find.textContaining('spread evenly'), findsOneWidget);
  });

  testWidgets('the level figure is the plan over the years still ahead', (
    tester,
  ) async {
    // Same arithmetic the chart prints, checked here rather than by reading a
    // label off a canvas: 2026 to 2030 is five years, and 50,000 in them is
    // 10,000 a year.
    final plan = <SpendYear>[
      (year: 2024, amount: 99000, parts: const []),
      (year: 2026, amount: 10000, parts: const []),
      (year: 2028, amount: 40000, parts: const []),
      (year: 2030, amount: 0, parts: const []),
    ];
    expect(LifecycleSpendChart.levelSpendFor(plan, 2026), 10000);
  });
}
