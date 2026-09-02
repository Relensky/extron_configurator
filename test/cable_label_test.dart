import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show cableLabelAnchor;

/// ============================================================================
///  EVERY RUN CARRIES ITS NUMBER, AND THE NUMBER CAN BE MOVED
/// ============================================================================
///  A run with no label is a run nobody can find again at the far end, so
///  every one drawn is born carrying its cable id — the same number the
///  schedule prints in its Cable ID column.
///
///  Where that number SITS is the other half. It lands on the midpoint of the
///  run's longest leg, which is right most of the time and unreadable the
///  rest: two runs sharing a corridor put their labels on top of each other.
///  Dragging one stores an offset from that anchor rather than an absolute
///  point, so a rerouted run takes its label with it.
/// ============================================================================
void main() {
  AvNode box(String id, double x) => AvNode(
        id: id,
        label: id,
        model: '',
        pos: Offset(x, 0),
        ports: [
          AvPort(
            id: 'p_$id',
            label: 'HDMI',
            signal: SignalType.hdmi,
            direction: PortDirection.bidirectional,
            side: PortSide.right,
          ),
        ],
      );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(box('A', 0));
    p.addAvNode(box('B', 400));
    return p;
  }

  group('the number', () {
    test('a run drawn on the canvas is labeled with its cable id', () {
      final p = room();
      final cable = p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'p_A',
        toNodeId: 'B',
        toPortId: 'p_B',
        signal: SignalType.hdmi,
      );
      expect(cable!.label, cable.id);
      expect(cable.label, 'C1');
    });

    test('a label typed by hand wins over the number', () {
      final p = room();
      final cable = p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'p_A',
        toNodeId: 'B',
        toPortId: 'p_B',
        signal: SignalType.hdmi,
        label: 'AV-04',
      );
      expect(cable!.label, 'AV-04');
    });
  });

  group('where it sits', () {
    test('the midpoint of the longest leg', () {
      // Two legs: a short one and a long one. The label goes on the long one,
      // which is the stretch with room to write on.
      expect(
        cableLabelAnchor(const [
          Offset(0, 0),
          Offset(0, 20),
          Offset(400, 20),
        ]),
        const Offset(200, 20),
      );
    });

    test('nowhere at all when no leg is long enough to write on', () {
      // A patch between adjacent boxes is better unlabeled than covered by
      // its own cable number.
      expect(
        cableLabelAnchor(const [Offset(0, 0), Offset(12, 0)]),
        isNull,
      );
    });

    test('a moved label is an OFFSET, so a rerouted run keeps it', () {
      // Storing the point it was dropped on would strand the label over open
      // canvas the moment somebody moved a box.
      const cable = AvCable(
        id: 'C1',
        fromNodeId: 'A',
        fromPortId: 'p_A',
        toNodeId: 'B',
        toPortId: 'p_B',
        signal: SignalType.hdmi,
        label: 'C1',
        labelOffset: Offset(0, -18),
      );
      const before = [Offset(0, 0), Offset(400, 0)];
      const after = [Offset(0, 300), Offset(400, 300)];
      expect(cableLabelAnchor(before)! + cable.labelOffset,
          const Offset(200, -18));
      expect(cableLabelAnchor(after)! + cable.labelOffset,
          const Offset(200, 282));
    });

    test('it survives a save and a reload', () {
      const moved = AvCable(
        id: 'C1',
        fromNodeId: 'A',
        fromPortId: 'p_A',
        toNodeId: 'B',
        toPortId: 'p_B',
        signal: SignalType.hdmi,
        label: 'C1',
        labelOffset: Offset(12, -18),
      );
      final back = AvCable.fromJson(moved.toJson());
      expect(back.labelOffset, const Offset(12, -18));

      // A label nobody has moved writes nothing, so an untouched room's file
      // does not grow a field per run.
      expect(
        moved.copyWith(labelOffset: Offset.zero).toJson()
            .containsKey('labelOffset'),
        isFalse,
      );
    });
  });
}
