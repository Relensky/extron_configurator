import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/online_copy.dart';
import 'package:extron_configurator/online_roundtrip.dart';
import 'package:extron_configurator/xlsx_reader.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// THE SHEET THAT COMES BACK.
///
/// The published copy is a spreadsheet other people can open, and the moment
/// somebody can open it they type in it. Two of its sheets are a form rather
/// than a report — a stable shape with a row id on every line — so what a
/// technician typed on a phone in a corridor arrives back in the job.
///
/// The failures worth guarding are the ones that would cost trust in a single
/// afternoon. An import that DELETED a record because somebody filtered the
/// sheet. An import that guessed at a cell it could not read and wrote the
/// guess into the job. An edit that arrived with no trace of where it came
/// from. And a re-import of an untouched copy quietly logging forty changes
/// that were not changes.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_import_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    final file = path.join(dir.path, 'bss101_config.json');
    File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
    p.addRoomToProject(file);
    return p;
  }

  String folder() {
    final f = path.join(dir.path, 'OneDrive');
    Directory(f).createSync(recursive: true);
    return f;
  }

  /// The published workbook's bytes, as they land in the sync folder.
  Future<Uint8List> publish(AppStateProvider p) async {
    final f = folder();
    await p.publishOnlineCopy(folder: f, includeProjectFile: false);
    return File(path.join(f, onlineWorkbookName(p.project))).readAsBytes();
  }

  /// The editable sheet, edited the way a spreadsheet program hands it back:
  /// re-saved with a shared-string table rather than the inline strings this
  /// app writes. [edit] is called with the sheet's grid to change.
  Uint8List reSaved(
    Uint8List bytes, {
    required void Function(List<List<String>> grid) edit,
    String sheet = kEditableDeliveriesSheet,
  }) {
    final grid = [
      for (final row in readXlsxSheet(bytes, sheet)!) [...row],
    ];
    edit(grid);
    // Written as a fresh book with only that sheet on it: an import has to
    // find its sheet by NAME, not by position, because Excel Online and
    // Google Sheets both reorder and re-lay-out what they save.
    return buildXlsx([XlsxSheet(name: sheet, rows: grid)]);
  }

  /// Where a column is on the editable sheet, by its header.
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

  /// The row on the editable sheet carrying [id].
  int rowOf(List<List<String>> grid, String id) =>
      grid.indexWhere((r) => r.isNotEmpty && r.first.trim() == id);

  group('the published copy carries the form', () {
    test('both editable sheets are on it, and only on it', () async {
      final p = job();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      final bytes = await publish(p);

      final sheets = readXlsxSheets(bytes);
      expect(sheets.containsKey(kEditableDeliveriesSheet), isTrue);
      expect(sheets.containsKey(kEditablePosSheet), isTrue);

      // The row id is the join, and it is the first column - see
      // online_roundtrip.dart.
      final rows = readXlsxTable(
        bytes,
        kEditableDeliveriesSheet,
        headerMarker: kRoundTripIdColumn,
      );
      expect(rows.single['row id'], p.project.deliveries.single.id);
      expect(rows.single['what'], 'Wall plate');
      expect(rows.single['qty'], '18');
      // Dates as text, because a date cell is a serial number the two
      // spreadsheet programs disagree about.
      expect(rows.single['arrived'], matches(r'^\d{4}-\d{2}-\d{2}$'));
    });
  });

  group('reading the edits back', () {
    test('a changed cell comes back as one change, named', () async {
      final p = job();
      final row = p.addProjectDelivery(
        itemName: 'Wall plate',
        qty: 18,
        deliveredOn: DateTime(2026, 4, 2),
      );
      final edited = reSaved(await publish(p), edit: (grid) {
        final r = rowOf(grid, row.id);
        grid[r][columnOf(grid, 'Qty')] = '12';
        grid[r][columnOf(grid, 'Where is it')] = 'In storage';
        grid[r][columnOf(grid, 'Delivered to / held at')] = 'Bessey basement';
      });

      final review = p.reviewOnlineImport(edited);
      expect(review.read.problems, isEmpty);
      expect(review.changes, hasLength(1));
      expect(review.changes.single.what, contains('Qty 18 -> 12'));
      expect(review.changes.single.what, contains('Delivered -> In storage'));

      // NOTHING IS WRITTEN BY LOOKING.
      expect(p.project.deliveryById(row.id)!.qty, 18);

      expect(p.applyOnlineImport(review.read), 1);
      final after = p.project.deliveryById(row.id)!;
      expect(after.qty, 12);
      expect(after.state, DeliveryState.stored);
      expect(after.location, 'Bessey basement');

      // AND IT SAYS WHERE IT CAME FROM. "Who changed this to 12" is the first
      // question asked of a figure that arrived from somewhere else.
      expect(
        p.project.history.where(
          (h) => h.summary.contains('from the online copy'),
        ),
        isNotEmpty,
      );
    });

    test('an untouched copy is no changes at all', () async {
      final p = job();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      p.addProjectPo(number: 'PO-1188', issuedOn: DateTime(2026, 3, 4));
      final bytes = await publish(p);

      final review = p.reviewOnlineImport(bytes);
      expect(review.changes, isEmpty, reason: 'nothing was edited');
      expect(p.applyOnlineImport(review.read), 0);
      expect(
        p.project.history.where(
          (h) => h.summary.contains('from the online copy'),
        ),
        isEmpty,
      );
    });

    test('a line with no row id is something new that arrived', () async {
      final p = job();
      final edited = reSaved(await publish(p), edit: (grid) {
        grid.add([
          '', // no row id: this is a new delivery
          'HDMI adapters',
          '4',
          kOneOffText,
          '2026-04-22',
          'Delivered',
          'Bessey loading dock',
          '',
          '',
          'bought at the counter, receipt in the folder',
        ]);
      });

      final review = p.reviewOnlineImport(edited);
      expect(review.changes.single.what, startsWith('added'));

      expect(p.applyOnlineImport(review.read), 1);
      final row = p.project.deliveries.single;
      expect(row.itemName, 'HDMI adapters');
      expect(row.qty, 4);
      expect(row.oneOff, isTrue, reason: 'it says one-off in Bought on');
      expect(row.poNumber, '');
      expect(row.deliveredOn, DateTime(2026, 4, 22));
      expect(row.location, 'Bessey loading dock');
      // The note column is a note, signed, not a field.
      expect(row.notes.single.text, contains('receipt in the folder'));
    });

    test('a row deleted from the sheet is NOT deleted from the job', () async {
      final p = job();
      final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      final edited = reSaved(await publish(p), edit: (grid) {
        grid.removeAt(rowOf(grid, row.id));
      });

      final review = p.reviewOnlineImport(edited);
      p.applyOnlineImport(review.read);

      // Somebody filtered the sheet, sorted it, or never scrolled to it.
      // Removing things stays a decision made in the app, in front of the
      // record being removed.
      expect(p.project.deliveryById(row.id), isNotNull);
      expect(p.project.deliveries, hasLength(1));
    });

    test('a cell it cannot read is reported, not guessed at', () async {
      final p = job();
      final row = p.addProjectDelivery(
        itemName: 'Wall plate',
        qty: 18,
        deliveredOn: DateTime(2026, 4, 2),
      );
      final edited = reSaved(await publish(p), edit: (grid) {
        final r = rowOf(grid, row.id);
        grid[r][columnOf(grid, 'Arrived')] = 'next Tuesday';
        grid[r][columnOf(grid, 'Qty')] = 'a dozen';
        grid[r][columnOf(grid, 'Where is it')] = 'somewhere';
        grid[r][columnOf(grid, 'Room')] = 'BSS 999';
      });

      final review = p.reviewOnlineImport(edited);
      expect(review.read.problems, hasLength(4));
      expect(review.read.problems.join(), contains('next Tuesday'));
      expect(review.read.problems.join(), contains('BSS 999'));

      p.applyOnlineImport(review.read);
      final after = p.project.deliveryById(row.id)!;
      // Every unreadable cell left the record alone.
      expect(after.deliveredOn, DateTime(2026, 4, 2));
      expect(after.qty, 18);
      expect(after.state, DeliveryState.delivered);
    });

    test('a row id the job has never heard of is skipped, and says so',
        () async {
      final p = job();
      final edited = reSaved(await publish(p), edit: (grid) {
        grid.add(['del99', 'A ghost', '1', '', '', 'Delivered', '', '', '', '']);
      });

      final review = p.reviewOnlineImport(edited);
      expect(review.read.problems.single, contains('del99'));
      expect(review.changes, isEmpty);
      expect(p.applyOnlineImport(review.read), 0);
      expect(p.project.deliveries, isEmpty);
    });

    test('a PO edited online comes back, and a new one joins the job',
        () async {
      final p = job();
      final po = p.addProjectPo(number: 'PO-1188');
      final edited = reSaved(
        await publish(p),
        sheet: kEditablePosSheet,
        edit: (grid) {
          final r = rowOf(grid, po.id);
          grid[r][columnOf(grid, 'Raised')] = '2026-03-04';
          grid[r][columnOf(grid, 'Raised for')] = '4000';
          grid[r][columnOf(grid, kRoundTripNoteColumn)] =
              'acknowledged, 6 week lead';
          grid.add(['', 'PO-1200', 'Extron Direct', '2026-03-11', '', '', '']);
        },
      );

      final review = p.reviewOnlineImport(edited);
      expect(p.applyOnlineImport(review.read), greaterThan(0));

      final back = p.project.poById(po.id)!;
      expect(back.issuedOn, DateTime(2026, 3, 4));
      expect(back.amount, 4000);
      expect(back.notes.single.text, 'acknowledged, 6 week lead');
      expect(p.project.poByNumber('PO-1200')?.issuedOn, DateTime(2026, 3, 11));
    });

    test('the wrong file is said to be the wrong file', () {
      final p = job();
      final notAWorkbook = buildXlsx([
        XlsxSheet(name: 'Sheet1', rows: [
          ['nothing', 'to do with this'],
        ]),
      ]);

      final review = p.reviewOnlineImport(notAWorkbook);
      expect(review.read.wrongFile, isTrue);
      expect(review.changes, isEmpty);
    });
  });

  group('updating it on every save', () {
    test('a save rewrites the copy, and leaves the job saved', () async {
      final p = job();
      final f = folder();
      final projectFile = path.join(dir.path, 'bss_project.json');

      await p.publishOnlineCopy(folder: f);
      p.setProjectOnlineAutoPublish(true);
      expect(p.project.onlineAutoPublish, isTrue);

      final workbook = File(path.join(f, onlineWorkbookName(p.project)));
      workbook.deleteSync();

      expect(await p.saveProject(to: projectFile), '');
      expect(workbook.existsSync(), isTrue, reason: 'the save republished it');
      // AND THE JOB IS SAVED. Publishing after the write would have left it
      // dirty the instant it was saved, every time.
      expect(p.projectDirty, isFalse);
      // The stamp went into the file, not just into memory.
      final saved = await BuildingProject.load(projectFile);
      expect(saved.onlinePublishedAt, isNotNull);
      expect(saved.onlineAutoPublish, isTrue);
    });

    test('it cannot be switched on with nowhere to write', () {
      final p = job();
      p.setProjectOnlineAutoPublish(true);
      expect(p.project.onlineAutoPublish, isFalse);

      // And clearing the folder takes it back off rather than leaving a switch
      // that reads as on while doing nothing.
      p.setProjectOnlineFolder(folder());
      p.setProjectOnlineAutoPublish(true);
      expect(p.project.onlineAutoPublish, isTrue);
      p.setProjectOnlineFolder('');
      expect(p.project.onlineAutoPublish, isFalse);
    });
  });
}
