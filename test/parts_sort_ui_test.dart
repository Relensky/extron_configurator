import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/part_sort.dart';
import 'package:extron_configurator/project_view.dart';

/// THE HEADINGS ON THE EQUIPMENT LIST ARE THE SORT.
///
/// part_sort_test.dart checks the ordering itself. This checks the only thing
/// that test cannot: that pressing a heading actually re-orders the rows on
/// screen, and that pressing it once more puts the grouped order back - because
/// a list somebody sorted by accident and could not un-sort has quietly lost
/// the grouping the estimate built it with.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_sort_ui'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Projector',
          model: 'PowerLite L610U',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
        AvNode(
          id: 'DISPLAYDEVICE_1',
          label: 'Display',
          model: 'Aquos 65',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
      ],
    }));
    return configPath;
  }

  AppStateProvider job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 1000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'Aquos 65',
        manufacturer: 'Sharp',
        category: 'Display',
        price: 400,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.addRoomToProject(writeRoom('r0', 'Bessey 101'));
    return p;
  }

  Future<void> openParts(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1700, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
    await tester.pumpAndSettle();
  }

  /// The part keys in the order their rows are actually laid out.
  List<String> rowOrder(WidgetTester tester, List<String> keys) {
    final placed = [
      for (final key in keys)
        if (find.byKey(ValueKey('part_select_$key')).evaluate().isNotEmpty)
          (
            key: key,
            y: tester.getTopLeft(find.byKey(ValueKey('part_select_$key'))).dy,
          ),
    ]..sort((a, b) => a.y.compareTo(b.y));
    return [for (final row in placed) row.key];
  }

  testWidgets('pressing a heading re-orders the rows, and pressing it again '
      'reverses them', (tester) async {
    final p = job();
    await openParts(tester, p);

    final master = p.priceProject().master;
    final keys = [for (final l in master) l.key];
    final byPrice = [...master]
      ..sort((a, b) => a.unitPrice.compareTo(b.unitPrice));
    final cheapestFirst = [for (final l in byPrice) l.key];

    await tester.tap(find.byKey(const ValueKey('parts_sort_unit')));
    await tester.pumpAndSettle();
    expect(rowOrder(tester, keys), cheapestFirst);

    await tester.tap(find.byKey(const ValueKey('parts_sort_unit')));
    await tester.pumpAndSettle();
    expect(rowOrder(tester, keys), cheapestFirst.reversed.toList());
  });

  testWidgets('a third press puts the grouped order back', (tester) async {
    final p = job();
    await openParts(tester, p);
    final keys = [for (final l in p.priceProject().master) l.key];
    final grouped = rowOrder(tester, keys);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('parts_sort_unit')));
      await tester.pumpAndSettle();
    }
    expect(rowOrder(tester, keys), grouped);
  });

  testWidgets('every column on the list is one of the headings', (tester) async {
    await openParts(tester, job());
    // A list where three of the seven headings sort is a list where somebody
    // presses the other four and concludes that none of them do.
    for (final key in PartSortKey.values) {
      if (key == PartSortKey.natural) continue;
      expect(
        find.byKey(ValueKey('parts_sort_${key.name}')),
        findsOneWidget,
        reason: '${kPartSortLabels[key]} should be pressable',
      );
    }
  });
}
