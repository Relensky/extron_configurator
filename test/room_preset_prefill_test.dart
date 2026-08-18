import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/room_presets.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A preset is only worth stamping out if the control side comes out of it.
///
/// Applying one draws the room; "build the control side" turns that drawing
/// into config blocks. The two halves are joined by the MODEL — the catalog
/// says what family a box is in and the module library says which driver
/// claims it — so a preset that names its models should produce a room whose
/// projectors are projectors and whose switchers are switchers, with no device
/// landing in the "nothing claimed it" pile that should have had a block.
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
    // Start from a room with no hardware, the way New Config does, so the
    // prefill is numbering from zero rather than from the template's blocks.
    p.roomConfig.removeWhere((k, v) => v is Map && v.containsKey('com_type'));
    final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
    for (final spec in p.uiSchema.deviceTypes) {
      setup[spec.countKey] = '0';
    }
    return p;
  }

  /// Which family each preset puts hardware into, and how many.
  ///
  /// The camera counts include the DOCUMENT CAMERA, which is a source in every
  /// one of these rooms and not a device the processor drives. It lands in the
  /// camera family because [familyForNode] reads the words in a model name and
  /// "Document Camera" contains one — a quirk of the heuristic, not of the
  /// preset, and one the prefill dialog shows before anything is written. It
  /// is asserted here rather than glossed over so that a change to the
  /// heuristic shows up as a change to these numbers.
  const expected = {
    'Basic classroom': {
      'PROJECTORDEVICE_': 1,
      // The TR311 and nothing else: a doc cam is a source, not a device.
      'CAMERADEVICE_': 1,
      'SWITCHERDEVICE_': 1,
    },
    'Hyflex': {
      'PROJECTORDEVICE_': 1,
      'CAMERADEVICE_': 2, // instructor + audience; the doc cam is a source
      'SWITCHERDEVICE_': 1,
      'DSPDEVICE_': 1,
      'RECORDERDEVICE_': 1,
      'USBDEVICE_': 1,
      'POWERDEVICE_': 1,
      'WIRELESSDEVICE_': 1,
      'SCREENDEVICE_': 1,
    },
    'Active learning': {
      'PROJECTORDEVICE_': 2,
      'CAMERADEVICE_': 2, // instructor + audience; the doc cam is a source
      // One matrix now, and no NAVigator or MediaPort behind it: every
      // student panel hangs off a DTP pair from the CrossPoint 108.
      'SWITCHERDEVICE_': 1,
      'DSPDEVICE_': 1,
      'MEDIAPORTDEVICE_': 0,
      'RECORDERDEVICE_': 1,
      'USBDEVICE_': 1,
      'POWERDEVICE_': 1,
      'WIRELESSDEVICE_': 1,
      'SCREENDEVICE_': 2,
      'NAVDEVICE_': 0,
      'STATIONDEVICE_': 7,
    },
    'Huddle': {
      'PROJECTORDEVICE_': 1,
      'WIRELESSDEVICE_': 1,
    },
  };

  for (final preset in builtInRoomPresets()) {
    test('${preset.name} builds the control side it should', () async {
      final p = await emptyRoom();
      p.applyRoomPreset(preset);

      final plan = planControlSide(p);
      applyControlSide(p, plan);

      final counts = <String, int>{};
      for (final key in p.roomConfig.keys) {
        final family = p.uiSchema.deviceTypeForSection(key);
        if (family == null) continue;
        counts[family.prefix] = (counts[family.prefix] ?? 0) + 1;
      }

      expected[preset.name]!.forEach((prefix, want) {
        expect(counts[prefix] ?? 0, want, reason: '$prefix in ${preset.name}');
      });
    });
  }

  /// The passive half of each room — the PC, the laptop plate, the speakers,
  /// the DTP pair, the touch panel — has no control block and never had one.
  /// Prefill is right to leave those alone; what would be wrong is a projector
  /// or a switcher landing there, which is what this pins down.
  test('nothing that needs a control block is left unplaceable', () async {
    const allowed = {
      'Instructor PC',
      'Room PC',
      'Laptop at the lectern',
      'Lectern DTP transmitter',
      'Credenza DTP transmitter',
      'Room-end DTP receiver',
      'Ceiling speakers',
      'Speakers - SM 28',
      'Ceiling mic array',
      'Confidence monitor',
      'AV LAN switch',
      'Control LAN switch',
      // Plugged in and pointed at a page. Nothing talks to it, so it has no
      // block, no module and no line on the control schematic — see
      // [isSourceOnlyDevice].
      'Document camera',
      'Neat Bar',
      'Control processor - IPCP Pro PCS1 xi',
      'Touch panel - TLP Pro 525M',
    };

    /// The extenders, which are numbered per station and so cannot be listed
    /// one by one. A DTP pair is a wire with a box at each end.
    bool isExtender(String label) =>
        label.startsWith('DTP transmitter') ||
        label.startsWith('DTP receiver');

    final offenders = <String>[];
    for (final preset in builtInRoomPresets()) {
      final p = await emptyRoom();
      p.applyRoomPreset(preset);
      for (final entry in planControlSide(p).unplaceable) {
        if (!allowed.contains(entry.nodeLabel) &&
            !isExtender(entry.nodeLabel)) {
          offenders.add('${preset.name}/${entry.nodeLabel}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'no device family claimed these, and one should have');
  });
}
