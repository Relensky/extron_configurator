import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// [FLOOR PLANS - FIT]: a sheet laid out on blank paper and then given a
// smaller drawing keeps everything reachable - the drawing grows instead.
void main() {
  PlanDevice device(String id, Offset pos) => PlanDevice(
      id: id, deviceKey: 'k', label: id, shape: 'box', pos: pos);

  test('things past the edge are noticed, and the drawing grows to cover them',
      () {
    final plan = FloorPlan(
      id: 'PLAN_1',
      name: 'Plan',
      imageFile: 'plan.png',
      imageSize: const Size(800, 600),
      pixelsPerFoot: 10,
      devices: [device('a', const Offset(100, 100)), device('b', const Offset(1100, 850))],
      markers: const {'loc': Offset(300, 200)},
    );
    expect(plan.hasContentOffSheet, isTrue);
    final k = plan.scaleToFitContent;
    expect(k, closeTo((850 + FloorPlan.kFitPadding) / 600, 1e-9));
    final fitted = plan.fittedToContent();
    expect(fitted.hasContentOffSheet, isFalse);
    // Same shape, and nothing placed has moved.
    expect(fitted.imageSize.width / fitted.imageSize.height, closeTo(800 / 600, 1e-9));
    expect(fitted.devices.last.pos, const Offset(1100, 850));
    // A calibration follows the drawing.
    expect(fitted.pixelsPerFoot, closeTo(10 * k, 1e-9));
  });

  test('a drawing that already covers everything is left alone', () {
    final plan = FloorPlan(
      id: 'PLAN_1',
      name: 'Plan',
      imageSize: const Size(1200, 900),
      devices: [device('a', const Offset(100, 100))],
    );
    expect(plan.hasContentOffSheet, isFalse);
    expect(plan.scaleToFitContent, 1);
    expect(identical(plan.fittedToContent(), plan), isTrue);
  });
}
