import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/lifecycle_view.dart';
import 'package:extron_configurator/project_lifecycle_view.dart';
import 'package:extron_configurator/pinned_grid.dart';
import 'package:extron_configurator/project_view.dart';

/// The two screens the replacement plan is read and filled in on.
///
/// The failure this guards is a survey nobody finishes: the whole plan derives
/// from one date per box, and if recording those means opening eleven device
/// dialogs it never gets done. The dates have to be one press each, from the
/// list.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('lifecycle_view_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AvNode box(String id) => AvNode(
    id: id,
    label: id,
    model: 'PROJ-1',
    pos: Offset.zero,
    ports: const [],
  );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Bessey 101',
          'gve_bldg': 'BSS',
          'gve_room': '101',
        },
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(box('PROJECTORDEVICE_1'));
    p.addAvNode(box('DISPLAYDEVICE_1'));
    return p;
  }

  Future<void> pumpRoom(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: LifecycleView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a room nobody has surveyed says so rather than reading as new',
      (tester) async {
    final p = room();
    await pumpRoom(tester, p);

    expect(
      find.byKey(const ValueKey('lifecycle_item_PROJECTORDEVICE_1')),
      findsOneWidget,
    );
    // "No install date", not "In service" — the two lead to opposite
    // decisions, and a plan that guesses at the safer-looking one is a plan
    // that reads better than the building is.
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('lifecycle_room_condition')),
          )
          .data,
      kEquipmentConditionLabels[EquipmentCondition.unknown],
    );
    expect(find.text('Set install date'), findsNWidgets(2));
  });

  testWidgets('a date is one press from the list, and it sticks', (
    tester,
  ) async {
    final p = room();
    await pumpRoom(tester, p);

    await tester.tap(
      find.byKey(const ValueKey('lifecycle_install_PROJECTORDEVICE_1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stepped_date_picker')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stepped_date_day_14')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stepped_date_confirm')));
    await tester.pumpAndSettle();

    final node = p.avNodeById('PROJECTORDEVICE_1')!;
    expect(node.installedOn, isNotNull);
    expect(node.installedOn!.day, 14);
    // Date only — see AvNode.installedOn.
    expect(node.installedOn!.hour, 0);
    // The other box is untouched: this edits one position, not the room.
    expect(p.avNodeById('DISPLAYDEVICE_1')!.installedOn, isNull);
  });

  testWidgets('the date can be taken back off', (tester) async {
    final p = room();
    p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2018, 4, 1));
    await pumpRoom(tester, p);

    await tester.tap(
      find.byKey(const ValueKey('lifecycle_install_clear_PROJECTORDEVICE_1')),
    );
    await tester.pumpAndSettle();
    expect(p.avNodeById('PROJECTORDEVICE_1')!.installedOn, isNull);
  });

  // -------------------------------------------------------------------------
  //  DATING THE WHOLE ROOM AT ONCE
  // -------------------------------------------------------------------------
  //  A room refreshed together went in together, so the honest record and the
  //  fastest one are the same thing. What matters is that the sweep says how
  //  much it will change, and that it cannot quietly destroy a date somebody
  //  recorded by hand.

  group('dating the whole room', () {
    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('lifecycle_date_room')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('room_install_date_dialog')),
        findsOneWidget,
      );
    }

    Future<void> pickDay(WidgetTester tester, String day) async {
      await tester.tap(find.byKey(const ValueKey('room_install_date_pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('stepped_date_day_$day')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stepped_date_confirm')));
      await tester.pumpAndSettle();
    }

    testWidgets('one date lands on every undated item', (tester) async {
      final p = room();
      await pumpRoom(tester, p);
      await openDialog(tester);
      await pickDay(tester, '14');

      // The button says how much it is about to change.
      expect(find.text('Date 2 items'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room_install_date_apply')));
      await tester.pumpAndSettle();

      for (final id in ['PROJECTORDEVICE_1', 'DISPLAYDEVICE_1']) {
        final node = p.avNodeById(id)!;
        expect(node.installedOn, isNotNull, reason: id);
        expect(node.installedOn!.day, 14, reason: id);
        expect(node.installedOn!.hour, 0, reason: id);
      }
      await tester.pumpAndSettle(const Duration(seconds: 8));
    });

    testWidgets('the survey sweep leaves a date somebody typed alone', (
      tester,
    ) async {
      final p = room();
      p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2018, 4, 1));
      await pumpRoom(tester, p);
      await openDialog(tester);
      await pickDay(tester, '14');

      // Only one is undated, and the default scope is the safe one.
      expect(find.text('Date 1 item'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room_install_date_apply')));
      await tester.pumpAndSettle();

      expect(
        p.avNodeById('PROJECTORDEVICE_1')!.installedOn,
        DateTime(2018, 4, 1),
        reason: 'the recorded date must survive a survey sweep',
      );
      expect(p.avNodeById('DISPLAYDEVICE_1')!.installedOn!.day, 14);
      await tester.pumpAndSettle(const Duration(seconds: 8));
    });

    testWidgets('the whole-room scope does overwrite, when asked', (
      tester,
    ) async {
      final p = room();
      p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2018, 4, 1));
      await pumpRoom(tester, p);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('room_install_scope_all')));
      await tester.pumpAndSettle();
      await pickDay(tester, '14');

      expect(find.text('Date 2 items'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room_install_date_apply')));
      await tester.pumpAndSettle();

      expect(p.avNodeById('PROJECTORDEVICE_1')!.installedOn!.day, 14);
      expect(p.avNodeById('DISPLAYDEVICE_1')!.installedOn!.day, 14);
      await tester.pumpAndSettle(const Duration(seconds: 8));
    });

    testWidgets('backing out changes nothing', (tester) async {
      final p = room();
      await pumpRoom(tester, p);
      await openDialog(tester);
      await pickDay(tester, '14');
      await tester.tap(find.byKey(const ValueKey('room_install_date_cancel')));
      await tester.pumpAndSettle();

      expect(p.avNodeById('PROJECTORDEVICE_1')!.installedOn, isNull);
      expect(p.avNodeById('DISPLAYDEVICE_1')!.installedOn, isNull);
    });
  });

  testWidgets('a room with nothing on the diagram says what to do', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {'SYSTEM_SETUP': {}};
    p.loadAvFlowForCurrentConfig();
    await pumpRoom(tester, p);
    expect(find.textContaining('Nothing to age yet'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  //  THE BUILDING
  // -------------------------------------------------------------------------

  testWidgets('the project pane rolls the rooms up into one plan', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final stem in ['bss101', 'bss103']) {
      final file = '${dir.path}/${stem}_config.json';
      File(file).writeAsStringSync('{"SYSTEM_SETUP":{"gve_room":"$stem"}}');
      // A drawing beside it with one dated box on it, which is what the
      // rollup actually reads.
      File('${dir.path}/${stem}_config_av_flow.json').writeAsStringSync(
        '{"nodes":[{"id":"PROJECTORDEVICE_1","label":"Projector 1",'
        '"model":"PROJ-1","installedOn":"2014-05-01","ports":[]}],'
        '"cables":[]}',
      );
      p.addRoomToProject(file);
    }

    tester.view.physicalSize = const Size(1600, 1200);
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

    // 2014 + 8 = 2022, so both rooms are years past their life.
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('lifecycle_band_overdue'),
            ),
          )
          .data,
      // The band carries the count AND what it costs to replace. Nothing in
      // this job is priced, which the band says rather than reading as free.
      '2 rooms · 2 items, not priced',
    );
    // And the grid carries a cell for the year it fell due.
    expect(find.textContaining('first due 2022'), findsNWidgets(2));
  });

  // -------------------------------------------------------------------------
  //  THE ROOM'S OWN CALENDAR
  // -------------------------------------------------------------------------
  //  The tab answered "how old is everything in here" and left "what year does
  //  it land, in how many tranches, and what does each cost" to the Project
  //  tab - a different screen, on a job the room may not even be on.

  testWidgets('the room tab draws the same year grid the project does',
      (tester) async {
    final p = room();
    p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2014, 5, 1));
    p.setAvNodeInstalledOn('DISPLAYDEVICE_1', DateTime(2019, 5, 1));
    await pumpRoom(tester, p);

    expect(find.text('REPLACEMENT YEAR'), findsOneWidget);
    // Including the zoom, which is part of the grid rather than of the page
    // it is on - the room's sheet is as wide as the building's.
    expect(find.byKey(const ValueKey('lifecycle_zoom_in')), findsOneWidget);
    expect(find.byKey(const ValueKey('lifecycle_zoom_out')), findsOneWidget);
    // Two install dates, so two tranches, each with its own line and its own
    // due year - exactly what the building sheet opens a room into.
    expect(find.textContaining('due 2022'), findsWidgets);
    expect(find.textContaining('due 2027'), findsWidgets);

    // And the line plays through from here too.
    await tester.tap(find.textContaining('due 2022').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('lifecycle_walkthrough')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lifecycle_walkthrough_total')),
      findsOneWidget,
    );
    // The played plan is a document too - the room's name is on it, so a
    // picture of it is a picture of a room rather than of a line.
    expect(
      find.byKey(const ValueKey('lifecycle_walkthrough_picture')),
      findsOneWidget,
    );
    expect(find.textContaining('when it falls due'), findsWidgets);
  });

  testWidgets('the room can hand its own plan over as a picture',
      (tester) async {
    final p = room();
    p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2014, 5, 1));
    await pumpRoom(tester, p);

    // The Project tab has had this since the plan did; this is the tab
    // somebody is on when they are asked what one room needs and when.
    final button = find.byKey(const ValueKey('lifecycle_room_picture'));
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('lifecycle_picture_dialog')),
      findsOneWidget,
    );
    // A building of one: the same flat sheet the Project tab photographs.
    expect(find.byType(LifecyclePlanSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LifecyclePlanSheet),
        matching: find.text('EVERYTHING, WHATEVER ITS AGE'),
      ),
      findsOneWidget,
    );
  });

  group('what to put aside for the room each year', () {
    /// A room whose two dates fall due in different years, so the plan is a
    /// line rather than a single spike and there is something to level.
    Future<AppStateProvider> planned(WidgetTester tester) async {
      // PRICED, because an unpriced plan has no line to draw and nothing to
      // set aside - the chart refuses to draw a flat zero and say the room
      // is free. The figures come off the base-cost card by config key, the
      // way a room whose models the catalog does not carry is priced.
      final p = room()
        ..baseCosts = BaseCostBook(
          costs: const [
            BaseCost(category: 'Projector', price: 6000),
            BaseCost(category: 'Display', price: 3000),
          ],
        )
        ..avDeviceLibrary = AvDeviceLibrary.empty();
      p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2014, 5, 1));
      p.setAvNodeInstalledOn('DISPLAYDEVICE_1', DateTime(2019, 5, 1));
      await pumpRoom(tester, p);
      return p;
    }

    testWidgets('the room draws its plan as a line, like the building does', (
      tester,
    ) async {
      // The grid says which year; the shape says which year is the bad one -
      // and on a room read standing in front of it, "what should we be
      // saving" is the question being asked.
      await planned(tester);
      expect(
        find.byKey(const ValueKey('room_lifecycle_spend_chart')),
        findsOneWidget,
      );
      expect(find.textContaining('WHAT THIS ROOM COSTS'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lifecycle_room_set_aside')),
        findsOneWidget,
      );
    });

    testWidgets('the picture carries the line and the figure with it', (
      tester,
    ) async {
      // The picture is what gets handed over. A sheet with the grid on it and
      // neither the shape nor the set-aside leaves the reader to work out the
      // one number the plan is read for.
      await planned(tester);
      await tester.tap(find.byKey(const ValueKey('lifecycle_room_picture')));
      await tester.pumpAndSettle();

      final sheet = find.byType(LifecyclePlanSheet);
      expect(
        find.descendant(
          of: sheet,
          matching: find.byKey(const ValueKey('lifecycle_sheet_spend_chart')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('TO SET ASIDE EACH YEAR'),
        ),
        findsOneWidget,
      );
    });
  });

  // -------------------------------------------------------------------------
  //  WALKING ONE ROOM THROUGH
  // -------------------------------------------------------------------------
  //  The grid says WHEN and HOW MUCH for forty rooms at once, which is the
  //  wrong shape for the other thing it gets used for: standing in front of
  //  somebody and walking them through ONE room, a date at a time, to the
  //  figure at the end.

  group('playing a room\'s plan through', () {
    /// A job whose one room has two replacement dates on it, so the plan has
    /// something to walk.
    Future<AppStateProvider> played(WidgetTester tester) async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      final file = '${dir.path}/bss101_config.json';
      File(file).writeAsStringSync('{"SYSTEM_SETUP":{"gve_room":"bss101"}}');
      File('${dir.path}/bss101_config_av_flow.json').writeAsStringSync(
        '{"nodes":['
        '{"id":"PROJECTORDEVICE_1","label":"Projector 1","model":"PROJ-1",'
        '"installedOn":"2014-05-01","ports":[]},'
        '{"id":"DISPLAYDEVICE_1","label":"Display 1","model":"DISP-1",'
        '"installedOn":"2019-05-01","ports":[]}'
        '],"cables":[]}',
      );
      p.addRoomToProject(file);

      tester.view.physicalSize = const Size(1600, 1200);
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
      return p;
    }

    testWidgets('the end of a line says what the whole room comes to',
        (tester) async {
      await played(tester);

      // The cell a run finishes on used to carry only what lands in THAT year.
      // A room with two dates therefore had no cell anywhere on the sheet
      // saying what refreshing it actually comes to.
      final tooltips = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((t) => t.message ?? '')
          .where((m) => m.contains('Full refresh for'))
          .toList();
      expect(tooltips, isNotEmpty);
      expect(tooltips.first, contains('across 2 dates'));
      expect(tooltips.first, contains('Click the row to play'));
    });

    testWidgets('clicking a line plays it through to the total',
        (tester) async {
      await played(tester);

      await tester.tap(find.textContaining('due 2022').first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lifecycle_walkthrough')),
        findsOneWidget,
      );

      // Every date pops up as the line reaches it, and the total lands once it
      // has been all the way across. pumpAndSettle has run the whole thing.
      expect(
        find.byKey(const ValueKey('lifecycle_play_bss101_2022')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lifecycle_play_bss101_2027')),
        findsOneWidget,
      );
      // THE TOTAL IS ON THE LINE, AT THE END OF IT - not in a box under the
      // chart. The sentence the walk-through tells is "it went in here, it
      // lands here, and this is what the room comes to", and a figure laid out
      // below breaks that sentence in half.
      final total = find.byKey(const ValueKey('lifecycle_walkthrough_total'));
      expect(total, findsOneWidget);
      expect(find.text('FULL REFRESH'), findsOneWidget);

      final last = find.byKey(const ValueKey('lifecycle_play_bss101_2027'));
      expect(
        tester.getRect(total).left,
        greaterThan(tester.getRect(last).left),
        reason: 'the total sits past the last date on the line',
      );
      // Beside the line rather than under the plot. Laid out below the chart
      // it would clear the whole plot - a good part of three hundred pixels -
      // from the callouts on it; on the chart it is within one plot of them.
      expect(
        (tester.getCenter(total).dy - tester.getCenter(last).dy).abs(),
        lessThan(200),
        reason: 'on the chart, not below it',
      );

      // And it can be watched again without reopening it.
      await tester.tap(
        find.byKey(const ValueKey('lifecycle_walkthrough_replay')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  //  HOW LONG IT LASTS
  // -------------------------------------------------------------------------
  //  The due date is the install date plus the life, and until now only the
  //  date could be edited from the list: the life lived on the catalog page,
  //  which is a different screen and a trip nobody makes while walking a room.

  group('the life a position is held to', () {
    Future<void> openLife(WidgetTester tester) async {
      await tester.tap(
        find.byKey(const ValueKey('lifecycle_life_PROJECTORDEVICE_1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('equipment_life_dialog')),
        findsOneWidget,
      );
    }

    testWidgets('a life typed on the row is held against that position only',
        (tester) async {
      final p = room();
      p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2018, 4, 1));
      await pumpRoom(tester, p);
      await openLife(tester);

      await tester.enterText(
        find.byKey(const ValueKey('equipment_life_years')),
        '5',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('equipment_life_apply')));
      await tester.pumpAndSettle();

      expect(p.avNodeById('PROJECTORDEVICE_1')!.lifeYears, 5);
      // The box beside it is untouched: this is a fact about one position.
      expect(p.avNodeById('DISPLAYDEVICE_1')!.lifeYears, 0);
      await tester.pumpAndSettle(const Duration(seconds: 8));
    });

    testWidgets('a life kept with the model is written into the catalog',
        (tester) async {
      final p = room();
      p.avDeviceLibrary.upsert(
        AvDeviceTemplate(model: 'PROJ-1', ports: const []),
      );
      await pumpRoom(tester, p);
      await openLife(tester);

      await tester.enterText(
        find.byKey(const ValueKey('equipment_life_years')),
        '6',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('equipment_life_scope_catalog')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('equipment_life_apply')));
      await tester.pumpAndSettle();

      // On the PRODUCT, so every other position of it follows - including the
      // other box in this room, which nobody touched.
      expect(p.avDeviceLibrary.templateForModel('PROJ-1')!.lifeYears, 6);
      expect(p.avNodeById('PROJECTORDEVICE_1')!.lifeYears, 0);
      expect(p.avNodeById('DISPLAYDEVICE_1')!.lifeYears, 0);
      await tester.pumpAndSettle(const Duration(seconds: 8));
    });

    testWidgets('a model the catalog has never heard of says so rather than '
        'failing when it is pressed', (tester) async {
      final p = room();
      await pumpRoom(tester, p);
      await openLife(tester);

      final tile = tester.widget<RadioListTile<EquipmentLifeScope>>(
        find.byKey(const ValueKey('equipment_life_scope_catalog')),
      );
      expect(tile.enabled, isFalse);
      expect(find.textContaining('is not in the catalog yet'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  //  THE SHEET IS A SHEET, NOT A BLOCK OF THE PAGE
  // -------------------------------------------------------------------------
  //  The replacement grid is wider and taller than the window it is read in.
  //  Laid out at full size it pushed the room list off the bottom and took the
  //  room names off the left edge as soon as anybody read across it, and on a
  //  display at 150% every cell on it clipped. It scrolls in its own frame now,
  //  with the names and the years pinned.

  group('the replacement grid', () {
    /// A job of [rooms] rooms, each with one box that went in in 2014 - which
    /// is a room years past its life, and a grid that spans from 2014 to the
    /// year it falls due.
    AppStateProvider building(int rooms) {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      for (var i = 0; i < rooms; i++) {
        final stem = 'bss${101 + i}';
        final file = '${dir.path}/${stem}_config.json';
        File(file).writeAsStringSync(
          '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"${101 + i}"}}',
        );
        File('${dir.path}/${stem}_config_av_flow.json').writeAsStringSync(
          '{"nodes":[{"id":"PROJECTORDEVICE_1","label":"Projector 1",'
          '"model":"PROJ-1","installedOn":"2014-05-01","ports":[]}],'
          '"cables":[]}',
        );
        p.addRoomToProject(file);
      }
      return p;
    }

    Future<void> pumpPlan(
      WidgetTester tester,
      AppStateProvider p, {
      Size size = const Size(1000, 900),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(textScale),
              ),
              child: const Scaffold(body: ProjectView()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // By icon, not by label: the pane rail drops its labels on a window
      // this narrow and the key rides on the label.
      await tester.tap(find.byIcon(Icons.history_toggle_off));
      await tester.pumpAndSettle();
    }

    /// THE SHEET OPENS FITTED - see [_LifecycleYearGridState._fit]. The tests
    /// below are about what the sheet does at its natural size, so they let go
    /// of the window first: the level button is both "100%" and "stop
    /// fitting", which is exactly the state they were written against.
    Future<void> atNaturalSize(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_level')));
      await tester.pumpAndSettle();
    }

    testWidgets('opens fitted, with the last replacement year on screen',
        (tester) async {
      // A room that falls due WELL past the twelve-year window the sheet used
      // to stop at: two years old, on a twenty-year cycle.
      final dueYear = DateTime.now().year + 18;
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      final file = '${dir.path}/bss150_config.json';
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"150"}}',
      );
      File('${dir.path}/bss150_config_av_flow.json').writeAsStringSync(
        '{"nodes":[{"id":"PROJECTORDEVICE_1","label":"Projector 1",'
        '"model":"PROJ-1","installedOn":"${dueYear - 20}-05-01",'
        '"lifeYears":20,"ports":[]}],"cables":[]}',
      );
      p.addRoomToProject(file);

      // Narrow enough that a sheet at 100% would run off the edge.
      await pumpPlan(tester, p, size: const Size(760, 1100));

      // THE FAR END OF THE PLAN IS ON THE SHEET. The window used to stop
      // twelve years out, so this column did not exist at all - the plan
      // looked complete and ended in a row of blanks.
      expect(
        find.text('$dueYear'),
        findsWidgets,
        reason: 'the sheet runs to the last replacement year',
      );

      // And it opens FITTED rather than at full size: the cells are smaller
      // than the ones the level button gives back.
      final key = ValueKey('lifecycle_cell_BSS 150_${DateTime.now().year}');
      final fitted = tester.getSize(find.byKey(key));
      await atNaturalSize(tester);
      expect(
        fitted.width,
        lessThan(tester.getSize(find.byKey(key)).width),
        reason: 'the sheet opens fitted to the window',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the room names stay put while the years scroll', (
      tester,
    ) async {
      // Narrow enough that thirteen years of columns run well past the edge,
      // and tall enough that the pane's header - which is a summary strip, a
      // row of exports and a pane switcher - is not what this test is about.
      await pumpPlan(tester, building(2), size: const Size(760, 1100));
      await atNaturalSize(tester);

      final name = find.text('BSS 101').first;
      final before = tester.getTopLeft(name);
      final yearBefore = tester.getTopLeft(find.text('2014').first);

      // FROM A POINT INSIDE THE GRID, not from its center. The frame is
      // deliberately taller than what is left of the window below the header
      // - that is what "it scrolls in its own frame" means - so its center can
      // sit below the bottom edge, and a drag aimed there lands on nothing.
      await tester.dragFrom(
        tester.getTopLeft(find.byType(PinnedGrid)) + const Offset(300, 60),
        const Offset(-240, 0),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(name),
        before,
        reason: 'the room a cell is about has to stay beside the cell',
      );
      expect(
        tester.getTopLeft(find.text('2014').first).dx,
        lessThan(yearBefore.dx),
        reason: 'the year headings move with the cells under them',
      );
    });

    testWidgets('a tall plan scrolls inside the grid rather than pushing the '
        'room list off the page', (tester) async {
      const size = Size(1000, 1100);
      await pumpPlan(tester, building(14), size: size);

      // Fourteen rooms at full size would be most of the window. The frame is
      // capped instead, and the rows move inside it.
      expect(
        tester.getSize(find.byType(PinnedGrid)).height,
        lessThan(size.height * 0.6),
      );

      final before = tester.getTopLeft(find.text('BSS 101').first);
      await tester.dragFrom(
        tester.getTopLeft(find.byType(PinnedGrid)) + const Offset(300, 60),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('BSS 101').first).dy,
        lessThan(before.dy),
        reason: 'the rows scroll inside the frame',
      );
    });

    testWidgets('the frame grows with the plan instead of stopping halfway',
        (tester) async {
      // THE SHEET IS THE PAGE. A frame fixed at half the window showed eight
      // rows of a twenty-four room building however much empty screen was
      // under it, so the reader scrolled a small window inside a large one to
      // see a picture that would have fitted.
      const size = Size(1000, 1100);
      await pumpPlan(tester, building(3), size: size);
      final small = tester.getSize(find.byType(PinnedGrid)).height;

      // Forty rooms is taller than any window this is read on, so the frame
      // is what limits it rather than the content.
      await pumpPlan(tester, building(40), size: size);
      final big = tester.getSize(find.byType(PinnedGrid)).height;

      expect(big, greaterThan(small), reason: 'more rooms, more sheet');
      expect(
        big,
        greaterThan(size.height * 0.6),
        reason: 'a tall plan uses the screen it is being read on',
      );
      expect(
        big,
        lessThan(size.height),
        reason: 'and still leaves a page around it',
      );
    });

    testWidgets('builds the rows on screen and not the rest', (tester) async {
      // THE SHEET IS BUILT A ROW AT A TIME. A building with several
      // replacement dates per room is hundreds of rows of a dozen cells, and
      // the frame shows eight of them - building the other two hundred is what
      // made this tab take a second to open.
      // EIGHTY ROOMS, because the frame grows with the sheet now - it takes
      // most of the window rather than half of it, so a plan has to be
      // properly taller than the window for "only what is on screen" to be a
      // claim worth checking.
      const size = Size(1000, 900);
      await pumpPlan(tester, building(80), size: size);

      final cells = find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> &&
            key.value.startsWith('lifecycle_cell_');
      });
      // Eighty rooms across a thirteen-year span is over a thousand cells; the
      // frame holds a fraction of them.
      expect(cells, findsWidgets);
      expect(
        cells.evaluate().length,
        lessThan(80 * 13 ~/ 2),
        reason: 'only the rows in the frame should have been built',
      );
    });

    testWidgets('the sheet zooms, and comes back to 100%', (tester) async {
      await pumpPlan(tester, building(2));
      await atNaturalSize(tester);
      const cell = ValueKey('lifecycle_cell_BSS 101_2014');
      final natural = tester.getSize(find.byKey(cell));

      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_in')));
      await tester.pumpAndSettle();
      final bigger = tester.getSize(find.byKey(cell));
      expect(bigger.width, greaterThan(natural.width));
      expect(bigger.height, greaterThan(natural.height));

      // The level is the way back. Somebody who has pushed the sheet down to
      // half size to see the shape of it should not have to press the other
      // arrow three times to read a figure again.
      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_level')));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(cell)), natural);

      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_out')));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(cell)).width, lessThan(natural.width));
    });

    testWidgets('fit puts the whole sheet inside the frame', (tester) async {
      // Narrow enough that thirteen years of columns run well past the edge.
      await pumpPlan(tester, building(2), size: const Size(760, 1100));
      await atNaturalSize(tester);
      final grid = find.byType(PinnedGrid);
      final frame = tester.getSize(grid).width;

      // Before: the last year is off the right-hand edge of the frame.
      // The sheet runs from the 2014 installs to this year, so the current
      // year is the column hardest against the right-hand edge.
      final lastYear = find.text('${DateTime.now().year}');
      expect(lastYear, findsWidgets);
      final before = tester.getTopLeft(lastYear.first).dx;
      expect(before, greaterThan(frame));

      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_fit')));
      await tester.pumpAndSettle();

      // After: it is on screen, and the sheet did not get any wider than the
      // frame it was fitted to.
      final after = tester.getTopLeft(lastYear.first).dx;
      expect(after, lessThan(before));
      expect(after, lessThan(frame));
      expect(tester.getSize(grid).width, lessThanOrEqualTo(frame + 1));
    });

    testWidgets('leaving the fit keeps the size it fitted to', (tester) async {
      await pumpPlan(tester, building(2), size: const Size(760, 1100));
      await atNaturalSize(tester);
      const cell = ValueKey('lifecycle_cell_BSS 101_2014');

      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_fit')));
      await tester.pumpAndSettle();
      final fitted = tester.getSize(find.byKey(cell));

      // Pressing it again lets go of the window without the sheet jumping
      // back to 100% under the reader.
      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_fit')));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(cell)), fitted);

      // And the level is still the way back.
      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_level')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(cell)).width,
        greaterThan(fitted.width),
      );
    });

    testWidgets('the figures go down with the boxes', (tester) async {
      await pumpPlan(tester, building(2));
      await atNaturalSize(tester);
      // The age in the 2014 cell, which is the figure a shrunk cell would
      // have put an ellipsis through.
      final year = find.descendant(
        of: find.byKey(const ValueKey('lifecycle_cell_BSS 101_2014')),
        matching: find.byType(Text),
      );
      final before = tester.widget<Text>(year).style?.fontSize;
      expect(before, isNotNull);

      await tester.tap(find.byKey(const ValueKey('lifecycle_zoom_out')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(year).style?.fontSize, lessThan(before!));
    });

    testWidgets('at 150% the cells grow rather than clip', (tester) async {
      await pumpPlan(tester, building(2));
      await atNaturalSize(tester);
      final plain = tester.getSize(
        find.byKey(const ValueKey('lifecycle_cell_BSS 101_2014')),
      );

      await pumpPlan(tester, building(2), textScale: 1.5);
      await atNaturalSize(tester);
      final scaled = tester.getSize(
        find.byKey(const ValueKey('lifecycle_cell_BSS 101_2014')),
      );

      expect(scaled.width, greaterThan(plain.width));
      expect(scaled.height, greaterThan(plain.height));
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT LANDS WHEN, AND WHAT IS IN IT
  // -------------------------------------------------------------------------
  //  A cell painted amber in the 2027 column says a year. It does not say
  //  which boxes, and it does not say "put twenty-four thousand in the 2027
  //  request" - which is the sentence the screen exists to produce.

  group('a room with more than one replacement date', () {
    /// One room whose projector went in in 2016 and whose display went in in
    /// 2019 - two dates, eight-year cycle, so 2024 and 2027.
    AppStateProvider phased() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      final file = '${dir.path}/bss101_config.json';
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"101"}}',
      );
      File('${dir.path}/bss101_config_av_flow.json').writeAsStringSync(
        '{"nodes":['
        '{"id":"PROJECTORDEVICE_1","label":"Projector 1","model":"PROJ-1",'
        '"installedOn":"2016-05-01","ports":[]},'
        '{"id":"DISPLAYDEVICE_1","label":"Display 1","model":"DISP-1",'
        '"installedOn":"2019-05-01","ports":[]}'
        '],"cables":[]}',
      );
      p.addRoomToProject(file);
      return p;
    }

    Future<void> pumpPlan(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.history_toggle_off));
      await tester.pumpAndSettle();
    }

    testWidgets('opens into a line per date, each running from its own start',
        (tester) async {
      await pumpPlan(tester, phased());

      // The projector's run: 2016 to 2024. Its first year is drawn, the year
      // before it is not.
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 101_2024_2016')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 101_2024_2025')),
        findsNothing,
      );
      // The display's run starts three years later and lands three years
      // later - which is the whole point of drawing them apart.
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 101_2027_2019')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 101_2027_2016')),
        findsNothing,
      );
    });

    testWidgets('a cell says which boxes are in it', (tester) async {
      await pumpPlan(tester, phased());

      final cell = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const ValueKey('lifecycle_cell_BSS 101_2024')),
          matching: find.byType(Tooltip),
        ),
      );
      // The name, not just a color and a figure. "Which boxes" is the first
      // thing anybody asks of a cell with money in it.
      expect(cell.message, contains('Projector 1'));
      expect(cell.message, contains('due 2024'));
      expect(cell.message, isNot(contains('Display 1')));
    });

    testWidgets('the room list carries the money in the year it lands',
        (tester) async {
      await pumpPlan(tester, phased());

      expect(find.text('BUDGET FOR THIS ROOM'), findsOneWidget);
      // One figure per date rather than one figure for the room: a budget
      // request is written a year at a time.
      expect(
        find.byKey(const ValueKey('lifecycle_due_BSS 101_2024')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('lifecycle_due_BSS 101_2027')),
        findsOneWidget,
      );
    });

    testWidgets('the room row folds its dates away and opens again',
        (tester) async {
      await pumpPlan(tester, phased());

      // Open by default: the room's own row plus one line per date.
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 101_2024_2016')),
        findsOneWidget,
      );

      final fold = find.byKey(const ValueKey('lifecycle_fold_BSS 101'));
      expect(fold, findsOneWidget);
      await tester.tap(fold);
      await tester.pumpAndSettle();

      // Folded: the tranche lines are gone and the room is still there,
      // carrying its own figures.
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 101_2024_2016')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('lifecycle_cell_BSS 101_2024')),
        findsOneWidget,
      );

      await tester.tap(fold);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 101_2024_2016')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a room that falls due once has nothing to fold',
        (tester) async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      final file = '${dir.path}/bss104_config.json';
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"104"}}',
      );
      File('${dir.path}/bss104_config_av_flow.json').writeAsStringSync(
        '{"nodes":['
        '{"id":"PROJECTORDEVICE_1","label":"Projector 1","model":"PROJ-1",'
        '"installedOn":"2019-05-01","ports":[]}'
        '],"cables":[]}',
      );
      p.addRoomToProject(file);
      await pumpPlan(tester, p);

      // A control that does nothing is a control somebody presses twice to
      // find that out.
      expect(
        find.byKey(const ValueKey('lifecycle_fold_BSS 104')),
        findsNothing,
      );
    });

    testWidgets('the room row carries the running total, the lines the add-on',
        (tester) async {
      final p = phased();
      // Two figures that cannot be confused with each other or with a sum of
      // anything else on the sheet.
      p.baseCosts.upsert(const BaseCost(category: 'Projector', price: 2499));
      p.baseCosts.upsert(const BaseCost(category: 'Display', price: 4173));
      await pumpPlan(tester, p);

      // The projector lands first, on its own: both rows agree there.
      expect(find.text(r'$2,499'), findsWidgets);

      // The display's year: the room row shows what the WHOLE room costs if it
      // is done then - 2,499 still owed plus 4,173 landing - while the line
      // under it says what that date adds.
      final roomCell = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('lifecycle_cell_BSS 101_2027')),
          matching: find.byType(Text),
        ),
      );
      expect(roomCell.data, r'$6,672');
      expect(find.textContaining(r'+$4,173'), findsWidgets);
    });

    testWidgets('a room that falls due all at once stays one line',
        (tester) async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      final file = '${dir.path}/bss102_config.json';
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"102"}}',
      );
      File('${dir.path}/bss102_config_av_flow.json').writeAsStringSync(
        '{"nodes":['
        '{"id":"PROJECTORDEVICE_1","label":"Projector 1","model":"PROJ-1",'
        '"installedOn":"2019-05-01","ports":[]},'
        '{"id":"DISPLAYDEVICE_1","label":"Display 1","model":"DISP-1",'
        '"installedOn":"2019-05-01","ports":[]}'
        '],"cables":[]}',
      );
      p.addRoomToProject(file);
      await pumpPlan(tester, p);

      // A second row saying the same thing as the first is a row to read past.
      expect(
        find.byKey(const ValueKey('lifecycle_span_BSS 102_2027_2019')),
        findsNothing,
      );
      // The budget figure is still broken out on the list underneath.
      expect(
        find.byKey(const ValueKey('lifecycle_due_BSS 102_2027')),
        findsOneWidget,
      );
    });
  });

  testWidgets('the room tab lays out at 150% without overflowing', (
    tester,
  ) async {
    final p = room();
    p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2018, 4, 1));
    const size = Size(1000, 720);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(1.5),
            ),
            child: const Scaffold(body: LifecycleView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The strip at the top is no longer nailed above the list: everything on
    // the tab is in one scroll region, which is what makes the list reachable
    // on a window this size at this type size.
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byKey(const ValueKey('lifecycle_date_room')), findsOneWidget);
  });

  testWidgets('a bracket taken off the cycle leaves the plan, and comes back',
      (tester) async {
    final p = room();
    await pumpRoom(tester, p);

    // Both boxes are on the plan to start with.
    expect(find.byKey(const ValueKey('lifecycle_item_PROJECTORDEVICE_1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('lifecycle_show_never')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('lifecycle_never_PROJECTORDEVICE_1')),
    );
    await tester.pumpAndSettle();

    // Off the list, and the toggle says how many are being held back rather
    // than leaving the room quietly one item shorter.
    expect(find.byKey(const ValueKey('lifecycle_item_PROJECTORDEVICE_1')),
        findsNothing);
    expect(find.textContaining('1 that never need replacing'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lifecycle_show_never')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lifecycle_item_PROJECTORDEVICE_1')),
        findsOneWidget);
    // In the row's own subtitle, which is a rich string - the step in words
    // in its own color, then the rest of the line.
    expect(find.textContaining('Never replaced'), findsWidgets);

    // And back onto the plan from the same button.
    await tester.tap(
      find.byKey(const ValueKey('lifecycle_never_PROJECTORDEVICE_1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lifecycle_show_never')), findsNothing);
    expect(find.byKey(const ValueKey('lifecycle_item_PROJECTORDEVICE_1')),
        findsOneWidget);
  });
}
