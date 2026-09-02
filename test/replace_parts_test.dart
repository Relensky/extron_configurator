import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/av_rack_view.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/device_editor_view.dart';

/// ============================================================================
///  REPLACING A PART, AND RENAMING ONE
/// ============================================================================
///  A quote is where the wrong part gets noticed — it is the page people read
///  — and until now only a DEVICE could be replaced from it. The vent plate
///  that turns out to be a fan panel, and the lead that has to be plenum, were
///  both "delete it and add the right one", which loses the rail it was on and
///  the spares typed beside it.
///
///  The other half is the rename. Editing a catalog entry's NAME from the cost
///  page wrote a second entry and left the old one behind, so the rack item,
///  the box and the line all went on naming a part the catalog no longer had.
/// ============================================================================
void main() {
  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'Vent plate',
        category: kCategoryRackHardware,
        rackUnits: 1,
        price: 20,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'Fan panel 3U',
        category: kCategoryRackHardware,
        rackUnits: 3,
        price: 180,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'HDMI 25 plenum',
        category: kCategoryCable,
        cableSignal: SignalType.hdmi,
        cableLengthFt: 25,
        price: 90,
        ports: [],
      ),
    );

  /// A rack with two vent plates in it, a box on the diagram nobody has
  /// catalogd, and a config block for it.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = catalog();
    p.addAvNode(device('D1', 'Owner switch', 'CAT-9300'));
    final rack = p.addAvRack('Rack 1', 12);
    for (var u = 1; u <= 2; u++) {
      p.addAvRackItem(
        const RackItem(
          id: '',
          catalogModel: 'Vent plate',
          label: 'Vent plate',
          category: kCategoryRackHardware,
          rackUnits: 1,
          price: 20,
        ),
        rackId: rack.id,
        startU: u,
      );
    }
    return p;
  }

  CostEstimate priced(AppStateProvider p) => computeRoomCost(
    model: buildAvFlowModel(p),
    library: p.avDeviceLibrary,
    settings: p.avCost,
  );

  Future<void> pumpCost(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('renaming a catalog entry', () {
    test('takes the room with it', () {
      final p = room();
      p.roomConfig['PROJECTORDEVICE_1'] = {
        'name': 'Rack vent - Vent plate',
        'model': 'Vent plate',
        'module': '',
      };
      p.addAvNode(device('N1', 'Rack vent - Vent plate', 'Vent plate'));
      p.setAvCostPrice('rackitem:model:vent plate', 18);

      final moved = p.renameAvCatalogModel('Vent plate', '1RU fan panel');

      expect(moved.rackItems, 2, reason: 'both plates in the frame');
      expect(moved.nodes, 1);
      expect(moved.blocks, 1);
      for (final item in p.avRackItems) {
        expect(item.catalogModel, '1RU fan panel');
        expect(item.label, '1RU fan panel',
            reason: 'the label IS the name a rack item is read by');
      }
      expect(p.avNodeById('N1')!.model, '1RU fan panel');
      expect(
        p.avNodeById('N1')!.label,
        'Rack vent - 1RU fan panel',
        reason: 'only the model part of a name moves',
      );
      expect(p.roomConfig['PROJECTORDEVICE_1']['model'], '1RU fan panel');
      // The price was typed against this part, and this part is the one that
      // has been renamed — so it moves with it instead of being dropped.
      expect(p.avCost.priceOverrides['rackitem:model:1ru fan panel'], 18);
      expect(p.avCost.priceOverrides['rackitem:model:vent plate'], isNull);
    });

    test('does nothing when the name has not really changed', () {
      final p = room();
      final moved = p.renameAvCatalogModel('Vent plate', 'vent  plate');
      expect(moved.rackItems, 0);
      expect(p.avRackItems.first.catalogModel, 'Vent plate');
    });

    testWidgets('the cost page offers it, and the row follows', (tester) async {
      final p = room();
      await pumpCost(tester, p);

      // The hardware row's edit button. The one box on the diagram is not in
      // the catalog, so this is the only "edit the entry" button on the page.
      final edit = find.byWidgetPredicate(
        (w) =>
            w is IconButton &&
            w.icon is Icon &&
            (w.icon as Icon).icon == Icons.edit_note,
      );
      expect(edit, findsOneWidget);
      await tester.tap(edit, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Retyping the name is what raises the question — an edit that keeps the
      // name has nothing to replace.
      expect(
        find.byKey(const ValueKey('catalog_replace_everywhere')),
        findsNothing,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Vent plate'),
        '1RU fan panel',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('catalog_replace_everywhere')),
        findsOneWidget,
        reason: 'the option to replace has to be offered, not assumed',
      );

      await tester.tap(find.text('Save to catalog'));
      await tester.pumpAndSettle();

      expect(p.avDeviceLibrary.templateForModel('Vent plate'), isNull,
          reason: 'the old entry goes; this was a rename, not a second part');
      expect(p.avDeviceLibrary.templateForModel('1RU fan panel'), isNotNull);
      expect(p.avRackItems.every((i) => i.label == '1RU fan panel'), isTrue);
      // Which is the whole point: the quote says the new name too.
      expect(priced(p).hardware.single.description, '1RU fan panel');
    });

    testWidgets('unticking it leaves the old entry alone', (tester) async {
      final p = room();
      await pumpCost(tester, p);

      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is IconButton &&
              w.icon is Icon &&
              (w.icon as Icon).icon == Icons.edit_note,
        ),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Vent plate'),
        '1RU fan panel',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('catalog_replace_everywhere')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save to catalog'));
      await tester.pumpAndSettle();

      expect(p.avDeviceLibrary.templateForModel('Vent plate'), isNotNull);
      expect(p.avDeviceLibrary.templateForModel('1RU fan panel'), isNotNull);
      expect(p.avRackItems.every((i) => i.label == 'Vent plate'), isTrue);
    });
  });

  group('renaming on the Catalog tab', () {
    Future<void> pumpCatalog(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: DeviceEditorView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Opens the entry and types a new name into the model box, which is what
    /// a rename IS on this tab — there is no button for it.
    Future<void> retype(WidgetTester tester, String from, String to) async {
      await tester.tap(find.text(from).first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, from).last,
        to,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    testWidgets('asks about the open room, and takes it with it', (
      tester,
    ) async {
      final p = room();
      await pumpCatalog(tester, p);
      await retype(tester, 'Vent plate', '1RU fan panel');

      // Two plates in the frame, so there is something to ask about.
      expect(find.text('Rename "Vent plate" to "1RU fan panel"?'),
          findsOneWidget);
      expect(find.textContaining('2 items in the racks'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(p.avDeviceLibrary.templateForModel('1RU fan panel'), isNotNull);
      expect(p.avDeviceLibrary.templateForModel('Vent plate'), isNull);
      expect(p.avRackItems.every((i) => i.label == '1RU fan panel'), isTrue);
    });

    testWidgets('or renames the entry alone when told to', (tester) async {
      final p = room();
      await pumpCatalog(tester, p);
      await retype(tester, 'Vent plate', '1RU fan panel');

      await tester.tap(find.byKey(const ValueKey('catalog_rename_follow')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(p.avDeviceLibrary.templateForModel('1RU fan panel'), isNotNull);
      expect(p.avRackItems.every((i) => i.label == 'Vent plate'), isTrue,
          reason: 'unticked means unticked - the room keeps the old name');
    });

    testWidgets('cancel leaves the entry and the box alone', (tester) async {
      final p = room();
      await pumpCatalog(tester, p);
      await retype(tester, 'Vent plate', '1RU fan panel');

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(p.avDeviceLibrary.templateForModel('Vent plate'), isNotNull);
      expect(p.avDeviceLibrary.templateForModel('1RU fan panel'), isNull);
      // The box went back to the name the entry actually has. It used to keep
      // the typed one, which reads as a rename that happened.
      expect(find.widgetWithText(TextField, 'Vent plate'), findsWidgets);
    });

    testWidgets('a part the room does not use is renamed without a word', (
      tester,
    ) async {
      final p = room();
      await pumpCatalog(tester, p);
      await retype(tester, 'Fan panel 3U', 'Fan panel 3RU');

      expect(find.textContaining('Rename "Fan panel 3U"'), findsNothing,
          reason: 'nothing in the room to ask about');
      expect(p.avDeviceLibrary.templateForModel('Fan panel 3RU'), isNotNull);
    });
  });

  group('replacing rack hardware', () {
    test('reaches every one of them, and un-racks what no longer fits', () {
      final p = room();
      final tall = p.avDeviceLibrary.templateForModel('Fan panel 3U')!;
      // Two 1U plates on U1 and U2: a 3U panel cannot stand on either without
      // running into the other.
      final kept = [
        for (final item in List.of(p.avRackItems)) p.swapAvRackItem(item, tall),
      ];

      expect(p.avRackItems.every((i) => i.catalogModel == 'Fan panel 3U'),
          isTrue);
      expect(p.avRackItems.every((i) => i.rackUnits == 3), isTrue);
      expect(kept.where((k) => !k).length, greaterThan(0),
          reason: 'a part that no longer fits comes off its rail rather than '
              'overlapping its neighbor');
      // Off the rail, still in the room — nothing is deleted behind anybody.
      expect(p.avRackItems.length, 2);
    });

    testWidgets('from the quote, on the whole row at once', (tester) async {
      final p = room();
      await pumpCost(tester, p);

      final key = priced(p).hardware.single.key;
      await tester.tap(
        find.byKey(ValueKey('hw_swap_$key')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog_swap_Fan panel 3U')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog_swap_apply')));
      await tester.pumpAndSettle();

      expect(
        p.avRackItems.every((i) => i.catalogModel == 'Fan panel 3U'),
        isTrue,
        reason: 'the row is a group of items, and the swap is about all of it',
      );
      expect(priced(p).hardware.single.unitPrice, 180);
    });
  });

  group('replacing a cable lead', () {
    test('buys that length as the picked entry, spares and all', () {
      final p = room();
      p.addAvNode(device('SRC', 'PC', 'PC'));
      p.setAvCableSpares('cable:hdmi', 2);

      // Nothing is drawn, so the type's own line carries the spares.
      final before = priced(p).cabling.single;
      expect(before.key, 'cable:hdmi');
      expect(before.qty, 2);

      p.setAvCableEntry(SignalType.hdmi, 0, 'HDMI 25 plenum');
      final after = priced(p).cabling.single;
      expect(after.model, 'HDMI 25 plenum');
      expect(after.unitPrice, 90);

      // The key is built out of the entry, so it moved — and the spares have
      // to move with it or the room quietly buys two fewer leads.
      p.moveAvCableLine(from: before.key, to: after.key);
      expect(priced(p).cabling.single.qty, 2);
      expect(p.avCost.cableSpares[after.key], 2);
    });

    test('the choice is saved with the room', () {
      final settings = RoomCostSettings()
        ..cableEntries['hdmi@25ft'] = 'HDMI 25 plenum';
      expect(settings.isEmpty, isFalse);
      final back = RoomCostSettings()..readJson(settings.toJson());
      expect(back.cableEntries['hdmi@25ft'], 'HDMI 25 plenum');
    });
  });

  group('the rack elevation', () {
    testWidgets('right-click offers replace, edit and un-rack', (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = room();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: AvRackView(captureKey: GlobalKey(), editMode: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('Vent plate').first,
        buttons: kSecondaryButton,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Replace with...'), findsOneWidget);
      expect(find.text('Un-rack'), findsOneWidget);

      await tester.tap(find.text('Replace with...'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog_swap_Fan panel 3U')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog_swap_apply')));
      await tester.pumpAndSettle();

      expect(
        p.avRackItems.where((i) => i.catalogModel == 'Fan panel 3U').length,
        1,
        reason: 'the block that was clicked, and only it',
      );
    });
  });

  group('a part nothing can ever drive', () {
    test('is not a gap in the config', () {
      final p = room();
      p.avDeviceLibrary.upsert(
        const AvDeviceTemplate(
          model: 'AverMedia USB',
          category: 'Camera',
          neverControlled: true,
          ports: [],
        ),
      );
      p.addAvNode(device('U1', 'USB capture', 'AverMedia USB'));

      expect(
        p.avDevicesWithoutControl.map((d) => d.key),
        isNot(contains('U1')),
      );
      final gaps = driverGapSections(p, buildAvFlowModel(p));
      expect(
        gaps.expand((s) => s.rows).where((r) => r.contains('AverMedia USB')),
        isEmpty,
        reason: 'a warning that can never be acted on is one people learn to '
            'scroll past',
      );
      // The box nobody has said that about is still reported.
      expect(p.avDevicesWithoutControl.map((d) => d.key), contains('D1'));
    });

    test('is a fact about the product, so the catalog file carries it', () {
      final entry = AvDeviceTemplate.fromJson({
        'model': 'AverMedia USB',
        'neverControlled': true,
      });
      expect(entry.neverControlled, isTrue);
      expect(entry.toJson()['neverControlled'], true);
      expect(
        const AvDeviceTemplate(model: 'X', ports: []).toJson()
            .containsKey('neverControlled'),
        isFalse,
        reason: 'the flag only appears on the entries that set it',
      );
    });
  });
}
