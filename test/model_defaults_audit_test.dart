import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/config_key_mapper.dart';
import 'package:extron_configurator/model_defaults_audit.dart';

/// A conversion fills a device block from the FAMILY defaults in key_map.json
/// and from a template block matched on the model string. Neither knows
/// anything about the driver that will actually run the device, and the driver
/// is the authority: it is written by whoever wrote the code that talks to the
/// box.
///
/// Where the two disagree, the room is wrong in a way that costs a
/// commissioning visit — so the conversion has to ask.
void main() {
  late AppStateProvider provider;

  /// The real driver library and the real key map: these bugs were reported
  /// against the shipped files, so the shipped files are what is under test.
  setUp(() async {
    provider = AppStateProvider(autoLoadSettings: false)
      ..modulesPath = path.join(Directory.current.path, 'device');
    await provider.preloadAllModules();
  });

  /// Runs [config] through the shipped conversion, the way opening a legacy
  /// file does, and loads the result into the provider.
  Future<void> convert(Map<String, dynamic> config) async {
    final map = await ConfigKeyMap.load(explicitPath: 'key_map.json');
    provider.roomConfig = map.apply(config).config;
  }

  Map<String, dynamic> legacyRoom() => {
    'SYSTEM_SETUP': {
      'dev_wireless': '1',
      'dev_power_controllers': '1',
      'gui_routing_mode': 'Normal',
    },
    // Kramer's own driver says TCP 9982; the wireless family default is SSH,
    // because the ShareLink is.
    'WIRELESSDEVICE_1': {
      'com_type': 'Network',
      'model': 'VIA GO',
      'ip_address': '10.0.0.9',
    },
    // One of the three models apc_other_AP79xxB_Series.py serves. The key map
    // carries a template block for the AP7900B only, so this one converts
    // with no module and no keep-alive trigger.
    'POWERDEVICE_1': {
      'com_type': 'Network',
      'model': 'AP7921B',
      'ip_address': '10.0.0.8',
    },
  };

  ModelDefaultMismatch? forSection(
    List<ModelDefaultMismatch> all,
    String section,
  ) {
    for (final m in all) {
      if (m.sectionKey == section) return m;
    }
    return null;
  }

  test('the driver library is on disk for these to mean anything', () {
    expect(provider.modelRegistry['VIA GO']?.module, 'krmr_VIA_GO');
    expect(
      provider.modelRegistry['AP7921B']?.module,
      'apc_other_AP79xxB_Series',
    );
  });

  group('after a conversion', () {
    test('the VIA GO is reported as SSH where its driver says TCP', () async {
      await convert(legacyRoom());
      // What the conversion left behind, and the reason this exists.
      expect(
        (provider.roomConfig['WIRELESSDEVICE_1'] as Map)['protocol'],
        'SSH',
      );

      final via = forSection(
        auditModelDefaults(provider),
        'WIRELESSDEVICE_1',
      )!;
      final byKey = {for (final d in via.diffs) d.key: d};

      expect(byKey['protocol']?.fromModule, 'TCP');
      expect(byKey['net_port']?.fromModule, 9982);
      expect(byKey['module']?.fromModule, 'modules.device.krmr_VIA_GO');
      expect(byKey['keep_alive_command']?.fromModule, 'RoomCode');
      // Connection facts are ticked when the review opens; the driver's own
      // naming is not, because the room has already been named.
      expect(via.defaultSelection, contains('protocol'));
      expect(via.defaultSelection, contains('net_port'));
      expect(via.defaultSelection, isNot(contains('name')));
      expect(via.defaultSelection, isNot(contains('btn_name')));
    });

    test('the APC gets its Schneider keep-alive trigger offered', () async {
      await convert(legacyRoom());
      final power = provider.roomConfig['POWERDEVICE_1'] as Map;
      // The conversion could not fill these: its template block spells the
      // model AP7900B.
      expect(power.containsKey('keep_alive_trigger'), isFalse);
      expect(power.containsKey('module'), isFalse);

      final apc = forSection(auditModelDefaults(provider), 'POWERDEVICE_1')!;
      final byKey = {for (final d in apc.diffs) d.key: d};

      expect(byKey['keep_alive_trigger']?.fromModule, 'Schneider Electric');
      expect(
        byKey['module']?.fromModule,
        'modules.device.apc_other_AP79xxB_Series',
      );
      expect(apc.defaultSelection, contains('keep_alive_trigger'));
    });

    test('a real address is never proposed away by a driver blank', () async {
      // Every DEVICE_INFO leaves ip_address, password and serial_port empty
      // because they are site-specific. "Apply the defaults" must not be a way
      // to wipe the address of a device that is already commissioned.
      await convert(legacyRoom());
      for (final m in auditModelDefaults(provider)) {
        for (final d in m.diffs) {
          expect(
            d.fromModule?.toString().isEmpty ?? true,
            isFalse,
            reason: '${m.sectionKey}.${d.key} would blank a value',
          );
        }
      }
    });

    test('applying only the ticked keys leaves the rest of the block', () async {
      await convert(legacyRoom());
      final via = forSection(
        auditModelDefaults(provider),
        'WIRELESSDEVICE_1',
      )!;

      provider.applyModelDefaultValues(via.sectionKey, {
        for (final d in via.diffs)
          if (via.defaultSelection.contains(d.key)) d.key: d.fromModule,
      });

      final dev = provider.roomConfig['WIRELESSDEVICE_1'] as Map;
      expect(dev['protocol'], 'TCP');
      expect(dev['net_port'], 9982);
      expect(dev['module'], 'modules.device.krmr_VIA_GO');
      // The room's own facts are untouched: its address, and the name the
      // conversion generated.
      expect(dev['ip_address'], '10.0.0.9');
      expect(dev['name'], 'Wireless - VIA GO');

      // And the room now agrees with the driver, so there is nothing left to
      // ask about.
      final left = forSection(auditModelDefaults(provider), 'WIRELESSDEVICE_1');
      expect(
        left?.diffs.where((d) => d.connection).toList() ?? const [],
        isEmpty,
      );
    });

    test('a room that already matches its drivers is not asked about', () async {
      await convert(legacyRoom());
      for (final m in auditModelDefaults(provider)) {
        provider.applyModelDefaultValues(m.sectionKey, {
          for (final d in m.diffs) d.key: d.fromModule,
        });
      }
      expect(auditModelDefaults(provider), isEmpty);
    });

    test('one device can be asked about on its own', () async {
      await convert(legacyRoom());
      // What the Devices tab's "Check Module Defaults" button asks: the device
      // on screen, not every tab behind it.
      final scoped =
          auditModelDefaults(provider, onlySection: 'WIRELESSDEVICE_1');
      expect(scoped.map((m) => m.sectionKey), ['WIRELESSDEVICE_1']);
      expect(auditModelDefaults(provider).length, greaterThan(scoped.length));

      // And a device that already agrees with its driver reports nothing, so
      // the button can say so rather than opening an empty review.
      provider.applyModelDefaultValues('WIRELESSDEVICE_1', {
        for (final d in scoped.single.diffs) d.key: d.fromModule,
      });
      expect(
        auditModelDefaults(provider, onlySection: 'WIRELESSDEVICE_1'),
        isEmpty,
      );
    });

    test('a device whose model no driver claims is left out of it', () async {
      await convert({
        'SYSTEM_SETUP': {'dev_projectors': '1'},
        'PROJECTORDEVICE_1': {
          'com_type': 'Network',
          'model': 'Some Box Nobody Wrote A Driver For',
        },
      });
      expect(auditModelDefaults(provider), isEmpty);
    });
  });

  group('a driver None', () {
    test('is not written into the block as a null', () async {
      // Every driver in the library spells out "device_id": None, meaning the
      // model does not use the key. Taken literally it put a null device_id on
      // every device anybody picked a model for.
      await convert(legacyRoom());
      for (final m in auditModelDefaults(provider)) {
        expect(
          m.diffs.map((d) => d.key),
          isNot(contains('device_id')),
          reason: '${m.sectionKey} would be given a null device_id',
        );
      }

      provider.applyModuleDefaults('POWERDEVICE_1', 'AP7921B');
      final dev = provider.roomConfig['POWERDEVICE_1'] as Map;
      expect(dev.containsKey('device_id'), isFalse);
      // The keys the driver DOES state are still applied.
      expect(dev['keep_alive_trigger'], 'Schneider Electric');
      expect(dev['protocol'], 'TCP');
      expect(dev['net_port'], 23);
    });
  });
}
