import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_logger.dart';

/// ============================================================================
///  SECRET STORE
/// ============================================================================
///  Where credentials live, as opposed to settings. Everything else the app
///  remembers goes in app_config.json as readable text, on purpose — paths and
///  ports are meant to be editable by hand. A password is not, so it is kept
///  out of that file entirely and handed to the OS keystore instead.
///
///  On Windows that is DPAPI: the value is encrypted against the logged-in
///  Windows account, so another account on the same machine (and anyone
///  reading the file off a backup or a synced profile) gets ciphertext.
///
///  Every operation is failure-tolerant. A keystore that won't open is a reason
///  to fall back to typing the password per transfer, never a reason to fail a
///  config load — so errors are logged and reported as "no value".
/// ============================================================================
abstract class SecretStore {
  /// The stored secret for [key], or null when there is none (or it can't be
  /// read).
  Future<String?> read(String key);

  /// Stores [value] under [key]; an empty value deletes the entry instead, so
  /// clearing a field never leaves the old secret behind. Returns false when
  /// the keystore rejected the write.
  Future<bool> write(String key, String value);

  /// Removes [key]. Succeeds silently when it was never there.
  Future<void> delete(String key);
}

/// The real thing: [FlutterSecureStorage], backed by DPAPI on Windows.
class OsSecretStore implements SecretStore {
  final FlutterSecureStorage _storage;

  OsSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e, stack) {
      AppLogger.logError('Could not read "$key" from the OS keystore', e, stack);
      return null;
    }
  }

  @override
  Future<bool> write(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
      return true;
    } catch (e, stack) {
      AppLogger.logError('Could not save "$key" to the OS keystore', e, stack);
      return false;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e, stack) {
      AppLogger.logError('Could not clear "$key" from the OS keystore', e, stack);
    }
  }
}

/// In-memory stand-in for tests and for any run with no platform plugin behind
/// it (a plain `flutter test` has no keystore). Holds nothing on disk.
@visibleForTesting
class InMemorySecretStore implements SecretStore {
  final Map<String, String> values;

  InMemorySecretStore([Map<String, String>? initial])
      : values = {...?initial};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String value) async {
    if (value.isEmpty) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Keys used in the store. Namespaced so they're recognizable in the keystore.
class SecretKeys {
  static const String processorPassword = 'extron_configurator.processor_password';
}
