import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';

/// The toolbar's device search, and a click on a run scrolling the cable list
/// below the drawing to its row.
void main() {
  const runs = 16;

  AvNode switcher() => AvNode(
    id: 'SWITCHERDEVICE_1',
    label: 'Switcher',
    model: 'SW4 HD 4K PLUS',
    pos: const Offset(40, 60),
    fromConfig: true,
    ports: [
      for (var i = 1; i <= runs; i++)
        AvPort(
          id: 'out_hdmi_$i',
          label: 'HDMI OUT $i',
          signal: SignalType.hdmi,
          direction: PortDirection.output,
          side: PortSide.right,
        ),
    ],
  );

  AvNode projector() => AvNode(
    id: 'PROJECTORDEVICE_1',
    label: 'Projector',
    model: 'PowerLite L610U',
    pos: const Offset(2400, 1400),
    fromConfig: true,
    ports: [
      for (var i = 1; i <= runs; i++)
        AvPort(
          id: 'in_hdmi_$i',
          label: 'HDMI IN $i',
          signal: SignalType.hdmi,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
    ],
  );

  AppStateProvider seeded() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(switcher());
    p.addAvNode(projector());
    for (var i = 1; i <= runs; i++) {
      p.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'out_hdmi_$i',
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_$i',
        signal: SignalType.hdmi,
      );
    }
    return p;
  }

  Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('picking a device from the search centers it and rings it',
      (tester) async {
    final provider = seeded();
    await pumpTab(tester, provider);

    final field = find.byKey(const ValueKey('av_device_search_field'));
    await tester.tap(field);
    await tester.pumpAndSettle();
    // Empty field: the whole list drops down.
    expect(find.byKey(const ValueKey('av_device_search_SWITCHERDEVICE_1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('av_device_search_PROJECTORDEVICE_1')),
        findsOneWidget);

    await tester.enterText(field, 'L610');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('av_device_search_SWITCHERDEVICE_1')),
        findsNothing);
    await tester.tap(
        find.byKey(const ValueKey('av_device_search_PROJECTORDEVICE_1')));
    await tester.pump();

    final ring = find.byKey(const ValueKey('av_found_ring'));
    expect(ring, findsOneWidget);
    // The box far down and right is now in the middle of the canvas.
    final viewer = tester.getRect(find.byType(InteractiveViewer));
    final at = tester.getRect(ring).center;
    expect((at - viewer.center).distance, lessThan(40));

    // The ring goes after a few seconds.
    await tester.pump(const Duration(seconds: 5));
    expect(ring, findsNothing);
  });

  testWidgets('clicking a run in Edit scrolls the cable list to its row',
      (tester) async {
    final provider = seeded();
    await pumpTab(tester, provider);
    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    final last = provider.avCables.last.id;
    final row = find.ancestor(
      of: find.byKey(ValueKey('av_cable_edit_$last')),
      matching: find.byType(Material),
    ).first;
    final list = find.byType(SingleChildScrollView).last;
    expect(tester.getRect(row).top, greaterThan(tester.getRect(list).bottom),
        reason: 'the last row starts off the bottom of the list');

    // The label's own tap, called directly: sixteen labels share a corridor
    // and a tap by position could land on a neighbor.
    final label = find.byKey(ValueKey('av_cable_label_$last'));
    tester
        .widget<GestureDetector>(
            find.descendant(of: label, matching: find.byType(GestureDetector))
                .first)
        .onTap!();
    // Not pumpAndSettle: the selected run's chevrons never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    final rowRect = tester.getRect(row);
    final listRect = tester.getRect(list);
    expect(rowRect.top, greaterThanOrEqualTo(listRect.top));
    expect(rowRect.bottom, lessThanOrEqualTo(listRect.bottom));
    expect(tester.widget<Material>(row).color, isNot(Colors.transparent));
  });

  testWidgets('the toolbar is in named groups that fold away', (tester) async {
    final provider = seeded();
    await pumpTab(tester, provider);
    for (final name in [
      'Edit',
      'Add and connect',
      'Layout and view',
      'Save and export',
    ]) {
      expect(find.byKey(ValueKey('av_group_$name')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('av_tidy_layout')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('av_group_Layout and view')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('av_tidy_layout')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('av_group_Layout and view')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('av_tidy_layout')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
