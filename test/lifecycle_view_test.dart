import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/lifecycle_view.dart';
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
      '2 rooms · 2 items',
    );
    // And the grid carries a cell for the year it fell due.
    expect(find.textContaining('first due 2022'), findsNWidgets(2));
  });
}
