import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_lifecycle.dart';
import 'package:extron_configurator/campus_lifecycle_view.dart';
import 'package:extron_configurator/project_view.dart';

/// ============================================================================
///  FROM A FIGURE ON THE CAMPUS TO THE PLAN BEHIND IT
/// ============================================================================
///  A cell on the campus calendar says "SCI owes 84,000 in 2031". Everything a
///  reader wants next is one level down - which rooms make that up, what is
///  already overdue, what the year either side looks like - and every route
///  into a project landed on the Rooms pane, which is a list of config files.
///
///  What is held here: that a building's figure is a way into that building's
///  replacement plan, that the campus TOTAL row is not (it is not any one
///  building), that a single click does nothing, and that the Project tab
///  actually lands on the pane it was asked for - including the second time.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_campus_cell'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A building whose rooms are all line items, so it has money on the plan
  /// and no config files to read.
  String job(String stem, {required int dueIn}) {
    final project = BuildingProject(name: stem, building: stem);
    project.addManualRoom(
      name: '$stem 101',
      installedOn: DateTime(2026 + dueIn - 8, 7),
      lifeYears: 8,
      replacementCost: 24000,
    );
    final file = path.join(dir.path, '${stem}_project.json');
    File(file).writeAsStringSync(jsonEncode(project.toJson()));
    return file;
  }

  /// Reads an estate off disk and puts its calendar on screen, returning the
  /// key of every figure that is a way into a building.
  ///
  /// The read is REAL FILE I/O and only happens on the real clock, so it is
  /// done inside [WidgetTester.runAsync] and finished BEFORE a frame is pumped.
  /// That is also why the grid takes a [CampusLifecycle] rather than a list of
  /// paths - see [CampusYearGrid].
  Future<List<String>> pumpGrid(
    WidgetTester tester,
    List<String> jobs, {
    ValueChanged<String>? onOpenJob,
  }) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = AppStateProvider(autoLoadSettings: false);
    late final CampusLifecycle campus;
    await tester.runAsync(() async {
      campus = await readCampus(
        provider: provider,
        projectPaths: jobs,
        asOf: DateTime(2026, 6, 15),
      );
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CampusYearGrid(campus: campus, onOpenJob: onOpenJob),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    return [
      for (final g in tester.widgetList<GestureDetector>(
        find.byWidgetPredicate(
          (w) => w is GestureDetector && w.onDoubleTap != null,
        ),
      ))
        (g.key as ValueKey<String>).value,
    ];
  }

  testWidgets('every building figure is a way into that building', (
    tester,
  ) async {
    final keys = await pumpGrid(tester, [
      job('SCI', dueIn: 2),
      job('BSS', dueIn: 5),
    ], onOpenJob: (_) {});

    expect(keys.where((k) => k.startsWith('campus_cell_SCI_')), isNotEmpty);
    expect(keys.where((k) => k.startsWith('campus_cell_BSS_')), isNotEmpty);
    // The CAMPUS row is the estate, not a building, so there is nothing for it
    // to open onto - and a figure that looked clickable and did nothing would
    // be worse than one that never offered.
    expect(keys.where((k) => k.startsWith('campus_cell__')), isEmpty);
  });

  testWidgets('the figure opens the building it is about', (tester) async {
    final sci = job('SCI', dueIn: 2);
    var opened = '';
    final keys = await pumpGrid(
      tester,
      [sci, job('BSS', dueIn: 5)],
      onOpenJob: (p) => opened = p,
    );

    final cell = find.byKey(
      ValueKey(keys.firstWhere((k) => k.startsWith('campus_cell_SCI_'))),
    );
    // Called rather than double-tapped: what is under test is WHICH building a
    // figure names, and racing the double-tap timer proves nothing about that.
    tester.widget<GestureDetector>(cell).onDoubleTap!();
    expect(opened, sci);
  });

  testWidgets('a single click leaves the campus alone', (tester) async {
    var opened = '';
    final keys = await pumpGrid(
      tester,
      [job('SCI', dueIn: 2)],
      onOpenJob: (p) => opened = p,
    );

    // Opening closes the campus and swaps the open job. That is far too big a
    // move for a stray click on a grid somebody is reading across, which is
    // why it is on the double and nothing is on the single.
    final cell = find.byKey(ValueKey(keys.first));
    expect(tester.widget<GestureDetector>(cell).onTap, isNull);
    await tester.tap(cell);
    // Past the double-tap window, so the recognizer gives up rather than
    // leaving its timer running past the end of the test.
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened, isEmpty);
  });

  testWidgets('nothing is offered when there is nowhere to go', (tester) async {
    // The flat sheet a picture is made from draws the same figures with no
    // callback, and must not dress them up as doors.
    final keys = await pumpGrid(tester, [job('SCI', dueIn: 2)]);
    expect(keys, isEmpty);
  });

  group('the pane the Project tab lands on', () {
    Future<AppStateProvider> pumpTab(WidgetTester tester) async {
      // Built in memory rather than opened off disk: opening also goes looking
      // for recovery copies, and this is about the pane the tab lands on.
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.newProject(name: 'SCI', building: 'SCI');
      provider.addProjectManualRoom(
        name: 'SCI 101',
        installedOn: DateTime(2020, 7),
        lifeYears: 8,
        replacementCost: 24000,
      );

      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      return provider;
    }

    testWidgets('is the one it was asked for, twice over', (tester) async {
      final provider = await pumpTab(tester);
      // Opens where it always did.
      expect(find.textContaining('Rooms are references'), findsOneWidget);

      provider.requestProjectPane('lifecycle');
      await tester.pumpAndSettle();
      expect(find.textContaining('Rooms are references'), findsNothing);

      // ASKING TWICE STILL WORKS. The reader is free to move off the pane, and
      // a request honored once must not then be ignored forever - see
      // [AppStateProvider.projectPaneRequestId].
      // By its key: the pane switcher keys whichever half is on screen, and
      // 'Rooms' is also a column heading on the list underneath.
      await tester.tap(find.byKey(const ValueKey('project_pane_rooms')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rooms are references'), findsOneWidget);

      provider.requestProjectPane('lifecycle');
      await tester.pumpAndSettle();
      expect(find.textContaining('Rooms are references'), findsNothing);
    });

    testWidgets('is unchanged by a name no pane has', (tester) async {
      final provider = await pumpTab(tester);
      // Steering by name means a rename on the pane list stops the steering,
      // rather than crashing the thing doing it.
      provider.requestProjectPane('no_such_pane');
      await tester.pumpAndSettle();
      expect(find.textContaining('Rooms are references'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
