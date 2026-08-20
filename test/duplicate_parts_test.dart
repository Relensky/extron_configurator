import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/device_editor_view.dart';
import 'package:extron_configurator/device_merge.dart';

/// ============================================================================
///  ONE PART NUMBER, ONE ENTRY
/// ============================================================================
///  The catalog is keyed by model NAME, and a name is whatever the page an
///  entry was imported from called it. "IN1608" off the price list and
///  "IN1608 xi" off the product site are one box in two entries — one with the
///  price, the other with the connectors — and the part number they share is
///  the only thing that says so. Left alone they drift, and a room is quoted
///  off whichever name the engineer happened to pick.
/// ============================================================================
void main() {
  AvPort port(String id) => AvPort(
        id: id,
        label: id.toUpperCase(),
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
      );

  AvDeviceTemplate entry(
    String model, {
    String partNumber = '',
    String category = '',
    double price = 0,
    double educationPrice = 0,
    int rackUnits = 0,
    List<AvPort> ports = const [],
  }) =>
      AvDeviceTemplate(
        model: model,
        partNumber: partNumber,
        category: category,
        price: price,
        educationPrice: educationPrice,
        rackUnits: rackUnits,
        ports: ports,
      );

  AvDeviceLibrary libraryOf(List<AvDeviceTemplate> entries) {
    final library = AvDeviceLibrary.empty();
    for (final e in entries) {
      library.upsert(e);
    }
    return library;
  }

  /// The catalog's two halves of one switcher.
  AvDeviceLibrary twoHalves() => libraryOf([
        entry('IN1608', partNumber: '60-1238-81', price: 4320),
        entry(
          'IN1608 xi',
          partNumber: '60-1238-81',
          category: 'DTP Systems',
          rackUnits: 1,
          ports: [port('hdmi_1'), port('hdmi_2')],
        ),
      ]);

  group('finding them', () {
    test('two entries wearing one part number are a group', () {
      final groups = twoHalves().duplicateParts;
      expect(groups, hasLength(1));
      expect(groups.single.partNumber, '60-1238-81');
      expect(groups.single.entries.map((t) => t.model),
          containsAll(['IN1608', 'IN1608 xi']));
    });

    test('case and spacing on a SKU are noise', () {
      final groups = libraryOf([
        entry('A', partNumber: '60-1238-81'),
        entry('B', partNumber: ' 60-1238-81 '),
        entry('C', partNumber: '60-1238-81'.toLowerCase()),
      ]).duplicateParts;
      expect(groups.single.entries, hasLength(3));
    });

    test('a placeholder is not a part number', () {
      // Four Quantum Ultra frames all say "Custom", which means "quoted per
      // job" — reporting them as duplicates of each other is noise, and
      // merging them would be wrong.
      final groups = libraryOf([
        entry('Quantum Ultra 305', partNumber: 'Custom'),
        entry('Quantum Ultra 610', partNumber: 'Custom'),
        entry('Quantum Ultra II 305', partNumber: 'Custom'),
      ]).duplicateParts;
      expect(groups, isEmpty);
    });

    test('a clean catalog reports nothing', () {
      final groups = libraryOf([
        entry('A', partNumber: '60-1'),
        entry('B', partNumber: '60-2'),
        entry('C'), // no part number at all
      ]).duplicateParts;
      expect(groups, isEmpty);
    });

    test('the field warning names the other entries', () {
      final library = twoHalves();
      final others = library.othersWithPartNumber(
        '60-1238-81',
        exceptModel: 'IN1608',
      );
      expect(others.map((t) => t.model), ['IN1608 xi']);
      // And an entry is never a duplicate of itself.
      expect(
        library.othersWithPartNumber('60-1238-81', exceptModel: 'IN1608 xi'),
        hasLength(1),
      );
    });
  });

  group('folding them into one', () {
    test('gaps in the keeper arrive ticked, disagreements do not', () {
      final library = twoHalves();
      final keeper = library.templateForModel('IN1608')!;
      final diffs = duplicateDiffs(keeper, [
        library.templateForModel('IN1608 xi')!,
      ]);
      final fields = {for (final f in diffs.single.fields) f.field: f};

      // The keeper has no category, no rack height and no connectors: taking
      // them loses nothing, so they are already ticked.
      expect(fields[DeviceField.category]!.selected, isTrue);
      expect(fields[DeviceField.rackUnits]!.selected, isTrue);
      expect(fields[DeviceField.ports]!.selected, isTrue);
      // And the price is not offered at all — the other entry hasn't got one,
      // so there is nothing to take.
      expect(fields.containsKey(DeviceField.price), isFalse);
    });

    test('a disagreement is a decision, not a default', () {
      final library = libraryOf([
        entry('Mine', partNumber: '60-1', price: 4320),
        entry('Theirs', partNumber: '60-1', price: 5000),
      ]);
      final diffs = duplicateDiffs(library.templateForModel('Mine')!, [
        library.templateForModel('Theirs')!,
      ]);
      final price =
          diffs.single.fields.firstWhere((f) => f.field == DeviceField.price);
      expect(price.selected, isFalse, reason: 'a typed price is not a gap');
      expect(price.mine, '4320.00');
      expect(price.theirs, '5000.00');
    });

    test('the merged entry keeps the price and gains the connectors', () {
      final library = twoHalves();
      final keeper = library.templateForModel('IN1608')!;
      final removed = applyDuplicateMerge(
        library,
        keeper,
        duplicateDiffs(keeper, [library.templateForModel('IN1608 xi')!]),
      );

      expect(removed, 1);
      expect(library.templateForModel('IN1608 xi'), isNull,
          reason: 'the absorbed entry is gone, not left beside the winner');
      final merged = library.templateForModel('IN1608')!;
      expect(merged.price, 4320);
      expect(merged.ports, hasLength(2));
      expect(merged.category, 'DTP Systems');
      expect(merged.rackUnits, 1);
      expect(library.duplicateParts, isEmpty);
      // It is the user's entry now, so it is written on the next save.
      expect(merged.custom, isTrue);
    });

    test('nothing ticked still collapses the group', () {
      final library = twoHalves();
      final keeper = library.templateForModel('IN1608')!;
      final diffs = duplicateDiffs(keeper, [
        library.templateForModel('IN1608 xi')!,
      ]);
      for (final f in diffs.single.fields) {
        f.selected = false;
      }
      applyDuplicateMerge(library, keeper, diffs);
      expect(library.templateForModel('IN1608')!.ports, isEmpty);
      expect(library.templateForModel('IN1608 xi'), isNull);
    });

    test('three entries fold into one in a single pass', () {
      final library = libraryOf([
        entry('A', partNumber: '60-1', price: 100),
        entry('B', partNumber: '60-1', category: 'Matrix'),
        entry('C', partNumber: '60-1', rackUnits: 3),
      ]);
      final keeper = library.templateForModel('A')!;
      final removed = applyDuplicateMerge(
        library,
        keeper,
        duplicateDiffs(keeper, [
          library.templateForModel('B')!,
          library.templateForModel('C')!,
        ]),
      );
      expect(removed, 2);
      final merged = library.templateForModel('A')!;
      expect(merged.price, 100);
      expect(merged.category, 'Matrix');
      expect(merged.rackUnits, 3);
      expect(library.modelCount, 1);
    });

    test('the education price crosses too', () {
      // It used to be the one published figure a merge could not carry, which
      // reads as "not on education pricing" rather than "nobody copied it".
      final library = libraryOf([
        entry('A', partNumber: '60-1', price: 4320),
        entry('B', partNumber: '60-1', educationPrice: 2500),
      ]);
      final keeper = library.templateForModel('A')!;
      applyDuplicateMerge(library, keeper,
          duplicateDiffs(keeper, [library.templateForModel('B')!]));
      expect(library.templateForModel('A')!.educationPrice, 2500);
    });
  });

  // ---------------------------------------------------------------------------
  //  THE CATALOG TAB
  // ---------------------------------------------------------------------------
  group('the Device Editor', () {
    Future<AppStateProvider> pumpEditor(
      WidgetTester tester,
      AvDeviceLibrary library,
    ) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final p = AppStateProvider(autoLoadSettings: false)
        ..settingsLoaded = true
        ..firstRunSetupNeeded = false
        ..avDeviceLibrary = library;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(
            home: Scaffold(body: DeviceEditorView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return p;
    }

    testWidgets('says nothing when the catalog is clean', (tester) async {
      await pumpEditor(tester, libraryOf([entry('A', partNumber: '60-1')]));
      expect(find.byKey(const ValueKey('catalog_duplicates')), findsNothing);
    });

    testWidgets('warns, and merges from the warning', (tester) async {
      final library = twoHalves();
      await pumpEditor(tester, library);

      final warning = find.byKey(const ValueKey('catalog_duplicates'));
      expect(warning, findsOneWidget);
      expect(find.text('1 duplicate part number'), findsOneWidget);

      await tester.tap(warning);
      await tester.pumpAndSettle();
      expect(find.text('Duplicate part numbers'), findsOneWidget);
      // One group, so it opens itself rather than making somebody click.
      expect(find.textContaining('Merge into'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dup_merge_60-1238-81')));
      await tester.pumpAndSettle();

      expect(library.duplicateParts, isEmpty);
      expect(library.templateForModel('IN1608 xi'), isNull);
      expect(library.templateForModel('IN1608')!.ports, hasLength(2));

      await tester.tap(find.byKey(const ValueKey('dup_close')));
      await tester.pumpAndSettle();
      // The count is gone from the toolbar with the duplicates.
      expect(find.byKey(const ValueKey('catalog_duplicates')), findsNothing);
      expect(find.textContaining('Save catalog to write it'), findsOneWidget);
    });

    testWidgets('the entry being edited says so, and offers the fix',
        (tester) async {
      final library = twoHalves();
      await pumpEditor(tester, library);

      // Open IN1608 in the form: the warning belongs beside the field that
      // caused it, not only in a count on the toolbar.
      await tester.tap(find.text('IN1608').first);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Part 60-1238-81 is also on IN1608 xi'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('entry_duplicate_merge')));
      await tester.pumpAndSettle();
      expect(find.text('Duplicate part numbers'), findsOneWidget);
      // Opened from an entry, so its group is the one already open.
      expect(find.textContaining('Merge into'), findsOneWidget);
    });

    testWidgets('the keeper can be the other one', (tester) async {
      final library = twoHalves();
      await pumpEditor(tester, library);
      await tester.tap(find.byKey(const ValueKey('catalog_duplicates')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('dup_keep_60-1238-81_IN1608 xi')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dup_merge_60-1238-81')));
      await tester.pumpAndSettle();

      // The name the rooms use is the one that survives, and this time that
      // is the xi.
      expect(library.templateForModel('IN1608'), isNull);
      final merged = library.templateForModel('IN1608 xi')!;
      expect(merged.ports, hasLength(2));
      expect(merged.price, 4320, reason: 'the price came across from IN1608');
    });
  });
}
