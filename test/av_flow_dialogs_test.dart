import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// The AV tab's dialogs are built inside the tab, so anything that throws
/// while they lay out takes the whole tab down to a gray screen rather than
/// showing an error in one dialog.
///
/// Regression: the device and cable dialogs put a [Spacer] between their
/// actions. AlertDialog lays actions out in an OverflowBar, which is not a
/// Flex, so the Expanded inside Spacer asserted and grayed out the tab the
/// moment you clicked a device's edit pencil.
void main() {
  AvNode switcher() => const AvNode(
    id: 'SWITCHERDEVICE_1',
    label: 'Switcher',
    model: 'SW4 HD 4K PLUS',
    pos: Offset(40, 60),
    fromConfig: true,
    rackUnits: 1,
    ports: [
      AvPort(
        id: 'in_hdmi_1',
        label: 'HDMI IN 1',
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
      ),
      AvPort(
        id: 'out_hdmi_1',
        label: 'HDMI OUT',
        signal: SignalType.hdmi,
        direction: PortDirection.output,
        side: PortSide.right,
      ),
    ],
  );

  AvNode projector() => const AvNode(
    id: 'PROJECTORDEVICE_1',
    label: 'Projector',
    model: 'PowerLite L610U',
    pos: Offset(500, 60),
    fromConfig: true,
    ports: [
      AvPort(
        id: 'in_hdmi_1',
        label: 'HDMI 1',
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
      ),
    ],
  );

  /// A provider holding a room with two devices already on the canvas.
  ///
  /// The sync has to happen BEFORE the nodes go in: opening the tab calls
  /// ensureAvFlowForCurrentConfig, which reloads (and therefore clears) the
  /// diagram the first time it sees a given config. Doing it here means the
  /// tab's own call is a no-op and the fixture survives.
  AppStateProvider seeded() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(switcher());
    p.addAvNode(projector());
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

  testWidgets('the device edit dialog opens instead of graying out the tab', (
    tester,
  ) async {
    final provider = seeded();
    await pumpTab(tester, provider);

    // Edit mode reveals the per-device pencil.
    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('av_edit_SWITCHERDEVICE_1')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Connectors'), findsOneWidget);
    expect(find.text('Remove device'), findsOneWidget);
  });

  testWidgets('the device dialog saves a retyped name and rack height', (
    tester,
  ) async {
    final provider = seeded();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('av_edit_SWITCHERDEVICE_1')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Main Switcher',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Rack U'), '3');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final node = provider.avNodeById('SWITCHERDEVICE_1')!;
    expect(node.label, 'Main Switcher');
    expect(node.rackUnits, 3);
  });

  testWidgets('every port row control is reachable, including delete', (
    tester,
  ) async {
    final provider = seeded();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('av_edit_SWITCHERDEVICE_1')));
    await tester.pumpAndSettle();

    // Regression: the row's fixed widths added up to more than the dialog, so
    // the delete button sat past the right edge — rendered, but off-screen and
    // impossible to click. An overflow shows up as an exception here.
    expect(tester.takeException(), isNull);

    final deletes = find.widgetWithIcon(IconButton, Icons.delete_outline);
    expect(deletes, findsNWidgets(2)); // one per port

    await tester.tap(deletes.first);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final node = provider.avNodeById('SWITCHERDEVICE_1')!;
    expect(node.ports.length, 1);
    expect(node.ports.single.id, 'out_hdmi_1');
  });

  testWidgets('deleting a port takes the cable plugged into it', (
    tester,
  ) async {
    final provider = seeded();
    provider.addAvCable(
      fromNodeId: 'SWITCHERDEVICE_1',
      fromPortId: 'out_hdmi_1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
    );
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('av_edit_SWITCHERDEVICE_1')));
    await tester.pumpAndSettle();

    // Second row is HDMI OUT, the cabled one.
    await tester.tap(
      find.widgetWithIcon(IconButton, Icons.delete_outline).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(provider.avCables, isEmpty);
  });

  testWidgets('a cable can be recolored away from its signal type', (
    tester,
  ) async {
    final provider = seeded();
    provider.addAvCable(
      fromNodeId: 'SWITCHERDEVICE_1',
      fromPortId: 'out_hdmi_1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
    );
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('av_cable_edit_C1')));
    await tester.pumpAndSettle();

    expect(find.text('Following the signal type'), findsOneWidget);

    // Red, which is nothing like HDMI's blue.
    await tester.tap(find.byKey(const ValueKey('cable_color_ef5350')));
    await tester.pumpAndSettle();
    expect(find.text('Custom for this run'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final cable = provider.avCables.single;
    expect(cable.hasCustomColor, isTrue);
    expect(cable.colorFor(), isNot(kSignalColors[SignalType.hdmi]));
  });

  testWidgets('the cable dialog opens from the cable list', (tester) async {
    final provider = seeded();
    provider.addAvCable(
      fromNodeId: 'SWITCHERDEVICE_1',
      fromPortId: 'out_hdmi_1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
    );
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('av_cable_edit_C1')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Cable C1'), findsOneWidget);
    expect(find.text('Clear bends'), findsOneWidget);
  });

  testWidgets('connectors only respond to clicks in Draw Cable mode', (
    tester,
  ) async {
    final provider = seeded();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    // Edit mode alone: a connector click must NOT arm a cable, so that a
    // click-with-a-pixel-of-travel stays a drag rather than half a cable.
    await tester.tap(find.text('HDMI OUT'));
    await tester.pumpAndSettle();
    expect(find.text('Pick 2nd connector...'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Draw Cable'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('HDMI OUT'));
    await tester.pumpAndSettle();
    expect(find.text('Pick 2nd connector...'), findsOneWidget);

    await tester.tap(find.text('HDMI 1'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(provider.avCables.length, 1);
    expect(provider.avCables.single.toNodeId, 'PROJECTORDEVICE_1');
  });

  testWidgets('dragging a device only writes its position once, on release', (
    tester,
  ) async {
    final provider = seeded();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    final start = provider.avNodeById('SWITCHERDEVICE_1')!.pos;
    int writes = 0;
    provider.addListener(() => writes++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Switcher')),
    );
    for (int i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(6, 4));
      await tester.pump();
    }
    // Mid-drag the provider has not been touched at all: the move is local
    // until release, so a drag doesn't rebuild every listener in the app.
    expect(writes, 0);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(writes, 1);
    // The pan recognizer eats the first movement as drag slop, so assert the
    // direction and that the device actually moved rather than an exact delta.
    final moved = provider.avNodeById('SWITCHERDEVICE_1')!.pos;
    expect(moved.dx, greaterThan(start.dx));
    expect(moved.dy, greaterThan(start.dy));
    expect(moved.dx - start.dx, greaterThan(moved.dy - start.dy));
  });

  /// A cable schedule is an ORDER, so every run has to be able to say what
  /// length of lead it is. Setting that one dialog at a time for a room with
  /// twenty runs is twenty chances to miss one, so the bulk control is the
  /// primary path and the per-cable dropdown is the exception.
  group('cable lengths', () {
    AppStateProvider cabled() {
      final p = seeded();
      p.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'out_hdmi_1',
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_1',
        signal: SignalType.hdmi,
      );
      return p;
    }

    testWidgets('the cable dialog sets a length and keeps it', (tester) async {
      final provider = cabled();
      await pumpTab(tester, provider);

      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('av_cable_edit_C1')));
      await tester.pumpAndSettle();

      expect(find.text('Not set'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cable_length')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15ft').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(provider.avCables.single.lengthFt, 15);
    });

    testWidgets('the bulk dialog sets every run at once', (tester) async {
      final provider = cabled();
      // A second run, so "apply to all" has something to be about.
      provider.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'in_hdmi_1',
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_1',
        signal: SignalType.hdmi,
      );
      await pumpTab(tester, provider);

      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('av_cable_lengths')));
      await tester.pumpAndSettle();
      expect(find.text('Cable lengths'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('av_lengths_bulk')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('25ft').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('av_lengths_apply_all')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(provider.avCables, hasLength(2));
      expect(provider.avCables.every((c) => c.lengthFt == 25), isTrue);
      // One undo entry for the lot, not one per run.
      expect(provider.avUndoLabel(AvUndoScope.flow), 'Set cable lengths');
    });

    testWidgets('the button stays away until there is a run to measure', (
      tester,
    ) async {
      final provider = seeded();
      await pumpTab(tester, provider);
      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('av_cable_lengths')), findsNothing);
    });
  });
}
