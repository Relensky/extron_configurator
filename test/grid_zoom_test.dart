import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/pinned_grid.dart';

/// HOW BIG THE SHEET IS BEING READ AT.
///
/// The replacement plan is the one screen in this app somebody leans into -
/// a figure in a cell four columns wide - and then leans back from to see the
/// shape of a decade. The zoom is those two readings of the same sheet, and
/// what these guard is the half that is easy to get backwards: zooming out
/// has to let MORE years into the frame, and zooming in must never quietly
/// throw the far ones away.
void main() {
  group('the steps', () {
    test('move one at a time and stop at both ends', () {
      expect(gridZoomIn(kGridZoomNormal), 1.25);
      expect(gridZoomOut(kGridZoomNormal), 0.75);
      expect(gridZoomIn(kGridZoomSteps.last), kGridZoomSteps.last);
      expect(gridZoomOut(kGridZoomSteps.first), kGridZoomSteps.first);
    });

    test('every step is reachable from the one below it', () {
      var at = kGridZoomSteps.first;
      final walked = <double>[at];
      while (gridZoomIn(at) != at) {
        at = gridZoomIn(at);
        walked.add(at);
      }
      expect(walked, kGridZoomSteps);
    });
  });

  group('the year window', () {
    test('widens as the sheet shrinks', () {
      expect(gridYearWindow(12, 0.5), 24);
      expect(gridYearWindow(25, 0.5), 50);
    });

    test('is the natural one at 100% and above', () {
      // Zooming IN is for reading a figure. A grid that gave the near years
      // more room by dropping the far ones would be hiding data somebody
      // could otherwise have scrolled to.
      expect(gridYearWindow(12, kGridZoomNormal), 12);
      expect(gridYearWindow(12, 1.5), 12);
      expect(gridYearWindow(12, 2), 12);
    });
  });

  // ---------------------------------------------------------------------------
  //  HOW WIDE THE PINNED COLUMN IS
  // ---------------------------------------------------------------------------
  //  A name that is ellipsised is not a label. The column was a fixed width
  //  chosen for a room number, and the campus sheet puts BUILDING names down
  //  it - 'Farm Agricultural Education Center' in 126 pixels is 'Farm Agri…',
  //  which names nothing and cannot be told from the building next to it.

  group('the frozen column', () {
    /// [PinnedGrid.frozenWidthFor] needs a BuildContext for the reader's text
    /// scale, so it is measured inside a pumped app.
    Future<double> widthOf(
      WidgetTester tester,
      List<String> lines, {
      double min = 100,
      double max = 400,
    }) async {
      late double measured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              measured = PinnedGrid.frozenWidthFor(
                context,
                lines,
                const TextStyle(fontSize: 14),
                min: min,
                max: max,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return measured;
    }

    testWidgets('a long name gets a wider column than a short one',
        (tester) async {
      final short = await widthOf(tester, ['BSS 103']);
      final long = await widthOf(
        tester,
        ['Farm Agricultural Education Center refresh'],
      );
      expect(long, greaterThan(short));
    });

    testWidgets('the longest name is the one that sizes it', (tester) async {
      final alone = await widthOf(
        tester,
        ['Farm Agricultural Education Center refresh'],
      );
      final withOthers = await widthOf(tester, [
        'BSS 103',
        'Farm Agricultural Education Center refresh',
        'PAC 101',
      ]);
      expect(withOthers, alone);
    });

    testWidgets('a short list still gets a column, not a stripe',
        (tester) async {
      expect(await widthOf(tester, ['A'], min: 168), 168);
    });

    testWidgets('one absurd name cannot eat the sheet', (tester) async {
      expect(
        await widthOf(tester, ['x' * 400], max: 340),
        340,
      );
    });

    testWidgets('an empty list falls back to the floor', (tester) async {
      expect(await widthOf(tester, const [], min: 210), 210);
    });
  });
}
