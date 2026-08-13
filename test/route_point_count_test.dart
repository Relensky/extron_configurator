import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_locations_view.dart';

/// A low-voltage run is rarely one cable and rarely a straight line. It is six
/// Cat 6 that reach a pull box in the ceiling, where two of them terminate and
/// four carry on to the rack — and until the count existed, every one of these
/// was drawn and scheduled as a single lead going straight across the room.
void main() {
  group('what each leg carries', () {
    ScreenSwitch run({
      double count = 1,
      List<double> viaCounts = const [],
    }) => ScreenSwitch(
      id: 'SCRSW_1',
      label: 'Screen',
      startLocationId: 'LOC_1',
      viaLocationIds: const ['LOC_2', 'LOC_3'],
      endLocationId: 'LOC_4',
      cableCount: count,
      viaCounts: viaCounts,
    );

    test('a run with no counts is one cable per leg, as it always was', () {
      final s = run();
      expect(s.legs, hasLength(3));
      for (int i = 0; i < s.legs.length; i++) {
        expect(s.countForLeg(i), 1);
      }
    });

    test('the run count carries down every leg', () {
      final s = run(count: 6);
      for (int i = 0; i < s.legs.length; i++) {
        expect(s.countForLeg(i), 6);
      }
    });

    test('a route point can drop cables from there on', () {
      // Six to the first point, four on from it, and the second point says
      // nothing so it inherits the run's six.
      final s = run(count: 6, viaCounts: const [4, 0]);
      expect(s.countForLeg(0), 6, reason: 'start to the first point');
      expect(s.countForLeg(1), 4, reason: 'on from the first point');
      expect(s.countForLeg(2), 6, reason: 'untouched, so the run count');
    });

    test('a leg is never nothing', () {
      final s = run(count: 0, viaCounts: const [0, 0]);
      expect(s.countForLeg(0), 1);
      expect(s.countForLeg(2), 1);
    });

    test('the counts survive a save and a reload', () {
      final back = ScreenSwitch.fromJson(
        run(count: 6, viaCounts: const [4, 0]).toJson(),
      );
      expect(back.cableCount, 6);
      expect(back.viaCounts, [4, 0]);
      // A run that carries one cable and no per-point counts writes neither.
      expect(run().toJson().containsKey('cables'), isFalse);
      expect(run().toJson().containsKey('viaCables'), isFalse);
    });
  });

  test('the cabling drawing counts each leg for itself', () {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final a = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
    final box = p.addAvLocation(
      const RoomLocation(id: '', name: 'Pull box', zone: RoomZone.pullBox),
    );
    final rack = p.addAvLocation(const RoomLocation(id: '', name: 'Rack'));
    p.addAvScreenSwitch(
      ScreenSwitch(
        id: '',
        label: 'Screen',
        startLocationId: a.id,
        viaLocationIds: [box.id],
        endLocationId: rack.id,
        cableCount: 6,
        viaCounts: const [4],
      ),
    );

    final model = buildAvFlowModel(p);
    final drawing = buildCablingSchematic(
      model: model,
      locations: model.locations,
      overrides: model.cablingEdits,
    );
    final legs = drawing.bundles
        .where((b) => b.id.contains('SCRSW'))
        .toList()
      ..sort((x, y) => x.id.compareTo(y.id));
    expect(legs, hasLength(2));
    expect(legs.first.count, 6, reason: 'lectern to the pull box');
    expect(legs.last.count, 4, reason: 'and four carry on to the rack');
  });

  group('the dialog', () {
    late AppStateProvider provider;

    setUp(() {
      provider = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      provider.loadAvFlowForCurrentConfig();
      provider.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
      provider.addAvLocation(
        const RoomLocation(id: '', name: 'Pull box', zone: RoomZone.pullBox),
      );
    });

    Future<void> openEditor(WidgetTester tester, ScreenSwitch? existing) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () =>
                      showScreenSwitchEditor(ctx, provider, existing),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the button says route point, not pull box', (tester) async {
      await openEditor(tester, null);
      expect(find.text('Add a route point'), findsOneWidget);
      expect(find.textContaining('pull box or secondary location'),
          findsOneWidget);
      expect(find.text('Add a pull box'), findsNothing);
    });

    testWidgets('the run carries a cable count', (tester) async {
      await openEditor(tester, null);
      expect(find.byKey(const ValueKey('run_cable_count')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('run_cable_count')),
        '6',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(provider.avScreenSwitches.single.cableCount, 6);
    });

    testWidgets('a route point carries its own count', (tester) async {
      final box = provider.avLocations
          .firstWhere((l) => l.zone == RoomZone.pullBox);
      // A run that already exists, opened for editing — which is the only way
      // a route point is on screen to be counted.
      final stored = provider.addAvScreenSwitch(
        ScreenSwitch(
          id: '',
          label: 'Screen',
          startLocationId: provider.avLocations.first.id,
          viaLocationIds: [box.id],
          cableCount: 6,
        ),
      );
      await openEditor(tester, stored);

      final count = find.byKey(const ValueKey('route_point_count_0'));
      expect(count, findsOneWidget);
      await tester.enterText(count, '4');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = provider.avScreenSwitches
          .firstWhere((s) => s.id == 'SCRSW_1');
      expect(saved.viaCounts, [4]);
      expect(saved.countForLeg(1), 4);
    });
  });
}
