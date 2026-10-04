import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/google_sheets_export.dart';
import 'package:extron_configurator/google_sheets_live.dart';
import 'package:extron_configurator/online_copy.dart';
import 'package:extron_configurator/online_roundtrip.dart';
import 'package:extron_configurator/online_sheet_merge.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// Google Sheets, in memory: one spreadsheet, its tabs, and what each cell
/// would show.
class _FakeGoogle {
  final tabs = <String, ({int id, List<List<String>> grid})>{};
  int created = 0;
  int batches = 0;
  /// Cells written, per tab.
  final written = <String, int>{};
  bool down = false;

  GoogleLiveSheet get client => GoogleLiveSheet(_send);

  String _text(Map cell) {
    final v = cell['userEnteredValue'];
    if (v is! Map) return '';
    return '${v['stringValue'] ?? v['numberValue'] ?? v['formulaValue'] ?? ''}';
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri,
    Object? body,
  ) async {
    if (down) throw const GoogleSheetsException('Google is unreachable');
    if (method == 'POST' && uri.path.endsWith('/spreadsheets')) {
      created++;
      final first = (body as Map)['sheets'][0]['properties']['title'];
      tabs['$first'] = (id: 0, grid: []);
      return {'spreadsheetId': 'sheet-1'};
    }
    if (uri.path.endsWith(':batchUpdate')) {
      batches++;
      for (final Map request in (body as Map)['requests']) {
        final add = request['addSheet'];
        if (add != null) {
          final p = add['properties'];
          tabs['${p['title']}'] = (id: p['sheetId'] as int, grid: []);
        }
        final cells = request['updateCells'];
        if (cells != null) {
          final id = (cells['range'] ?? cells['start'])['sheetId'];
          final name = tabs.keys.firstWhere((k) => tabs[k]!.id == id);
          // A whole-tab range clears it; a start writes cells in place.
          final grid = cells['range'] != null
              ? <List<String>>[]
              : [for (final row in tabs[name]!.grid) List.of(row)];
          final start = cells['start'] as Map?;
          final r0 = (start?['rowIndex'] as int?) ?? 0;
          final c0 = (start?['columnIndex'] as int?) ?? 0;
          final rows = (cells['rows'] as List?) ?? const [];
          for (var r = 0; r < rows.length; r++) {
            final values = (rows[r] as Map)['values'] as List;
            while (grid.length <= r0 + r) {
              grid.add([]);
            }
            final row = grid[r0 + r];
            for (var c = 0; c < values.length; c++) {
              while (row.length <= c0 + c) {
                row.add('');
              }
              row[c0 + c] = _text(values[c] as Map);
              written[name] = (written[name] ?? 0) + 1;
            }
          }
          // Trailing blanks trimmed, the way Google returns a grid.
          for (final row in grid) {
            while (row.isNotEmpty && row.last.isEmpty) {
              row.removeLast();
            }
          }
          while (grid.isNotEmpty && grid.last.isEmpty) {
            grid.removeLast();
          }
          tabs[name] = (id: id as int, grid: grid);
        }
      }
      return {};
    }
    if (uri.path.endsWith('values:batchGet')) {
      final names = [
        for (final r in uri.queryParametersAll['ranges']!)
          r.substring(1, r.length - 1),
      ];
      return {
        'valueRanges': [
          for (final n in names) {'values': tabs[n]!.grid},
        ],
      };
    }
    return {
      'sheets': [
        for (final e in tabs.entries)
          {
            'properties': {
              'title': e.key,
              'sheetId': e.value.id,
              'gridProperties': {'rowCount': 1000, 'columnCount': 26},
            },
          },
      ],
    };
  }
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_live_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String syncFolder() {
    final folder = path.join(dir.path, 'OneDrive');
    Directory(folder).createSync();
    return folder;
  }

  /// A job with one delivery on it, publishing to the fake Sheet.
  ({AppStateProvider p, _FakeGoogle google}) job() {
    final google = _FakeGoogle();
    final p = AppStateProvider(autoLoadSettings: false)
      ..liveSheetOverride = google.client;
    p.newProject(name: 'Bessey Hall');
    final config = path.join(dir.path, 'bss101_config.json');
    File(config).writeAsStringSync('{"SYSTEM_SETUP":{}}');
    p.addRoomToProject(config);
    p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
    p.setProjectOnlineToSheet(true);
    return (p: p, google: google);
  }

