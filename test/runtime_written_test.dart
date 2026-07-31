import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A room's config.json is written back BY THE PROCESSOR while the room runs:
/// it sets its own power-schedule times and ENVIRONMENT.traceback_allowed on
/// the fly. So a downloaded config legitimately carries items the template
/// never had, and the template audit used to report all three as problems on
/// every single download.
void main() {
  Future<UiSchema> schema() => UiSchema.load(explicitPath: 'ui_schema.json');

  /// The template the audit compares against.
  Future<Map<String, dynamic>> template() async =>
      jsonDecode(await File('config.json').readAsString())
          as Map<String, dynamic>;

  /// BSS239's shape: the three processor-written items plus one genuinely
  /// unknown key, which must still be reported.
  Map<String, dynamic> downloadedRoom() => {
        'ENVIRONMENT': {'traceback_allowed': true},
        'SYSTEM_SETUP': {
          'gve_bldg': 'BSS',
          'gve_room': '239',
          'morning_power_on_time': '06:30:43',
          'nightly_shutdown_time': '23:37:29',
          'something_nobody_recognises': 'x',
        },
      };

  group('isRuntimeWritten', () {
    test('covers the three items the processor maintains', () async {
      final s = await schema();
      expect(s.isRuntimeWritten('ENVIRONMENT'), isTrue);
      expect(s.isRuntimeWritten('ENVIRONMENT', 'traceback_allowed'), isTrue);
      expect(s.isRuntimeWritten('SYSTEM_SETUP', 'morning_power_on_time'), isTrue);
      expect(s.isRuntimeWritten('SYSTEM_SETUP', 'nightly_shutdown_time'), isTrue);
    });

    test('does not cover anything else', () async {
      final s = await schema();
      expect(s.isRuntimeWritten('SYSTEM_SETUP'), isFalse);
      expect(s.isRuntimeWritten('SYSTEM_SETUP', 'gve_room'), isFalse);
      expect(s.isRuntimeWritten('METRICS_CONFIG'), isFalse);
      expect(s.isRuntimeWritten('SWITCHERDEVICE_1', 'group_prog_gain'), isFalse);
    });

    test('the __readme entry is not treated as a pattern', () async {
      final s = await schema();
      expect(s.isRuntimeWritten('anything_at_all'), isFalse);
    });
  });

  group('the template audit', () {
    test('says nothing about the processor-written items', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..uiSchema = await schema()
        ..roomConfig = downloadedRoom();

      p.flagUnknownKeys(await template());

      final flags = p.systemLogs.where((l) => l.startsWith('FLAGGED')).toList();
      for (final quiet in const [
        'ENVIRONMENT',
        'traceback_allowed',
        'morning_power_on_time',
        'nightly_shutdown_time',
      ]) {
        expect(flags.where((l) => l.contains(quiet)), isEmpty,
            reason: '$quiet is written by the processor, not a problem');
      }
    });

    test('still reports a key nobody recognises', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..uiSchema = await schema()
        ..roomConfig = downloadedRoom();

      p.flagUnknownKeys(await template());

      expect(
          p.systemLogs.where(
              (l) => l.contains('something_nobody_recognises')),
          hasLength(1),
          reason: 'the audit must still earn its keep');
    });
  });

  group('the System tab', () {
    test('the schedule times are described, so they render normally', () async {
      final s = await schema();
      // With no schema entry AND no dictionary description these draw with the
      // red "unknown key" outline. Giving them definitions is what stops that.
      for (final key in const [
        'morning_power_on_time',
        'nightly_shutdown_time',
      ]) {
        final spec = s.specFor(key);
        expect(spec, isNotNull, reason: '$key needs a definition');
        expect(spec!.description, isNotNull);
        expect(spec.description, contains('PROCESSOR'),
            reason: 'the (i) text should say who writes it');
      }
    });
  });
}
