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

  String writeRoom(String stem, String name, List<AvNode> nodes) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [for (final n in nodes) n.toJson()],
    }));
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

  for (final width in [1100.0, 1400.0, 1900.0]) {
    testWidgets('the tab lays out at ${width.round()} px wide', (tester) async {
      final p = withProject();
      for (final pane in ['Rooms', 'Core Components', 'Vendors']) {
        await pump(tester, p, width: width);
        await tester.tap(find.text(pane));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$pane at $width');
      }
    });
  }
}
