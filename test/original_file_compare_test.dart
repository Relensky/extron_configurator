import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/model_defaults_audit.dart';

/// The driver review answers "what does the python module say this model
/// wants". A converted room raises a second question the app could not answer:
/// "what did the file I opened actually have here" — the port the site had
/// changed on purpose, the baud rate a family default overwrote.
///
/// Same review, one more thing to compare against, and nothing ticked: the
/// converted value is usually the right one, so this is a list to read before
/// it is a list to take.
void main() {
  late AppStateProvider provider;

  setUp(() async {
    provider = AppStateProvider(autoLoadSettings: false);
    await provider.loadUiSchema();
  });

  Map<String, dynamic> converted() => {
    'SYSTEM_SETUP': {'dev_projectors': '1'},
    'PROJECTORDEVICE_1': {
      'name': 'Projector',
      'model': 'PT-FW430U',
      'com_type': 'Serial',
      'serial_port': 'COM2',
      'baud': 9600,
      // A key the conversion added: the original never carried it.
      'keep_alive_interval': 30,
    },
  };

  test('a value the conversion rewrote is reported against the file', () {
    provider.roomConfig = converted();
    provider.originalLoadedConfig = {
      'PROJECTORDEVICE_1': {
        'name': 'Projector',
        'model': 'PT-FW430U',
        'com_type': 'Serial',
        'serial_port': 'COM1',
        'baud': 38400,
      },
    };

    final found = auditOriginalFile(provider);
    expect(found, hasLength(1));
    final byKey = {for (final d in found.first.diffs) d.key: d};
    expect(byKey['serial_port']?.fromModule, 'COM1');
    expect(byKey['baud']?.fromModule, 38400);
    expect(found.first.comType, kOriginalFileComparison);
  });

  test('nothing is ticked — the converted value is the one to keep', () {
    provider.roomConfig = converted();
    provider.originalLoadedConfig = {
      'PROJECTORDEVICE_1': {'serial_port': 'COM1'},
    };
    expect(auditOriginalFile(provider).first.defaultSelection, isEmpty);
  });

  test('a key the conversion ADDED is not offered as a change', () {
    provider.roomConfig = converted();
    provider.originalLoadedConfig = {
      'PROJECTORDEVICE_1': {'serial_port': 'COM2'},
    };
    // Only serial_port is in both blocks, and it agrees, so there is nothing
    // to report — keep_alive_interval must not read as "the file said blank".
    expect(auditOriginalFile(provider), isEmpty);
  });

  test('a legacy section name is lined up with what it became', () {
    provider.roomConfig = converted();
    provider.lastSectionRenames = {'PROJECTOR1DEVICE': 'PROJECTORDEVICE_1'};
    provider.originalLoadedConfig = {
      // The legacy spelling of both the section and the property.
      'PROJECTOR1DEVICE': {'SERIALPORT': 'COM1'},
    };
    final found = auditOriginalFile(provider);
    expect(found, hasLength(1));
    expect(found.first.diffs.single.key, 'serial_port');
    expect(found.first.diffs.single.fromModule, 'COM1');
  });

  test('one device can be asked about on its own', () {
    provider.roomConfig = converted()
      ..['SYSTEM_SETUP']['dev_cameras'] = '1'
      ..['CAMERADEVICE_1'] = {'name': 'Camera', 'ip_address': '10.0.0.5'};
    provider.originalLoadedConfig = {
      'PROJECTORDEVICE_1': {'serial_port': 'COM1'},
      'CAMERADEVICE_1': {'ip_address': '10.0.0.4'},
    };
    expect(auditOriginalFile(provider), hasLength(2));
    expect(
      auditOriginalFile(provider, onlySection: 'CAMERADEVICE_1'),
      hasLength(1),
    );
  });

  group('finding the pre-conversion copy on disk', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('original_file_compare');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
    });

    test('the backup beside the config is read when memory has none',
        () async {
      final configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync(jsonEncode(converted()));
      File(path.join(dir.path, 'BSS103_old_config.json')).writeAsStringSync(
        jsonEncode({
          'PROJECTORDEVICE_1': {'serial_port': 'COM1'},
        }),
      );

      provider.roomConfig = converted();
      provider.currentConfigPath = configPath;
      // A room converted in an earlier session: nothing in memory.
      expect(provider.originalLoadedConfig, isEmpty);
      expect(provider.hasOriginalFileConfig, isTrue);

      expect(await provider.ensureOriginalFileConfig(), isTrue);
      expect(auditOriginalFile(provider).single.diffs.single.key,
          'serial_port');
    });

    test('a room that was never converted has nothing to compare against',
        () async {
      final configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync(jsonEncode(converted()));
      provider.roomConfig = converted();
      provider.currentConfigPath = configPath;

      expect(provider.hasOriginalFileConfig, isFalse);
      expect(await provider.ensureOriginalFileConfig(), isFalse);
      expect(auditOriginalFile(provider), isEmpty);
    });
  });
}
