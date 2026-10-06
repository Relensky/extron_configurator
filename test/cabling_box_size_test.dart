import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/cabling_view.dart';

/// Boxes on the cabling drawing grow to show all of their text, and can be
/// dragged to a size of their own.
void main() {
  test('a box grows with its text', () {
    const short = CablingBox(id: 'box:1', label: 'Lectern');
    final long = short.copyWith(
      body: List.filled(12, '6x Cat 6a to the rack, labeled per the schedule')
          .join('\n'),
    );
    expect(long.size.height, greaterThan(short.size.height));
    expect(short.size, const Size(180, 66));

    final note = CablingBox(
      id: 'box:2',
      label: 'Scope',
      kind: CablingBoxKind.note,
      body: 'Supercalifragilisticexpialidocious ' * 40,
    );
    // Narrowing a note makes it taller rather than cutting the text off.
    final narrow = note.copyWith(customSize: const Size(120, 60));
    expect(narrow.size.width, 120);
    expect(narrow.size.height, greaterThan(note.size.height));
  });

  test('a dragged size is kept, but never shorter than the text', () {
    const box = CablingBox(id: 'box:1', label: 'Lectern');
    final big = box.copyWith(customSize: const Size(300, 200));
    expect(big.size, const Size(300, 200));
    final tiny = box.copyWith(customSize: const Size(300, 1));
    expect(tiny.size.height, greaterThanOrEqualTo(CablingBox.kMinSize.height));
  });

  test('a box size saves, undoes and fits back to its text', () {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final box = p.addCablingBox(kind: CablingBoxKind.note, label: 'Scope');
    p.setCablingBoxSize(box.id, const Size(400, 300));
    CablingBox drawn() =>
        p.cablingDrawing.boxes.firstWhere((b) => b.id == box.id);
    expect(drawn().size, const Size(400, 300));

    final saved = p.avCabling.toJson();
    expect(saved['sizes'], {
      box.id: {'w': 400.0, 'h': 300.0},
    });
    final back = CablingOverrides()..readJson(saved);
    expect(back.sizes[box.id], const Size(400, 300));

    p.setCablingBoxSize(box.id, null);
    expect(drawn().customSize, isNull);
  });

  testWidgets('a selected box is resized by its corner', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final box = p.addCablingBox(
      kind: CablingBoxKind.note,
      label: 'Scope',
      pos: const Offset(200, 200),
    );
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

    final handle = find.byKey(ValueKey('cabling_resize_${box.id}'));
    expect(handle, findsNothing);
    await tester.tap(find.text('Scope'));
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);

    final before = p.cablingDrawing.boxes
        .firstWhere((b) => b.id == box.id)
        .size;
    await tester.drag(handle, const Offset(120, 80));
    await tester.pumpAndSettle();
    final after = p.avCabling.sizes[box.id]!;
    expect(after.width, greaterThan(before.width + 60));
    expect(tester.takeException(), isNull);
  });
}
