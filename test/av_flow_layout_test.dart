import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_layout.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// Tidy layout: nothing on top of anything, sources left, displays right,
/// and a table of displays once there are many.
void main() {
  late AvDeviceLibrary library;
  setUpAll(() async {
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AvNode box(String id, {Offset pos = Offset.zero, String label = ''}) =>
      AvNode(
        id: id,
        label: label.isEmpty ? id : label,
        model: '',
        pos: pos,
        ports: const [],
      );

  void expectNoOverlaps(List<AvNode> nodes, Map<String, Offset> at) {
    final rects = [
      for (final n in nodes) (at[n.id] ?? n.pos) & n.size,
    ];
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(rects[i].overlaps(rects[j]), isFalse,
            reason: '${nodes[i].id} and ${nodes[j].id} overlap');
      }
    }
  }

  test('a pile of boxes comes out with nothing overlapping', () {
    final nodes = [
      box('AVSOURCE_INPUT_1'),
      box('AVSOURCE_INPUT_2'),
      box('SWITCHERDEVICE_1'),
      box('DSPDEVICE_1'),
      box('PROJECTORDEVICE_1'),
      box('AVNODE_1', label: 'Lobby display'),
    ];
    final at = tidyAvLayout(nodes, library);
    expect(at.keys.toSet(), nodes.map((n) => n.id).toSet());
    expectNoOverlaps(nodes, at);
    // Sources left of the switcher, displays right of everything.
    expect(at['AVSOURCE_INPUT_1']!.dx, lessThan(at['SWITCHERDEVICE_1']!.dx));
    expect(at['SWITCHERDEVICE_1']!.dx, lessThan(at['DSPDEVICE_1']!.dx));
    expect(at['DSPDEVICE_1']!.dx, lessThan(at['PROJECTORDEVICE_1']!.dx));
    // A display added by hand goes with the displays.
    expect(at['AVNODE_1']!.dx, at['PROJECTORDEVICE_1']!.dx);
  });

  test('many displays are drawn as a table on the right', () {
    final nodes = [
      box('SWITCHERDEVICE_1'),
      for (var i = 1; i <= 20; i++)
        box('PROJECTORDEVICE_$i', pos: Offset(0, i * 10.0)),
    ];
    final at = tidyAvLayout(nodes, library);
    expectNoOverlaps(nodes, at);
    final xs = {
      for (var i = 1; i <= 20; i++) at['PROJECTORDEVICE_$i']!.dx,
    };
    // More than one column, all right of the switcher.
    expect(xs.length, greaterThan(1));
    expect(xs.every((x) => x > at['SWITCHERDEVICE_1']!.dx), isTrue);
    // No column taller than the stack limit.
    final perColumn = <double, int>{};
    for (var i = 1; i <= 20; i++) {
      final x = at['PROJECTORDEVICE_$i']!.dx;
      perColumn[x] = (perColumn[x] ?? 0) + 1;
    }
    expect(perColumn.values.every((n) => n <= kAvDestinationsPerColumn),
        isTrue);
  });

  test('a tidy is one undo step and keeps the order of a column', () {
    final p = AppStateProvider(autoLoadSettings: false)
      ..avDeviceLibrary = library;
    p.addAvNode(box('AVSOURCE_INPUT_2', pos: const Offset(900, 900)),
        recordUndo: false);
    p.addAvNode(box('AVSOURCE_INPUT_1', pos: const Offset(905, 100)),
        recordUndo: false);
    final moved = p.arrangeAvNodes(tidyAvLayout(p.avNodes, library));
    expect(moved, 2);
    // The one that was higher stays higher.
    expect(p.avNodeById('AVSOURCE_INPUT_1')!.pos.dy,
        lessThan(p.avNodeById('AVSOURCE_INPUT_2')!.pos.dy));
    expect(p.avUndoLabel(AvUndoScope.flow), 'Tidy layout');
    // Already tidy: nothing to move, nothing to undo.
    expect(p.arrangeAvNodes(tidyAvLayout(p.avNodes, library)), 0);
  });

  test('tidy orders a column so the cables do not cross', () {
    AvPort out(int i) => AvPort(
      id: 'out$i',
      label: 'OUT $i',
      signal: SignalType.hdmi,
      direction: PortDirection.output,
      side: PortSide.right,
    );
    const input = AvPort(
      id: 'in',
      label: 'IN',
      signal: SignalType.hdmi,
      direction: PortDirection.input,
      side: PortSide.left,
    );
    final nodes = [
      AvNode(
        id: 'SWITCHERDEVICE_1',
        label: 'Switcher',
        model: '',
        pos: Offset.zero,
        ports: [for (var i = 1; i <= 3; i++) out(i)],
      ),
      // Drawn in the opposite order to the outputs that feed them.
      for (var i = 1; i <= 3; i++)
        AvNode(
          id: 'PROJECTORDEVICE_$i',
          label: 'Projector $i',
          model: '',
          pos: Offset(600, (4 - i) * 200.0),
          ports: const [input],
        ),
    ];
    final cables = [
      for (var i = 1; i <= 3; i++)
        AvCable(
          id: 'C$i',
          fromNodeId: 'SWITCHERDEVICE_1',
          fromPortId: 'out$i',
          toNodeId: 'PROJECTORDEVICE_$i',
          toPortId: 'in',
          signal: SignalType.hdmi,
        ),
    ];
    final byId = {for (final n in nodes) n.id: n};
    // Kept in the order they were in, three runs cross.
    final plain = tidyAvLayout(nodes, library);
    expect(avLayoutCrossings(byId, plain, cables), 3);

    final at = tidyAvLayout(nodes, library, cables: cables);
    expectNoOverlaps(nodes, at);
    expect(avLayoutCrossings(byId, at, cables), 0);
    expect(at['PROJECTORDEVICE_1']!.dy, lessThan(at['PROJECTORDEVICE_2']!.dy));
    expect(at['PROJECTORDEVICE_2']!.dy, lessThan(at['PROJECTORDEVICE_3']!.dy));

    // Tidied again, nothing moves.
    final moved = [
      for (final n in nodes) n.copyWith(pos: at[n.id]),
    ];
    final again = tidyAvLayout(moved, library, cables: cables);
    for (final n in moved) {
      expect(again[n.id], n.pos, reason: n.id);
    }
  });
}
