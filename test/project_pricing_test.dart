import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_pricing.dart';

/// ============================================================================
///  PRICING A PART FROM THE PARTS LIST
/// ============================================================================
///  A job with three unpriced parts has a total that is short by an unknown
///  amount. The parts list is where that is visible, so it is where the fix
///  belongs — and there are two fixes, because there are two reasons a part has
///  no price:
///
///    * the CATALOG never had one, and the figure is a fact about the product;
///    * the figure is NEGOTIATED, and belongs to this job and no other.
///
///  Both are offered. The tests below hold the line that separates them: the
///  catalog route must not touch a room file, and the job route must not touch
///  the catalog.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_pricing'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvNode device(String id, String label, String model) => AvNode(
        id: id,
        label: label,
        model: model,
        pos: Offset.zero,
        ports: const [],
      );

  /// A room on disk carrying [nodes], with no prices anywhere.
  String writeRoom(String stem, String name, List<AvNode> nodes) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [for (final n in nodes) n.toJson()],
    }));
    return configPath;
  }

  /// Two rooms, both carrying the same unpriced product, plus one room that
  /// does not — the room that must NOT be written.
  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path
      ..avDevicesFilePath = path.join(dir.path, 'av_devices.json');
    // A catalog that knows the product but has never had a price for it, which
    // is exactly how a part reaches the list unpriced.
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'Display X',
        manufacturer: 'Generic',
        category: 'Display',
        ports: [],
      ));
    p.newProject(name: 'Pricing test');
    p.addRoomToProject(
      writeRoom('a', 'Room A', [device('n1', 'Display', 'Display X')]),
    );
    p.addRoomToProject(
      writeRoom('b', 'Room B', [device('n1', 'Display', 'Display X')]),
    );
    p.addRoomToProject(
      writeRoom('c', 'Room C', [device('n1', 'Camera', 'Camera Y')]),
    );
    return p;
  }

  MasterPartLine displayLine(ProjectEstimate estimate) => estimate.master
      .firstWhere((l) => l.model.toLowerCase() == 'display x');

  double onDisk(String stem, String key) {
    final f = File(path.join(dir.path, '${stem}_config_cost.json'));
    if (!f.existsSync()) return -1;
    final doc = jsonDecode(f.readAsStringSync()) as Map;
    final cost = doc['cost'] as Map?;
    final overrides = cost?['priceOverrides'] as Map?;
    return (overrides?[key] as num?)?.toDouble() ?? -1;
  }

  // -------------------------------------------------------------------------
  //  THE PART THE LIST IS TALKING ABOUT
  // -------------------------------------------------------------------------

  test('an unpriced part is reported, and knows which rooms carry it', () {
    final p = withProject();
    final estimate = p.priceProject();

    expect(estimate.unpricedParts, greaterThan(0));
    final line = displayLine(estimate);
    expect(line.unpriced, isTrue);

    // Two of the three rooms, and the keys THOSE rooms price by.
    expect(line.lineKeysByRoom, hasLength(2));
    expect(line.lineKeysByRoom.values.every((k) => k.isNotEmpty), isTrue);
    expect(roomsCarrying(p, line), hasLength(2));
  });

  // -------------------------------------------------------------------------
  //  THE CATALOG ROUTE
  // -------------------------------------------------------------------------

  group('save to catalog', () {
    test('prices every room from one figure, touching no room file', () async {
      final p = withProject();
      final before = File(path.join(dir.path, 'a_config_cost.json'));
      expect(before.existsSync(), isFalse);

      final saved = await priceInCatalog(
        provider: p,
        line: displayLine(p.priceProject()),
        price: 1200,
      );
      expect(saved, isNot(startsWith('Error')));

      final after = p.priceProject();
      expect(displayLine(after).unpriced, isFalse);
      expect(displayLine(after).unitPrice, 1200);
      // Two rooms x 1200.
      expect(after.grandTotal, 2400);

      expect(before.existsSync(), isFalse,
          reason: 'the catalog route must not write a room file');
    });

    test('keeps everything the catalog entry already had', () async {
      final p = withProject();
      await priceInCatalog(
        provider: p,
        line: displayLine(p.priceProject()),
        price: 1200,
      );

      final entry = p.avDeviceLibrary.templateForModel('Display X')!;
      expect(entry.price, 1200);
      expect(entry.manufacturer, 'Generic',
          reason: 'an upsert must not blank the fields it was not given');
      expect(entry.category, 'Display');
    });

    test('a part with no model says so instead of inventing an entry',
        () async {
      final p = withProject();
      final line = displayLine(p.priceProject());
      final blank = MasterPartLine(
        key: line.key,
        kind: line.kind,
        description: line.description,
        model: '',
        partNumber: '',
        manufacturer: '',
        category: '',
        qty: line.qty,
        total: line.total,
        unitPrice: 0,
        maxUnitPrice: 0,
        qtyByRoom: line.qtyByRoom,
        vendor: null,
        tagSource: line.tagSource,
        unpriced: true,
        lineKeysByRoom: line.lineKeysByRoom,
      );

      final result =
          await priceInCatalog(provider: p, line: blank, price: 500);
      expect(result, startsWith('Error'));
      expect(p.avDeviceLibrary.all, hasLength(1),
          reason: 'nothing was added to the catalog');
    });
  });

  // -------------------------------------------------------------------------
  //  THE THIS-JOB ROUTE
  // -------------------------------------------------------------------------

  group('price on this job only', () {
    test('writes the rooms that carry it and leaves the others alone',
        () async {
      final p = withProject();
      final line = displayLine(p.priceProject());

      final result =
          await priceAcrossProject(provider: p, line: line, price: 950);

      expect(result.roomsWritten, 2);
      expect(result.failures, isEmpty);
      expect(result.openRoomChanged, isFalse);

      final key = line.lineKeysByRoom.values.first.first;
      expect(onDisk('a', key), 950);
      expect(onDisk('b', key), 950);
      expect(File(path.join(dir.path, 'c_config_cost.json')).existsSync(),
          isFalse,
          reason: 'Room C does not carry this part');
    });

    test('the total follows, and the catalog does not', () async {
      final p = withProject();
      await priceAcrossProject(
        provider: p,
        line: displayLine(p.priceProject()),
        price: 950,
      );

      final after = p.priceProject();
      expect(displayLine(after).unpriced, isFalse);
      expect(after.grandTotal, 1900);
      expect(p.avDeviceLibrary.templateForModel('Display X')!.price, 0,
          reason: 'a negotiated figure must not become the list price');
    });

    test('the open room is changed on screen, not underneath the editor',
        () async {
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);
      final line = displayLine(p.priceProject());

      final result =
          await priceAcrossProject(provider: p, line: line, price: 950);

      expect(result.openRoomChanged, isTrue);
      expect(result.roomsWritten, 1, reason: 'only Room B was on disk');
      // On screen, and unsaved — the user gets to look before it is committed.
      expect(p.avCost.priceOverrides.values, contains(950.0));
      expect(p.roomHasUnsavedChanges, isTrue);
      // Its file still says nothing.
      expect(File(path.join(dir.path, 'a_config_cost.json')).existsSync(),
          isFalse);
    });

    test('a room whose file has gone is reported, not silently skipped',
        () async {
      final p = withProject();
      final line = displayLine(p.priceProject());
      File(path.join(dir.path, 'b_config.json')).deleteSync();

      final result =
          await priceAcrossProject(provider: p, line: line, price: 950);

      expect(result.roomsWritten, 1);
      expect(result.failures, hasLength(1));
      expect(result.failures.single, contains('b_config'));
    });

    test('a second price replaces the first rather than stacking', () async {
      final p = withProject();
      final line = displayLine(p.priceProject());
      await priceAcrossProject(provider: p, line: line, price: 950);
      await priceAcrossProject(
        provider: p,
        line: displayLine(p.priceProject()),
        price: 1100,
      );

      expect(p.priceProject().grandTotal, 2200);
    });
  });

  // -------------------------------------------------------------------------
  //  GETTING THERE FROM THE WARNING
  // -------------------------------------------------------------------------

  testWidgets('the warning opens the list of parts with no price',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = withProject()
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    p.selectTab(AppTab.project.index);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The count, and the fact that it is a button at all — a warning nobody
    // can press leaves somebody hunting a parts list for the rows it means.
    final warning = find.byKey(const ValueKey('project_warnings'));
    expect(warning, findsOneWidget);

    await tester.tap(warning);
    await tester.pumpAndSettle();

    // The parts pane, filtered to the ones with no price.
    expect(find.text('not priced'), findsWidgets);
    expect(find.textContaining('Display X'), findsWidgets);
    expect(find.textContaining('Camera Y'), findsWidgets,
        reason: 'both unpriced parts are listed');
  });
}
