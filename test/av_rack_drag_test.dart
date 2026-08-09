import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_rack_view.dart';

/// The rack page accepts gear three ways — drag and drop, click-then-click,
/// and a typed U — and all three go through the same occupancy rules. These
/// cover the drag path and the half-width sharing that makes two boxes fit on
/// one rail.
void main() {
  AvNode device(
    String id, {
    RackWidth width = RackWidth.full,
    int units = 1,
  }) => AvNode(
    id: id,
    label: id,
    model: 'Model $id',
    pos: Offset.zero,
    rackUnits: units,
    rackWidth: width,
    ports: const [],
  );

  /// A provider with one 12U frame and whatever devices are handed in.
  (AppStateProvider, RackFrame) rackWith(List<AvNode> devices) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    for (final d in devices) {
      p.addAvNode(d);
    }
    final rack = p.addAvRack('Rack 1', 12);
    return (p, rack);
  }

  Future<void> pumpRacks(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: AvRackView(captureKey: GlobalKey(), editMode: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drags from the centre of [from] to the centre of [to] in steps, the way
  /// a real pointer moves, so Draggable hands over to DragTarget.
  Future<void> dragOnto(
    WidgetTester tester,
    Finder from,
    Finder to,
  ) async {
    final start = tester.getCenter(from);
    final end = tester.getCenter(to);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 100));
    // A few intermediate moves: one big jump can skip the hover entirely.
    for (int i = 1; i <= 5; i++) {
      await gesture.moveTo(Offset.lerp(start, end, i / 5)!);
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Finder slot(RackFrame rack, int u, RackHalf side, {String face = 'front'}) =>
      find.byKey(ValueKey('u_${rack.id}_${face}_${u}_${side.name}'));

  testWidgets('a device drags from the to-place list into a U', (tester) async {
    final (provider, rack) = rackWith([device('AMP', units: 2)]);
    await pumpRacks(tester, provider);

    await dragOnto(tester, find.text('AMP (2U)'), slot(rack, 5, RackHalf.left));

    final placed = provider.avRackSlots['AMP'];
    expect(placed, isNotNull);
    expect(placed!.startU, 5);
    expect(placed.face, RackFace.front);
    // A full-width device takes the whole rail whichever half it was aimed at.
    expect(placed.half, RackHalf.full);
  });

  testWidgets('a racked device drags to a different U', (tester) async {
    final (provider, rack) = rackWith([device('AMP')]);
    provider.setAvRackSlot('AMP', RackSlot(rackId: rack.id, startU: 2));
    await pumpRacks(tester, provider);

    await dragOnto(tester, find.text('AMP'), slot(rack, 9, RackHalf.right));

    expect(provider.avRackSlots['AMP']!.startU, 9);
  });

  testWidgets('two half-width devices land side by side in one U', (
    tester,
  ) async {
    final (provider, rack) = rackWith([
      device('LEFTBOX', width: RackWidth.half),
      device('RIGHTBOX', width: RackWidth.half),
    ]);
    await pumpRacks(tester, provider);

    await dragOnto(
      tester,
      find.text('LEFTBOX (1U ½)'),
      slot(rack, 4, RackHalf.left),
    );
    await dragOnto(
      tester,
      find.text('RIGHTBOX (1U ½)'),
      slot(rack, 4, RackHalf.right),
    );

    expect(provider.avRackSlots['LEFTBOX']!.startU, 4);
    expect(provider.avRackSlots['LEFTBOX']!.half, RackHalf.left);
    expect(provider.avRackSlots['RIGHTBOX']!.startU, 4);
    expect(provider.avRackSlots['RIGHTBOX']!.half, RackHalf.right);
  });

  testWidgets('a drop onto an occupied half is refused', (tester) async {
    final (provider, rack) = rackWith([
      device('LEFTBOX', width: RackWidth.half),
      device('OTHER', width: RackWidth.half),
    ]);
    provider.setAvRackSlot(
      'LEFTBOX',
      RackSlot(rackId: rack.id, startU: 4, half: RackHalf.left),
    );
    await pumpRacks(tester, provider);

    await dragOnto(
      tester,
      find.text('OTHER (1U ½)'),
      slot(rack, 4, RackHalf.left),
    );

    // Refused, so it stays unplaced rather than stacking on top.
    expect(provider.avRackSlots.containsKey('OTHER'), isFalse);
    expect(provider.avRackSlots['LEFTBOX']!.half, RackHalf.left);
  });

  testWidgets('a full-width device is refused where only a half is free', (
    tester,
  ) async {
    final (provider, rack) = rackWith([
      device('HALFBOX', width: RackWidth.half),
      device('FULLBOX'),
    ]);
    provider.setAvRackSlot(
      'HALFBOX',
      RackSlot(rackId: rack.id, startU: 7, half: RackHalf.left),
    );
    await pumpRacks(tester, provider);

    await dragOnto(
      tester,
      find.text('FULLBOX (1U)'),
      slot(rack, 7, RackHalf.right),
    );

    expect(provider.avRackSlots.containsKey('FULLBOX'), isFalse);
  });
}
