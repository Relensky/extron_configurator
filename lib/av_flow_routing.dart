import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'room_locations.dart';

/// ============================================================================
///  DRAWING THE ROUTING THE CONFIG ALREADY KNOWS
/// ============================================================================
///  A finished control config is a wiring list written in switcher numbers.
///  `input_pc` is 1 because the room PC is on input 1; `output_proj_1` is "3B"
///  because the projector hangs off output 3's DTP connector; and the
///  projector's own `input` says HDBaseT because that is the socket the lead
///  goes into at the far end. Three facts, and between them they say exactly
///  which cable runs where.
///
///  None of that reached the diagram. `_seedFromConfig` places the config's
///  DEVICES and stops: the sources — the PC, the doc cam, the laptop plate,
///  the USB-C plate — are not config blocks at all, so they never appeared,
///  and not one cable was drawn. Somebody then read the numbers back off the
///  System tab and drew the room by hand, which is the same information
///  entered twice and the reason a drawing and a config disagree.
///
///  So: read the numbers, resolve them onto real connectors, and draw it.
///
///  RESOLVING A NUMBER ONTO A CONNECTOR is the whole difficulty, because the
///  number in the config is the number printed on the box, and the catalog
///  records connectors by NAME. The two only meet in the label: input 3 is the
///  input port whose label ends in 3 — "HDMI 3" on a DTP CrossPoint 84 4K
///  IPCP MA 70, "HDMI 003" on the plain 84 4K, "HDMI IN 3" on an IN1608 SA.
///  Matching on the label's trailing number covers all three and every other
///  Extron front panel, without a table of models to keep up to date.
///
///  Outputs carry a letter as well ("3B" is output 3's B connector), and there
///  the labels stop agreeing: the MA 70 spells it "DTP OUT 003B" and the plain
///  84 4K calls the same socket "DTP OUT 1". An exact number+letter match gets
///  the first; nothing gets the second, and rather than guess — a cable drawn
///  to the wrong output is worse than no cable, because it looks checked — it
///  goes on the unresolved list with the value that could not be placed, for
///  somebody to draw by hand.
/// ============================================================================

/// Video signals a switcher tie can be about. Audio-only ties are drawn too
/// (the program feed, the ALD) but they resolve against the audio ports.
const Set<SignalType> _videoSignals = {
  SignalType.hdmi,
  SignalType.hdbaset,
  SignalType.displayPort,
  SignalType.usbC,
  SignalType.sdi,
  SignalType.vga,
};

/// Line-level audio: what a DSP, an assisted-listening transmitter or a
/// capture card is fed with. Kept apart from [_speakerAudio] because a
/// switcher with an amplifier in it has both, and `output_audio: "1"` means
/// the line output when it is feeding a DSP and the amp output when it is
/// feeding the ceiling.
const Set<SignalType> _lineAudio = {
  SignalType.analogAudio,
  SignalType.digitalAudio,
  SignalType.dante,
};

const Set<SignalType> _speakerAudio = {SignalType.speaker};

/// One source the config names but the diagram has no box for.
///
/// The room's own gear is already on the canvas — a camera and a wireless
/// receiver are config blocks and `_seedFromConfig` places them. These are the
/// other kind of source: the ones that are a plate, a lead and somebody's
/// laptop, which no config block was ever going to describe.
class _SourceSpec {
  final String label;
  final String model;

  /// Where it belongs in the room. Sources sit at the lectern; the two
  /// disc players sit in the rack.
  final RoomZone zone;

  const _SourceSpec(this.label, this.model, [this.zone = RoomZone.lectern]);
}

/// The `input_*` keys that mean "a box nobody wrote a control block for".
///
/// `input_usb` is one key with two meanings — the room has a USB-C plate or it
/// has a VGA plate, and `gui_usb_or_vga` says which — so it is resolved at
/// plan time rather than listed here.
const Map<String, _SourceSpec> _passiveSources = {
  'input_pc': _SourceSpec('Room PC', 'PC'),
  'input_doc_cam': _SourceSpec('Document camera', 'Document Camera'),
  'input_hdmi': _SourceSpec('Laptop at the HDMI plate', 'HDMI Laptop'),
  'input_dvd': _SourceSpec('DVD player', 'DVD Player', RoomZone.rack),
  'input_blu_ray': _SourceSpec('Blu-ray player', 'Blu-ray Player',
      RoomZone.rack),
};

