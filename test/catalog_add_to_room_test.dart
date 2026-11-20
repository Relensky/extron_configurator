import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/catalog_add_to_room.dart';

/// Add to room, from a catalog entry: which rooms are offered, and the part
/// landing on the right list.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Room 1'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  test('nothing open, nowhere to add it', () {
    expect(roomChoicesFor(AppStateProvider(autoLoadSettings: false)), isEmpty);
  });

  test('a room open offers that room', () {
    expect(roomChoicesFor(room()), hasLength(1));
  });

  test('each kind lands on its own list', () {
    const display = AvDeviceTemplate(model: 'Display X', ports: []);
    const plate = AvDeviceTemplate(
      model: 'Vent plate',
      category: kCategoryRackHardware,
      rackUnits: 1,
      ports: [],
    );
    expect(costItemSetFor(display, 2).extraEquipment.single.qty, 2);
    expect(costItemSetFor(plate, 1).extraHardware.single.catalogModel,
        'Vent plate');
  });

  testWidgets('added to the open room from the dialog', (tester) async {
    final p = room();
    const display = AvDeviceTemplate(model: 'Display X', price: 900, ports: []);
    p.avDeviceLibrary = AvDeviceLibrary.empty()..upsert(display);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => addCatalogEntryToRoom(context, p, display),
                child: const Text('add'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('catalog_add_qty')), '3');
    await tester.tap(find.byKey(const ValueKey('catalog_add_go')));
    await tester.pumpAndSettle();
    final line = p.avCost.extraEquipment.single;
    expect(line.catalogModel, 'Display X');
    expect(line.qty, 3);
    expect(find.textContaining('Display X added to'), findsOneWidget);
  });
}
