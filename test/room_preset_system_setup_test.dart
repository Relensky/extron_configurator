import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/room_presets.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A room type has to bring the NUMBERS as well as the boxes.
///
/// Drawing the gear and leaving SYSTEM_SETUP pointing at the template's
/// demonstration room means somebody reads the input numbers off the diagram
/// and types them in — the second pass the presets exist to remove. These
/// cover what a preset is allowed to decide (the switcher I/O map, the source
/// layout), what it must never carry (the room's own identity), and the order
/// the pieces have to happen in for the counts and the source inputs to agree.
void main() {
  Future<AppStateProvider> emptyRoom() async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
      ..avDeviceLibrary =
          await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    p.roomConfig
      ..clear()
      ..addAll(
        Map<String, dynamic>.from(
          jsonDecode(File('config.json').readAsStringSync()) as Map,
        ),
      );
    // The state New Config leaves behind: no hardware, no device blocks.
    p.roomConfig.removeWhere((k, v) => v is Map && v.containsKey('com_type'));
    final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
    for (final spec in p.uiSchema.deviceTypes) {
      setup[spec.countKey] = '0';
    }
    return p;
  }

  RoomPreset byName(String name) =>
      builtInRoomPresets().firstWhere((p) => p.name == name);

  group('the shipped room types are named for the type', () {
    test('there are four, and they are these four', () {
      expect(
        builtInRoomPresets().map((p) => p.name).toList(),
        ['Basic classroom', 'Hyflex', 'Huddle', 'Active learning'],
      );
    });

    test('no room is named in a name or a description', () {
      // Checked as building codes rather than by shape: a room number and a
      // model number look identical written down — 'BSS 239' and 'IN1608 SA'
      // are the same pattern — and the models are the whole point of these
      // presets. So the test knows which codes are buildings.
      final building = RegExp(r'\b(AJH|BSS|PAC|OCNL|TEHA|BUTE)\b');
      for (final preset in builtInRoomPresets()) {
        expect(building.hasMatch(preset.name), isFalse,
            reason: '${preset.name} is named after a room');
        expect(building.hasMatch(preset.description), isFalse,
            reason: '${preset.name} describes itself with a room');
      }
    });

    test('a type that shipped under a longer name is renamed, not doubled', () {
      final root = Directory.systemTemp.createTempSync('preset_rename_');
      try {
        // A folder as an older version left it: the old file name, the old
        // name inside, and a shop's own edit to prove nothing is thrown away.
        final dir = roomPresetDirectory(root.path);
        File('${dir.path}/Hyflex classroom$kRoomPresetExtension')
            .writeAsStringSync(jsonEncode({
          'name': 'Hyflex classroom',
          'description': 'Ours, not theirs',
          'builtIn': true,
        }));

        ensureBuiltInRoomPresets(root.path);
        final presets = loadRoomPresets(root.path);

        expect(presets.where((p) => p.name.startsWith('Hyflex')).length, 1);
        final hyflex = presets.firstWhere((p) => p.name == 'Hyflex');
        expect(hyflex.description, 'Ours, not theirs');
        expect(
          File('${dir.path}/Hyflex classroom$kRoomPresetExtension').existsSync(),
          isFalse,
        );
      } finally {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('the switcher numbers a room type decides', () {
    test('survive the trip to disk and back', () {
      final root = Directory.systemTemp.createTempSync('preset_io_');
      try {
        saveRoomPreset(
          root.path,
          const RoomPreset(
            name: 'Seminar room',
            systemSetup: {'input_pc': '3', 'output_proj_1': '5B'},
          ),
        );
        final read = loadRoomPresets(root.path).single;
        expect(read.systemSetup['input_pc'], '3');
        expect(read.systemSetup['output_proj_1'], '5B');
      } finally {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('come off the preset\'s own cabling', () async {
      // Hyflex draws the PC into HDMI IN 1 and the projector off DTP OUT 3B.
      final hyflex = byName('Hyflex');
      expect(hyflex.systemSetup['input_pc'], '1');
      expect(hyflex.systemSetup['input_wireless'], '3');
      expect(hyflex.systemSetup['output_proj_1'], '3B');
      expect(hyflex.systemSetup['output_cc'], '1');
    });

    test('a room with no matrix says so rather than guessing', () {
      // The huddle space has no switcher at all: the plate goes to the bar and
      // the bar to the display. 'None' is the documented way to tell the
      // processor there is no switcher output to mute.
      final huddle = byName('Huddle');
      expect(huddle.systemSetup['input_pc'], '');
      expect(huddle.systemSetup['output_proj_1'], 'None');
    });
  });

  group('applying a room type to a new room', () {
    test('overwrites the template\'s demonstration numbers', () async {
      final p = await emptyRoom();
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;

      // What the template ships, and what the room would keep if a preset
      // only filled blanks.
      expect(setup['input_pc'], '1');
      expect(setup['output_proj_1'], '5B');

      final preset = byName('Basic classroom');
      p.applyRoomPreset(preset);
      final result = buildControlSideForPreset(p, preset);

      expect(result.blocks, greaterThan(0));
      expect(result.settings, greaterThan(0));
      expect(setup['input_pc'], '3');
      expect(setup['input_doc_cam'], '4');
      expect(setup['input_hdmi'], '7');
      expect(setup['output_proj_1'], '1');
      expect(setup['output_audio'], '1');
    });

    test('fills the source layout and the I/O map together', () async {
      final p = await emptyRoom();
      final preset = byName('Hyflex');
      p.applyRoomPreset(preset);
      buildControlSideForPreset(p, preset);

      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(setup['gui_inputs'], '4');
      expect(setup['gui_tab_type'], 'DOC_WL');
      expect(setup['input_pc'], '1');
      expect(setup['input_wireless'], '3');
      expect(setup['input_inst_cam'], '5');
      expect(setup['input_aud_cam'], '6');
      expect(setup['output_proj_1'], '3B');
      expect(setup['output_monitor_1'], '2');
    });

    test('the device blocks and the counts come with it', () async {
      final p = await emptyRoom();
      final preset = byName('Hyflex');
      p.applyRoomPreset(preset);
      final result = buildControlSideForPreset(p, preset);

      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      expect(p.roomConfig['PROJECTORDEVICE_1'], isA<Map>());
      expect(p.roomConfig['SWITCHERDEVICE_1'], isA<Map>());
      expect(setup['dev_projectors'], '1');
      expect(setup['dev_switchers'], '1');
      // Every block the prefill created is one the diagram is keyed to.
      expect(result.blocks, greaterThanOrEqualTo(9));
    });

    test('a blank clears a value but never resurrects a pruned key', () async {
      final p = await emptyRoom();
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      setup['output_audio_ald'] = '4';
      setup.remove('output_cc2'); // as a prune would have left it

      p.applyPresetSystemSetup(
        const RoomPreset(
          name: 'Blanks',
          systemSetup: {'output_audio_ald': '', 'output_cc2': ''},
        ),
      );

      expect(setup['output_audio_ald'], '');
      expect(setup.containsKey('output_cc2'), isFalse);
    });
  });

  group('saving a room as a type', () {
    test('carries the I/O map and leaves the room\'s identity behind',
        () async {
      final p = await emptyRoom();
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      setup['input_pc'] = '9';
      setup['gui_full_room_name'] = 'Bessey 103';
      setup['gve_room'] = '103';

      final saved = p.currentRoomAsPreset(name: 'Ours');

      expect(saved.systemSetup['input_pc'], '9');
      expect(saved.systemSetup.containsKey('gui_full_room_name'), isFalse);
      expect(saved.systemSetup.containsKey('gve_room'), isFalse);
      expect(saved.systemSetup.containsKey('ip_address'), isFalse);
    });
  });
}