/// The `input_*` keys that name a device the config DOES describe, so the box
/// is already on the canvas and only the cable is missing.
const Map<String, String> _deviceSources = {
  'input_wireless': 'WIRELESSDEVICE_1',
  'input_inst_cam': 'CAMERADEVICE_1',
  'input_aud_cam': 'CAMERADEVICE_2',
};

/// The `output_*` keys that feed a device the config describes.
///
/// The display outputs are the one-to-one pairing the config guarantees:
/// `output_proj_2` is PROJECTORDEVICE_2 and cannot be anything else. Capture
/// is looser — a room's capture card is a MediaPort in one build and an AV
/// Bridge in another — so those two are resolved by looking for whichever the
/// room actually has.
const Map<String, String> _deviceDestinations = {
  'output_proj_1': 'PROJECTORDEVICE_1',
  'output_proj_2': 'PROJECTORDEVICE_2',
  'output_proj_3': 'PROJECTORDEVICE_3',
  'output_proj_4': 'PROJECTORDEVICE_4',
};

/// The `output_*` keys that feed a box no control block describes.
const Map<String, _SourceSpec> _passiveDestinations = {
  'output_monitor_1': _SourceSpec('Confidence monitor', 'Confidence Monitor'),
  'output_monitor_2':
      _SourceSpec('Confidence monitor 2', 'Confidence Monitor'),
  'output_audio_ald':
      _SourceSpec('Assisted listening', 'Assisted Listening', RoomZone.rack),
};

/// One cable the routing would draw.
class RoutedCable {
  /// The config key this came from, so the review can say WHY the cable is
  /// there — 'input_pc' rather than 'somebody decided'.
  final String configKey;

  /// The value that key held ('1', '3B'). Printed next to the cable in the
  /// review, because that number is the thing being trusted.
  final String value;

  final String fromNodeId;
  final String fromPortId;
  final String fromPortLabel;
  final String toNodeId;
  final String toPortId;
  final String toPortLabel;
  final SignalType signal;

  /// What each end is called, for a review that reads as a sentence.
  final String fromLabel;
  final String toLabel;

  const RoutedCable({
    required this.configKey,
    required this.value,
    required this.fromNodeId,
    required this.fromPortId,
    required this.fromPortLabel,
    required this.toNodeId,
    required this.toPortId,
    required this.toPortLabel,
    required this.signal,
    required this.fromLabel,
    required this.toLabel,
  });

  String get summary =>
      '$fromLabel ($fromPortLabel) → $toLabel ($toPortLabel)';
}

/// A tie the config states that could not be drawn, and the reason.
///
/// Reported rather than swallowed: an output the catalog spells differently
/// from the front panel is a real gap in the catalog entry, and the tech is
/// the only one who can say which socket was meant.
class UnroutedTie {
  final String configKey;
  final String value;
  final String reason;

  const UnroutedTie(this.configKey, this.value, this.reason);
}

/// What drawing the routing would do, worked out before anything is drawn.
class RoutingPlan {
  /// Boxes to add, keyed by the node id they will be given.
  final List<AvNode> newNodes;

  final List<RoutedCable> cables;
  final List<UnroutedTie> unresolved;

  /// Cables already on the diagram that this would have drawn — counted so the
  /// review can say why the number is smaller than the config's.
  final int alreadyDrawn;

  const RoutingPlan({
    this.newNodes = const [],
    this.cables = const [],
    this.unresolved = const [],
    this.alreadyDrawn = 0,
  });

  bool get isEmpty => newNodes.isEmpty && cables.isEmpty;
}

// ---------------------------------------------------------------------------
//  RESOLVING A CONFIG NUMBER ONTO A CONNECTOR
// ---------------------------------------------------------------------------

/// A connector reference: the number printed on the box, the letter that picks
/// between that output's two sockets, or both.
///
/// All three spellings turn up in real configs. `input_pc: "1"` is a number;
/// `output_proj_1: "3B"` is output 3's B socket on a DTP CrossPoint; and
/// `output_proj_1: "C"` is an IN1608, whose three mirrored outputs are lettered
/// A, B and C with no numbers at all. The processor strips non-digits and
/// works on the number, but the letter is not noise to a DRAWING — it is the
/// difference between the HDMI socket and the DTP socket, which is a different
/// cable to a different box.
typedef ConnectorRef = ({int? number, String letter});

