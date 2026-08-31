import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_view.dart';

/// THE HEAD OF THE RESPONSIBILITY SHEET.
///
/// Two failures, both about a reader losing their place on a document that is
/// wider than the window:
///
///   THE WORD 'ROOM' WAS FURTHEST FROM THE ROOMS. It sat at the top of the
///   corner with 'Cutsheet', 'Furnished by' and 'Installed by' stacked between
///   it and the first room name - so the one label that says what the frozen
///   column IS was four rows above it, and the three labels underneath, which
///   name rows running off to the RIGHT, read as though they described the
///   rooms. It is on a strip of its own at the bottom of the header now,
///   directly over the rooms, and that strip is what separates the agreement
///   from the quantities.
///
///   THE SCOPE NAMES WERE CLIPPED. A fixed 60-pixel row with three lines of
///   ellipsis in it, on a document whose lines are called 'Conduit and back
///   boxes for floor-mounted connectivity'. The row is measured off the names
///   it actually carries now.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('matrix_header_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider withMatrix() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final number in ['101', '103']) {
      final file = '${dir.path}/bss${number}_config.json';
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"$number"}}',
      );
      p.addRoomToProject(file);
    }
    p.addStarterResponsibilityItems();
    // The cutsheet row is one decision for the whole grid - a job with no
    // cutsheets anywhere keeps it off - so one line has to carry one for the
    // row to be on the sheet at all.
    final first = p.project.responsibility.first;
    p.updateResponsibilityItem(
      first.copyWith(productLink: 'https://example.invalid/cutsheet.pdf'),
    );
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

  group('the corner names the column it is over', () {
    testWidgets('ROOM sits under the cutsheet and the two parties', (
      tester,
    ) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      final room = tester.getTopLeft(find.text('ROOM'));
      for (final above in ['Cutsheet', 'Furnished by', 'Installed by']) {
        expect(
          room.dy,
          // .first is the corner's own label - the editor list further
          // down the pane names the same two parties on every row.
          greaterThan(tester.getTopLeft(find.text(above).first).dy),
          reason: '"$above" names a row running to the right; ROOM names the '
              'column running down, so it belongs at the bottom of the head',
        );
      }
    });

    testWidgets('and directly over the first room name', (tester) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      final room = tester.getBottomLeft(find.text('ROOM'));
      final first = tester.getTopLeft(find.text('BSS 101').first);
      // Nothing between the label and the thing it labels.
      expect(first.dy, greaterThanOrEqualTo(room.dy - 1));
      expect(first.dy - room.dy, lessThan(16));
    });

    testWidgets('the scope names still have a heading of their own', (
      tester,
    ) async {
      final p = withMatrix();
      await pumpPane(tester, p);
      // The corner is beside the scope names as well as above the rooms, and
      // it is the scope names the top of it was always naming.
      expect(find.text('SCOPE OF WORK'), findsOneWidget);
    });
  });

  group('a scope name is read, not guessed at', () {
    testWidgets('the header grows for a name that would have been clipped', (
      tester,
    ) async {
      // Same sheet twice: once with the starter lines, once with one of them
      // renamed to the kind of sentence this document really carries. The
      // header has to be taller the second time, because the name is longer
      // than the old fixed row could ever have shown.
      //
      // Measured as WHERE THE FIRST ROOM STARTS, which is the header's whole
      // height and the thing that has to move for the name to fit.
      final short = withMatrix();
      await pumpPane(tester, short);
      final shortHead = tester.getTopLeft(find.text('BSS 101').first).dy;

      final long = withMatrix();
      final first = long.project.responsibility.first;
      long.updateResponsibilityItem(
        first.copyWith(
          scope: 'Conduit, back boxes and pull strings for every '
              'floor-mounted connectivity point anywhere in the room',
        ),
      );
      await pumpPane(tester, long);
      final longHead = tester.getTopLeft(find.text('BSS 101').first).dy;

      expect(
        longHead,
        greaterThan(shortHead),
        reason: 'the row is measured off the names it carries, so a heading '
            'that needs five lines gets five rather than an ellipsis',
      );
    });
  });
}
