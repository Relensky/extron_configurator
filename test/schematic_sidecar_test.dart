import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// The schematic belongs to the config file it was drawn for: it is saved as
/// `<config>_control_schematic.json` beside it, and must come back from that
/// folder
/// when the config is opened — not only when the Schematic tab is visited.
/// The one judgment call is a session that already has a diagram of its own;
/// that is the case the UI prompts about, driven by [schematicLayoutNeedsChoice].
void main() {
  late Directory dir;
  late String configPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('schematic_sidecar_test_');
    configPath = path.join(dir.path, 'BSS103_config.json');
    File(configPath).writeAsStringSync('{}');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Writes a sidecar next to [configPath] holding one node and one line.
  void writeSidecar() {
    File(path.join(dir.path, 'BSS103_config_control_schematic.json'))
        .writeAsStringSync(jsonEncode({
      'positions': {
        'PROJECTORDEVICE_1': [120.0, 340.0]
      },
      'links': [
        {'from': 'PROCESSOR', 'to': 'IDF', 'color': '42A5F5', 'label': 'uplink'}
      ],
      'hiddenEdges': ['PROCESSOR>DSPDEVICE_1'],
    }));
  }

  AppStateProvider openedOn(String configFile) =>
      AppStateProvider(autoLoadSettings: false)..currentConfigPath = configFile;

  test('the sidecar path sits next to the working config', () {
    final p = openedOn(configPath);
    expect(p.schematicSidecarPath,
        path.join(dir.path, 'BSS103_config_control_schematic.json'));
  });

  test('opening a config loads the layout saved in its folder', () {
    writeSidecar();
    final p = openedOn(configPath);

    p.loadSchematicLayoutForCurrentConfig();

    expect(p.schematicPositions['PROJECTORDEVICE_1'], const Offset(120, 340));
    expect(p.schematicLinks.single['label'], 'uplink');
    expect(p.schematicHiddenEdges, contains('PROCESSOR>DSPDEVICE_1'));
  });

  test('a config with no saved layout opens on a blank diagram', () {
    final p = openedOn(configPath);
    p.setSchematicPosition('PROJECTORDEVICE_1', const Offset(10, 10));

    p.loadSchematicLayoutForCurrentConfig();

    expect(p.hasSchematicLayout, isFalse);
  });

  group('choosing between an arranged diagram and the saved one', () {
    test('no prompt when the session has drawn nothing', () {
      writeSidecar();
      final p = openedOn(configPath);
      expect(p.schematicLayoutNeedsChoice, isFalse);
    });

    test('no prompt when the opened config has no saved layout', () {
      final p = openedOn(configPath);
      p.setSchematicPosition('PROJECTORDEVICE_1', const Offset(10, 10));
      expect(p.schematicLayoutNeedsChoice, isFalse);
    });

    test('prompts when both exist', () {
      writeSidecar();
      final p = openedOn(configPath);
      p.setSchematicPosition('PROJECTORDEVICE_1', const Offset(10, 10));
      expect(p.schematicLayoutNeedsChoice, isTrue);
    });

    test('discarding the saved layout keeps the arranged one, and the tab '
        'does not overwrite it later', () {
      writeSidecar();
      final p = openedOn(configPath);
      p.setSchematicPosition('PROJECTORDEVICE_1', const Offset(10, 10));

      p.keepSchematicLayoutForCurrentConfig();
      expect(p.schematicPositions['PROJECTORDEVICE_1'], const Offset(10, 10));

      // Visiting the Schematic tab afterwards must not undo that answer.
      p.ensureSchematicLayoutForCurrentConfig();
      expect(p.schematicPositions['PROJECTORDEVICE_1'], const Offset(10, 10));
      expect(p.schematicLayoutNeedsChoice, isFalse);
    });

    test('taking the saved layout replaces the arranged one', () {
      writeSidecar();
      final p = openedOn(configPath);
      p.setSchematicPosition('PROJECTORDEVICE_1', const Offset(10, 10));

      p.loadSchematicLayoutForCurrentConfig();

      expect(p.schematicPositions['PROJECTORDEVICE_1'], const Offset(120, 340));
      expect(p.schematicLayoutNeedsChoice, isFalse);
    });
  });

  test('a corrupt sidecar leaves a blank diagram instead of throwing', () {
    File(path.join(dir.path, 'BSS103_config_control_schematic.json'))
        .writeAsStringSync('not json at all');
    final p = openedOn(configPath);

    p.loadSchematicLayoutForCurrentConfig();

    expect(p.hasSchematicLayout, isFalse);
  });

  test('a round trip through the sidecar preserves the layout', () async {
    final p = openedOn(configPath);
    p.setSchematicPosition('DSPDEVICE_1', const Offset(64, 96));
    p.addSchematicLink('PROCESSOR', 'DSPDEVICE_1', 'FFA726', 'COM1');
    p.hideSchematicEdge('PROCESSOR>IDF');

    final saved = await p.saveSchematicLayout();
    expect(saved, isNotEmpty);

    final reopened = openedOn(configPath)
      ..loadSchematicLayoutForCurrentConfig();

    expect(reopened.schematicPositions['DSPDEVICE_1'], const Offset(64, 96));
    expect(reopened.schematicLinks.single['label'], 'COM1');
    expect(reopened.schematicHiddenEdges, contains('PROCESSOR>IDF'));
  });

  group('the rename from <config>_schematic.json', () {
    String legacyPath() => path.join(dir.path, 'BSS103_config_schematic.json');
    String currentPath() =>
        path.join(dir.path, 'BSS103_config_control_schematic.json');

    void writeLegacy() {
      File(legacyPath()).writeAsStringSync(jsonEncode({
        'positions': {
          'DSPDEVICE_1': [11.0, 22.0]
        },
        'links': [
          {'from': 'PROCESSOR', 'to': 'IDF', 'color': '42A5F5', 'label': 'old'}
        ],
        'hiddenEdges': <String>[],
      }));
    }

    test('a pre-rename file is still found and read', () {
      writeLegacy();
      final p = openedOn(configPath);

      expect(p.hasSavedSchematicLayout, isTrue);
      p.loadSchematicLayoutForCurrentConfig();

      expect(p.schematicPositions['DSPDEVICE_1'], const Offset(11, 22));
      expect(p.schematicLinks.single['label'], 'old');
    });

    test('loading one does NOT move it - a read leaves the folder alone', () {
      writeLegacy();
      openedOn(configPath).loadSchematicLayoutForCurrentConfig();

      expect(File(legacyPath()).existsSync(), isTrue);
      expect(File(currentPath()).existsSync(), isFalse);
    });

    test('saving moves it: new file written, old one retired', () async {
      writeLegacy();
      final p = openedOn(configPath)..loadSchematicLayoutForCurrentConfig();

      final saved = await p.saveSchematicLayout();

      expect(saved, currentPath());
      expect(File(currentPath()).existsSync(), isTrue);
      expect(
        File(legacyPath()).existsSync(),
        isFalse,
        reason: 'a stale duplicate would quietly diverge from the real one',
      );

      // And the content survived the move.
      final reopened = openedOn(configPath)
        ..loadSchematicLayoutForCurrentConfig();
      expect(reopened.schematicPositions['DSPDEVICE_1'], const Offset(11, 22));
      expect(reopened.schematicLinks.single['label'], 'old');
    });

    test('the current name wins when both are present', () {
      writeLegacy();
      File(currentPath()).writeAsStringSync(jsonEncode({
        'positions': {
          'DSPDEVICE_1': [99.0, 99.0]
        },
        'links': <Map<String, String>>[],
        'hiddenEdges': <String>[],
      }));

      final p = openedOn(configPath)..loadSchematicLayoutForCurrentConfig();

      expect(p.schematicPositions['DSPDEVICE_1'], const Offset(99, 99));
      expect(p.schematicLinks, isEmpty);
    });

    test('a room with no sidecar at all is unaffected', () async {
      final p = openedOn(configPath);
      p.setSchematicPosition('IDF', const Offset(5, 5));

      final saved = await p.saveSchematicLayout();

      expect(saved, currentPath());
      expect(File(legacyPath()).existsSync(), isFalse);
    });
  });
}
