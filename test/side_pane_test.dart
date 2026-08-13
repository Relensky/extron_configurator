import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/side_pane.dart';

/// Every page in this app is a drawing with a column of controls beside it, and
/// every one of those columns used to be a width nobody could argue with. The
/// pane is the one widget both sides use, so it has to behave the same
/// wherever it turns up: drag the edge to resize, fold it away, get it back.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    PaneSide side = PaneSide.right,
    double initialWidth = 320,
    double minWidth = 180,
    double maxWidth = 620,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: ColoredBox(color: Colors.black12)),
              SidePane(
                side: side,
                title: 'Devices',
                storageKey: 'test_pane',
                initialWidth: initialWidth,
                minWidth: minWidth,
                maxWidth: maxWidth,
                child: ListView(
                  children: const [Text('a device in the list')],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double paneWidth(WidgetTester tester) =>
      tester.getSize(find.byType(SidePane)).width;

  /// The divider between the pane and the page, which is also the handle.
  final grip = find.byKey(const ValueKey('pane_grip_test_pane'));

  testWidgets('opens at its width with the child on it', (tester) async {
    await pump(tester);
    expect(find.text('a device in the list'), findsOneWidget);
    // The pane is the panel plus the grip that resizes it.
    expect(paneWidth(tester), greaterThanOrEqualTo(320));
    expect(paneWidth(tester), lessThan(340));
  });

  testWidgets('folds to a strip and comes back', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('pane_fold_test_pane')));
    await tester.pumpAndSettle();

    expect(find.text('a device in the list'), findsNothing);
    expect(paneWidth(tester), kFoldedPaneWidth);
    // The name is still on the strip, which is how a folded pane is found.
    expect(find.text('Devices'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pane_unfold_test_pane')));
    await tester.pumpAndSettle();
    expect(find.text('a device in the list'), findsOneWidget);
  });

  testWidgets('dragging the grip left widens a right-hand pane',
      (tester) async {
    await pump(tester);
    final before = paneWidth(tester);
    // Dragged further than the gesture slop, which the first few pixels of
    // any drag are spent on.
    await tester.drag(grip, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(paneWidth(tester), greaterThan(before + 150));
  });

  testWidgets('dragging the grip left narrows a left-hand pane',
      (tester) async {
    await pump(tester, side: PaneSide.left);
    final before = paneWidth(tester);
    await tester.drag(grip, const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(paneWidth(tester), lessThan(before - 60));
  });

  testWidgets('it cannot be dragged past its limits', (tester) async {
    await pump(tester, minWidth: 200, maxWidth: 400);
    await tester.drag(grip, const Offset(-4000, 0));
    await tester.pumpAndSettle();
    expect(paneWidth(tester), lessThan(420));

    await tester.drag(grip, const Offset(4000, 0));
    await tester.pumpAndSettle();
    expect(paneWidth(tester), greaterThan(195));
  });

  group('the pane across the bottom', () {
    Future<void> pumpBottom(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: ColoredBox(color: Colors.black12)),
                BottomPane(
                  storageKey: 'test_bottom',
                  initialHeight: 190,
                  minHeight: 90,
                  maxHeight: 500,
                  child: ListView(
                    children: const [Text('a line in the list')],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final bottomGrip = find.byKey(const ValueKey('pane_grip_test_bottom'));
    double paneHeight(WidgetTester tester) =>
        tester.getSize(find.byType(BottomPane)).height;

    testWidgets('dragging its top edge up makes it taller', (tester) async {
      await pumpBottom(tester);
      final before = paneHeight(tester);
      expect(find.text('a line in the list'), findsOneWidget);

      await tester.drag(bottomGrip, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(paneHeight(tester), greaterThan(before + 150));
    });

    testWidgets('it stops at its limits and comes back on a double-click',
        (tester) async {
      await pumpBottom(tester);
      final before = paneHeight(tester);

      await tester.drag(bottomGrip, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(paneHeight(tester), lessThan(520));

      await tester.drag(bottomGrip, const Offset(0, 4000));
      await tester.pumpAndSettle();
      expect(paneHeight(tester), greaterThan(95));

      await tester.tap(bottomGrip);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(bottomGrip);
      await tester.pumpAndSettle();
      expect(paneHeight(tester), before);
    });
  });

  testWidgets('double-clicking the grip puts the width back', (tester) async {
    await pump(tester);
    final before = paneWidth(tester);
    await tester.drag(grip, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(paneWidth(tester), greaterThan(before));

    // The way back from a pane dragged to a silly size.
    await tester.tap(grip);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(grip);
    await tester.pumpAndSettle();
    expect(paneWidth(tester), before);
  });
}
