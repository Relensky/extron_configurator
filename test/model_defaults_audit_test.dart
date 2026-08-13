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
    // The shipped schema too: its "hideWhen" rules are what keep a net_port
    // out of a review of a serial connection, so a review tested without them
    // is not the review the app runs.
    await provider.loadUiSchema();
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
    // The other way round: Extron's own driver says SSH on 22023, and the
    // file arrives on TCP.
    'DSPDEVICE_1': {
      'com_type': 'Network',
      'model': 'DMP 64 Plus C AT',
      'ip_address': '10.0.0.5',
      'protocol': 'TCP',
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

    test('a model spelled the way the file spells it is still found', () async {
      // The registry is keyed by the string the DRIVER spells — 'VIA GO' —
      // and a legacy file spells the same box however whoever typed it felt
      // at the time. 'Via Go' is what they are actually full of.
      //
      // The module resolution has always matched case-insensitively, so the
      // block came out of a conversion carrying krmr_VIA_GO; the review looked
      // the same string up EXACTLY, missed, and skipped the device. The one
      // box whose driver disagrees with its family default was the one box
      // never reviewed, and the VIA GO stayed on the ShareLink's SSH.
      final room = legacyRoom();
      (room['WIRELESSDEVICE_1'] as Map)['model'] = 'Via Go';
      await convert(room);

      final via = forSection(auditModelDefaults(provider), 'WIRELESSDEVICE_1');
      expect(
        via,
        isNotNull,
        reason: 'a VIA GO spelled "Via Go" must still be reviewed',
      );
      final byKey = {for (final d in via!.diffs) d.key: d};
      expect(byKey['protocol']?.fromModule, 'TCP');
      expect(byKey['net_port']?.fromModule, 9982);
      expect(via.defaultSelection, contains('protocol'));
    });

    test('the module resolution and the review agree on a model', () async {
      // The two used to match differently, which is the whole bug: whatever
      // fills in the module has to be what the review looks up, or a device
      // gets a driver and no defaults from it.
      for (final spelling in const ['VIA GO', 'Via Go', 'via go', ' Via Go ']) {
        expect(
          provider.modelEntryFor(spelling)?.module,
          'krmr_VIA_GO',
          reason: 'model "$spelling"',
        );
      }
      // Spacing is a different string rather than the same one shouted, and
      // guessing across it is how the wrong driver gets picked.
      expect(provider.modelEntryFor('VIAGO'), isNull);
    });

    test('the DMP is offered the SSH its driver states', () async {
      await convert(legacyRoom());
      // What the conversion left behind, and the reason this exists.
      expect((provider.roomConfig['DSPDEVICE_1'] as Map)['protocol'], 'TCP');

      final dsp = forSection(auditModelDefaults(provider), 'DSPDEVICE_1')!;
      final byKey = {for (final d in dsp.diffs) d.key: d};
      expect(byKey['protocol']?.fromModule, 'SSH');
      expect(byKey['net_port']?.fromModule, 22023);
      expect(dsp.defaultSelection, contains('protocol'));

      provider.applyModelDefaultValues(dsp.sectionKey, {
        for (final d in dsp.diffs)
          if (dsp.defaultSelection.contains(d.key)) d.key: d.fromModule,
      });
      final dev = provider.roomConfig['DSPDEVICE_1'] as Map;
      expect(dev['protocol'], 'SSH');
      expect(dev['net_port'], 22023);
      // The site's own address survives it.
      expect(dev['ip_address'], '10.0.0.5');
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

    test('a device is reviewed against the connection it is actually on',
        () async {
      // The complaint this fixes: a device on a COM port was compared against
      // the driver's NETWORK block, so it was offered a net_port and told
      // nothing about its baud rate.
      // Whichever file the registry gives this model — two copies of the DMP
      // driver ship, and which one wins is not what this test is about.
      final owner = provider.modelRegistry['DMP 64 Plus C']!.module;
      provider.roomConfig = <String, dynamic>{
        'SYSTEM_SETUP': <String, dynamic>{'dev_dsps': '1'},
        'DSPDEVICE_1': <String, dynamic>{
          'com_type': 'Serial',
          'model': 'DMP 64 Plus C',
          'module': 'modules.device.$owner',
          'serial_port': 'COM1',
        },
      };

      final onSerial =
          auditModelDefaults(provider, onlySection: 'DSPDEVICE_1');
      expect(onSerial, hasLength(1));
      expect(onSerial.single.comType, 'Serial');
      final serialKeys = onSerial.single.diffs.map((d) => d.key).toSet();
      expect(serialKeys, contains('baud'));
      expect(serialKeys, isNot(contains('net_port')),
          reason: 'a COM port has no network port to propose');

      // ...and the picker can still ask what the same driver says about the
      // network, which is how you see the port before moving the device.
      final onNetwork = auditModelDefaults(provider,
          onlySection: 'DSPDEVICE_1', comType: 'Network');
      expect(onNetwork, hasLength(1));
      expect(onNetwork.single.comType, 'Network');
      final networkKeys = onNetwork.single.diffs.map((d) => d.key).toSet();
      expect(networkKeys, contains('net_port'));
      expect(networkKeys, contains('protocol'));
      // Asking about a connection also proposes the com_type that goes with
      // it — a baud rate on a device still set to Network means nothing.
      expect(
        onNetwork.single.diffs
            .firstWhere((d) => d.key == 'com_type')
            .fromModule,
        'Network',
      );
    });

    test('the review still opens when only another connection has anything '
        'to say', () async {
      // Everything already agrees for the connection this device is on, but
      // the driver has a serial block too — so the one-device review opens
      // with no rows and the picker available, rather than reporting "clean"
      // and leaving no way to look.
      final owner = provider.modelRegistry['DMP 64 Plus C']!.module;
      provider.roomConfig = <String, dynamic>{
        'SYSTEM_SETUP': <String, dynamic>{'dev_dsps': '1'},
        'DSPDEVICE_1': <String, dynamic>{
          'com_type': 'Network',
          'model': 'DMP 64 Plus C',
          'module': 'modules.device.$owner',
        },
      };
      for (final m in auditModelDefaults(provider, onlySection: 'DSPDEVICE_1')) {
        provider.applyModelDefaultValues(m.sectionKey, {
          for (final d in m.diffs) d.key: d.fromModule,
        });
      }

      final scoped = auditModelDefaults(provider, onlySection: 'DSPDEVICE_1');
      expect(scoped, hasLength(1));
      expect(scoped.single.diffs, isEmpty);
      expect(scoped.single.availableComTypes, contains('Serial'));

      // The whole-file review keeps its old manners and stays shut.
      expect(auditModelDefaults(provider), isEmpty);
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
