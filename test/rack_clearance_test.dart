import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_rack_view.dart';

/// A rack elevation says what FITS. It says nothing about what should not be
/// touching — the amplifier that vents upwards, the drawer whose lid opens —
/// and both of those fit under the next unit and fail on site.
///
/// The catalog records the clearance on the MODEL, the elevation shades those
/// rails light red, and nothing is ever refused: the person in front of the
/// frame knows things the catalog does not.
void main() {
  AvNode device(String id, {int units = 1, String model = ''}) => AvNode(
    id: id,
    label: id,
    model: model.isEmpty ? 'Model $id' : model,
    pos: Offset.zero,
    rackUnits: units,
    ports: const [],
  );

  /// A provider with one 12U frame, one amplifier model in the catalog that
  /// wants a rail either side of it, and whatever devices are handed in.
  (AppStateProvider, RackFrame) rackWith(
    List<AvNode> devices, {
    int above = 1,
    int below = 1,
  }) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary.upsert(
      AvDeviceTemplate(
        model: 'HOT AMP',
        category: 'Amplifier',
        rackUnits: 2,
        clearanceAboveU: above,
        clearanceBelowU: below,
        ports: const [],
      ),
    );
    for (final d in devices) {
      p.addAvNode(d);
    }
    final rack = p.addAvRack('Rack 1', 12);
    return (p, rack);
  }

  group('what the catalog says about space', () {
    test('the clearance survives a save and a reload of the entry', () {
      final json = const AvDeviceTemplate(
        model: 'HOT AMP',
        rackUnits: 2,
        clearanceAboveU: 2,
        clearanceBelowU: 1,
        ports: [],
      ).toJson();
      final back = AvDeviceTemplate.fromJson(json);
      expect(back.clearanceAboveU, 2);
      expect(back.clearanceBelowU, 1);
    });

    test('a model that wants nothing writes nothing into the file', () {
      final json = const AvDeviceTemplate(model: 'Plain', ports: []).toJson();
      expect(json.containsKey('clearanceAboveU'), isFalse);
      expect(json.containsKey('clearanceBelowU'), isFalse);
    });

    test('the rails above and below a placed device are the warned ones', () {
      final (p, rack) = rackWith([device('AMP_1', units: 2, model: 'HOT AMP')]);
      p.avRackPlaceSharing(
        nodeId: 'AMP_1',
        rackId: rack.id,
        face: RackFace.front,
        startU: 5,
      );

      final warnings = p.rackClearanceWarnings(
        rackId: rack.id,
        face: RackFace.front,
        heightU: rack.heightU,
      );
      // Occupies U5–U6, so U7 above and U4 below.
      expect(warnings.keys.toSet(), {4, 7});
      expect(warnings[7], contains('above'));
      expect(warnings[4], contains('below'));
    });

    test('a rail off the end of the frame is not warned about', () {
      final (p, rack) = rackWith(
        [device('AMP_1', units: 2, model: 'HOT AMP')],
        above: 3,
        below: 3,
      );
      p.avRackPlaceSharing(
        nodeId: 'AMP_1',
        rackId: rack.id,
        face: RackFace.front,
        startU: 1,
      );
      final warnings = p.rackClearanceWarnings(
        rackId: rack.id,
        face: RackFace.front,
        heightU: rack.heightU,
      );
      // U1–U2 occupied: three rails above are real, three below are floor.
      expect(warnings.keys.toSet(), {3, 4, 5});
    });

    test('the other face of the same frame is left alone', () {
      final (p, rack) = rackWith([device('AMP_1', units: 2, model: 'HOT AMP')]);
      p.avRackPlaceSharing(
        nodeId: 'AMP_1',
        rackId: rack.id,
        face: RackFace.front,
        startU: 5,
      );
      expect(
        p.rackClearanceWarnings(
          rackId: rack.id,
          face: RackFace.rear,
          heightU: rack.heightU,
        ),
        isEmpty,
      );
    });

    test('a model with no clearance recorded warns about nothing', () {
      final (p, rack) = rackWith([device('SW_1')]);
      p.avRackPlaceSharing(
        nodeId: 'SW_1',
        rackId: rack.id,
        face: RackFace.front,
        startU: 5,
      );
      expect(
        p.rackClearanceWarnings(
          rackId: rack.id,
          face: RackFace.front,
          heightU: rack.heightU,
        ),
        isEmpty,
      );
    });
  });

  group('on the elevation', () {
    Future<void> pumpRacks(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: AvRackView(captureKey: GlobalKey(), editMode: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// The fill painted on one rail's drop zone.
    Color? slotColor(WidgetTester tester, RackFrame rack, int u) {
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byKey(ValueKey('u_${rack.id}_${RackFace.front.name}_$u')),
          matching: find.byType(Container),
        ),
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    testWidgets('the kept-clear rail is washed red and its neighbours are not',
        (tester) async {
      final (p, rack) = rackWith([device('AMP_1', units: 2, model: 'HOT AMP')]);
      p.avRackPlaceSharing(
        nodeId: 'AMP_1',
        rackId: rack.id,
        face: RackFace.front,
        startU: 5,
      );
      await pumpRacks(tester, p);

      expect(slotColor(tester, rack, 7), kRackClearanceWash);
      expect(slotColor(tester, rack, 4), kRackClearanceWash);
      // Two rails away is an ordinary empty rail.
      expect(slotColor(tester, rack, 9), isNull);
    });

    testWidgets('the warning never refuses a placement', (tester) async {
      final (p, rack) = rackWith([
        device('AMP_1', units: 2, model: 'HOT AMP'),
        device('SW_1'),
      ]);
      p.avRackPlaceSharing(
        nodeId: 'AMP_1',
        rackId: rack.id,
        face: RackFace.front,
        startU: 5,
      );
      await pumpRacks(tester, p);

      // Straight into the rail the amplifier asked to be left empty.
      final placed = p.avRackPlaceSharing(
        nodeId: 'SW_1',
        rackId: rack.id,
        face: RackFace.front,
        startU: 7,
      );
      expect(placed, isTrue, reason: 'clearance is advice, not a rule');
      expect(p.avRackSlots['SW_1']?.startU, 7);
    });
  });
}
