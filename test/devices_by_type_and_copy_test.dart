import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/dynamic_devices_view.dart';

/// The Devices page: devices broken down by type, each type shown or hidden,
/// and one device's settings copied onto another of its type.
void main() {
  late AppStateProvider provider;

  // The schema is loaded outside testWidgets: real file I/O awaited inside
  // one never completes.
  setUp(() async {
    provider = AppStateProvider(autoLoadSettings: false);
    await provider.loadUiSchema();
    provider.roomConfig = {
      'SYSTEM_SETUP': {'dev_cameras': '2', 'dev_projectors': '1'},
      'CAMERADEVICE_1': {
        'name': 'Camera 1',
        'model': 'TR311HW',
        'com_type': 'Network',
        'ip_address': '10.0.0.1',
        'net_port': 52381,
        'user': 'main',
        'ptz_speeds': [1, 2, 3],
      },
      'CAMERADEVICE_2': {
        'name': 'Camera 2',
        'model': 'Cam570',
        'com_type': 'Network',
        'ip_address': '10.0.0.2',
        'net_port': 1,
        'user': 'other',
      },
      'PROJECTORDEVICE_1': {
        'name': 'Projector',
        'model': 'PowerLite L630U',
        'com_type': 'Network',
      },
    };
  });

  Future<void> pump(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(home: Scaffold(body: body)),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('only devices of the same type are offered to copy from', () {
    expect(sameTypeDevices(provider, 'CAMERADEVICE_2'), ['CAMERADEVICE_1']);
    expect(sameTypeDevices(provider, 'PROJECTORDEVICE_1'), isEmpty);
  });

  test('copying leaves the unit\'s own name and address alone', () {
    final n = provider.copyDeviceSettings(
      'CAMERADEVICE_1',
      'CAMERADEVICE_2',
      ['model', 'net_port', 'user', 'ptz_speeds'],
    );
    expect(n, 4);
    final cam2 = provider.roomConfig['CAMERADEVICE_2'] as Map;
    expect(cam2['model'], 'TR311HW');
    expect(cam2['net_port'], 52381);
    expect(cam2['user'], 'main');
    expect(cam2['ptz_speeds'], [1, 2, 3]);
    expect(cam2['name'], 'Camera 2');
    expect(cam2['ip_address'], '10.0.0.2');
    // A copy, not the same list.
    (cam2['ptz_speeds'] as List).add(4);
    expect((provider.roomConfig['CAMERADEVICE_1'] as Map)['ptz_speeds'],
        [1, 2, 3]);
    // Already the same: nothing to do.
    expect(
      provider.copyDeviceSettings(
          'CAMERADEVICE_1', 'CAMERADEVICE_2', ['user']),
      0,
    );
  });

  testWidgets('the copy dialog starts with the per-unit settings unticked', (
    tester,
  ) async {
    await pump(
      tester,
      const DeviceConfigurationForm(deviceKey: 'CAMERADEVICE_2'),
    );
    await tester.tap(find.byKey(const ValueKey('device_copy_from')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('copy_device_settings_dialog')),
        findsOneWidget);
    bool ticked(String k) => tester
        .widget<CheckboxListTile>(find.byKey(ValueKey('copy_device_key_$k')))
        .value!;
    expect(ticked('name'), isFalse);
    expect(ticked('ip_address'), isFalse);
    expect(ticked('model'), isTrue);

    await tester.tap(find.byKey(const ValueKey('copy_device_go')));
    await tester.pumpAndSettle();
    final cam2 = provider.roomConfig['CAMERADEVICE_2'] as Map;
    expect(cam2['user'], 'main');
    expect(cam2['name'], 'Camera 2');
    expect(cam2['ip_address'], '10.0.0.2');
    expect(find.textContaining('from Camera 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a type can be hidden from the tabs and shown again', (
    tester,
  ) async {
    await pump(tester, const DynamicDevicesTabsView());
    expect(find.widgetWithText(Tab, 'Projector'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('devices_by_type')));
    await tester.pumpAndSettle();
    final projectors = find.byWidgetPredicate((w) =>
        w is FilterChip &&
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('devices_type_') &&
        w.label is Text &&
        ((w.label as Text).data ?? '').contains('(1)'));
    expect(projectors, findsOneWidget);
    await tester.tap(projectors);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Tab, 'Projector'), findsNothing);
    expect(find.widgetWithText(Tab, 'Camera 1'), findsOneWidget);

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Tab, 'Projector'), findsOneWidget);
    // Leave the page as other tests expect it.
    await tester.tap(find.byKey(const ValueKey('devices_by_type')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
