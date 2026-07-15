import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:extron_configurator/app_state.dart';

/// Unit tests for AppStateProvider.locateModuleManual — the pure PDF-path
/// resolver shared by the in-app viewer and the external-open fallback.
void main() {
  group('AppStateProvider.locateModuleManual', () {
    test('empty module name returns an error, no path', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      final r = provider.locateModuleManual('');
      expect(r.path, isNull);
      expect(r.error, isNotNull);
    });

    test('missing file returns a "No manual found" error', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.documentationPath =
          Directory.systemTemp.createTempSync('docs_empty_').path;
      final r = provider.locateModuleManual('device.avr_TR311');
      expect(r.path, isNull);
      expect(r.error, contains('No manual found'));
    });

    test('resolves <module base>.pdf when it exists', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      final dir = Directory.systemTemp.createTempSync('docs_ok_');
      provider.documentationPath = dir.path;
      // module name uses dot notation; only the last segment is the file base.
      final pdf = File(p.join(dir.path, 'avr_TR311.pdf'))
        ..writeAsBytesSync([1, 2, 3]);

      final r = provider.locateModuleManual('device.avr_TR311');

      expect(r.error, isNull);
      expect(r.path, pdf.path);
    });
  });
}
