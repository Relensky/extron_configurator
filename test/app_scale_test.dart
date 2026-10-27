import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_scale.dart';

/// The app is fitted to the monitor and drawn at the size chosen in App
/// Config, whatever Windows' display scaling is.
void main() {
  Future<({Size size, double dpr})> measure(
    WidgetTester tester, {
    required double windowsScale,
    required double appScale,
    Size? screen,
    VoidCallback? onTap,
  }) async {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = windowsScale;
    addTearDown(tester.view.reset);
    if (screen != null) {
      tester.view.display.size = screen;
      addTearDown(tester.view.display.reset);
    }
    late Size size;
    late double dpr;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScale(
          scale: appScale,
          fitToMonitor: screen != null,
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              size = MediaQuery.sizeOf(context);
              dpr = MediaQuery.devicePixelRatioOf(context);
              return Center(
                child: ElevatedButton(
                  onPressed: onTap,
                  child: const Text('Press'),
                ),
              );
            },
          ),
        ),
      ),
    );
    return (size: size, dpr: dpr);
  }

  testWidgets('at 100% the app is the size it is at Windows 100%',
      (tester) async {
    final m = await measure(tester, windowsScale: 1.5, appScale: 1.0);
    // 1800 physical pixels are 1800 of the app's, not 1200.
    expect(m.size, const Size(1800, 1200));
    expect(m.dpr, 1.0);
  });

  testWidgets('a chosen size is used however Windows is set', (tester) async {
    final m = await measure(tester, windowsScale: 1.0, appScale: 1.5);
    expect(m.size, const Size(1200, 800));
    expect(m.dpr, 1.5);
  });

  testWidgets('Follow Windows leaves its scaling alone', (tester) async {
    final m = await measure(tester, windowsScale: 1.5, appScale: 0);
    expect(m.size, const Size(1200, 800));
  });

  testWidgets('presses still land on what is under the pointer',
      (tester) async {
    var pressed = 0;
    await measure(
      tester,
      windowsScale: 1.5,
      appScale: 1.0,
      onTap: () => pressed++,
    );
    await tester.tap(find.text('Press'));
    expect(pressed, 1);
  });

  group('fitted to the monitor', () {
    testWidgets('1080p is the reference layout at any Windows scale',
        (tester) async {
      final m = await measure(tester,
          windowsScale: 1.25, appScale: 1.0, screen: const Size(1920, 1080));
      expect(m.dpr, 1.0);
      expect(m.size, const Size(1800, 1200));
    });

    testWidgets('4K shows the same layout, only sharper', (tester) async {
      final m = await measure(tester,
          windowsScale: 1.5, appScale: 1.0, screen: const Size(3840, 2160));
      expect(m.dpr, 2.0);
      expect(m.size, const Size(900, 600));
    });

    testWidgets('Interface Size zooms on top of the fit', (tester) async {
      final m = await measure(tester,
          windowsScale: 1.0, appScale: 1.5, screen: const Size(2560, 1440));
      expect(m.dpr, closeTo(2.0, 1e-9));
    });

    testWidgets('a small laptop is never fitted below 75%', (tester) async {
      final m = await measure(tester,
          windowsScale: 1.0, appScale: 1.0, screen: const Size(1280, 720));
      expect(m.dpr, AppScale.minFit);
    });

    testWidgets('a portrait monitor gets the landscape scale', (tester) async {
      final m = await measure(tester,
          windowsScale: 1.0, appScale: 1.0, screen: const Size(1080, 1920));
      expect(m.dpr, 1.0);
    });

    testWidgets('Follow Windows still leaves its scaling alone',
        (tester) async {
      final m = await measure(tester,
          windowsScale: 1.5, appScale: 0, screen: const Size(3840, 2160));
      expect(m.size, const Size(1200, 800));
    });

    testWidgets('presses land on what is under the pointer', (tester) async {
      var pressed = 0;
      await measure(tester,
          windowsScale: 1.5,
          appScale: 1.0,
          screen: const Size(3840, 2160),
          onTap: () => pressed++);
      await tester.tap(find.text('Press'));
      expect(pressed, 1);
    });

    // Crossing monitors mid-drag re-laid-out the whole app at every crossing;
    // the fit now changes once, when the window is let go.
    testWidgets('the fit is held through a drag and applied on release',
        (tester) async {
      addTearDown(() => AppScale.windowMoving.value = false);
      var m = await measure(tester,
          windowsScale: 1.0, appScale: 1.0, screen: const Size(1920, 1080));
      expect(m.dpr, 1.0);
      AppScale.windowMoving.value = true;
      m = await measure(tester,
          windowsScale: 1.0, appScale: 1.0, screen: const Size(3840, 2160));
      expect(m.dpr, 1.0, reason: 'held mid-drag');
      AppScale.windowMoving.value = false;
      await tester.pump();
      m = await measure(tester,
          windowsScale: 1.0, appScale: 1.0, screen: const Size(3840, 2160));
      expect(m.dpr, 2.0);
    });
  });
}
