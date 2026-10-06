import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/online_room_edits.dart';
import 'package:extron_configurator/online_sheet_merge.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_workbook.dart';
import 'package:extron_configurator/save_actions.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// A count changed on a room's tab in the published copy comes back into the
/// room's estimate on a pull, and every other figure in the copy already
/// follows it.
void main() {
  late Directory dir;
  late AppStateProvider provider;
  late String projectFile;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('room_edits_');
    provider = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = Directory.current.path;
    await provider.loadUiSchema();
    await provider.loadKeyMap();
    await provider.loadAvDeviceLibrary();
    provider.newProject(name: 'Refresh');
    provider.addProjectManualRoomList(
      'LANG 300\t2 Projector 1 Cam 1 Mic\tCentral\t31671\n'
      '\n'
      'HOLT 171\t2 Projector\tCentral\t5000',
      groupsArePriorities: true,
    );
    projectFile = path.join(dir.path, 'Refresh_project.json');
    expect(await provider.saveProject(to: projectFile), isEmpty);
    final built = await buildLineItemRooms(
      provider,
      provider.project.manualRooms.take(2).toList(),
      dir.path,
    );
    expect(built.built, ['LANG 300', 'HOLT 171']);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProjectEstimate price() => computeProjectEstimate(
    project: provider.project,
    projectPath: projectFile,
    library: provider.avDeviceLibrary,
  );

  /// The published copy's tabs, as the pull reads them.
  Map<String, List<List<String>>> publish(ProjectEstimate e) => workbookGrids(
    buildXlsx(buildProjectWorkbookSheets(estimate: e, editable: true)),
  );

  /// The row of [grid] carrying [id] in its Row id column, and where its Qty
  /// is.
  (int, int) rowOf(List<List<String>> grid, String id) {
    var qty = -1, idCol = -1;
    for (var r = 0; r < grid.length; r++) {
      final row = grid[r];
      if (row.contains(kRoomRowIdColumn) && row.contains('Qty')) {
        qty = row.indexOf('Qty');
        idCol = row.indexOf(kRoomRowIdColumn);
        continue;
      }
      if (idCol >= 0 && idCol < row.length && row[idCol] == id) {
        return (r, qty);
      }
    }
    throw StateError('no row for $id');
  }

  test('a room tab carries a row id on every line, and its Qty drives the '
      'line, All Items and Core Components', () {
    final e = price();
    final sheets = buildProjectWorkbookSheets(estimate: e, editable: true);
    final tabs = projectRoomTabNames(e);
    final holt = e.rooms.firstWhere((r) => r.name == 'HOLT 171');
    final tab = sheets.firstWhere((s) => s.name == tabs[holt.ref.id]);
    final line = holt.estimate!.equipment.first;
    final row = tab.rows.firstWhere((r) => r.contains(line.key));
    expect(row.whereType<XlsxFormula>(), isNotEmpty);

    final allItems = sheets.firstWhere((s) => s.name == kProjectAllItemsSheet);
    expect(
      allItems.rows.expand((r) => r).whereType<XlsxNumberFormula>().where(
        (f) => f.formula.contains(tab.name),
      ),
      isNotEmpty,
    );
  });

  test('a changed count and a deleted row come back into the rooms', () async {
    final e = price();
    final tabs = projectRoomTabNames(e);
    final grids = publish(e);
    final holt = e.rooms.firstWhere((r) => r.name == 'HOLT 171');
    final lang = e.rooms.firstWhere((r) => r.name == 'LANG 300');
    final holtTab = tabs[holt.ref.id]!;
    final langTab = tabs[lang.ref.id]!;

    // HOLT 171: one more of its first line.
    final first = holt.estimate!.equipment.first;
    final (r1, q1) = rowOf(grids[holtTab]!, first.key);
    grids[holtTab]![r1][q1] = '${(first.qty + 1).round()}';
    // LANG 300: a line deleted outright.
    final gone = lang.estimate!.equipment.last;
    final (r2, _) = rowOf(grids[langTab]!, gone.key);
    grids[langTab]!.removeAt(r2);

    final read = readRoomEdits(grids, e, published: publish(e));
    expect(read.problems, isEmpty);
    expect(read.edits, hasLength(2));
    final more = read.edits.singleWhere((x) => x.lineKey == first.key);
    expect(more.to, first.qty + 1);
    expect(more.change.kind, kRoomLineKind);
    final removed = read.edits.singleWhere((x) => x.lineKey == gone.key);
    expect(removed.removed, isTrue);

    for (final edit in read.edits) {
      expect(await applyRoomEditsToFile(edit.configPath, [edit]), 1);
    }
    final after = price();
    final holtNow = after.rooms.firstWhere((r) => r.name == 'HOLT 171');
    final langNow = after.rooms.firstWhere((r) => r.name == 'LANG 300');
    expect(
      holtNow.estimate!.equipment.firstWhere((l) => l.key == first.key).qty,
      first.qty + 1,
    );
    // A line-item room draws its devices, so a deleted row is a count of 0
    // on a line that stays - the device is still on the drawing. A line
    // added by hand coming off is the test below.
    expect(removed.drawn, isTrue);
    expect(
      langNow.estimate!.equipment.singleWhere((l) => l.key == gone.key).qty,
      0,
    );
  });

  test('nothing changed reads as nothing', () {
    final e = price();
    final read = readRoomEdits(publish(e), e, published: publish(e));
    expect(read.edits, isEmpty);
    expect(read.problems, isEmpty);
  });

  test('a qty that is not a number is reported and left alone', () {
    final e = price();
    final tabs = projectRoomTabNames(e);
    final grids = publish(e);
    final holt = e.rooms.firstWhere((r) => r.name == 'HOLT 171');
    final line = holt.estimate!.equipment.first;
    final (r, q) = rowOf(grids[tabs[holt.ref.id]!]!, line.key);
    grids[tabs[holt.ref.id]!]![r][q] = 'a few';
    final read = readRoomEdits(grids, e, published: publish(e));
    expect(read.edits, isEmpty);
    expect(read.problems.single, contains('a few'));
  });

  test('an older copy does not undo a count already brought in', () async {
    final e = price();
    final published = publish(e);
    final tabs = projectRoomTabNames(e);
    final holt = e.rooms.firstWhere((r) => r.name == 'HOLT 171');
    final tab = tabs[holt.ref.id]!;
    final first = holt.estimate!.equipment.first;

    // The Sheet: one more, brought in.
    final sheet = publish(e);
    final (r, q) = rowOf(sheet[tab]!, first.key);
    sheet[tab]![r][q] = '${(first.qty + 1).round()}';
    final edit = readRoomEdits(sheet, e, published: published).edits.single;
    await applyRoomEditsToFile(edit.configPath, [edit]);
    final after = price();

    // The synced .xlsx still says what was published: not an edit.
    final stale = readRoomEdits(published, after, published: published);
    expect(stale.edits, isEmpty);
    // And the Sheet read again has nothing new to bring in either.
    expect(readRoomEdits(sheet, after, published: published).edits, isEmpty);
  });

  test('a line added since the publish is not read as deleted', () {
    final e = price();
    final tabs = projectRoomTabNames(e);
    final holt = e.rooms.firstWhere((r) => r.name == 'HOLT 171');
    final tab = tabs[holt.ref.id]!;
    final first = holt.estimate!.equipment.first;
    // Published without the line, as if it had been added afterwards.
    final published = publish(e);
    final (r, _) = rowOf(published[tab]!, first.key);
    published[tab]!.removeAt(r);
    final now = publish(e);
    now[tab]!.removeAt(r);
    expect(readRoomEdits(now, e, published: published).edits, isEmpty);
  });

  test('a drawn device keeps its line at 0; a line added by hand comes off',
      () {
    final cost = <String, dynamic>{
      'extraEquipment': [
        {'id': 'x1', 'description': 'Mount', 'qty': 2},
      ],
    };
    const drawn = RoomLineEdit(
      roomId: 'r',
      roomName: 'Room',
      configPath: '',
      tab: 'Room',
      lineKey: 'model:projector',
      description: 'Projector',
      from: 2,
      to: 0,
      drawn: true,
      onDrawing: 2,
    );
    const added = RoomLineEdit(
      roomId: 'r',
      roomName: 'Room',
      configPath: '',
      tab: 'Room',
      lineKey: 'x1',
      description: 'Mount',
      from: 2,
      to: 0,
      drawn: false,
    );
    expect(applyRoomEditsToCostJson(cost, [drawn, added]), 2);
    expect(cost['qtyOverrides'], {'model:projector': 0.0});
    expect(cost['extraEquipment'], isEmpty);
    // Back to what the drawing counts clears the typed count.
    const back = RoomLineEdit(
      roomId: 'r',
      roomName: 'Room',
      configPath: '',
      tab: 'Room',
      lineKey: 'model:projector',
      description: 'Projector',
      from: 0,
      to: 2,
      drawn: true,
      onDrawing: 2,
    );
    applyRoomEditsToCostJson(cost, [back]);
    expect(cost.containsKey('qtyOverrides'), isFalse);
  });

  test('the listed edits leave out the quantities brought in', () {
    final before = {
      'HOLT 171': [
        ['Device', 'Qty', 'Unit price', 'Row id'],
        ['Projector', '2', '100', 'x1'],
        ['Screen', '1', '50', 'x2'],
      ],
    };
    final now = {
      'HOLT 171': [
        ['Device', 'Qty', 'Unit price', 'Row id'],
        ['Projector', '3', '100', 'x1'],
        ['Screen', '1', '75', 'x2'],
      ],
    };
    final edits = sheetEdits(
      before,
      now,
      ignore: (tab, row, column) =>
          (column == 'Qty' || column.isEmpty) && row.contains('x1'),
    );
    expect(edits, hasLength(1));
    expect(edits.single.what, contains('Unit price'));
  });
}
