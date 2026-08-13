import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/room_locations.dart';

/// An architectural export draws all the way to its own border, so the key,
/// the callout list and the notes all ended up on top of the walls somebody
/// was reading. A sheet can now carry blank paper round the drawing for them
/// to sit on — and adding it must not slide every mark off the thing it marks.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  test('a sheet with no margins is the size of its image', () {
    const sheet = FloorPlan(
      id: 'PLAN_1',
      name: 'Level 1',
      imageSize: Size(1200, 900),
    );
    expect(sheet.sheetSize, const Size(1200, 900));
    expect(sheet.toJson().containsKey('margins'), isFalse);
  });

  test('the margins grow the sheet and survive a save and a reload', () {
    const sheet = FloorPlan(
      id: 'PLAN_1',
      name: 'Level 1',
      imageSize: Size(1200, 900),
      margins: EdgeInsets.fromLTRB(40, 0, 260, 80),
    );
    expect(sheet.sheetSize, const Size(1500, 980));

    final back = FloorPlan.fromJson(sheet.toJson());
    expect(back.margins, const EdgeInsets.fromLTRB(40, 0, 260, 80));
    expect(back.sheetSize, const Size(1500, 980));
  });

  test('space on the right leaves everything where it was', () {
    final p = room();
    final plan = p.addAvFloorPlan(
      const FloorPlan(id: '', name: 'L1', imageSize: Size(1200, 900)),
    );
    final loc = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
    p.moveAvLocationMarker(plan.id, loc.id, const Offset(300, 400));

    p.setAvPlanMargins(plan.id, const EdgeInsets.only(right: 300));

    final after = p.avFloorPlanById(plan.id)!;
    expect(after.sheetSize.width, 1500);
    // Nothing to shift: the image is still at the sheet's origin.
    expect(after.markerFor(loc.id), const Offset(300, 400));
  });

  test('space on the left carries the whole drawing with it', () {
    final p = room();
    final plan = p.addAvFloorPlan(
      const FloorPlan(
        id: '',
        name: 'L1',
        imageSize: Size(1200, 900),
        callouts: [
          FloorPlanCallout(id: 'CALLOUT_1', tag: '1', pos: Offset(100, 100)),
        ],
        annotations: [
          PlanAnnotation(
            id: 'NOTE_1',
            start: Offset(10, 20),
            end: Offset(30, 40),
          ),
        ],
        keyPos: Offset(24, 24),
      ),
    );
    final loc = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
    p.moveAvLocationMarker(plan.id, loc.id, const Offset(300, 400));
    p.setAvRunWaypoints(plan.id, 'run:1', const [Offset(500, 500)]);

    p.setAvPlanMargins(plan.id, const EdgeInsets.fromLTRB(200, 100, 0, 0));

    final after = p.avFloorPlanById(plan.id)!;
    // The marker is still on the same spot of the DRAWING, which is the whole
    // requirement: the image moved, so everything on it moved with it.
    expect(after.markerFor(loc.id), const Offset(500, 500));
    expect(after.callouts.single.pos, const Offset(300, 200));
    expect(after.annotations.single.start, const Offset(210, 120));
    expect(after.waypointsFor('run:1').single, const Offset(700, 600));
    expect(after.keyPos, const Offset(224, 124));
    expect(after.sheetSize, const Size(1400, 1000));
  });

  test('taking the space back moves everything back', () {
    final p = room();
    final plan = p.addAvFloorPlan(
      const FloorPlan(id: '', name: 'L1', imageSize: Size(1200, 900)),
    );
    final loc = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
    p.moveAvLocationMarker(plan.id, loc.id, const Offset(300, 400));

    p.setAvPlanMargins(plan.id, const EdgeInsets.fromLTRB(200, 0, 0, 0));
    p.setAvPlanMargins(plan.id, EdgeInsets.zero);

    expect(p.avFloorPlanById(plan.id)!.markerFor(loc.id),
        const Offset(300, 400));
  });

  test('a negative margin is not a margin', () {
    final p = room();
    final plan = p.addAvFloorPlan(
      const FloorPlan(id: '', name: 'L1', imageSize: Size(1200, 900)),
    );
    p.setAvPlanMargins(plan.id, const EdgeInsets.fromLTRB(-50, 0, -10, 0));
    expect(p.avFloorPlanById(plan.id)!.margins, EdgeInsets.zero);
  });
}
