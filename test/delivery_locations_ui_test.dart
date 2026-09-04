import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p2;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/delivery_locations.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/project_view.dart';

/// The saved places and the bulk move, driven the way somebody uses them.
///
/// The model tests next door prove the record is right; what these guard is
/// the wiring - a place set up in settings that never reaches the delivery
/// log, a tick that selects nothing, and a move that changes the rows without
/// leaving anything behind saying where they had been.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('places_ui_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final stem in ['bss101', 'bss103']) {
      final file = '${dir.path}/${stem}_config.json';
      File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
      p.addRoomToProject(file);
    }
    return p;
  }

  Future<void> pumpPane(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_deliveries')));
    await tester.pumpAndSettle();
  }

  /// showTimedSnackBar arms a timer past the bar's own duration, and the tree
  /// cannot be torn down with it still pending.
  Future<void> letTheSnackBarGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  group('the delivery log', () {
    testWidgets('ticking two rows offers to move them, and moves them', (
      tester,
    ) async {
      final p = withProject();
      p.deliveryLocations.add(
        name: 'MLIB 031',
        use: DeliveryLocationUse.storage,
      );
      final a = p.addProjectDelivery(
        itemName: 'Wall plate',
        qty: 6,
        location: 'Bessey loading dock',
      );
      final b = p.addProjectDelivery(
        itemName: 'Ceiling mount',
        qty: 3,
        location: 'Bessey loading dock',
      );
      await pumpPane(tester, p);

      // Nothing ticked, no bar: a bulk control above an untouched list is one
      // more thing between somebody and the log.
      expect(
        find.byKey(const ValueKey('deliveries_selected_count')),
        findsNothing,
      );

      await tester.tap(find.byKey(ValueKey('delivery_select_${a.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('delivery_select_${b.id}')));
      await tester.pumpAndSettle();

      // The bar says how many, and where they all are now.
      expect(
        find.text('2 deliveries selected  ·  On site - Bessey loading dock'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('deliveries_selection_move')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('move_deliveries_dialog')),
          findsOneWidget);

      // The saved place is one press away rather than typed.
      await tester.tap(find.byKey(const ValueKey('delivery_location_pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MLIB 031').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('move_deliveries_save')));
      await tester.pumpAndSettle();

      for (final id in [a.id, b.id]) {
        final row = p.project.deliveryById(id)!;
        expect(row.state, DeliveryState.stored);
        expect(row.location, 'MLIB 031');
        // AND THE ROW STILL SAYS WHERE IT CAME FROM, signed and timed.
        expect(
          row.notes.single.text,
          'Moved from On site - Bessey loading dock to In storage - MLIB 031.',
        );
        expect(row.notes.single.user, isNotNull);
      }
      await letTheSnackBarGo(tester);
    });

    testWidgets('the header box ticks the whole log and clears it again', (
      tester,
    ) async {
      final p = withProject();
      p.addProjectDelivery(itemName: 'Wall plate', qty: 6);
      p.addProjectDelivery(itemName: 'Ceiling mount', qty: 3);
      await pumpPane(tester, p);

      await tester.tap(find.byKey(const ValueKey('delivery_select_all')));
      await tester.pumpAndSettle();
      expect(find.text('2 deliveries selected  ·  On site'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('deliveries_selection_clear')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('deliveries_selected_count')),
        findsNothing,
      );
    });

    testWidgets('a saved place is one press away when a lot goes into store', (
      tester,
    ) async {
      final p = withProject();
      p.deliveryLocations.add(
        name: 'MLIB 031',
        address: 'Library basement',
        use: DeliveryLocationUse.storage,
      );
      final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 6);
      await pumpPane(tester, p);

      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('delivery_state_${row.id}')),
          matching: find.text('In storage'),
        ),
      );
      await tester.pumpAndSettle();

      // The chip fills the box, so the place is not retyped into a second
      // spelling of itself.
      await tester.tap(find.byKey(const ValueKey('delivery_where_chip_MLIB 031')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delivery_where_save')));
      await tester.pumpAndSettle();

      expect(p.project.deliveryById(row.id)!.location, 'MLIB 031');
    });
  });

  group('the settings side', () {
    testWidgets('the editor adds a place, and it reaches the delivery log', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: AppSettingsView())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('edit_delivery_locations')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      // scrollUntilVisible stops as soon as the row EXISTS, which can leave it
      // half under the bottom edge - and a tap there lands on nothing. Where
      // it stops moves whenever anything above it on the tab changes height.
      await tester.ensureVisible(
        find.byKey(const ValueKey('edit_delivery_locations')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit_delivery_locations')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('delivery_locations_dialog')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('delivery_location_new')),
        'Central Stores',
      );
      await tester.tap(find.byKey(const ValueKey('delivery_location_add')));
      await tester.pumpAndSettle();

      expect(p.deliveryLocations.byName('Central Stores'), isNotNull);
      // And it is offered on the next delivery without anything else being
      // done to it - the whole point of setting one up.
      expect(
        [for (final c in p.deliveryPlacesFor(storage: false)) c.name],
        ['Central Stores'],
      );
    });

  });

  group('the path setting', () {
    test('blank falls back to the root folder', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = dir.path;
      expect(
        p.effectiveDeliveryLocationsPath,
        p2.join(dir.path, 'delivery_locations.json'),
      );
    });

    test('a chosen path wins, even before anything is read from it', () {
      // A list pointed at a share with no file in it yet is a first save INTO
      // the share, not a stray copy left in the root folder.
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = dir.path
        ..deliveryLocationsFilePath = '${dir.path}/shared/places.json';
      expect(
        p.effectiveDeliveryLocationsPath,
        '${dir.path}/shared/places.json',
      );
    });

    test('it survives a save and a reload of the settings file', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..deliveryLocationsFilePath = '${dir.path}/places.json';
      final saved = jsonDecode(jsonEncode(p.settingsAsJson())) as Map;
      expect(saved['deliveryLocationsFilePath'], '${dir.path}/places.json');
    });

    test('saving writes the file the path points at, folders and all', () async {
      final target = '${dir.path}/shared/delivery_locations.json';
      final p = AppStateProvider(autoLoadSettings: false)
        ..deliveryLocationsFilePath = target;
      p.deliveryLocations.add(name: 'MLIB loading dock');

      expect(await p.saveDeliveryLocations(), target);
      final written = jsonDecode(File(target).readAsStringSync()) as Map;
      expect((written['locations'] as List).single['name'], 'MLIB loading dock');
    });

    test('the list is read from it', () async {
      final shared = '${dir.path}/shared.json';
      await File(shared).writeAsString(
        jsonEncode({
          'locations': [
            {'name': 'Central Stores', 'address': '1 Campus Drive'},
          ],
        }),
      );
      final p = AppStateProvider(autoLoadSettings: false)
        ..deliveryLocationsFilePath = shared;
      await p.loadDeliveryLocations();

      expect(p.deliveryLocations.byName('Central Stores')?.address,
          '1 Campus Drive');
      // And the editor writes back to the same file rather than dropping a
      // second list beside the app.
      expect(p.effectiveDeliveryLocationsPath, shared);
    });
  });
}
