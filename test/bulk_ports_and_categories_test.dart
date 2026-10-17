import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_port_editor.dart';

/// Adding many connectors at once, the no-module network switch category, and
/// categories people add themselves.
void main() {
  group('bulkAvPorts', () {
    test('48 network ports, both ways, on top', () {
      final ports = bulkAvPorts(
        count: 48,
        name: 'LAN',
        signal: SignalType.network,
        direction: PortDirection.bidirectional,
        side: PortSide.top,
      );
      expect(ports, hasLength(48));
      expect(ports.first.label, 'LAN 1');
      expect(ports.last.label, 'LAN 48');
      expect(ports.every((p) => p.signal == SignalType.network), isTrue);
      expect(
        ports.every((p) => p.direction == PortDirection.bidirectional),
        isTrue,
      );
      expect(ports.every((p) => p.side == PortSide.top), isTrue);
      expect(ports.map((p) => p.id).toSet(), hasLength(48));
    });

    test('ids never collide with ports already there', () {
      final first = bulkAvPorts(
        count: 4,
        name: 'LAN',
        signal: SignalType.network,
        direction: PortDirection.bidirectional,
        side: PortSide.left,
      );
      final again = bulkAvPorts(
        count: 4,
        name: 'LAN',
        signal: SignalType.network,
        direction: PortDirection.bidirectional,
        side: PortSide.left,
        existingIds: first.map((p) => p.id),
      );
      final all = {...first.map((p) => p.id), ...again.map((p) => p.id)};
      expect(all, hasLength(8));
    });

    test('numbering starts where asked and a blank name uses the type', () {
      final ports = bulkAvPorts(
        count: 2,
        name: ' ',
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
        start: 5,
      );
      expect(ports.map((p) => p.label), ['HDMI 5', 'HDMI 6']);
    });
  });

  testWidgets('the dialog returns the ports it describes', (tester) async {
    List<AvPort>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await showBulkPortDialog(context, existing: const []),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bulk_port_count')), '48');
    await tester.pump();
    expect(find.text('Adds 48: LAN 1 to LAN 48.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bulk_port_add')));
    await tester.pumpAndSettle();
    expect(result, hasLength(48));
    expect(result!.first.signal, SignalType.network);
    expect(result!.first.direction, PortDirection.bidirectional);
  });

  group('categories', () {
    test('the no-module switch is known but not tracked to a section', () {
      expect(kWellKnownCategories, contains(kCategoryStandaloneSwitch));
      expect(kTrackedCategories, isNot(contains(kCategoryStandaloneSwitch)));
      expect(isTrackedCategory(kCategoryStandaloneSwitch), isTrue);
      expect(categoryLimits(kCategoryStandaloneSwitch), contains('no control'));
    });

    test('added categories are offered, deduped and removable', () {
      final library = AvDeviceLibrary.empty();
      expect(library.addCategory('Lighting'), isTrue);
      expect(library.addCategory('lighting'), isFalse);
      expect(library.addCategory('Switcher'), isFalse);
      expect(library.addCategory('  '), isFalse);
      expect(library.categories, contains('Lighting'));
      expect(library.removeCategory('LIGHTING'), isTrue);
      expect(library.categories, isNot(contains('Lighting')));
    });

    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('catalog_categories');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('saved with the catalog and kept across two editors', () async {
      final path = '${dir.path}/av_devices.json';
      await File(path).writeAsString(jsonEncode({
        'devices': [
          {'model': 'Box', 'category': 'DSP', 'ports': <Object>[]},
        ],
      }));
      final a = await AvDeviceLibrary.readFile(path);
      final b = await AvDeviceLibrary.readFile(path);
      a.addCategory('Lighting');
      expect(a.differsFromBaseline, isTrue);
      expect(await a.save(), isNotEmpty);
      b.addCategory('Furniture');
      expect(await b.save(), isNotEmpty);

      final disk = await AvDeviceLibrary.readFile(path);
      expect(disk.addedCategories, ['Furniture', 'Lighting']);

      // A removal here is not undone by the file still holding it.
      disk.removeCategory('Lighting');
      expect(await disk.save(), isNotEmpty);
      final after = await AvDeviceLibrary.readFile(path);
      expect(after.addedCategories, ['Furniture']);
    });
  });
}
