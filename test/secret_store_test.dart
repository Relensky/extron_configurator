import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/secret_store.dart';

/// The processor password is the one thing the app remembers that must NOT sit
/// in app_config.json: that file is meant to be hand-editable and gets copied
/// around, so the credential goes to the OS keystore instead (DPAPI on
/// Windows). These cover the provider's side of that contract.
void main() {
  const key = SecretKeys.processorPassword;

  AppStateProvider providerWith(SecretStore store) =>
      AppStateProvider(autoLoadSettings: false, secretStore: store);

  group('saving', () {
    test('writes to the keystore, not to the settings map', () async {
      final store = InMemorySecretStore();
      final p = providerWith(store);

      final ok = await p.setDefaultProcessorPassword('ATEC2007');

      expect(ok, isTrue);
      expect(store.values[key], 'ATEC2007');
      // In memory for this session, so the SFTP dialogs can read it
      expect(p.defaultProcessorPassword, 'ATEC2007');
    });

    test('clearing the field deletes the entry rather than storing empty',
        () async {
      final store = InMemorySecretStore({key: 'ATEC2007'});
      final p = providerWith(store);

      await p.setDefaultProcessorPassword('');

      expect(store.values.containsKey(key), isFalse);
    });

    test('keystroke writes land in order, so nothing truncates', () async {
      // The field saves on every keystroke. With writes running concurrently,
      // a slow early one ("S") can finish after a fast later one and leave a
      // one-character password stored.
      final store = _SlowingStore();
      final p = providerWith(store);

      const typed = 'ATEC2007';
      final writes = [
        for (int i = 1; i <= typed.length; i++)
          p.setDefaultProcessorPassword(typed.substring(0, i)),
      ];
      await Future.wait(writes);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(store.values[key], typed);
      expect(store.order.last, typed,
          reason: 'the last keystroke must be the last thing written');
      expect(store.order, hasLength(typed.length));
    });

    test('reports a keystore refusal instead of pretending it saved', () async {
      final p = providerWith(_RefusingStore());
      expect(await p.setDefaultProcessorPassword('ATEC2007'), isFalse);
      // Still usable for this session — the dialogs get it, the disk doesn't
      expect(p.defaultProcessorPassword, 'ATEC2007');
    });
  });

  group('the toggle', () {
    test('turning it off deletes the stored credential', () async {
      final store = InMemorySecretStore({key: 'ATEC2007'});
      final p = providerWith(store)
        ..useDefaultProcessorPassword = true
        ..defaultProcessorPassword = 'ATEC2007';

      await p.setUseDefaultProcessorPassword(false);

      expect(store.values.containsKey(key), isFalse,
          reason: 'switching it off must get the credential off the machine');
      expect(p.defaultProcessorPassword, '');
      expect(p.autofillProcessorPassword, '');
    });
  });

  group('the settings file', () {
    test('never carries the password', () async {
      final p = providerWith(InMemorySecretStore())
        ..useDefaultProcessorPassword = true;
      await p.setDefaultProcessorPassword('ATEC2007');

      final json = p.settingsAsJson();

      expect(json.containsKey('defaultProcessorPassword'), isFalse,
          reason: 'the credential must not reach app_config.json');
      // The toggle itself is an ordinary setting and does belong there
      expect(json['useDefaultProcessorPassword'], isTrue);
    });
  });
}

/// A store whose writes complete out of order: the EARLIER the value arrives,
/// the longer it takes. Without serialization the first keystroke wins the race
/// and the stored password is a one-character prefix.
class _SlowingStore implements SecretStore {
  final Map<String, String> values = {};

  /// Values in the order they actually landed.
  final List<String> order = [];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String value) async {
    await Future.delayed(Duration(milliseconds: 40 - value.length * 4));
    values[key] = value;
    order.add(value);
    return true;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A keystore that fails every write — a locked or unavailable credential
/// store.
class _RefusingStore implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<bool> write(String key, String value) async => false;
  @override
  Future<void> delete(String key) async {}
}
