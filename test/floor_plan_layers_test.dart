import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_sidecar.dart' show AvUndoScope;

/// A cabling set is issued one trade at a time: the network contractor gets
/// the network sheet, the AV contractor gets theirs, and neither has to read
/// around the other's runs. So the plan draws the runs it knows about and can
/// show one cable type at a time.
void main() {
  AvNode device(String id, String locationId, SignalType signal) => AvNode(
    id: id,
    label: id,
    model: '',
    pos: Offset.zero,
    locationId: locationId,
    ports: [
      AvPort(
        id: 'p1',
        label: 'P1',
        signal: signal,
        direction: PortDirection.bidirectional,
        side: PortSide.right,
      ),
    ],
  );

  /// Two locations placed ON THE SHEET with a network run and a DTP run
  /// between them, plus a screen control run on the same pair.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final sheet = p.addFloorPlanSheet(name: 'Level 1');
    p.addAvLocation(
      const RoomLocation(id: 'LOC_1', name: 'Instructor station'),
    );
    p.addAvLocation(const RoomLocation(id: 'LOC_2', name: 'Equipment rack'));
    // A marker belongs to the SHEET, not to the room's location list.
    p.moveAvLocationMarker(sheet.id, 'LOC_1', const Offset(200, 200));
    p.moveAvLocationMarker(sheet.id, 'LOC_2', const Offset(600, 400));

    for (final (i, signal) in [
      SignalType.network,
      SignalType.hdbaset,
    ].indexed) {
      p.addAvNode(device('A$i', 'LOC_1', signal));
      p.addAvNode(device('B$i', 'LOC_2', signal));
      p.addAvCable(
        fromNodeId: 'A$i',
        fromPortId: 'p1',
        toNodeId: 'B$i',
        toPortId: 'p1',
        signal: signal,
      );
    }

    p.addAvScreenSwitch(
      const ScreenSwitch(
        id: '',
        label: 'Front screen',
        startLocationId: 'LOC_1',
        endLocationId: 'LOC_2',
        cableType: 'Cat 5e',
      ),
    );
    return p;
  }

  /// One run, both ends placed and nothing in the way, so its route is the
  /// straight line between the two markers and the middle of that line is on
  /// it — which is what lets a test click the run the way a user does.
  AppStateProvider oneRunRoom() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final sheet = p.addFloorPlanSheet(name: 'Level 1');
    p.addAvLocation(const RoomLocation(id: 'LOC_1', name: 'Lectern'));
    p.addAvLocation(const RoomLocation(id: 'LOC_2', name: 'Rack'));
    p.moveAvLocationMarker(sheet.id, 'LOC_1', const Offset(200, 200));
    p.moveAvLocationMarker(sheet.id, 'LOC_2', const Offset(700, 200));
    p.addAvNode(device('A', 'LOC_1', SignalType.network));
    p.addAvNode(device('B', 'LOC_2', SignalType.network));
    p.addAvCable(
      fromNodeId: 'A',
      fromPortId: 'p1',
      toNodeId: 'B',
      toPortId: 'p1',
      signal: SignalType.network,
    );
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: FloorPlanView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a layer chip per cable type that lands on the plan', (
    tester,
  ) async {
    final p = room();
    await pump(tester, p);

    expect(find.text('Cable runs'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Off'), findsOneWidget);
    // Named the way the cabling drawing names them.
    expect(find.byKey(const ValueKey('plan_layer_Network')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan_layer_AV cabling')), findsOneWidget);
    // The screen control run is cable somebody pulls too, and it is on the
    // sheet under whatever it was specified as.
    expect(find.byKey(const ValueKey('plan_layer_Cat 5e')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a layer leaves the others off the sheet', (
    tester,
  ) async {
    final p = room();
    await pump(tester, p);

    await tester.tap(find.byKey(const ValueKey('plan_layer_Network')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('plan_layer_Network')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('plan_layer_AV cabling')),
          )
          .selected,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a room with nothing placed grows no layer bar', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Bare'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    await pump(tester, p);

    expect(find.text('Cable runs'), findsNothing);
  });

  testWidgets('a run with one end off the sheet still leaves the page', (
    tester,
  ) async {
    // One end placed is enough to draw something honest: the run heads off the
    // edge as a squiggle labelled with where it is going, which is what a pull
    // to the IDF actually does. It is therefore NOT one of the runs the bar
    // reports as missing — a plan that quietly leaves out half the pulls is
    // worse than one that says how many it left out, but a plan that says it
    // left out runs it has drawn is worse still.
    final p = room();
    p.removeAvLocationMarker(p.avFloorPlans.single.id, 'LOC_2');
    await pump(tester, p);

    expect(find.textContaining('not on this sheet'), findsNothing);
    // The cables are still on the layer bar, because they are still drawn.
    expect(find.text('Cable runs'), findsOneWidget);
  });

  testWidgets('runs with NEITHER end on the sheet are counted, not hidden', (
    tester,
  ) async {
    // Nowhere to start the line from, so the honest thing is to say how many
    // were left out rather than invent where the cable goes.
    final p = room();
    final sheet = p.avFloorPlans.single.id;
    p.removeAvLocationMarker(sheet, 'LOC_1');
    p.removeAvLocationMarker(sheet, 'LOC_2');
    await pump(tester, p);

    expect(find.textContaining('not on this sheet'), findsOneWidget);
  });

  testWidgets('a second sheet starts empty and is placed on its own', (
    tester,
  ) async {
    // The whole point of a second sheet: its own image, its own callouts and
    // its own markers. Before, every sheet redrew the first sheet's
    // coordinates, so a Level 2 plan came up pre-scribbled with Level 1.
    final p = room();
    final level2 = p.addFloorPlanSheet(name: 'Level 2');
    expect(level2.markers, isEmpty);

    await pump(tester, p);
    // Nothing lands on the new sheet, so every run is reported missing.
    expect(find.textContaining('not on this sheet'), findsOneWidget);

    p.moveAvLocationMarker(level2.id, 'LOC_1', const Offset(50, 60));
    // Level 1 keeps its own coordinates for the same location.
    expect(
      p.avFloorPlans.first.markerFor('LOC_1'),
      const Offset(200, 200),
    );
    expect(p.avFloorPlanById(level2.id)!.markerFor('LOC_1'),
        const Offset(50, 60));
  });

  group('a run keeps off what is already printed', () {
    test('a marker is its dot AND the name under it', () {
      // The name is what makes the dot mean anything, so it is part of what a
      // cable line has to go round. A box drawn round the dot alone let runs
      // scribble straight through the labels.
      final bare = locationMarkerBounds(const Offset(300, 200), '');
      final named = locationMarkerBounds(
        const Offset(300, 200),
        'Instructor station floor box',
      );

      expect(named.height, greaterThan(bare.height));
      expect(named.width, greaterThan(bare.width));
      // The dot still sits on the coordinates it was given, whatever the name
      // under it measures.
      expect(named.center.dx, closeTo(300, 0.01));
      expect(named.top, bare.top);
    });

    test('the plate makes room for the zone badge printed on it', () {
      // The glyph is drawn INSIDE the plate, so the box a run keeps off has to
      // include it. Measured on the words alone, a run could come in over the
      // icon that says whether this is a ceiling drop or a wall box.
      final words = TextPainter(
        text: const TextSpan(
          text: 'Ceiling mic',
          style: TextStyle(fontSize: kLocationLabelFontSize),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
      )..layout(maxWidth: kLocationLabelWidth);
      final plate = locationLabelBounds(const Offset(300, 200), 'Ceiling mic')!;

      expect(plate.width - words.width, greaterThan(kLocationZoneBadgeWidth));
      expect(plate.height, greaterThanOrEqualTo(kLocationZoneIconSize));
      // And it is still centred on the dot, badge and all.
      expect(plate.center.dx, closeTo(300, 0.01));
    });

    test('a run steps round a label instead of crossing it', () {
      final label = locationMarkerBounds(const Offset(400, 300), 'Ceiling mic');
      final route = latticeRoute(
        const Offset(200, 300),
        const Offset(600, 300),
        [label],
      );

      expect(route, isNotNull);
      // It turned rather than running straight through.
      expect(route!.length, greaterThan(2));
      expect(polylineHitsAny(route, [label]), isFalse);
    });

    test('nothing in the way leaves the run straight', () {
      // A cabling sheet reads best when a run that CAN be a straight line is
      // one. Dodging is for when there is something to dodge.
      final route = latticeRoute(
        const Offset(200, 300),
        const Offset(600, 300),
        const [],
      );
      expect(route, [const Offset(200, 300), const Offset(600, 300)]);
    });
  });

  /// The key's "mounting surface" section is a legend for a glyph that has to
  /// actually be on the drawing. It listed a ceiling icon and a wall icon while
  /// every marker on the sheet was the same blue dot, which left the reader no
  /// way to tell a ceiling drop from a wall box without knowing the room.
  group('the zone glyph on a marker', () {
    AppStateProvider placed() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      final sheet = p.addFloorPlanSheet(name: 'Level 1');
      p.addAvLocation(
        const RoomLocation(
          id: 'LOC_1',
          name: 'Speaker 1',
          zone: RoomZone.ceiling,
          callout: 'H',
        ),
      );
      p.addAvLocation(
        const RoomLocation(
          id: 'LOC_2',
          name: 'Wall switch',
          zone: RoomZone.wall,
          callout: 'M',
        ),
      );
      p.moveAvLocationMarker(sheet.id, 'LOC_1', const Offset(200, 200));
      p.moveAvLocationMarker(sheet.id, 'LOC_2', const Offset(600, 400));
      return p;
    }

    /// The icon drawn inside a marker, found through the tooltip that names it
    /// so the key's own copy of the same glyph is not what gets counted.
    Finder onMarker(String name, IconData icon) => find.descendant(
      of: find.ancestor(
        of: find.text(name),
        matching: find.byType(Tooltip),
      ),
      matching: find.byIcon(icon),
    );

    testWidgets('is the one its row in the key explains', (tester) async {
      final p = placed();
      await pump(tester, p);

      // The key says what the surfaces on this sheet are...
      expect(find.text('Mounting surface'.toUpperCase()), findsOneWidget);
      expect(find.text('Ceiling'), findsOneWidget);
      expect(find.text('Wall'), findsOneWidget);

      // ...and each marker carries the glyph its row is about.
      expect(onMarker('Speaker 1', kRoomZoneIcons[RoomZone.ceiling]!),
          findsOneWidget);
      expect(onMarker('Wall switch', kRoomZoneIcons[RoomZone.wall]!),
          findsOneWidget);
      // Not each other's.
      expect(onMarker('Speaker 1', kRoomZoneIcons[RoomZone.wall]!), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('goes with the plate, which a nameless marker has none of', (
      tester,
    ) async {
      // [locationLabelBounds] reports no plate for a location with no name, so
      // the marker must not draw one either — a plate the routing does not
      // know about is a plate runs are drawn straight across.
      final p = placed();
      await pump(tester, p);
      final ceiling = find.byIcon(kRoomZoneIcons[RoomZone.ceiling]!);
      final withPlate = tester.widgetList(ceiling).length;

      p.updateAvLocation(p.avLocationById('LOC_1')!.copyWith(name: ''));
      await tester.pumpAndSettle();

      // One fewer: the key still explains the surface, the marker no longer
      // carries the glyph.
      expect(ceiling, findsNWidgets(withPlate - 1));
      expect(withPlate - 1, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  });

  /// How many cables are in a run is the number that changes while somebody is
  /// standing in front of the plan counting them, and it was only editable on
  /// the Cabling tab.
  group('setting a run\'s cable count from the plan', () {
    test('a click picks the run whose line it landed on', () {
      // Two pulls fanned apart the way the sheet fans them.
      final routes = {
        'a': [const Offset(0, 100), const Offset(400, 100)],
        'b': [const Offset(0, 112), const Offset(400, 112)],
      };

      expect(runIdNearest(routes, const Offset(200, 101)), 'a');
      expect(runIdNearest(routes, const Offset(200, 111)), 'b');
      // In the gap, where both are within reach, the nearer one wins — the
      // slack must never hand back the wrong one of a pair.
      expect(runIdNearest(routes, const Offset(200, 104)), 'a');
      expect(runIdNearest(routes, const Offset(200, 108)), 'b');
      // And a click on empty paper is not a click on a run.
      expect(runIdNearest(routes, const Offset(200, 300)), isEmpty);
      expect(
        runIdNearest(routes, const Offset(200, 100 - kRunTapSlack - 1)),
        isEmpty,
      );
    });

    test('it answers against the drawn route, dodges and all', () {
      // The line steps round a marker, so the straight line between its ends
      // is exactly where it is NOT.
      final routes = {
        'a': [
          const Offset(0, 100),
          const Offset(200, 100),
          const Offset(200, 300),
          const Offset(400, 300),
        ],
      };
      expect(runIdNearest(routes, const Offset(200, 200)), 'a');
      expect(runIdNearest(routes, const Offset(300, 150)), isEmpty);
    });

    testWidgets('the sheet says the runs can be clicked', (tester) async {
      final p = room();
      await pump(tester, p);
      expect(
        find.textContaining('click a run to set its cable count'),
        findsOneWidget,
      );

      // Nothing to click when the runs are turned off.
      await tester.tap(find.widgetWithText(ChoiceChip, 'Off'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('click a run to set its cable count'),
        findsNothing,
      );
    });

    testWidgets('clicking one picks it up, and its count writes through', (
      tester,
    ) async {
      final p = oneRunRoom();
      await pump(tester, p);
      final bundle = p.cablingSchematic(buildAvFlowModel(p)).bundles.single;
      expect(bundle.count, 1);

      // The plan draws at 1:1 from the top-left of its viewport, so the
      // midpoint of the two markers is where the line is.
      final origin = tester.getTopLeft(find.byType(InteractiveViewer));
      await tester.tapAt(origin + const Offset(450, 200));
      await tester.pumpAndSettle();

      expect(find.text('Lectern  \u2192  Rack'), findsOneWidget);
      await tester.enterText(
        find.byKey(ValueKey('plan_run_count_${bundle.id}')),
        '6',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Written through the same override the Cabling tab edits, so both pages
      // and the schedule report one number.
      expect(p.avCabling.counts[bundle.id], 6);
      expect(p.cablingSchematic(buildAvFlowModel(p)).bundles.single.count, 6);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clicking bare paper puts it down again', (tester) async {
      final p = oneRunRoom();
      await pump(tester, p);
      final origin = tester.getTopLeft(find.byType(InteractiveViewer));

      await tester.tapAt(origin + const Offset(450, 200));
      await tester.pumpAndSettle();
      expect(find.text('Lectern  \u2192  Rack'), findsOneWidget);

      await tester.tapAt(origin + const Offset(60, 700));
      await tester.pumpAndSettle();
      expect(find.text('Lectern  \u2192  Rack'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  /// The router picks a way through, and picks a defensible one. Which side of
  /// the room the cable is actually pulled down is a fact about the building,
  /// and the drawing has to be able to say it.
  group('routing a run by hand', () {
    test('a bend steers the line, and the legs still dodge', () {
      // Nothing in the way: the guide IS the line.
      expect(
        routeThrough(
          [const Offset(0, 0), const Offset(100, 200), const Offset(400, 0)],
          const [],
        ),
        [const Offset(0, 0), const Offset(100, 200), const Offset(400, 0)],
      );

      // Something across one leg: that leg goes round it, and the bend the
      // user placed is still on the path. A hand-placed bend says where the
      // run should GO; it does not license it to cut through a box.
      final blocked = [const Rect.fromLTWH(180, 120, 120, 120)];
      final routed = routeThrough(
        [const Offset(0, 200), const Offset(240, 300), const Offset(500, 60)],
        blocked,
      );
      expect(routed.first, const Offset(0, 200));
      expect(routed.last, const Offset(500, 60));
      expect(routed, contains(const Offset(240, 300)));
      expect(polylineHitsAny(routed, blocked), isFalse);
    });

    test('a new bend lands in the leg it was dropped on', () {
      const start = Offset(0, 0);
      const end = Offset(400, 0);
      const bends = [Offset(100, 100), Offset(300, 100)];

      // Before the first bend, between the two, and after the second.
      expect(bendInsertIndex(start, bends, end, const Offset(40, 40)), 0);
      expect(bendInsertIndex(start, bends, end, const Offset(200, 100)), 1);
      expect(bendInsertIndex(start, bends, end, const Offset(360, 40)), 2);
    });

    test('a plan holds the bends per SHEET', () {
      // The pull belongs to the room; the shape of the line belongs to the
      // drawing. Two sheets of one room draw the same run their own way.
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      final one = p.addFloorPlanSheet(name: 'Level 1');
      final two = p.addFloorPlanSheet(name: 'Level 2');

      p.setAvRunWaypoints(one.id, 'bundle:x', const [Offset(50, 60)]);
      p.setAvRunWaypoints(two.id, 'bundle:x', const [Offset(400, 90)]);

      expect(
        p.avFloorPlanById(one.id)!.waypointsFor('bundle:x'),
        const [Offset(50, 60)],
      );
      expect(
        p.avFloorPlanById(two.id)!.waypointsFor('bundle:x'),
        const [Offset(400, 90)],
      );

      // Straightening one leaves the other alone.
      p.setAvRunWaypoints(one.id, 'bundle:x', const []);
      expect(p.avFloorPlanById(one.id)!.waypointsFor('bundle:x'), isEmpty);
      expect(p.avFloorPlanById(two.id)!.waypointsFor('bundle:x'), hasLength(1));
    });

    test('bends survive the sidecar round trip', () {
      const bare = FloorPlan(id: 'PLAN_1', name: 'Level 1');
      final bent = bare.withRunWaypoints(
        'bundle:x',
        const [Offset(120, 40), Offset(120, 500)],
      );

      expect(
        FloorPlan.fromJson(bent.toJson()).waypointsFor('bundle:x'),
        const [Offset(120, 40), Offset(120, 500)],
      );
      // A straightened run writes nothing rather than an empty list.
      expect(
        bent
            .withRunWaypoints('bundle:x', const [])
            .toJson()
            .containsKey('runWaypoints'),
        isFalse,
      );
    });

    testWidgets('the sheet grows handles for the run being worked on', (
      tester,
    ) async {
      final p = oneRunRoom();
      await pump(tester, p);
      final bundle = p.cablingSchematic(buildAvFlowModel(p)).bundles.single;
      final origin = tester.getTopLeft(find.byType(InteractiveViewer));

      // Nothing picked up: no handles anywhere on the drawing.
      expect(find.byKey(ValueKey('plan_add_bend_${bundle.id}_0')), findsNothing);

      await tester.tapAt(origin + const Offset(450, 200));
      await tester.pumpAndSettle();
      expect(
        find.text('Drag a hollow dot onto the line to turn it'),
        findsOneWidget,
      );

      // The hollow dot at the middle of the only leg adds a bend there.
      await tester.tap(find.byKey(ValueKey('plan_add_bend_${bundle.id}_0')));
      await tester.pumpAndSettle();

      expect(p.avFloorPlans.single.waypointsFor(bundle.id), hasLength(1));
      expect(find.text('1 bend on this sheet'), findsOneWidget);
      expect(find.byKey(ValueKey('plan_bend_${bundle.id}_0')), findsOneWidget);

      // And the way back out of a route steered by hand.
      await tester.tap(find.byKey(const ValueKey('plan_straighten_run')));
      await tester.pumpAndSettle();
      expect(p.avFloorPlans.single.waypointsFor(bundle.id), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a bend drags, and one drag is one undo', (tester) async {
      final p = oneRunRoom();
      await pump(tester, p);
      final bundle = p.cablingSchematic(buildAvFlowModel(p)).bundles.single;
      final origin = tester.getTopLeft(find.byType(InteractiveViewer));

      await tester.tapAt(origin + const Offset(450, 200));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('plan_add_bend_${bundle.id}_0')));
      await tester.pumpAndSettle();
      final placed = p.avFloorPlans.single.waypointsFor(bundle.id).single;

      // In steps, the way a pointer does it: the handle and the sheet's own
      // pan are both watching, and one jump from end to end gives the arena
      // nothing to decide on.
      final from = tester.getCenter(
        find.byKey(ValueKey('plan_bend_${bundle.id}_0')),
      );
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 60));
      for (var step = 1; step <= 4; step++) {
        await gesture.moveTo(from + Offset(0, 30.0 * step));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final moved = p.avFloorPlans.single.waypointsFor(bundle.id).single;
      expect(moved.dy, greaterThan(placed.dy));
      // One drag is one entry: undoing puts the bend back where it started
      // rather than unwinding it a pointer event at a time.
      p.undoAvFlow(AvUndoScope.floorPlans);
      expect(
        p.avFloorPlans.single.waypointsFor(bundle.id).single.dy,
        closeTo(placed.dy, 0.01),
      );
      expect(tester.takeException(), isNull);
    });
  });

  /// The sheet places every caption itself, and places them well enough that
  /// most are never touched. The ones that are touched are the ones it cannot
  /// reason about — a label over the door swing, or over the very bit of the
  /// plan the note beside it points at.
  group('moving a cable label', () {
    /// The caption block for the only run on the sheet, keyed the way the
    /// drawing keys it: the pair of markers it joins.
    const edgeKey = 'loc:LOC_1|loc:LOC_2';

    testWidgets('drags, and stays where it was put', (tester) async {
      final p = oneRunRoom();
      await pump(tester, p);

      final label = find.byKey(const ValueKey('plan_label_$edgeKey'));
      expect(label, findsOneWidget);
      expect(p.avFloorPlans.single.labelOffsetFor(edgeKey), Offset.zero);
      final before = tester.getTopLeft(label);

      // In steps, the way a pointer does it: the label and the sheet's own pan
      // are both watching, and one jump gives the arena nothing to decide on.
      final from = tester.getCenter(label);
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 60));
      for (var step = 1; step <= 4; step++) {
        await gesture.moveTo(from + Offset(0, 25.0 * step));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      // Down the page and nowhere sideways. Not to the pixel: the pointer has
      // to clear the drag threshold before the first delta is reported, so the
      // label lands a little short of the travel — which is what every drag in
      // the app does.
      final moved = p.avFloorPlans.single.labelOffsetFor(edgeKey);
      expect(moved.dy, greaterThan(40));
      expect(moved.dx.abs(), lessThan(2));
      // And the block on the page went with it.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('plan_label_$edgeKey'))).dy,
        greaterThan(before.dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('goes back where the sheet had it on a double-click', (
      tester,
    ) async {
      final p = oneRunRoom();
      p.setAvRunLabelOffset(p.avFloorPlans.single.id, edgeKey,
          const Offset(0, 120));
      await pump(tester, p);

      final at = tester.getCenter(
        find.byKey(const ValueKey('plan_label_$edgeKey')),
      );
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(at);
      await tester.pumpAndSettle();

      expect(p.avFloorPlans.single.labelOffsetFor(edgeKey), Offset.zero);
      expect(tester.takeException(), isNull);
    });

    test('the nudge is remembered per sheet, and round-trips', () {
      const bare = FloorPlan(id: 'PLAN_1', name: 'Level 1');
      final moved = bare.withRunLabelOffset(edgeKey, const Offset(30, -40));

      expect(moved.labelOffsetFor(edgeKey), const Offset(30, -40));
      expect(
        FloorPlan.fromJson(moved.toJson()).labelOffsetFor(edgeKey),
        const Offset(30, -40),
      );
      // Put back is stored as nothing at all, not as a zero.
      expect(
        moved
            .withRunLabelOffset(edgeKey, Offset.zero)
            .toJson()
            .containsKey('runLabelOffsets'),
        isFalse,
      );
    });

    test('a moved label follows its run when the marker moves', () {
      // The whole reason it is a nudge and not a position: a label moved clear
      // of a door swing is still clear of it after the rack is dragged.
      final p = oneRunRoom();
      final sheet = p.avFloorPlans.single.id;
      p.setAvRunLabelOffset(sheet, edgeKey, const Offset(0, 90));
      p.moveAvLocationMarker(sheet, 'LOC_2', const Offset(700, 600));

      expect(
        p.avFloorPlanById(sheet)!.labelOffsetFor(edgeKey),
        const Offset(0, 90),
      );
    });
  });

  test('the plan draws the same runs the cabling drawing does', () {
    // Both read the same call, so the sheet a contractor is handed and the
    // one-line drawing beside it cannot disagree about what runs where.
    final p = room();
    final drawing = p.cablingSchematic(buildAvFlowModel(p));
    expect(
      drawing.bundles.map((b) => b.cableType).toSet(),
      {'Network', 'AV cabling', 'Cat 5e'},
    );
    expect(
      drawing.bundles.firstWhere((b) => b.isControlRun).color,
      kCablingControlRunColor,
    );
  });
}
