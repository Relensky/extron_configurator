import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/pinned_grid.dart';
import 'package:extron_configurator/project_lifecycle_view.dart';
import 'package:extron_configurator/project_view.dart';

/// THE PLAN AS SOMETHING THAT LEAVES THE SCREEN.
///
/// The grid on the Lifecycle pane scrolls in its own frame with the room names
/// and the year headings pinned - which is right for reading it and useless for
/// handing it over, because a photograph of that is a photograph of the eight
/// rooms and six years that happened to be showing.
///
/// [LifecyclePlanSheet] is the same sheet laid out flat. What these guard is
/// that it stays the WHOLE plan: nothing lazy, nothing pinned, every room and
/// every year on it, and the totals printed on it so it can be understood in a
/// document with no app around it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_lc_picture'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(String stem, String name, int installedYear) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gui_full_room_name': name,
        'gve_bldg': 'BSS',
        'gve_room': stem,
      },
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        {
          'id': 'PROJECTORDEVICE_1',
          'label': 'Projector 1',
          'model': 'PROJ-1',
          'installedOn': '$installedYear-05-01',
          'ports': const [],
        },
      ],
      'cables': const [],
    }));
    return configPath;
  }

  AppStateProvider job({int rooms = 3}) {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PROJ-1',
        manufacturer: 'Generic',
        category: 'Projector',
        price: 10000,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    for (var i = 0; i < rooms; i++) {
      p.addRoomToProject(writeRoom('r$i', 'Bessey 10$i', 2014 + i));
    }
    return p;
  }

  Future<void> openLifecycle(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_lifecycle')));
    await tester.pumpAndSettle();
  }

  testWidgets('the pane offers a picture and a spreadsheet', (tester) async {
    await openLifecycle(tester, job());
    expect(find.byKey(const ValueKey('lifecycle_picture')), findsOneWidget);
    expect(find.byKey(const ValueKey('lifecycle_spreadsheet')), findsOneWidget);
  });

  testWidgets('the picture is the whole plan, not the window over it',
      (tester) async {
    final p = job(rooms: 3);
    await openLifecycle(tester, p);

    await tester.tap(find.byKey(const ValueKey('lifecycle_picture')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('lifecycle_picture_dialog')),
      findsOneWidget,
    );
    // The flat sheet, and NOT the scrolling frame: a capture of a PinnedGrid
    // is a capture of the frame.
    expect(find.byType(LifecyclePlanSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LifecyclePlanSheet),
        matching: find.byType(PinnedGrid),
      ),
      findsNothing,
    );

    // Every room is on it, whether or not it would have fitted on screen.
    for (final room in ['BSS r0', 'BSS r1', 'BSS r2']) {
      expect(
        find.descendant(
          of: find.byType(LifecyclePlanSheet),
          matching: find.text(room),
        ),
        findsOneWidget,
        reason: '$room has to be on the picture',
      );
    }
  });

  testWidgets('it carries its own heading and totals', (tester) async {
    final p = job();
    await openLifecycle(tester, p);
    await tester.tap(find.byKey(const ValueKey('lifecycle_picture')));
    await tester.pumpAndSettle();

    // A grid of coloured cells with no title and no totals on it explains
    // nothing once it is in a document with no app around it.
    final sheet = find.byType(LifecyclePlanSheet);
    expect(
      find.descendant(of: sheet, matching: find.textContaining('Bessey')),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text('EVERYTHING, WHATEVER ITS AGE'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.textContaining('As of ')),
      findsOneWidget,
    );
  });

  testWidgets('the strip breaks the whole-building figure out on its own',
      (tester) async {
    await openLifecycle(tester, job());

    // The items and the money as two figures behind a rule, rather than one
    // run-on chip beside the two asks - see [LifecycleEverythingChunk].
    expect(
      find.byKey(const ValueKey('lifecycle_everything_chunk')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lifecycle_everything_items')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lifecycle_everything_money')),
      findsOneWidget,
    );
  });

  testWidgets('the flat sheet draws a building of one as happily as forty',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: LifecyclePlanSheet(
                building: BuildingLifecycle(
                  rooms: const [],
                  asOf: DateTime(2026, 6, 1),
                ),
                title: 'An unsurveyed building',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('An unsurveyed building'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  //  THE WHOLE TIMELINE, NOT A WINDOW ON IT
  // ---------------------------------------------------------------------------

  /// A room whose projector went in a long time ago, and one whose display is
  /// held to a forty-year life - so the span runs well past both ends of the
  /// window the on-screen grid caps itself to.
  String writeWideRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gui_full_room_name': name,
        'gve_bldg': 'BSS',
        'gve_room': stem,
      },
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        {
          'id': 'PROJECTORDEVICE_1',
          'label': 'Projector 1',
          'model': 'PROJ-1',
          'installedOn': '1998-05-01',
          'ports': const [],
        },
        {
          'id': 'DISPLAYDEVICE_1',
          'label': 'Lectern rack frame',
          'model': 'LONG-LIFE-1',
          'installedOn': '2022-05-01',
          'ports': const [],
        },
      ],
      'cables': const [],
    }));
    return configPath;
  }

  AppStateProvider wideJob() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PROJ-1',
        manufacturer: 'Generic',
        category: 'Projector',
        price: 10000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'LONG-LIFE-1',
        manufacturer: 'Generic',
        category: 'Display',
        price: 4000,
        lifeYears: 40,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.addRoomToProject(writeWideRoom('r0', 'Bessey 100'));
    return p;
  }

  BuildingLifecycle planOf(AppStateProvider p) => buildProjectLifecycle(
    estimate: p.priceProject(),
    library: p.avDeviceLibrary,
    baseCosts: p.baseCosts,
    tier: p.pricingTier,
  );

  testWidgets('the picture carries every year, both ends of the span',
      (tester) async {
    final p = wideJob();
    final plan = planOf(p);

    // The setup has to actually exercise the cap, or this test passes for the
    // wrong reason on any job that happens to fit.
    expect(
      plan.allYears.length,
      greaterThan(plan.years().length),
      reason: 'the on-screen grid should be capping this job',
    );

    await openLifecycle(tester, p);
    await tester.tap(find.byKey(const ValueKey('lifecycle_picture')));
    await tester.pumpAndSettle();

    final sheet = find.byType(LifecyclePlanSheet);
    // A 1998 install at one end and a 2062 replacement at the other: both are
    // dates the plan turns on, and both were off the picture.
    for (final year in [plan.allYears.first, plan.allYears.last]) {
      expect(
        find.descendant(of: sheet, matching: find.text('$year')),
        findsOneWidget,
        reason: '$year is on the plan and has to be on the picture',
      );
    }
    // ...and every year in between, so the row a reader traces is unbroken.
    for (final year in plan.allYears) {
      expect(
        find.descendant(of: sheet, matching: find.text('$year')),
        findsOneWidget,
        reason: '$year should be a column on the picture',
      );
    }
  });

  testWidgets('the grid on the pane still caps itself - a screen is a window',
      (tester) async {
    final p = wideJob();
    final plan = planOf(p);
    await openLifecycle(tester, p);

    // The picture is uncapped BECAUSE the screen is not. Thirty columns of
    // nothing in front of the first real one is thirty columns to scroll past.
    expect(
      find.descendant(
        of: find.byType(LifecycleYearGrid),
        matching: find.text('${plan.allYears.first}'),
      ),
      findsNothing,
    );
  });

}
