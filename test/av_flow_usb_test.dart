import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';

/// USB-C and USB are one connector family; a run between different plugs is
/// listed as the lead it needs.
void main() {
  AvPort usb(String id, String label, SignalType s, PortDirection d) => AvPort(
    id: id,
    label: label,
    signal: s,
    direction: d,
    side: d == PortDirection.input ? PortSide.left : PortSide.right,
  );

  final laptop = AvNode(
    id: 'AVNODE_1',
    label: 'Laptop',
    model: '',
    pos: Offset.zero,
    ports: [usb('c', 'USB-C', SignalType.usbC, PortDirection.output)],
  );
  final camera = AvNode(
    id: 'AVNODE_2',
    label: 'Camera',
    model: '',
    pos: const Offset(400, 0),
    ports: [
      usb('a', 'USB', SignalType.usbData, PortDirection.input),
      usb('b', 'USB B', SignalType.usbData, PortDirection.input),
      usb('c', 'USB-C IN', SignalType.usbC, PortDirection.input),
    ],
  );

  test('USB-C into USB is a cable, not an adapter', () {
    expect(checkPortMatch(laptop, laptop.ports.single, camera, camera.ports[0]),
        PortMatch.ok);
  });

  test('Dante into a network switch port is a cable, not an adapter', () {
    final dsp = AvNode(
      id: 'AVNODE_3',
      label: 'DSP',
      model: '',
      pos: Offset.zero,
      ports: [usb('d', 'Dante', SignalType.dante, PortDirection.bidirectional)],
    );
    final sw = AvNode(
      id: 'AVNODE_4',
      label: 'Switch',
      model: '',
      pos: const Offset(400, 0),
      ports: [
        usb('p1', 'Port 1', SignalType.network, PortDirection.bidirectional),
      ],
    );
    expect(checkPortMatch(dsp, dsp.ports.single, sw, sw.ports.single),
        PortMatch.ok);
    expect(checkPortMatch(sw, sw.ports.single, dsp, dsp.ports.single),
        PortMatch.ok);
  });

  test('the lead is named by its two plugs', () {
    final c = laptop.ports.single;
    expect(usbCableName(c, camera.ports[0]), 'USB-C to USB-A');
    expect(usbCableName(c, camera.ports[1]), 'USB-C to USB-B');
    expect(usbCableName(c, camera.ports[2]), '');
  });

  test('the schedule and the counts list the USB-C to USB-A lead', () {
    final byId = {laptop.id: laptop, camera.id: camera};
    const cable = AvCable(
      id: 'C1',
      fromNodeId: 'AVNODE_1',
      fromPortId: 'c',
      toNodeId: 'AVNODE_2',
      toPortId: 'a',
      signal: SignalType.usbC,
    );
    expect(cableSignalName(cable, byId), 'USB-C to USB-A');
    final model = AvFlowModel(
      nodes: [laptop, camera],
      cables: const [cable],
      racks: const [],
      rackSlots: const {},
      canvasSize: const Size(900, 560),
      roomTitle: 'Test Room',
      unplaced: const [],
    );
    final schedule = avFlowSections(
      AppStateProvider(autoLoadSettings: false),
      model,
    ).firstWhere((s) => s.title == 'Cable Schedule');
    expect(schedule.rows.single, contains('USB-C to USB-A'));
    expect(
      cableCountSection(model).rows.any((r) => r.contains('USB-C to USB-A')),
      isTrue,
    );
  });
}
