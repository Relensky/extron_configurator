import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/room_presets.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  THE ACTIVE LEARNING ROOM, OFF THE MATRIX
/// ============================================================================
///  It used to be a NAV room: seven student panels on an AV LAN, each an
///  encoder and a decoder on a NAVigator, with an IN1804 and an SW4 behind the
///  main matrix and a MediaPort making the USB. It is now one DTP CrossPoint
///  108 and a twisted pair to every screen.
///
///  The rule that decides how a screen is fed is the thing worth pinning: a
///  DTP output is twisted pair already and runs straight to a receiver (or
///  straight into a projector's own HDBaseT socket); an HDMI output is not, so
///  it needs a transmitter in the rack first. Get that backwards and the room
///  quotes an HDMI lead running two hundred feet to a student table.
/// ============================================================================
void main() {
  late UiSchema schema;
  final preset =
      builtInRoomPresets().firstWhere((p) => p.name == 'Active learning');

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AvNode node(String id) => preset.nodes.firstWhere((n) => n.id == id);
  Iterable<AvNode> withModel(String model) =>
      preset.nodes.where((n) => n.model == model);

  /// Every cable out of [id], as "port -> node.port".
  List<String> from(String id) => [
        for (final c in preset.cables)
          if (c.fromNodeId == id) '${c.fromPortId} -> ${c.toNodeId}.${c.toPortId}',
      ];

  group('what is in the room', () {
    test('one matrix, and it is the 108', () {
      final switchers =
          preset.nodes.where((n) => n.id.startsWith('SWITCHERDEVICE_'));
      expect(switchers, hasLength(1));
      expect(switchers.single.model, 'DTP CrossPoint 108 4K IPCP MA 70');
    });

    test('no NAVigator and no MediaPort', () {
      for (final gone in const ['NAVDEVICE_', 'MEDIAPORTDEVICE_']) {
        expect(preset.nodes.where((n) => n.id.startsWith(gone)), isEmpty,
            reason: '$gone should be gone from this room');
      }
    });

    test('the cameras are a TR211 and a Cam570', () {
      expect(node('CAMERADEVICE_1').model, 'TR211');
      expect(node('CAMERADEVICE_2').model, 'Cam570');
    });

    test('the recorder is an AV Bridge 2x1', () {
      expect(node('RECORDERDEVICE_1').model, 'AV Bridge 2x1');
    });
  });

  group('how each screen is fed', () {
    test('a projector takes the DTP output straight into its HDBaseT', () {
      // Twisted pair at both ends: no box in between, and none quoted.
      expect(from('SWITCHERDEVICE_1'),
          contains('dtp_out_1 -> PROJECTORDEVICE_1.in_hdbt_1'));
      expect(from('SWITCHERDEVICE_1'),
          contains('dtp_out_2 -> PROJECTORDEVICE_2.in_hdbt_1'));
    });

    test('a panel on a DTP output needs a receiver and nothing else', () {
      // Stations 1 and 2 are on the two spare DTP outputs.
      for (final i in const [1, 2]) {
        final rx = 'AVNODE_${30 + i}';
        expect(node(rx).model, 'DTP HDMI 4K 230 Rx');
        expect(from('SWITCHERDEVICE_1'),
            contains('dtp_out_${i + 2} -> $rx.port_1786393825139452'));
        expect(from(rx), contains('hdmi -> STATIONDEVICE_$i.in_hdmi_1'));
        // No transmitter was invented for a run that is already twisted pair.
        expect(preset.nodes.where((n) => n.id == 'AVNODE_${20 + i}'), isEmpty);
      }
    });

    test('a panel on an HDMI output gets a transmitter as well', () {
      for (final i in const [3, 4, 5, 6, 7]) {
        final tx = 'AVNODE_${20 + i}';
        final rx = 'AVNODE_${30 + i}';
        expect(node(tx).model, 'DTP HDMI 4K 230 Tx');
        expect(node(rx).model, 'DTP HDMI 4K 230 Rx');
        // Matrix HDMI out, into the transmitter; pair across the room; HDMI
        // out of the receiver into the panel.
        expect(from('SWITCHERDEVICE_1'),
            contains('hdmi_${i - 1} -> $tx.hdmi'));
        expect(from(tx),
            contains('port_1786393062452313 -> $rx.port_1786393825139452'));
        expect(from(rx), contains('hdmi -> STATIONDEVICE_$i.in_hdmi_1'));
      }
    });

    test('so the room buys five transmitters and seven receivers', () {
      // Two panels on DTP need no transmitter; the other five do. Every panel
      // needs a receiver. They are real boxes at real money.
      expect(withModel('DTP HDMI 4K 230 Tx'), hasLength(5));
      expect(withModel('DTP HDMI 4K 230 Rx'), hasLength(7));
    });

    test('every one of the seven panels is actually fed', () {
      for (int i = 1; i <= 7; i++) {
        expect(
          preset.cables.any((c) =>
              c.toNodeId == 'STATIONDEVICE_$i' && c.toPortId == 'in_hdmi_1'),
          isTrue,
          reason: 'station $i has no picture',
        );
      }
    });
  });

  test('the expansion bus runs matrix to DSP and nowhere else', () {
    final exp = preset.cables.singleWhere((c) => c.label == 'AUD-04');
    expect(exp.fromNodeId, 'SWITCHERDEVICE_1');
    expect(exp.toNodeId, 'DSPDEVICE_1');
    // Both ends are the DMP expansion socket — the one link that only ever
    // goes between those two.
    expect(
      expansionBusFor(node('SWITCHERDEVICE_1').portById(exp.fromPortId)!.label),
      'dmp',
    );
    expect(
      expansionBusFor(node('DSPDEVICE_1').portById(exp.toPortId)!.label),
      'dmp',
    );
  });

  test('every box with a control block has a driver for it', () async {
    // Against the real driver library, since "module controllable" is a claim
    // about what is actually in it. Skipped when the template is not checked
    // out beside this repo, the same way controlscript_modules_test is.
    const modules =
        'C:/GitHub/ControlScript-Template/base/assets/src/modules/device';
    if (!Directory(modules).existsSync()) {
      markTestSkipped('ControlScript-Template not checked out');
      return;
    }

    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary =
          await AvDeviceLibrary.load(explicitPath: 'av_devices.json')
      ..modulesPath = modules;
    await p.preloadAllModules();
    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};
    p.loadAvFlowForCurrentConfig();
    p.applyRoomPreset(preset);

    // The point of dropping the NAV and the MediaPort: what is left is a room
    // the processor can actually drive. A block with no module is a device
    // somebody has to go and find a driver for.
    //
    // The seven Newline panels are the exception, and it is not one this
    // preset can fix: the driver library has nothing for a TT-7523Q, by any
    // name. Named here rather than waved through, so the day somebody writes
    // that driver this test says so by failing.
    final plan = planControlSide(p);
    final gaps = plan.withoutModule
        .map((e) => '${e.sectionKey} (${e.model})')
        .toList();
    expect(
      gaps.where((g) => !g.startsWith('STATIONDEVICE_')),
      isEmpty,
      reason: 'these would be created with no driver',
    );
    expect(gaps.where((g) => g.startsWith('STATIONDEVICE_')), hasLength(7),
        reason: 'if this drops to 0 the TT-7523Q has a driver now — take the '
            'exception out');
  });
}
