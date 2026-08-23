import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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

    await tester.tap(find.text('Core Components'));
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
      await tester.tap(find.text('Core Components'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Spared ('));
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
      // The other room's panel-only line is gone from the list.
      expect(find.textContaining('Spare panel'), findsNothing);
      expect(find.text('2 spare'), findsOneWidget);
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

    testWidgets('a job with no spares offers no chip at all', (tester) async {
      await pump(tester, withProject());
      await tester.tap(find.text('Core Components'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Spared ('), findsNothing);
    });
  });

  testWidgets('the starter vendors tag the parts without any setup',
      (tester) async {
    final p = withProject();
    await pump(tester, p);
    await tester.tap(find.text('Core Components'));
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
    await tester.tap(find.text('Core Components'));
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

    await tester.tap(find.text('Vendors'));
    await tester.pumpAndSettle();

    expect(find.text('Extron'), findsWidgets, reason: 'the manufacturer rule');
    expect(find.text('Camera'), findsWidgets, reason: 'a category rule');
    // Two transmitters at 500.
    expect(find.textContaining(r'$1,000.00'), findsWidgets);
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

    for (final pane in ['Rooms', 'Core Components', 'Vendors']) {
      testWidgets('on $pane', (tester) async {
        final p = withProject();
        await pump(tester, p, width: 1200);
        await tester.tap(find.text(pane));
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
      for (final pane in [
        (label: 'Rooms', icon: Icons.meeting_room),
        (label: 'Core Components', icon: Icons.inventory_2),
        (label: 'Timeline', icon: Icons.event_available),
        (label: 'Vendors', icon: Icons.local_shipping),
        (label: 'To do', icon: Icons.checklist),
        (label: 'Notes', icon: Icons.sticky_note_2_outlined),
        (label: 'History', icon: Icons.history),
      ]) {
        await pump(tester, p, width: width);
        await tester.tap(
          width < 920
              ? find.byIcon(pane.icon).first
              : find.text(pane.label).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${pane.label} at $width');
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
      expect(find.text('Core Components'), findsOneWidget);
      // The three identity fields sit side by side, so the two short ones are
      // still their own fixed width.
      final name = tester.getRect(find.byType(TextField).first);
      final building = tester.getRect(find.byType(TextField).at(1));
      expect(building.left, greaterThan(name.left));
      expect(building.top, name.top, reason: 'same line');
    });

    testWidgets('a narrow window stacks the fields and keeps every button on '
        'screen', (tester) async {
      await pump(tester, withProject(), width: 800);

      // The codes drop to a line of their own, leaving the name a field wide
      // enough to read a project name in.
      final name = tester.getRect(find.byType(TextField).first);
      final building = tester.getRect(find.byType(TextField).at(1));
      expect(building.top, greaterThan(name.top), reason: 'own line');

      // Every action is still there, as an icon, and still inside the window.
      for (final icon in [
        Icons.note_add_outlined,
        Icons.folder_open,
        Icons.save_outlined,
        Icons.close,
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
}
