import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/room_sidecar.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/room_locations.dart';

/// ============================================================================
///  WHAT THE PAPER IS
/// ============================================================================
///  The sheet used to be white, full stop. That was defensible while a sheet
///  always had a drawing behind it — an architect's export is black ink on
///  nothing, and a white mat is what stops a transparent PNG reading as a
///  hole. It stopped being defensible the moment a sheet could be BLANK,
///  because then the paper is the whole picture, and a full white rectangle
///  in a dark room is the thing people turn the lights on for.
///
///  It then followed the app theme for a while, which made the exported PNG
///  depend on how the person exporting it liked their app. So the default is
///  BLACK, the same black either way, and a sheet that wants a light mat under
///  a scan says so per sheet — the layout sheet and an imported export want
///  different backgrounds, and one shared color would make the second
///  unreadable to fix the first.
///
///  What makes that safe is that the ink follows the PAPER: everything printed
///  on the sheet asks [FloorPlan.paperIsDark] rather than the theme, so no
///  color offered here is one the labels disappear on.
/// ============================================================================
void main() {
  group('the default', () {
    const sheet = FloorPlan(id: 'PLAN_1', name: 'Room layout');

    test('is black, and the same black in either theme', () {
      expect(sheet.paper, FloorPlan.kPaperDefault);
      expect(FloorPlan.kPaperDefault, const Color(0xFF000000));
    });

    test('prints in light ink, because the paper says so', () {
      expect(sheet.paperIsDark, isTrue);
    });

    test('a sheet set back to white prints in dark ink', () {
      const white = FloorPlan(
        id: 'PLAN_1',
        name: 'Room layout',
        paperColor: Color(0xFFFFFFFF),
      );
      expect(white.paperIsDark, isFalse);
    });
  });

  group('a sheet that has chosen its own', () {
    const chosen = Color(0xFFE8F0E8);
    const sheet = FloorPlan(
      id: 'PLAN_1',
      name: 'Room layout',
      paperColor: chosen,
    );

    test('keeps it whatever the theme is doing', () {
      expect(sheet.paper, chosen);
    });

    test('and it survives the round trip', () {
      final back = FloorPlan.fromJson(
          jsonDecode(jsonEncode(sheet.toJson())) as Map<String, dynamic>);
      expect(back.paperColor, chosen);
    });

    test('while on the default writes nothing to the file', () {
      const plain = FloorPlan(id: 'PLAN_1', name: 'Room layout');
      expect(plain.toJson().containsKey('paper'), isFalse,
          reason: 'a room that has not chosen has nothing to record');
      final back = FloorPlan.fromJson(
          jsonDecode(jsonEncode(plain.toJson())) as Map<String, dynamic>);
      expect(back.paperColor, isNull);
    });
  });

  group('the colors on offer', () {
    /// WCAG contrast between two opaque colors: (L1 + 0.05) / (L2 + 0.05).
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    // What the sheet actually prints in, either side of [paperIsDark].
    const lightInk = Color(0xFFFFFFFF);
    const darkInk = Color(0xDD000000); // Colors.black87

    test('every swatch clears 4.5:1 against the ink it gets', () {
      for (final paper in kPaperSwatches) {
        final sheet = FloorPlan(
          id: 'PLAN_1',
          name: 'Room layout',
          paperColor: paper,
        );
        final ink = sheet.paperIsDark ? lightInk : darkInk;
        expect(
          contrast(paper, ink),
          greaterThanOrEqualTo(4.5),
          reason: 'paper $paper prints '
              '${sheet.paperIsDark ? 'light' : 'dark'} ink at '
              '${contrast(paper, ink).toStringAsFixed(2)}:1',
        );
      }
    });

    test('none of them is a mid-tone', () {
      // The old palette had a slate and a gray in it. Neither ink reads well
      // on those, and which one the sheet picks comes down to a threshold
      // nobody can see — so they are not offered.
      for (final paper in kPaperSwatches) {
        final l = paper.computeLuminance();
        expect(
          l < 0.18 || l > 0.55,
          isTrue,
          reason: '$paper sits in the middle at '
              '${l.toStringAsFixed(2)} luminance',
        );
      }
    });

    test('the default is one of them, and it is first', () {
      expect(kPaperSwatches.first, FloorPlan.kPaperDefault);
    });

    test('there are light papers too, for a scan that brings no background',
        () {
      expect(
        kPaperSwatches.where((c) => c.computeLuminance() > 0.55),
        isNotEmpty,
      );
      expect(kPaperSwatches, contains(const Color(0xFFFFFFFF)));
    });
  });

  group('setting it', () {
    AppStateProvider room() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};
      p.loadAvFlowForCurrentConfig();
      p.addFloorPlanSheet(name: 'Room layout');
      return p;
    }

    test('writes the color onto that sheet', () {
      final p = room();
      final id = p.avFloorPlans.single.id;
      p.setAvPlanPaperColor(id, const Color(0xFFCFD4DA));
      expect(p.avFloorPlans.single.paperColor, const Color(0xFFCFD4DA));
    });

    test('and null puts it back to the default', () {
      final p = room();
      final id = p.avFloorPlans.single.id;
      p.setAvPlanPaperColor(id, const Color(0xFFCFD4DA));
      p.setAvPlanPaperColor(id, null);
      // Null has to mean "clear it", not "leave it alone" — the same trap the
      // cable color override has.
      expect(p.avFloorPlans.single.paperColor, isNull);
      expect(p.avFloorPlans.single.paper, FloorPlan.kPaperDefault);
    });

    test('it is one sheet own business, not the room', () {
      final p = room();
      final first = p.avFloorPlans.single.id;
      final second = p.addFloorPlanSheet(name: 'Level 2').id;
      p.setAvPlanPaperColor(first, const Color(0xFFF6F1E7));

      expect(p.avFloorPlanById(first)!.paperColor, const Color(0xFFF6F1E7));
      expect(p.avFloorPlanById(second)!.paperColor, isNull);
    });

    test('and it is undoable', () {
      final p = room();
      final id = p.avFloorPlans.single.id;
      p.setAvPlanPaperColor(id, const Color(0xFF9AA3AC));
      p.undoAvFlow(AvUndoScope.floorPlans);
      expect(p.avFloorPlans.single.paperColor, isNull);
    });
  });
}
