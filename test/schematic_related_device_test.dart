import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schematic_view.dart';

/// The control schematic is DERIVED from the config, so it could only ever
/// draw what the processor talks to. The building switch the processor lands
/// on, the room PC, the UPS the rack is fed from — all real, all absent, and
/// the reader was left to infer them from a line disappearing off the box.
///
/// A hand-added box fills that in. It is deliberately NOT a controlled device:
/// dashed rather than solid, in its own grey rather than a connection colour,
/// and reported under its own heading rather than as a device with eight blank
/// columns where its IP and protocol would go.
void main() {
  AppStateProvider room() => AppStateProvider(autoLoadSettings: false)
    ..roomConfig = {
      'SYSTEM_SETUP': {
        'gui_full_room_name': 'Test Room',
        'processor1': 'MainProcessor',
        'dev_projectors': '1',
      },
      'PROJECTORDEVICE_1': {
        'name': 'Projector 1',
        'model': 'VPL-PHZ60',
        'com_type': 'Network',
        'ip_address': '10.0.0.5',
        'protocol': 'TCP',
      },
    };

  group('a box for equipment the control system does not talk to', () {
    test('lands on the diagram, drawn as related rather than controlled', () {
      final p = room();
      final id = p.addSchematicExtraNode(
        title: 'Building network switch',
        subtitle: 'Cisco 9200 • IDF 2B',
        icon: 'switch',
      );
      expect(id, 'EXTRA_1');

      final model = SchematicModel.build(p);
      final node = model.nodeById(id)!;
      expect(node.title, 'Building network switch');
      expect(node.subtitle, 'Cisco 9200 • IDF 2B');
      expect(node.related, isTrue);
      expect(node.icon, kRelatedNodeIcons['switch']!.icon);
      // It carries no connection of its own: the config says nothing about it,
      // so nothing may be claimed about how the processor reaches it.
      expect(model.edges.any((e) => e.fromId == id || e.toId == id), isFalse);
    });

    test('a nameless box is refused rather than drawn', () {
      final p = room();
      expect(p.addSchematicExtraNode(title: '   '), '');
      expect(p.schematicExtraNodes, isEmpty);
    });

    test('can be joined to the diagram with the ordinary line tool', () {
      final p = room();
      final id = p.addSchematicExtraNode(title: 'Room PC');
      p.addSchematicLink(id, 'PROCESSOR', '42A5F5', 'USB');

      final model = SchematicModel.build(p);
      final drawn = model.edges.singleWhere((e) => e.fromId == id);
      expect(drawn.toId, 'PROCESSOR');
      expect(drawn.label, 'USB');
      expect(drawn.custom, isTrue);
    });

    test('never takes an id the diagram generates for itself', () {
      // EXTRA_n cannot collide with a device key either — those are the
      // config's own section names.
      final p = room();
      for (var i = 0; i < 3; i++) {
        p.addSchematicExtraNode(title: 'Box $i');
      }
      final ids = [for (final n in p.schematicExtraNodes) n['id']];
      expect(ids, ['EXTRA_1', 'EXTRA_2', 'EXTRA_3']);
      expect(ids.toSet(), hasLength(3));
      expect(
        SchematicModel.build(p).nodes.map((n) => n.id).toSet(),
        hasLength(SchematicModel.build(p).nodes.length),
      );
    });

    test('renaming keeps the id, so the lines drawn to it survive', () {
      final p = room();
      final id = p.addSchematicExtraNode(title: 'Switch');
      p.addSchematicLink('PROCESSOR', id, '42A5F5', 'uplink');

      p.updateSchematicExtraNodeAt(0, title: 'Building switch', icon: 'switch');

      expect(p.schematicExtraNodes.single['id'], id);
      final model = SchematicModel.build(p);
      expect(model.nodeById(id)!.title, 'Building switch');
      expect(model.edges.any((e) => e.toId == id), isTrue);
    });

    test('removing one takes its lines and its dragged spot with it', () {
      // Left behind, they would be inherited by whatever box next took the id.
      final p = room();
      final id = p.addSchematicExtraNode(title: 'UPS');
      p.addSchematicLink(id, 'PROCESSOR', '42A5F5', 'power');
      p.setSchematicPosition(id, const Offset(40, 500));

      p.removeSchematicExtraNodeAt(0);

      expect(p.schematicExtraNodes, isEmpty);
      expect(p.schematicLinks, isEmpty);
      expect(p.schematicPositions.containsKey(id), isFalse);
    });

    test('is on the undo stack like every other layout edit', () {
      final p = room();
      p.addSchematicExtraNode(title: 'Room PC');
      expect(p.schematicUndoLabel, 'Add related device');

      p.removeSchematicExtraNodeAt(0);
      expect(p.schematicExtraNodes, isEmpty);

      expect(p.undoSchematic(), 'Remove related device');
      expect(p.schematicExtraNodes.single['title'], 'Room PC');
      expect(p.undoSchematic(), 'Add related device');
      expect(p.schematicExtraNodes, isEmpty);
    });
  });

  group('the report', () {
    test('lists related equipment apart from the controlled devices', () {
      final p = room();
      final id = p.addSchematicExtraNode(
        title: 'Building network switch',
        subtitle: 'Cisco 9200',
        icon: 'switch',
      );
      p.addSchematicLink(id, 'PROCESSOR', '42A5F5', 'uplink');

      final sections = reportSections(p, SchematicModel.build(p));
      final related =
          sections.singleWhere((s) => s.title == 'Related Equipment');
      expect(related.header, ['Name', 'Detail', 'Connected To']);
      expect(related.rows.single, [
        'Building network switch',
        'Cisco 9200',
        'Processor',
      ]);

      // And it is NOT one of the devices the processor drives.
      final devices = sections.singleWhere((s) => s.title == 'Devices');
      expect(
        devices.rows.map((r) => r.first),
        isNot(contains('Building network switch')),
      );
      // The device count is still the count of controlled devices.
      final system = sections.singleWhere((s) => s.title == 'System');
      expect(
        system.rows.singleWhere((r) => r.first == 'Device Count')[1],
        '1',
      );
    });

    test('says nothing at all when the room has no related equipment', () {
      final sections = reportSections(room(), SchematicModel.build(room()));
      expect(sections.any((s) => s.title == 'Related Equipment'), isFalse);
    });
  });

  group('the sidecar', () {
    late Directory dir;
    late String configPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('schematic_extra_test_');
      configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('carries the hand-added boxes there and back', () async {
      final p = room()..currentConfigPath = configPath;
      final id = p.addSchematicExtraNode(
        title: 'Building network switch',
        subtitle: 'Cisco 9200',
        icon: 'switch',
      );
      p.addSchematicLink(id, 'PROCESSOR', '42A5F5', 'uplink');
      expect(await p.saveSchematicLayout(), isNotEmpty);

      final back = room()..currentConfigPath = configPath;
      back.loadSchematicLayoutForCurrentConfig();

      expect(back.schematicExtraNodes.single, {
        'id': id,
        'title': 'Building network switch',
        'subtitle': 'Cisco 9200',
        'icon': 'switch',
      });
      expect(back.hasSchematicLayout, isTrue);
      expect(SchematicModel.build(back).nodeById(id)!.related, isTrue);
    });

    test('drops an entry with no id or no name instead of drawing a blank', () {
      File(path.join(dir.path, 'BSS103_config_control_schematic.json'))
          .writeAsStringSync(jsonEncode({
        'extraNodes': [
          {'id': 'EXTRA_1', 'title': 'Room PC'},
          {'id': 'EXTRA_2'},
          {'title': 'No id'},
          'not even a map',
        ],
      }));

      final p = room()..currentConfigPath = configPath;
      p.loadSchematicLayoutForCurrentConfig();

      expect(p.schematicExtraNodes, hasLength(1));
      expect(p.schematicExtraNodes.single['title'], 'Room PC');
      // The absent icon falls back rather than drawing nothing.
      expect(
        SchematicModel.build(p).nodeById('EXTRA_1')!.icon,
        kRelatedNodeIcons[kDefaultRelatedNodeIcon]!.icon,
      );
    });
  });

  group('the Control Schematic tab', () {
    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: SchematicView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers Add device in edit mode, and draws what it adds', (
      tester,
    ) async {
      final p = room();
      await pump(tester, p);

      // Not on the toolbar until the diagram is being edited.
      expect(find.byKey(const ValueKey('schematic_add_device')), findsNothing);
      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schematic_add_device')));
      await tester.pumpAndSettle();

      expect(find.text('Add Device'), findsWidgets);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Building network switch',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('related_icon_switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add Device'));
      await tester.pumpAndSettle();

      expect(p.schematicExtraNodes.single['title'], 'Building network switch');
      expect(p.schematicExtraNodes.single['icon'], 'switch');
      // On the drawing, and explained in the key.
      expect(find.text('Building network switch'), findsWidgets);
      expect(find.text(kRelatedLegendLabel), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('will not add a box with no name', (tester) async {
      final p = room();
      await pump(tester, p);
      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schematic_add_device')));
      await tester.pumpAndSettle();

      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Add Device'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('the key stays quiet on a room with none', (tester) async {
      await pump(tester, room());
      expect(find.text(kRelatedLegendLabel), findsNothing);
    });
  });
}
