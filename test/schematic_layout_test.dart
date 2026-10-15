import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/schematic_layout.dart';
import 'package:extron_configurator/schematic_view.dart';

/// Tidy on the Schematic: the processor in the middle, the devices round it
/// with nothing touching, or a table when there are many.
void main() {
  SchematicNode node(String id, {ConnType conn = ConnType.serial}) =>
      SchematicNode(
        id: id,
        title: id,
        subtitle: '',
        icon: Icons.device_hub,
        conn: conn,
        pos: Offset.zero,
      );

  List<SchematicNode> room(int devices) => [
        node(kSchematicProcessor, conn: ConnType.network),
        node(kSchematicIdf, conn: ConnType.network),
        for (var i = 1; i <= devices; i++)
          node('DEVICE_$i',
              conn: i.isEven ? ConnType.network : ConnType.serial),
      ];

  void expectNoOverlaps(Map<String, Offset> at) {
    final rects = [
      for (final p in at.values) p & const Size(kNodeWidth, kNodeHeight),
    ];
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(rects[i].overlaps(rects[j]), isFalse);
      }
    }
  }

  test('a few devices go evenly round the processor', () {
    final at = tidySchematic(room(10));
    expect(at, hasLength(12));
    expectNoOverlaps(at);
    // The processor is in the middle of the ring.
    final hub = at[kSchematicProcessor]!;
    final xs = [for (var i = 1; i <= 10; i++) at['DEVICE_$i']!.dx];
    final ys = [for (var i = 1; i <= 10; i++) at['DEVICE_$i']!.dy];
    expect(xs.reduce((a, b) => a < b ? a : b), lessThan(hub.dx));
    expect(xs.reduce((a, b) => a > b ? a : b), greaterThan(hub.dx));
    expect(ys.reduce((a, b) => a < b ? a : b), lessThan(hub.dy));
    expect(ys.reduce((a, b) => a > b ? a : b), greaterThan(hub.dy));
  });

  test('many devices go in a table under the processor', () {
    final at = tidySchematic(room(40));
    expectNoOverlaps(at);
    final rows = {for (var i = 1; i <= 40; i++) at['DEVICE_$i']!.dy};
    expect(rows.length, greaterThan(1));
    expect(rows.every((y) => y > at[kSchematicProcessor]!.dy), isTrue);
  });

  test('a tidy is one undo step', () {
    final p = AppStateProvider(autoLoadSettings: false);
    expect(p.arrangeSchematic(tidySchematic(room(5))), 7);
    expect(p.arrangeSchematic(tidySchematic(room(5))), 0);
  });

  test('config devices are named by kind', () {
    expect(configDeviceTypeLabel('SWITCHERDEVICE_1'), 'Switcher device 1');
    expect(configDeviceTypeLabel('POWERDEVICE_2'), 'Power device 2');
    expect(configDeviceTypeLabel('AVSOURCE_INPUT_3'), 'Source input 3');
    expect(configDeviceTypeLabel('AVNODE_4'), '');
  });
}
