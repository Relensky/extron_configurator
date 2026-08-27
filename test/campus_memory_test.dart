import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_file.dart';

/// ============================================================================
///  WHICH SHEET A JOB IS ON
/// ============================================================================
///  The link between a campus and its buildings ran one way: the campus named
///  its jobs and a job named nothing. So Campus, pressed inside a building,
///  gave a sheet of ONE building and left somebody to find the other
///  thirty-three on disk — every session, by whoever was in it.
///
///  What is held here: that a job remembers its sheet as a PATH and never as a
///  copy of the list, that the pointer travels with the folder, that saving a
///  campus is what tells the jobs on it, and that a campus which has since been
///  moved or deleted falls back to the sheet of one rather than failing.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_campus_mem'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A real project file, so the paths under test are real ones.
  String job(String stem, {String folder = ''}) {
    final root = folder.isEmpty ? dir.path : path.join(dir.path, folder);
    Directory(root).createSync(recursive: true);
    final file = path.join(root, '${stem}_project.json');
    File(file).writeAsStringSync(
      jsonEncode(BuildingProject(name: stem, building: stem).toJson()),
    );
    return file;
  }

  BuildingProject readBack(String file) => BuildingProject.fromJson(
    Map<String, dynamic>.from(jsonDecode(File(file).readAsStringSync()) as Map),
  );

  group('the pointer on the job', () {
    test('is stored relative and comes back absolute', () async {
      final file = job('AGYM');
      final campus = path.join(dir.path, 'Chico_campus.json');

      final project = await BuildingProject.load(file);
      project.campusFile = BuildingProject.storePath(campus, file);
      await project.save(file);

      // Relative on disk, so the whole folder can be copied to a laptop.
      final doc =
          jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
      expect(doc['campusFile'], 'Chico_campus.json');

      expect(readBack(file).resolvedCampusFile(file), campus);
    });

    test('is a path and never a copy of the campus', () async {
      final file = job('AGYM');
      final project = await BuildingProject.load(file);
      project.campusFile = 'Chico_campus.json';
      await project.save(file);

      final doc = jsonDecode(File(file).readAsStringSync()) as Map;
      // A job that cached the estate would be a job that could disagree with
      // it, which is the drift the whole lifecycle feature exists to remove.
      for (final key in ['campus', 'campusProjects', 'campusName']) {
        expect(doc.containsKey(key), isFalse, reason: '$key is the sheet\'s');
      }
    });

    test('a job on no campus writes no key at all', () {
      final doc = BuildingProject(name: 'AGYM').toJson();
      expect(doc.containsKey('campusFile'), isFalse);
    });

    test('a clone keeps it', () {
      final project = BuildingProject(name: 'AGYM')
        ..campusFile = 'Chico_campus.json';
      expect(project.clone().campusFile, 'Chico_campus.json');
    });
  });

  group('saving the campus tells the jobs on it', () {
    test('every job comes to point back at the sheet', () async {
      final jobs = [job('AGYM'), job('BSS'), job('SCI')];
      final campus = path.join(dir.path, 'Chico_campus.json');
      await CampusFile(name: 'Chico', projects: jobs).save(campus);

      final result = await stampCampusIntoProjects(
        campusPath: campus,
        projects: jobs,
      );
      expect(result.written, 3);
      expect(result.failed, isEmpty);

      for (final j in jobs) {
        expect(readBack(j).resolvedCampusFile(j), campus);
      }
    });

    test('a job that already points here is not rewritten', () async {
      final jobs = [job('AGYM'), job('BSS')];
      final campus = path.join(dir.path, 'Chico_campus.json');
      await CampusFile(name: 'Chico', projects: jobs).save(campus);

      await stampCampusIntoProjects(campusPath: campus, projects: jobs);
      final again = await stampCampusIntoProjects(
        campusPath: campus,
        projects: jobs,
      );
      expect(again.written, 0);
      expect(again.unchanged, 2);
    });

    test('the job this session has open is left for the session to set',
        () async {
      final open = job('AGYM');
      final other = job('BSS');
      final campus = path.join(dir.path, 'Chico_campus.json');

      final result = await stampCampusIntoProjects(
        campusPath: campus,
        projects: [open, other],
        skip: open,
      );
      expect(result.written, 1);
      // Its file on disk is stale by definition - there may be unsaved work in
      // front of it, and writing underneath would lose it or be lost by it.
      expect(readBack(open).campusFile, isEmpty);
      expect(readBack(other).campusFile, isNotEmpty);
    });

    test('one unreadable job does not undo the rest', () async {
      final good = job('AGYM');
      final broken = path.join(dir.path, 'BROKEN_project.json');
      File(broken).writeAsStringSync('not json at all');
      final campus = path.join(dir.path, 'Chico_campus.json');

      final result = await stampCampusIntoProjects(
        campusPath: campus,
        projects: [good, broken],
      );
      expect(result.written, 1);
      expect(result.failed, ['BROKEN_project.json']);
      expect(readBack(good).campusFile, isNotEmpty);
    });

    test('a job in a folder below the campus keeps a relative pointer',
        () async {
      final nested = job('AGYM', folder: 'jobs');
      final campus = path.join(dir.path, 'Chico_campus.json');

      // A campus SITTING ABOVE its jobs is the ordinary shape of an estate,
      // and the pointer has to climb for the folder to survive being copied.
      await stampCampusIntoProjects(campusPath: campus, projects: [nested]);
      expect(readBack(nested).campusFile, path.join('..', 'Chico_campus.json'));
      expect(readBack(nested).resolvedCampusFile(nested), campus);
    });

    test('a job nowhere near the campus stores the absolute path', () async {
      final far = job('AGYM', folder: path.join('a', 'b', 'c', 'd'));
      final campus = path.join(dir.path, 'Chico_campus.json');

      // Four levels up is two files that happen to be on one disk. A `..`
      // chain that long breaks on any move at all, which is the one thing a
      // relative path is for.
      await stampCampusIntoProjects(campusPath: campus, projects: [far]);
      expect(readBack(far).campusFile, campus);
      expect(readBack(far).resolvedCampusFile(far), campus);
    });
  });

  group('what the Campus button is handed', () {
    test('the remembered sheet, once the job knows one', () async {
      final file = job('AGYM');
      final campus = path.join(dir.path, 'Chico_campus.json');
      await CampusFile(name: 'Chico', projects: [file]).save(campus);

      final provider = AppStateProvider(autoLoadSettings: false);
      expect(await provider.openProject(file), isEmpty);
      expect(provider.projectCampusFile, isEmpty);

      provider.setProjectCampusFile(campus);
      expect(provider.projectCampusFile, campus);
      expect(provider.project.campusFile, 'Chico_campus.json');
    });

    test('nothing, when the sheet it remembers has been deleted', () async {
      final file = job('AGYM');
      final campus = path.join(dir.path, 'Chico_campus.json');
      await CampusFile(name: 'Chico', projects: [file]).save(campus);

      final provider = AppStateProvider(autoLoadSettings: false);
      await provider.openProject(file);
      provider.setProjectCampusFile(campus);
      File(campus).deleteSync();

      // Folders get renamed and jobs get copied out of them. The honest answer
      // then is the sheet of one, not an error about a file nobody asked to
      // open.
      expect(provider.projectCampusFile, isEmpty);
      expect(provider.project.campusFile, isNotEmpty, reason: 'still recorded');
    });

    test('the pointer is re-homed when the job is saved somewhere else',
        () async {
      final file = job('AGYM', folder: 'chico');
      final campus = path.join(dir.path, 'chico', 'Chico_campus.json');
      await CampusFile(name: 'Chico', projects: [file]).save(campus);

      final provider = AppStateProvider(autoLoadSettings: false);
      await provider.openProject(file);
      provider.setProjectCampusFile(campus);
      expect(provider.project.campusFile, 'Chico_campus.json');

      final elsewhere = path.join(dir.path, 'AGYM_project.json');
      expect(await provider.saveProject(to: elsewhere), isEmpty);

      // A job saved into another folder that kept its old relative pointer
      // would open the wrong sheet, or none.
      expect(provider.projectCampusFile, campus);
      expect(readBack(elsewhere).resolvedCampusFile(elsewhere), campus);
    });
  });

  group('is this job on that sheet', () {
    test('yes, however the path was spelled', () async {
      final file = job('AGYM');
      final campus = CampusFile(name: 'Chico', projects: [file]);
      expect(campusListsProject(campus, file), isTrue);
      expect(
        campusListsProject(
          campus,
          path.join(dir.path, '.', 'AGYM_project.json'),
        ),
        isTrue,
      );
    });

    test('no, for a job that is not on it', () {
      final campus = CampusFile(name: 'Chico', projects: [job('AGYM')]);
      expect(campusListsProject(campus, job('BSS')), isFalse);
      expect(campusListsProject(campus, ''), isFalse);
    });
  });
}
