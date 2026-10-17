import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';

/// Edit shape: a box can be drawn wider and taller by hand, and its side
/// ports spread out to fill it.
void main() {
  AvNode switchBox() => AvNode(
        id: 'AVNODE_1',
        label: 'Switch',
        model: '',
        pos: const Offset(40, 60),
        ports: [
          for (var i = 1; i <= 4; i++)
            AvPort(
              id: 'p$i',
              label: 'IN $i',
              signal: SignalType.network,
              direction: PortDirection.bidirectional,
              side: i <= 2 ? PortSide.left : PortSide.right,
            ),
        ],
      );

  test('a hand size wins, but never cuts off the side ports', () {
    final auto = switchBox();
    final big = auto.copyWith(customWidth: 600, customHeight: 400);
    expect(big.width, 600);
    expect(big.height, 400);
    // The rows spread to fill the extra height.
    expect(big.rowPitch, greaterThan(kAvPortRowHeight));
    expect(big.localAnchorOf('p2').dy, greaterThan(auto.localAnchorOf('p2').dy));
    expect(big.localAnchorOf('p3').dx, 600);

    final tiny = auto.copyWith(customWidth: 10, customHeight: 10);
    expect(tiny.width, kAvNodeMinShapeWidth);
    expect(tiny.height, auto.autoHeight);

    final back = AvNode.fromJson(big.toJson());
    expect(back.customWidth, 600);
    expect(back.customHeight, 400);
    expect(auto.toJson().containsKey('width'), isFalse);
  });

  testWidgets('Edit shape shows handles that resize the box', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    provider.loadAvFlowForCurrentConfig();
    provider.addAvNode(switchBox());
    final before = provider.avNodeById('AVNODE_1')!;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('av_edit_AVNODE_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('av_edit_shape')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('av_resize_corner_AVNODE_1'))),
    );
    for (var i = 0; i < 15; i++) {
      await gesture.moveBy(const Offset(10, 8));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final after = provider.avNodeById('AVNODE_1')!;
    // The first movement goes to drag slop, so allow for it.
    expect(after.width, greaterThan(before.width + 100));
    expect(after.height, greaterThan(before.height + 80));

    await tester.tap(find.byKey(const ValueKey('av_shape_reset')));
    await tester.pumpAndSettle();
    expect(provider.avNodeById('AVNODE_1')!.customWidth, 0);

    await tester.tap(find.byKey(const ValueKey('av_shape_done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('av_resize_corner_AVNODE_1')), findsNothing);
  });
}
