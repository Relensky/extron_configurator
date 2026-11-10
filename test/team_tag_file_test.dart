import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/team_tag_file.dart';

/// A "working on" tag made on a copy of a room on this PC links to the
/// shared copy, or to nothing with a warning.
void main() {
  const mapped = {'S:': r'\\doit-files\ATEC'};

  test('net use is read into drive letters', () {
    const out = '''
New connections will be remembered.

Status       Local     Remote                    Network
-------------------------------------------------------------------------------
OK           S:        \\\\doit-files\\ATEC        Microsoft Windows Network
Unavailable  T:        \\\\old-server\\share       Microsoft Windows Network
The command completed successfully.
''';
    final m = parseNetUse(out);
    expect(m['S:'], r'\\doit-files\ATEC');
    expect(m['T:'], r'\\old-server\share');
  });

  test('UNC and mapped drives are shared; C: is not', () {
    expect(sharedPathOf(r'\\srv\a\config.json', mapped: mapped),
        r'\\srv\a\config.json');
    expect(sharedPathOf(r'S:\CTS\ARTS_111\config.json', mapped: mapped),
        r'\\doit-files\ATEC\CTS\ARTS_111\config.json');
    expect(sharedPathOf(r'C:\Users\me\ARTS_111\config.json', mapped: mapped),
        '');
    expect(sharedPathOf('', mapped: mapped), '');
  });

  group('the tag', () {
    TeamTagTarget target({
      String project = '',
      String config = '',
      String copy = '',
    }) => teamTagTargetOf(
      roomId: 'ARTS 111',
      projectPath: project,
      projectName: project.isEmpty ? '' : '600k',
      configPath: config,
      sharedCopy: copy,
      mapped: mapped,
    );

    test('a shared project or room links as before', () {
      final p = target(project: r'\\srv\Projects\600k.json',
          config: r'\\srv\Projects\600k\ARTS_111\config.json');
      expect(p.file, r'\\srv\Projects\600k.json');
      expect(p.project, '600k');
      expect(p.note, isEmpty);
      final r = target(config: r'S:\x\ARTS_111\config.json');
      expect(r.file, r'\\doit-files\ATEC\x\ARTS_111\config.json');
      expect(r.note, isEmpty);
    });

    test('a local copy links to the shared room, and says so', () {
      final t = target(
        config: r'C:\Users\me\ARTS_111\config.json',
        copy: r'\\srv\Projects\600k\ARTS_111\config.json',
      );
      expect(t.file, r'\\srv\Projects\600k\ARTS_111\config.json');
      expect(t.project, isEmpty);
      expect(t.note, contains('copy on this PC'));
    });

    test('a local job holding a shared room links to the room', () {
      final t = target(
        project: r'C:\jobs\600k.json',
        config: r'\\srv\Projects\600k\ARTS_111\config.json',
      );
      expect(t.file, r'\\srv\Projects\600k\ARTS_111\config.json');
      expect(t.note, isEmpty);
    });

    test('a local copy with no shared room has no file and warns', () {
      final t = target(config: r'C:\Users\me\ARTS_111\config.json');
      expect(t.file, isEmpty);
      expect(t.note, contains('cannot save it'));
    });
  });

  test('the shared copy is found by its room, not just its folder', () async {
    final root = await Directory.systemTemp.createTemp('team_tag_');
    addTearDown(() => root.delete(recursive: true));
    Future<void> room(String rel, String bldg, String num) async {
      final f = File(path.join(root.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': bldg, 'gve_room': num},
      }));
    }

    await room(r'600k\ARTS_111\config.json', 'ARTS', '111');
    await room(r'Test\BSS103\code\upload_to_root\config.json', 'BSS', '103');
    // Same folder name, a different room inside.
    await room(r'Other\ARTS_112\config.json', 'ARTS', '999');
    String idFor(Map<String, dynamic> c) {
      final s = c['SYSTEM_SETUP'] as Map;
      return '${s['gve_bldg']} ${s['gve_room']}';
    }

    expect(await findSharedRoomConfig(root.path, 'ARTS 111', idFor),
        path.join(root.path, '600k', 'ARTS_111', 'config.json'));
    expect(await findSharedRoomConfig(root.path, 'BSS 103', idFor),
        path.join(root.path, 'Test', 'BSS103', 'code', 'upload_to_root',
            'config.json'));
    expect(await findSharedRoomConfig(root.path, 'ARTS 112', idFor), '');
    expect(await findSharedRoomConfig(root.path, 'HOLT 999', idFor), '');
  });
}
