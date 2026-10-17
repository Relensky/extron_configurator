import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/nav_rail.dart';

/// The Cost tab's Estimate only switch, and Other items taking another
/// catalog model like the equipment does.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        'PROJECTORDEVICE_1': {'name': 'Projector 1', 'model': 'L630U'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
      value: p,
      child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Estimate only hides the programming tabs and keeps the room',
      (tester) async {
    final p = room();
    p.addAvCostItem(description: 'Mount', unitPrice: 300);
    await pump(tester, p);
    expect(p.isEstimateRoom, isFalse);

    await tester.tap(find.byKey(const ValueKey('cost_estimate_only')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cost_estimate_only_go')));
    await tester.pumpAndSettle();

    expect(p.isEstimateRoom, isTrue);
    expect(p.roomConfig.containsKey('PROJECTORDEVICE_1'), isTrue,
        reason: 'nothing is deleted');
    expect(p.avCost.items, hasLength(1));
    final tabs = visibleNavTabs(estimateOnly: p.isEstimateRoom)
        .map((t) => t.tab)
        .toSet();
    for (final hidden in [
      AppTab.wizard,
      AppTab.devices,
      AppTab.system,
      AppTab.rawJson,
    ]) {
      expect(tabs.contains(hidden), isFalse);
    }
    for (final kept in [
      AppTab.avFlow,
      AppTab.floorPlan,
      AppTab.cabling,
      AppTab.racks,
      AppTab.photos,
    ]) {
      expect(tabs.contains(kept), isTrue);
    }
  });

  testWidgets('an Other items line is replaced with another catalog model',
      (tester) async {
    final p = room()
      ..avDeviceLibrary = (AvDeviceLibrary.empty()
        ..upsert(const AvDeviceTemplate(
            model: 'RPMAU', category: 'Mount / bracket', price: 300,
            ports: []))
        ..upsert(const AvDeviceTemplate(
            model: 'PRG-UNV', category: 'Mount / bracket', price: 250,
            ports: [])));
    final mount = p.addAvCostItem(
        description: 'RPMAU', catalogModel: 'RPMAU', category: 'Mount');
    await pump(tester, p);

    await tester.ensureVisible(find.byKey(ValueKey('item_swap_${mount.id}')));
    await tester.tap(find.byKey(ValueKey('item_swap_${mount.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog_swap_PRG-UNV')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog_swap_apply')));
    await tester.pumpAndSettle();

    final swapped = p.avCost.items.single;
    expect(swapped.catalogModel, 'PRG-UNV');
    expect(swapped.description, 'PRG-UNV');
    expect(swapped.category, 'Mount / bracket');
  });
}
