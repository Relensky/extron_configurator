import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// A config LOADED from disk gets the UI schema's baseline blocks injected by
/// the migration; a config built from the template never ran that pass. So a
/// converted room carried ENVIRONMENT.controlscript_profile (the ControlScript
/// pro/xi processor type) while a brand new file had no ENVIRONMENT block at
/// all — the setting simply wasn't there to set.
void main() {
  late Directory dir;
  late String templatePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('new_config_baseline_test_');
    templatePath = path.join(dir.path, 'config.json');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeTemplate(Map<String, dynamic> doc) =>
      File(templatePath).writeAsStringSync(jsonEncode(doc));

  /// A test provider starts on UiSchema.builtIn(); the real app loads
  /// ui_schema.json at startup, and that file is where the baseline blocks are
  /// described, so load it here too.
  Future<AppStateProvider> provider() async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = templatePath;
    await p.loadUiSchema();
    return p;
  }

  test('a new file gets the ControlScript profile even when the template '
      'has no ENVIRONMENT block', () async {
    writeTemplate({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
    });
    final p = await provider();

    expect(await p.createNewConfig(), isTrue);

    final env = p.roomConfig['ENVIRONMENT'];
    expect(env, isA<Map>(),
        reason: 'the pro/xi setting needs a block to live in');
    expect((env as Map)['controlscript_profile'], 'pro');
  });

  test('a value the template does carry is never overwritten', () async {
    writeTemplate({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS'},
      // An Xi room's template must not be quietly reset to 'pro'.
      'ENVIRONMENT': {'controlscript_profile': 'xi'},
    });
    final p = await provider();

    await p.createNewConfig();

    expect(p.roomConfig['ENVIRONMENT']['controlscript_profile'], 'xi');
  });

  test('other schema baseline blocks land too (METRICS_CONFIG)', () async {
    writeTemplate({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS'},
    });
    final p = await provider();

    await p.createNewConfig();

    final metrics = p.roomConfig['METRICS_CONFIG'];
    expect(metrics, isA<Map>());
    expect((metrics as Map).containsKey('uri'), isTrue);
  });

  test('a non-Map already under that name is left alone, not clobbered',
      () async {
    writeTemplate({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS'},
      'ENVIRONMENT': 'something else entirely',
    });
    final p = await provider();

    await p.createNewConfig();

    expect(p.roomConfig['ENVIRONMENT'], 'something else entirely');
  });

  test('the shipped template carries the setting outright', () {
    final shipped = jsonDecode(File('config.json').readAsStringSync())
        as Map<String, dynamic>;
    final env = shipped['ENVIRONMENT'];
    expect(env, isA<Map>(),
        reason: 'the pro/xi profile should be visible in the template itself');
    expect((env as Map)['controlscript_profile'], 'pro');
  });

  /// A new config was never converted from anything, and the toolbar must not
  /// say it was.
  ///
  /// The Convert button reads [AppStateProvider.lastLoadHadChanges] and shows
  /// [AppStateProvider.systemLogs] — both of which belonged to the file that
  /// was open BEFORE New Config was pressed. Left standing, pressing Convert
  /// on a brand new room opened the previous room's migration log, naming its
  /// backup ("BSS112_old_config.json") as this config's original.
  test("a new file does not inherit the last room's conversion", () async {
    writeTemplate({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
    });
    final p = await provider();

    // What opening a legacy room leaves behind.
    p
      ..lastLoadHadChanges = true
      ..conversionAcknowledged = true
      ..lastSectionRenames = {'CAMERA1DEVICE': 'CAMERADEVICE_1'};
    p.systemLogs.addAll([
      "BACKUP SAVED: Original file preserved as 'BSS112_old_config.json'",
      'KEY MAPPING: Translated 14 legacy item(s)',
    ]);

    expect(await p.createNewConfig(), isTrue);

    expect(p.systemLogs, isEmpty,
        reason: 'the log describes a file this room has nothing to do with');
    expect(p.lastLoadHadChanges, isFalse,
        reason: 'nothing was converted, so Convert has nothing to open');
    expect(p.conversionNeedsAttention, isFalse);
    expect(p.conversionAcknowledged, isFalse);
    expect(p.lastSectionRenames, isEmpty);
  });
}
