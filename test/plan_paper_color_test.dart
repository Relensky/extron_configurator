import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/room_sidecar.dart';
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
///  So the default follows the theme, and a room that wants its own colour
///  says so per sheet — the layout sheet and an imported export want
///  different backgrounds, and one shared colour would make the second
///  unreadable to fix the first.
/// ============================================================================
void main() {
  group('the default follows the theme', () {
    const sheet = FloorPlan(id: 'PLAN_1', name: 'Room layout');

    test('white on a light screen', () {
      expect(sheet.paperFor(dark: false), FloorPlan.kPaperLight);
    });

    test('and not white on a dark one', () {
      final dark = sheet.paperFor(dark: true);
      expect(dark, FloorPlan.kPaperDark);
      expect(dark, isNot(FloorPlan.kPaperLight));
      // Still light enough that black ink from an export reads on it: this is
      // a dimmer paper, not a dark one.
      expect(dark.computeLuminance(), greaterThan(0.6));
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
      expect(sheet.paperFor(dark: false), chosen);
      expect(sheet.paperFor(dark: true), chosen);
    });

    test('and it survives the round trip', () {
      final back = FloorPlan.fromJson(
          jsonDecode(jsonEncode(sheet.toJson())) as Map<String, dynamic>);
      expect(back.paperColor, chosen);
    });

    test('while following the theme writes nothing to the file', () {
      const plain = FloorPlan(id: 'PLAN_1', name: 'Room layout');
      expect(plain.toJson().containsKey('paper'), isFalse,
          reason: 'a room that has not chosen has nothing to record');
      final back = FloorPlan.fromJson(
          jsonDecode(jsonEncode(plain.toJson())) as Map<String, dynamic>);
      expect(back.paperColor, isNull);
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

    test('writes the colour onto that sheet', () {
      final p = room();
      final id = p.avFloorPlans.single.id;
      p.setAvPlanPaperColor(id, const Color(0xFFCFD4DA));
      expect(p.avFloorPlans.single.paperColor, const Color(0xFFCFD4DA));
    });

    test('and null puts it back to following the theme', () {
      final p = room();
      final id = p.avFloorPlans.single.id;
      p.setAvPlanPaperColor(id, const Color(0xFFCFD4DA));
      p.setAvPlanPaperColor(id, null);
      // Null has to mean "clear it", not "leave it alone" — the same trap the
      // cable colour override has.
      expect(p.avFloorPlans.single.paperColor, isNull);
      expect(p.avFloorPlans.single.paperFor(dark: true), FloorPlan.kPaperDark);
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
