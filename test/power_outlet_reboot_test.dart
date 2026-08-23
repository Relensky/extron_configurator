import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schematic_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// The per-outlet reboot settings — `power1_outlet_N_supports_reboot` and
/// `power1_outlet_N_reboot_only` — are optional: a room that doesn't carry them
/// behaves exactly as before.
void main() {
  Future<UiSchema> schema() => UiSchema.load(explicitPath: 'ui_schema.json');

  /// A room with a power controller and three outlets, the third of which is
  /// reboot-only.
  Map<String, dynamic> room({bool withReboot = true}) => {
        'SYSTEM_SETUP': {
          'gve_bldg': 'BSS',
          'gve_room': '461',
          'dev_power_controllers': '1',
          'power1_outlet_1': 'PC',
          'power1_outlet_2': 'Switch',
          'power1_outlet_3': 'Doc\\rCam',
          if (withReboot) ...{
            'power1_outlet_1_supports_reboot': true,
            'power1_outlet_1_reboot_only': false,
            'power1_outlet_2_supports_reboot': false,
            'power1_outlet_2_reboot_only': false,
            'power1_outlet_3_supports_reboot': true,
            'power1_outlet_3_reboot_only': true,
          },
        },
        'POWERDEVICE_1': {
          'name': 'Power Controller - APC AP7900B',
          'model': 'AP7900B',
          'com_type': 'Network',
          'ip_address': '10.0.0.5',
        },
      };

  Future<List<List<dynamic>>> outletRows({bool withReboot = true}) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await schema()
      ..roomConfig = room(withReboot: withReboot);
    final sections = reportSections(p, SchematicModel.build(p));
    return sections.firstWhere((s) => s.title == 'Power Outlets').rows;
  }

  group('the schema', () {
    test('describes both keys as booleans, per outlet', () async {
      final s = await schema();
      for (final key in const [
        'power1_outlet_1_supports_reboot',
        'power1_outlet_8_reboot_only',
      ]) {
        final spec = s.specFor(key);
        expect(spec, isNotNull, reason: '$key should resolve to a definition');
        expect(spec!.type, 'bool',
            reason: 'a checkbox, not free text - the values are JSON booleans');
        expect(spec.description, isNotNull);
      }
    });

    test('the specific patterns beat the generic outlet-name one', () async {
      final s = await schema();
      // power1_outlet_* would otherwise swallow these and render them as the
      // 23-character GUI name field.
      expect(s.specFor('power1_outlet_2_supports_reboot')!.type, 'bool');
      expect(s.specFor('power1_outlet_2_reboot_only')!.type, 'bool');
      // ...while the outlet name itself still gets the generic entry
      expect(s.specFor('power1_outlet_2')!.type, isNot('bool'));
      expect(s.specFor('power1_outlet_2')!.helperText, contains('23'));
    });

    test('neither key is required - absence is not flagged', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..uiSchema = await schema()
        ..roomConfig = room(withReboot: false);
      // The migration only injects what system_defaults lists; these are not
      // there, so a room without them stays without them.
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup.keys.where((k) => k.toString().contains('reboot')), isEmpty);
    });
  });

  group('the device report', () {
    test('lists one row per outlet, not one per companion key', () async {
      // Regression: the outlet filter matched on the `power1_outlet_` PREFIX,
      // so every companion key became its own row — and since none of them
      // ends in the outlet number, each reported as a nameless "Outlet 0".
      final rows = await outletRows();

      expect(rows, hasLength(3));
      expect(rows.map((r) => r.first).toList(),
          ['Outlet 1', 'Outlet 2', 'Outlet 3']);
      expect(rows.any((r) => r.first == 'Outlet 0'), isFalse);
    });

    test('reports each outlet\'s reboot capability', () async {
      final rows = await outletRows();
      // [outlet, name, reboot] — the '_action' column is gone with the key
      expect(rows[0][2], 'Reboot supported');
      expect(rows[1][2], 'No reboot');
      expect(rows[2][2], 'Reboot only');
    });

    test('a room without the settings reports a blank, not a claim', () async {
      final rows = await outletRows(withReboot: false);
      expect(rows, hasLength(3));
      for (final row in rows) {
        expect(row[2], '',
            reason: 'absent keys must not read as "No reboot"');
      }
    });
  });

  /// `power<N>_outlet_<M>_action` said the same thing as `_reboot_only` from
  /// the panel's end. The load retires it, and must not lose an outlet that
  /// was only ever declared reboot-only through the old key.
  group('the _action fold', () {
    AppStateProvider provider() => AppStateProvider(autoLoadSettings: false);

    test('a legacy "Reboot" becomes reboot_only, and the key goes', () async {
      final p = provider();
      // The file as opened: reboot-only stated the old way, and nothing else.
      final original = <String, dynamic>{
        'SYSTEM_SETUP': {
          'power1_outlet_3': 'Doc Cam',
          'power1_outlet_3_action': 'Reboot',
        },
      };
      // ...and the config after the companion rules ran, which is where the
      // `_reboot_only: false` comes from — the conversion's default, not the
      // room's decision.
      p.roomConfig = {
        'SYSTEM_SETUP': {
          'power1_outlet_3': 'Doc Cam',
          'power1_outlet_3_action': 'Reboot',
          'power1_outlet_3_supports_reboot': true,
          'power1_outlet_3_reboot_only': false,
        },
      };

      p.foldOutletActionIntoRebootOnly(original);

      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup.containsKey('power1_outlet_3_action'), isFalse);
      expect(setup['power1_outlet_3_reboot_only'], isTrue,
          reason: 'the outlet must still cycle rather than switch off');
      expect(p.systemLogs.any((l) => l.contains('power1_outlet_3_action')),
          isTrue, reason: 'the migration must be reported');
    });

    test('a null placeholder is dropped without comment', () async {
      final p = provider();
      final original = <String, dynamic>{
        'SYSTEM_SETUP': {'power1_outlet_1_action': null},
      };
      p.roomConfig = {
        'SYSTEM_SETUP': {
          'power1_outlet_1_action': null,
          'power1_outlet_1_reboot_only': false,
        },
      };

      p.foldOutletActionIntoRebootOnly(original);

      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup.containsKey('power1_outlet_1_action'), isFalse);
      expect(setup['power1_outlet_1_reboot_only'], isFalse);
      expect(p.systemLogs, isEmpty);
    });

    test('a reboot_only the FILE declared wins, and is flagged', () async {
      final p = provider();
      // The contradiction the processor used to warn about: the file says
      // 'Reboot' on one key and false on the other. False is what the
      // processor acts on, so the conversion must not silently flip it.
      final original = <String, dynamic>{
        'SYSTEM_SETUP': {
          'power1_outlet_8_action': 'Reboot',
          'power1_outlet_8_reboot_only': false,
        },
      };
      p.roomConfig = {
        'SYSTEM_SETUP': {
          'power1_outlet_8_action': 'Reboot',
          'power1_outlet_8_reboot_only': false,
        },
      };

      p.foldOutletActionIntoRebootOnly(original);

      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup.containsKey('power1_outlet_8_action'), isFalse);
      expect(setup['power1_outlet_8_reboot_only'], isFalse,
          reason: 'the key the processor reads keeps its value');
      expect(p.systemLogs.any((l) => l.startsWith('FLAGGED')), isTrue);
    });

    test('every outlet is handled, not just the first', () async {
      final p = provider();
      final original = <String, dynamic>{
        'SYSTEM_SETUP': {
          for (int n = 1; n <= 8; n++)
            'power1_outlet_${n}_action': n.isEven ? 'Reboot' : null,
        },
      };
      p.roomConfig = {
        'SYSTEM_SETUP': {
          for (int n = 1; n <= 8; n++) ...{
            'power1_outlet_${n}_action': n.isEven ? 'Reboot' : null,
            'power1_outlet_${n}_reboot_only': false,
          },
        },
      };

      p.foldOutletActionIntoRebootOnly(original);

      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup.keys.where((k) => k.toString().endsWith('_action')), isEmpty);
      for (int n = 1; n <= 8; n++) {
        expect(setup['power1_outlet_${n}_reboot_only'], n.isEven,
            reason: 'outlet $n');
      }
    });
  });
}
