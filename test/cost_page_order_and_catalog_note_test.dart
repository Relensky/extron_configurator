import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';

/// Other items sit above Rack hardware, and a line whose part is in the
/// catalog with no price says it is an update that needs a price.
void main() {
  const roomPc = AvDeviceTemplate(
    model: 'Room PC',
    category: kCategoryMisc,
    powerInput: PowerInput.none,
    custom: true,
    ports: [],
  );

  Future<AppStateProvider> pump(WidgetTester tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Arts 111'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()..upsert(roomPc);
    p.addAvCostItem(description: 'Room PC');
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();
    return p;
  }

  testWidgets('Other items is above Rack hardware', (tester) async {
    await pump(tester);
    final items = tester.getTopLeft(find.text('Add other items')).dy;
    final rack = find.text('Rack hardware');
    expect(rack, findsWidgets);
    final rackTop = tester
        .widgetList(rack)
        .indexed
        .map((e) => tester.getTopLeft(rack.at(e.$1)).dy)
        .reduce((a, b) => a < b ? a : b);
    expect(items, lessThan(rackTop));
  });

  testWidgets('an unpriced catalog part is an update that needs a price',
      (tester) async {
    await pump(tester);
    const tip = 'Update Room PC in the device catalog - it has no price yet';
    expect(find.byTooltip(tip), findsOneWidget);
    await tester.tap(find.byTooltip(tip));
    await tester.pumpAndSettle();

    final note = find.byKey(const ValueKey('catalog_existing_note'));
    expect(
      tester.widget<Text>(note).data,
      '"Room PC" is in the catalog but has no price. Put in a list price to '
      'save it to the catalog.',
    );
    ElevatedButton save() => tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Save to catalog'));
    expect(save().onPressed, isNull);

    await tester.enterText(
        find.byKey(const ValueKey('catalog_list_price')), '899');
    await tester.pump();
    expect(save().onPressed, isNotNull);
    expect(
      tester.widget<Text>(note).data,
      'Saving updates "Room PC" in the catalog.',
    );
  });
}
