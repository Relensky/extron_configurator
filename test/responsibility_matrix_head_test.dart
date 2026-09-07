import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_view.dart';

/// THE TOP OF A SCOPE COLUMN.
///
/// Two failures, both of them the kind a sheet of thirty columns multiplies.
/// The handle used to stand BESIDE the name, so every heading was indented by
/// its own grip and a name that wrapped started its second line further left
/// than its first - thirty columns, no two of them beginning in the same
/// place. And the party under it was drawn at a fixed size, so 'Owner' and
/// 'Contractor' were the one thing on the document that did not grow when
/// somebody zoomed in to read it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('matrix_head_cell_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider withMatrix() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    final file = '${dir.path}/bss101_config.json';
    File(file).writeAsStringSync(
      '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"101"}}',
    );
    p.addRoomToProject(file);
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

  /// The scope name inside one column head, as opposed to the same words on
  /// the editor list further down the pane.
  Finder headText(String id, String scope) => find.descendant(
    of: find.byKey(ValueKey('matrix_head_$id')),
    matching: find.text(scope),
  );

  group('the grip and the name are stacked, not side by side', () {
    testWidgets('the grip is above the name and both start at the same edge', (
      tester,
    ) async {
      final p = withMatrix();
      await pumpPane(tester, p);
      final first = p.project.responsibility.first;

      final grip = tester.getRect(
        find.byKey(ValueKey('matrix_grip_${first.id}')),
      );
      final name = tester.getRect(headText(first.id, first.scope));

      // The handle in the top left corner, clear of the name under it.
      expect(grip.bottom, lessThanOrEqualTo(name.top + 1));
      // And nothing indenting the name: both are flush with the column's own
      // left edge.
      expect(name.left, closeTo(grip.left, 1));
    });

    testWidgets('every column head starts its name in the same place', (
      tester,
    ) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      final lefts = <double>[
        for (final item in p.project.responsibility.take(3))
          tester.getRect(headText(item.id, item.scope)).left,
      ];
      // Relative to the column each one is in: the sheet steps sideways by a
      // fixed column width, so the offsets have to step by the same amount.
      final steps = <double>[
        for (var i = 1; i < lefts.length; i++) lefts[i] - lefts[i - 1],
      ];
      for (final step in steps) {
        expect(step, closeTo(steps.first, 1));
      }
    });
  });

  group('the parties are read at the size the sheet is read at', () {
    /// How big one party's name is drawn in the column heads.
    ///
    /// The BIGGEST of them on the pane: the same two parties are named on
    /// every row of the editor list further down, which does not zoom, so the
    /// grid is whichever copy the sheet's own size has moved.
    double partySize(WidgetTester tester, String party) => tester
        .widgetList<Text>(find.text(party))
        .map((t) => t.style?.fontSize ?? 0)
        .reduce((a, b) => a > b ? a : b);

    testWidgets('owner and contractor grow with the zoom', (tester) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      final owner = partySize(tester, 'Owner');
      final contractor = partySize(tester, 'Contractor');

      await tester.tap(find.byKey(const ValueKey('matrix_zoom_in')));
      await tester.pumpAndSettle();

      // BOTH of them, and by the same step: they are one row above the other
      // and a sheet that grew one of them would read as a change of emphasis.
      expect(partySize(tester, 'Owner'), greaterThan(owner));
      expect(partySize(tester, 'Contractor'), greaterThan(contractor));
      expect(
        partySize(tester, 'Owner') / owner,
        closeTo(partySize(tester, 'Contractor') / contractor, 0.01),
      );
    });

    testWidgets('and shrink again when the sheet is zoomed back out', (
      tester,
    ) async {
      final p = withMatrix();
      await pumpPane(tester, p);

      await tester.tap(find.byKey(const ValueKey('matrix_zoom_in')));
      await tester.pumpAndSettle();
      final bigger = partySize(tester, 'Owner');

      await tester.tap(find.byKey(const ValueKey('matrix_zoom_out')));
      await tester.pumpAndSettle();
      expect(partySize(tester, 'Owner'), lessThan(bigger));
    });
  });
}
