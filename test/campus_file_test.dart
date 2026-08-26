import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/campus_file.dart';

/// ============================================================================
///  A CAMPUS, AS A FILE
/// ============================================================================
///  Assembling a campus is picking eleven projects out of four folders. Until
///  now that assembly lived in one window and died with it, so the next person
///  to want the same estate rebuilt it from memory and got a different eleven.
///
///  What these guard is the promise that makes the file safe to keep: it holds
///  the LIST and never the figures. A campus that cached a total would be a
///  document that could disagree with the buildings it names, which is the
///  drift the whole lifecycle feature exists to remove.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_campus_file'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// An empty file standing in for a project, so the paths are real ones.
  String job(String stem, {String folder = ''}) {
    final root = folder.isEmpty ? dir.path : path.join(dir.path, folder);
    Directory(root).createSync(recursive: true);
    final file = path.join(root, '${stem}_project.json');
    File(file).writeAsStringSync('{"name":"$stem","rooms":[]}');
    return file;
  }

  test('it round-trips the list, and nothing else', () async {
    final file = path.join(dir.path, 'chico_campus.json');
    await CampusFile(
      name: 'Chico campus',
      projects: [job('bss'), job('phy')],
    ).save(file);

    final doc = jsonDecode(await File(file).readAsString()) as Map;
    expect(doc['kind'], 'campus');
    expect(doc['name'], 'Chico campus');
    expect((doc['projects'] as List), hasLength(2));
    // NOT A CACHE OF THE PLAN. Nothing in here is a figure - open it in June
    // and it reads June's jobs off disk.
    for (final key in ['total', 'years', 'refreshCost', 'rooms', 'items']) {
      expect(doc.containsKey(key), isFalse, reason: '$key has no business in a campus file');
    }

    final back = await CampusFile.load(file);
    expect(back.name, 'Chico campus');
    expect(back.file, file);
    expect(
      [for (final p in back.projects) path.basename(p)],
      ['bss_project.json', 'phy_project.json'],
    );
  });

  test('a job under the campus is stored relative, and survives a move',
      () async {
    final file = path.join(dir.path, 'chico_campus.json');
    await CampusFile(
      name: 'Chico',
      projects: [job('bss', folder: 'BSS')],
    ).save(file);

    final doc = jsonDecode(await File(file).readAsString()) as Map;
    expect(
      (doc['projects'] as List).single,
      isNot(contains(dir.path)),
      reason: 'a path under the campus is written relative to it',
    );

    // The whole folder copied somewhere else still opens.
    final moved = Directory(path.join(dir.path, 'copy'))..createSync();
    File(path.join(moved.path, 'BSS')).parent.createSync(recursive: true);
    Directory(path.join(moved.path, 'BSS')).createSync(recursive: true);
    File(path.join(moved.path, 'BSS', 'bss_project.json'))
        .writeAsStringSync('{"name":"bss","rooms":[]}');
    final movedFile = path.join(moved.path, 'chico_campus.json');
    File(movedFile).writeAsStringSync(await File(file).readAsString());

    final back = await CampusFile.load(movedFile);
    expect(File(back.projects.single).existsSync(), isTrue);
  });

  test('a job outside the campus folder keeps its absolute path', () async {
    final elsewhere = Directory.systemTemp.createTempSync('rcb_other_job');
    addTearDown(() {
      try {
        elsewhere.deleteSync(recursive: true);
      } catch (_) {}
    });
    final far = path.join(elsewhere.path, 'far_project.json');
    File(far).writeAsStringSync('{"name":"far","rooms":[]}');

    final file = path.join(dir.path, 'chico_campus.json');
    await CampusFile(name: 'Chico', projects: [far]).save(file);
    final back = await CampusFile.load(file);
    expect(back.projects.single, path.normalize(far));
  });

  group('telling it from the other two documents', () {
    test('by its name, and by what is inside it when renamed', () {
      final named = path.join(dir.path, 'chico_campus.json');
      File(named).writeAsStringSync('{}');
      expect(CampusFile.looksLikeCampus(named), isTrue);

      final renamed = path.join(dir.path, 'whatever.json');
      File(renamed).writeAsStringSync(
        jsonEncode({'kind': 'campus', 'projects': <String>[]}),
      );
      expect(CampusFile.looksLikeCampus(renamed), isTrue);
    });

    test('a project is not a campus, and neither is a room', () {
      expect(CampusFile.looksLikeCampus(job('bss')), isFalse);

      final room = path.join(dir.path, 'bss101_config.json');
      File(room).writeAsStringSync('{"SYSTEM_SETUP":{}}');
      expect(CampusFile.looksLikeCampus(room), isFalse);
    });

    test('and neither is something unreadable', () {
      final junk = path.join(dir.path, 'junk.json');
      File(junk).writeAsStringSync('not json at all');
      expect(CampusFile.looksLikeCampus(junk), isFalse);
    });
  });

  test('a file with no name in it is called after itself', () async {
    final file = path.join(dir.path, 'north_of_the_creek_campus.json');
    File(file).writeAsStringSync(
      jsonEncode({'kind': 'campus', 'projects': <String>[]}),
    );
    expect((await CampusFile.load(file)).name, 'north of the creek');
  });

  test('a file with no list of projects says so rather than opening empty',
      () async {
    final file = path.join(dir.path, 'broken_campus.json');
    File(file).writeAsStringSync(jsonEncode({'kind': 'campus'}));
    expect(CampusFile.load(file), throwsA(isA<FormatException>()));
  });
}
