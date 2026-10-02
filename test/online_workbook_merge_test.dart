import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/google_sheets_live.dart';
import 'package:extron_configurator/online_copy.dart';
import 'package:extron_configurator/online_sheet_merge.dart';

/// The .xlsx in the synced folder is checked tab by tab and cell by cell, the
/// same as the live Google Sheet - see online_sheet_merge.dart.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_wb_merge_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A job publishing to a sync folder on every save, saved once.
  Future<({AppStateProvider p, String project, String workbook})>
      published() async {
    final folder = path.join(dir.path, 'OneDrive');
    Directory(folder).createSync();
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    final config = path.join(dir.path, 'bss101_config.json');
    File(config).writeAsStringSync('{"SYSTEM_SETUP":{}}');
    p.addRoomToProject(config);
    p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
    p.setProjectOnlineFolder(folder);
    p.setProjectOnlineToFolder(true);
    p.setProjectOnlineAutoPublish(true);
    final project = path.join(dir.path, 'bessey.json');
    expect(await p.saveProject(to: project), '');
    return (
      p: p,
      project: project,
      workbook: path.join(folder, onlineWorkbookName(p.project)),
    );
  }

  /// Types [replacement] over the first text cell of a tab that is not read
  /// back, the way Excel Online would leave the file. Returns the tab and
  /// what the cell said.
  ({String tab, String was}) typeIntoReportTab(String workbook) {
    final archive = ZipDecoder().decodeBytes(File(workbook).readAsBytesSync());
    String text(String name) => utf8.decode(
          archive.files.firstWhere((f) => f.name == name).content as List<int>,
        );
    final rels = {
      for (final m in RegExp(r'Id="([^"]+)"[^>]*Target="([^"]+)"')
          .allMatches(text('xl/_rels/workbook.xml.rels')))
        m.group(1)!: m.group(2)!,
    };
    for (final m in RegExp(r'<sheet name="([^"]+)"[^>]*r:id="([^"]+)"')
        .allMatches(text('xl/workbook.xml'))) {
      final tab = m.group(1)!;
      if (kLiveReadBackSheets.contains(tab)) continue;
      final part = 'xl/${rels[m.group(2)]!}';
      final xml = text(part);
      final cell =
          RegExp(r'<t xml:space="preserve">([^<]+)</t>').firstMatch(xml);
      if (cell == null) continue;
      final edited = xml.replaceFirst(
        cell.group(0)!,
        '<t xml:space="preserve">TYPED BY HAND</t>',
      );
      final out = Archive();
      for (final f in archive.files) {
        final bytes = f.name == part
            ? utf8.encode(edited)
            : (f.content as List<int>);
        out.addFile(ArchiveFile(f.name, bytes.length, bytes));
      }
      File(workbook)
        ..writeAsBytesSync(ZipEncoder().encode(out))
        // Somebody else's save, later than ours.
        ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
      return (tab: tab, was: cell.group(1)!);
    }
    throw StateError('the workbook has no report tab with text in it');
  }

  test('a publish keeps what every tab of the workbook said', () async {
    final (:p, :project, :workbook) = await published();
    final baseline = readSheetBaseline(project, workbook: true);
    expect(baseline, isNotNull);
    expect(baseline!.keys.length, greaterThan(kLiveReadBackSheets.length));
    // The workbook unchanged reads the same as what was kept.
    final review = p.reviewOnlineWorkbook(File(workbook).readAsBytesSync());
    expect(listedOnlyChanges(review.changes), isEmpty);
  });

  test('typing in a room tab holds the save\'s publish and is listed',
      () async {
    final (:p, :project, :workbook) = await published();
    final typed = typeIntoReportTab(workbook);
    final before = File(workbook).readAsBytesSync();

    await p.saveProject();

    // Not written over...
    expect(File(workbook).readAsBytesSync(), before);
    // ...and listed: where, and what it said and says.
    final change = p.onlineHold!.changes.single;
    expect(change.kind, kSheetEditKind);
    expect(change.name, startsWith('${typed.tab}, row '));
    expect(change.what, contains('-> "TYPED BY HAND"'));
    expect(p.onlineHold!.sheet, isFalse);
  });

  test('a pull of the workbook lists it too', () async {
    final (:p, project: _, :workbook) = await published();
    typeIntoReportTab(workbook);

    final review = p.reviewOnlineWorkbook(
      Uint8List.fromList(File(workbook).readAsBytesSync()),
    );

    expect(listedOnlyChanges(review.changes).single.what,
        contains('TYPED BY HAND'));
  });

  test('a formula is compared as a formula; typed over, it is an edit', () {
    final changes = sheetEdits({
      'Room': [
        ['Item', 'Qty', 'Each', 'Total'],
        ['Projector', '2', '100', kFormulaCell],
      ],
    }, {
      'Room': [
        ['Item', 'Qty', 'Each', 'Total'],
        ['Projector', '2', '100', '250'],
      ],
    });
    expect(changes.single.what, 'Total: "(formula)" -> "250"');
  });
}