/// Reads a config I/O value: '3B', '1', 'C'.
ConnectorRef parseIoValue(String raw) {
  final v = raw.trim();
  final both = RegExp(r'^(\d+)\s*([A-Za-z])?$').firstMatch(v);
  if (both != null) {
    return (
      number: int.tryParse(both.group(1)!),
      letter: (both.group(2) ?? '').toUpperCase(),
    );
  }
  final letterOnly = RegExp(r'^([A-Za-z])$').firstMatch(v);
  if (letterOnly != null) {
    return (number: null, letter: letterOnly.group(1)!.toUpperCase());
  }
  return (number: null, letter: '');
}

/// Reads a port label the same way: 'HDMI 003' -> 3, 'DTP OUT 003B' -> 3B,
/// 'DTP OUT C' -> C, 'AUDIO OUT' -> neither.
///
/// A trailing letter only counts when it stands alone or follows the digits —
/// otherwise every label ending in a word ('HDMI') would read as a connector
/// letter.
ConnectorRef parsePortLabel(String label) {
  final trimmed = label.trim();
  final both = RegExp(r'(\d+)\s*([A-Za-z])?\s*$').firstMatch(trimmed);
  if (both != null) {
    return (
      number: int.tryParse(both.group(1)!),
      letter: (both.group(2) ?? '').toUpperCase(),
    );
  }
  final letterOnly = RegExp(r'(?:^|\s)([A-Za-z])$').firstMatch(trimmed);
  if (letterOnly != null) {
    return (number: null, letter: letterOnly.group(1)!.toUpperCase());
  }
  return (number: null, letter: '');
}

/// The signal an output's connector letter implies on Extron gear: A is the
/// HDMI socket of that output, B the DTP/HDBaseT one.
SignalType? _signalForLetter(String letter) => switch (letter) {
      'A' => SignalType.hdmi,
      'B' => SignalType.hdbaset,
      _ => null,
    };

/// The port on [node] that switcher I/O [value] names, or null.
///
/// [wantOutput] picks which side of the box to look at and [signals] which kind
/// of connector, so a program-audio output is not competing with the HDMI
/// outputs for the number 1.
///
/// The passes get steadily less certain and stop before they start guessing,
/// because a cable drawn to the wrong socket is worse than no cable — it looks
/// checked:
///
///   1. one candidate of that kind, so there is nothing to choose between;
///   2. the number AND the letter ('3B' -> 'DTP OUT 003B');
///   3. the letter alone ('C' -> 'DTP OUT C');
///   4. the number alone, preferring an unlettered socket;
///   5. the CONNECTOR CONVENTION, for a lettered value whose catalog entry
///      counts connectors instead of outputs — see below;
///   6. nothing.
///
/// Pass 5 is the one that earns its keep. Half the DTP CrossPoint entries label
/// an 84's two DTP sockets "DTP OUT 1" and "DTP OUT 2" — a per-connector
/// counter, not the output numbers — so `output_proj_1: "3B"` matches neither.
/// But the model number says the box has four outputs, and Extron always puts
/// the DTP sockets on the LAST of them, so two DTP connectors on a four-output
/// box are outputs 3 and 4: "3B" is DTP OUT 1. That inference needs
/// [declaredOutputs]; without it (an unparseable model) the pass is skipped and
/// the tie is reported instead.
AvPort? portForIoValue(
  AvNode node,
  String value, {
  required bool wantOutput,
  Set<SignalType> signals = _videoSignals,
  int declaredOutputs = 0,
}) {
  final want = parseIoValue(value);
  if (want.number == null && want.letter.isEmpty) return null;

  final candidates = node.ports.where((p) {
    if (!signals.contains(p.signal)) return false;
    return wantOutput ? p.isOutput : p.isInput;
  }).toList();
  if (candidates.isEmpty) return null;

  // 1. Nothing to choose between.
  if (candidates.length == 1) return candidates.first;

  final refs = {for (final p in candidates) p: parsePortLabel(p.label)};

  // 2. Number and letter both stated, and a label agrees on both.
  if (want.number != null && want.letter.isNotEmpty) {
    for (final e in refs.entries) {
      if (e.value.number == want.number && e.value.letter == want.letter) {
        return e.key;
      }
    }
  }

  // 3. A letter on its own — the IN1608's A/B/C outputs.
  if (want.number == null && want.letter.isNotEmpty) {
    final matches = [
      for (final e in refs.entries)
        if (e.value.number == null && e.value.letter == want.letter) e.key,
    ];
    if (matches.length == 1) return matches.first;
    return null;
  }

  // 4. The number, preferring the socket with no letter after it.
  final sameNumber = [
    for (final e in refs.entries)
      if (e.value.number == want.number) e.key,
  ];
  if (want.letter.isEmpty) {
    for (final p in sameNumber) {
      if (refs[p]!.letter.isEmpty) return p;
    }
    if (sameNumber.length == 1) return sameNumber.first;
    return null;
  }

  // 5. The connector convention, for a catalog entry that counts connectors.
  final signal = _signalForLetter(want.letter);
  if (signal == null || declaredOutputs <= 0) return null;
  final ofSignal = [
    for (final e in refs.entries)
      if (e.key.signal == signal && e.value.number != null) e.key,
  ]..sort((a, b) => refs[a]!.number!.compareTo(refs[b]!.number!));
  if (ofSignal.isEmpty) return null;

  // Only when they really are a 1..d counter. Anything else is already the
  // output numbers, and pass 2 would have matched.
  for (int i = 0; i < ofSignal.length; i++) {
    if (refs[ofSignal[i]]!.number != i + 1) return null;
  }
  final firstOutput = declaredOutputs - ofSignal.length + 1;
  final index = want.number! - firstOutput;
  if (index < 0 || index >= ofSignal.length) return null;
  return ofSignal[index];
}