  group('the client file Google exports', () {
    test('a Desktop app client gives its id and secret', () {
      final c = parseGoogleClientJson(
        '{"installed":{"client_id":"abc.apps.googleusercontent.com",'
        '"client_secret":"s3","redirect_uris":["http://localhost"]}}',
      );
      expect(c?.clientId, 'abc.apps.googleusercontent.com');
      expect(c?.clientSecret, 's3');
      expect(c?.desktop, isTrue);
    });

    test('a web client is read but flagged', () {
      final c = parseGoogleClientJson('{"web":{"client_id":"w","client_secret":"x"}}');
      expect(c?.clientId, 'w');
      expect(c?.desktop, isFalse);
    });

    test('anything else is refused', () {
      expect(parseGoogleClientJson('not json'), isNull);
      expect(parseGoogleClientJson('{"rooms":[]}'), isNull);
    });

    test('loading one fills the settings in', () async {
      final p = AppStateProvider(autoLoadSettings: false);
      final file = File(path.join(dir.path, 'client_secret.json'))
        ..writeAsStringSync(
          '{"installed":{"client_id":"abc","client_secret":"s3"}}',
        );
      expect(await p.loadGoogleClientFile(file.path), '');
      expect(p.googleClientId, 'abc');
      expect(p.googleClientSecret, 's3');
    });
  });

  group('a sheet as requests', () {
    test('a pasted link gives the id', () {
      expect(
        liveSheetIdFrom('https://docs.google.com/spreadsheets/d/1AbC_-9/edit#gid=0'),
        '1AbC_-9',
      );
      expect(liveSheetIdFrom(' 1AbC_-9 '), '1AbC_-9');
    });

    test('text that looks like a formula stays text', () {
      final cell = liveCell('=SUM(A1)', XlsxRowStyle.normal, '', const {});
      expect(cell['userEnteredValue'], {'stringValue': '=SUM(A1)'});
    });

    test('a link to another tab goes by that tab\'s id', () {
      final cell = liveCell(
        const XlsxLink(text: 'Summary', sheet: 'Summary'),
        XlsxRowStyle.normal,
        '',
        const {'Summary': 7},
      );
      expect(
        cell['userEnteredValue']['formulaValue'],
        '=HYPERLINK("#gid=7&range=A1","Summary")',
      );
    });

    test('money is a number with a currency format', () {
      final cell = liveCell(
        const XlsxMoney(value: 12.5, text: r'$12.50'),
        XlsxRowStyle.normal,
        '',
        const {},
      );
      expect(cell['userEnteredValue'], {'numberValue': 12.5});
      expect(cell['userEnteredFormat']['numberFormat']['type'], 'CURRENCY');
    });

    test('the grid grows and never shrinks, and a cut merge drops the freeze',
        () {
      final requests = liveSheetRequests(
        XlsxSheet(
          name: 'T',
          rows: [
            ['a', '', ''],
          ],
          merges: const ['A1:C1'],
          freezeColumns: 1,
        ),
        sheetId: 3,
        sheetIds: const {'T': 3},
        haveRows: 1000,
        haveColumns: 2,
      );
      final grid = requests[2]['updateSheetProperties']['properties']
          ['gridProperties'];
      expect(grid['rowCount'], 1000);
      expect(grid['columnCount'], 4);
      expect(grid['frozenColumnCount'], 0);
      expect(requests.where((r) => r.containsKey('mergeCells')), hasLength(1));
    });
  });

