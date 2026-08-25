import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/lifecycle_view.dart';
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

    testWidgets('the room names stay put while the years scroll', (
      tester,
    ) async {
      // Narrow enough that thirteen years of columns run well past the edge.
      await pumpPlan(tester, building(2), size: const Size(760, 900));

      final name = find.text('BSS 101').first;
      final before = tester.getTopLeft(name);
      final yearBefore = tester.getTopLeft(find.text('2014').first);

      await tester.drag(find.byType(PinnedGrid), const Offset(-240, 0));
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
      const size = Size(1000, 900);
      await pumpPlan(tester, building(14), size: size);

      // Fourteen rooms at full size would be most of the window. The frame is
      // capped instead, and the rows move inside it.
      expect(
        tester.getSize(find.byType(PinnedGrid)).height,
        lessThan(size.height * 0.6),
      );

      final before = tester.getTopLeft(find.text('BSS 101').first);
      await tester.drag(find.byType(PinnedGrid), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('BSS 101').first).dy,
        lessThan(before.dy),
        reason: 'the rows scroll inside the frame',
      );
    });

    testWidgets('builds the rows on screen and not the rest', (tester) async {
      // THE SHEET IS BUILT A ROW AT A TIME. A building with several
      // replacement dates per room is hundreds of rows of a dozen cells, and
      // the frame shows eight of them - building the other two hundred is what
      // made this tab take a second to open.
      const size = Size(1000, 900);
      await pumpPlan(tester, building(30), size: size);

      final cells = find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> &&
            key.value.startsWith('lifecycle_cell_');
      });
      // Thirty rooms across a thirteen-year span is getting on for four
      // hundred cells; the frame holds a fraction of them.
      expect(cells, findsWidgets);
      expect(
        cells.evaluate().length,
        lessThan(30 * 13 ~/ 2),
        reason: 'only the rows in the frame should have been built',
      );
    });

    testWidgets('at 150% the cells grow rather than clip', (tester) async {
      await pumpPlan(tester, building(2));
      final plain = tester.getSize(
        find.byKey(const ValueKey('lifecycle_cell_BSS 101_2014')),
      );

      await pumpPlan(tester, building(2), textScale: 1.5);
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
      // The name, not just a colour and a figure. "Which boxes" is the first
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
    // in its own colour, then the rest of the line.
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
