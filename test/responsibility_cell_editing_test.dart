import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_view.dart';
import 'package:extron_configurator/responsibility_matrix.dart';

/// ============================================================================
///  ANSWERING THE MATRIX WHERE IT IS READ
/// ============================================================================
///  Two things this sheet could not do, both of which sent somebody through a
///  dialog to change one word:
///
///    WHOSE JOB IT IS was ink. The pair of party rows is what the whole
///    document exists to settle, and settling one meant opening the row's
///    editor, finding the right field among eight, typing, and saving —
///    thirty times on a sheet of thirty.
///
///    NOT EVERY CELL IS A NUMBER. The honest answer for a room is often "as
///    required", "per plan" or "existing to remain", and the quantity field
///    took digits only: anything else was dropped on the way in and the cell
///    went blank. A blank and "we have not decided" are opposite things to a
///    contractor pricing the line, which is the argument this document exists
///    to prevent.
///
///  So a cell is answered by pressing it, an answer can be words, and the ones
///  that are words are marked — because they are the cells the totals row
///  cannot add, and a total that quietly skipped four rooms is a bid short by
///  four rooms.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('resp_cells_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final (stem, code) in [('bss101', '101'), ('bss103', '103')]) {
      final file = '${dir.path}/${stem}_config.json';
      File(file).writeAsStringSync(
        jsonEncode({
          'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': code},
        }),
      );
      p.addRoomToProject(file);
    }
    return p;
  }

  Future<void> pumpPane(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_responsibility')));
    await tester.pumpAndSettle();
  }

  /// The id of the one room the tests set cells on.
  String roomId(AppStateProvider p) => p.project.rooms.first.id;

  // -------------------------------------------------------------------------
  //  WHOSE JOB IT IS, FROM THE SHEET
  // -------------------------------------------------------------------------

  group('the party cells', () {
    testWidgets('open a menu and set the cell they were pressed on', (
      tester,
    ) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_party_furnished_${item.id}')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('matrix_party_choice_Owner')));
      await tester.pumpAndSettle();

      final after = p.project.responsibilityById(item.id)!;
      expect(after.furnishedBy, 'Owner');
      // ONLY the cell that was pressed. The pair is the point of the sheet,
      // and a picker that set both would be answering a question nobody asked.
      expect(after.installedBy, isEmpty);
    });

    testWidgets('offer the parties this job has actually named', (
      tester,
    ) async {
      final p = withProject();
      final first = p.addResponsibilityItem('Projection screen');
      p.updateResponsibilityItem(
        p.project.responsibilityById(first.id)!.copyWith(
          furnishedBy: 'Valley/DPR',
        ),
      );
      final second = p.addResponsibilityItem('Ceiling speakers');
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_party_installed_${second.id}')).first,
      );
      await tester.pumpAndSettle();

      // A JOB'S OWN VOCABULARY BEATS THE DEFAULTS. Re-typing 'Valley/DPR' on
      // the second line is a second party as far as the color and the
      // contractor are concerned.
      expect(
        find.byKey(const ValueKey('matrix_party_choice_Valley/DPR')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('matrix_party_choice_Valley/DPR')),
      );
      await tester.pumpAndSettle();
      expect(
        p.project.responsibilityById(second.id)!.installedBy,
        'Valley/DPR',
      );
    });

    testWidgets('can take an answer back off', (tester) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      p.updateResponsibilityItem(
        p.project.responsibilityById(item.id)!.copyWith(installedBy: 'Owner'),
      );
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_party_installed_${item.id}')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('matrix_party_clear')));
      await tester.pumpAndSettle();

      expect(p.project.responsibilityById(item.id)!.installedBy, isEmpty);
    });

    testWidgets('a line nobody has claimed offers nothing to clear', (
      tester,
    ) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_party_furnished_${item.id}')).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('matrix_party_clear')), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  //  A CELL THAT IS NOT A NUMBER
  // -------------------------------------------------------------------------

  group('a room cell', () {
    testWidgets('takes a count, and it adds into the total', (tester) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_cell_${item.id}_${roomId(p)}')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('matrix_qty_field')),
        '4',
      );
      await tester.pumpAndSettle();
      // The dialog says which of the two it is about to save, while it is
      // being typed rather than after it is committed.
      expect(find.textContaining('adds into the line total'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('matrix_qty_save')));
      await tester.pumpAndSettle();

      final after = p.project.responsibilityById(item.id)!;
      expect(after.qtyByRoom[roomId(p)], 4);
      expect(after.total, 4);
      expect(after.cellIsNote(roomId(p)), isFalse);
    });

    testWidgets('takes words, keeps them, and leaves them out of the total', (
      tester,
    ) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_cell_${item.id}_${roomId(p)}')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('matrix_qty_field')),
        'As required',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Not a number'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('matrix_qty_save')));
      await tester.pumpAndSettle();

      final after = p.project.responsibilityById(item.id)!;
      expect(after.cellText(roomId(p)), 'As required');
      expect(after.cellIsNote(roomId(p)), isTrue);
      // IT CANNOT BE ADDED UP, and a sheet that counted it as one would be a
      // bid short by however many rooms said it.
      expect(after.total, 0);
      expect(after.noteCount, 1);
      // And the words are on the sheet, not just in the file.
      expect(find.text('As required'), findsWidgets);
    });

    testWidgets('offers the usual answers, numbers and words together', (
      tester,
    ) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_cell_${item.id}_${roomId(p)}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('matrix_qty_menu')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('matrix_qty_answer_2')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('matrix_qty_answer_Per plan')),
        findsOneWidget,
      );

      // PICKING FILLS THE FIELD rather than closing on it: the field stays the
      // single answer to what the cell says, and anything can still be typed.
      await tester.tap(
        find.byKey(const ValueKey('matrix_qty_answer_Per plan')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('matrix_qty_field')))
            .controller
            ?.text,
        'Per plan',
      );
    });

    testWidgets('a cell holds one answer, so words replace a count', (
      tester,
    ) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      p.setResponsibilityQty(item.id, roomId(p), 4);
      p.setResponsibilityNote(item.id, roomId(p), 'Per plan');

      final after = p.project.responsibilityById(item.id)!;
      expect(after.qtyByRoom.containsKey(roomId(p)), isFalse);
      expect(after.cellText(roomId(p)), 'Per plan');

      // And back the other way.
      p.setResponsibilityQty(item.id, roomId(p), 2);
      final again = p.project.responsibilityById(item.id)!;
      expect(again.cellIsNote(roomId(p)), isFalse);
      expect(again.cellText(roomId(p)), '2');
    });

    testWidgets('blank takes the room off the line', (tester) async {
      final p = withProject();
      final item = p.addResponsibilityItem('Projection screen');
      p.setResponsibilityNote(item.id, roomId(p), 'As required');
      await pumpPane(tester, p);

      await tester.tap(
        find.byKey(ValueKey('matrix_cell_${item.id}_${roomId(p)}')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('matrix_qty_field')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('matrix_qty_save')));
      await tester.pumpAndSettle();

      final after = p.project.responsibilityById(item.id)!;
      expect(after.cellText(roomId(p)), isEmpty);
      expect(after.cellIsNote(roomId(p)), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT THE FILE AND THE DOCUMENTS DO WITH IT
  // -------------------------------------------------------------------------

  group('a noted cell', () {
    test('survives a round trip through the file', () {
      const item = ResponsibilityItem(
        id: 'resp1',
        scope: 'Projection screen',
        qtyByRoom: {'r1': 4},
        noteByRoom: {'r2': 'As required'},
      );
      final back = ResponsibilityItem.fromJson(
        jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>,
      );
      expect(back.qtyByRoom['r1'], 4);
      expect(back.cellText('r2'), 'As required');
      expect(back.total, 4);
    });

    test('is recovered from an older file that dropped it', () {
      // BEFORE THIS, a quantity that would not parse was thrown away on the
      // way in - so a sheet somebody had answered in words opened with those
      // cells blank, which reads as a room that does not want the line.
      final back = ResponsibilityItem.fromJson({
        'id': 'resp1',
        'scope': 'Projection screen',
        'qtyByRoom': {'r1': 2, 'r2': 'as required'},
      });
      expect(back.qtyByRoom['r1'], 2);
      expect(back.cellText('r2'), 'as required');
      expect(back.cellIsNote('r2'), isTrue);
      // A bare zero is still an absence rather than an answer.
      final zeroed = ResponsibilityItem.fromJson({
        'id': 'resp2',
        'scope': 'Speakers',
        'qtyByRoom': {'r1': 0},
      });
      expect(zeroed.cellText('r1'), isEmpty);
      expect(zeroed.cellIsNote('r1'), isFalse);
    });

    test('is washed in the spreadsheet, and the count is not', () {
      const item = ResponsibilityItem(
        id: 'resp1',
        scope: 'Projection screen',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
        qtyByRoom: {'r1': 4},
        noteByRoom: {'r2': 'As required'},
      );
      final sections = responsibilityMatrixSections(
        [item],
        roomNames: [(id: 'r1', name: 'BSS 101'), (id: 'r2', name: 'BSS 103')],
      );
      final row = sections.first.rows.first;
      // The count is plain text: tinting three hundred ordinary cells to make
      // a point about four is a sheet of fills.
      expect(row[4], '4');
      expect(row[5].toString(), 'As required');
      expect(row[5], isNot(isA<String>()));
      // The total says what it could not add.
      expect(row[6].toString(), contains('+1 noted'));
    });

    test('the shared rule decides what counts', () {
      // One rule, so the dialog, the highlight and the total agree.
      expect(responsibilityCellIsCount('4'), isTrue);
      expect(responsibilityCellIsCount(' 2.5 '), isTrue);
      expect(responsibilityCellIsCount('0'), isFalse);
      expect(responsibilityCellIsCount('As required'), isFalse);
      expect(responsibilityCellIsCount(''), isFalse);
    });
  });
}
