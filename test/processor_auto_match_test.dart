import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// Opening a room picks its deployment processor out of processors.json when
/// the list names exactly one for it - so Upload goes to the right box without
/// anybody choosing it - and never guesses between two.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('proc_match_'));
  tearDown(() => dir.deleteSync(recursive: true));

  AppStateProvider withProcessors(List<Map<String, dynamic>> list) =>
      AppStateProvider(autoLoadSettings: false)..processors = list;

  String writeRoom(String name, Map<String, dynamic> setup) {
    final file = path.join(dir.path, name);
    File(file).writeAsStringSync(jsonEncode({'SYSTEM_SETUP': setup}));
    return file;
  }

  const agym = {'roomName': 'AGYM 129', 'ipAddress': '10.248.129.8'};
  const bss = {'roomName': 'BSS 103', 'ipAddress': '10.1.1.3'};

  test('matches the building code and room number', () async {
    final p = withProcessors([agym, bss]);
    await p.openConfigAtPath(
      writeRoom('x.json', {'gve_bldg': 'BSS', 'gve_room': '103'}),
    );
    expect(p.selectedProcessor?['roomName'], 'BSS 103');
    expect(p.selectedProcessorIp, '10.1.1.3');
  });

  test('falls back to the file name', () async {
    final p = withProcessors([agym, bss]);
    await p.openConfigAtPath(writeRoom('AGYM_129_config.json', {}));
    expect(p.selectedProcessor?['roomName'], 'AGYM 129');
  });

  test('picks nothing when no processor matches', () async {
    final p = withProcessors([agym]);
    await p.openConfigAtPath(
      writeRoom('x.json', {'gve_bldg': 'SSC', 'gve_room': '210'}),
    );
    expect(p.selectedProcessor, isNull);
  });

  test('never guesses between two processors with the same name', () async {
    final p = withProcessors([bss, {...bss, 'ipAddress': '10.9.9.9'}]);
    await p.openConfigAtPath(
      writeRoom('x.json', {'gve_bldg': 'BSS', 'gve_room': '103'}),
    );
    expect(p.selectedProcessor, isNull);
  });

  test('opening a different room replaces the match', () async {
    final p = withProcessors([agym, bss]);
    await p.openConfigAtPath(
      writeRoom('a.json', {'gve_bldg': 'BSS', 'gve_room': '103'}),
    );
    await p.openConfigAtPath(
      writeRoom('b.json', {'gve_bldg': 'AGYM', 'gve_room': '129'}),
    );
    expect(p.selectedProcessor?['roomName'], 'AGYM 129');
  });
}
