import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/room_presets.dart';

/// Every lead in every shipped room type is one the AV Flow tab itself would
/// draw without a question: both ends exist, it runs out of something and
/// into something, the signals agree, and no input is fed twice.
void main() {
  for (final preset in builtInRoomPresets()) {
    test('${preset.name}: every lead is a real one', () {
      final byId = {for (final n in preset.nodes) n.id: n};
      final fed = <String, String>{};
      final problems = <String>[];
      for (final c in preset.cables) {
        final where = '${c.id} ${c.fromNodeId}.${c.fromPortId} -> '
            '${c.toNodeId}.${c.toPortId}';
        final a = byId[c.fromNodeId];
        final b = byId[c.toNodeId];
        final from = a?.portById(c.fromPortId);
        final to = b?.portById(c.toPortId);
        if (a == null || b == null || from == null || to == null) {
          problems.add('$where: an end is missing');
          continue;
        }
        final match = checkPortMatch(a, from, b, to);
        if (match != PortMatch.ok) problems.add('$where: ${match.name}');
        if (to.direction == PortDirection.input) {
          final other = fed['${b.id}.${to.id}'];
          if (other != null) problems.add('$where: input also fed by $other');
          fed['${b.id}.${to.id}'] = c.id;
        }
      }
      expect(problems, isEmpty);
    });
  }

  test('Active learning: the matrix amp drives the ceiling', () {
    final p = builtInRoomPresets().firstWhere((p) => p.name == 'Active learning');
    final spk = p.cables.singleWhere((c) => c.toNodeId == 'AVNODE_8');
    expect('${spk.fromNodeId}.${spk.fromPortId}', 'SWITCHERDEVICE_1.ma_out_70v');
  });
}
