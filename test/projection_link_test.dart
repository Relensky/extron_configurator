import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/number_dial.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/projection_calc.dart';

/// A projector's throw and its screen kept to the same image, and numbers
/// typed into the floor plan's dials.
void main() {
  const screen = PlanDevice(
    id: 'S',
    deviceKey: 's',
    label: 'Screen',
    shape: 'screen',
    pos: Offset(0, 0),
    width: 160,
  );
  const projector = PlanDevice(
    id: 'P',
    deviceKey: 'p',
    label: 'Projector',
    shape: 'projector',
    pos: Offset(0, 400),
    rotation: 180,
    fov: 30,
    range: 400,
  );

  test('beam angle and throw ratio go both ways', () {
    expect(throwRatioForBeam(beamAngleForRatio(1.8)), closeTo(1.8, 1e-9));
    // A 2.0 lens 10 ft away throws an image 5 ft wide.
    expect(imageWidthForBeam(10, beamAngleForRatio(2)), closeTo(5, 1e-9));
    expect(
      imageWidthForBeam(12, beamAngleToFill(12, 7.5)),
      closeTo(7.5, 1e-9),
    );
  });

  test('a longer reach makes the screen wider', () {
    final out = withProjectionLinked(
      [screen, projector],
      projector.copyWith(range: 500),
    );
    final s = out.firstWhere((d) => d.id == 'S');
    expect(s.width, closeTo(imageWidthForBeam(500, 30), 1e-9));
    // Watched from six image heights of a 16:10 picture.
    expect(s.range, closeTo(s.width / 1.6 * 6, 1e-9));
  });

  test('a wider screen zooms its projector to fill it', () {
    final out = withProjectionLinked(
      [screen, projector],
      screen.copyWith(width: 240),
    );
    final p = out.firstWhere((d) => d.id == 'P');
    expect(imageWidthForBeam(p.range, p.fov), closeTo(240, 1e-6));
    expect(p.range, 400);
  });

  test('turning or moving leaves the pair alone', () {
    final out = withProjectionLinked(
      [screen, projector],
      projector.copyWith(rotation: 170, pos: const Offset(10, 400)),
    );
    expect(out.firstWhere((d) => d.id == 'S').width, 160);
  });

  test('a gain screen gains on the room light, not loses', () {
    // Room light comes from everywhere, so gain does not raise it.
    expect(screenReflectance(1.8), kWhiteScreenReflectance);
    expect(screenReflectance(0.8), 0.8);
    double straightOn(double gain) {
      final peak = nitsFromFootLamberts(footLamberts(5000, gain, 62.5));
      return contrastInRoom(peak, ambientNits(8, screenReflectance(gain)));
    }

    expect(straightOn(1.8), greaterThan(straightOn(1.0)));
    // 5000 lm on a 10 ft screen in 8 fc: 12:1, short of 15:1 but past 7:1.
    expect(straightOn(1.0), closeTo(12.1, 0.1));
  });

  test('contrast is named by the highest category it holds', () {
    expect(contrastCategory(5), isNull);
    expect(contrastCategory(12), 'Passive viewing');
    expect(contrastCategory(15), 'Basic decision making');
    expect(contrastCategory(90), 'Full-motion video');
  });

  test('lengths read in feet and inches', () {
    expect(parseFeetInches('12'), 12);
    expect(parseFeetInches("12' 6\""), 12.5);
    expect(parseFeetInches('12 6'), 12.5);
    expect(parseFeetInches('12ft 6in'), 12.5);
    expect(parseFeetInches('150"'), 12.5);
    expect(parseFeetInches('abc'), isNull);
  });

  test('each working-area band keeps a color of its own', () {
    final d = screen.copyWith(rangeColors: {15: 0xFF1565C0, 80: 0xFF6A1B9A});
    final back = PlanDevice.fromJson(d.toJson());
    expect(back.rangeColors, {15: 0xFF1565C0, 80: 0xFF6A1B9A});
    expect(PlanDevice.fromJson(screen.toJson()).rangeColors, isEmpty);
  });

  testWidgets('the field opens with the number the dial shows', (
    tester,
  ) async {
    var value = 12.42;
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, set) => NumberDial(
              sliderKey: const ValueKey('dial'),
              value: value,
              min: 1,
              max: 150,
              format: formatFeetInches,
              parse: parseFeetInches,
              onChanged: (v) => set(() => value = v),
              onChangeEnd: (_) => ended++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('dial_number')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('dial_field')),
    );
    expect(field.controller!.text, "12' 5\"");
    // Left as it was, nothing moves.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(value, 12.42);
    expect(ended, 0);
  });

  testWidgets('click the number to type one', (tester) async {
    var value = 10.0;
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, set) => NumberDial(
              sliderKey: const ValueKey('dial'),
              label: 'Reach',
              value: value,
              min: 1,
              max: 150,
              format: formatFeetInches,
              parse: parseFeetInches,
              typedMax: 500,
              onChanged: (v) => set(() => value = v),
              onChangeEnd: (_) => ended++,
            ),
          ),
        ),
      ),
    );
    expect(find.text("10'"), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dial_number')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('dial_field')), "200' 6");
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // Past the slider's end, but within what may be typed.
    expect(value, 200.5);
    expect(ended, 1);
    expect(find.text("200' 6\""), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
