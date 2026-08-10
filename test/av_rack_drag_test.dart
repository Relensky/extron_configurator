import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_rack_view.dart';

/// The rack page accepts gear three ways — drag and drop, click-then-click,
/// and a typed U — and all three go through the same occupancy rules. These
/// cover the drag path and the half-width sharing that makes two boxes fit on
/// one rail.
void main() {
  AvNode device(String id, {int units = 1}) => AvNode(
    id: id,
    label: id,
    model: 'Model $id',
    pos: Offset.zero,
    rackUnits: units,
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

  /// Drags from the center of [from] to the center of [to] in steps, the way
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

  Finder slot(RackFrame rack, int u, {String face = 'front'}) =>
      find.byKey(ValueKey('u_${rack.id}_${face}_$u'));

  testWidgets('a device drags from the to-place list into a U', (tester) async {
    final (provider, rack) = rackWith([device('AMP', units: 2)]);
    await pumpRacks(tester, provider);

    await dragOnto(tester, find.text('AMP (2U)'), slot(rack, 5));

    final placed = provider.avRackSlots['AMP'];
    expect(placed, isNotNull);
    expect(placed!.startU, 5);
    expect(placed.face, RackFace.front);
    // Alone on the rail, so it keeps the whole width.
    expect(placed.slice.columns, 1);
  });

  testWidgets('a racked device drags to a different U', (tester) async {
    final (provider, rack) = rackWith([device('AMP')]);
    provider.setAvRackSlot('AMP', RackSlot(rackId: rack.id, startU: 2));
    await pumpRacks(tester, provider);

    await dragOnto(tester, find.text('AMP'), slot(rack, 9));

    expect(provider.avRackSlots['AMP']!.startU, 9);
  });

  testWidgets('two devices dropped on the same U share the rail', (
    tester,
  ) async {
    final (provider, rack) = rackWith([device('BOXA'), device('BOXB')]);
    await pumpRacks(tester, provider);

    await dragOnto(tester, find.text('BOXA (1U)'), slot(rack, 4));
    await dragOnto(tester, find.text('BOXB (1U)'), slot(rack, 4));

    expect(provider.avRackSlots['BOXA']!.startU, 4);
    expect(provider.avRackSlots['BOXA']!.slice.columns, 2);
    expect(provider.avRackSlots['BOXA']!.slice.column, 0);
    expect(provider.avRackSlots['BOXB']!.slice.column, 1);
  });

  testWidgets('a third device makes it thirds', (tester) async {
    final (provider, rack) = rackWith([
      device('REVOLABS'),
      device('DTPRX'),
      device('MICROPC'),
    ]);
    await pumpRacks(tester, provider);

    for (final name in ['REVOLABS', 'DTPRX', 'MICROPC']) {
      await dragOnto(tester, find.text('$name (1U)'), slot(rack, 2));
    }

    expect(
      provider.avRackOccupantsAt(
        rackId: rack.id,
        face: RackFace.front,
        startU: 2,
      ),
      ['REVOLABS', 'DTPRX', 'MICROPC'],
    );
    expect(provider.avRackSlots['MICROPC']!.slice.columns, 3);
  });

  testWidgets('a drop is refused once the rail is full', (tester) async {
    final devices = [
      for (int i = 0; i < kMaxRackColumns; i++) device('D$i'),
      device('ONEMORE'),
    ];
    final (provider, rack) = rackWith(devices);
    await pumpRacks(tester, provider);

    for (int i = 0; i < kMaxRackColumns; i++) {
      await dragOnto(tester, find.text('D$i (1U)'), slot(rack, 3));
    }
    await dragOnto(tester, find.text('ONEMORE (1U)'), slot(rack, 3));

    expect(provider.avRackSlots.containsKey('ONEMORE'), isFalse);
    expect(provider.avRackSlots.length, kMaxRackColumns);
  });

  group('hardware waiting to be placed', () {
    testWidgets('an unplaced shelf waits in the toolbar and drags into a U', (
      tester,
    ) async {
      final (provider, rack) = rackWith([]);
      // What "Add unplaced" produces: on the parts list, on the estimate, and
      // in no frame until somebody puts it in one.
      final item = provider.addAvRackItem(
        const RackItem(
          id: '',
          catalogModel: '1U Shelf',
          label: '1U Shelf',
          category: 'Shelf',
          rackUnits: 1,
          price: 42,
        ),
      );
      expect(item, isNotNull);
      expect(provider.avRackSlots.containsKey(item!.id), isFalse);

      await pumpRacks(tester, provider);
      await dragOnto(tester, find.text('1U Shelf (1U)'), slot(rack, 7));

      expect(provider.avRackSlots[item.id]?.startU, 7);
    });

    testWidgets('"Add unplaced" adds the part without asking for a U', (
      tester,
    ) async {
      final (provider, _) = rackWith([]);
      provider.avDeviceLibrary = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: '2U Vent',
            category: 'Vent plate',
            rackUnits: 2,
            price: 30,
            ports: [],
          ),
        );
      await pumpRacks(tester, provider);

      await tester.tap(find.text('Add plate / shelf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add unplaced'));
      await tester.pumpAndSettle();

      expect(provider.avRackItems.length, 1);
      expect(provider.avRackItems.single.label, '2U Vent');
      expect(
        provider.avRackSlots.containsKey(provider.avRackItems.single.id),
        isFalse,
        reason: 'it is waiting, not racked',
      );
    });
  });

  testWidgets('dropping onto a tall device shares that device\'s rail', (
    tester,
  ) async {
    final (provider, rack) = rackWith([
      device('TALL', units: 3),
      device('SMALL'),
    ]);
    provider.setAvRackSlot('TALL', RackSlot(rackId: rack.id, startU: 6));
    await pumpRacks(tester, provider);

    // The 3U block covers U6-U8, so a drop anywhere on it means "go beside
    // this one" — and beside it means starting where it starts, at U6.
    await dragOnto(tester, find.text('SMALL (1U)'), find.text('TALL'));

    expect(provider.avRackSlots['SMALL']!.startU, 6);
    expect(provider.avRackSlots['SMALL']!.slice.columns, 2);
    expect(provider.avRackSlots['TALL']!.slice.column, 0);
  });
}