/// The port on a display named by its config block's `input` ('HDBaseT',
/// 'HDMI 1'), or null when the block does not say or the label is not there.
///
/// This is the far end of the run, and the config states it outright — no
/// number to resolve, just a socket by name. Matched case- and space-
/// insensitively, so 'HDBaseT', 'HDBASET' and 'HDBase-T' are one socket.
AvPort? portForDeviceInput(AvNode node, String inputValue) {
  final want = _flatten(inputValue);
  if (want.isEmpty) return null;
  for (final p in node.ports) {
    if (!p.isInput && p.direction != PortDirection.bidirectional) continue;
    if (!_videoSignals.contains(p.signal)) continue;
    if (_flatten(p.label) == want) return p;
  }
  // 'HDBaseT' against a port spelled 'DTP IN' and the like: fall back to the
  // one input of that signal type when the box has exactly one.
  final signal = _signalForInputName(want);
  if (signal != null) {
    final matches = node.ports
        .where((p) => p.signal == signal && (p.isInput ||
            p.direction == PortDirection.bidirectional))
        .toList();
    if (matches.length == 1) return matches.first;
  }
  return null;
}

String _flatten(String s) =>
    s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

SignalType? _signalForInputName(String flattened) {
  if (flattened.startsWith('hdbaset') || flattened.startsWith('dtp')) {
    return SignalType.hdbaset;
  }
  if (flattened.startsWith('hdmi')) return SignalType.hdmi;
  if (flattened.startsWith('displayport') || flattened.startsWith('dp')) {
    return SignalType.displayPort;
  }
  if (flattened.startsWith('vga') || flattened.startsWith('computer')) {
    return SignalType.vga;
  }
  if (flattened.startsWith('usbc') || flattened.startsWith('typec')) {
    return SignalType.usbC;
  }
  return null;
}

/// The first video OUTPUT on a source box — the connector its lead leaves by.
AvPort? _sourceOutputPort(AvNode node) {
  for (final p in node.ports) {
    if (p.isOutput && _videoSignals.contains(p.signal)) return p;
  }
  return null;
}

// ---------------------------------------------------------------------------
//  PLANNING
// ---------------------------------------------------------------------------

