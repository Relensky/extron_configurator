import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/projection_calc.dart';
import 'package:extron_configurator/projection_calculator_dialog.dart';

void main() {
  group('image and throw', () {
    test('a 120 inch 16:9 diagonal is about 104.6 by 58.8 inches', () {
      final img = imageFromDiagonal(10, kScreenAspects[1]);
      expect(img.width * 12, closeTo(104.6, 0.1));
      expect(img.height * 12, closeTo(58.8, 0.1));
      expect(img.diagonal, closeTo(10, 1e-9));
    });

    test('throw ratio is distance over width', () {
      expect(throwDistance(5, 2), 10);
      expect(imageWidthAt(10, 2), 5);
      expect(throwRatioFor(10, 5), 2);
      expect(imageWidthAt(10, 0), 0);
    });

    test('foot-lamberts are lumens times gain over area', () {
      expect(footLamberts(5000, 1, 50), 100);
      expect(footLamberts(5000, 1.3, 50), closeTo(130, 1e-9));
      expect(nitsFromFootLamberts(10), closeTo(34.26, 1e-9));
      expect(contrastInRoom(100, 5), 21);
    });

    test('lens height range follows the shift', () {
      final r = lensHeightRange(
        bottom: 4,
        imageHeight: 6,
        shiftUpPct: 50,
        shiftDownPct: 10,
      );
      expect(r.low, closeTo(6.4, 1e-9));
      expect(r.high, closeTo(10, 1e-9));
    });

    test('feet and inches read back', () {
      expect(formatFeetInches(18.5), "18' 6\"");
      expect(formatFeetInches(12), "12'");
      expect(formatFeetInches(11.999), "12'");
      expect(trimFeetInches(6), '6');
      expect(trimFeetInches(6.5), '6.5');
    });
  });

  group('screen falloff', () {
    test('half as bright at the half-gain angle', () {
      expect(relativeBrightness(0, 40), closeTo(1, 1e-9));
      expect(relativeBrightness(40, 40), closeTo(0.5, 1e-9));
      expect(relativeBrightness(-40, 40), closeTo(0.5, 1e-9));
      expect(relativeBrightness(60, 40), lessThan(0.5));
      expect(relativeBrightness(90, 40), 0);
    });

    test('higher gain narrows the typical angle', () {
      expect(typicalHalfGainAngle(1.0), 60);
      expect(typicalHalfGainAngle(0.8), 60);
      expect(typicalHalfGainAngle(1.3), 40);
      expect(typicalHalfGainAngle(1.15), closeTo(50, 1e-9));
      expect(typicalHalfGainAngle(3), 20);
    });
  });

  group('where an image works', () {
    test('the working angle is where brightness meets what is needed', () {
      // Half as bright at 40 degrees; needing half the peak is 40 degrees.
      expect(workingAngle(200, 100, 40), closeTo(40, 1e-6));
      expect(angleForBrightness(0.5, 40), closeTo(40, 1e-6));
      expect(workingAngle(100, 200, 40), 0);
      expect(workingAngle(0, 10, 40), 0);
    });

    test('room light and contrast set the brightness needed', () {
      // 10 fc on a 1.0 gain screen bounces about 34 nits.
      expect(ambientNits(10, 1), closeTo(34.26, 0.01));
      expect(neededNits(15, 34.26), closeTo(479.6, 0.1));
      expect(farthestViewer(5), 30);
      expect(imageHeightFromWidth(16), 9);
    });

    test('display brightness and size come off the catalog', () {
      const panel = AvDeviceTemplate(
        model: 'TH-55SQ2HW',
        manufacturer: 'Panasonic',
        notes: '500 nits, 4K',
        ports: [],
      );
      expect(displayNitsOf(panel), 500);
      expect(displayNitsOf(panel.copyWith(nits: 700)), 700);
      expect(displayDiagonalOf(panel), 55);
      expect(
        displayDiagonalOf(
          const AvDeviceTemplate(model: 'INF7500', ports: []),
        ),
        75,
      );
      expect(
        displayDiagonalOf(
          const AvDeviceTemplate(model: 'LE-C1135', ports: []),
        ),
        0,
      );
      expect(widthFromDiagonalInches(55) * 12, closeTo(47.9, 0.1));
      expect(parseNits('350 cd/m2 typical'), 350);
    });

    test('a screen keeps its gain and a display its width', () {
      const screen = PlanDevice(
        id: 'DEV_1',
        deviceKey: 's',
        label: 'Screen',
        shape: 'screen',
        pos: Offset.zero,
        gain: 1.3,
      );
      expect(PlanDevice.fromJson(screen.toJson()).gain, 1.3);
      const tv = PlanDevice(
        id: 'DEV_2',
        deviceKey: 'd',
        label: 'Display',
        shape: 'display',
        pos: Offset.zero,
        width: 90,
      );
      expect(tv.hasFace, isTrue);
      expect(PlanDevice.fromJson(tv.toJson()).width, 90);
      expect(tv.toJson(), isNot(contains('gain')));
    });
  });

  group('angles on the plan', () {
    test('rotation toward each direction', () {
      const o = Offset(100, 100);
      expect(rotationToward(o, const Offset(100, 0)), closeTo(0, 1e-9));
      expect(rotationToward(o, const Offset(200, 100)), closeTo(90, 1e-9));
      expect(rotationToward(o, const Offset(100, 200)), closeTo(180, 1e-9));
      expect(rotationToward(o, const Offset(0, 100)), closeTo(270, 1e-9));
    });

    test('off-axis angle from the screen center line', () {
      // Screen facing down the sheet; projector straight below is square.
      const s = Offset(0, 0);
      expect(offAxisAngle(s, 180, const Offset(0, 100)), closeTo(0, 1e-9));
      expect(offAxisAngle(s, 180, const Offset(100, 100)), closeTo(45, 1e-9));
      expect(angleBetweenRotations(350, 10), 20);
    });

    test('square to screen faces it and sits on its center line', () {
      expect(squareToScreen(180), 0);
      expect(squareToScreen(270), 90);
      final p = pointOnCenterLine(Offset.zero, 90, 50);
      expect(p.dx, closeTo(50, 1e-9));
      expect(p.dy, closeTo(0, 1e-9));
    });

    test('a projector pairs with the nearest screen', () {
      const proj = PlanDevice(
        id: 'DEV_1',
        deviceKey: 'p',
        label: 'Projector',
        shape: 'projector',
        pos: Offset(0, 0),
      );
      const near = PlanDevice(
        id: 'DEV_2',
        deviceKey: 's',
        label: 'Near',
        shape: 'screen',
        pos: Offset(0, 100),
      );
      const far = PlanDevice(
        id: 'DEV_3',
        deviceKey: 's',
        label: 'Far',
        shape: 'screen',
        pos: Offset(0, 500),
      );
      // A screen keeps its width through a save; other devices do not
      // write one.
      final back = PlanDevice.fromJson(near.copyWith(width: 96).toJson());
      expect(back.width, 96);
      expect(proj.toJson(), isNot(contains('width')));
      const devices = [proj, far, near];
      expect(projectionPartner(devices, proj)?.id, 'DEV_2');
      expect(projectionPartner(devices, far)?.id, 'DEV_1');
      expect(deviceShapeHasFov('screen'), isTrue);
      // Screens still do not turn on the cabling drawing.
      expect(deviceShapeAims('screen'), isFalse);
    });
  });

  group('specs off the catalog', () {
    test('reads the throw ratio and lumens from notes', () {
      expect(
        parseThrowRatio('Throw ratio (WUXGA / WXGA): 1.44 to 2.32 / NA'),
        (1.44, 2.32),
      );
      expect(parseThrowRatio('Throw ratio (WUXGA / WXGA): 0.35:1'), (0.35, 0.35));
      expect(parseThrowRatio('No ratio here'), isNull);
      final dash = String.fromCharCode(0x2013);
      expect(parseThrowRatio('Throw ratio: 1.2${dash}1.8'), (1.2, 1.8));
      expect(parseLumens('7,000 Lumens, Laser, WUXGA'), 7000);
      expect(parseLumens('6,200 lm WUXGA Laser LCD'), 6200);
      expect(parseLumens('nothing'), 0);
    });

    test('own fields win over the notes', () {
      const t = AvDeviceTemplate(
        model: 'PJ-1',
        category: 'Projector',
        notes: '5,000 Lumens. Throw ratio: 1.2 to 1.9',
        throwRatioMin: 1.4,
        throwRatioMax: 2.2,
        ports: [],
      );
      final s = projectorSpecsOf(t)!;
      expect(s.throwMin, 1.4);
      expect(s.throwMax, 2.2);
      expect(s.lumens, 5000);
      expect(s.throwLabel, '1.4 - 2.2:1');
      expect(templateTakesProjection(t), isTrue);
    });

    test('a lens supplies the throw and the projector the lumens', () {
      const pj = AvDeviceTemplate(
        model: 'PJ-2',
        category: 'Projector',
        lumens: 8000,
        ports: [],
      );
      const lens = AvDeviceTemplate(
        model: 'Middle-Throw Lens #1',
        notes: 'Throw ratio (WUXGA / WXGA): 1.44 to 2.32 / NA',
        ports: [],
      );
      final choices = projectorSpecChoices([pj], [lens]);
      expect(choices, hasLength(2));
      expect(choices.last.source, 'Middle-Throw Lens #1');
      expect(choices.last.throwMin, 1.44);
      expect(choices.last.lumens, 8000);
    });

    test('throw and lumens survive the catalog file', () {
      const t = AvDeviceTemplate(
        model: 'PJ-3',
        throwRatioMin: 1.2,
        throwRatioMax: 1.8,
        lumens: 6000,
        ports: [],
      );
      final back = AvDeviceTemplate.fromJson(t.toJson());
      expect(back.throwRatioMin, 1.2);
      expect(back.throwRatioMax, 1.8);
      expect(back.lumens, 6000);
      expect(
        AvDeviceTemplate.fromJson({'model': 'x', 'lumens': 'lots'}).lumens,
        0,
      );
      expect(const AvDeviceTemplate(model: 'y', ports: []).toJson(),
          isNot(contains('lumens')));
    });
  });

  group('calculator dialog', () {
    Future<void> open(
      WidgetTester tester, {
      List<ProjectorSpecs> specs = const [],
      double? distanceFt,
      ValueChanged<double>? onSave,
    }) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectionCalculatorDialog(
              specs: specs,
              distanceFt: distanceFt,
              onSaveDistance: onSave,
            ),
          ),
        ),
      );
    }

    testWidgets('fills the throw from the specs and gives the distance', (
      tester,
    ) async {
      await open(
        tester,
        specs: const [
          ProjectorSpecs(source: 'PJ', throwMin: 2, throwMax: 2, lumens: 5000),
        ],
      );
      // 120 inch 16:10 is 101.8 inches wide; 2:1 throws from 17 ft.
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('projection_result_distance')),
            )
            .data,
        '17\' 0"',
      );
      expect(find.byKey(const ValueKey('projection_brightness')), findsOneWidget);
      expect(find.byKey(const ValueKey('projection_zoom')), findsNothing);
    });

    testWidgets('a room distance starts it from the distance and saves', (
      tester,
    ) async {
      double? saved;
      await open(
        tester,
        specs: const [ProjectorSpecs(source: 'PJ', throwMin: 1.5, throwMax: 2)],
        distanceFt: 15,
        onSave: (v) => saved = v,
      );
      expect(find.byKey(const ValueKey('projection_distance')), findsOneWidget);
      expect(find.byKey(const ValueKey('projection_zoom')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('projection_save_distance')));
      await tester.pump();
      expect(saved, 15);
    });

    testWidgets('the screen size can be typed in feet, and is drawn', (
      tester,
    ) async {
      await open(
        tester,
        specs: const [ProjectorSpecs(source: 'PJ', throwMin: 2, throwMax: 2)],
      );
      expect(find.byKey(const ValueKey('projection_diagram')), findsOneWidget);
      String distance() => tester
          .widget<Text>(find.byKey(const ValueKey('projection_result_distance')))
          .data!;
      final before = distance();

      // Switching to feet converts 120 in to 10 ft: same screen, same throw.
      await tester.tap(find.text('ft').first);
      await tester.pump();
      final size = tester.widget<TextField>(
        find.byKey(const ValueKey('projection_size')),
      );
      expect(size.controller!.text, '10');
      expect(distance(), before);

      await tester.enterText(find.byKey(const ValueKey('projection_size')), '5');
      await tester.pump();
      expect(distance(), isNot(before));
      expect(tester.takeException(), isNull);
    });

    testWidgets('asks for a throw ratio when there is none', (tester) async {
      await open(tester);
      expect(
        find.textContaining('Enter the projector\'s throw ratio'),
        findsOneWidget,
      );
    });
  });
}
