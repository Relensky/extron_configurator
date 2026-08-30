import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/online_copy.dart';
import 'package:extron_configurator/online_roundtrip.dart';
import 'package:extron_configurator/xlsx_reader.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// PUBLISH-ON-SAVE MUST NOT WRITE OVER SOMEBODY ELSE'S TYPING.
///
/// The published workbook is not only a report: two of its sheets are a form
/// that a technician on site fills in, and reading those back is a thing
/// somebody here has to remember to do. So publish-on-save had a hole in it
/// the size of the feature — a delivery logged in Excel Online at eight was
/// gone when anybody here pressed Ctrl+S at nine, with no warning to either of
/// them.
///
/// The four things that have to hold. A publish that would destroy work stands
/// down and says what it found. THE SAVE ITSELF STILL HAPPENS, because the job
/// on disk and a spreadsheet in a sync folder are different documents and
/// holding one hostage to the other would be the wrong trade every time. A
/// file a sync client merely touched is not a reason to stop. And somebody who
/// has been shown what is at stake can still say go over it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_overwrite_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String syncFolder() {
    final f = path.join(dir.path, 'OneDrive', 'AV jobs');
    Directory(f).createSync(recursive: true);
    return f;
  }

  /// A job that publishes into [folder] on every save, with one delivery on it
  /// for somebody to edit.
  ({AppStateProvider p, String folder, String projectFile, String deliveryId})
      publishingJob() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    final config = path.join(dir.path, 'bss101_config.json');
    File(config).writeAsStringSync('{"SYSTEM_SETUP":{}}');
    p.addRoomToProject(config);
    final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 18);

    final folder = syncFolder();
    p.setProjectOnlineFolder(folder);
    p.setProjectOnlineAutoPublish(true);
    return (
      p: p,
      folder: folder,
      projectFile: path.join(dir.path, 'bessey.json'),
      deliveryId: row.id,
    );
  }

  String workbookPath(AppStateProvider p, String folder) =>
      path.join(folder, onlineWorkbookName(p.project));

  /// The published sheet, edited the way Excel Online hands it back, and put
  /// where the sync client would have put it.
  ///
  /// The timestamp is set explicitly rather than left to the write: on a
  /// filesystem with second granularity a rewrite inside the same second can
  /// land on the very timestamp the app recorded, and this test would then be
  /// asserting about a coincidence.
  void editThePublishedCopy(
    AppStateProvider p,
    String folder, {
    required void Function(List<List<String>> grid) edit,
  }) {
    final file = File(workbookPath(p, folder));
    final bytes = Uint8List.fromList(file.readAsBytesSync());
    final grid = [
      for (final row in readXlsxSheet(bytes, kEditableDeliveriesSheet)!)
        [...row],
    ];
    edit(grid);
    file.writeAsBytesSync(
      buildXlsx([XlsxSheet(name: kEditableDeliveriesSheet, rows: grid)]),
    );
    file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
  }

  int columnOf(List<List<String>> grid, String header) {
    for (final row in grid) {
      if (row.isNotEmpty && row.first.trim() == kRoundTripIdColumn) {
        return row.indexWhere(
          (c) => c.trim().toLowerCase() == header.toLowerCase(),
        );
      }
    }
    return -1;
  }

  int rowOf(List<List<String>> grid, String id) =>
      grid.indexWhere((r) => r.isNotEmpty && r.first.trim() == id);

  group('the ordinary case is unchanged', () {
    test('a save publishes, and records the timestamp it is answerable for',
        () async {
      final job = publishingJob();

      expect(await job.p.saveProject(to: job.projectFile), '');

      final book = File(workbookPath(job.p, job.folder));
      expect(book.existsSync(), isTrue);
      expect(job.p.onlineHold, isNull, reason: 'nobody had touched it');

      // NOT [onlinePublishedAt]. That is when we published; this is what the
      // FILE says, and the next publish compares against this one because it
      // is the only one a sync client and a spreadsheet program both move.
      expect(job.p.project.onlineFileStamp, isNotNull);
      expect(job.p.project.onlineFileStamp, book.lastModifiedSync());
    });

    test('a second save with nobody in the file publishes again', () async {
      final job = publishingJob();
      await job.p.saveProject(to: job.projectFile);

      job.p.addProjectDelivery(itemName: 'Bracket', qty: 4);
      expect(await job.p.saveProject(), '');

      expect(job.p.onlineHold, isNull);
      final rows = readXlsxTable(
        File(workbookPath(job.p, job.folder)).readAsBytesSync(),
        kEditableDeliveriesSheet,
        headerMarker: kRoundTripIdColumn,
      );
      expect(rows, hasLength(2), reason: 'the new delivery went out');
    });
  });

  group('somebody has been typing in it', () {
    test('the publish stands down, and says what it found', () async {
      final job = publishingJob();
      await job.p.saveProject(to: job.projectFile);

      editThePublishedCopy(job.p, job.folder, edit: (grid) {
        grid[rowOf(grid, job.deliveryId)][columnOf(grid, 'Qty')] = '12';
      });
      final theirBytes =
          File(workbookPath(job.p, job.folder)).readAsBytesSync();

      // The job changes here too, so this save has something of its own to
      // publish - which is exactly the collision being guarded.
      job.p.setProjectField(stakeholder: 'Facilities');
      expect(await job.p.saveProject(), '');

      final hold = job.p.onlineHold;
      expect(hold, isNotNull, reason: 'their typing was found');
      expect(hold!.changes, hasLength(1));
      expect(hold.changes.single.what, contains('Qty 18 -> 12'));

      // AND THE FILE IS UNTOUCHED. Byte for byte: a publish that "mostly"
      // stood down is the same bug wearing a smaller hat.
      expect(
        File(workbookPath(job.p, job.folder)).readAsBytesSync(),
        theirBytes,
      );
    });

    test('the job is still saved - the hold is about the copy, not the file',
        () async {
      final job = publishingJob();
      await job.p.saveProject(to: job.projectFile);

      editThePublishedCopy(job.p, job.folder, edit: (grid) {
        grid[rowOf(grid, job.deliveryId)][columnOf(grid, 'Qty')] = '12';
      });

      job.p.setProjectField(stakeholder: 'Facilities');
      expect(await job.p.saveProject(), '');

      // The save reported success, the dirty flag cleared, and the stakeholder
      // typed a moment ago is in the file on disk. Somebody who pressed Save
      // got a save.
      expect(job.p.projectDirty, isFalse);
      expect(
        File(job.projectFile).readAsStringSync(),
        contains('Facilities'),
      );
    });

    test('told to go over it anyway, it does', () async {
      final job = publishingJob();
      await job.p.saveProject(to: job.projectFile);
      editThePublishedCopy(job.p, job.folder, edit: (grid) {
        grid[rowOf(grid, job.deliveryId)][columnOf(grid, 'Qty')] = '12';
      });

      expect(await job.p.saveProject(overwriteOnlineCopy: true), '');

      expect(job.p.onlineHold, isNull, reason: 'the publish went through');
      final rows = readXlsxTable(
        File(workbookPath(job.p, job.folder)).readAsBytesSync(),
        kEditableDeliveriesSheet,
        headerMarker: kRoundTripIdColumn,
      );
      // The job's own figure, back over theirs - which is what was asked for,
      // in front of a list of what it cost.
      expect(rows.single['qty'], '18');
    });

    test('bringing their changes in first clears the hold and publishes',
        () async {
      final job = publishingJob();
      await job.p.saveProject(to: job.projectFile);
      editThePublishedCopy(job.p, job.folder, edit: (grid) {
        grid[rowOf(grid, job.deliveryId)][columnOf(grid, 'Qty')] = '12';
      });
      await job.p.saveProject();

      // What the box does when somebody presses "Bring the changes in": apply
      // what was held, then save again with the publish let through.
      final hold = job.p.onlineHold!;
      expect(job.p.applyOnlineImport(hold.read), greaterThan(0));
      expect(await job.p.saveProject(overwriteOnlineCopy: true), '');

      expect(job.p.onlineHold, isNull);
      expect(job.p.project.deliveries.single.qty, 12,
          reason: 'their figure is in the job');
      final rows = readXlsxTable(
        File(workbookPath(job.p, job.folder)).readAsBytesSync(),
        kEditableDeliveriesSheet,
        headerMarker: kRoundTripIdColumn,
      );
      expect(rows.single['qty'], '12', reason: 'and back out in the copy');
    });
  });

  group('a moved timestamp is not by itself a reason to stop', () {
    test('a file the sync client only touched still publishes', () async {
      final job = publishingJob();
      await job.p.saveProject(to: job.projectFile);

      // OneDrive re-downloading its own upload: the timestamp moves, the
      // content does not. Stopping here every save would train somebody to
      // press "Overwrite it" without reading, which is worse than not asking.
      File(workbookPath(job.p, job.folder))
          .setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));

      job.p.addProjectDelivery(itemName: 'Bracket', qty: 4);
      expect(await job.p.saveProject(), '');

      expect(job.p.onlineHold, isNull);
      final rows = readXlsxTable(
        File(workbookPath(job.p, job.folder)).readAsBytesSync(),
        kEditableDeliveriesSheet,
        headerMarker: kRoundTripIdColumn,
      );
      expect(rows, hasLength(2), reason: 'the publish went through');
    });

    test('a different workbook under the same name is not our edits to rescue',
        () async {
      final job = publishingJob();
      await job.p.saveProject(to: job.projectFile);

      // Somebody dropped an unrelated spreadsheet in the sync folder. It has
      // no editable sheet on it, so there is nothing to bring back and nothing
      // to protect - and a job that refused to publish forever because of it
      // would be stuck with no way out that this app offers.
      File(workbookPath(job.p, job.folder)).writeAsBytesSync(
        buildXlsx([
          XlsxSheet(name: 'Sheet1', rows: const [
            ['not', 'this', 'job'],
          ]),
        ]),
      );

      expect(await job.p.saveProject(), '');
      expect(job.p.onlineHold, isNull);
      expect(
        readXlsxSheets(File(workbookPath(job.p, job.folder)).readAsBytesSync())
            .containsKey(kEditableDeliveriesSheet),
        isTrue,
        reason: 'the real copy was written back over it',
      );
    });
  });

  group('the timestamp rule itself', () {
    test('what we wrote is not a change; anything else is', () {
      final ours = DateTime(2026, 4, 2, 9, 30);
      final stamp = (file: 'x.xlsx', modified: ours);

      expect(onlineCopyMovedSince(stamp, ourStamp: ours), isFalse);
      expect(
        onlineCopyMovedSince(
          (file: 'x.xlsx', modified: ours.add(const Duration(seconds: 1))),
          ourStamp: ours,
        ),
        isTrue,
      );
      // A sync client that restored an OLDER copy moved the file too, and that
      // copy may hold the very rows this exists to protect.
      expect(
        onlineCopyMovedSince(
          (file: 'x.xlsx', modified: ours.subtract(const Duration(hours: 2))),
          ourStamp: ours,
        ),
        isTrue,
      );
      // Nothing published, nothing to compare.
      expect(onlineCopyMovedSince(null, ourStamp: ours), isFalse);
    });

    test('a job published before the stamp existed falls back, generously', () {
      final published = DateTime(2026, 4, 2, 9, 30);

      // The write finishes after the publish began, always: [OnlineCopyResult]
      // stamps itself before the bytes go down. Reading that as somebody's
      // edit would hold every publish on a job saved by the old version.
      expect(
        onlineCopyMovedSince(
          (file: 'x.xlsx', modified: published.add(const Duration(seconds: 20))),
          publishedAt: published,
        ),
        isFalse,
      );
      expect(
        onlineCopyMovedSince(
          (file: 'x.xlsx', modified: published.add(const Duration(hours: 3))),
          publishedAt: published,
        ),
        isTrue,
      );
    });
  });
}
