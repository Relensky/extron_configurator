import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schematic_view.dart';

/// Right-click on the Control Schematic: a line opens its edit dialog, a box
/// turns on Edit mode and its editor.
void main() {
  AppStateProvider room() => AppStateProvider(autoLoadSettings: false)
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
    }
    ..selectedProcessor = {'roomName': 'Test room'};

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: SchematicView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool editOn(WidgetTester tester) =>
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Edit'))
          .selected;

  test('a point on a line finds it; one off every line finds nothing', () {
    final model = SchematicModel.build(room());
    final edge = model.edges.first;
    final a = model.nodeById(edge.fromId)!.center;
    final b = model.nodeById(edge.toId)!.center;
    // Near either end, clear of any curve's bend.
    final near = Offset.lerp(a, b, 0.05)!;
    expect(schematicEdgeAt(model, near)?.autoId, edge.autoId);
    expect(schematicEdgeAt(model, const Offset(-500, -500)), isNull);
  });

  testWidgets('right-click on a line opens it for editing', (tester) async {
    final p = room();
    await pump(tester, p);
    final model = SchematicModel.build(p);
    final edge = model.edges.first;
    final a = model.nodeById(edge.fromId)!.center;
    final b = model.nodeById(edge.toId)!.center;
    // A point on the line that is not under a box.
    final onLine = [
      for (var t = 0.0; t <= 1; t += 0.05) Offset.lerp(a, b, t)!,
    ].firstWhere(
      (q) =>
          schematicEdgeAt(model, q) != null &&
          !model.nodes.any((n) =>
              (n.pos & const Size(kNodeWidth, kNodeHeight)).inflate(4)
                  .contains(q)),
    );
    final origin =
        tester.getTopLeft(find.byKey(const ValueKey('schematic_lines')));
    await tester.tapAt(origin + onLine, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Edit Connection Line'), findsOneWidget);
    expect(editOn(tester), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-click on a box turns Edit on and says where it is set', (
    tester,
  ) async {
    final p = room();
    await pump(tester, p);
    expect(editOn(tester), isFalse);
    await tester.tap(find.text('Projector 1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(editOn(tester), isTrue);
    expect(find.textContaining('on the Devices tab'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(p.requestedDeviceKey, 'PROJECTORDEVICE_1');
    expect(p.selectedTabIndex, AppTab.devices.index);
    expect(tester.takeException(), isNull);
  });
}