  group('publishing to the Sheet', () {
    test('makes the Sheet once and writes the same one after that', () async {
      final (:p, :google) = job();

      final first = await p.publishOnlineCopy();
      expect(first.failed, isEmpty);
      expect(first.written, [kOnlineSheetLabel]);
      expect(p.project.onlineSheetId, 'sheet-1');
      expect(p.project.onlinePublishedAt, isNotNull);
      expect(google.tabs.keys, contains(kEditableDeliveriesSheet));

      await p.publishOnlineCopy();
      expect(google.created, 1);
    });

    test('a second publish writes only the cells that changed', () async {
      final (:p, :google) = job();
      await p.publishOnlineCopy();

      // Nothing changed: only the History tab, which logs the publish and
      // the time it was made, is written to.
      google.written.clear();
      await p.publishOnlineCopy();
      expect(google.written.keys.toSet().difference({'History'}), isEmpty);

      // One quantity changed: that cell on the deliveries tab, not the tab.
      p.updateProjectDelivery(p.project.deliveries.single.copyWith(qty: 20));
      google.written.clear();
      await p.publishOnlineCopy();
      expect(google.written[kEditableDeliveriesSheet], 1);
    });

    test('goes to the folder and the Sheet in one publish', () async {
      final (:p, :google) = job();
      final folder = syncFolder();

      final result = await p.publishOnlineCopy(folder: folder);

      expect(result.failed, isEmpty);
      expect(result.written, [
        onlineWorkbookName(p.project),
        onlineProjectFileName(p.project),
        kOnlineSheetLabel,
      ]);
      expect(google.batches, greaterThan(0));
    });

    test('Google being unreachable does not stop the folder', () async {
      final (:p, :google) = job();
      final folder = syncFolder();
      google.down = true;

      final result = await p.publishOnlineCopy(folder: folder);

      expect(result.written, hasLength(2));
      expect(result.failed.single, startsWith(kOnlineSheetLabel));
    });

    test('the folder switched off leaves the Sheet alone to publish',
        () async {
      final (:p, google: _) = job();
      final folder = syncFolder();
      p.setProjectOnlineFolder(folder);
      p.setProjectOnlineToFolder(false);

      final result = await p.publishOnlineCopy();

      expect(result.written, [kOnlineSheetLabel]);
      expect(Directory(folder).listSync(), isEmpty);
    });
  });

  group('not writing over what was typed in the Sheet', () {
    test('an untouched Sheet is published over on save', () async {
      final (:p, :google) = job();
      p.setProjectOnlineAutoPublish(true);
      await p.saveProject(to: path.join(dir.path, 'bessey.json'));
      final before = google.batches;

      await p.saveProject();

      expect(p.onlineHold, isNull);
      expect(google.batches, greaterThan(before));
    });

    test('a quantity typed in the Sheet holds the publish and comes back',
        () async {
      final (:p, :google) = job();
      p.setProjectOnlineAutoPublish(true);
      await p.saveProject(to: path.join(dir.path, 'bessey.json'));

      final grid = google.tabs[kEditableDeliveriesSheet]!.grid;
      final header = grid.indexWhere(
        (r) => r.isNotEmpty && r.first == kRoundTripIdColumn,
      );
      grid[header + 1][grid[header].indexOf('Qty')] = '20';
      final before = google.batches;

      await p.saveProject();

      expect(p.onlineHold?.sheet, isTrue);
      expect(p.onlineHold!.changes.single.what, contains('18 -> 20'));
      expect(google.batches, before);

      p.applyOnlineImport(p.onlineHold!.read);
      expect(p.project.deliveries.single.qty, 20);
    });
  });