/// Works out what drawing the config's routing would add, without drawing it.
///
/// Everything hangs off the MAIN switcher (SWITCHERDEVICE_1): it is the box
/// every `input_*` and `output_*` number is a number on. A room with no
/// switcher block, or one that is not on the canvas yet, gets an empty plan
/// and a reason — there is nothing to route through.
RoutingPlan planRoutingFromConfig(AppStateProvider provider) {
  final config = provider.roomConfig;
  final setup = config['SYSTEM_SETUP'];
  if (setup is! Map) {
    return const RoutingPlan(
      unresolved: [
        UnroutedTie('SYSTEM_SETUP', '',
            'This room has no SYSTEM_SETUP block, so there are no switcher '
            'numbers to draw.'),
      ],
    );
  }

  final nodesById = {for (final n in provider.avNodes) n.id: n};
  final switcher = nodesById['SWITCHERDEVICE_1'];
  if (switcher == null) {
    return RoutingPlan(
      unresolved: [
        UnroutedTie(
          'SWITCHERDEVICE_1',
          '',
          config.containsKey('SWITCHERDEVICE_1')
              ? 'The main switcher is not on the canvas yet — press "Place all '
                  'from config" first, then draw the routing.'
              : 'This room has no SWITCHERDEVICE_1, and every input_ and '
                  'output_ number is a number on that box.',
        ),
      ],
    );
  }

  final newNodes = <AvNode>[];
  final cables = <RoutedCable>[];
  final unresolved = <UnroutedTie>[];
  int alreadyDrawn = 0;

  // How many outputs the box HAS, which its connector labels do not always
  // say — see [portForIoValue] pass 5.
  final declaredOutputs =
      AvDeviceLibrary.switcherSize(switcher.model).$2;

  // Somewhere to put a box that has to be created. Sources go down the left of
  // whatever is already drawn, destinations down the right.
  double leftY = 60, rightY = 60;
  double rightX = 40;
  for (final n in provider.avNodes) {
    rightX = math.max(rightX, n.pos.dx + 340);
  }

  final lectern = _locationFor(provider, RoomZone.lectern);
  final rack = _locationFor(provider, RoomZone.rack);
  final wall = _locationFor(provider, RoomZone.wall);

  AvNode place(_SourceSpec spec, String nodeId, {required bool onLeft}) {
    final template = provider.avDeviceLibrary.resolve(
      configKey: nodeId,
      model: spec.model,
    );
    final y = onLeft ? leftY : rightY;
    final node = AvNode(
      id: nodeId,
      label: spec.label,
      model: spec.model,
      pos: Offset(onLeft ? 40 : rightX, y),
      ports: withPowerInlet(template.ports, template.powerInput),
      rackUnits: template.rackUnits,
      powerWatts: template.powerWatts,
      btuPerHour: template.btuPerHour,
      powerSource: powerSourceForInput(template.powerInput),
      locationId: switch (spec.zone) {
        RoomZone.rack => rack,
        RoomZone.wall => wall,
        _ => lectern,
      },
    );
    if (onLeft) {
      leftY = y + node.height + 30;
    } else {
      rightY = y + node.height + 30;
    }
    newNodes.add(node);
    return node;
  }

  /// Records one tie, unless the same two connectors are already joined.
  void draw({
    required String configKey,
    required String value,
    required AvNode from,
    required AvPort fromPort,
    required AvNode to,
    required AvPort toPort,
    required SignalType signal,
  }) {
    final drawn = provider.avCables.any((c) =>
        (c.fromNodeId == from.id &&
            c.fromPortId == fromPort.id &&
            c.toNodeId == to.id &&
            c.toPortId == toPort.id) ||
        (c.fromNodeId == to.id &&
            c.fromPortId == toPort.id &&
            c.toNodeId == from.id &&
            c.toPortId == fromPort.id));
    if (drawn) {
      alreadyDrawn++;
      return;
    }
    if (cables.any((c) =>
        c.fromNodeId == from.id &&
        c.fromPortId == fromPort.id &&
        c.toNodeId == to.id &&
        c.toPortId == toPort.id)) {
      return;
    }
    cables.add(RoutedCable(
      configKey: configKey,
      value: value,
      fromNodeId: from.id,
      fromPortId: fromPort.id,
      fromPortLabel: fromPort.label,
      toNodeId: to.id,
      toPortId: toPort.id,
      toPortLabel: toPort.label,
      signal: signal,
      fromLabel: from.label,
      toLabel: to.label,
    ));
  }

  // --- the sources -----------------------------------------------------------
  //  Every one of these is "this box is on switcher input N", so they all end
  //  the same way: find input N on the switcher, find the box's own output,
  //  and join the two.

  void routeSource(String key, AvNode source, {AvPort? fromPort}) {
    final value = setup[key]?.toString().trim() ?? '';
    if (value.isEmpty) return;
    final switcherPort =
        portForIoValue(switcher, value, wantOutput: false);
    if (switcherPort == null) {
      unresolved.add(UnroutedTie(key, value,
          'No input on ${switcher.label} is labelled $value.'));
      return;
    }
    final out = fromPort ?? _sourceOutputPort(source);
    if (out == null) {
      unresolved.add(UnroutedTie(key, value,
          '${source.label} has no video output to run from.'));
      return;
    }
    draw(
      configKey: key,
      value: value,
      from: source,
      fromPort: out,
      to: switcher,
      toPort: switcherPort,
      // The cable is whatever the switcher's connector is: a source on
      // 'DTP IN 7' is an HDBaseT run whatever the box at the far end calls
      // its own socket.
      signal: switcherPort.signal,
    );
  }

  // The room PC, and its extended desktop on a second lead. A PC drawn from
  // the generic catalog entry has one output, so the second one is added here
  // rather than pretending the room has two PCs.
  AvNode? pc;
  final pcValue = setup['input_pc']?.toString().trim() ?? '';
  final pcExtended = setup['input_pc_extended']?.toString().trim() ?? '';
  if (pcValue.isNotEmpty || pcExtended.isNotEmpty) {
    pc = _existingByModelOrLabel(provider, const ['PC', 'PC Micro'], 'pc') ??
        place(_passiveSources['input_pc']!, _freeId(provider, newNodes),
            onLeft: true);
    if (pcExtended.isNotEmpty) {
      final outs = pc.ports
          .where((p) => p.isOutput && _videoSignals.contains(p.signal))
          .toList();
      if (outs.length < 2) {
        final added = AvPort(
          id: 'out_extended',
          label: 'HDMI OUT 2',
          signal: SignalType.hdmi,
          direction: PortDirection.output,
          side: PortSide.right,
        );
        pc = pc.copyWith(ports: [...pc.ports, added]);
        final at = newNodes.indexWhere((n) => n.id == pc!.id);
        if (at >= 0) newNodes[at] = pc;
      }
    }
  }
  if (pc != null) {
    final outs = pc.ports
        .where((p) => p.isOutput && _videoSignals.contains(p.signal))
        .toList();
    if (pcValue.isNotEmpty) {
      routeSource('input_pc', pc, fromPort: outs.isEmpty ? null : outs.first);
    }
    if (pcExtended.isNotEmpty) {
      routeSource('input_pc_extended', pc,
          fromPort: outs.length > 1 ? outs[1] : null);
    }
  }

  for (final entry in _passiveSources.entries) {
    if (entry.key == 'input_pc') continue; // handled above, with its second lead
    final value = setup[entry.key]?.toString().trim() ?? '';
    if (value.isEmpty) continue;
    final existing =
        _existingByModelOrLabel(provider, [entry.value.model], entry.key);
    final node = existing ??
        place(entry.value, _freeId(provider, newNodes), onLeft: true);
    routeSource(entry.key, node);
  }

  // The laptop plate that is a USB-C plate in a new room and a VGA plate in an
  // old one. One switcher input, one key, and gui_usb_or_vga says which lead
  // is actually hanging off it — so the box drawn has to follow that setting
  // or the drawing contradicts the panel's own button.
  final usbValue = setup['input_usb']?.toString().trim() ?? '';
  if (usbValue.isNotEmpty) {
    final isVga =
        (setup['gui_usb_or_vga']?.toString().trim().toUpperCase() ?? 'USB') ==
            'VGA';
    final spec = isVga
        ? const _SourceSpec('Laptop at the VGA plate', 'VGA Laptop')
        : const _SourceSpec('Laptop at the USB-C plate', 'USB-C Laptop');
    final existing =
        _existingByModelOrLabel(provider, [spec.model], 'input_usb');
    final node =
        existing ?? place(spec, _freeId(provider, newNodes), onLeft: true);
    routeSource('input_usb', node);
  }

  for (final entry in _deviceSources.entries) {
    final value = setup[entry.key]?.toString().trim() ?? '';
    if (value.isEmpty) continue;
    final node = nodesById[entry.value];
    if (node == null) {
      unresolved.add(UnroutedTie(entry.key, value,
          '${entry.value} is not on the canvas.'));
      continue;
    }
    routeSource(entry.key, node);
  }

  // A sub switcher hangs off one input of the main one, and the key names that
  // input. Which block is the sub switcher is sub_switch_switcher (2 or 3).
  final subInput = setup['input_sub_switcher']?.toString().trim() ?? '';
  if (subInput.isNotEmpty) {
    final which = setup['sub_switch_switcher']?.toString().trim() ?? '2';
    final sub = nodesById['SWITCHERDEVICE_$which'];
    if (sub == null) {
      unresolved.add(UnroutedTie('input_sub_switcher', subInput,
          'SWITCHERDEVICE_$which is not on the canvas.'));
    } else {
      routeSource('input_sub_switcher', sub);
    }
  }

  // --- the destinations ------------------------------------------------------
  //  The mirror image: find output N on the switcher, find the socket the far
  //  box's own config says the lead goes into, and join those.

  void routeDestination(
    String key,
    AvNode dest, {
    AvPort? toPort,
    Set<SignalType> signals = _videoSignals,
  }) {
    final value = setup[key]?.toString().trim() ?? '';
    if (value.isEmpty) return;
    // The documented 'None': a display this switcher does not drive. Not a
    // failure to resolve — a statement that there is no cable.
    if (value.toLowerCase() == 'none') return;
    final switcherPort = portForIoValue(
      switcher,
      value,
      wantOutput: true,
      signals: signals,
      declaredOutputs: declaredOutputs,
    );
    if (switcherPort == null) {
      unresolved.add(UnroutedTie(key, value,
          'No output on ${switcher.label} is labelled $value. Extron spells '
          'the same socket differently between models — check the connector '
          'names on the device tab and draw this one by hand.'));
      return;
    }
    final landing = toPort ??
        dest.ports
            .where((p) =>
                signals.contains(p.signal) &&
                (p.isInput || p.direction == PortDirection.bidirectional))
            .firstOrNull;
    if (landing == null) {
      unresolved.add(UnroutedTie(
          key, value, '${dest.label} has no matching input to land on.'));
      return;
    }
    draw(
      configKey: key,
      value: value,
      from: switcher,
      fromPort: switcherPort,
      to: dest,
      toPort: landing,
      signal: switcherPort.signal,
    );
  }

  final projectorCount =
      int.tryParse(setup['dev_projectors']?.toString().trim() ?? '') ?? 0;

  for (final entry in _deviceDestinations.entries) {
    final value = setup[entry.key]?.toString().trim() ?? '';
    if (value.isEmpty || value.toLowerCase() == 'none') continue;
    final node = nodesById[entry.value];
    if (node == null) {
      // A display output for a display the room does not have. Worth saying
      // out loud rather than reporting as a missing box: the number is dead
      // config left behind when the room shrank, and it will go on looking
      // like a second projector to everyone who reads the file.
      final number = int.tryParse(
              entry.value.substring('PROJECTORDEVICE_'.length)) ??
          0;
      if (number > projectorCount && projectorCount > 0) {
        unresolved.add(UnroutedTie(
            entry.key,
            value,
            'This room has $projectorCount display'
            '${projectorCount == 1 ? '' : 's'} (dev_projectors), so there is '
            'no ${entry.value} for output $value to feed — the key is left '
            'over and nothing is drawn for it.'));
      } else {
        unresolved.add(UnroutedTie(entry.key, value,
            '${entry.value} is not on the canvas.'));
      }
      continue;
    }
    // The display's OWN config says which socket the lead goes into. That is
    // the fact this whole feature turns on: 'HDBaseT' on the projector block
    // is not a preference, it is the connector somebody plugged into.
    final block = config[entry.value];
    final declared =
        (block is Map ? block['input']?.toString() : null)?.trim() ?? '';
    AvPort? landing =
        declared.isEmpty ? null : portForDeviceInput(node, declared);
    if (declared.isNotEmpty && landing == null) {
      unresolved.add(UnroutedTie(
          '${entry.value}.input',
          declared,
          '${node.label} has no connector called "$declared" — the cable is '
          'drawn on its first video input instead.'));
    }
    routeDestination(entry.key, node, toPort: landing);
  }

  for (final entry in _passiveDestinations.entries) {
    final value = setup[entry.key]?.toString().trim() ?? '';
    if (value.isEmpty || value.toLowerCase() == 'none') continue;
    final existing =
        _existingByModelOrLabel(provider, [entry.value.model], entry.key);
    final node = existing ??
        place(entry.value, _freeId(provider, newNodes), onLeft: false);
    routeDestination(
      entry.key,
      node,
      signals: entry.key == 'output_audio_ald' ? _lineAudio : _videoSignals,
    );
  }

  // Program audio: to the DSP when the room has one — that is what "DSP
  // system" mode means — and to the ceiling speakers otherwise, where the
  // amplifier is inside the switcher (an SA or MA build) and the cable is
  // speaker level rather than line.
  final audioValue = setup['output_audio']?.toString().trim() ?? '';
  if (audioValue.isNotEmpty && audioValue.toLowerCase() != 'none') {
    final dsp = nodesById['DSPDEVICE_1'];
    if (dsp != null) {
      routeDestination('output_audio', dsp, signals: _lineAudio);
    } else {
      final existing = _existingByModelOrLabel(
          provider, const ['Ceiling Speakers'], 'output_audio');
      final node = existing ??
          place(
              const _SourceSpec(
                  'Ceiling speakers', 'Ceiling Speakers', RoomZone.ceiling),
              _freeId(provider, newNodes),
              onLeft: false);
      routeDestination('output_audio', node, signals: _speakerAudio);
    }
  }

  // Capture: whichever box this room makes its USB feed with.
  for (final key in const ['output_cc', 'output_cc2']) {
    final value = setup[key]?.toString().trim() ?? '';
    if (value.isEmpty || value.toLowerCase() == 'none') continue;
    final node = nodesById['MEDIAPORTDEVICE_1'] ??
        nodesById['RECORDERDEVICE_1'] ??
        nodesById['USBDEVICE_1'];
    if (node == null) {
      unresolved.add(UnroutedTie(key, value,
          'This room has no MediaPort, recorder or USB switcher on the canvas '
          'for the capture feed to land on.'));
      continue;
    }
    routeDestination(key, node);
  }

  return RoutingPlan(
    newNodes: newNodes,
    cables: cables,
    unresolved: unresolved,
    alreadyDrawn: alreadyDrawn,
  );
}

