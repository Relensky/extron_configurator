import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/projection_calc.dart';

/// Readable from: whether a seat can read a screen or display.
void main() {
  group('the readability rule', () {
    test('reads out to 6 image heights, watches out to 8', () {
      expect(farthestViewer(5), 30);
      expect(farthestWatcher(5), 40);
      expect(readabilityAt(height: 5, distance: 12), Readability.readable);
      expect(readabilityAt(height: 5, distance: 30), Readability.readable);
      expect(readabilityAt(height: 5, distance: 31), Readability.watchOnly);
      expect(readabilityAt(height: 5, distance: 40), Readability.watchOnly);
      expect(readabilityAt(height: 5, distance: 41), Readability.tooFar);
      expect(Readability.readable.ok, isTrue);
      expect(Readability.watchOnly.ok, isFalse);
    });

    test('within 60 degrees either side of straight on', () {
      expect(kReadableHalfAngle, 60);
      expect(
        readabilityAt(height: 5, distance: 10, offAxis: 60),
        Readability.readable,
      );
      expect(
        readabilityAt(height: 5, distance: 10, offAxis: 61),
        Readability.offToSide,
      );
    });

    test('a 75 inch display reads to about 18 ft', () {
      // 75" 16:9 is about 5' 5" wide and 3' 1" high.
      final w = widthFromDiagonalInches(75);
      final h = imageHeightFromWidth(w);
      expect(farthestViewer(h), closeTo(18.4, 0.1));
      expect(planImageHeight('display', w), closeTo(h, 1e-9));
      // A plan screen is 16:10.
      expect(planImageHeight('screen', 16), 10);
      expect(planImageHeight('camera', 16), 0);
    });

    test('content types read to the CTS dashboard\'s image heights', () {
      expect(
        {for (final c in ReadingContent.values) c.name: c.heights},
        {'video': 8, 'slides': 6, 'documents': 5, 'spreadsheets': 4},
      );
      expect(ReadingContent.fromName('documents'), ReadingContent.documents);
      expect(ReadingContent.fromName('nope'), ReadingContent.slides);
      // 5 ft high: spreadsheets to 20, documents 25, slides 30, video 40.
      Readability at(double d, ReadingContent c) =>
          readabilityAt(height: 5, distance: d, content: c);
      expect(at(20, ReadingContent.spreadsheets), Readability.readable);
      expect(at(21, ReadingContent.spreadsheets), Readability.watchOnly);
      expect(at(25, ReadingContent.documents), Readability.readable);
      expect(at(40, ReadingContent.video), Readability.readable);
      expect(at(41, ReadingContent.video), Readability.tooFar);
      expect(
        contentReadAt(height: 5, distance: 22),
        [ReadingContent.video, ReadingContent.slides, ReadingContent.documents],
      );
      expect(contentReadAt(height: 5, distance: 10, offAxis: 70), isEmpty);
    });

    test('lengths show in feet and inches with centimeters', () {
      expect(feetAndCm(18 + 4 / 12), '18\' 4" (559 cm)');
      expect(feetAndCm(10), '10\' 0" (305 cm)');
    });
  });

  testWidgets('a seat on the plan or a typed distance is checked', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    final plan = p.activeFloorPlan!;
    p.updateAvFloorPlan(plan.copyWith(pixelsPerFoot: 20));
    // 3.2 ft wide at 16:9 is 1.8 ft high: readable to 10' 10", 216 px.
    p.addAvPlanDevice(
      plan.id,
      const PlanDevice(
        id: '',
        deviceKey: 'generic:display',
        label: 'Display',
        shape: 'display',
        pos: Offset(300, 150),
        rotation: 180,
        width: 64,
      ),
    );
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: FloorPlanView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith('Display\n'),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan_device_readable')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_readable_range')), findsOneWidget);
    String readout() => tester
        .widget<Text>(find.byKey(const ValueKey('plan_device_readable_readout')))
        .data!;
    String result() => tester
        .widget<Text>(find.byKey(const ValueKey('plan_device_readable_result')))
        .data!;
    expect(readout(), contains('readable to 10\' 10" (329 cm)'));
    expect(find.byKey(const ValueKey('plan_device_readable_result')),
        findsNothing);

    // Plan spots to the screen: the sheet's corner, at the view's zoom.
    // The corner is read each time, since the bar above grows a line.
    final scale = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    Future<void> seat(Offset at) async {
      final origin = tester
          .getTopLeft(find.byKey(const ValueKey('plan_readable_range')));
      await tester.tapAt(origin + at * scale);
      // Past the double-click wait, so the next tap is a tap of its own.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    // 10 ft straight out in front.
    await seat(const Offset(300, 350));
    expect(readout(), contains('viewer 10\' 0" (305 cm), 0° off center'));
    expect(result(), Readability.readable.label);
    String summary() => tester
        .widget<Text>(
            find.byKey(const ValueKey('plan_device_readable_content_summary')))
        .data!;
    // Documents read to 9 ft, spreadsheets to 7' 2".
    expect(summary(), 'Reads video, slides; too far for documents, '
        'spreadsheets');
    // 13 ft: past 6 image heights, inside 8.
    await seat(const Offset(300, 410));
    expect(result(), Readability.watchOnly.label);
    expect(summary(), 'Reads video; too far for slides, documents, '
        'spreadsheets');

    // Video reads to 8 image heights, so 13 ft reads it.
    await tester.tap(find.byKey(const ValueKey('plan_device_readable_content')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey('plan_device_readable_content_video')));
    await tester.pumpAndSettle();
    expect(result(), Readability.readable.label);
    expect(readout(), contains('readable to 14\' 5"'));
    // Spreadsheets, 4 heights: 7' 2".
    await tester.tap(find.byKey(const ValueKey('plan_device_readable_content')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
        const ValueKey('plan_device_readable_content_spreadsheets')));
    await tester.pumpAndSettle();
    expect(result(), Readability.watchOnly.label);
    expect(readout(), contains('readable to 7\' 2"'));
    // Back to slides for the rest.
    await tester.tap(find.byKey(const ValueKey('plan_device_readable_content')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey('plan_device_readable_content_slides')));
    await tester.pumpAndSettle();
    // Beside it.
    await seat(const Offset(500, 150));
    expect(result(), Readability.offToSide.label);
    // The tap picked a seat and left the display selected.
    expect(find.byKey(const ValueKey('plan_device_readable')), findsOneWidget);

    // Typed: no angle, distance only.
    final field = find.byKey(const ValueKey('plan_device_readable_distance'));
    await tester.enterText(field, '9\' 6"');
    await tester.pump();
    expect(readout(), contains('viewer 9\' 6" (290 cm)'));
    expect(readout(), isNot(contains('off center')));
    expect(result(), Readability.readable.label);
    await tester.enterText(field, '20');
    await tester.pump();
    expect(result(), Readability.tooFar.label);
    expect(tester.takeException(), isNull);
  });
}
