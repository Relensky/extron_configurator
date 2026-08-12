import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/dynamic_devices_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// The trash button on a device field worked, and the field came straight
/// back.
///
/// The schema offers a handful of keys BEFORE they exist in a block —
/// "addIfMissing" on device_id, service_port, use_device_mute, the keep-alive
/// fields, baud — so a device converted to a serial box still has somewhere to
/// type one in. That placeholder is also what made those keys look permanent:
/// the delete removed the key and the missing-field pass drew the field again,
/// so nothing appeared to happen. An AV Bridge 2x1 was the case that showed it.
///
/// The fields with a SLOT of their own — model, module, keep alive, input, and
/// a projector's individual-mode input — had no trash button at all.
void main() {
  // Loaded ONCE, out here: testWidgets runs its body in a fake-async zone, and
  // real file I/O awaited inside one never completes.
  late UiSchema schema;
  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  /// A device block as a conversion leaves it, with the confirmation dialog
  /// turned off so a delete is one tap.
  AppStateProvider room(Map<String, dynamic> device) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..confirmBeforeDelete = false;
    p.roomConfig = {
      'SYSTEM_SETUP': {'dev_switchers': '1', 'dev_projectors': '1'},
      ...device,
    };
    return p;
  }

  /// Pumped rather than settled: the keep-alive slot spins a
  /// CircularProgressIndicator while a module is parsed, and pumpAndSettle
  /// waits ten minutes for an animation that never stops.
  Future<void> pump(WidgetTester tester, AppStateProvider provider,
      String deviceKey) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: DeviceConfigurationForm(deviceKey: deviceKey)),
        ),
      ),
    );
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Asserts the field whose label mentions [key] has a trash button next to
  /// it.
  ///
  /// Scrolled to first: the form is a lazy ListView and the placeholder fields
  /// are appended at the bottom of it, so the very keys this is about are the
  /// ones not built until the page is scrolled.
  Future<void> expectDeletable(WidgetTester tester, String key) async {
    final label = find.textContaining(key, findRichText: true);
    await tester.scrollUntilVisible(
      label,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
    expect(
      find.descendant(
        of: find.ancestor(of: label.first, matching: find.byType(Row)).first,
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsWidgets,
      reason: '"$key" should have a trash button beside it',
    );
  }

  group('the provider', () {
    test('a deleted key stays deleted, so the schema stops offering it',
        () async {
      final p = room({
        'SWITCHERDEVICE_1': {
          'name': 'AV Bridge 2x1',
          'com_type': 'Serial',
          'device_id': '1',
          'use_device_mute': true,
        },
      });

      p.removeConfigKey('SWITCHERDEVICE_1', 'device_id');

      expect(
        (p.roomConfig['SWITCHERDEVICE_1'] as Map).containsKey('device_id'),
        isFalse,
      );
      expect(p.isConfigKeyOmitted('SWITCHERDEVICE_1', 'device_id'), isTrue);
    });

    test('declining a key that was never in the config still records it',
        () async {
      final p = room({
        'SWITCHERDEVICE_1': {'name': 'AV Bridge 2x1', 'com_type': 'Serial'},
      });

      p.removeConfigKey('SWITCHERDEVICE_1', 'service_port');

      expect(p.isConfigKeyOmitted('SWITCHERDEVICE_1', 'service_port'), isTrue);
    });

    test('typing a value in is asking for the key back', () async {
      final p = room({
        'SWITCHERDEVICE_1': {'name': 'AV Bridge 2x1', 'device_id': '1'},
      });

      p.removeConfigKey('SWITCHERDEVICE_1', 'device_id');
      p.updateDeviceValue('SWITCHERDEVICE_1', 'device_id', '4');

      expect(p.isConfigKeyOmitted('SWITCHERDEVICE_1', 'device_id'), isFalse);
      expect((p.roomConfig['SWITCHERDEVICE_1'] as Map)['device_id'], '4');
    });

    test('Check Defaults adding it back is too', () async {
      final p = room({
        'SWITCHERDEVICE_1': {'name': 'AV Bridge 2x1', 'device_id': '1'},
      });

      p.removeConfigKey('SWITCHERDEVICE_1', 'device_id');
      p.addConfigKey('SWITCHERDEVICE_1', 'device_id', '1');

      expect(p.isConfigKeyOmitted('SWITCHERDEVICE_1', 'device_id'), isFalse);
    });

    test('the note belongs to the room, and does not follow the next one',
        () async {
      final p = room({
        'SWITCHERDEVICE_1': {'name': 'AV Bridge 2x1', 'device_id': '1'},
      });
      p.removeConfigKey('SWITCHERDEVICE_1', 'device_id');

      await p.createNewConfig(); // no template path — fails, but clears first

      expect(p.isConfigKeyOmitted('SWITCHERDEVICE_1', 'device_id'), isFalse);
    });
  });

  group('the devices tab', () {
    testWidgets('every key the AV Bridge 2x1 carries has a trash button', (
      tester,
    ) async {
      // The conversion case from the report: a block switched to the AV Bridge
      // 2x1 (a Network device — see its DEVICE_INFO) that did not come away
      // with these three, so the schema offers them as placeholders.
      final p = room({
        'SWITCHERDEVICE_1': {
          'name': 'AV Bridge 2x1',
          'model': 'AV Bridge 2x1',
          'module': 'modules.device.vadd_switcher_AV_Bridge_2x1',
          'com_type': 'Network',
          'ip_address': '10.0.0.9',
        },
      });
      await pump(tester, p, 'SWITCHERDEVICE_1');

      for (final key in ['device_id', 'service_port', 'use_device_mute']) {
        await expectDeletable(tester, key);
      }
    });

    testWidgets('deleting a placeholder key takes the field off the page', (
      tester,
    ) async {
      final p = room({
        'SWITCHERDEVICE_1': {
          'name': 'AV Bridge 2x1',
          'com_type': 'Serial',
          'device_id': '1',
        },
      });
      await pump(tester, p, 'SWITCHERDEVICE_1');
      expect(find.textContaining('device_id'), findsWidgets);

      p.removeConfigKey('SWITCHERDEVICE_1', 'device_id');
      await settle(tester);

      expect(find.textContaining('device_id'), findsNothing);
    });

    testWidgets("a projector's keep-alive trigger and individual input can go",
        (tester) async {
      final p = room({
        'PROJECTORDEVICE_1': {
          'name': 'Projector 1',
          'com_type': 'Network',
          'module': '',
          'ip_address': '10.0.0.5',
        },
      });
      await pump(tester, p, 'PROJECTORDEVICE_1');

      for (final key in ['keep_alive_trigger', 'input_individual']) {
        await expectDeletable(tester, key);
      }
    });

    testWidgets('the input slot itself is deletable and stays gone', (
      tester,
    ) async {
      final p = room({
        'PROJECTORDEVICE_1': {
          'name': 'Projector 1',
          'com_type': 'Network',
          'module': '',
          'input': 'HDMI 1',
        },
      });
      await pump(tester, p, 'PROJECTORDEVICE_1');
      expect(find.textContaining('Input (type or select)'), findsOneWidget);

      p.removeConfigKey('PROJECTORDEVICE_1', 'input');
      await settle(tester);

      expect(find.textContaining('Input (type or select)'), findsNothing);
    });
  });
}