/// A node already on the canvas that IS one of these models, or whose label
/// says so. Keeps a second press from drawing a second PC next to the first.
AvNode? _existingByModelOrLabel(
  AppStateProvider provider,
  List<String> models,
  String key,
) {
  final wanted = {for (final m in models) _flatten(m)};
  for (final n in provider.avNodes) {
    if (n.isJackField) continue;
    if (wanted.contains(_flatten(n.model))) return n;
  }
  return null;
}

/// The next free `AVNODE_<n>`, counting the ones this plan has already claimed
/// as well as the ones on the canvas.
String _freeId(AppStateProvider provider, List<AvNode> pending) {
  final taken = {
    ...provider.avNodes.map((n) => n.id),
    ...pending.map((n) => n.id),
  };
  int n = 1;
  while (taken.contains('AVNODE_$n')) {
    n++;
  }
  return 'AVNODE_$n';
}

/// The room's location for a zone, or [kNoLocationId] when it has none. A box
/// drawn into a room that has recorded its locations should land in one;
/// a room with no locations yet is not given any.
String _locationFor(AppStateProvider provider, RoomZone zone) {
  for (final l in provider.avLocations) {
    if (l.zone == zone) return l.id;
  }
  return kNoLocationId;
}

// ---------------------------------------------------------------------------
//  DRAWING IT
// ---------------------------------------------------------------------------

