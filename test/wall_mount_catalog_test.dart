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
    width: 34.6,
    height: 16.9,
    depth: 2.9,
    plateHeight: 7.9,
    armWidth: 1.1,
    armSpanMax: 33.5,
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
      expect(m.armDrawWidth, 1.1);
      expect(m.armSpanMax, 33.5);
      expect(m.plateHeight, 7.9);
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
      expect(w.item(d.id)!.standoff, closeTo(2.9, 1e-9));
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
      expect(rail.depth, closeTo(3.6, 1e-9));
      expect(rail.top, closeTo(27, 1e-9));
      expect(rail.x, d.x);
      expect(rail.width, d.width);
      expect(checkWall(w).where((i) => i.text.contains('sticks out')), isEmpty);
    });

    test('reach findings are accessibility findings', () {
      final w = withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);
      final reach = checkWall(w).firstWhere((i) => i.text.contains('48"'));
      expect(reach.access, isTrue);
      expect(reach.advice, contains('CBC 11B-308'));
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
