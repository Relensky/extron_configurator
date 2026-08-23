import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  ROOM ON THE PAGE FOR THE CABLES
/// ============================================================================
///  The automatic layout used to put its columns 340 apart against a box that
///  is allowed to be 300 wide. Every run between two columns then had a 40px
///  corridor to share, and a dozen of them do not fit in it: the lines came
///  out drawn on top of each other and across the boxes.
///
///  So the grid is checked here rather than looked at: a corridor wide enough
///  for the lanes, boxes that never land on each other, and a gap between
///  stacked boxes a crossing run can actually pass through.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  /// A room with four sources and a DTP projector — enough boxes that the
  /// left column has to stack and enough runs to fill the corridor.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library;

    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{
      'dev_projectors': '1',
      'dev_switchers': '1',
      'input_pc': '1',
      'input_hdmi': '4',
      'input_doc_cam': '6',
      'input_dvd': '2',
      'output_proj_1': '3B',
    };
    p.roomConfig['PROJECTORDEVICE_1'] = <String, dynamic>{
      'name': 'Projector - PowerLite L630U',
      'model': 'PowerLite L630U',
      'input': 'HDBaseT',
      'com_type': 'Network',
    };
    p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{
      'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
      'model': 'DTP CrossPoint 84 4K IPCP MA 70',
      'com_type': 'Network',
    };

    for (final (key, at) in [
      ('SWITCHERDEVICE_1', const Offset(kAvAutoColumnPitch, kAvAutoOriginY)),
      ('PROJECTORDEVICE_1',
          const Offset(kAvAutoColumnPitch * 3, kAvAutoOriginY)),
    ]) {
      final dev = p.roomConfig[key] as Map;
      final template = p.avDeviceLibrary
          .resolve(configKey: key, model: dev['model'].toString());
      p.addAvNode(AvNode(
        id: key,
        label: dev['name'].toString(),
        model: dev['model'].toString(),
        pos: at,
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));
    }
    return p;
  }

  group('the grid the automatic passes lay out on', () {
    test('a column is wider than the widest box, with room for the lanes', () {
      // The corridor every run between two columns has to share. Twelve lanes
      // 20px apart, and the labels that ride on them, need far more than the
      // 40px the old 340 pitch left.
      expect(kAvAutoColumnPitch - kAvNodeMaxWidth, greaterThanOrEqualTo(150));
    });

    test('stacked boxes leave a gap a crossing run can pass through', () {
      expect(kAvAutoRowGap, greaterThanOrEqualTo(60));
    });

    test('no two boxes the routing places land on top of each other', () {
      final p = room();
      final plan = planRoutingFromConfig(p);
      expect(plan.newNodes, isNotEmpty);

      final all = [...p.avNodes, ...plan.newNodes];
      for (int i = 0; i < all.length; i++) {
        for (int j = i + 1; j < all.length; j++) {
          expect(
            all[i].rect.overlaps(all[j].rect),
            isFalse,
            reason: '${all[i].label} sits on top of ${all[j].label}',
          );
        }
      }
    });

    test('boxes stacked in one column keep the full row gap', () {
      final p = room();
      final plan = planRoutingFromConfig(p);

      final byColumn = <int, List<AvNode>>{};
      for (final n in [...p.avNodes, ...plan.newNodes]) {
        byColumn
            .putIfAbsent((n.pos.dx / kAvAutoColumnPitch).round(), () => [])
            .add(n);
      }
      for (final column in byColumn.values) {
        column.sort((a, b) => a.pos.dy.compareTo(b.pos.dy));
        for (int i = 1; i < column.length; i++) {
          final gap = column[i].pos.dy -
              (column[i - 1].pos.dy + column[i - 1].height);
          expect(
            gap,
            greaterThanOrEqualTo(kAvAutoRowGap - 0.01),
            reason: '${column[i].label} is $gap below '
                '${column[i - 1].label}',
          );
        }
      }
    });
  });

  group('what a run says when nobody has numbered it', () {
    test('the box at each end, source first', () {
      const pc = AvNode(
          id: 'a', label: 'Room PC', model: 'PC', pos: Offset.zero, ports: []);
      const sw = AvNode(
          id: 'b',
          label: 'Switcher',
          model: 'IN1608',
          pos: Offset.zero,
          ports: []);
      expect(defaultCableLabel(pc, sw), 'Room PC → Switcher');
    });

    test('a long name is cut rather than laid across the diagram', () {
      const long = 'DTP receiver - Projector - PowerLite L630U';
      final short = shortNodeLabel(long);
      expect(short.length, lessThanOrEqualTo(24));
      expect(short, endsWith('…'));
      expect(long, startsWith(short.substring(0, short.length - 1)));
    });

    test('a name that fits is left exactly as it is', () {
      expect(shortNodeLabel('Room PC'), 'Room PC');
    });
  });
}
