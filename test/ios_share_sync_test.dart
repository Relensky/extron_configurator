import 'dart:convert';
import 'dart:io';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/recent_files.dart';
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

    test('offline, a recent job opens from the copy, not "gone"', () {
      final live = p.join(projects, 'Job', 'job.json');
      write(p.join(mirrorProjects, 'Job', 'job.json'), '{}');
      final entry = RecentFile(
        file: live,
        name: 'Job',
        touchedAt: DateTime(2026, 11, 19),
      );
      IosShare.offline = true;
      expect(entry.stillThere, isTrue);
      expect(entry.here, p.join(mirrorProjects, 'Job', 'job.json'));
    });

    test('a path under an older SMB mount name moves to the current one', () {
      const lf = '/private/var/mobile/Library/LiveFiles/'
          'com.apple.filesystems.smbclientd';
      IosShare.useForTest('$lf/NEWxyzATEC/CTS/StaffFiles/Classroom Technology',
          unc: ctUnc);
      expect(
        sharePath('$lf/fhRfWQATEC/CTS/StaffFiles/Classroom Technology/'
            'Projects/Job/job.json'),
        '$lf/NEWxyzATEC/CTS/StaffFiles/Classroom Technology/Projects/Job/'
            'job.json',
      );
      // Another share on the same server is not this one.
      expect(sharePath('$lf/fhRfWQOTHER/x.json'), '$lf/fhRfWQOTHER/x.json');
    }, skip: Platform.isWindows);

    test('a local share path is written back as the share path', () {
      expect(uncPath(p.join(projects, 'Job', 'job.json')),
          r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Projects\Job\job.json');
      expect(uncPath(p.join(mirrorProjects, 'Job')),
          r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Projects\Job');
      expect(uncPath('/somewhere/else'), '/somewhere/else');
    });

    test('a folder is named the way the Files app lists it', () {
      expect(
        IosShare.filesAppPath(p.join(projects, 'Job')),
        'doit-files > ATEC > CTS > StaffFiles > Classroom Technology > '
        'Projects > Job',
      );
      expect(IosShare.filesAppPath('/somewhere/else'),
          'On My iPhone > Room Config Builder');
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
    // In the host's separators, whatever [rel] is written with.
    String share(String rel) => p.joinAll([projects, ...rel.split('/')]);
    String copy(String rel) => p.joinAll([mirrorProjects, ...rel.split('/')]);

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

    test('a paused job waits; it syncs alone when asked', () async {
      write(share('A/A_project.json'), '{"a":1}');
      write(share('B/B_project.json'), '{"b":1}');
      ShareSync.keepFolderOf(share('A/A_project.json'));
      ShareSync.keepFolderOf(share('B/B_project.json'));
      await ShareSync.syncNow();
      final aUnc = '$ctUnc\\Projects\\A';
      final bUnc = '$ctUnc\\Projects\\B';

      ShareSync.setPaused(bUnc, true);
      expect(ShareSync.isPaused(bUnc), isTrue);
      write(copy('A/A_project.json'), '{"a":2}', minutesAgo: 1);
      write(copy('B/B_project.json'), '{"b":2}', minutesAgo: 1);
      write(share('B/new.json'), '{}');
      await ShareSync.syncNow();
      // A went up; B waited, both ways, and still counts as waiting.
      expect(File(share('A/A_project.json')).readAsStringSync(), '{"a":2}');
      expect(File(share('B/B_project.json')).readAsStringSync(), '{"b":1}');
      expect(File(copy('B/new.json')).existsSync(), isFalse);
      expect(ShareSync.status.value.pending, 1);

      // B on its own, though paused.
      write(copy('A/A_project.json'), '{"a":3}', minutesAgo: 0);
      await ShareSync.syncFolder(bUnc);
      expect(File(share('B/B_project.json')).readAsStringSync(), '{"b":2}');
      expect(File(copy('B/new.json')).existsSync(), isTrue);
      // ...and A was left alone.
      expect(File(share('A/A_project.json')).readAsStringSync(), '{"a":2}');
      expect(ShareSync.isPaused(bUnc), isTrue);
      expect(ShareSync.isPaused(aUnc), isFalse);
    });

    test('a whole job comes down, rooms in other folders too', () async {
      write(share('BMU/BMU_project.json'), '{"rooms":[]}');
      write(share('BMU/plans/level1.pdf'), 'pdf');
      // A room kept beside another job, not in the job's own folder.
      write(share('Shared Rooms/BMU 210/BMU210_config.json'), '{}');
      write(share('Elsewhere/untouched.json'), '{}');
      final added = await ShareSync.keepJobOffline([
        sharePath('$ctUnc\\Projects\\BMU\\BMU_project.json'),
        sharePath('$ctUnc\\Projects\\Shared Rooms\\BMU 210\\BMU210_config.json'),
        sharePath('$ctUnc\\Projects\\BMU\\plans\\level1.pdf'),
      ]);
      // The plans folder is inside the job's, so two folders, not three.
      expect(added, 2);
      expect(File(copy('BMU/BMU_project.json')).existsSync(), isTrue);
      expect(File(copy('BMU/plans/level1.pdf')).existsSync(), isTrue);
      expect(File(copy('Shared Rooms/BMU 210/BMU210_config.json')).existsSync(),
          isTrue);
      expect(File(copy('Elsewhere/untouched.json')).existsSync(), isFalse);
    });

    test('the device manuals come down, and are never sent back', () async {
      final manuals = p.join(classroomTech, 'Dashboard', 'manuals');
      final copyManuals = p.join(IosShare.mirrorRoot, 'CTS', 'StaffFiles',
          'Classroom Technology', 'Dashboard', 'manuals');
      write(p.join(manuals, 'catalog', 'manuals.json'), '{"models":{}}');
      write(p.join(manuals, 'files', 'epson', 'guide.pdf'), 'pdf');
      expect(ShareSync.keepManuals, isTrue);
      final r = await ShareSync.syncNow();
      expect(r.received, 2);
      expect(File(p.join(copyManuals, 'files', 'epson', 'guide.pdf'))
          .readAsStringSync(), 'pdf');

      // Offline, a manual opens from the copy.
      IosShare.offline = true;
      expect(
          sharePath('$ctUnc\\Dashboard\\manuals\\files\\epson\\guide.pdf'),
          p.join(copyManuals, 'files', 'epson', 'guide.pdf'));
      IosShare.offline = false;

      // Changed on the iPad: not sent, and the share keeps its own.
      write(p.join(copyManuals, 'files', 'epson', 'guide.pdf'), 'scribbled',
          minutesAgo: 1);
      final r2 = await ShareSync.syncNow();
      expect(r2.sent, 0);
      expect(File(p.join(manuals, 'files', 'epson', 'guide.pdf'))
          .readAsStringSync(), 'pdf');

      // Turned off: not brought down any more.
      ShareSync.keepManuals = false;
      write(p.join(manuals, 'files', 'epson', 'new.pdf'), 'new');
      await ShareSync.syncNow();
      expect(File(p.join(copyManuals, 'files', 'epson', 'new.pdf')).existsSync(),
          isFalse);
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

    group('discard', () {
      /// The discarded versions kept on the device.
      List<File> backups() {
        final d = Directory(
            p.join(IosShare.mirrorRoot, '.sync', 'discarded'));
        if (!d.existsSync()) return [];
        return d.listSync(recursive: true).whereType<File>().toList();
      }

      test('online: each change takes the share\'s version, held ones too',
          () async {
        write(share('Configurator_Files/costs.json'), jsonEncode({'a': 1}));
        write(share('Configurator_Files/vendors.json'), jsonEncode({'v': 1}));
        await ShareSync.syncNow();

        // Changed here only.
        write(copy('Configurator_Files/costs.json'), jsonEncode({'a': 2}),
            minutesAgo: 2);
        // Changed on both sides: held.
        write(copy('Configurator_Files/vendors.json'), jsonEncode({'v': 2}),
            minutesAgo: 3);
        write(share('Configurator_Files/vendors.json'), jsonEncode({'v': 3}),
            minutesAgo: 1);
        // Made here only.
        write(copy('Configurator_Files/new.json'), '{}', minutesAgo: 2);
        expect((await ShareSync.syncNow(pull: false)).held, hasLength(1));
        // That send took costs.json and new.json up: change them again.
        write(copy('Configurator_Files/costs.json'), jsonEncode({'a': 5}),
            minutesAgo: 0);

        final n = await ShareSync.discardChanges();
        expect(n, 2);
        expect(jsonDecode(File(copy('Configurator_Files/costs.json'))
            .readAsStringSync()), {'a': 2});
        expect(jsonDecode(File(copy('Configurator_Files/vendors.json'))
            .readAsStringSync()), {'v': 3});
        // The share is untouched.
        expect(jsonDecode(File(share('Configurator_Files/costs.json'))
            .readAsStringSync()), {'a': 2});
        expect(jsonDecode(File(share('Configurator_Files/vendors.json'))
            .readAsStringSync()), {'v': 3});
        expect(ShareSync.status.value.held, isEmpty);
        expect(ShareSync.status.value.pending, 0);
        expect(backups(), hasLength(2));

        final after = await ShareSync.syncNow();
        expect(after.sent + after.received, 0);
        expect(after.held, isEmpty);
      });

      test('online: a file made only here goes', () async {
        await ShareSync.syncNow();
        write(copy('Configurator_Files/mine.pdf'), 'x', minutesAgo: 1);
        expect(await ShareSync.discardChanges(), 1);
        expect(File(copy('Configurator_Files/mine.pdf')).existsSync(), isFalse);
        expect(File(share('Configurator_Files/mine.pdf')).existsSync(), isFalse);
        expect(backups().single.readAsStringSync(), 'x');
      });

      test('offline: JSON goes back to the last sync, the rest comes down later',
          () async {
        write(share('Configurator_Files/costs.json'), jsonEncode({'a': 1}));
        write(share('Configurator_Files/plan.pdf'), 'one');
        await ShareSync.syncNow();

        // The share stops answering.
        final away = '$classroomTech-away';
        Directory(classroomTech).renameSync(away);
        expect(await IosShare.checkReachable(), isFalse);
        write(copy('Configurator_Files/costs.json'), jsonEncode({'a': 9}),
            minutesAgo: 1);
        write(copy('Configurator_Files/plan.pdf'), 'mine', minutesAgo: 1);

        expect(await ShareSync.discardChanges(), 2);
        expect(jsonDecode(File(copy('Configurator_Files/costs.json'))
            .readAsStringSync()), {'a': 1});
        expect(File(copy('Configurator_Files/plan.pdf')).existsSync(), isFalse);
        expect(ShareSync.status.value.pending, 0);

        // It answers again: nothing goes up, the PDF comes back down.
        Directory(away).renameSync(classroomTech);
        final r = await ShareSync.syncNow();
        expect(r.sent, 0);
        expect(r.held, isEmpty);
        expect(File(copy('Configurator_Files/plan.pdf')).readAsStringSync(),
            'one');
        expect(jsonDecode(File(share('Configurator_Files/costs.json'))
            .readAsStringSync()), {'a': 1});
      });
    });
  });
}
