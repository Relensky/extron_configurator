import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cabling_view.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A room with its devices on the Devices tab and nothing drawn or priced
/// yet. The estimate is worked out from the AV Flow's boxes, so with none
/// it is empty, and the floor plan had nothing to place until somebody
/// happened to open the AV Flow tab.
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AppStateProvider configOnly() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'dev_switchers': '1',
          'dev_projectors': '1',
          'output_proj_1': '3B',
        },
        'SWITCHERDEVICE_1': {
          'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
          'model': 'DTP CrossPoint 84 4K IPCP MA 70',
          'com_type': 'Network',
        },
        'PROJECTORDEVICE_1': {
          'name': 'Projector - PowerLite L630U',
          'model': 'PowerLite L630U',
          'input': 'HDBaseT',
          'com_type': 'Network',
        },
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p, Widget page) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(home: Scaffold(body: page)),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('devices the estimate does not list are offered, once each', () {
    final model = AvFlowModel(
      nodes: const [
        AvNode(id: 'A', label: 'Lectern PC', model: '', pos: Offset.zero,
            ports: []),
        AvNode(id: 'B', label: 'Owned display', model: 'X', pos: Offset.zero,
            ports: [], excludeFromCost: true),
      ],
      cables: const [],
      racks: const [],
      rackSlots: const {},
      canvasSize: Size.zero,
      roomTitle: '',
      unplaced: const [
        AvUnplacedDevice(key: 'CAMERADEVICE_1', label: 'PTZ Camera',
            model: '', dismissed: false),
        AvUnplacedDevice(key: 'MICDEVICE_1', label: 'Mic', model: '',
            dismissed: true),
      ],
    );
    const priced = [
      RoomDeviceChoice(key: 'node:A', name: 'Lectern PC', qty: 1,
          shape: 'pc'),
    ];
    final units = withUnpricedDevices(priced, model);
    expect([for (final c in units) c.key],
        ['node:A', 'node:B', 'node:CAMERADEVICE_1']);
    expect(units.firstWhere((c) => c.key == 'node:CAMERADEVICE_1').shape,
        'camera');
    // A box taken off by hand stays off.
    expect(units.any((c) => c.key == 'node:MICDEVICE_1'), isFalse);

    final names = withUnpricedDevices(const [], model, byUnit: false);
    expect([for (final c in names) c.key],
        ['lectern pc', 'owned display', 'ptz camera']);
  });

  testWidgets('opening the Floor Plan draws the room and offers its devices', (
    tester,
  ) async {
    final p = configOnly();
    p.addFloorPlanSheet(name: 'Level 1');
    expect(p.avNodes, isEmpty);
    expect(p.roomCost.equipment, isEmpty);

    await pump(tester, p, const FloorPlanView());
    expect(p.avNodeById('SWITCHERDEVICE_1'), isNotNull);
    expect(p.avNodeById('PROJECTORDEVICE_1'), isNotNull);
    expect(
      p.planDeviceChoices.map((c) => c.key),
      containsAll(['node:SWITCHERDEVICE_1', 'node:PROJECTORDEVICE_1']),
    );

    await tester.tap(find.byKey(const ValueKey('plan_add_device')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('add_device_node:PROJECTORDEVICE_1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening Cabling draws the room and offers its devices', (
    tester,
  ) async {
    final p = configOnly();
    await pump(tester, p, const CablingView());
    expect(p.avNodeById('PROJECTORDEVICE_1'), isNotNull);
    expect(
      p.cablingDeviceChoices.map((c) => c.name),
      contains('Projector - PowerLite L630U'),
    );
    expect(tester.takeException(), isNull);
  });
}
