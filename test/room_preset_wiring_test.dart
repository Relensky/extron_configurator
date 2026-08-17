import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/room_presets.dart';

/// The shipped room types are DRAWINGS, and a drawing with a cable landing on a
/// connector that isn't there is worse than no drawing: it looks finished. The
/// four presets are modelled on builds that exist, with real models on them,
/// which buys three things that have to actually hold:
///
///   * every cable ends on a port that exists, at both ends;
///   * every node sits in a location the preset ships;
///   * every named model is a model the catalog knows, so the diagram gets its
///     price, its heat load and its python driver rather than a blank row.
///
/// The third is the one that rots quietly — a model renamed in av_devices.json
/// leaves the preset pointing at nothing and nobody notices until a room is
/// costed.
void main() {
  final presets = builtInRoomPresets();

  test('there are four of them and they are all built-ins', () {
    expect(presets, hasLength(4));
    for (final p in presets) {
      expect(p.builtIn, isTrue, reason: p.name);
      expect(p.description, isNotEmpty, reason: p.name);
    }
  });

  test('no shipped type carries a wall plate', () {
    // A plate is what a particular building asks for, not part of the room
    // type: these rooms are drawn device-to-device, and the laptop plugs into
    // the transmitter (or the switcher) rather than into a box on the wall.
    for (final preset in presets) {
      expect(
        preset.nodes.where((n) => n.isJackField),
        isEmpty,
        reason: '${preset.name} still has a jack field',
      );
      expect(preset.jackCount, 0, reason: preset.name);
    }
  });

  test('the huddle room is the small-room build', () {
    final huddle = presets.firstWhere((p) => p.name == 'Huddle');
    final models = huddle.nodes.map((n) => n.model).toSet();

    // The processor is a control processor, not the IP Link interface the
    // preset used to name.
    expect(models, contains('IPCP Pro PCS1 xi'));
    expect(models, contains('VIA GO2'));
    // One twisted pair crosses the room in place of the table plate.
    expect(models, contains('DTP HDMI 4K 230 Tx'));
    expect(models, contains('DTP HDMI 4K 230 Rx'));
  });

  test('the one-projector classroom names its speakers', () {
    final basic = presets.firstWhere((p) => p.name == 'Basic classroom');
    // 8 ohm rather than the 70V SM 28T: this room's IN1608 SA drives them
    // directly off its own amplifier.
    expect(basic.nodes.map((n) => n.model), contains('SM 28 Black'));
  });

  test('every cable lands on a port that exists', () {
    final offenders = <String>[];
    for (final preset in presets) {
      final ports = <String, Set<String>>{
        for (final n in preset.nodes) n.id: {for (final p in n.ports) p.id},
      };
      for (final cable in preset.cables) {
        final from = ports[cable.fromNodeId];
        final to = ports[cable.toNodeId];
        if (from == null) {
          offenders.add('${preset.name}/${cable.id}: no node '
              '${cable.fromNodeId}');
        } else if (!from.contains(cable.fromPortId)) {
          offenders.add('${preset.name}/${cable.id}: '
              '${cable.fromNodeId} has no port ${cable.fromPortId}');
        }
        if (to == null) {
          offenders.add('${preset.name}/${cable.id}: no node '
              '${cable.toNodeId}');
        } else if (!to.contains(cable.toPortId)) {
          offenders.add('${preset.name}/${cable.id}: '
              '${cable.toNodeId} has no port ${cable.toPortId}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('no cable is drawn twice', () {
    for (final preset in presets) {
      final seen = <String>{};
      for (final c in preset.cables) {
        final ends = [
          '${c.fromNodeId}.${c.fromPortId}',
          '${c.toNodeId}.${c.toPortId}',
        ]..sort();
        expect(seen.add(ends.join(' <-> ')), isTrue,
            reason: '${preset.name}: ${c.id} duplicates an earlier cable');
      }
      expect(preset.cables.map((c) => c.id).toSet(),
          hasLength(preset.cables.length),
          reason: '${preset.name}: two cables share an id');
    }
  });

  test('every node sits in a location the preset ships', () {
    final offenders = <String>[];
    for (final preset in presets) {
      final ids = {for (final l in preset.locations) l.id};
      for (final node in preset.nodes) {
        if (node.locationId.isEmpty) continue;
        if (!ids.contains(node.locationId)) {
          offenders.add('${preset.name}/${node.id}: ${node.locationId}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('every rack slot names a rack and a node the preset ships', () {
    final offenders = <String>[];
    for (final preset in presets) {
      final rackIds = {for (final r in preset.racks) r.id};
      final nodeIds = {for (final n in preset.nodes) n.id};
      preset.rackSlots.forEach((nodeId, slot) {
        if (!nodeIds.contains(nodeId)) {
          offenders.add('${preset.name}: slot for missing node $nodeId');
        }
        if (!rackIds.contains(slot.rackId)) {
          offenders.add('${preset.name}/$nodeId: no rack ${slot.rackId}');
        }
      });
    }
    expect(offenders, isEmpty);
  });

  test('every screen switch run names locations the preset ships', () {
    final offenders = <String>[];
    for (final preset in presets) {
      final ids = {for (final l in preset.locations) l.id};
      for (final run in preset.screenSwitches) {
        for (final loc in [run.startLocationId, run.endLocationId]) {
          if (loc.isEmpty) continue;
          if (!ids.contains(loc)) {
            offenders.add('${preset.name}/${run.id}: $loc');
          }
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('every named model is in the catalog', () {
    final catalog = File('av_devices.json');
    expect(catalog.existsSync(), isTrue,
        reason: 'the catalog has to be there for this to mean anything');
    final doc = jsonDecode(catalog.readAsStringSync()) as Map;
    final known = {
      for (final d in (doc['devices'] as List))
        (d as Map)['model'].toString().trim().toLowerCase(),
    };

    final offenders = <String>[];
    for (final preset in presets) {
      for (final node in preset.nodes) {
        // A jack field's "model" is its own count ("3-jack field"), and a
        // generic box (the ceiling speakers, the AV LAN switch) is deliberately
        // nameless — the model is what the room chooses, not what the preset
        // does.
        if (node.isJackField) continue;
        final model = node.model.trim();
        if (model.isEmpty) continue;
        if (!known.contains(model.toLowerCase())) {
          offenders.add('${preset.name}/${node.label}: "$model"');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'these models are not in av_devices.json');
  });

  test('a node that names a model uses that model\'s port ids', () async {
    // The point of naming the model is that the preset and the catalog are the
    // same device. A port id the catalog does not have is a cable that comes
    // adrift the moment somebody re-picks the model on the device tab.
    final library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');

    final offenders = <String>[];
    for (final preset in presets) {
      for (final node in preset.nodes) {
        if (node.isJackField || node.model.trim().isEmpty) continue;
        final template = library.templateForModel(node.model);
        if (template == null) continue;
        final catalogPorts = {for (final p in template.ports) p.id};
        for (final port in node.ports) {
          if (!catalogPorts.contains(port.id)) {
            offenders.add('${preset.name}/${node.label} (${node.model}): '
                '${port.id}');
          }
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'these ports are not on the catalog entry for that model');
  });
}
