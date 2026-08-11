import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/report_tools.dart';

/// Two sheets an installer actually carries: which device is on which numbered
/// jack of a wall box or patch panel, and where every device's mains comes
/// from — including which outlet of the power controller.
void main() {
  AvPort port(String id, String label, SignalType s, PortDirection d) => AvPort(
    id: id,
    label: label,
    signal: s,
    direction: d,
    side: d == PortDirection.output ? PortSide.right : PortSide.left,
  );

  AvNode wallBox(String id, String label, int jacks) => AvNode(
    id: id,
    label: label,
    model: '$jacks-jack Network field',
    pos: Offset.zero,
    kind: AvNodeKind.jackField,
    powerSource: PowerSource.none,
    ports: [
      for (int i = 1; i <= jacks; i++)
        port('jack_$i', 'J$i', SignalType.network, PortDirection.bidirectional),
    ],
  );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  ReportSection sectionNamed(List<ReportSection> all, String title) =>
      all.firstWhere((s) => s.title == title);

  /// Reads a cell by COLUMN NAME. The schedules gain columns as the sheets
  /// grow — a location on every row, the far end's location — and a test
  /// pinned to column 3 fails on the next one of those without anything
  /// being wrong.
  Object? cell(ReportSection s, List<dynamic> row, String column) =>
      row[s.header.indexOf(column)];

  test('the jack schedule says which device is on which jack', () {
    final p = room();
    p.addAvNode(wallBox('WB1', 'Lectern wall plate', 4));
    p.addAvNode(
      AvNode(
        id: 'PC',
        label: 'Room PC',
        model: 'Room PC',
        pos: const Offset(400, 0),
        ports: [
          port('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        ],
      ),
    );
    p.addAvCable(
      fromNodeId: 'PC',
      fromPortId: 'lan_1',
      toNodeId: 'WB1',
      toPortId: 'jack_2',
      signal: SignalType.network,
      label: 'DATA-12',
    );

    final model = buildAvFlowModel(p);
    final jacks = sectionNamed(avReportSections(p, model), 'Jack Schedule');

    expect(jacks.header.first, 'Wall box / panel');
    expect(jacks.rows.length, 4); // one row per jack

    final j2 = jacks.rows.firstWhere(
      (r) => cell(jacks, r, 'Jack') == 'J2',
    );
    expect(cell(jacks, j2, 'Wall box / panel'), 'Lectern wall plate');
    expect(cell(jacks, j2, 'Connected device'), 'Room PC');
    expect(cell(jacks, j2, 'Device port'), 'LAN');
    expect(cell(jacks, j2, 'Cable'), 'C1');

    // Unused jacks are still listed — knowing what is spare is the point.
    expect(
      jacks.rows
          .where((r) => cell(jacks, r, 'Connected device') == '(spare)')
          .length,
      3,
    );
  });

  test('a jack still reports when the cable was drawn from the box end', () {
    final p = room();
    p.addAvNode(wallBox('WB1', 'Floor box', 2));
    p.addAvNode(
      AvNode(
        id: 'CAM',
        label: 'Camera',
        model: 'TR311HW',
        pos: const Offset(400, 0),
        ports: [
          port('lan_1', 'LAN', SignalType.network, PortDirection.bidirectional),
        ],
      ),
    );
    // Drawn box -> device, the opposite direction to the test above.
    p.addAvCable(
      fromNodeId: 'WB1',
      fromPortId: 'jack_1',
      toNodeId: 'CAM',
      toPortId: 'lan_1',
      signal: SignalType.network,
    );

    final model = buildAvFlowModel(p);
    final jacks = sectionNamed(avReportSections(p, model), 'Jack Schedule');
    final j1 = jacks.rows.firstWhere((r) => cell(jacks, r, 'Jack') == 'J1');
    expect(cell(jacks, j1, 'Connected device'), 'Camera');
  });

  test('there is no jack schedule when the room has no jack fields', () {
    final p = room();
    p.addAvNode(
      AvNode(
        id: 'PC',
        label: 'Room PC',
        model: 'Room PC',
        pos: Offset.zero,
        ports: const [],
      ),
    );
    final titles = avReportSections(
      p,
      buildAvFlowModel(p),
    ).map((s) => s.title);
    expect(titles, isNot(contains('Jack Schedule')));
  });

  group('the power report', () {
    test('separates controller, wall and PoE, and names the outlet', () {
      final p = room();
      p.addAvNode(
        AvNode(
          id: 'POWERDEVICE_1',
          label: 'APC',
          model: 'AP7900B',
          pos: Offset.zero,
          ports: [
            port('out_pwr_1', 'OUTLET 1', SignalType.power,
                PortDirection.output),
            port('out_pwr_3', 'OUTLET 3', SignalType.power,
                PortDirection.output),
          ],
        ),
      );
      p.addAvNode(
        AvNode(
          id: 'SWITCHERDEVICE_1',
          label: 'Switcher',
          model: 'SW4',
          pos: const Offset(400, 0),
          powerSource: PowerSource.controller,
          ports: [
            port('in_pwr', 'AC IN', SignalType.power, PortDirection.input),
          ],
        ),
      );
      p.addAvNode(
        AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Projector',
          model: 'L610U',
          pos: const Offset(800, 0),
          powerSource: PowerSource.wall,
          ports: const [],
        ),
      );
      p.addAvNode(
        AvNode(
          id: 'CAMERADEVICE_1',
          label: 'Camera',
          model: 'TR311HW',
          pos: const Offset(800, 200),
          powerSource: PowerSource.poe,
          ports: const [],
        ),
      );

      // The switcher is on outlet 3 of the APC.
      p.addAvCable(
        fromNodeId: 'POWERDEVICE_1',
        fromPortId: 'out_pwr_3',
        toNodeId: 'SWITCHERDEVICE_1',
        toPortId: 'in_pwr',
        signal: SignalType.power,
      );

      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Schedule',
      );

      final switcher = power.rows.firstWhere((r) => r[0] == 'Switcher');
      expect(switcher[2], kPowerSourceLabels[PowerSource.controller]);
      expect(switcher[5], 'APC');
      expect(switcher[6], 'OUTLET 3');

      final projector = power.rows.firstWhere((r) => r[0] == 'Projector');
      expect(projector[2], kPowerSourceLabels[PowerSource.wall]);
      expect(projector[5], '', reason: 'a wall outlet has nothing to trace to');

      final camera = power.rows.firstWhere((r) => r[0] == 'Camera');
      expect(camera[2], kPowerSourceLabels[PowerSource.poe]);
    });

    test('a device with nothing recorded still appears', () {
      final p = room();
      p.addAvNode(
        AvNode(
          id: 'DSPDEVICE_1',
          label: 'DSP',
          model: 'DMP 64',
          pos: Offset.zero,
          ports: const [],
        ),
      );
      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Schedule',
      );
      expect(power.rows.single[0], 'DSP');
      expect(power.rows.single[2], kPowerSourceLabels[PowerSource.unspecified]);
    });

    test('jack fields are left out — a wall plate has no mains', () {
      final p = room();
      p.addAvNode(wallBox('WB1', 'Wall box', 2));
      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Schedule',
      );
      expect(power.rows, isEmpty);
    });
  });

  test('the node kind and power source round-trip through JSON', () {
    final box = wallBox('WB1', 'Wall box', 3);
    final restored = AvNode.fromJson(box.toJson());
    expect(restored.kind, AvNodeKind.jackField);
    expect(restored.isJackField, isTrue);
    expect(restored.powerSource, PowerSource.none);
    expect(restored.ports.length, 3);
    expect(restored.ports[1].label, 'J2');

    const device = AvNode(
      id: 'D',
      label: 'D',
      model: 'M',
      pos: Offset.zero,
      powerSource: PowerSource.controller,
      ports: [],
    );
    final back = AvNode.fromJson(device.toJson());
    expect(back.kind, AvNodeKind.device);
    expect(back.powerSource, PowerSource.controller);
  });
}
