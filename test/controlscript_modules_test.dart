import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';

/// The real driver library the rooms are built from — the ControlScript
/// template's module folder — read the way the app reads it.
///
/// The per-connection DEVICE_INFO blocks are only worth anything if the app
/// picks them up off the actual files, and those files are hand-edited between
/// releases. Skipped (not failed) when the template is not checked out beside
/// this repo, so the suite still runs on a machine that only has this one.
void main() {
  const modules =
      r'C:\GitHub\ControlScript-Template\base\assets\src\modules\device';
  final available = Directory(modules).existsSync();

  late AppStateProvider provider;

  setUpAll(() async {
    if (!available) return;
    provider = AppStateProvider(autoLoadSettings: false)..modulesPath = modules;
    await provider.preloadAllModules();
  });

  test('the template library is on disk for these to mean anything', () {
    if (!available) {
      markTestSkipped('ControlScript-Template not checked out');
      return;
    }
    expect(provider.modelRegistry, isNotEmpty);
  }, skip: !available);

  test('every driver that declares connection blocks parses into the registry',
      () {
    final withBlocks = provider.moduleComTypeDefaults;
    expect(withBlocks.length, greaterThan(60),
        reason: 'the whole library should carry per-connection blocks now');

    for (final entry in withBlocks.entries) {
      // 22023 is the Extron SSH port; a block naming it and then saying TCP
      // describes a connection that cannot be made.
      for (final block in entry.value.values) {
        if (block['net_port'] == 22023) {
          expect(block['protocol'], 'SSH', reason: entry.key);
        }
      }
      for (final style in entry.value.keys) {
        expect(kComTypeDefaultNames, contains(style),
            reason: '${entry.key} declares an unknown connection style');
      }
      // Serial says how fast, everything else says where.
      final serial = entry.value['serial'];
      if (serial != null) {
        expect(serial['baud'], isA<int>(), reason: '${entry.key} serial baud');
      }
      for (final style in ['network', 'serialoverethernet', 'http']) {
        final block = entry.value[style];
        if (block == null) continue;
        expect(block['net_port'], isA<int>(),
            reason: '${entry.key} $style net_port');
        expect(block['protocol'], isNotNull,
            reason: '${entry.key} $style protocol');
      }
    }
  }, skip: !available);

  test('serial over ethernet is the Extron gateway everywhere', () {
    var counted = 0;
    for (final entry in provider.moduleComTypeDefaults.entries) {
      final soe = entry.value['serialoverethernet'];
      if (soe == null) continue;
      counted++;
      expect(soe['net_port'], 2001, reason: entry.key);
      expect(soe['ip_address'], '192.168.254.254', reason: entry.key);
      // The credential is checked by the gateway the COM port hangs off, not
      // by the device on the far end, so it is the Extron one whoever made
      // the box being controlled.
      expect(soe['password'], 'ATEC2007', reason: entry.key);
    }
    expect(counted, 62);
  }, skip: !available);

  test('the SoE password wins over the device password when switched to', () {
    // A Sony projector: root/ATEC2008 on its own network port, but ATEC2007
    // once it is reached through an Extron gateway.
    provider.roomConfig['PROJECTORDEVICE_1'] = <String, dynamic>{
      'model': 'VPL-PHZ60',
      'module': 'modules.device.sony_vp_VPL_P_Series',
      'com_type': 'Network',
      'password': 'ATEC2008',
      'ip_address': '10.1.2.3',
    };

    provider.updateDeviceValue(
        'PROJECTORDEVICE_1', 'com_type', 'SerialOverEthernet');

    final dev = provider.roomConfig['PROJECTORDEVICE_1'];
    expect(dev['password'], 'ATEC2007');
    expect(dev['ip_address'], '192.168.254.254');
    expect(dev['net_port'], 2001);
  }, skip: !available);

  test('Extron gear carries the house credentials', () {
    for (final entry in provider.moduleDefaults.entries) {
      if (!entry.key.startsWith('extr_')) continue;
      expect(entry.value['user'], 'admin', reason: entry.key);
      expect(entry.value['password'], 'ATEC2007', reason: entry.key);
    }
  }, skip: !available);

  test('everything else takes the other password', () {
    for (final entry in provider.moduleDefaults.entries) {
      if (entry.key.startsWith('extr_')) continue;
      if (!entry.value.containsKey('password')) continue;
      expect(entry.value['password'], 'ATEC2008', reason: entry.key);
    }
  }, skip: !available);

  test('changing com_type on a real driver loads that connection', () {
    // The DMP 64 Plus: SSH 22023 on the network, 38400 baud on a COM port.
    const module = 'modules.device.extr_dsp_DMP_64_Plus_Series';
    provider.roomConfig['DSPDEVICE_1'] = <String, dynamic>{
      'model': 'DMP 64 Plus C',
      'module': module,
      'com_type': 'Network',
      'protocol': 'SSH',
      'net_port': 22023,
      'ip_address': '10.1.2.3',
    };

    provider.updateDeviceValue('DSPDEVICE_1', 'com_type', 'Serial');
    expect(provider.roomConfig['DSPDEVICE_1']['baud'], 38400);
    expect(provider.lastComTypeDefaults, contains('baud = 38400'));

    provider.updateDeviceValue(
        'DSPDEVICE_1', 'com_type', 'SerialOverEthernet');
    final dev = provider.roomConfig['DSPDEVICE_1'];
    expect(dev['net_port'], 2001);
    expect(dev['protocol'], 'TCP');
    expect(dev['ip_address'], '192.168.254.254');

    provider.updateDeviceValue('DSPDEVICE_1', 'com_type', 'Network');
    expect(provider.roomConfig['DSPDEVICE_1']['net_port'], 22023);
    expect(provider.roomConfig['DSPDEVICE_1']['protocol'], 'SSH');
  }, skip: !available);

  test('the matrix switchers still refresh their ties', () {
    // RefreshMatrix re-reads every tie as well as proving the connection, so
    // it stays the keep alive on the five DTP CrossPoints and the NAVigator
    // whatever the preference order would otherwise pick.
    final matrices = provider.moduleDefaults.keys
        .where((k) => k.startsWith('extr_matrix_') || k.contains('NAVigator'))
        .toList();
    expect(matrices.length, 6);
    for (final key in matrices) {
      expect(provider.moduleDefaults[key]!['keep_alive_command'],
          'RefreshMatrix',
          reason: key);
      // ...and no per-connection block quietly overrides it.
      for (final block
          in (provider.moduleComTypeDefaults[key] ?? {}).values) {
        expect(block.containsKey('keep_alive_command'), isFalse, reason: key);
      }
    }
  }, skip: !available);

  test('the HTTP-only drivers describe themselves as HTTP', () {
    for (final key in ['pana_camera_AW_HE_UE_Series',
                       'smsg_display_UNxxTU8000_Series_v1_0_1_0',
                       'poly_vtc_Poly_Studio_X_Series_v1_3_3_0']) {
      expect(provider.moduleDefaults[key]?['com_type'], 'HTTP', reason: key);
      expect(provider.moduleComTypeDefaults[key], contains('http'),
          reason: key);
    }
  }, skip: !available);

  test('the two drivers that had no metadata now have some', () {
    for (final key in ['dyds_other_DL3B_DL3W_LCD100_v1_0_1_0',
                       'extr_switcher_DTP3_T_212_D_v1_0_0_0']) {
      expect(provider.moduleDefaults[key], isNotNull, reason: key);
      expect(provider.moduleComTypeDefaults[key], contains('serial'),
          reason: key);
    }
    // Both are reached by a COM port or the gateway, never directly.
    expect(provider.moduleComTypeDefaults[
        'dyds_other_DL3B_DL3W_LCD100_v1_0_1_0'], isNot(contains('network')));
    expect(provider.modelRegistry['DL3B']?.module,
        'dyds_other_DL3B_DL3W_LCD100_v1_0_1_0');
    expect(provider.modelRegistry['DTP3 T 212 D']?.module,
        'extr_switcher_DTP3_T_212_D_v1_0_0_0');
  }, skip: !available);

  test('a connection that cannot poll the usual command says what it can', () {
    // The Samsung polls Power down a serial line, but its DeviceHTTPClass has
    // no Power command at all, so the http block names the one that connection
    // can actually answer rather than a poll that would never come back.
    final blocks =
        provider.moduleComTypeDefaults['smsg_display_UNxxTU8000_Series_v1_0_1_0'];
    expect(blocks, isNotNull);
    expect(provider.moduleDefaults['smsg_display_UNxxTU8000_Series_v1_0_1_0']
        ?['keep_alive_command'], 'Power');
    expect(blocks!['http']?['keep_alive_command'], 'Input');
    // ...and the connections that CAN poll it carry no override at all.
    expect(blocks['serial']?.containsKey('keep_alive_command'), isFalse);
  }, skip: !available);
}
