import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schematic_view.dart';

/// Dragging a box used to write its position to the provider on every pointer
/// move, so each frame of a drag rebuilt every listener in the app — the nav
/// rail, the app bar, the lot. The move is local now and lands in the provider
/// once, on release.
void main() {
  AppStateProvider roomWithOneProjector() {
    return AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'processor1': 'MainProcessor',
          'dev_projectors': '1',
        },
        'PROJECTORDEVICE_1': {
          'name': 'Projector 1',
          'model': 'VPL-PHZ60',
          'com_type': 'Network',
          'ip_address': '10.0.0.5',
          'protocol': 'TCP',
        },
      };
  }

  Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: SchematicView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a drag reaches the provider once, on release', (tester) async {
    final provider = roomWithOneProjector();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    int writes = 0;
    provider.addListener(() => writes++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Projector 1')),
    );
    for (int i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(5, 3));
      await tester.pump();
    }
    // Nothing has been written yet — the box is following the cursor locally.
    expect(writes, 0);
    expect(provider.schematicPositions, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(writes, 1);
    expect(provider.schematicPositions.containsKey('PROJECTORDEVICE_1'), isTrue);
  });

  testWidgets('the dragged box lands where it was dropped, not twice as far',
      (tester) async {
    final provider = roomWithOneProjector();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    final before = tester.getTopLeft(find.byType(SchematicView));
    final boxBefore =
        tester.getTopLeft(find.text('Projector 1')) - before;

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Projector 1')),
    );
    // One big move past the drag-slop threshold, then a measured one.
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(50, 30));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final boxAfter = tester.getTopLeft(find.text('Projector 1')) - before;
    final moved = boxAfter - boxBefore;

    // Regression guard on the commit path: it captures the position at drag
    // start, because by release the view's model is the PREVIEW and reading
    // the offset back off that would apply the drag a second time.
    expect(moved.dx, greaterThan(40));
    expect(moved.dx, lessThan(95));
    expect(moved.dy, greaterThan(0));
    expect(moved.dy, lessThan(45));
  });

  testWidgets('boxes do not drag while a line is being drawn', (tester) async {
    final provider = roomWithOneProjector();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Draw Line'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Projector 1')),
    );
    for (int i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(8, 8));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(provider.schematicPositions, isEmpty);
  });

  testWidgets('the tab is called Control Schematic', (tester) async {
    final provider = roomWithOneProjector();
    await pumpTab(tester, provider);

    expect(find.text('Control Schematic'), findsOneWidget);
    expect(find.text('Room Schematic'), findsNothing);
  });

  testWidgets('the legend sits below the lowest box, not over it', (
    tester,
  ) async {
    final provider = roomWithOneProjector();
    await pumpTab(tester, provider);

    // The legend's first entry names the network row; find the box that sits
    // lowest and check the key clears it.
    final legend = find.text('Network (via IDF)');
    expect(legend, findsOneWidget);

    final legendTop = tester.getTopLeft(legend).dy;
    final projectorBottom = tester.getBottomLeft(find.text('Projector 1')).dy;
    expect(
      legendTop,
      greaterThan(projectorBottom),
      reason: 'the legend must clear the diagram rather than overlap it',
    );
  });
}
