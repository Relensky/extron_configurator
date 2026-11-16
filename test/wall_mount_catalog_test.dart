import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/device_merge.dart';
import 'package:extron_configurator/mount_spec.dart';
import 'package:extron_configurator/wall_elevation.dart';
import 'package:extron_configurator/wall_elevation_view.dart';

/// Wall mounting sizes on catalog products, mount arms, and hanging a
/// display on a mount from the Walls tab.
void main() {
  // The Q Pro 86 as its drawing gives it.
  const qproSpec = WallMountSpec(
    role: MountRole.display,
    width: 78.03,
    height: 46.88,
    depth: 4.7,
    vesaW: 800,
    vesaH: 400,
    holeLeft: 23.25,
    holeUp: 14.3,
    touch: true,
  );
  const mountSpec = WallMountSpec(
    role: MountRole.mount,
    width: 37.79,
    height: 16.5,
    depth: 2.67,
    plateHeight: 9.76,
    armWidth: 1.45,
    armSpanMin: 3.93,
    armSpanMax: 31.49,
    vesaW: 800,
    vesaH: 400,
    maxTilt: 10,
    capacityLb: 250,
  );
  const wall = WallView(id: 'WALL_1', name: 'Front wall');

  group('on a catalog product', () {
    test('survives the catalog file, and can be taken off', () {
      const t = AvDeviceTemplate(
        model: 'TT-8624QPRO',
        category: 'Display',
        weightLbs: 120,
        mounting: qproSpec,
        ports: [],
      );
      final back = AvDeviceTemplate.fromJson(t.toJson());
      expect(back.mounting, qproSpec);
      expect(back.copyWith(clearMounting: true).mounting, isNull);
      expect(back.copyWith(notes: 'x').mounting, qproSpec);
    });

    test('a catalog merge offers it', () {
      const mine = AvDeviceTemplate(model: 'TT-8624QPRO', ports: []);
      const theirs = AvDeviceTemplate(
        model: 'TT-8624QPRO',
        mounting: qproSpec,
        ports: [],
      );
      final diff = fieldDiffs(mine, theirs)
          .firstWhere((d) => d.field == DeviceField.mounting);
      expect(diff.mineIsBlank, isTrue);
      expect(diff.applyTo(mine, theirs).mounting, qproSpec);
    });
  });

  group('on the wall', () {
    test('a display from the catalog puts its holes where the drawing says', () {
      final d = placePreset(
        wall,
        wallItemFromSpec(qproSpec, model: 'TT-8624QPRO', weightLb: 120),
      );
      final low = d.vesaHoles.first;
      expect(low.dx - d.x, closeTo(23.25, 1e-9));
      expect(low.dy - d.y, closeTo(14.3, 1e-9));
      expect(d.weightLb, 120);
      expect(d.touch, isTrue);
      expect(differsFromSpec(d, qproSpec, weightLb: 120), isFalse);
      expect(
        differsFromSpec(d.copyWith(width: 70), qproSpec, weightLb: 120),
        isTrue,
      );
    });

    test('a mount from the catalog brings its arms', () {
      final m = wallItemFromSpec(mountSpec, model: 'EPR8A50600-000');
      expect(m.kind, WallItemKind.mount);
      expect(m.armDrawWidth, 1.45);
      expect(m.armSpanMin, 3.93);
      expect(m.armSpanMax, 31.49);
      expect(m.plateHeight, 9.76);
    });

    test('arms that cannot reach the holes are a problem', () {
      var w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final m = w.items.firstWhere((i) => i.kind == WallItemKind.mount);
      String problems(WallView w) => [
        for (final i in checkWall(w))
          if (i.level == WallIssueLevel.problem) i.text,
      ].join('\n');
      expect(problems(w), isNot(contains('arms')));
      w = w.withItem(m.copyWith(armSpanMax: 24));
      expect(problems(w), contains('apart at most'));
      w = w.withItem(m.copyWith(armSpanMin: 34));
      expect(problems(w), contains('apart at'));
      w = w.withItem(m.copyWith(vesaMinW: 900));
      expect(problems(w), contains('narrower than'));
    });

    test('a mount is hung on a display, and let go', () {
      var w = wall.withItem(placePreset(wall, kNewlineQPro86));
      final d = w.items.single;
      w = w.withItem(placePreset(w, kNewlineTiltMount, atX: 0));
      final m = w.items.firstWhere((i) => i.kind == WallItemKind.mount);
      w = hangMount(w, m.id, d.id);
      expect(w.item(d.id)!.mountId, m.id);
      expect(w.item(d.id)!.standoff, closeTo(2.67, 1e-9));
      expect(w.item(m.id)!.centerX, closeTo(w.item(d.id)!.vesaCenterX, 1e-9));
      w = hangMount(w, m.id, '');
      expect(w.item(d.id)!.mountId, isEmpty);
      expect(w.item(d.id)!.standoff, 0);
    });

    test('dropping a mount on a display hangs it; dropping it elsewhere does not',
        () {
      var w = wall.withItem(placePreset(wall, kNewlineQPro86));
      final d = w.items.single;
      w = w.withItem(placePreset(w, kNewlineTiltMount, atX: 0).copyWith(y: 90));
      final m = w.items.firstWhere((i) => i.kind == WallItemKind.mount);
      expect(hangOnDrop(w, m.id), isNull);
      final over = w.withItem(m.copyWith(
        x: d.centerX - m.width / 2,
        y: d.centerY - m.height / 2,
      ));
      final hung = hangOnDrop(over, m.id)!;
      expect(hung.wall.item(d.id)!.mountId, m.id);
      expect(hung.label, contains('Hang'));
    });
  });

  group('California cane rail', () {
    WallIssue protrusion(WallView w) => checkWall(w)
        .firstWhere((i) => i.text.contains('sticks out'));

    test('the protrusion finding is accessibility, with a cane rail fix', () {
      final w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      final issue = protrusion(w);
      expect(issue.access, isTrue);
      expect(issue.railFor, d.id);
      expect(issue.advice, contains('cane rail'));
      expect(issue.advice, contains('27"'));
      expect(issue.text, contains('CBC 11B-307.2'));
    });

    test('a cane rail under the display clears it', () {
      var w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      w = withCaneRail(w, d.id);
      final rail = w.items.firstWhere((i) => i.kind == WallItemKind.caneRail);
      // 4" in from the display's front, 2.67" + 4.7" off the wall.
      expect(rail.depth, closeTo(2.67 + 4.7 - 4, 1e-9));
      expect(rail.top, closeTo(27, 1e-9));
      expect(rail.x, d.x);
      expect(rail.width, d.width);
      expect(checkWall(w).where((i) => i.text.contains('sticks out')), isEmpty);
    });

    test('a rail follows its display unless locked or moved by hand', () {
      var w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      w = withCaneRail(w, d.id).resolved();
      final railId =
          w.items.firstWhere((i) => i.kind == WallItemKind.caneRail).id;
      expect(w.guardedBy(railId)?.id, d.id);

      // The display moves and gets deeper: the rail keeps up.
      w = w.withItem(w.item(d.id)!.copyWith(x: 30, depth: 6)).resolved();
      var rail = w.item(railId)!;
      expect(rail.x, 30);
      expect(rail.depth, closeTo(w.item(d.id)!.front - 4, 1e-9));

      // Locked, it stays put.
      w = w.withItem(rail.copyWith(locked: true));
      w = w.withItem(w.item(d.id)!.copyWith(x: 50)).resolved();
      expect(w.item(railId)!.x, 30);

      // Untied, it stays put too; the display going leaves it as drawn.
      w = w.withItem(w.item(railId)!.copyWith(locked: false, mountId: ''));
      w = w.withItem(w.item(d.id)!.copyWith(x: 10)).resolved();
      expect(w.item(railId)!.x, 30);
      w = withCaneRail(w, d.id).resolved();
      final tied =
          w.items.lastWhere((i) => i.kind == WallItemKind.caneRail);
      w = w.withoutItem(d.id);
      expect(w.item(tied.id)!.mountId, isEmpty);
      expect(w.item(tied.id)!.x, 10);
    });

    test('an added cane rail goes under the display that needs it', () {
      var w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      final preset =
          kWallItemPresets.firstWhere((p) => p.name == 'Cane rail').item;
      final rail = placePreset(w, preset);
      expect(rail.mountId, d.id);
      expect(rail.width, d.width);
      expect(rail.top, closeTo(27, 1e-9));
      w = w.withItem(rail);
      expect(checkWall(w).where((i) => i.railFor.isNotEmpty), isEmpty);
      // With nothing left to guard, it is the plain preset.
      expect(placePreset(w, preset).mountId, isEmpty);
    });

    test('setting the plate bottom moves the display on it', () {
      var w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final m = w.items.firstWhere((i) => i.kind == WallItemKind.mount);
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      final before = plateOf(w, m.id)!.top;
      w = withPlateBottom(w, m.id, 50).resolved();
      expect(plateOf(w, m.id)!.top, closeTo(50, 1e-9));
      expect(w.item(d.id)!.y, closeTo(d.y + 50 - before, 1e-9));
      expect(plateOf(w, m.id)!.height, closeTo(9.76, 1e-9));
    });

    test('reach findings are accessibility findings', () {
      final w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final reach = checkWall(w).firstWhere((i) => i.text.contains('48"'));
      expect(reach.access, isTrue);
      expect(reach.advice, contains('CBC 11B-308'));
    });
  });

  group('conduit and raceway', () {
    WallItem preset(String name) =>
        kWallItemPresets.firstWhere((p) => p.name.startsWith(name)).item;

    test('Wiremold and EMT come at their sizes, running up the wall', () {
      final v700 = preset('Wiremold 700');
      expect(v700.kind, WallItemKind.raceway);
      expect(v700.width, 0.75);
      expect(v700.depth, 0.66);
      expect(v700.height, 48);
      expect(preset('Conduit, 3/4" EMT').width, 0.922);
    });

    test('turning lays a run across about its center', () {
      final r = preset('Wiremold 500').copyWith(x: 100, y: 40);
      final t = turned(r);
      expect(t.width, 48);
      expect(t.height, 0.75);
      expect(t.centerX, closeTo(r.centerX, 1e-9));
      expect(t.centerY, closeTo(r.centerY, 1e-9));
      expect(turned(t).width, r.width);
    });

    test('raceway into a box is fine; across a door is not', () {
      final box = WallItem(
        id: 'B',
        kind: WallItemKind.outlet,
        x: 99,
        y: 36,
        width: 2.75,
        height: 4.5,
        depth: 0.25,
      );
      final run = preset('Wiremold 700').copyWith(id: 'R', x: 100, y: 38);
      var w = wall.withItem(box).withItem(run);
      expect(checkWall(w).where((i) => i.itemIds.contains('R')), isEmpty);
      final door = WallItem(
        id: 'D',
        kind: WallItemKind.door,
        x: 90,
        width: 36,
        height: 84,
      );
      w = w.withItem(door);
      expect(
        checkWall(w).any((i) =>
            i.level == WallIssueLevel.problem && i.itemIds.contains('R')),
        isTrue,
      );
    });
  });

  group('saving to the catalog', () {
    test('a wall item turns back into the sizes it came from', () {
      final d = wallItemFromSpec(qproSpec, model: 'TT-8624QPRO');
      final back = specFromWallItem(d);
      expect(back.holeLeft, closeTo(qproSpec.holeLeft, 1e-9));
      expect(back.holeUp, closeTo(qproSpec.holeUp, 1e-9));
      expect(back.vesaW, 800);
      expect(back.role, MountRole.display);
      final m = wallItemFromSpec(mountSpec, model: 'EPR8A50600-000');
      expect(specFromWallItem(m).toJson(), mountSpec.toJson());
    });

    test('Save to catalog writes the sizes and backs the file up first',
        () async {
      final dir = await Directory.systemTemp.createTemp('wall_catalog_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/av_devices.json');
      await file.writeAsString(jsonEncode({'devices': []}));
      final p = AppStateProvider(autoLoadSettings: false)
        ..avDevicesFilePath = file.path;
      final m = wallItemFromSpec(kSpecNewlineTiltMount,
              model: 'EPR8A50600-000')
          .copyWith(vesaMinW: 200, vesaMinH: 200);
      final r = await p.saveWallItemToCatalog(m);
      expect(r.ok, isTrue, reason: r.message);
      final saved = jsonDecode(await file.readAsString()) as Map;
      final entry = (saved['devices'] as List)
          .cast<Map>()
          .firstWhere((e) => e['model'] == 'EPR8A50600-000');
      expect(entry['mounting']['vesaMinW'], 200);
      expect(
        dir.listSync().any((f) => f.path.contains('av_devices.json.bak_')),
        isTrue,
      );
      // A model the catalog lacks is only added when asked.
      final other = m.copyWith(model: 'NEW-MOUNT');
      expect((await p.saveWallItemToCatalog(other)).ok, isFalse);
      expect((await p.saveWallItemToCatalog(other, create: true)).ok, isTrue);
      expect(p.avDeviceLibrary.templateForModel('NEW-MOUNT')?.mounting,
          isNotNull);
    });
  });

  group('hook seat', () {
    test('the hooks set where the plate sits on the arms', () {
      var w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount)
          .resolved();
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      var m = w.items.firstWhere((i) => i.kind == WallItemKind.mount);
      // Centered: the plate's top is half the plate over the VESA center.
      expect(
        hookAboveTopHoles(m, d),
        closeTo(9.76 / 2 - 400 / 25.4 / 2, 1e-9),
      );
      final displayY = d.y;
      m = withHookAboveTopHoles(m, d, 3);
      w = w.withItem(m).resolved();
      m = w.item(m.id)!;
      expect(hookAboveTopHoles(m, w.item(d.id)), closeTo(3, 1e-9));
      final topHoles = w.item(d.id)!.vesaCenterY + 400 / 25.4 / 2;
      expect(plateOf(w, m.id)!.bottom, closeTo(topHoles + 3, 1e-9));
      // The display stays put; the plate moves.
      expect(w.item(d.id)!.y, displayY);
      // Survives a save.
      expect(WallItem.fromJson(m.toJson()).plateOffset, m.plateOffset);
      // Past the arms' ends is a warning.
      w = w.withItem(m.copyWith(plateOffset: 20));
      expect(
        checkWall(w).any((i) => i.text.contains('past the ends of its arms')),
        isTrue,
      );
    });
  });

  group('measuring points', () {
    test('VESA holes, arms and plate measure as the drawings say', () {
      final w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount)
          .resolved();
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      final m = w.items.firstWhere((i) => i.kind == WallItemKind.mount);
      WallMark mark(String id) => markById(w, id)!;

      // Low holes 14.3" up from the display's bottom, 23.25" in from its left.
      var g = markDistance(mark('${d.id}:vB'), mark('${d.id}:B'));
      // (The drawing rounds 400 mm to 15.75", so to its precision.)
      expect(g.upDown, closeTo(14.3, 0.005));
      expect(g.across, isNull);
      g = markDistance(mark('${d.id}:vL'), mark('${d.id}:L'));
      expect(g.across, closeTo(23.25, 0.005));

      // The mount's own hole rows are the display's when it hangs one.
      g = markDistance(mark('${m.id}:hB'), mark('wall:floor'));
      expect(g.upDown, closeTo(mark('${d.id}:vB').y!, 1e-9));

      // The arms sit on the holes: 800 mm apart center to center.
      g = markDistance(mark('${m.id}:armLc'), mark('${m.id}:armRc'));
      expect(g.across, closeTo(800 / 25.4, 1e-9));
      g = markDistance(mark('${m.id}:armLc'), mark('${d.id}:vL'));
      expect(g.across, closeTo(0, 1e-9));

      // Plate end to the left arm's outer edge, and to the display's end.
      g = markDistance(mark('${m.id}:plateL'), mark('${m.id}:armLo'));
      expect(g.across, closeTo((37.79 - 800 / 25.4 - 1.45) / 2, 1e-9));
      g = markDistance(mark('${m.id}:plateL'), mark('${d.id}:L'));
      expect(g.across, greaterThan(0));

      // The plate's top above the floor.
      g = markDistance(mark('${m.id}:plateT'), mark('wall:floor'));
      expect(g.upDown, closeTo(plateOf(w, m.id)!.bottom, 1e-9));
    });

    test('a single hole measures to the ceiling, floor and wall end', () {
      final w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount)
          .resolved();
      final d = w.items.firstWhere((i) => i.kind == WallItemKind.display);
      final m = w.items.firstWhere((i) => i.kind == WallItemKind.mount);
      WallMark mark(String id) => markById(w, id)!;
      final tl = mark('${d.id}:pTL');
      expect(tl.label, '${d.name}: VESA top left hole');
      expect(tl.x, mark('${d.id}:vL').x);
      expect(tl.y, mark('${d.id}:vT').y);
      var g = markDistance(tl, mark('wall:ceiling'));
      expect(g.upDown, closeTo(w.heightIn - tl.y!, 1e-9));
      g = markDistance(mark('${d.id}:pBR'), mark('wall:floor'));
      expect(g.upDown, closeTo(mark('${d.id}:vB').y!, 1e-9));
      g = markDistance(mark('${m.id}:pBL'), mark('wall:left'));
      expect(g.across, closeTo(mark('${d.id}:vL').x!, 1e-9));
    });
  });

  group('measuring', () {
    test('clear space and centers between two items', () {
      const door = WallItem(
        id: 'D', kind: WallItemKind.door, x: 10, width: 36, height: 84);
      const box = WallItem(
        id: 'B', kind: WallItemKind.outlet, x: 70, y: 90, width: 4, height: 4);
      final g = gapBetween(door, box);
      expect(g.across, 24);
      expect(g.upDown, 6);
      expect(g.centersAcross, 44);
      expect(g.centersUpDown, 50);
      expect(gapBetween(box, door).across, 24);
      // Side by side at the same height: no gap up and down.
      expect(gapBetween(door, door.copyWith(id: 'E', x: 50)).upDown, 0);
    });
  });

  group('in the room', () {
    AppStateProvider room() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      return p;
    }

    testWidgets('zoom in, fit, and the key on and off the drawing',
        (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall');
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wall_zoom_in')));
      await tester.pump();
      expect(find.text('125%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wall_zoom_fit')));
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.text('Key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Put the key on the drawing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Key'));
      await tester.pumpAndSettle();
      // On now; and back off, so other tests start without it.
      await tester.tap(find.text('Take the key off the drawing'));
      await tester.pumpAndSettle();
    });

    testWidgets('the Key button explains the notation', (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall');
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Key'));
      await tester.pumpAndSettle();
      expect(find.text('Notation'), findsOneWidget);
      expect(find.text('CLG'), findsOneWidget);
    });

    testWidgets('Measure points reads VESA low holes to the display bottom',
        (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall');
      p.updateWallView(
        withDisplayOnMount(
            p.avWallViews.single, kNewlineQPro86, kNewlineTiltMount),
        'Add the Q Pro',
      );
      final d = p.avWallViews.single.items
          .firstWhere((i) => i.kind == WallItemKind.display);
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('wall_item_row_${d.id}')));
      await tester.pump();
      Future<void> pick(String key, String label) async {
        final f = find.byKey(ValueKey(key));
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await pick('wall_mark_from_', '${d.name}: VESA low holes');
      await pick('wall_mark_to_', '${d.name}: bottom');
      final result = tester.widget<Text>(
        find.byKey(const ValueKey('wall_mark_result')),
      );
      final w = p.avWallViews.single;
      final low = markById(w, '${d.id}:vB')!.y! - w.item(d.id)!.y;
      expect(result.data, 'Up and down: ${inchesLabel(low)}');
    });

    testWidgets('Measure to reads the space from a door to a display',
        (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall');
      var w = p.avWallViews.single;
      w = w.withItem(placePreset(w, kNewlineQPro86, atX: 60));
      w = w.withItem(const WallItem(
        id: 'D', kind: WallItemKind.door, label: 'Door', x: 6, width: 36,
        height: 84));
      p.updateWallView(w, 'Add both');
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wall_item_row_D')));
      await tester.pump();
      final pick = find.byKey(const ValueKey('wall_measure_to_'));
      await tester.ensureVisible(pick);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Newline Q Pro 86"').last);
      await tester.pumpAndSettle();
      final result = tester.widget<Text>(
        find.byKey(const ValueKey('wall_measure_result')),
      );
      expect(result.data, contains('Clear across: 1\' 6"'));
    });

    testWidgets('a wall is sized in mm, and the box keeps its length on a '
        'change of unit', (tester) async {
      addTearDown(() => wallLengthUnit = LengthUnit.feet);
      final p = room();
      p.addWallView(name: 'Front wall');
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wall_edit')));
      await tester.pumpAndSettle();
      final before = p.avWallViews.single.widthIn;
      await tester.tap(find.byKey(const ValueKey('wall_dialog_units')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Millimeters').last);
      await tester.pumpAndSettle();
      expect(wallLengthUnit, LengthUnit.mm);
      final box = tester.widget<TextField>(
        find.byKey(const ValueKey('wall_width')),
      );
      expect(parseInchesText(box.controller!.text), closeTo(before, 0.01));
      await tester.enterText(find.byKey(const ValueKey('wall_width')), '3000');
      await tester.pump();
      expect(find.textContaining('300 cm'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wall_dialog_ok')));
      await tester.pumpAndSettle();
      expect(p.avWallViews.single.widthIn, closeTo(3000 / 25.4, 1e-6));
    });

    testWidgets("a mount's panel picks the display it holds", (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall');
      var w = p.avWallViews.single;
      w = w.withItem(placePreset(w, kNewlineQPro86));
      w = w.withItem(placePreset(w, kNewlineTiltMount, atX: 0));
      p.updateWallView(w, 'Add both');
      final m = p.avWallViews.single.items
          .firstWhere((i) => i.kind == WallItemKind.mount);
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('wall_item_row_${m.id}')));
      await tester.pump();
      final holds = find.byKey(const ValueKey('wall_field_holds'));
      await tester.ensureVisible(holds);
      await tester.tap(holds);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Newline Q Pro 86"').last);
      await tester.pumpAndSettle();
      final d = p.avWallViews.single.items
          .firstWhere((i) => i.kind == WallItemKind.display);
      expect(d.mountId, m.id);
      expect(find.byKey(const ValueKey('wall_mount_armMax')), findsOneWidget);
    });

    testWidgets('accessibility findings have their own box and a cane rail button',
        (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall');
      p.updateWallView(
        withDisplayOnMount(p.avWallViews.single, kNewlineQPro86, kNewlineTiltMount),
        'Add the Q Pro',
      );
      final d = p.avWallViews.single.items
          .firstWhere((i) => i.kind == WallItemKind.display);
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      final box = find.byKey(const ValueKey('wall_access_box'));
      expect(box, findsOneWidget);
      expect(
        find.descendant(of: box, matching: find.textContaining('sticks out')),
        findsOneWidget,
      );
      final add = find.byKey(ValueKey('wall_add_cane_rail_${d.id}'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pump();
      expect(
        p.avWallViews.single.items.where((i) => i.kind == WallItemKind.caneRail),
        hasLength(1),
      );
      expect(find.textContaining('sticks out'), findsNothing);
    });
  });

  group('built-in mounts', () {
    test('the drawn products carry their wall mounting sizes', () {
      final lib = AvDeviceLibrary.builtIn();
      for (final model in [
        'TT-8624QPRO',
        'EPR8A50600-000',
        'XSM1U',
        'XTM1U',
        'FCAV1U',
        '60-612',
      ]) {
        expect(lib.templateForModel(model)?.mounting?.hasSize, isTrue,
            reason: model);
      }
      expect(lib.templateForModel('TT-8624QPRO')!.mounting!.role,
          MountRole.display);
      expect(lib.templateForModel('XTM1U')!.mounting!.maxTilt, 12);
    });

    test('a catalog file entry with no sizes takes the built-in ones', () async {
      final dir = Directory.systemTemp.createTempSync('rcb_mounts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/av_devices.json')
        ..writeAsStringSync(jsonEncode({
          'devices': [
            {
              'model': 'XTM1U',
              'manufacturer': 'Chief',
              'category': 'Rack hardware',
              'price': 258.71,
              'ports': [],
            },
            {
              'model': '60-612',
              'mounting': {'role': 'mount', 'w': 30, 'h': 20},
              'ports': [],
            },
          ],
        }));
      final lib = await AvDeviceLibrary.load(explicitPath: file.path);
      final xtm = lib.templateForModel('XTM1U')!;
      expect(xtm.price, 258.71);
      expect(xtm.category, 'Rack hardware');
      expect(xtm.mounting, kSpecChiefXTM1U);
      // Sizes the file has stay its own.
      expect(lib.templateForModel('60-612')!.mounting!.width, 30);
    });

    test('the Fusion mounts take the Q Pro; the Neo-Flex is too narrow', () {
      List<String> fit(String presetName) {
        final p = kWallItemPresets.firstWhere((p) => p.name == presetName);
        final w = withDisplayOnMount(wall, kNewlineQPro86, p.item);
        return [
          for (final i in checkWall(w))
            if (i.level == WallIssueLevel.problem) i.text,
        ];
      }

      expect(fit('Chief Fusion fixed mount (XSM1U)'), isEmpty);
      expect(fit('Chief Fusion tilt mount (XTM1U)'), isEmpty);
      expect(fit('Ergotron Neo-Flex tilt mount (60-612)'), isNotEmpty);
    });
  });

  group('mount limits', () {
    List<WallIssue> found(WallItem mount, {double lb = 0}) {
      final d = kNewlineQPro86.copyWith(weightLb: lb);
      return checkWall(withDisplayOnMount(wall, d, mount));
    }

    test('a mount with no limits says it cannot check them', () {
      final bare = kNewlineTiltMount.copyWith(capacityLb: 0, vesaW: 0, vesaH: 0);
      final notes = [
        for (final i in found(bare, lb: 120))
          if (i.level == WallIssueLevel.note) i.text,
      ];
      expect(notes.any((t) => t.contains('no weight limit set')), isTrue);
      expect(notes.any((t) => t.contains('no VESA range set')), isTrue);
    });

    test('a display over the weight limit or VESA range is a problem', () {
      final small = kNewlineTiltMount.copyWith(capacityLb: 100, vesaW: 600);
      final problems = [
        for (final i in found(small, lb: 120))
          if (i.level == WallIssueLevel.problem) i.text,
      ];
      expect(problems.any((t) => t.contains('100 lb limit')), isTrue);
      expect(problems.any((t) => t.contains('wider than')), isTrue);
    });

    test('a catalog entry with a role and no size gets a stand-in size', () {
      final s = withStandInSize(const WallMountSpec(role: MountRole.mount, vesaW: 600));
      expect(s.hasSize, isTrue);
      expect(s.vesaW, 600);
      expect(withStandInSize(const WallMountSpec(role: MountRole.display)).width,
          57.3);
    });

    testWidgets('the Walls catalog picker lists a mount with no size yet',
        (tester) async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      p.avDeviceLibrary.upsert(const AvDeviceTemplate(
        model: 'Bare mount 1',
        category: 'Mount / bracket',
        mounting: WallMountSpec(role: MountRole.mount, capacityLb: 150),
        ports: [],
      ));
      p.addWallView(name: 'Front wall');
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: WallElevationView())),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wall_add_item')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wall_add_catalog')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('wall_catalog_search')), 'Bare mount');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wall_catalog_Bare mount 1')));
      await tester.pumpAndSettle();
      final m = p.avWallViews.single.items.single;
      expect(m.kind, WallItemKind.mount);
      expect(m.width, 32);
      expect(m.capacityLb, 150);
      // Its panel opens on what it takes.
      expect(find.text('What it takes'), findsOneWidget);
      expect(find.byKey(const ValueKey('wall_mount_vesa_preset')), findsOneWidget);
    });
  });
}