/// What drawing the routing actually did.
typedef RoutingResult = ({int nodesAdded, int cablesDrawn, int unresolved});

/// Draws [plan] onto the canvas.
///
/// Nothing is destructive: an existing cable between the same two connectors
/// is left alone (it was counted as `alreadyDrawn` when the plan was made),
/// and no cable somebody drew by hand is removed — a tie the config does not
/// mention is not a tie the config says is wrong.
RoutingResult applyRoutingFromConfig(
  AppStateProvider provider,
  RoutingPlan plan,
) {
  for (final node in plan.newNodes) {
    provider.addAvNode(node, recordUndo: false);
  }

  int drawn = 0;
  for (final cable in plan.cables) {
    final added = provider.addAvCable(
      fromNodeId: cable.fromNodeId,
      fromPortId: cable.fromPortId,
      toNodeId: cable.toNodeId,
      toPortId: cable.toPortId,
      signal: cable.signal,
      label: '',
      recordUndo: false,
    );
    if (added != null) drawn++;
  }

  AppLogger.logInfo(
    'Drew the routing from the config: ${plan.newNodes.length} box(es) added, '
    '$drawn cable(s) drawn, ${plan.unresolved.length} tie(s) the numbers did '
    'not resolve.',
  );

  return (
    nodesAdded: plan.newNodes.length,
    cablesDrawn: drawn,
    unresolved: plan.unresolved.length,
  );
}
