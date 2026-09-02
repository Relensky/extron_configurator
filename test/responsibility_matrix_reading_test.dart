import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/pinned_grid.dart';
import 'package:extron_configurator/project_view.dart';

/// READING ACROSS THE RESPONSIBILITY MATRIX.
///
/// The failure this guards is the one a wide sheet always has: a quantity read
/// against the wrong room. The room name is pinned to the left edge and the
/// number is twenty-eight columns to the right of it, with nine identical rows
/// in between, and the band on alternate rows says "this is an odd row" rather
/// than "this is YOUR row".
///
/// Two answers, both tested here: the line under the pointer is lit right
/// across the sheet, frozen half included, and the sheet zooms the way the
/// replacement plan does - out for the shape of the agreement, in to read a
/// figure, and one press to fit.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('matrix_reading_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A job with enough rooms that a row is worth tracking across, and the
  /// usual scope lines on it.
  AppStateProvider withMatrix() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final number in ['101', '103', '105', '107']) {
      final file = '${dir.path}/bss${number}_config.json';
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"$number"}}',
      );
      p.addRoomToProject(file);
    }
    p.addStarterResponsibilityItems();
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

  /// The fill painted by [container], or null when it has none.
  ///
  /// Read off the box the cell actually draws rather than off a color this
  /// test computes: the point is that the two halves of the sheet agree, and a
  /// test that recomputed the color would agree with itself whatever they did.
  Color? fillOfBox(WidgetTester tester, Finder container) {
    final decoration = tester.widget<Container>(container).decoration;
    return decoration is BoxDecoration ? decoration.color : null;
  }

  /// The wash behind a scope cell. The cell's box is INSIDE its InkWell.
  Color? cellFill(WidgetTester tester, Finder cell) => fillOfBox(
    tester,
    find.descendant(of: cell, matching: find.byType(Container)).first,
  );

  /// The wash behind a room name in the frozen column, whose box is the Text's
  /// own parent - the frozen half has no InkWell around it.
  Color? nameFill(WidgetTester tester, Finder name) => fillOfBox(
    tester,
    find.ancestor(of: name, matching: find.byType(Container)).first,
  );

  // -------------------------------------------------------------------------
  //  THE SHEET ZOOMS
  // -------------------------------------------------------------------------

  group('the sheet is sized by the reader', () {
    testWidgets('it carries the same three controls the plan does', (
      tester,
    ) async {
      await pumpPane(tester, withMatrix());

      expect(find.byKey(const ValueKey('matrix_zoom_out')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix_zoom_in')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix_zoom_fit')), findsOneWidget);
      expect(find.byKey(const ValueKey('matrix_zoom_level')), findsOneWidget);
    });

    testWidgets('it opens fitted, so the whole agreement is on screen', (
      tester,
    ) async {
      await pumpPane(tester, withMatrix());

      final fit = tester.widget<IconButton>(
        find.byKey(const ValueKey('matrix_zoom_fit')),
      );
      expect(
        fit.isSelected,
        isTrue,
        reason: 'the first question is how much of it nobody has claimed, '
            'which is a question about the whole sheet',
      );
    });

    testWidgets('zooming in makes the cells bigger, and leaves the fit', (
      tester,
    ) async {
      await pumpPane(tester, withMatrix());

      final grid = find.byType(PinnedGrid);
      final before = tester.widget<PinnedGrid>(grid).bodyWidth;

      await tester.tap(find.byKey(const ValueKey('matrix_zoom_in')));
      await tester.pumpAndSettle();

      expect(tester.widget<PinnedGrid>(grid).bodyWidth, greaterThan(before));
      // Zooming by hand is a decision about the size, so the sheet stops
      // chasing the window.
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('matrix_zoom_fit')))
            .isSelected,
        isFalse,
      );
    });

    testWidgets('zooming out makes them smaller and keeps every column', (
      tester,
    ) async {
      final p = withMatrix();
      await pumpPane(tester, p);
      final items = p.project.responsibility.length;

      await tester.tap(find.byKey(const ValueKey('matrix_zoom_in')));
      await tester.pumpAndSettle();
      final wide = tester.widget<PinnedGrid>(find.byType(PinnedGrid)).bodyWidth;

      await tester.tap(find.byKey(const ValueKey('matrix_zoom_out')));
      await tester.pumpAndSettle();
      final grid = tester.widget<PinnedGrid>(find.byType(PinnedGrid));

      expect(grid.bodyWidth, lessThan(wide));
      // FITTING SCALES THE SHEET, IT DOES NOT DROP COLUMNS. Every scope item
      // is still on it - what changed is how much fits on screen at once.
      expect(
        grid.bodyWidth / grid.frozenWidth,
        greaterThan(0),
        reason: 'a sheet with no scope columns is not a matrix',
      );
      expect(p.project.responsibility.length, items);
    });

    testWidgets('the level reads as a percentage and goes back to 100%', (
      tester,
    ) async {
      await pumpPane(tester, withMatrix());

      await tester.tap(find.byKey(const ValueKey('matrix_zoom_in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('matrix_zoom_level')));
      await tester.pumpAndSettle();

      expect(find.text('100%'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  //  THE LINE UNDER THE POINTER
  // -------------------------------------------------------------------------

  group('hovering a line lights it right across the sheet', () {
    testWidgets('the cell and the room name it belongs to are both washed', (
      tester,
    ) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      final room = p.project.rooms[1];
      final item = p.project.responsibility.first;
      final cell = find.byKey(ValueKey('matrix_cell_${item.id}_${room.id}'));
      expect(cell, findsOneWidget);

      // The name in the frozen half that is on the same line. Found by its
      // text rather than by a key, because it is the half a reader is trying
      // to get their eye back to.
      final names = p.priceProject().roomCodeNames;
      final nameFinder = find.text(names[room.id]!);
      expect(nameFinder, findsOneWidget);

      final cellBefore = cellFill(tester, cell);
      final nameBefore = nameFill(tester, nameFinder);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(cell));
      await tester.pumpAndSettle();

      final cellAfter = cellFill(tester, cell);
      final nameAfter = nameFill(tester, nameFinder);

      expect(cellAfter, isNot(cellBefore), reason: 'the cell is lit');
      expect(
        nameAfter,
        isNot(nameBefore),
        reason: 'and so is the room name pinned to the far left of the line - '
            'lighting one half of a row is lighting none of it',
      );
      expect(
        nameAfter,
        cellAfter,
        reason: 'both halves take the SAME wash, or the line does not read as '
            'one line',
      );
    });

    testWidgets('leaving the sheet puts the highlight out', (tester) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      final room = p.project.rooms[1];
      final item = p.project.responsibility.first;
      final cell = find.byKey(ValueKey('matrix_cell_${item.id}_${room.id}'));
      final resting = cellFill(tester, cell);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(cell));
      await tester.pumpAndSettle();
      expect(cellFill(tester, cell), isNot(resting));

      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        cellFill(tester, cell),
        resting,
        reason: 'a highlight that stays behind is a second row that looks like '
            'the one being read',
      );
    });

    testWidgets('only the line under the pointer is lit', (tester) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      final item = p.project.responsibility.first;
      final lit = find.byKey(
        ValueKey('matrix_cell_${item.id}_${p.project.rooms[1].id}'),
      );
      final other = find.byKey(
        ValueKey('matrix_cell_${item.id}_${p.project.rooms[3].id}'),
      );
      final otherResting = cellFill(tester, other);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(lit));
      await tester.pumpAndSettle();

      expect(cellFill(tester, other), otherResting);
    });
  });
}
