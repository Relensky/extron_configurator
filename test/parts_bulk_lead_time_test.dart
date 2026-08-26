import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/project_view.dart';

/// ONE LEAD TIME, MANY PARTS - AND A LIST THAT CAN BE READ IN ORDER.
///
/// A lead time is never learned about one part. What comes back from the phone
/// call is "six to eight weeks on anything of ours", for a vendor with nineteen
/// lines on the job - and typed one dialog at a time what actually happened was
/// that the first three got the figure and the rest stayed blank, which reads
/// on the timeline as sixteen parts nobody has to think about.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_bulk_lead'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A room with one projector and one display on the drawing.
  String writeRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Projector',
          model: 'PowerLite L610U',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
        AvNode(
          id: 'DISPLAYDEVICE_1',
          label: 'Display',
          model: 'Aquos 65',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
      ],
    }));
    return configPath;
  }

  AppStateProvider job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 1000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'Aquos 65',
        manufacturer: 'Sharp',
        category: 'Display',
        price: 400,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.setProjectDeadline(DateTime(2026, 6, 1));
    p.addRoomToProject(writeRoom('r0', 'Bessey 101'));
    return p;
  }

  Future<void> openParts(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1700, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
    await tester.pumpAndSettle();
  }

  testWidgets('nothing is ticked to begin with, so no bar and no bulk edit',
      (tester) async {
    await openParts(tester, job());
    expect(find.byKey(const ValueKey('parts_selected_count')), findsNothing);
    expect(find.byKey(const ValueKey('parts_selection_lead')), findsNothing);
  });

  testWidgets('ticking rows one at a time arms the bar', (tester) async {
    final p = job();
    await openParts(tester, p);

    final keys = p.priceProject().master.map((l) => l.key).toList();
    expect(keys.length, greaterThanOrEqualTo(2));

    await tester.tap(find.byKey(ValueKey('part_select_${keys.first}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('parts_selected_count')))
          .data,
      startsWith('1 part selected'),
    );

    await tester.tap(find.byKey(ValueKey('part_select_${keys[1]}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('parts_selected_count')))
          .data,
      startsWith('2 parts selected'),
    );

    // And ticking one again takes it back off.
    await tester.tap(find.byKey(ValueKey('part_select_${keys.first}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('parts_selected_count')))
          .data,
      startsWith('1 part selected'),
    );
  });

  testWidgets('the heading box takes every row on the list at once',
      (tester) async {
    final p = job();
    await openParts(tester, p);
    final total = p.priceProject().master.length;

    await tester.tap(find.byKey(const ValueKey('parts_select_shown')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('parts_selected_count')))
          .data,
      startsWith('$total parts selected'),
    );

    // Pressed again with everything on, it clears - a Select all that could
    // only ever add is a control somebody has to hunt for the opposite of.
    await tester.tap(find.byKey(const ValueKey('parts_select_shown')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parts_selected_count')), findsNothing);
  });

  testWidgets('one figure lands on every part that was ticked', (tester) async {
    final p = job();
    await openParts(tester, p);

    await tester.tap(find.byKey(const ValueKey('parts_select_shown')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('parts_selection_lead')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bulk_part_schedule_dialog')),
        findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('bulk_lead_days')),
      '42',
    );
    await tester.pumpAndSettle();
    // The dialog says what the whole selection would land on, before it is
    // applied: 1 June less 42 days is 20 April.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('bulk_order_preview')))
          .data,
      contains('20 Apr 2026'),
    );

    await tester.tap(find.byKey(const ValueKey('bulk_part_schedule_save')));
    await tester.pumpAndSettle();

    final master = p.priceProject().master;
    expect(master, isNotEmpty);
    for (final line in master) {
      expect(
        p.project.partLeadTimes[line.key],
        42,
        reason: '${line.description} should have taken the bulk figure',
      );
    }
  });

  testWidgets('a field nobody armed is a field nobody changed', (tester) async {
    final p = job();
    await openParts(tester, p);
    final keys = p.priceProject().master.map((l) => l.key).toList();

    // One part already wants to be on site early - the screen that goes in
    // before the walls close. A bulk lead-time edit must not wipe it.
    p.setProjectPartNeedBy(keys.first, DateTime(2026, 3, 2));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('parts_select_shown')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('parts_selection_lead')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bulk_lead_days')), '14');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk_part_schedule_save')));
    await tester.pumpAndSettle();

    expect(p.project.partLeadTimes[keys.first], 14);
    expect(p.project.partNeedBy[keys.first], DateTime(2026, 3, 2));
  });

  testWidgets('the selection survives the dialog, for the next edit',
      (tester) async {
    final p = job();
    await openParts(tester, p);
    final total = p.priceProject().master.length;

    await tester.tap(find.byKey(const ValueKey('parts_select_shown')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('parts_selection_lead')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bulk_lead_days')), '7');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk_part_schedule_save')));
    await tester.pumpAndSettle();

    // The usual next move after "one week on all of these" is "and they are
    // all wanted for the second phase". Re-ticking nineteen rows is how that
    // second edit does not get made.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('parts_selected_count')))
          .data,
      startsWith('$total parts selected'),
    );

    await tester.tap(find.byKey(const ValueKey('parts_selection_clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('parts_selected_count')), findsNothing);
  });
}
