import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_routing.dart';

/// Auto-route by name: boxes whose names end in the same place - "NAV Decoder
/// Station 1" and "Station 1" - are cabled output to input on video.

const Set<SignalType> _nameRouteSignals = {
  SignalType.hdmi,
  SignalType.hdbaset,
  SignalType.displayPort,
  SignalType.usbC,
  SignalType.sdi,
  SignalType.vga,
};

/// The place a box's name ends in, as 'station 1', or '' when it ends in no
/// word and number.
String namePlaceKey(String label) {
  final m = RegExp(r'([A-Za-z]+)\s*#?\s*(\d+)\s*$').firstMatch(label.trim());
  if (m == null) return '';
  return '${m.group(1)!.toLowerCase()} ${int.parse(m.group(2)!)}';
}

/// The runs Auto-route by name would draw. Only free connectors are used,
/// a loop-through output never feeds anything, and two NAV boxes are never
/// joined (they talk over the network).
List<RoutedCable> planNameRoutes(AppStateProvider provider) {
  final taken = <String>{
    for (final c in provider.avCables) ...[
      '${c.fromNodeId}.${c.fromPortId}',
      '${c.toNodeId}.${c.toPortId}',
    ],
  };
  bool free(AvNode n, AvPort p) => !taken.contains('${n.id}.${p.id}');

  final groups = <String, List<AvNode>>{};
  for (final n in provider.avNodes) {
    final key = namePlaceKey(n.label);
    if (key.isNotEmpty) groups.putIfAbsent(key, () => []).add(n);
  }

  final cables = <RoutedCable>[];
  for (final entry in groups.entries) {
    final boxes = entry.value;
    if (boxes.length < 2) continue;
    // Decoders first, so a display takes its feed from the decoder.
    final sources = [...boxes]..sort((a, b) {
        int rank(AvNode n) => navRole(n) == NavRole.decoder ? 0 : 1;
        return rank(a) - rank(b);
      });
    for (final src in sources) {
      for (final out in src.ports) {
        if (out.direction == PortDirection.input ||
            !_nameRouteSignals.contains(out.signal) ||
            RegExp('LOOP', caseSensitive: false).hasMatch(out.label) ||
            !free(src, out)) {
          continue;
        }
        // A NAV source feeds a box that is not NAV; anything else feeds an
        // encoder first.
        final dests = boxes.where((d) => d.id != src.id).where((d) =>
            !(navRole(src) != null && navRole(d) != null)).toList()
          ..sort((a, b) {
            int rank(AvNode n) => navRole(src) == null
                ? (navRole(n) == NavRole.encoder ? 0 : 1)
                : 0;
            return rank(a) - rank(b);
          });
        AvNode? to;
        AvPort? toPort;
        for (final d in dests) {
          toPort = d.ports
              .where((p) =>
                  p.direction != PortDirection.output &&
                  p.signal == out.signal &&
                  free(d, p))
              .firstOrNull;
          if (toPort != null) {
            to = d;
            break;
          }
        }
        if (to == null || toPort == null) continue;
        taken
          ..add('${src.id}.${out.id}')
          ..add('${to.id}.${toPort.id}');
        cables.add(RoutedCable(
          configKey: 'name',
          value: entry.key,
          fromNodeId: src.id,
          fromPortId: out.id,
          fromPortLabel: out.label,
          toNodeId: to.id,
          toPortId: toPort.id,
          toPortLabel: toPort.label,
          signal: out.signal,
          fromLabel: src.label,
          toLabel: to.label,
        ));
      }
    }
  }
  return cables;
}
