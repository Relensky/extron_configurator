import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';

/// The floor plan carries the AV Flow tab's zoom bar and magnifier: zoom out,
/// in, fit, 100%, and a lens that reads the sheet at full size.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: FloorPlanView())),
      ),
    );
    await tester.pump();
  }

  String level(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('av_zoom_level'))).data!;

  testWidgets('the zoom bar zooms the sheet and turns the magnifier on',
      (tester) async {
    await pump(tester, room());
    expect(find.byKey(const ValueKey('plan_zoom_bar')), findsOneWidget);
    expect(level(tester), '100%');

    await tester.tap(find.byKey(const ValueKey('av_zoom_in')));
    await tester.pump();
    expect(level(tester), '125%');

    await tester.tap(find.byKey(const ValueKey('av_zoom_actual')));
    await tester.pump();
    expect(level(tester), '100%');

    await tester.tap(find.byKey(const ValueKey('av_zoom_out')));
    await tester.pump();
    expect(level(tester), '80%');

    // The magnifier: its own zoom and size controls appear with it, and the
    // pointer tracker that moves the lens is laid over the sheet.
    expect(find.byKey(const ValueKey('plan_magnifier_tracker')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('av_zoom_magnifier')));
    await tester.pump();
    expect(find.byKey(const ValueKey('plan_magnifier_tracker')), findsOneWidget);
    expect(find.byKey(const ValueKey('av_lens_level')), findsOneWidget);
    expect(find.byKey(const ValueKey('av_zoom_lens_size')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('av_zoom_magnifier')));
    await tester.pump();
    expect(find.byKey(const ValueKey('plan_magnifier_tracker')), findsNothing);
  });
}
