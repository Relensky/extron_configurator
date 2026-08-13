import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/room_locations.dart';

/// An architectural plan is a line drawing, and text dropped straight onto one
/// lands on a wall. Every label is printed on a plate; this is what colour that
/// plate and the words on it are — per sheet, because the drawing issued to the
/// electrician and the one in the design pack are the same room and not the
/// same drawing.
void main() {
  test('a sheet nobody has recoloured follows the drawing it is on', () {
    const sheet = FloorPlan(id: 'PLAN_1', name: 'Level 1');
    for (final kind in PlanTextKind.values) {
      expect(sheet.styleFor(kind).isDefault, isTrue);
    }
    // Which is what the two resolvers mean by an unset colour.
    expect(
      planLabelBackground(PlanLabelStyle.unset, Colors.white),
      Colors.white,
    );
    expect(planLabelInk(PlanLabelStyle.unset, Colors.black87), Colors.black87);
  });

  test('a colour that IS set wins over the drawing default', () {
    const style = PlanLabelStyle(background: 0xFF00FF00, ink: 0xFF000080);
    expect(planLabelBackground(style, Colors.white), const Color(0xFF00FF00));
    expect(planLabelInk(style, Colors.black87), const Color(0xFF000080));
  });

  test('the colours survive a save and a reload of the sheet', () {
    const sheet = FloorPlan(id: 'PLAN_1', name: 'Level 1');
    final recoloured = sheet
        .withLabelStyle(
          PlanTextKind.wiring,
          const PlanLabelStyle(background: 0xFFFFF59D, ink: 0xFF000000),
        )
        .withLabelStyle(
          PlanTextKind.location,
          const PlanLabelStyle(background: 0xFFFFFFFF),
        );

    final back = FloorPlan.fromJson(recoloured.toJson());
    expect(back.styleFor(PlanTextKind.wiring).background, 0xFFFFF59D);
    expect(back.styleFor(PlanTextKind.wiring).ink, 0xFF000000);
    expect(back.styleFor(PlanTextKind.location).background, 0xFFFFFFFF);
    // Untouched, so still the drawing's own.
    expect(back.styleFor(PlanTextKind.callout).isDefault, isTrue);
  });

  test('a sheet put back to standard saves as one that was never touched', () {
    const sheet = FloorPlan(id: 'PLAN_1', name: 'Level 1');
    final recoloured = sheet.withLabelStyle(
      PlanTextKind.callout,
      const PlanLabelStyle(background: 0xFF123456),
    );
    final reset = recoloured.withLabelStyle(
      PlanTextKind.callout,
      PlanLabelStyle.unset,
    );
    expect(reset.labelStyles, isEmpty);
    expect(reset.toJson().containsKey('labelStyles'), isFalse);
  });

  test('the provider recolours only the sheet it was asked about', () {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final one = p.addAvFloorPlan(const FloorPlan(id: '', name: 'Level 1'));
    final two = p.addAvFloorPlan(const FloorPlan(id: '', name: 'Level 2'));

    p.setAvPlanLabelStyle(
      one.id,
      PlanTextKind.wiring,
      const PlanLabelStyle(background: 0xFFFFF59D),
    );

    expect(
      p.avFloorPlanById(one.id)!.styleFor(PlanTextKind.wiring).background,
      0xFFFFF59D,
    );
    // The other sheet is a different drawing and is left alone.
    expect(
      p.avFloorPlanById(two.id)!.styleFor(PlanTextKind.wiring).isDefault,
      isTrue,
    );
  });
}
