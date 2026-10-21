import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/cost_estimate_view.dart';

/// A "not priced" room link on the project's parts list lands on that room's
/// Cost page with the part's line in the MIDDLE of the screen, lit up - not at
/// the top of a long page with the reader left to find the row.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    // Enough rows that the last cable is well below the first screenful, and
    // not even built by the ListView until the page scrolls toward it.
    for (var i = 0; i < 25; i++) {
      p.addAvCostExtraEquipment(description: 'Owner display $i', qty: 1);
    }
    for (var i = 0; i < 10; i++) {
      p.addAvCostExtraCable(description: 'Cable $i', qty: 1);
    }
    return p;
  }

  Finder lit() => find.byWidgetPredicate((w) =>
      w is Container &&
      w.foregroundDecoration is BoxDecoration &&
      (w.foregroundDecoration as BoxDecoration).border != null);

  testWidgets('the requested line is centered and lit, once', (tester) async {
    tester.view.physicalSize = const Size(1900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = room();
    final target = p.avCost.extraCables.last.id;
    p.requestCostLine(target);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump();
    }

    expect(lit(), findsOneWidget);
    final box = tester.renderObject<RenderBox>(lit());
    final middle = box.localToGlobal(box.size.center(Offset.zero)).dy;
    expect((middle - 450).abs(), lessThan(120),
        reason: 'the line should sit in the middle of the 900px window');
    // Taken: a later visit to the page is not sent back to it.
    expect(p.requestedCostLine, isEmpty);

    // Lit for a few seconds, then the page is just the page again.
    await tester.pump(const Duration(seconds: 7));
    expect(lit(), findsNothing);
  });
}
