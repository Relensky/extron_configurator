import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_view.dart';

/// The Project tab: the building total at the top, the rooms behind it, the
/// merged parts list, and the vendor tagging that splits it.
///
/// The tab is also read on whatever window somebody has — and it carries wide
/// tables — so the layout gets the same overflow check the Cost tab has.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_project_view'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  String writeRoom(
    String stem,
    String name,
    List<AvNode> nodes, {
    /// Shelf spares this room asked for: description -> units. Written as
    /// whole spare LINES on the cost sidecar, which is one of the two ways a
    /// room says "spare" and the one a test can write without guessing at a
    /// device group's line key.
    Map<String, double> spares = const {},
    double sparePrice = 300,
  }) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [for (final n in nodes) n.toJson()],
    }));
    if (spares.isNotEmpty) {
      File(path.join(dir.path, '${stem}_config_cost.json'))
          .writeAsStringSync(jsonEncode({
        'cost': {
          'extraEquipment': [
            for (final e in spares.entries)
              {
                'id': '$stem-${e.key}',
                'description': e.key,
                'qty': e.value,
                'unitPrice': sparePrice,
                'spare': true,
              },
          ],
        },
      }));
    }
    return configPath;
  }

  /// A provider holding a two-room project, both rooms on disk.
  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'DTP2 T 211',
        manufacturer: 'Extron',
        partNumber: '60-1439-13',
        category: 'Transmitter',
        price: 500,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'RoboSHOT 12E',
        manufacturer: 'Vaddio',
        category: 'Camera',
        price: 2000,
        ports: [],
      ));

    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.addRoomToProject(writeRoom('a', 'Bessey 101', [
      device('d1', 'Lectern TX', 'DTP2 T 211'),
      device('d2', 'Room camera', 'RoboSHOT 12E'),
    ]));
    p.addRoomToProject(writeRoom('b', 'Bessey 103', [
      device('d1', 'Lectern TX', 'DTP2 T 211'),
    ]));
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p,
      {double width = 1600}) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the rooms, showing each room and the building total',
      (tester) async {
    await pump(tester, withProject());

    expect(find.text('Bessey 101'), findsOneWidget);
    expect(find.text('Bessey 103'), findsOneWidget);
    expect(find.text('Building total'), findsOneWidget);
    // 500 + 2000 + 500, in the header and again in the totals card.
    expect(find.text(r'$3,000.00'), findsWidgets);
    expect(find.text('Project total'), findsWidgets);
  });

  testWidgets('unticking a room takes it out of the total but leaves it listed',
      (tester) async {
    final p = withProject();
    await pump(tester, p);

    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();

    expect(find.text('Bessey 103'), findsOneWidget, reason: 'still on the job');
    // The camera room alone.
    expect(find.text(r'$2,500.00'), findsWidgets);
    expect(p.priceProject().grandTotal, 2500);
  });

  testWidgets('the master list merges a part across rooms', (tester) async {
    final p = withProject();
    await pump(tester, p);

    await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
    await tester.pumpAndSettle();

    // One transmitter line, quantity two, and the rooms it is for.
    expect(find.textContaining('60-1439-13'), findsOneWidget);
    // The breakdown appears on the row, and again on its no-module note —
    // these fixture rooms have no config device blocks behind their boxes.
    expect(find.text('Bessey 101 ×1, Bessey 103 ×1'), findsOneWidget);
    final transmitter = p
        .priceProject()
        .master
        .firstWhere((l) => l.partNumber == '60-1439-13');
    expect(transmitter.qty, 2, reason: 'one in each room, merged onto a line');
    expect(transmitter.qtyByRoom, hasLength(2));
  });

  group('isolating the spares', () {
    /// A job whose two rooms both put a spare on the shelf, one of them twice.
    AppStateProvider withSpares() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.newProject(name: 'Bessey refresh', building: 'BSS');
      p.addRoomToProject(writeRoom(
        'a',
        'Bessey 101',
        [],
        spares: {'Spare lamp': 2},
      ));
      p.addRoomToProject(writeRoom(
        'b',
        'Bessey 103',
        [],
        spares: {'Spare lamp': 1, 'Spare panel': 1},
      ));
      return p;
    }

    Future<void> openSpares(WidgetTester tester, AppStateProvider p) async {
      await pump(tester, p);
      await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Spares'));
      await tester.pumpAndSettle();
    }

    testWidgets('the spares filter shows what they cost and who asked',
        (tester) async {
      await openSpares(tester, withSpares());

      expect(find.byKey(const ValueKey('project_spares_panel')),
          findsOneWidget);
      // 4 units at 300 across two parts.
      expect(find.textContaining('4 units across 2 parts'), findsOneWidget);
      expect(find.textContaining(r'$1,200.00'), findsWidgets);

      // The rooms that asked, on the row rather than only in a total — the
      // whole point of the feature is that a merged line can be broken back
      // down to the room that wanted it.
      expect(find.text('Spare for Bessey 101 ×2, Bessey 103 ×1'),
          findsOneWidget);
      expect(find.text('Spare for Bessey 103 ×1'), findsOneWidget);
    });

    testWidgets('a room chip narrows the list to that room’s spares',
        (tester) async {
      final p = withSpares();
      await openSpares(tester, p);

      final room = p.project.rooms.first.id;
      await tester.tap(find.byKey(ValueKey('spare_room_$room')));
      await tester.pumpAndSettle();

      // Bessey 101 asked for two lamps and nothing else, so the panel counts
      // and prices ITS spares and the panel is titled for it.
      expect(find.text('Spares for Bessey 101'), findsOneWidget);
      expect(find.textContaining('2 units across 1 part'), findsOneWidget);
      expect(find.text('2 spare'), findsOneWidget);

      // The other room's part is gone from the LIST. Not from the page: the
      // section above it is the whole job's shelf list and stays whole, and
      // the chip narrows the parts under it.
      final panel = p
          .priceProject()
          .master
          .firstWhere((l) => l.description == 'Spare panel');
      expect(
        find.byKey(ValueKey('part_price_${panel.key}')),
        findsNothing,
        reason: 'the panel is not one of Bessey 101 spares',
      );
    });

    testWidgets('leaving the spares filter drops the room narrowing',
        (tester) async {
      final p = withSpares();
      await openSpares(tester, p);
      await tester.tap(
        find.byKey(ValueKey('spare_room_${p.project.rooms.first.id}')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('All ('));
      await tester.pumpAndSettle();

      // A room left selected behind another filter would be an invisible one:
      // a list quietly missing rows with nothing on screen saying why.
      expect(find.byKey(const ValueKey('project_spares_panel')), findsNothing);
      expect(find.textContaining('Spare panel'), findsOneWidget);
    });

    testWidgets('a job with no spares still offers the way in', (tester) async {
      // The chip is the door to the section where a spare is ADDED, so one
      // that appeared only once somebody had already added a spare would be a
      // door that opens from the inside.
      await pump(tester, withProject());
      await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
      await tester.pumpAndSettle();

      expect(find.text('Spares'), findsOneWidget);
      await tester.tap(find.text('Spares'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('project_spares_section')),
          findsOneWidget);
      expect(find.textContaining('Nothing on this job has a spare yet'),
          findsOneWidget);
    });
  });

  group('what is flagged about a room', () {
    /// A room whose only device has no price anywhere, so the row has
    /// something to flag.
    AppStateProvider withFlags() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.newProject(name: 'Bessey refresh', building: 'BSS');
      p.addRoomToProject(writeRoom('a', 'Bessey 101', [
        device('d1', 'Lectern TX', 'NO SUCH MODEL'),
      ]));
      return p;
    }

    testWidgets('the icon is big enough to read as a control',
        (tester) async {
      final p = withFlags();
      await pump(tester, p);

      final id = p.project.rooms.first.id;
      final icon = find.descendant(
        of: find.byKey(ValueKey('room_row_flags_$id')),
        matching: find.byIcon(Icons.info_outline),
      );
      expect(icon, findsOneWidget);
      // It used to be 18 in the quiet ink beside four buttons, where it read
      // as decoration rather than as the one thing on the row that is not
      // always there.
      expect(tester.widget<Icon>(icon).size, 24);
    });

    testWidgets('pressing it copies what is flagged, named for the room',
        (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final p = withFlags();
      await pump(tester, p);
      await tester.tap(
        find.byKey(ValueKey('room_row_flags_${p.project.rooms.first.id}')),
      );
      // THE COPY WAITS OUT THE DOUBLE-CLICK. The same target now opens the
      // room's Cost page on a double-click, so a single one cannot be acted on
      // until the gesture recognizer knows a second is not coming.
      await tester.pump(kDoubleTapTimeout);
      await tester.pump();

      // The room leads: a bare "1 line(s) have no price" pasted into a message
      // is a fact with no subject.
      expect(copied, isNotNull);
      expect(copied, contains('Bessey 101'));
      expect(copied, contains('no price'));
      expect(find.textContaining('Copied what is flagged'), findsOneWidget);

      // Let the confirmation bar finish rather than leaving its timer running.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  // -------------------------------------------------------------------------
  //  FROM A FLAG TO THE THING IT IS ABOUT
  // -------------------------------------------------------------------------
  //  A flag names a fault in a ROOM, and the page that fixes it is one room
  //  switch and one tab away. Reading the flag and then hunting for the room
  //  was most of the work of acting on it.

  group('a flag is a way in', () {
    /// Double-clicks [target] and lets the room actually open.
    ///
    /// THE PUMP IN THE MIDDLE IS NOT OPTIONAL. Landing on the room's own page
    /// means reading that room off disk, and a widget test runs in a
    /// fake-async zone where real file I/O never completes - so the handler
    /// would sit for ever on its first await and the room would still be
    /// unopened when the expectations ran. [WidgetTester.runAsync] steps
    /// outside that zone for long enough for the read to finish.
    Future<void> doubleClick(WidgetTester tester, Finder target) async {
      await tester.tap(target);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(target);
      await tester.pump();
      // Several turns of the real loop with a pump between them: the open
      // reads a config, then a sidecar, then prices the room, and each await
      // needs the zone stepped out of once more.
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    AppStateProvider withFlags() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.newProject(name: 'Bessey refresh', building: 'BSS');
      p.addRoomToProject(writeRoom('a', 'Bessey 101', [
        device('d1', 'Lectern TX', 'NO SUCH MODEL'),
      ]));
      return p;
    }

    testWidgets('double-clicking what is flagged opens that room on its Cost '
        'page', (tester) async {
      final p = withFlags();
      await pump(tester, p);

      await doubleClick(
        tester,
        find.byKey(ValueKey('room_row_flags_${p.project.rooms.first.id}')),
      );

      // The room is the one the flag was on, and the tab is the one the fault
      // is fixed on - not the project tab it was double-clicked from.
      expect(p.openProjectRoom?.id, p.project.rooms.first.id);
      expect(p.selectedTabIndex, AppTab.cost.index);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('double-clicking a price opens the room that has most of that '
        'part', (tester) async {
      final p = withProject();
      await pump(tester, p);
      await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
      await tester.pumpAndSettle();

      final line = p.priceProject().master.first;
      await doubleClick(tester, find.byKey(ValueKey('part_price_${line.key}')));

      // The price dialog is the SINGLE click and must not have opened as well.
      expect(find.byKey(const ValueKey('part_price_dialog')), findsNothing);
      expect(p.selectedTabIndex, AppTab.cost.index);
      expect(p.openProjectRoom, isNotNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  // -------------------------------------------------------------------------
  //  THE PANE SWITCHER SIZES ITSELF TO ITS OWN LABELS
  // -------------------------------------------------------------------------
  //  A SegmentedButton gives every segment the width of the widest one and
  //  then clamps that to a ninth of the row, so one long label that does not
  //  fit wraps INSIDE its button. The switcher measures instead of guessing.

  group('the pane switcher never wraps a label', () {
    testWidgets('a window wide enough for nine labels keeps them, one line '
        'each', (tester) async {
      await pump(tester, withProject(), width: 2600);

      final longest = find.byKey(
        const ValueKey('project_pane_responsibility'),
      );
      expect(tester.widget(longest), isA<Text>());
      // As tall as the shortest label on the strip: two lines would be twice
      // the height, which is the fault being fixed.
      expect(
        tester.getSize(longest).height,
        tester.getSize(find.byKey(const ValueKey('project_pane_rooms'))).height,
      );
    });

    testWidgets('a window that cannot hold them drops to icons with the name '
        'on a tooltip', (tester) async {
      await pump(tester, withProject(), width: 900);

      // The key follows the pane, not the label - a segment is findable in
      // either shape, and here the shape is an icon.
      expect(
        tester.widget(find.byKey(const ValueKey('project_pane_responsibility'))),
        isA<Icon>(),
      );
      expect(find.byTooltip('Responsibility'), findsOneWidget);
    });
  });

  group('vendors', () {
    testWidgets('a new vendor lands at the top of the list', (tester) async {
      final p = withProject();
      final wasFirst = p.project.vendors.first.id;
      await pump(tester, p);
      await tester.tap(find.byIcon(Icons.local_shipping).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add vendor'));
      await tester.pumpAndSettle();

      // Order decides which vendor claims a part, and the reason somebody
      // presses Add is nearly always that this one should win. It also has to
      // be somewhere they can see it.
      expect(p.project.vendors.first.name, 'New vendor');
      expect(p.project.vendors[1].id, wasFirst);
    });

    testWidgets('the add box survives adding a rule and keeps the focus',
        (tester) async {
      final p = withProject();
      await pump(tester, p);
      await tester.tap(find.byIcon(Icons.local_shipping).first);
      await tester.pumpAndSettle();
      // The cards are closed by default now; the rules are behind the toggle.
      await tester.tap(
        find.byKey(ValueKey('vendor_toggle_${p.project.vendors.first.id}')),
      );
      await tester.pumpAndSettle();

      final box = find.byKey(const ValueKey('rule_add_Categories')).first;
      expect(box, findsOneWidget);
      final field = find.descendant(of: box, matching: find.byType(TextField));

      await tester.tap(field);
      await tester.enterText(field, 'Ceiling speakers');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Adding rules is a run, not a single act: the box has to survive its
      // own success, empty and still focused, ready for the next one.
      expect(find.text('Ceiling speakers'), findsWidgets);
      expect(tester.widget<TextField>(field).controller?.text, '');
      expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);
    });
  });

  testWidgets('the starter vendors tag the parts without any setup',
      (tester) async {
    final p = withProject();
    await pump(tester, p);
    await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
    await tester.pumpAndSettle();

    final estimate = p.priceProject();
    // "Extron Direct" by manufacturer, the camera by category — the split the
    // feature was asked for, out of the box.
    expect(estimate.untaggedParts, 0);
    expect(
      estimate.master
          .firstWhere((l) => l.manufacturer == 'Extron')
          .vendor
          ?.name,
      'Extron Direct',
    );
    expect(
      estimate.master
          .firstWhere((l) => l.manufacturer == 'Vaddio')
          .vendor
          ?.name,
      'AV Reseller',
    );
  });

  testWidgets('a part can be pinned to a different vendor from the list',
      (tester) async {
    final p = withProject();
    await pump(tester, p);
    await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
    await tester.pumpAndSettle();

    final extronKey = p
        .priceProject()
        .master
        .firstWhere((l) => l.manufacturer == 'Extron')
        .key;

    // Pin it away from the rule, the way the dropdown does.
    p.pinProjectPart(extronKey, p.project.vendors.last.id);
    await tester.pumpAndSettle();

    final line = p
        .priceProject()
        .master
        .firstWhere((l) => l.manufacturer == 'Extron');
    expect(line.vendor?.name, 'AV Reseller');
    expect(line.tagSource, VendorTagSource.pinned);
  });

  testWidgets('the vendors pane lists the rules and their totals',
      (tester) async {
    final p = withProject();
    await pump(tester, p);

    await tester.tap(find.byKey(const ValueKey('project_pane_vendors')));
    await tester.pumpAndSettle();

    // Closed, the card is the name, what it claims, and what it comes to.
    expect(find.text('Extron Direct'), findsOneWidget);
    expect(find.textContaining(r'$1,000.00'), findsWidgets);

    // The rules are one press away.
    await tester.tap(find.byKey(const ValueKey('vendor_toggle_vendor1')));
    await tester.pumpAndSettle();
    expect(find.text('Extron'), findsWidgets, reason: 'the manufacturer rule');
  });

  testWidgets('the vendor list opens one card at a time', (tester) async {
    final p = withProject();
    await pump(tester, p);
    await tester.tap(find.byKey(const ValueKey('project_pane_vendors')));
    await tester.pumpAndSettle();

    // CLOSED BY DEFAULT. The screen is about the ORDER, and two open cards
    // never fitted on it together. Checked against a label only an OPEN card
    // has - the header's own identity fields are LiveTextFields too.
    const inside = 'Notes on the quote request';
    expect(find.text(inside), findsNothing);

    await tester.tap(find.byKey(const ValueKey('vendor_toggle_vendor1')));
    await tester.pumpAndSettle();
    expect(find.text(inside), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('vendor_toggle_vendor1')));
    await tester.pumpAndSettle();
    expect(find.text(inside), findsNothing);
  });

  testWidgets('a vendor is dragged into a different priority', (tester) async {
    // The order is a RULE - the first vendor whose rules claim a part gets it
    // - so dragging one is a change to how the job is tagged, not a tidy-up.
    final p = withProject();
    final before = p.project.vendors.map((v) => v.name).toList();
    expect(before, hasLength(greaterThan(1)));

    await pump(tester, p);
    await tester.tap(find.byKey(const ValueKey('project_pane_vendors')));
    await tester.pumpAndSettle();

    final first = tester.getCenter(
      find.byKey(ValueKey('vendor_drag_${p.project.vendors.first.id}')),
    );
    final second = tester.getCenter(
      find.byKey(ValueKey('vendor_drag_${p.project.vendors[1].id}')),
    );

    // Moved in steps rather than in one jump: a reorderable list decides where
    // the row has landed from the pointer positions it is given, and a single
    // moveTo gives it one.
    final gesture = await tester.startGesture(first);
    await tester.pump(const Duration(milliseconds: 100));
    final step = (second.dy - first.dy + 12) / 10;
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, step));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      p.project.vendors.map((v) => v.name).toList(),
      isNot(before),
      reason: 'the drag must have moved it',
    );
    expect(p.project.vendors[1].name, before.first);
  });

  testWidgets('an empty project says what to do rather than showing zeros',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)..newProject();
    await pump(tester, p);

    expect(find.textContaining('No rooms on this project yet'), findsOneWidget);
  });

  testWidgets('a room whose file has gone is flagged, not dropped',
      (tester) async {
    final p = withProject();
    final gone = path.join(dir.path, 'a_config.json');
    File(gone).deleteSync();
    p.refreshProjectRooms();
    await pump(tester, p);

    expect(find.textContaining('The config is not at'), findsOneWidget);
    // The other room still prices.
    expect(p.priceProject().grandTotal, 500);
    expect(p.priceProject().failedRooms, 1);
  });

  testWidgets('the first room onto an untouched project brings the vendor '
      'split with it', (tester) async {
    // Landing on the tab and adding the open room, without pressing New. A
    // project with no vendors would put every part in the untagged pile.
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'DTP2 T 211',
        manufacturer: 'Extron',
        price: 500,
        ports: [],
      ));
    expect(p.project.vendors, isEmpty);

    p.addRoomToProject(writeRoom('a', 'Bessey 101', [
      device('d1', 'Lectern TX', 'DTP2 T 211'),
    ]));
    await pump(tester, p);

    expect(p.project.vendors, isNotEmpty);
    expect(p.priceProject().untaggedParts, 0);
  });

  testWidgets('a project whose vendors were all deleted does not get them '
      'back on the next room', (tester) async {
    final p = withProject();
    p.project.vendors.clear();

    p.addRoomToProject(writeRoom('c', 'Bessey 105', [
      device('d1', 'Lectern TX', 'DTP2 T 211'),
    ]));
    await pump(tester, p);

    expect(p.project.vendors, isEmpty, reason: 'deleting them meant it');
  });

  testWidgets('the open room is swapped in memory rather than on disk',
      (tester) async {
    // The one case the headless swap tests cannot reach: if the open room's
    // files were written, the editor would still hold the old model and the
    // next Save would quietly undo the swap.
    final p = withProject();
    p.avDeviceLibrary.upsert(const AvDeviceTemplate(
      model: 'DTP2 T 202',
      manufacturer: 'Extron',
      category: 'Transmitter',
      price: 600,
      ports: [],
    ));

    // Open the first room the way the app does.
    p.currentConfigPath = path.join(dir.path, 'a_config.json');
    p.loadAvFlowForCurrentConfig();
    await pump(tester, p);

    final template = p.avDeviceLibrary.templateForModel('DTP2 T 202')!;
    final plan = p.planProjectModelSwap('DTP2 T 211', template);
    expect(plan.affectedRooms, hasLength(2));
    expect(plan.affectedRooms.first.isOpenRoom, isTrue);

    final result = p.applyProjectModelSwap(plan);

    expect(result.openRoomBoxes, 1);
    expect(result.openRoomDirty, isTrue);
    expect(result.disk.rooms, 1, reason: 'only the closed room was written');

    // In memory for the open room...
    expect(
      p.avNodes.firstWhere((n) => n.id == 'd1').model,
      'DTP2 T 202',
    );
    // ...and on disk for the other one.
    expect(
      readRoomFromDisk(path.join(dir.path, 'b_config.json'))
          .model
          .nodes
          .firstWhere((n) => n.id == 'd1')
          .model,
      'DTP2 T 202',
    );
    // The open room's file is untouched until the user saves it.
    expect(
      readRoomFromDisk(p.currentConfigPath)
          .model
          .nodes
          .firstWhere((n) => n.id == 'd1')
          .model,
      'DTP2 T 211',
    );
  });

  group('the tab is one scroll region', () {
    // It used to be two — a header that scrolled inside itself above a list
    // that scrolled on its own — which put a scrollbar inside a scrollbar and
    // meant the building total could only be reached by dragging the inner
    // one while the outer sat still.
    // Text fields carry a scroller of their own — horizontal on a single-line
    // field, vertical on a multi-line one — tagged with the 'editable'
    // restoration id. Those are field internals, not the page.
    bool isPageScroller(Widget w) =>
        w is Scrollable &&
        w.axisDirection == AxisDirection.down &&
        w.restorationId != 'editable';

    final vertical = find.byWidgetPredicate(isPageScroller);

    // By key rather than by label: 'Equipment' is also a heading on the cost
    // breakdown, so tapping the words would sometimes hit the wrong one.
    for (final pane in ['rooms', 'parts', 'vendors']) {
      testWidgets('on $pane', (tester) async {
        final p = withProject();
        await pump(tester, p, width: 1200);
        await tester.tap(find.byKey(ValueKey('project_pane_$pane')));
        await tester.pumpAndSettle();

        expect(
          find.descendant(of: find.byType(ProjectView), matching: vertical),
          findsOneWidget,
          reason: '$pane has more than one thing that scrolls',
        );
      });
    }

    testWidgets('the building total is as tall as its contents',
        (tester) async {
      // A sliver of its own, not the last row of a list: nothing about it
      // should ever be able to scroll independently.
      final p = withProject();
      await pump(tester, p, width: 1200);

      final totals = find.text('Building total');
      expect(totals, findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(of: totals, matching: find.byType(Card)).first,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Scrollable &&
                w.axisDirection == AxisDirection.down &&
                w.restorationId != 'editable',
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('scrolling reaches the building total', (tester) async {
      final p = withProject();
      // Short enough that the totals card starts below the fold.
      await pump(tester, p, width: 1200);
      tester.view.physicalSize = const Size(1200, 420);
      await tester.pumpAndSettle();

      await tester.drag(
        find.descendant(
          of: find.byType(ProjectView),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Scrollable &&
                w.axisDirection == AxisDirection.down &&
                w.restorationId != 'editable',
          ),
        ),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();

      expect(find.text('Project total'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  for (final width in [700.0, 900.0, 1100.0, 1400.0, 1900.0]) {
    testWidgets('the tab lays out at ${width.round()} px wide', (tester) async {
      final p = withProject();
      // A narrow window drops the segment labels so seven panes still fit, so
      // which of the two the switcher offers is itself part of the layout
      // being checked.
      // Every pane on the switcher. History is no longer among them - it is
      // an icon on the toolbar now, reachable from every tab rather than only
      // from the job.
      for (final pane in [
        (key: 'rooms', icon: Icons.meeting_room),
        (key: 'parts', icon: Icons.inventory_2),
        (key: 'plans', icon: Icons.architecture),
        (key: 'timeline', icon: Icons.event_available),
        (key: 'lifecycle', icon: Icons.history_toggle_off),
        (key: 'responsibility', icon: Icons.handshake_outlined),
        (key: 'vendors', icon: Icons.local_shipping),
        (key: 'todo', icon: Icons.checklist),
        (key: 'notes', icon: Icons.sticky_note_2_outlined),
      ]) {
        await pump(tester, p, width: width);
        // WHICHEVER SHAPE THE SWITCHER IS IN. The labels come off when they no
        // longer fit on one line, which is measured from the labels rather
        // than read off a threshold - so the width alone no longer says which
        // of the two the tap has to find.
        final labeled = find.byKey(ValueKey('project_pane_${pane.key}'));
        await tester.tap(
          labeled.evaluate().isEmpty
              ? find.byIcon(pane.icon).first
              : labeled.first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${pane.key} at $width');
      }
    });
  }

  // -------------------------------------------------------------------------
  //  THE HEADER ON A SMALL WINDOW
  // -------------------------------------------------------------------------
  //  The title strip and the buttons cannot both have their full size on a
  //  narrow window, and it is the TITLE that has to give: a project name is
  //  read at a glance and typed once, and the buttons are the reason the
  //  header is there at all.

  group('the header gives way before the buttons do', () {
    testWidgets('a wide window keeps the fields on one line and the labels on '
        'the buttons', (tester) async {
      await pump(tester, withProject(), width: 1600);

      expect(find.text('Quote requests'), findsOneWidget);
      expect(find.text('Where it stands'), findsOneWidget);
      // By key: 'Equipment' is also a heading on the cost breakdown, so the
      // pane's own label is no longer findable by its words alone.
      expect(
        find.byKey(const ValueKey('project_pane_parts')),
        findsOneWidget,
      );
      // All four identity fields sit side by side.
      final name = tester.getRect(find.byType(TextField).first);
      final stakeholder = tester.getRect(find.byType(TextField).at(1));
      final building = tester.getRect(find.byType(TextField).at(2));
      expect(stakeholder.left, greaterThan(name.left));
      expect(building.left, greaterThan(stakeholder.left));
      expect(building.top, name.top, reason: 'same line');
      // The name takes the larger share of what is left over: it is the
      // longest of the four and what every other screen refers back to.
      expect(name.width, greaterThan(stakeholder.width));
    });

    testWidgets('a narrow window stacks the fields and keeps every button on '
        'screen', (tester) async {
      await pump(tester, withProject(), width: 800);

      // The codes drop to a line of their own, leaving the two prose fields
      // wide enough to read a project name and a department in.
      final name = tester.getRect(find.byType(TextField).first);
      final stakeholder = tester.getRect(find.byType(TextField).at(1));
      final building = tester.getRect(find.byType(TextField).at(2));
      expect(stakeholder.top, greaterThan(name.top), reason: 'own line');
      expect(building.top, greaterThan(stakeholder.top), reason: 'own line');
      expect(name.width, stakeholder.width, reason: 'both full width');

      // Every action is still there, as an icon, and still inside the window.
      // The file actions are NOT among them any more - New, Open, Save and
      // Close live on the title bar, and Close on the banner beside it.
      for (final icon in [
        Icons.refresh,
        Icons.flag_outlined,
        Icons.table_view,
        Icons.send_outlined,
      ]) {
        final button = find.byIcon(icon);
        expect(button, findsWidgets, reason: '$icon is still offered');
        expect(
          tester.getRect(button.first).right,
          lessThanOrEqualTo(800),
          reason: '$icon is on screen, not past the edge',
        );
      }
      // The labels are gone, which is the whole point — they are what did not
      // fit.
      expect(find.text('Quote requests'), findsNothing);
    });

    testWidgets('the actions sit above the project name, split left and right',
        (tester) async {
      await pump(tester, withProject(), width: 1600);

      final refresh = tester.getRect(find.text('Refresh'));
      final stands = tester.getRect(find.text('Where it stands'));
      final workbook = tester.getRect(find.text('Workbook'));
      final rfq = tester.getRect(find.text('Quote requests'));
      final name = tester.getRect(find.byType(TextField).first);
      final panes = tester.getRect(find.byKey(const ValueKey(
          'project_pane_rooms')));

      // One row of its own, above the name and the totals.
      for (final r in [refresh, stands, workbook, rfq]) {
        expect(r.top, refresh.top, reason: 'all four on the same row');
        expect(r.bottom, lessThanOrEqualTo(name.top),
            reason: 'the row sits above the project name');
      }
      expect(name.bottom, lessThanOrEqualTo(panes.top),
          reason: 'the pane switcher is still below the name');

      // WHAT YOU DO TO THE JOB ON THE LEFT, what you get OUT of it on the
      // right. Refresh is hard against the header's own left edge.
      expect(refresh.left, lessThan(stands.left));
      expect(stands.right, lessThan(workbook.left));
      expect(workbook.left, lessThan(rfq.left));
      final refreshButton =
          tester.getRect(find.byKey(const ValueKey('project_refresh')));
      expect(refreshButton.left, lessThanOrEqualTo(name.left),
          reason: 'Refresh is at the far left, under the name it re-reads');

      // THE FILE ACTIONS ARE GONE FROM THIS TAB. They are on the title bar,
      // and two Saves on one screen is one Save too many.
      for (final label in ['New', 'Open', 'Save', 'Close']) {
        expect(find.text(label), findsNothing, reason: '$label moved out');
      }
      expect(find.byKey(const ValueKey('project_close')), findsNothing);
    });

    testWidgets('who the job is for is a field on the header', (tester) async {
      final p = withProject();
      await pump(tester, p, width: 1600);

      final field = find.widgetWithText(TextField, 'Stakeholder');
      expect(field, findsOneWidget);

      await tester.enterText(field, 'Physics department');
      await tester.pump();
      // It goes out on the workbook's first sheet and on every quote request,
      // and until it was here the only way to set it was through the API.
      expect(p.project.stakeholder, 'Physics department');
    });

    testWidgets('the collapsed buttons still do their job', (tester) async {
      final p = withProject();
      await pump(tester, p, width: 800);

      // Pressed by icon, with nothing standing in the way of the tap — the
      // failure this guards is a button drawn on screen and overlapped by
      // whatever wrapped on top of it.
      await tester.tap(find.byIcon(Icons.flag_outlined));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('project_briefing')), findsOneWidget);
    });

    testWidgets('the selected pane keeps its icon when the labels go',
        (tester) async {
      await pump(tester, withProject(), width: 800);
      // Rooms is the pane the tab opens on. With no label beside it, a tick
      // in place of the icon would leave the current pane the one segment
      // with nothing on it saying what it is.
      expect(find.byIcon(Icons.meeting_room), findsWidgets);
    });

    testWidgets('a narrow window still reaches every pane', (tester) async {
      final p = withProject();
      await pump(tester, p, width: 800);

      // The labels are gone from the switcher, so the icons have to be the
      // targets — and all seven have to be on screen.
      await tester.tap(find.byIcon(Icons.inventory_2).first);
      await tester.pumpAndSettle();
      expect(find.text('Search parts'), findsOneWidget);
    });
  });
  // -------------------------------------------------------------------------
  //  THE ORDER OF THE PHASES ON THE TIMELINE
  // -------------------------------------------------------------------------

  Future<void> openTimeline(WidgetTester tester, AppStateProvider p) async {
    await pump(tester, p);
    final labeled = find.byKey(const ValueKey('project_pane_timeline'));
    await tester.tap(
      labeled.evaluate().isEmpty
          ? find.byIcon(Icons.event_available).first
          : labeled.first,
    );
    await tester.pumpAndSettle();
  }

  // THE DATES BEFORE THE CARDS. The pane below is a list, and a list cannot
  // say whether the first order is next week or in March - see
  // [ProjectDateGraph]. This guards the wiring: the graph is drawn on the pane
  // rather than only being a widget that could be.
  testWidgets('the timeline opens with its dates on one rail', (tester) async {
    final p = withProject();
    p.project.deliveryDeadline = DateTime(2026, 6, 1);
    p.addProjectTrack('Infrastructure', deadline: DateTime(2026, 5, 1));
    await openTimeline(tester, p);

    expect(find.byKey(const ValueKey('timeline_date_graph')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('timeline_date_mark_Delivery deadline')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_date_mark_Infrastructure on site')),
      findsOneWidget,
    );
  });

  testWidgets('a phase is dragged into place by its handle', (tester) async {
    final p = withProject();
    p.project.deliveryDeadline = DateTime(2026, 6, 1);
    p.addProjectTrack('Infrastructure', deadline: DateTime(2026, 5, 1));
    p.addProjectTrack('Tech install', deadline: DateTime(2026, 3, 1));
    await openTimeline(tester, p);

    expect(find.text('Infrastructure'), findsOneWidget);
    expect(find.text('Tech install'), findsOneWidget);

    // The second phase, picked up by its handle and dropped on the first.
    final handle = find.byKey(
      ValueKey('track_drag_${p.project.tracks[1].id}'),
    );
    expect(handle, findsOneWidget);
    final target = tester.getCenter(find.text('Infrastructure'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      [for (final t in p.project.tracks) t.name],
      ['Tech install', 'Infrastructure'],
      reason: 'the phase should have landed where it was dropped',
    );
  });

  testWidgets('the two dates each sort the phases their own way',
      (tester) async {
    final p = withProject();
    p.project.deliveryDeadline = DateTime(2026, 6, 1);
    final infra = p.addProjectTrack(
      'Infrastructure',
      deadline: DateTime(2026, 5, 1),
    );
    final tech = p.addProjectTrack(
      'Tech install',
      deadline: DateTime(2026, 3, 1),
    );
    // The tech goes in first and is finished last.
    p.setProjectTrackCompletion(infra.id, DateTime(2026, 6, 1));
    p.setProjectTrackCompletion(tech.id, DateTime(2026, 9, 1));
    await openTimeline(tester, p);

    await tester.tap(find.byKey(const ValueKey('timeline_sort_delivery')));
    await tester.pumpAndSettle();
    expect(
      [for (final t in p.project.tracks) t.name],
      ['Tech install', 'Infrastructure'],
    );

    await tester.tap(find.byKey(const ValueKey('timeline_sort_completion')));
    await tester.pumpAndSettle();
    expect(
      [for (final t in p.project.tracks) t.name],
      ['Infrastructure', 'Tech install'],
      reason: 'delivered first is not the same as finished first',
    );

    // And the date somebody set is on the card, not just in the file.
    expect(find.textContaining('finished'), findsWidgets);
  });

}
