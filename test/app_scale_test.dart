import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/main.dart' show AppScale;

/// The app is drawn at the size chosen in App Config, whatever Windows'
/// display scaling is.
void main() {
  Future<({Size size, double dpr})> measure(
    WidgetTester tester, {
    required double windowsScale,
    required double appScale,
    VoidCallback? onTap,
  }) async {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = windowsScale;
    addTearDown(tester.view.reset);
    late Size size;
    late double dpr;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScale(scale: appScale, child: child!),
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
}
