import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_flow_model.dart';

/// ============================================================================
///  SIX LEADS DRAWN AS ONE
/// ============================================================================
///  The router works a cable at a time, and two cables with the same problem
///  get the same answer — the same lane over a block of boxes, the same
///  channel out of the pathfinder. Six runs then come out drawn on top of each
///  other, which is not a tidy diagram: five of the leads are invisible and the
///  visible one is whichever was painted last.
///
///  The cabling sheet has always fanned runs sharing an edge onto their own
///  lanes. This is the same thing for a router that produces polylines.
/// ============================================================================
void main() {
  group('runs sharing a corridor', () {
    test('are slid apart so every one of them can be seen', () {
      // Three runs down the same vertical corridor and along the same
      // horizontal leg — the shape every source-into-switcher run has.
      final routes = <String, List<Offset>>{
        for (final id in ['C1', 'C2', 'C3'])
          id: const [
            Offset(200, 100),
            Offset(218, 100),
            Offset(218, 300),
            Offset(400, 300),
            Offset(418, 300),
          ],
      };

      final fanned = fanOverlappingRuns(routes);

      // The vertical leg each run travels down is now three separate lines.
      final xs = {for (final r in fanned.values) r[1].dx};
      expect(xs.length, 3, reason: 'the corridor is still one line: $xs');

      // And they are a readable distance apart, not a rounding error.
      final sorted = xs.toList()..sort();
      expect(sorted.last - sorted.first, greaterThanOrEqualTo(4));
      // But still one bundle going the same way, not a scatter.
      expect(sorted.last - sorted.first, lessThanOrEqualTo(20));
    });

    test('keep both ends on their own connector', () {
      final routes = <String, List<Offset>>{
        for (final id in ['C1', 'C2'])
          id: const [
            Offset(200, 100),
            Offset(218, 100),
            Offset(218, 300),
            Offset(400, 300),
            Offset(418, 300),
          ],
      };

      final fanned = fanOverlappingRuns(routes);
      for (final route in fanned.values) {
        // The port anchors are where the sockets are. A run fanned off its own
        // connector is a run drawn into thin air.
        expect(route.first, const Offset(200, 100));
        expect(route.last, const Offset(418, 300));
      }
    });

    test('stay joined up: every leg is still square', () {
      final routes = <String, List<Offset>>{
        for (final id in ['C1', 'C2', 'C3', 'C4'])
          id: const [
            Offset(200, 100),
            Offset(218, 100),
            Offset(218, 300),
            Offset(400, 300),
            Offset(418, 300),
          ],
      };

      for (final route in fanOverlappingRuns(routes).values) {
        for (int i = 0; i < route.length - 1; i++) {
          final a = route[i], b = route[i + 1];
          expect(
            (a.dx - b.dx).abs() < 0.01 || (a.dy - b.dy).abs() < 0.01,
            isTrue,
            reason: 'the leg $a → $b came out diagonal',
          );
        }
      }
    });
  });

  group('runs that are not on top of each other', () {
    test('a straight run described in three points comes back as two', () {
      // Straightened on the way through: a stub in line with the leg after it
      // is one leg, and treating it as two would slide half a straight run
      // sideways from the other half.
      final routes = <String, List<Offset>>{
        'straight': const [Offset(0, 0), Offset(40, 0), Offset(200, 0)],
      };
      expect(fanOverlappingRuns(routes)['straight'],
          const [Offset(0, 0), Offset(200, 0)]);
    });

    test('two that merely cross are left alone', () {
      final routes = <String, List<Offset>>{
        'across': const [
          Offset(0, 100),
          Offset(0, 200),
          Offset(400, 200),
          Offset(400, 300),
        ],
        'down': const [
          Offset(100, 0),
          Offset(200, 0),
          Offset(200, 400),
          Offset(300, 400),
        ],
      };

      expect(fanOverlappingRuns(routes), routes);
    });

    test('two in the same corridor at different heights are left alone', () {
      final routes = <String, List<Offset>>{
        'high': const [
          Offset(0, 100),
          Offset(40, 100),
          Offset(40, 160),
          Offset(240, 160),
        ],
        'low': const [
          Offset(0, 400),
          Offset(40, 400),
          Offset(40, 460),
          Offset(240, 460),
        ],
      };

      expect(fanOverlappingRuns(routes), routes);
    });

    test('a single run is handed straight back', () {
      final routes = <String, List<Offset>>{
        'only': const [Offset(0, 0), Offset(40, 0), Offset(40, 80)],
      };
      expect(fanOverlappingRuns(routes), routes);
    });
  });
}
