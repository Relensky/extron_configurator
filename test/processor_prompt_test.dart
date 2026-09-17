import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/processor_prompt.dart';
import 'package:extron_configurator/schematic_view.dart';

/// The control schematic waits for the room to have a processor.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'IPCP Pro 555',
          category: 'Control processor',
          ports: [],
        ),
      )
      ..upsert(
        const AvDeviceTemplate(model: 'Display X', category: 'Display', ports: []),
      );
    return p;
  }

  group('a room has a processor when', () {
    test('nothing says so, it does not', () {
      final p = room();
      addCatalogProcessor(p, 'Display X');
      expect(p.roomHasProcessor, isFalse);
    });

    test('one is drawn on the AV flow', () {
      final p = room();
      expect(addCatalogProcessor(p, 'IPCP Pro 555'), isNotNull);
      expect(p.roomHasProcessor, isTrue);
    });

    test('one is quoted on the cost page', () {
      final p = room()..addAvCostExtraEquipment(catalogModel: 'IPCP Pro 555');
      expect(p.roomHasProcessor, isTrue);
    });

    test('a deployment processor is chosen', () {
      final p = room()..selectedProcessor = {'roomName': 'BSS 103'};
      expect(p.roomHasProcessor, isTrue);
    });
  });

  test('the category matches however the catalog spells it', () {
    expect(isControlProcessorCategory('Control processor'), isTrue);
    expect(isControlProcessorCategory('control processors'), isTrue);
    expect(isControlProcessorCategory('Display'), isFalse);
  });

  testWidgets('the tab asks for a processor, then draws once one is added', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final p = room();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: SchematicView())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No processor in this room'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add_processor_from_catalog')));
    await tester.pumpAndSettle();
    // Only processors are offered.
    expect(find.text('IPCP Pro 555'), findsOneWidget);
    expect(find.text('Display X'), findsNothing);

    await tester.tap(find.text('IPCP Pro 555'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.pumpAndSettle();

    expect(p.avNodes.where((n) => n.model == 'IPCP Pro 555'), hasLength(1));
    expect(find.text('No processor in this room'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
