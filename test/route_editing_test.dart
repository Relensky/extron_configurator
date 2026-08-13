import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/cabling_view.dart';
import 'package:extron_configurator/layout_tools.dart';
import 'package:extron_configurator/room_locations.dart';

/// Steering a run by hand had two faults that felt like one. The handles lost
/// the drag after a single move — the route reshapes as it is dragged, which
/// changed how many handles there are, and an unkeyed one was matched against
/// its neighbour and thrown away mid-gesture — and every pointer event wrote
/// through the provider, re-routing every run on the sheet to draw one frame.
///
/// And the thing a drawing actually wants, a square corner, could only be
/// reached by dragging a dot until it happened to line up.
void main() {
  group('the geometry', () {
    test('a bend near square with its neighbour is pulled square', () {
      // Within the snap distance: this is the corner somebody is aiming at.
      expect(
        snapToRightAngle(const Offset(104, 61), const [
          Offset(100, 20),
          Offset(300, 60),
        ]),
        const Offset(100, 60),
      );
    });

    test('a deliberately diagonal bend is left alone', () {
      const point = Offset(160, 140);
      expect(
        snapToRightAngle(point, const [Offset(100, 20), Offset(300, 60)]),
        point,
      );
    });

    test('the corner goes the long way first', () {
      // A wide leg turns after running along it; a tall one turns after
      // running down it. Either is a right angle; only one reads as the way
      // cable is pulled.
      expect(
        rightAngleTurn(const Offset(0, 0), const Offset(200, 40)).single,
        const Offset(200, 0),
      );
      expect(
        rightAngleTurn(const Offset(0, 0), const Offset(40, 200)).single,
        const Offset(0, 200),
      );
    });

    test('a leg that is already square is jogged instead', () {
      // A single corner on a straight leg lands on one of its own ends and
      // turns nothing. What that leg wants is a jog — out, along, back.
      final jog = rightAngleTurn(const Offset(0, 100), const Offset(400, 100));
      expect(jog, hasLength(2));
      // Both bends off the line by the same amount, so all four corners are
      // square.
      expect(jog.first.dy, jog.last.dy);
      expect(jog.first.dy, isNot(100));
      expect(jog.first.dx, lessThan(jog.last.dx));
    });
  });

  group('on the cabling drawing', () {
    AppStateProvider room() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      final a = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
      final b = p.addAvLocation(const RoomLocation(id: '', name: 'Rack'));
      p.addAvScreenSwitch(
        ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: a.id,
          endLocationId: b.id,
          cableType: '18/2 plenum',
        ),
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
          child: const MaterialApp(home: Scaffold(body: CablingView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Builds the page and picks the only run by clicking its label, which is
    /// how most people select one.
    Future<String> selectRun(WidgetTester tester, AppStateProvider p) async {
      await pump(tester, p);
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey &&
              (w.key as ValueKey).value.toString().startsWith('cabling_label_'),
        ),
      );
      await tester.pumpAndSettle();
      return p.cablingSchematic(buildAvFlowModel(p)).bundles.first.id;
    }

    testWidgets('right-clicking the add-bend handle puts in a square corner',
        (tester) async {
      final p = room();
      final id = await selectRun(tester, p);

      final add = find.byKey(ValueKey('cabling_add_bend_${id}_0'));
      expect(add, findsOneWidget);
      await tester.tap(add, buttons: 0x02); // secondary
      await tester.pumpAndSettle();

      final bends = p.avCabling.waypoints[id];
      expect(bends, isNotNull);
      expect(bends, hasLength(2));
      // The corner of the two ends, not their midpoint — which is what makes
      // the two legs square.
      final ends = p
          .cablingSchematic(buildAvFlowModel(p))
          .endsOf(
            p.cablingSchematic(buildAvFlowModel(p)).bundles.first,
            0,
            endAnchors: p.avCabling.endAnchors,
          )!;
      // The boxes on a derived drawing sit in a column, so this leg is
      // already square: the turn is a jog out and back, which is the shape a
      // run takes to get round something.
      final middle = (ends.from + ends.to) / 2;
      expect(bends!.every((b) => (b.dx - middle.dx).abs() > 20), isTrue,
          reason: 'the jog leaves the line it was straight on');
    });

    testWidgets('a bend keeps the drag for its whole travel', (tester) async {
      final p = room();
      final id = await selectRun(tester, p);
      await tester.tap(find.byKey(ValueKey('cabling_add_bend_${id}_0')));
      await tester.pumpAndSettle();
      final placed = p.avCabling.waypoints[id]!.single;

      // In steps, the way a pointer does it. The route reshapes as it goes,
      // which is exactly what used to kill the gesture after the first move.
      final handle = find.byKey(ValueKey('cabling_bend_${id}_0'));
      final from = tester.getCenter(handle);
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 60));
      for (var step = 1; step <= 5; step++) {
        await gesture.moveTo(from + Offset(0, 26.0 * step));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final moved = p.avCabling.waypoints[id]!.single;
      // Most of the travel, not the first 26 pixels of it.
      expect(moved.dy - placed.dy, greaterThan(70));
    });

    testWidgets('where a run lands on its box can be moved and centred again',
        (tester) async {
      final p = room();
      final id = await selectRun(tester, p);

      final handle = find.byKey(ValueKey('cabling_end_${id}_from'));
      expect(handle, findsOneWidget);

      final from = tester.getCenter(handle);
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 60));
      for (var step = 1; step <= 5; step++) {
        await gesture.moveTo(from + Offset(0, 16.0 * step));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final key = cablingEndKey(id, true);
      expect(p.avCabling.endAnchors[key], isNotNull);
      // Stored as a fraction of the box, so it survives the box being dragged
      // across the sheet or resized by a longer name.
      expect(p.avCabling.endAnchors[key]!.dy, greaterThan(0.5));
      expect(p.avCabling.endAnchors[key]!.dy, lessThanOrEqualTo(1.0));

      // Double-click puts it back in the middle of the box.
      final at = tester.getCenter(find.byKey(ValueKey('cabling_end_${id}_from')));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(p.avCabling.endAnchors[key], isNull);
    });

    test('the anchors survive a save and a reload of the sidecar', () {
      final p = room();
      p.setCablingEndAnchor('run:1', true, const Offset(0.1, 0.9));
      final json = p.avCabling.toJson();
      p.avCabling.clear();
      p.avCabling.readJson(json);
      expect(p.avCabling.endAnchors[cablingEndKey('run:1', true)],
          const Offset(0.1, 0.9));
    });
  });
}
