import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/room_sidecar.dart';
import 'package:extron_configurator/tab_export.dart' show wallReportSections;
import 'package:extron_configurator/wall_elevation.dart';
import 'package:extron_configurator/wall_elevation_view.dart';

/// The Walls tab: a wall straight on, a display on its mount, and the check
/// for clashes, mount fit and things sticking out into the room.
void main() {
  const wall = WallView(id: 'WALL_1', name: 'Front wall', widthIn: 240, heightIn: 108);

  /// The Q Pro 86 on the Newline mount, centered, 36" off the floor.
  WallView qpro() => withDisplayOnMount(wall, kNewlineQPro86, kNewlineTiltMount);

  WallItem display(WallView w) =>
      w.items.firstWhere((i) => i.kind == WallItemKind.display);
  WallItem mount(WallView w) =>
      w.items.firstWhere((i) => i.kind == WallItemKind.mount);

  List<String> texts(WallView w, WallIssueLevel level) => [
    for (final i in checkWall(w))
      if (i.level == level) i.text,
  ];

  group('lengths', () {
    test('a bare number is inches; feet need a mark', () {
      expect(parseInchesText('36'), 36);
      expect(parseInchesText('36.5"'), 36.5);
      expect(parseInchesText("3'"), 36);
      expect(parseInchesText("3' 6\""), 42);
      expect(parseInchesText('3ft 6in'), 42);
      expect(parseInchesText('-2'), -2);
      expect(parseInchesText('abc'), isNull);
      expect(inchesLabel(42), "3' 6\"");
      expect(inchesLabel(7.6), '7.6"');
      expect(inchesLabel(36), "3'");
    });

    test('lengths show and read back in the unit picked', () {
      addTearDown(() => wallLengthUnit = LengthUnit.feet);
      expect(inchesLabel(42, unit: LengthUnit.inches), '42"');
      expect(inchesLabel(31.49, unit: LengthUnit.inches), '31.49"');
      expect(inchesLabel(42, unit: LengthUnit.cm), '106.7 cm');
      expect(inchesLabel(42, unit: LengthUnit.mm), '1067 mm');
      expect(parseInchesText('1016 mm'), closeTo(40, 1e-9));
      expect(parseInchesText('101.6cm'), closeTo(40, 1e-9));
      expect(parseInchesText('1 m'), closeTo(39.370, 1e-3));
      wallLengthUnit = LengthUnit.mm;
      expect(inchesLabel(42), '1067 mm');
      expect(parseInchesText('254'), closeTo(10, 1e-9));
      expect(parseInchesText('10"'), 10);
      expect(parseInchesText(lengthFieldText(37.79)), closeTo(37.79, 0.005));
      wallLengthUnit = LengthUnit.cm;
      expect(parseInchesText('25.4'), closeTo(10, 1e-9));
      expect(parseInchesText(lengthFieldText(37.79)), closeTo(37.79, 0.005));
    });
  });

  group('display on its mount', () {
    test('the mount sits on the VESA center and pushes the display out', () {
      final w = qpro();
      final d = display(w), m = mount(w);
      expect(d.mountId, m.id);
      expect(d.standoff, closeTo(2.67, 1e-9));
      expect(d.front, closeTo(2.67 + 4.7, 1e-9));
      // VESA center 22.175" above the display's bottom.
      expect(m.centerY, closeTo(d.y + 14.3 + 15.75 / 2, 1e-9));
      expect(m.centerX, closeTo(d.vesaCenterX, 1e-9));
    });

    test('the Q Pro holes sit where its drawing puts them', () {
      final d = display(qpro());
      final low = d.vesaHoles.first;
      // 800 mm is 31.496", a hair over the drawing's 31.49".
      expect(low.dx - d.x, closeTo(23.25, 0.01));
      expect(low.dy - d.y, closeTo(14.3, 0.01));
      expect(d.vesaHoles.last.dx - d.vesaHoles.first.dx, closeTo(800 / 25.4, 1e-9));
      expect(d.vesaHoles.last.dy - d.vesaHoles.first.dy, closeTo(400 / 25.4, 1e-9));
      expect(d.toJson()['vesaLeft'], closeTo(38.995, 1e-9));
    });

    test('an off-center pattern pulls the mount with it', () {
      var w = qpro();
      w = w.withItem(display(w).copyWith(vesaLeft: 30, vesaUp: 20));
      final d = display(w), m = mount(w);
      expect(m.centerX, closeTo(d.x + 30, 1e-9));
      expect(m.centerY, closeTo(d.y + 20, 1e-9));
    });

    test('holes off the back of the display are a problem', () {
      var w = qpro();
      w = w.withItem(display(w).copyWith(vesaLeft: 5));
      expect(texts(w, WallIssueLevel.problem).join(), contains('VESA holes'));
      expect(texts(w, WallIssueLevel.warning).join(), contains('shows past'));
    });

    test('moving the display takes the mount with it', () {
      final w = qpro();
      final d = display(w);
      final moved = w.withItem(d.copyWith(x: d.x + 10, y: d.y + 6));
      expect(mount(moved).centerX, closeTo(display(moved).vesaCenterX, 1e-9));
      expect(mount(moved).centerY, closeTo(display(moved).vesaCenterY, 1e-9));
    });

    test('the Q Pro fits the Newline mount', () {
      final issues = checkWall(qpro());
      expect(
        issues.where((i) => i.text.contains('VESA') || i.text.contains('arms')),
        isEmpty,
      );
      // No weight on the drawing, so it says it could not check it.
      expect(texts(qpro(), WallIssueLevel.note).join(),
          contains('no weight set'));
    });

    test('a pattern or weight past the mount is a problem', () {
      var w = qpro();
      w = w.withItem(display(w).copyWith(vesaW: 1000, weightLb: 300));
      final problems = texts(w, WallIssueLevel.problem).join('\n');
      expect(problems, contains('wider than'));
      expect(problems, contains('over'));
    });

    test('tilting past the mount is a problem; within it is not', () {
      var w = qpro();
      w = w.withItem(display(w).copyWith(tiltDeg: 8));
      expect(texts(w, WallIssueLevel.problem).join(), isNot(contains('tilted')));
      expect(display(w).front, greaterThan(7.6));
      w = w.withItem(display(w).copyWith(tiltDeg: 15));
      expect(texts(w, WallIssueLevel.problem).join(), contains('tilted'));
    });

    test('removing the mount lets the display back onto the wall', () {
      final w = qpro();
      final left = w.withoutItem(mount(w).id).resolved();
      expect(display(left).mountId, isEmpty);
      expect(display(left).standoff, 0);
    });
  });

  group('clashes', () {
    test('a box under the mount plate runs into it', () {
      var w = qpro();
      final m = mount(w);
      w = w.withItem(WallItem(
        id: w.nextItemId(),
        kind: WallItemKind.outlet,
        label: 'Power',
        x: m.centerX - 2.25,
        y: m.centerY - 2.25,
        width: 4.5,
        height: 4.5,
        depth: 0.3,
      ));
      expect(texts(w, WallIssueLevel.problem).join(),
          contains('runs into Power'));
    });

    test('a box behind the display, clear of the plate, is fine', () {
      var w = qpro();
      final d = display(w);
      w = w.withItem(WallItem(
        id: w.nextItemId(),
        kind: WallItemKind.outlet,
        label: 'Power',
        x: d.x + 6,
        y: d.y + 4,
        width: 4.5,
        height: 4.5,
        depth: 0.3,
      ));
      final all = checkWall(w).map((i) => i.text).join('\n');
      expect(all, isNot(contains('Power')));
      expect(all, isNot(contains('No power or data box')));
    });

    test('anything over a door is a problem; a fire alarm too', () {
      var w = qpro();
      final d = display(w);
      w = w.withItem(WallItem(
        id: w.nextItemId(),
        kind: WallItemKind.door,
        label: 'Door',
        x: d.right - 10,
        width: 36,
        height: 84,
        depth: 0,
      ));
      w = w.withItem(WallItem(
        id: w.nextItemId(),
        kind: WallItemKind.fireAlarm,
        label: 'Strobe',
        x: d.x + 2,
        y: d.top - 6,
        width: 5,
        height: 5.5,
        depth: 2.5,
      ));
      final problems = texts(w, WallIssueLevel.problem).join('\n');
      expect(problems, contains('over the door'));
      expect(problems, contains('Strobe'));
    });

    test('past the end of the wall or through the ceiling', () {
      var w = qpro();
      w = w.withItem(display(w).copyWith(x: 200, y: 70));
      final problems = texts(w, WallIssueLevel.problem).join('\n');
      expect(problems, contains('past the end of the wall'));
      expect(problems, contains('above the ceiling'));
    });
  });

  group('sticking out', () {
    test('7.6" out with its bottom at 36" is past the 4" limit', () {
      expect(texts(qpro(), WallIssueLevel.warning).join(),
          contains('sticks out'));
    });

    test('a low credenza under it is found by a cane first', () {
      var w = qpro();
      final d = display(w);
      w = w.withItem(WallItem(
        id: w.nextItemId(),
        kind: WallItemKind.credenza,
        label: 'Credenza',
        x: d.x - 2,
        width: d.width + 4,
        height: 26,
        depth: 18,
      ));
      expect(texts(w, WallIssueLevel.warning).join(),
          isNot(contains('sticks out')));
    });

    test('above 80" is overhead, not in the way', () {
      var w = qpro();
      w = w.withItem(display(w).copyWith(y: 81));
      expect(texts(w, WallIssueLevel.warning).join(),
          isNot(contains('sticks out')));
    });
  });

  test('touch area above 48" is noted', () {
    final notes = texts(qpro(), WallIssueLevel.note).join('\n');
    expect(notes, contains('above the 48" reach limit'));
  });

  test('a wall survives JSON', () {
    final w = qpro();
    final back = WallView.fromJson(w.toJson());
    expect(back.toJson(), w.toJson());
  });

  test('walls are saved with the floor plans', () {
    expect(kRoomSidecarKeys[RoomSidecarPart.floorPlans], contains('wallViews'));
  });

  group('mounting', () {
    test('each mount is tagged and placed from both ends and the floor', () {
      final w = qpro();
      final d = display(w), m = mount(w);
      final placed = mountPlacements(w);
      expect(placed, hasLength(1));
      final p = placed.single;
      expect(p.tag, 'M1');
      expect(p.display?.id, d.id);
      expect(p.fromLeft, closeTo(m.wallFootprint.center.dx, 1e-9));
      expect(p.fromLeft + p.fromRight, closeTo(240, 1e-9));
      expect(p.centerY, closeTo(d.vesaCenterY, 1e-9));
      expect(p.plateBottom, lessThan(p.plateTop));
      expect(p.holes, d.vesaHoles);
      expect(p.vesaWmm, d.vesaW);
      expect(p.offWall, closeTo(d.standoff, 1e-9));
    });

    test('tags run left to right', () {
      var w = qpro();
      final spare = placePreset(w, kNewlineTiltMount, atX: 10);
      w = w.withItem(spare);
      final placed = mountPlacements(w);
      expect(placed.map((p) => p.tag), ['M1', 'M2']);
      expect(placed.first.mount.id, spare.id);
      expect(placed.first.display, isNull);
    });

    test('the export lists the mounts first', () {
      final sections = wallReportSections([qpro()]);
      expect(sections.first.title, 'Front wall - mounting');
      expect(sections.first.rows.single.first, 'M1');
      expect(sections.first.rows.single, contains('800 x 400 mm'));
      expect(wallReportSections([wall]).first.title, isNot(contains('mounting')));
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

    test('adding, editing and undoing a wall', () {
      final p = room();
      final id = p.addWallView(name: 'Front wall', widthIn: 240, heightIn: 108);
      expect(p.avWallViews.single.id, id);
      expect(p.avFlowAsJson()['wallViews'], isA<List>());
      p.updateWallView(
        withDisplayOnMount(p.avWallViews.single, kNewlineQPro86, kNewlineTiltMount),
        'Add the Q Pro',
      );
      expect(p.avWallViews.single.items, hasLength(2));
      expect(p.undoAvFlow(AvUndoScope.floorPlans), 'Add the Q Pro');
      expect(p.avWallViews.single.items, isEmpty);
      p.redoAvFlow(AvUndoScope.floorPlans);
      expect(p.avWallViews.single.items, hasLength(2));
      p.removeWallView(id);
      expect(p.avWallViews, isEmpty);
    });

    testWidgets('the side panel scrolls past the chat button', (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall');
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(padding: EdgeInsets.only(bottom: 88)),
              child: Scaffold(body: WallElevationView()),
            ),
          ),
        ),
      );
      await tester.pump();
      final list = tester.widget<ListView>(find.byType(ListView).last);
      expect((list.padding as EdgeInsets).bottom, 12 + 88);
    });

    testWidgets('Mounting draws the mounting layout and back', (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall', widthIn: 240, heightIn: 108);
      p.updateWallView(
        withDisplayOnMount(p.avWallViews.single, kNewlineQPro86, kNewlineTiltMount),
        'Add the Q Pro',
      );
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
      await tester.tap(find.text('Mounting'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final mode = tester.widget<SegmentedButton<bool>>(
        find.byKey(const ValueKey('wall_view_mode')),
      );
      expect(mode.selected, {true});
      // Picking still works on the mounting layout.
      final d = p.avWallViews.single.items
          .firstWhere((i) => i.kind == WallItemKind.display);
      await tester.tap(find.byKey(ValueKey('wall_item_row_${d.id}')));
      await tester.pump();
      expect(find.byKey(const ValueKey('wall_field_y')), findsOneWidget);
      await tester.tap(find.text('Elevation'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the tab draws the wall and lists the check', (tester) async {
      final p = room();
      p.addWallView(name: 'Front wall', widthIn: 240, heightIn: 108);
      p.updateWallView(
        withDisplayOnMount(p.avWallViews.single, kNewlineQPro86, kNewlineTiltMount),
        'Add the Q Pro',
      );
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
      expect(find.byKey(const ValueKey('wall_picker')), findsOneWidget);
      expect(find.text('Check'), findsOneWidget);
      expect(find.textContaining('sticks out'), findsOneWidget);

      // Picking the display opens its editor.
      final d = p.avWallViews.single.items
          .firstWhere((i) => i.kind == WallItemKind.display);
      await tester.tap(find.byKey(ValueKey('wall_item_row_${d.id}')));
      await tester.pump();
      expect(find.byKey(const ValueKey('wall_field_y')), findsOneWidget);

      // Typing a new height moves it.
      await tester.enterText(find.byKey(const ValueKey('wall_field_y')), '48');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(
        p.avWallViews.single.item(d.id)!.y,
        48,
      );

      // The display's panel sets where its holes are and its mount's size.
      Future<void> type(String key, String text) async {
        final f = find.byKey(ValueKey(key));
        await tester.ensureVisible(f);
        await tester.enterText(f, text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      await type('wall_field_vesaHoleLeft', '20');
      final moved = p.avWallViews.single.item(d.id)!;
      expect(moved.vesaHoles.first.dx - moved.x, closeTo(20, 1e-9));
      await type('wall_mount_w', '30');
      final m = p.avWallViews.single.items
          .firstWhere((i) => i.kind == WallItemKind.mount);
      expect(m.width, 30);
      expect(m.centerX, closeTo(moved.vesaCenterX, 1e-9));
    });
  });
}
