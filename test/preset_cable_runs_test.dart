import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/room_presets.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  A ROOM STAMPED FROM A ROOM TYPE IS CABLED, NOT NEARLY CABLED
/// ============================================================================
///  A preset ships a drawing AND the switcher numbers that describe it, and
///  the routing pass runs on every visit to the AV Flow tab. So the two have
///  to agree, and when they disagree the pass must not "fix" the drawing by
///  adding a second lead.
///
///  They disagreed four ways, and every one of them put a cable on the page
///  that cannot exist:
///
///    * the preset draws DTP OUT 1 into a projector's HDBaseT socket and
///      `output_proj_1: 1` reads as HDMI 1, so every projector was fed twice;
///    * a camera whose HDMI OUT already ran to a transmitter was given a
///      second lead out of the same socket into the matrix;
///    * a DTP CrossPoint 82 spells its last two inputs 'DTP IN 1' and
///      'DTP IN 2' where its 84 sibling spells them 7 and 8, so the wall
///      plate's input number resolved onto nothing;
///    * the huddle room has no matrix at all and every I/O key blank, and was
///      reported as a room missing its switcher.
///
///  This walks every built-in room type through the real new-project path and
///  asserts the drawing that comes out is one a contractor could pull.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;
  late Directory presetDir;
  late List<RoomPreset> presets;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    presetDir = Directory.systemTemp.createTempSync('preset_cable_runs_');
    ensureBuiltInRoomPresets(presetDir.path);
    presets = loadRoomPresets(presetDir.path);
  });

  tearDownAll(() {
    try {
      presetDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A new project made from [preset], the way the New Config flow makes one:
  /// the room type is stamped in, then the control side is built from what it
  /// drew (which is what writes the SYSTEM_SETUP numbers).
  AppStateProvider newRoomFrom(RoomPreset preset) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library
      ..modulesPath = path.join(Directory.current.path, 'device');
    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};
    p.loadAvFlowForCurrentConfig();
    p.applyRoomPreset(preset);
    buildControlSideForPreset(p, preset);
    return p;
  }

  /// Every connector with more than one lead on it. A socket takes one cable;
  /// two is a drawing nobody can build from.
  List<String> doubledSockets(AppStateProvider p) {
    final count = <String, int>{};
    for (final c in p.avCables) {
      count['${c.fromNodeId}|${c.fromPortId}'] =
          (count['${c.fromNodeId}|${c.fromPortId}'] ?? 0) + 1;
      count['${c.toNodeId}|${c.toPortId}'] =
          (count['${c.toNodeId}|${c.toPortId}'] ?? 0) + 1;
    }
    return [
      for (final e in count.entries)
        if (e.value > 1)
          () {
            final parts = e.key.split('|');
            final node = p.avNodeById(parts[0]);
            return '${node?.label ?? parts[0]} · '
                '${node?.portById(parts[1])?.label ?? parts[1]} '
                '(${e.value} leads)';
          }(),
    ];
  }

  test('the room types are on disk to be checked', () {
    expect(presets.map((p) => p.name), containsAll(<String>[
      'Active learning',
      'Basic classroom',
      'Huddle',
      'Hyflex',
    ]));
  });

  for (final name in const [
    'Active learning',
    'Basic classroom',
    'Huddle',
    'Hyflex',
  ]) {
    group(name, () {
      test('every switcher number the room type states can be drawn', () {
        final preset = presets.firstWhere((p) => p.name == name);
        final p = newRoomFrom(preset);
        final plan = planRoutingFromConfig(p, respectDismissed: true);

        expect(
          plan.unresolved.map((u) => '${u.configKey}=${u.value}: ${u.reason}'),
          isEmpty,
        );
      });

      test('no socket ends up with two leads on it', () {
        final preset = presets.firstWhere((p) => p.name == name);
        final p = newRoomFrom(preset);

        // The drawing the room type shipped is sound on its own...
        expect(doubledSockets(p), isEmpty, reason: 'as the preset drew it');

        // ...and still sound after the config's own numbers are drawn onto it.
        applyRoutingFromConfig(
          p,
          planRoutingFromConfig(p, respectDismissed: true),
          quiet: true,
        );
        expect(doubledSockets(p), isEmpty, reason: 'after the routing pass');
      });

      test('running the pass again changes nothing', () {
        final preset = presets.firstWhere((p) => p.name == name);
        final p = newRoomFrom(preset);
        applyRoutingFromConfig(
          p,
          planRoutingFromConfig(p, respectDismissed: true),
          quiet: true,
        );
        final nodes = p.avNodes.length;
        final cables = p.avCables.length;

        // Every visit to the tab runs it. A pass that adds one more box each
        // time is how a room grows a fourth projector by being looked at.
        final second = planRoutingFromConfig(p, respectDismissed: true);
        applyRoutingFromConfig(p, second, quiet: true);
        expect(p.avNodes.length, nodes);
        expect(p.avCables.length, cables);
        expect(second.unresolved, isEmpty);
      });

      test('a display number names the socket its own lead leaves from', () {
        // The tightest version of the question. It is not enough that the
        // pass adds nothing — the number in SYSTEM_SETUP has to point at the
        // connector the room type's own cable comes out of, or the System tab
        // and the drawing are two documents describing different rooms. This
        // is what caught `output_proj_1: 1` on a CrossPoint 108, where the
        // projector's lead leaves output 5's DTP connector.
        final preset = presets.firstWhere((p) => p.name == name);
        final p = newRoomFrom(preset);
        final switcher = p.avNodeById('SWITCHERDEVICE_1');
        if (switcher == null) return; // the huddle room has no matrix
        final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
        final size = AvDeviceLibrary.switcherSize(switcher.model);

        for (final entry in const {
          'output_proj_1': 'PROJECTORDEVICE_1',
          'output_proj_2': 'PROJECTORDEVICE_2',
          'output_proj_3': 'PROJECTORDEVICE_3',
          'output_proj_4': 'PROJECTORDEVICE_4',
        }.entries) {
          final value = setup[entry.key]?.toString().trim() ?? '';
          if (value.isEmpty || value.toLowerCase() == 'none') continue;
          final display = p.avNodeById(entry.value);
          if (display == null) continue;

          final port = portForIoValue(
            switcher,
            value,
            wantOutput: true,
            declaredOutputs: size.$2,
            declaredInputs: size.$1,
          );
          expect(port, isNotNull,
              reason: '${entry.key} = $value names no connector on '
                  '${switcher.model}');

          // What the room type drew out of that socket, and where it lands.
          final lead = p.avCables.where((c) =>
              c.fromNodeId == switcher.id && c.fromPortId == port!.id);
          expect(lead, isNotEmpty,
              reason: '${entry.key} = $value resolves to ${port!.label}, '
                  'which the drawing leaves empty');
          final lands = lead.first.toNodeId;
          expect(
            lands == display.id ||
                p.avCables.any((c) =>
                    (c.fromNodeId == lands && c.toNodeId == display.id) ||
                    (c.toNodeId == lands && c.fromNodeId == display.id)),
            isTrue,
            reason: '${entry.key} = $value leaves ${port.label} and does not '
                'reach ${display.label}',
          );
        }
      });

      test('the runs the room type drew are all still there', () {
        final preset = presets.firstWhere((p) => p.name == name);
        final p = newRoomFrom(preset);
        final before = p.avCables.length;
        applyRoutingFromConfig(
          p,
          planRoutingFromConfig(p, respectDismissed: true),
          quiet: true,
        );
        // Nothing the preset drew is removed — the pass only ever adds.
        expect(p.avCables.length, greaterThanOrEqualTo(before));
      });
    });
  }
}
