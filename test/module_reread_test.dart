import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// ============================================================================
///  THE DRIVER CHANGED WHILE THE APP WAS OPEN
/// ============================================================================
///  Every python driver is parsed once and the answer kept — its commands, its
///  inputs, the states of each command — because the device tabs ask for all
///  of them on every rebuild. Which means the person who maintains the drivers
///  is looking at an app that still believes the file it read at startup: an
///  Update method added ten minutes ago is not in the keep-alive dropdown, and
///  restarting was the only way to pick it up.
///
///  Held here: that re-reading actually re-reads. A reload that warmed the
///  caches again on top of the stale entries would look exactly like a working
///  button and change nothing, which is the failure that is impossible to
///  notice from the outside.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_modules_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Writes a driver with the given Update methods on it, in the shape
  /// [AppStateProvider.getCommandsForModule] parses.
  void writeDriver(String stem, List<String> commands) {
    final devices = Directory(path.join(dir.path, 'devices'));
    devices.createSync(recursive: true);
    File(path.join(devices.path, '$stem.py')).writeAsStringSync([
      'class DeviceClass:',
      for (final c in commands) '    def Update$c(self, value, qualifier):',
      if (commands.isEmpty) '    pass',
      for (final _ in commands) '        pass',
    ].join('\n'));
  }

  AppStateProvider providerAt() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.modulesPath = path.join(dir.path, 'devices');
    return p;
  }

  test('a driver edited on disk is read again', () async {
    writeDriver('krmr_VIA_GO', ['Power', 'Input']);
    final p = providerAt();
    await p.preloadAllModules();

    const module = 'modules.device.krmr_VIA_GO';
    expect(await p.getCommandsForModule(module), ['Input', 'Power']);

    // The same file, with a command added the way somebody adds one: in the
    // next window, while this app is still open.
    writeDriver('krmr_VIA_GO', ['Power', 'Input', 'AutoImage']);
    expect(
      await p.getCommandsForModule(module),
      ['Input', 'Power'],
      reason: 'still the copy it parsed at startup, which is the problem',
    );

    final found = await p.reloadModules();
    expect(found, greaterThan(0), reason: 'it says how many it read');
    expect(
      await p.getCommandsForModule(module),
      ['AutoImage', 'Input', 'Power'],
      reason: 'the new command is there',
    );
  });

  test('a driver deleted on disk drops out of the list', () async {
    writeDriver('old_projector', ['Power']);
    writeDriver('new_projector', ['Power']);
    final p = providerAt();
    await p.preloadAllModules();
    expect(p.availableModules, containsAll(['old_projector', 'new_projector']));

    File(path.join(dir.path, 'devices', 'old_projector.py')).deleteSync();
    await p.reloadModules();

    expect(p.availableModules, contains('new_projector'));
    expect(
      p.availableModules,
      isNot(contains('old_projector')),
      reason: 'a module that is gone is gone, not remembered',
    );
  });
}
