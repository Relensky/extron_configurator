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
}