  // The tabs the app writes and cannot read back - a room's listing, the
  // summary. Typing there used to be found by no pull and written over by the
  // next save. See online_sheet_merge.dart.
  group('typing in a tab that is not read back', () {
    /// Some tab other than the three read-back ones, with a cell to change.
    ({String tab, int row, int col}) reportCell(_FakeGoogle google) {
      for (final e in google.tabs.entries) {
        if (kLiveReadBackSheets.contains(e.key)) continue;
        for (var r = 0; r < e.value.grid.length; r++) {
          final c = e.value.grid[r].indexWhere((v) => v.isNotEmpty);
          if (c >= 0) return (tab: e.key, row: r, col: c);
        }
      }
      throw StateError('the job published no report tab');
    }

    test('a publish keeps what every tab said, beside the project', () async {
      final (:p, :google) = job();
      p.setProjectOnlineAutoPublish(true);
      final file = path.join(dir.path, 'bessey.json');
      await p.saveProject(to: file);

      final baseline = readSheetBaseline(file);
      expect(baseline, isNotNull);
      expect(baseline!.keys, containsAll(google.tabs.keys));
    });

    test('holds the publish, and is listed rather than applied', () async {
      final (:p, :google) = job();
      p.setProjectOnlineAutoPublish(true);
      await p.saveProject(to: path.join(dir.path, 'bessey.json'));

      final cell = reportCell(google);
      final was = google.tabs[cell.tab]!.grid[cell.row][cell.col];
      google.tabs[cell.tab]!.grid[cell.row][cell.col] = 'TYPED BY HAND';
      final before = google.batches;

      await p.saveProject();

      // Not written over...
      expect(google.batches, before);
      expect(google.tabs[cell.tab]!.grid[cell.row][cell.col], 'TYPED BY HAND');
      // ...and listed, saying where and what.
      final change = p.onlineHold!.changes.single;
      expect(change.kind, kSheetEditKind);
      expect(change.name, startsWith('${cell.tab}, row ${cell.row + 1}'));
      expect(change.what, contains('"$was" -> "TYPED BY HAND"'));
      // Nothing for an import to act on: it is the list that keeps it.
      expect(appliedChanges(p.onlineHold!.changes), isEmpty);
      expect(p.applyOnlineImport(p.onlineHold!.read), 0);
    });

    test('a pull lists it too, with what can be brought in', () async {
      final (:p, :google) = job();
      p.setProjectOnlineAutoPublish(true);
      await p.saveProject(to: path.join(dir.path, 'bessey.json'));

      final cell = reportCell(google);
      google.tabs[cell.tab]!.grid[cell.row][cell.col] = 'TYPED BY HAND';
      final grid = google.tabs[kEditableDeliveriesSheet]!.grid;
      final header = grid.indexWhere(
        (r) => r.isNotEmpty && r.first == kRoundTripIdColumn,
      );
      grid[header + 1][grid[header].indexOf('Qty')] = '20';

      final review = await p.reviewLiveSheet();

      expect(appliedChanges(review.changes).single.what, contains('18 -> 20'));
      expect(listedOnlyChanges(review.changes).single.what,
          contains('TYPED BY HAND'));
    });

    test('once it has been published over, it is not reported again',
        () async {
      final (:p, :google) = job();
      p.setProjectOnlineAutoPublish(true);
      await p.saveProject(to: path.join(dir.path, 'bessey.json'));
      final cell = reportCell(google);
      google.tabs[cell.tab]!.grid[cell.row][cell.col] = 'TYPED BY HAND';
      await p.saveProject();
      expect(p.onlineHold, isNotNull);

      await p.saveProject(overwriteOnlineCopy: true);
      await p.saveProject();

      expect(p.onlineHold, isNull);
    });
  });

  group('comparing two readings of a tab', () {
    test('a changed cell is named by its heading; a number written another '
        'way is not a change', () {
      final changes = sheetEdits({
        'BSS 101': [
          ['BSS 101 - parts'],
          ['Item', 'Model', 'Qty', 'Price'],
          ['Projector', 'PT-1', '2', '12.5'],
          ['Screen', 'S-9', '1', '300'],
        ],
      }, {
        'BSS 101': [
          ['BSS 101 - parts'],
          ['Item', 'Model', 'Qty', 'Price'],
          ['Projector', 'PT-1', '3', '12.50'],
          ['Screen', 'S-9', '1', '300', ''],
        ],
      });
      expect(changes.single.name, 'BSS 101, row 3 (Projector)');
      expect(changes.single.what, 'Qty: "2" -> "3"');
    });

    test('added and removed rows are listed whole; skipped and hand-made '
        'tabs are left out', () {
      final changes = sheetEdits({
        'Room': [
          ['a', 'b'],
          ['c', 'd'],
        ],
        'Deliveries': [
          ['x'],
        ],
      }, {
        'Room': [
          ['a', 'b'],
          ['new', 'row'],
          ['c', 'd'],
        ],
        'Deliveries': [
          ['y'],
        ],
        'My notes': [
          ['typed by hand'],
        ],
      }, skip: {'Deliveries'});
      expect(changes.single.what, 'row added or changed to: new | row');
    });

    test('a tab that has gone is said to have gone', () {
      final changes = sheetEdits({
        'Room': [
          ['a'],
        ],
      }, {});
      expect(changes.single.what, contains('deleted or renamed'));
    });
  });
}
