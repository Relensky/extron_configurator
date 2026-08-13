import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/cabling_view.dart';
import 'package:extron_configurator/room_locations.dart';

/// The cabling sheet places every caption itself, and places them well enough
/// that most are never touched. The ones that are touched are the ones the
/// drawing cannot reason about — a label over the bit of the sheet somebody is
/// pointing at, or where the next revision needs a note. Those have to be
/// movable, and a label moved by hand has to STAY moved when a box shifts.
void main() {
  /// A room with two locations and one run between them, which is one caption.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final a = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
    final b = p.addAvLocation(const RoomLocation(id: '', name: 'Rack'));
    p.addAvScreenSwitch(
      ScreenSwitch(
        id: '',
        label: 'Front screen',
        startLocationId: a.id,
        endLocationId: b.id,
        cableType: '18/2 plenum',
      ),
    );
    return p;
  }

  Future<void> pumpCabling(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CablingView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drags [what] by [step] four times over, pumping between moves. A single
  /// jump gives the gesture arena — the pad and the sheet's own pan — nothing
  /// to decide on, and the pan usually takes it.
  Future<void> dragInSteps(
    WidgetTester tester,
    Finder what,
    Offset step,
  ) async {
    final from = tester.getCenter(what);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 60));
    for (var i = 1; i <= 4; i++) {
      await gesture.moveTo(from + step * i.toDouble());
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Every caption pad on the drawing.
  Finder labels() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey &&
            (w.key as ValueKey).value.toString().startsWith('cabling_label_'),
      );

  testWidgets('a caption carries a pad that can be grabbed', (tester) async {
    final p = room();
    await pumpCabling(tester, p);
    expect(labels(), findsWidgets);
  });

  testWidgets('dragging one moves it and remembers where it was put',
      (tester) async {
    final p = room();
    await pumpCabling(tester, p);

    final label = labels().first;
    final before = tester.getTopLeft(label);
    // In steps, the way a pointer does it: the label and the sheet's own pan
    // are both watching, and one jump gives the arena nothing to decide on.
    await dragInSteps(tester, label, const Offset(20, 15));
    await tester.pumpAndSettle();

    // Stored as a nudge from the automatic spot, so the label follows its run
    // when a box moves rather than being left behind pointing at nothing.
    expect(p.avCabling.labelOffsets, isNotEmpty);
    final after = tester.getTopLeft(labels().first);
    expect(after.dx, greaterThan(before.dx));
    expect(after.dy, greaterThan(before.dy));
  });

  testWidgets('double-clicking a moved caption puts it back', (tester) async {
    final p = room();
    // Moved before the page is built, so the double-click is the only gesture
    // in this test and cannot be confused with the drag that preceded it.
    p.setCablingLabelOffset('loc:LOC_1|loc:LOC_2', const Offset(0, 120));
    await pumpCabling(tester, p);
    final moved = tester.getTopLeft(labels().first);

    // At a fixed point, twice: the pad moves with the label, so tapping "the
    // finder" twice can be two taps in two different places.
    final at = tester.getCenter(labels().first);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(at);
    await tester.pumpAndSettle();

    expect(p.avCabling.labelOffsets, isEmpty);
    // ...and the block on the page went back with it.
    expect(tester.getTopLeft(labels().first).dy, lessThan(moved.dy));
  });

  testWidgets('right-clicking a label takes that one off the sheet',
      (tester) async {
    final p = room();
    await pumpCabling(tester, p);
    expect(labels(), findsOneWidget);

    // ONE label, not all of them: a sheet regularly carries a run that needs
    // no caption while every other one does.
    await tester.tap(labels().first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(p.avCabling.hiddenLabels, isNotEmpty);
    expect(labels(), findsNothing);

    // A hidden caption cannot right-click itself back, so the way back is on
    // the toolbar — and it says how many came back.
    expect(find.textContaining('1 hidden'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cabling_labels')));
    await tester.pumpAndSettle();
    expect(p.avCabling.hiddenLabels, isEmpty);
    expect(labels(), findsOneWidget);
  });

  test('a hidden label survives a save and a reload of the sidecar', () {
    final p = room();
    p.setCablingLabelHidden('loc:LOC_1|loc:LOC_2', true);
    final json = p.avCabling.toJson();
    p.avCabling.clear();
    p.avCabling.readJson(json);
    expect(p.avCabling.hiddenLabels, contains('loc:LOC_1|loc:LOC_2'));
  });

  test('a moved label survives a save and a reload of the sidecar', () {
    final p = room();
    p.setCablingLabelOffset('loc:LOC_1|loc:LOC_2', const Offset(12, -8));
    final json = p.avCabling.toJson();

    p.avCabling.clear();
    expect(p.avCabling.labelOffsets, isEmpty);
    p.avCabling.readJson(json);
    expect(p.avCabling.labelOffsets['loc:LOC_1|loc:LOC_2'],
        const Offset(12, -8));
  });
}
