import 'dart:convert';
import 'dart:io';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/services/ios_share.dart';
import 'package:extron_configurator/services/share_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The CTS share on an iPad, played by a temp folder: the Classroom
/// Technology folder picked, the offline copy in a data folder beside it.
void main() {
  late Directory tmp;
  late String classroomTech; // the picked folder
  late String projects; // ...\Projects on "the share"
  late String mirrorProjects; // ...\Projects in the copy

  const ctUnc = r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology';

  /// Sets [file]'s time well apart from any other, so a change is a change
  /// whatever the file system's clock resolution.
  void stamp(String file, int minutesAgo) => File(file).setLastModifiedSync(
      DateTime.now().subtract(Duration(minutes: minutesAgo)));

  void write(String file, String text, {int minutesAgo = 60}) {
    File(file).parent.createSync(recursive: true);
    File(file).writeAsStringSync(text);
    stamp(file, minutesAgo);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ios_share_');
    classroomTech = p.join(tmp.path, 'smb', 'ATEC', 'CTS', 'StaffFiles',
        'Classroom Technology');
    projects = p.join(classroomTech, 'Projects');
    Directory(p.join(projects, 'Configurator_Files')).createSync(recursive: true);
    IosShare.dataDirForTest = p.join(tmp.path, 'data');
    IosShare.useForTest(classroomTech, unc: ctUnc);
    ShareSync.runAnywhereForTest = true;
    mirrorProjects = p.join(IosShare.mirrorRoot, 'CTS', 'StaffFiles',
        'Classroom Technology', 'Projects');
  });

  tearDown(() {
    IosShare.useForTest(null);
    IosShare.dataDirForTest = null;
    ShareSync.runAnywhereForTest = false;
    tmp.deleteSync(recursive: true);
  });

  group('paths', () {
    test('a share path is the picked folder, the domain or not', () {
      expect(sharePath('$ctUnc\\Projects\\Job\\job.json'),
          p.join(projects, 'Job', 'job.json'));
      expect(
          sharePath(r'\\doit-files.csuchico.edu\ATEC\CTS\StaffFiles'
              r'\Classroom Technology\Projects'),
          projects);
      expect(sharePath(r'C:\Users\x\file.json'), r'C:\Users\x\file.json');
    });

    test('offline, a share path is its place in the copy, and back', () {
      IosShare.offline = true;
      final offline = sharePath('$ctUnc\\Projects\\Job\\job.json');
      expect(offline, p.join(mirrorProjects, 'Job', 'job.json'));
      IosShare.offline = false;
      expect(sharePath(offline), p.join(projects, 'Job', 'job.json'));
    });

    test('a local share path is written back as the share path', () {
      expect(uncPath(p.join(projects, 'Job', 'job.json')),
          r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Projects\Job\job.json');
      expect(uncPath(p.join(mirrorProjects, 'Job')),
          r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Projects\Job');
      expect(uncPath('/somewhere/else'), '/somewhere/else');
    });

    test('a room saved on Windows resolves on the iPad', () {
      final job = p.join(projects, 'BMU', 'BMU_project.json');
      expect(BuildingProject.resolvePath(r'Rooms\BMU 101\room_config.json', job),
          p.join(projects, 'BMU', 'Rooms', 'BMU 101', 'room_config.json'));
      expect(
          BuildingProject.resolvePath(
              '$ctUnc\\Projects\\BMU\\Rooms\\BMU 102\\room_config.json', job),
          p.join(projects, 'BMU', 'Rooms', 'BMU 102', 'room_config.json'));
    });

    test('a room outside the job is stored as a share path', () {
      final job = p.join(projects, 'BMU', 'BMU_project.json');
      expect(
          BuildingProject.storePath(
              p.join(projects, 'Other', 'room_config.json'), job),
          '$ctUnc\\Projects\\Other\\room_config.json');
      expect(
          BuildingProject.storePath(
              p.join(projects, 'BMU', 'Rooms', 'A', 'room_config.json'), job),
          p.join('Rooms', 'A', 'room_config.json'));
    });
  });

  group('sync', () {
    /// The Projects folder relative to the share's top, as the sync names
    /// files.
    const rel = 'CTS/StaffFiles/Classroom Technology/Projects';
    String share(String rel) => p.join(projects, rel);
    String copy(String rel) => p.join(mirrorProjects, rel);

    test('the configurator files come down; a file gone from the share goes',
        () async {
      write(share('Configurator_Files/av_devices.json'), '{"devices":[]}');
      write(share('Configurator_Files/assets/logo.png'), 'png');
      final r = await ShareSync.syncNow();
      expect(r.received, 2);
      expect(File(copy('Configurator_Files/av_devices.json')).readAsStringSync(),
          '{"devices":[]}');

      File(share('Configurator_Files/assets/logo.png')).deleteSync();
      final r2 = await ShareSync.syncNow();
      expect(r2.removed, 1);
      expect(File(copy('Configurator_Files/assets/logo.png')).existsSync(),
          isFalse);
    });

    test('an edit made offline goes up when the share answers', () async {
      write(share('Configurator_Files/base_costs.json'), '{"a":1}');
      await ShareSync.syncNow();

      IosShare.offline = true;
      final offlinePath =
          sharePath('$ctUnc\\Projects\\Configurator_Files\\base_costs.json');
      expect(offlinePath, copy('Configurator_Files/base_costs.json'));
      write(offlinePath, '{"a":2}', minutesAgo: 1);

      final r = await ShareSync.syncNow(); // the share answers again
      expect(IosShare.offline, isFalse);
      expect(r.sent, 1);
      expect(File(share('Configurator_Files/base_costs.json')).readAsStringSync(),
          '{"a":2}');
      // And nothing waits the next time.
      final r2 = await ShareSync.syncNow();
      expect(r2.sent + r2.received, 0);
    });

    test('a JSON file changed on both sides is held until reviewed',
        () async {
      write(share('Configurator_Files/vendors.json'),
          jsonEncode({'a': 1, 'b': 1}));
      await ShareSync.syncNow();

      write(copy('Configurator_Files/vendors.json'),
          jsonEncode({'a': 2, 'b': 1}),
          minutesAgo: 2);
      write(share('Configurator_Files/vendors.json'),
          jsonEncode({'a': 1, 'b': 3, 'c': 4}),
          minutesAgo: 1);

      // Nothing combined on its own: both sides as they were.
      final r = await ShareSync.syncNow();
      expect(r.held, ['$rel/Configurator_Files/vendors.json']);
      expect(ShareSync.status.value.held, r.held);
      expect(
          jsonDecode(
              File(share('Configurator_Files/vendors.json')).readAsStringSync()),
          {'a': 1, 'b': 3, 'c': 4});
      expect(
          jsonDecode(
              File(copy('Configurator_Files/vendors.json')).readAsStringSync()),
          {'a': 2, 'b': 1});
      // And still held the next time.
      expect((await ShareSync.syncNow()).held, hasLength(1));

      // Reviewed: the base, mine and theirs are there to combine, and the
      // approved combine goes to both sides.
      final review = (await ShareSync.loadReview(r.held.single))!;
      expect(review.json, isTrue);
      expect(review.base, {'a': 1, 'b': 1});
      expect(review.mine, {'a': 2, 'b': 1});
      expect(review.theirs, {'a': 1, 'b': 3, 'c': 4});
      await ShareSync.applyCombined(review, {'a': 2, 'b': 3, 'c': 4});
      expect(
          jsonDecode(
              File(share('Configurator_Files/vendors.json')).readAsStringSync()),
          {'a': 2, 'b': 3, 'c': 4});
      expect(
          jsonDecode(
              File(copy('Configurator_Files/vendors.json')).readAsStringSync()),
          {'a': 2, 'b': 3, 'c': 4});
      expect(ShareSync.status.value.held, isEmpty);
      final after = await ShareSync.syncNow();
      expect(after.held, isEmpty);
      expect(after.sent + after.received, 0);
    });

    test('a combine is refused when the share changed during the review',
        () async {
      write(share('Configurator_Files/costs.json'), jsonEncode({'a': 1}));
      await ShareSync.syncNow();
      write(copy('Configurator_Files/costs.json'), jsonEncode({'a': 2}),
          minutesAgo: 3);
      write(share('Configurator_Files/costs.json'), jsonEncode({'a': 3}),
          minutesAgo: 2);
      final r = await ShareSync.syncNow();
      final review = (await ShareSync.loadReview(r.held.single))!;
      write(share('Configurator_Files/costs.json'), jsonEncode({'a': 4}),
          minutesAgo: 1);
      await expectLater(ShareSync.applyCombined(review, {'a': 2}),
          throwsA(isA<ShareChangedAgain>()));
      expect(
          jsonDecode(
              File(share('Configurator_Files/costs.json')).readAsStringSync()),
          {'a': 4});
    });

    test('another file changed on both sides is kept as decided', () async {
      write(share('Configurator_Files/plan.pdf'), 'one');
      write(share('Configurator_Files/photo.jpg'), 'one');
      await ShareSync.syncNow();

      write(copy('Configurator_Files/plan.pdf'), 'mine!', minutesAgo: 2);
      write(share('Configurator_Files/plan.pdf'), 'theirs', minutesAgo: 1);
      write(copy('Configurator_Files/photo.jpg'), 'mine!', minutesAgo: 2);
      write(share('Configurator_Files/photo.jpg'), 'theirs', minutesAgo: 1);

      final r = await ShareSync.syncNow();
      expect(r.held, hasLength(2));

      final pdf = (await ShareSync.loadReview(
          '$rel/Configurator_Files/plan.pdf'))!;
      expect(pdf.json, isFalse);
      final kept = await ShareSync.keepBoth(pdf);
      expect(kept, contains('iPad edits'));
      expect(File(share('Configurator_Files/plan.pdf')).readAsStringSync(),
          'theirs');
      expect(File(copy('Configurator_Files/plan.pdf')).readAsStringSync(),
          'theirs');
      final beside = Directory(share('Configurator_Files'))
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.contains('iPad edits'));
      expect(File(share('Configurator_Files/${beside.single}'))
          .readAsStringSync(), 'mine!');

      final jpg = (await ShareSync.loadReview(
          '$rel/Configurator_Files/photo.jpg'))!;
      await ShareSync.keepMine(jpg);
      expect(File(share('Configurator_Files/photo.jpg')).readAsStringSync(),
          'mine!');
      expect(ShareSync.status.value.held, isEmpty);
    });

    test('a job opened here is kept, its rooms and all', () async {
      write(share('BMU/BMU_project.json'), '{}');
      write(share('BMU/Rooms/BMU 101/room_config.json'), '{"room":1}');
      write(share('BMU/Rooms/BMU 101/room_files/walls.json'), '{"walls":[]}');
      write(share('Other/other_project.json'), '{}');

      ShareSync.keepFolderOf(share('BMU/BMU_project.json'));
      await ShareSync.syncNow();

      expect(File(copy('BMU/Rooms/BMU 101/room_files/walls.json')).existsSync(),
          isTrue);
      expect(File(copy('Other/other_project.json')).existsSync(), isFalse);
      expect(ShareSync.keptFolders, ['$ctUnc\\Projects\\BMU']);
    });

    test('a room\'s backups and lock files stay on the share', () async {
      write(share('Configurator_Files/labor_rates.json'), '{}');
      write(share('Configurator_Files/labor_rates.json.lock'), 'x');
      write(share('Configurator_Files/backups/old.json'), '{}');
      write(share('Configurator_Files/.editing/av_devices.json/x@pc.json'), '{}');
      write(copy('Configurator_Files/.editing/av_devices.json/me@iPad.json'), '{}');
      await ShareSync.syncNow();
      expect(File(copy('Configurator_Files/labor_rates.json')).existsSync(),
          isTrue);
      expect(File(copy('Configurator_Files/labor_rates.json.lock')).existsSync(),
          isFalse);
      expect(Directory(copy('Configurator_Files/backups')).existsSync(),
          isFalse);
      // Who is editing what is live state: never copied either way.
      expect(File(copy('Configurator_Files/.editing/av_devices.json/x@pc.json'))
          .existsSync(), isFalse);
      expect(File(share('Configurator_Files/.editing/av_devices.json/me@iPad.json'))
          .existsSync(), isFalse);
    });
  });
}
