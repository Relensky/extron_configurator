import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/main.dart';

/// ============================================================================
///  150% AND 200%, WITH A ROOM OPEN
/// ============================================================================
///  Every tab and project pane with a drawn room open - devices with ports, a
///  cable, a rack - at large Text Size, at large Interface Size on a 1080p
///  screen, and at both. Collects every error so one run shows them all.
/// ============================================================================
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('large_scale_');
    SettingsSection.forgetOpenForTest();
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AvPort port(String id, String label, PortDirection d, PortSide s) => AvPort(
        id: id,
        label: label,
        signal: SignalType.hdmi,
        direction: d,
        side: s,
      );

  Future<AppStateProvider> job() async {
    final config = path.join(dir.path, 'BSS_103', 'config.json');
    Directory(path.join(dir.path, 'BSS_103', 'room_files'))
        .createSync(recursive: true);
    File(config).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gui_full_room_name': 'Bessey Hall 103 Lecture Theatre',
        'gve_bldg': 'BSS',
        'gve_room': '103',
      },
    }));
    File(path.join(dir.path, 'BSS_103', 'room_files', 'BSS_103_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'AVNODE_1',
          label: 'Lectern switcher',
          model: 'DTP CrossPoint 84 4K',
          pos: const Offset(80, 120),
          ports: [
            for (var i = 1; i <= 4; i++)
              port('in$i', 'HDMI input $i', PortDirection.input,
                  PortSide.left),
            for (var i = 1; i <= 2; i++)
              port('out$i', 'HDBaseT output $i', PortDirection.output,
                  PortSide.right),
          ],
        ).toJson(),
        AvNode(
          id: 'AVNODE_2',
          label: 'Front projector',
          model: 'PowerLite L610U',
          pos: const Offset(520, 140),
          ports: [
            port('in1', 'HDBaseT in', PortDirection.input, PortSide.left),
          ],
        ).toJson(),
      ],
      'cables': [
        const AvCable(
          id: 'c1',
          fromNodeId: 'AVNODE_1',
          fromPortId: 'out1',
          toNodeId: 'AVNODE_2',
          toPortId: 'in1',
          signal: SignalType.hdmi,
          label: 'V-101',
        ).toJson(),
      ],
    }));

    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'DTP CrossPoint 84 4K',
        manufacturer: 'Extron',
        category: 'Switcher',
        price: 9000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 1000,
        ports: [],
      ));
    p.newProject(name: 'Sweep');
    p.addRoomToProject(config);
    await p.saveProject(to: path.join(dir.path, 'Sweep_project.json'));
    await p.openProjectRoomRef(p.project.rooms.single);
    final rack = p.addAvRack('Lectern rack', 12);
    p.setAvRackSlot('AVNODE_1', RackSlot(rackId: rack.id, startU: 2));
    return p;
  }

  // 1920x1080 at Interface Size 150% and 200%, and the text turned up.
  const cases = <({String name, double text, double ui})>[
    (name: 'text 150%', text: 1.5, ui: 1.0),
    (name: 'text 200%', text: 2.0, ui: 1.0),
    (name: 'interface 150%', text: 1.0, ui: 1.5),
    (name: 'interface 200%', text: 1.0, ui: 2.0),
    (name: 'interface 150% text 150%', text: 1.5, ui: 1.5),
  ];

  for (final c in cases) {
    testWidgets('every tab and pane with a room open at ${c.name}',
        (tester) async {
      late AppStateProvider p;
      await tester.runAsync(() async => p = await job());
      p
        ..textScale = c.text
        ..uiScale = c.ui;
      tester.view.physicalSize = const Size(1920, 1040);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final failures = <String>[];
      final saved = FlutterError.onError;
      FlutterError.onError = (d) {
        // The widget the layout broke in, so the failure says where to look.
        final at = RegExp(r'lib/[\w/]+\.dart:\d+')
            .firstMatch(d.toString())
            ?.group(0);
        failures.add('${c.name} @ $where: '
            '${d.exceptionAsString().split('\n').first} ($at)');
      };
      addTearDown(() => FlutterError.onError = saved);

      await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ));
      await tester.pumpAndSettle();

      for (final tab in AppTab.values) {
        where = tab.name;
        p.selectTab(tab.index);
        await tester.pumpAndSettle();
      }
      p.selectTab(AppTab.project.index);
      await tester.pumpAndSettle();
      for (final pane in [
        'rooms', 'parts', 'plans', 'timeline', 'deliveries', 'lifecycle',
        'responsibility', 'procurement', 'vendors', 'todo', 'notes',
      ]) {
        where = 'project $pane';
        final key = find.byKey(ValueKey('project_pane_$pane'));
        if (key.evaluate().isEmpty) continue;
        await tester.tap(key.first, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      FlutterError.onError = saved;
      for (final f in failures.toSet()) {
        debugPrint('OVERFLOW $f');
      }
      expect(failures.toSet().toList(), isEmpty);
    });
  }
}

String where = 'start';
