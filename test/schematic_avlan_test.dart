import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schematic_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  WHICH NETWORK A DROP IS ON
/// ============================================================================
///  The schematic ran every network device to the Network IDF, which is the
///  one thing about a room's networking somebody opens this tab to check, and
///  it was wrong for half of them. A device on 192. is not on the building
///  network — it is on the AV LAN, which is the processor's own port in most
///  of these rooms and a small switch of its own in the rest.
///
///  Which of the three cannot be read off the config, so the room records it,
///  and the drawing says so: an AV LAN drop carries the note, an IDF drop
///  carries the port and protocol it always did.
/// ============================================================================
void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  /// A room with one device on the campus network, one on the AV LAN, and a
  /// touch panel.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)..uiSchema = schema;
    p.roomConfig
      ..clear()
      ..addAll(<String, dynamic>{
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'dev_switchers': '1',
          'dev_projectors': '1',
          'gve_id_tlp_1': 'TLP1',
          'gui_tab': '4_Cams_Mic_Dev',
        },
        'SWITCHERDEVICE_1': {
          'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
          'model': 'DTP CrossPoint 84 4K IPCP MA 70',
          'com_type': 'Network',
          'ip_address': '192.168.254.101',
          'protocol': 'TCP',
          'net_port': '23',
        },
        'PROJECTORDEVICE_1': {
          'name': 'Projector - PowerLite L630U',
          'model': 'PowerLite L630U',
          'com_type': 'Network',
          'ip_address': '10.83.12.40',
          'protocol': 'TCP',
          'net_port': '3629',
        },
      });
    p.loadSchematicLayoutForCurrentConfig();
    return p;
  }

  /// Where a device's line lands, and what is written on it.
  ({String to, String label}) drop(SchematicModel m, String id) {
    final e = m.edges.firstWhere((e) => e.fromId == id);
    return (to: e.toId, label: e.label);
  }

  group('reading the address', () {
    test('192. is the AV LAN and nothing else is', () {
      expect(isAvLanAddress('192.168.254.101'), isTrue);
      expect(isAvLanAddress(' 192.0.2.7 '), isTrue);
      expect(isAvLanAddress('10.83.12.40'), isFalse);
      expect(isAvLanAddress('130.86.1.1'), isFalse);
      expect(isAvLanAddress(''), isFalse);
      // The trap: a campus address that merely contains 192.
      expect(isAvLanAddress('10.192.4.5'), isFalse);
    });
  });

  group('by default everything is a building drop', () {
    test('both devices go to the IDF, with no note on either', () {
      final m = SchematicModel.build(room());

      expect(drop(m, 'SWITCHERDEVICE_1').to, kSchematicIdf);
      expect(drop(m, 'SWITCHERDEVICE_1').label, 'TCP 23');
      expect(drop(m, 'PROJECTORDEVICE_1').label, 'TCP 3629');
      // Writing "AV LAN" on every line would make the word mean nothing.
      expect(m.edges.any((e) => e.label.contains('AV LAN')), isFalse);
    });

    test('the panel is on the IDF too', () {
      final m = SchematicModel.build(room());
      expect(drop(m, kSchematicTouchPanel).to, kSchematicIdf);
      expect(drop(m, kSchematicTouchPanel).label, 'PoE');
    });
  });

  group('moved to the processor', () {
    test('only the 192. device moves, and it gets the note', () {
      final p = room();
      p.setSchematicLanding(kSchematicProcessor, avLan: true);
      final m = SchematicModel.build(p);

      expect(drop(m, 'SWITCHERDEVICE_1').to, kSchematicProcessor);
      expect(drop(m, 'SWITCHERDEVICE_1').label, 'TCP 23 • AV LAN');

      // The campus device is not the AV LAN's business.
      expect(drop(m, 'PROJECTORDEVICE_1').to, kSchematicIdf);
      expect(drop(m, 'PROJECTORDEVICE_1').label, 'TCP 3629');
    });

    test('the report stops saying "via IDF" about it', () {
      final p = room();
      p.setSchematicLanding(kSchematicProcessor, avLan: true);
      final m = SchematicModel.build(p);

      expect(connectionSummary(m, m.nodeById('SWITCHERDEVICE_1')!),
          contains('AV LAN'));
      expect(connectionSummary(m, m.nodeById('PROJECTORDEVICE_1')!),
          'Network (via IDF)');
    });

    test('the panel moves on its own switch', () {
      final p = room();
      p.setSchematicLanding(kSchematicProcessor, avLan: false);
      final m = SchematicModel.build(p);

      expect(drop(m, kSchematicTouchPanel).to, kSchematicProcessor);
      // Still PoE wherever it lands — that is how it is powered, not where it
      // is plugged.
      expect(drop(m, kSchematicTouchPanel).label, 'PoE • AV LAN');
      // And it did not drag the devices with it.
      expect(drop(m, 'SWITCHERDEVICE_1').to, kSchematicIdf);
    });
  });

  group('moved to a switch of the room own', () {
    test('a hand-drawn switch box is a landing choice', () {
      final p = room();
      p.addSchematicExtraNode(
        title: 'AV switch',
        subtitle: 'Cisco 9200 • rack',
        icon: 'switch',
      );
      final id = p.schematicExtraNodes.single['id']!;
      p.setSchematicLanding(id, avLan: true);

      final m = SchematicModel.build(p);
      expect(drop(m, 'SWITCHERDEVICE_1').to, id);
      expect(drop(m, 'SWITCHERDEVICE_1').label, 'TCP 23 • AV LAN');
    });

    test('deleting that box puts its drops back on the IDF', () {
      final p = room();
      p.addSchematicExtraNode(
          title: 'AV switch', subtitle: '', icon: 'switch');
      final id = p.schematicExtraNodes.single['id']!;
      p.setSchematicLanding(id, avLan: true);
      p.removeSchematicExtraNodeAt(0);

      // A line to an id nothing draws is a line to nowhere rather than a
      // visible mistake, so the drops go back where they were before anybody
      // chose.
      final m = SchematicModel.build(p);
      expect(drop(m, 'SWITCHERDEVICE_1').to, kSchematicIdf);
      expect(drop(m, 'SWITCHERDEVICE_1').label, 'TCP 23');
    });
  });

  group('the toolbar', () {
    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1800, 1200);
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

    testWidgets('offers both controls, and moving one draws it',
        (tester) async {
      final p = room();
      await pump(tester, p);

      expect(find.byKey(const ValueKey('schematic_avlan_target')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('schematic_panel_target')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('schematic_avlan_target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Processor (AV LAN)').last);
      await tester.pumpAndSettle();

      expect(p.schematicAvLanTarget, kSchematicProcessor);
      expect(p.schematicPanelTarget, kSchematicIdf,
          reason: 'the two are separate decisions');
    });

    testWidgets('the 192 control stays away from a room with none',
        (tester) async {
      final p = room();
      (p.roomConfig['SWITCHERDEVICE_1'] as Map)['ip_address'] = '10.83.12.9';
      await pump(tester, p);

      expect(find.byKey(const ValueKey('schematic_avlan_target')),
          findsNothing);
      // The panel is on every room, so its control stays.
      expect(find.byKey(const ValueKey('schematic_panel_target')),
          findsOneWidget);
    });
  });
}
