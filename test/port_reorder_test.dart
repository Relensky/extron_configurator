import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/av_port_editor.dart';
import 'package:extron_configurator/device_editor_view.dart';

/// Connector order is the order the sockets are drawn down the side of the box,
/// so matching it to the real panel is ordinary work — and a step at a time
/// with two arrows is a lot of clicks on a sixteen-input matrix. These drag the
/// handle the way a user does.
void main() {
  AvPort port(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.hdmi,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  AppStateProvider withCatalog(List<AvPort> ports) {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(AvDeviceTemplate(model: 'Switcher Y', ports: ports));
    return p;
  }

  Future<void> pump(
    WidgetTester tester,
    AppStateProvider provider,
    Widget child,
  ) async {
    tester.view.physicalSize = const Size(1800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Picks up the handle on [from]'s row and drops it on [onto]'s, the way a
  /// pointer does it.
  Future<void> dragRow(WidgetTester tester, String from, String onto) async {
    final handle = find
        .descendant(
          of: find.ancestor(
            of: find.widgetWithText(TextField, from),
            matching: find.byType(AvPortEditorRow),
          ),
          matching: find.byIcon(Icons.drag_indicator),
        )
        .first;
    final start = tester.getCenter(handle);
    final target = tester.getCenter(find.widgetWithText(TextField, onto));

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 200));
    // In steps: the list works out where the row would land from the moves it
    // sees, and one jump from end to end gives it nothing to work with.
    for (var step = 1; step <= 4; step++) {
      await gesture.moveTo(
        Offset.lerp(start, Offset(start.dx, target.dy), step / 4)!,
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  List<String> labels(AppStateProvider p) => [
    for (final port in p.avDeviceLibrary.templateForModel('Switcher Y')!.ports)
      port.label,
  ];

  group('the device editor connector list', () {
    testWidgets('drags a connector down the list', (tester) async {
      final provider = withCatalog([
        port('a', 'HDMI IN 1'),
        port('b', 'HDMI IN 2'),
        port('c', 'HDMI IN 3'),
      ]);
      await pump(tester, provider, const DeviceEditorView());
      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();

      expect(labels(provider), ['HDMI IN 1', 'HDMI IN 2', 'HDMI IN 3']);

      await dragRow(tester, 'HDMI IN 1', 'HDMI IN 3');

      // Moved to the end, and nothing was duplicated or dropped on the way.
      expect(labels(provider), ['HDMI IN 2', 'HDMI IN 3', 'HDMI IN 1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('drags a connector back up the list', (tester) async {
      final provider = withCatalog([
        port('a', 'HDMI IN 1'),
        port('b', 'HDMI IN 2'),
        port('c', 'HDMI IN 3'),
      ]);
      await pump(tester, provider, const DeviceEditorView());
      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();

      await dragRow(tester, 'HDMI IN 3', 'HDMI IN 1');

      expect(labels(provider), ['HDMI IN 3', 'HDMI IN 1', 'HDMI IN 2']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the arrows still work for a single-step nudge', (
      tester,
    ) async {
      final provider = withCatalog([
        port('a', 'HDMI IN 1'),
        port('b', 'HDMI IN 2'),
      ]);
      await pump(tester, provider, const DeviceEditorView());
      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();

      expect(labels(provider), ['HDMI IN 2', 'HDMI IN 1']);
    });

    testWidgets('a row keeps editing its own port after a drag', (
      tester,
    ) async {
      final provider = withCatalog([
        port('a', 'HDMI IN 1'),
        port('b', 'HDMI IN 2'),
      ]);
      await pump(tester, provider, const DeviceEditorView());
      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();

      await dragRow(tester, 'HDMI IN 1', 'HDMI IN 2');
      expect(labels(provider), ['HDMI IN 2', 'HDMI IN 1']);

      // Renaming the row that moved has to reach the port that moved, not
      // whatever is now sitting at its old index.
      await tester.enterText(
        find.widgetWithText(TextField, 'HDMI IN 1'),
        'PROGRAM OUT',
      );
      await tester.pumpAndSettle();

      expect(labels(provider), ['HDMI IN 2', 'PROGRAM OUT']);
      expect(tester.takeException(), isNull);
    });
  });

  /// The screen this was asked for: the AV Flow tab's per-device dialog, where
  /// a room's own copy of a device gets its connectors set up.
  group('the AV Flow device dialog', () {
    AppStateProvider seeded() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      p.addAvNode(
        AvNode(
          id: 'SWITCHERDEVICE_1',
          label: 'Switcher',
          model: 'SW4',
          pos: const Offset(40, 60),
          fromConfig: true,
          rackUnits: 1,
          ports: [port('a', 'HDMI IN 1'), port('b', 'HDMI IN 2')],
        ),
      );
      return p;
    }

    testWidgets('drags a connector and saves the new order', (tester) async {
      final provider = seeded();
      tester.view.physicalSize = const Size(1800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: AvFlowView())),
        ),
      );
      await tester.pumpAndSettle();

      // Edit mode reveals the per-device pencil.
      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('av_edit_SWITCHERDEVICE_1')));
      await tester.pumpAndSettle();

      await dragRow(tester, 'HDMI IN 1', 'HDMI IN 2');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      final saved = provider.avNodeById('SWITCHERDEVICE_1')!.ports;
      // The power inlet is appended on save, so compare only the signal ports.
      expect(
        [for (final p in saved.where((p) => !p.isPowerInlet)) p.label],
        ['HDMI IN 2', 'HDMI IN 1'],
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('row keys', () {
    test('follow the port, and stay unique when a file repeats an id', () {
      final unique = avPortRowKeys([port('a', 'IN 1'), port('b', 'IN 2')]);
      expect(unique.toSet().length, 2);

      // A hand-edited catalog can repeat an id. Two rows claiming the same key
      // is a crash in a reorderable list, not a cosmetic mix-up.
      final repeated = avPortRowKeys([
        port('a', 'IN 1'),
        port('a', 'IN 2'),
        port('a', 'IN 3'),
      ]);
      expect(repeated.toSet().length, 3);

      // The key is the port's, not the index's — so it travels with the port.
      final before = avPortRowKeys([port('a', 'IN 1'), port('b', 'IN 2')]);
      final after = avPortRowKeys([port('b', 'IN 2'), port('a', 'IN 1')]);
      expect(after.first, before.last);
      expect(after.last, before.first);
    });
  });
}
