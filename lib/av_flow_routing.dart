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

  /// True for a box the room does not buy. The laptop at a plate is the
  /// presenter's own machine: the plate and the lead are real, so the box
  /// belongs on the diagram, but putting it on the quote is quoting somebody
  /// for their own laptop. See [AvNode.excludeFromCost].
  final bool excludeFromCost;

  const _SourceSpec(
    this.label,
    this.model, [
    this.zone = RoomZone.lectern,
    this.excludeFromCost = false,
  ]);
}

/// The `input_*` keys that mean "a box nobody wrote a control block for".
///
/// `input_usb` is one key with two meanings — the room has a USB-C plate or it
/// has a VGA plate, and `gui_usb_or_vga` says which — so it is resolved at
/// plan time rather than listed here.
const Map<String, _SourceSpec> _passiveSources = {
  'input_pc': _SourceSpec('Room PC', 'PC'),
  'input_doc_cam': _SourceSpec('Document camera', 'Document Camera'),
  'input_hdmi': _SourceSpec(
      'Laptop at the HDMI plate', 'HDMI Laptop', RoomZone.lectern, true),
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

/// The box that goes in when the switcher end of a run is DTP and the display
/// end is HDMI.
///
/// A DTP output does not plug into a display. It is twisted pair carrying
/// HDBaseT, and it lands on a receiver at the room end which turns it back
/// into an HDMI lead a foot long. Everybody who builds these rooms knows that
/// and nobody writes it in the config — `output_proj_1: "3B"` and the
/// projector's `input: "HDMI 1"` are both true, and the receiver between them
/// is assumed. A drawing that joins those two directly is drawing a cable that
/// cannot exist, and an estimate taken off that drawing is missing a $600 box
/// per display.
///
/// The 230 rather than the 330: it is what the room presets build with, and it
/// is the entry whose catalog ports are complete enough to cable — see
/// [room_presets.dart]. Swap the model on the box if the run is longer than
/// 230 feet.
const _dtpReceiver = _SourceSpec(
  'Room-end DTP receiver',
  'DTP HDMI 4K 230 Rx',
  RoomZone.wall,
);

/// The box that goes in at the other end of the same problem: a source with an
/// HDMI output on a DTP input of the switcher.
///
/// The cameras are the ones this happens to — `input_inst_cam: "8"` on a DTP
/// CrossPoint is DTP IN 8, and a camera has an HDMI socket and nothing else.
/// Same fact as [_dtpReceiver], read the other way round: twisted pair at the
/// switcher end, a short HDMI lead at the far end, and a box where they meet
/// that the config never mentions because everybody knows it is there.
const _dtpTransmitter = _SourceSpec(
  'DTP transmitter',
  'DTP HDMI 4K 230 Tx',
);

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

  /// Nodes this would record as fed from a power controller outlet.
  ///
  /// Carried separately from the cable because they are two different facts:
  /// the cable is the lead, and [AvNode.powerSource] is what the Power
  /// Schedule prints in its Source column. Drawing the one and leaving the
  /// other saying "Not recorded" is a report that contradicts its own diagram.
  final List<String> powered;

  const RoutingPlan({
    this.newNodes = const [],
    this.cables = const [],
    this.unresolved = const [],
    this.alreadyDrawn = 0,
    this.powered = const [],
  });

  bool get isEmpty => newNodes.isEmpty && cables.isEmpty && powered.isEmpty;
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

/// The box's expansion-bus connector, or null when it has none.
///
/// Extron spells it 'DMP EXP' on both the switcher and the DMP, and other
/// families spell their own bus 'EXPANSION' or 'EXP' — matched on the word so
/// a new model does not need a table entry. Deliberately NOT matched on the
/// signal: the catalog files this connector under Dante on the boxes that
/// have it, and it is not a Dante socket in any sense a network engineer
/// would recognise.
AvPort? _expansionPort(AvNode node) {
  for (final p in node.ports) {
    final words = p.label.toUpperCase().split(RegExp(r'[^A-Z0-9]+'));
    if (words.contains('EXP') || words.contains('EXPANSION')) return p;
  }
  return null;
}

/// The connectors on [dest] a tie of [signals] could land on, in the order the
/// catalog lists them.
List<AvPort> landingCandidates(AvNode dest, Set<SignalType> signals) => [
      for (final p in dest.ports)
        if (signals.contains(p.signal) &&
            (p.isInput || p.direction == PortDirection.bidirectional))
          p,
    ];

/// How good a landing [port] is for a run leaving [fromPort], higher first.
///
/// A NUMBERED connector is a general-purpose one — 'MIC/LINE 1', 'HDMI IN 2',
/// 'AUDIO 3' — and a named one is almost always special-purpose: 'DMP EXP' is
/// the bus between two DSPs, 'ACP' is Extron's control pad, 'USB AUDIO' is the
/// box's own soundcard. None of the three is where a program feed lands, and
/// on a DMP 64 Plus C AT the expansion port is listed FIRST, so taking the
/// first matching connector drew the matrix into it every time.
///
/// Matching the source's own signal breaks the remaining ties, so a run stays
/// on one kind of connector when the box offers a conversion as well.
int landingRank(AvPort port, AvPort fromPort) =>
    (parsePortLabel(port.label).number != null ? 2 : 0) +
    (port.signal == fromPort.signal ? 1 : 0);

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
  int declaredInputs = 0,
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
  // 5. The TRAILING BLOCK, for a catalog entry that numbers a group of
  //    connectors from one.
  //
  //    A DTP CrossPoint 82 is eight inputs and two outputs, and its last two
  //    inputs are the twisted-pair ones. The catalog spells them 'DTP IN 1'
  //    and 'DTP IN 2' — what is printed on the connector — while the same two
  //    sockets on its 84 sibling are spelled 'DTP IN 7' and 'DTP IN 8'. So
  //    `input_hdmi: 7` resolved on one model and on nothing at all on the
  //    other, and a room built on the 82 had no way to say which input its
  //    wall plate was on.
  //
  //    The box says how many inputs it has, so the last group in connector
  //    order numbered 1..k is inputs N-k+1..N. Only a clean 1..k counter
  //    qualifies: anything else is already the real numbers, and pass 4 would
  //    have matched it.
  final declared = wantOutput ? declaredOutputs : declaredInputs;
  if (want.letter.isEmpty && sameNumber.isEmpty && declared > 0) {
    final lastSignal = refs.keys.last.signal;
    final tail = [
      for (final e in refs.entries)
        if (e.key.signal == lastSignal && e.value.number != null) e.key,
    ]..sort((a, b) => refs[a]!.number!.compareTo(refs[b]!.number!));
    bool counter = tail.isNotEmpty;
    for (int i = 0; i < tail.length; i++) {
      if (refs[tail[i]]!.number != i + 1) counter = false;
    }
    if (counter && tail.length < declared) {
      final index = want.number! - (declared - tail.length) - 1;
      if (index >= 0 && index < tail.length) return tail[index];
    }
  }

  if (want.letter.isEmpty) {
    for (final p in sameNumber) {
      if (refs[p]!.letter.isEmpty) return p;
    }
    if (sameNumber.length == 1) return sameNumber.first;
    return null;
  }

  // 6. The connector convention, for a catalog entry that counts connectors.
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
///
/// [respectDismissed] leaves out a box somebody took off the canvas by hand.
/// Only the automatic pass ([autoDrawRoutingFromConfig]) sets it; pressing
/// **Draw the routing from config** is an explicit "draw it again", the same
/// distinction the config seed makes between its silent first visit and
/// **Place all from config**.
RoutingPlan planRoutingFromConfig(
  AppStateProvider provider, {
  bool respectDismissed = false,
}) {
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
    // A room with no matrix AND no numbers is not a room with a problem. The
    // huddle space is the case: the wireless comes in over a DTP pair, the bar
    // and the PC go straight into the display's own HDMI sockets, and every
    // switcher I/O key is blank on purpose. Complaining that it has no
    // SWITCHERDEVICE_1 puts a red line on a room type that is drawn correctly.
    final stated = setup.entries.where((e) {
      final key = e.key.toString();
      if (!key.startsWith('input_') && !key.startsWith('output_')) return false;
      final value = e.value?.toString().trim() ?? '';
      return value.isNotEmpty && value.toLowerCase() != 'none';
    });
    if (stated.isEmpty) return const RoutingPlan();

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

  /// True when the box this field would place was deleted from the canvas.
  bool dismissed(String key) =>
      respectDismissed &&
      provider.avDismissedDevices.contains(avAutoNodeId(key));

  // How many outputs the box HAS, which its connector labels do not always
  // say — see [portForIoValue] pass 5.
  final declaredInputs = AvDeviceLibrary.switcherSize(switcher.model).$1;
  final declaredOutputs = AvDeviceLibrary.switcherSize(switcher.model).$2;

  // Somewhere to put a box that has to be created. Sources go down the left of
  // whatever is already drawn, destinations down the right.
  double leftY = kAvAutoOriginY, rightY = kAvAutoOriginY;
  double rightX = kAvAutoOriginX;
  for (final n in provider.avNodes) {
    rightX = math.max(rightX, n.pos.dx + kAvAutoColumnPitch);
    // Below what is already in the left column, not on top of it. A second
    // pass that adds one transmitter used to drop it at y=60 over the PC.
    if (n.pos.dx < kAvAutoColumnPitch) {
      leftY = math.max(leftY, n.pos.dy + n.height + kAvAutoRowGap);
    }
  }

  final lectern = _locationFor(provider, RoomZone.lectern);
  final rack = _locationFor(provider, RoomZone.rack);
  final wall = _locationFor(provider, RoomZone.wall);

  /// [at] overrides the running column position, for a box whose place on the
  /// page is decided by the box it feeds rather than by the order it was
  /// created in — a receiver belongs immediately upstream of its display.
  AvNode place(
    _SourceSpec spec,
    String nodeId, {
    required bool onLeft,
    Offset? at,
    String? label,
  }) {
    final template = provider.avDeviceLibrary.resolve(
      configKey: nodeId,
      model: spec.model,
    );
    final y = onLeft ? leftY : rightY;
    final node = AvNode(
      id: nodeId,
      label: label ?? spec.label,
      model: spec.model,
      pos: at ?? Offset(onLeft ? kAvAutoOriginX : rightX, y),
      ports: withPowerInlet(template.ports, template.powerInput),
      // The config field put it here, so it is a config device: the report
      // says where it came from, and taking it off the canvas is remembered
      // rather than undone by the next automatic pass.
      fromConfig: true,
      excludeFromCost: spec.excludeFromCost,
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
    // A box given its own position has not consumed a slot in either column.
    if (at == null) {
      if (onLeft) {
        leftY = y + node.height + kAvAutoRowGap;
      } else {
        rightY = y + node.height + kAvAutoRowGap;
      }
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

  /// The far end of everything already landing on one connector — cables on
  /// the canvas and the ones this plan has decided to draw, since a plan that
  /// only looks at the canvas puts its own second tie on top of its first.
  List<({String node, String port})> feedsInto(String nodeId, String portId) {
    final out = <({String node, String port})>[];
    void consider(String fromNode, String fromPort, String toNode,
        String toPort) {
      if (toNode == nodeId && toPort == portId) {
        out.add((node: fromNode, port: fromPort));
      } else if (fromNode == nodeId && fromPort == portId) {
        out.add((node: toNode, port: toPort));
      }
    }

    for (final c in provider.avCables) {
      consider(c.fromNodeId, c.fromPortId, c.toNodeId, c.toPortId);
    }
    for (final c in cables) {
      consider(c.fromNodeId, c.fromPortId, c.toNodeId, c.toPortId);
    }
    return out;
  }

  /// Whether [nodeId] is already on the far end of [port] of [node] — used to
  /// recognise the receiver a DTP run was drawn through on an earlier pass.
  bool joinedTo(AvNode node, AvPort port, String nodeId) =>
      feedsInto(node.id, port.id).any((f) => f.node == nodeId);

  /// True when [nodeId] is already joined to the switcher — straight onto it,
  /// or through one box between them.
  ///
  /// The one box is the whole point: a camera reaches the matrix through a
  /// transmitter and a display through a receiver, and a drawing that shows
  /// either of those is a drawing that has ALREADY made this connection. What
  /// it does not tell you is which numbered socket it landed on, which is
  /// exactly the thing the config states and the thing two people spell
  /// differently — so a room whose drawing already says "this camera is on
  /// the matrix" is not a room with a question to answer.
  bool joinedToSwitcher(String nodeId) {
    if (nodeId == switcher.id) return true;
    for (final c in provider.avCables) {
      String? other;
      if (c.fromNodeId == nodeId) other = c.toNodeId;
      if (c.toNodeId == nodeId) other = c.fromNodeId;
      if (other == null) continue;
      if (other == switcher.id) return true;
      // One hop: the transmitter or receiver in the middle.
      for (final c2 in provider.avCables) {
        if ((c2.fromNodeId == other && c2.toNodeId == switcher.id) ||
            (c2.toNodeId == other && c2.fromNodeId == switcher.id)) {
          return true;
        }
      }
    }
    return false;
  }

  /// True when [a] and [b] have a cable between them, either way round.
  bool joined(String a, String b) => provider.avCables.any((c) =>
      (c.fromNodeId == a && c.toNodeId == b) ||
      (c.fromNodeId == b && c.toNodeId == a));

  /// True when the switcher connector [value] names already has a lead on it.
  ///
  /// A socket takes one cable. If the drawing already shows something on
  /// output 2, then `output_monitor_1: 2` is describing THAT lead — not asking
  /// for a second one, and certainly not asking for a second confidence
  /// monitor to hang it off. Checked before a box is placed, because the box
  /// is the expensive half of the mistake: it lands on the canvas, on the
  /// estimate and in the rack schedule.
  ///
  /// Unresolvable values are left alone — the normal path reports those with
  /// a reason, and this is not the place to say it a second time.
  bool switcherSocketTaken(
    String value, {
    required bool wantOutput,
    Set<SignalType> signals = _videoSignals,
  }) {
    final port = portForIoValue(
      switcher,
      value,
      wantOutput: wantOutput,
      signals: signals,
      declaredOutputs: declaredOutputs,
      declaredInputs: declaredInputs,
    );
    if (port == null) return false;
    return provider.avCables.any((c) =>
        (c.fromNodeId == switcher.id && c.fromPortId == port.id) ||
        (c.toNodeId == switcher.id && c.toPortId == port.id));
  }

  // --- the sources -----------------------------------------------------------
  //  Every one of these is "this box is on switcher input N", so they all end
  //  the same way: find input N on the switcher, find the box's own output,
  //  and join the two.

  /// The transmitter for one DTP run in, found the same three ways the
  /// receiver is: its stable id, a box this plan already placed, and a
  /// transmitter already cabled off this source on a diagram drawn by hand.
  ({AvNode node, AvPort input, AvPort output})?
      transmitterFor(String key, AvNode source) {
    final txId = avAutoNodeId('${key}_tx');

    AvNode? existing = nodesById[txId];
    for (final n in newNodes) {
      if (n.id == txId) existing = n;
    }
    existing ??= _transmitterFedBy(provider, source);

    final node = existing ??
        place(
          _dtpTransmitter,
          txId,
          onLeft: true,
          label: '${_dtpTransmitter.label} — ${source.label}',
        );
    return _extenderPorts(node, SignalType.hdmi, SignalType.hdbaset);
  }

  void routeSource(String key, AvNode source, {AvPort? fromPort}) {
    final value = setup[key]?.toString().trim() ?? '';
    if (value.isEmpty) return;
    final switcherPort = portForIoValue(
      switcher,
      value,
      wantOutput: false,
      declaredInputs: declaredInputs,
    );
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
    // The socket at the SOURCE end takes one lead as well. A camera whose
    // HDMI OUT already runs to the recorder has nothing left to plug into the
    // switcher with, and drawing it anyway is two cables out of one
    // connector — the same mistake as two feeds into one display, at the
    // other end of the run.
    //
    // Not counted: a far end that IS the switcher (this tie, already drawn)
    // or a transmitter sitting on the switcher input this tie names, which is
    // this pass recognising the box it put in on an earlier run.
    final onThatSocket = feedsInto(source.id, out.id);
    final servesThisTie = onThatSocket.any((f) =>
        f.node == switcher.id || joinedTo(switcher, switcherPort, f.node));
    if (onThatSocket.isNotEmpty && !servesThisTie) {
      // Already on the matrix, by whatever route the drawing shows — straight
      // in, or through the transmitter beside it. The number in the config
      // says which input; the drawing says it is connected; they are the same
      // fact and the drawing is the one with a cable in it.
      if (joinedToSwitcher(source.id)) {
        alreadyDrawn++;
        return;
      }
      final far = onThatSocket
          .map((f) => nodesById[f.node]?.label ?? f.node)
          .toSet()
          .join(', ');
      unresolved.add(UnroutedTie(
          key,
          value,
          '${source.label} already has ${out.label} running to $far, which is '
          'not on ${switcher.label}, so it cannot also run to input $value. '
          'The drawing is left as it is — check which of the two is right.'));
      return;
    }
    // The other half of what [_dtpReceiver] fixes, and the more common one:
    // the cameras land on DTP inputs and a camera has an HDMI socket. Twisted
    // pair into the switcher, a short HDMI lead at the camera, and a
    // transmitter where the two meet.
    if (switcherPort.signal == SignalType.hdbaset &&
        out.signal == SignalType.hdmi) {
      // Deleted by hand takes both its cables with it — half a run drawn to a
      // box that is not there is worse than the gap it leaves.
      if (dismissed('${key}_tx')) return;
      final tx = transmitterFor(key, source);
      if (tx == null) {
        unresolved.add(UnroutedTie(
            key,
            value,
            '${source.label} leaves by ${out.label} and '
            '${switcherPort.label} is a DTP input, so the run needs a '
            'transmitter — and the catalog entry for '
            '${_dtpTransmitter.model} has no HDMI input and DTP output to '
            'cable it by. Draw this one by hand.'));
        return;
      }
      draw(
        configKey: key,
        value: value,
        from: source,
        fromPort: out,
        to: tx.node,
        toPort: tx.input,
        signal: SignalType.hdmi,
      );
      draw(
        configKey: key,
        value: value,
        from: tx.node,
        fromPort: tx.output,
        to: switcher,
        toPort: switcherPort,
        signal: SignalType.hdbaset,
      );
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
  if ((pcValue.isNotEmpty || pcExtended.isNotEmpty) && !dismissed('input_pc')) {
    pc = _existingByModelOrLabel(provider, const ['PC', 'PC Micro'], 'pc') ??
        place(_passiveSources['input_pc']!, avAutoNodeId('input_pc'),
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
    if (value.isEmpty || dismissed(entry.key)) continue;
    final existing =
        _existingByModelOrLabel(provider, [entry.value.model], entry.key);
    final node = existing ??
        place(entry.value, avAutoNodeId(entry.key), onLeft: true);
    routeSource(entry.key, node);
  }

  // The laptop plate that is a USB-C plate in a new room and a VGA plate in an
  // old one. One switcher input, one key, and gui_usb_or_vga says which lead
  // is actually hanging off it — so the box drawn has to follow that setting
  // or the drawing contradicts the panel's own button.
  final usbValue = setup['input_usb']?.toString().trim() ?? '';
  if (usbValue.isNotEmpty && !dismissed('input_usb')) {
    final isVga =
        (setup['gui_usb_or_vga']?.toString().trim().toUpperCase() ?? 'USB') ==
            'VGA';
    final spec = isVga
        ? const _SourceSpec(
            'Laptop at the VGA plate', 'VGA Laptop', RoomZone.lectern, true)
        : const _SourceSpec(
            'Laptop at the USB-C plate', 'USB-C Laptop', RoomZone.lectern,
            true);
    final existing =
        _existingByModelOrLabel(provider, [spec.model], 'input_usb');
    final node =
        existing ?? place(spec, avAutoNodeId('input_usb'), onLeft: true);
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

  /// The receiver for one DTP run: the box, the socket the twisted pair
  /// lands on and the socket the short HDMI lead leaves by.
  ///
  /// Recognised before it is created, three ways, because none of them is
  /// reliable on its own: the id this feature gives it, a box this same
  /// plan has already put in, and — for a diagram drawn before any of this
  /// existed — a receiver already cabled into the display, whatever it was
  /// called when somebody dragged it there.
  ({AvNode node, AvPort input, AvPort output})?
      receiverFor(String key, AvNode dest) {
    final rxId = avAutoNodeId('${key}_rx');

    AvNode? existing = nodesById[rxId];
    for (final n in newNodes) {
      if (n.id == rxId) existing = n;
    }
    existing ??= _receiverFeeding(provider, dest);

    final node = existing ??
        place(
          _dtpReceiver,
          rxId,
          onLeft: false,
          // Immediately upstream of what it feeds, which is where it is in
          // the room: the receiver is on the wall behind the display.
          at: Offset(
            math.max(kAvAutoOriginX, dest.pos.dx - kAvAutoColumnPitch),
            dest.pos.dy,
          ),
          label: '${_dtpReceiver.label} — ${dest.label}',
        );

    return _extenderPorts(node, SignalType.hdbaset, SignalType.hdmi);
  }

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
    // WHICH SOCKET ON THE FAR BOX. This used to be `firstOrNull` — the first
    // connector of a matching signal, every time — and it is wrong twice over.
    //
    //  * Two ties that land on the SAME box both took connector one.
    //    `output_cc: 1` and `output_cc2: 2` into an AV Bridge 2x1 came out as
    //    two leads from the DTP CrossPoint drawn onto HDMI IN 1, which is a
    //    socket that takes one lead.
    //  * The first connector is not always a connector a program feed goes
    //    to. A DMP 64 Plus C AT lists 'DMP EXP' first — the expansion bus
    //    between two DSPs — so `output_audio: 1` was drawn from the matrix
    //    into the DSP's expansion port instead of a MIC/LINE input.
    //
    // So: the tie's own socket if it already has one, else the best free one,
    // where "best" prefers a NUMBERED general-purpose connector (MIC/LINE 1,
    // HDMI IN 2) over a named special-purpose one (ACP, DMP EXP, USB AUDIO),
    // and a connector of the switcher's own signal over a conversion.
    final candidates = landingCandidates(dest, signals);

    /// True when what is already on [p] is THIS tie's cable — drawn straight
    /// off the switcher's output, or off the receiver that output feeds. A
    /// second pass has to recognise its own work, or it walks along the box's
    /// inputs drawing a fresh lead every time it runs.
    bool ownedByThisTie(AvPort p) => feedsInto(dest.id, p.id).any((f) =>
        (f.node == switcher.id && f.port == switcherPort.id) ||
        joinedTo(switcher, switcherPort, f.node));

    // Best rank first, and the catalog's own order inside a rank — so two
    // ties onto the same box take connector one and connector two, in that
    // order, rather than fighting over whichever sorted first this run.
    final free = [
      for (final (i, p) in candidates.indexed)
        if (feedsInto(dest.id, p.id).isEmpty) (index: i, port: p),
    ]..sort((a, b) {
        final byRank = landingRank(b.port, switcherPort)
            .compareTo(landingRank(a.port, switcherPort));
        return byRank != 0 ? byRank : a.index.compareTo(b.index);
      });

    // A box that ALREADY has a feed of this kind does not get a second one.
    //
    // The config says which switcher output drives this display. A drawing
    // that already shows it driven — off another output, through a receiver,
    // or onto a socket this pass spells differently — has answered the same
    // question, and two feeds into one display is the one answer that is
    // certainly wrong. It is how a room stamped from a room type came out
    // with every projector fed twice: the preset draws DTP OUT 1 into the
    // projector's HDBaseT socket and `output_proj_1: 1` reads as HDMI 1, so a
    // second lead landed on the free HDMI connector beside it.
    //
    // The DRAWING wins and the disagreement is reported: a lead somebody drew
    // is a decision, and a number resolved through a table of connector names
    // is a lookup. Only feeds that were already SAVED count — a tie drawn by
    // this same pass is this pass's own work, and a box with two ties onto it
    // (`output_cc` and `output_cc2` into an AV Bridge) still gets both.
    final fedAlready = toPort == null && !candidates.any(ownedByThisTie)
        ? candidates
            .where((p) => provider.avCables.any((c) =>
                (c.toNodeId == dest.id && c.toPortId == p.id) ||
                (c.fromNodeId == dest.id && c.fromPortId == p.id)))
            .toList()
        : const <AvPort>[];
    if (fedAlready.isNotEmpty) {
      if (joinedToSwitcher(dest.id)) {
        // Fed from THIS switcher already, on a socket spelled differently
        // from the one the number resolves to: the same connection, not a
        // second one, and not a disagreement anybody needs to read about. A
        // room stamped from a room type is this case for every display it
        // has — the preset draws DTP OUT 1 into the projector and
        // `output_proj_1: 1` reads as HDMI 1.
        //
        // What says it is the SAME connection: the socket the number resolves
        // to is spoken for too. When that socket is FREE the config really is
        // asking for another lead into a box with nowhere to put it — two
        // capture feeds into a recorder with one HDMI input — so this falls
        // through to the landing check below, which says exactly that.
        if (feedsInto(switcher.id, switcherPort.id).isNotEmpty) {
          alreadyDrawn++;
          return;
        }
      } else {
        unresolved.add(UnroutedTie(
            key,
            value,
            '${dest.label} is already cabled on '
            '${fedAlready.map((p) => p.label).join(', ')} from something '
            'other than ${switcher.label}, so $value would be a second feed '
            'into the same box. The drawing is left as it is — check which of '
            'the two is right.'));
        return;
      }
    }

    // The socket on the SWITCHER takes one lead too. A number pointing at an
    // output that already runs somewhere else is a disagreement between the
    // drawing and the config, and drawing the second lead is the one answer
    // that is certainly wrong.
    final onSwitcherSocket = feedsInto(switcher.id, switcherPort.id)
        .where((f) => f.node != dest.id && !joined(f.node, dest.id))
        .map((f) => nodesById[f.node]?.label ?? f.node)
        .toSet();
    if (onSwitcherSocket.isNotEmpty) {
      unresolved.add(UnroutedTie(
          key,
          value,
          '${switcherPort.label} on ${switcher.label} already runs to '
          '${onSwitcherSocket.join(', ')}, so it cannot also feed '
          '${dest.label}. The drawing is left as it is — check which of the '
          'two is right.'));
      return;
    }

    final landing = toPort ??
        candidates.where(ownedByThisTie).firstOrNull ??
        free.firstOrNull?.port;
    if (landing == null) {
      unresolved.add(UnroutedTie(
          key,
          value,
          candidates.isEmpty
              ? '${dest.label} has no matching input to land on.'
              : 'Every input on ${dest.label} that could take $value is '
                  'already fed by something else '
                  '(${candidates.map((p) => p.label).join(', ')}). Nothing is '
                  'drawn rather than a second lead onto a socket that already '
                  'has one.'));
      return;
    }

    // A DTP output feeding an HDMI input is not one cable, it is two and a
    // receiver — see [_dtpReceiver]. The config states both ends and leaves
    // the box between them unsaid, so it is put in here rather than drawn as
    // a lead that cannot be bought.
    if (switcherPort.signal == SignalType.hdbaset &&
        landing.signal == SignalType.hdmi) {
      // Before inventing a box: does the far end take twisted pair itself?
      //
      // A projector with an HDBaseT socket needs no receiver, whatever its
      // config block's `input` happens to name — that field records which
      // connector somebody plugged into, and a room whose matrix output is
      // DTP and whose display has a DTP socket is a room where the answer is
      // that socket. Drawing a receiver into it quotes a box the room does
      // not need and puts a join in a run that has none.
      final native = dest.ports
          .where((p) =>
              p.signal == SignalType.hdbaset &&
              (p.isInput || p.direction == PortDirection.bidirectional))
          .firstOrNull;
      if (native != null) {
        draw(
          configKey: key,
          value: value,
          from: switcher,
          fromPort: switcherPort,
          to: dest,
          toPort: native,
          signal: SignalType.hdbaset,
        );
        return;
      }

      // The receiver taken off the canvas by hand takes its two cables with
      // it: half a run drawn to a box that is not there is worse than none.
      if (dismissed('${key}_rx')) return;
      final rx = receiverFor(key, dest);
      if (rx == null) {
        unresolved.add(UnroutedTie(
            key,
            value,
            '${switcherPort.label} is a DTP output and '
            '${dest.label} takes ${landing.label}, so the run needs a '
            'receiver — and the catalog entry for '
            '${_dtpReceiver.model} has no DTP input and HDMI output to '
            'cable it by. Draw this one by hand.'));
        return;
      }
      draw(
        configKey: key,
        value: value,
        from: switcher,
        fromPort: switcherPort,
        to: rx.node,
        toPort: rx.input,
        signal: SignalType.hdbaset,
      );
      draw(
        configKey: key,
        value: value,
        from: rx.node,
        fromPort: rx.output,
        to: dest,
        toPort: landing,
        signal: SignalType.hdmi,
      );
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
    if (value.isEmpty ||
        value.toLowerCase() == 'none' ||
        dismissed(entry.key)) {
      continue;
    }
    final signals =
        entry.key == 'output_audio_ald' ? _lineAudio : _videoSignals;
    // Already cabled off that socket — see [switcherSocketTaken]. This is how
    // a room stamped from a room type grew a SECOND confidence monitor: the
    // preset draws one off HDMI OUT 2 and calls it what it likes, and the box
    // this pass would place is recognised by model, so a monitor named
    // differently was not found and another one was bought.
    if (switcherSocketTaken(value, wantOutput: true, signals: signals)) {
      alreadyDrawn++;
      continue;
    }
    final existing =
        _existingByModelOrLabel(provider, [entry.value.model], entry.key);
    final node = existing ??
        place(entry.value, avAutoNodeId(entry.key), onLeft: false);
    routeDestination(entry.key, node, signals: signals);
  }

  // PROGRAM AUDIO.
  //
  // In a room with a DSP, `output_audio` is the LINK on the switcher side —
  // the number of the tie that feeds the DSP over the expansion bus, not a
  // discrete analog output somebody runs a lead from. So nothing is drawn
  // from it here: the pair is joined by their DMP EXP connectors below, which
  // is the one cable that actually exists between them.
  //
  // Without a DSP the same key means what it always did: the amplifier is
  // inside the switcher (an SA or MA build) and the run is speaker level to
  // the ceiling.
  final audioValue = setup['output_audio']?.toString().trim() ?? '';
  if (audioValue.isNotEmpty &&
      audioValue.toLowerCase() != 'none' &&
      nodesById['DSPDEVICE_1'] == null) {
    // The amplifier output already has a speaker run on it: a preset that
    // ships an SM 28 pair is a room with speakers, whatever they are called.
    if (!switcherSocketTaken(audioValue,
        wantOutput: true, signals: _speakerAudio)) {
      final existing = _existingByModelOrLabel(
          provider, const ['Ceiling Speakers'], 'output_audio');
      final node = existing ??
          place(
              const _SourceSpec(
                  'Ceiling speakers', 'Ceiling Speakers', RoomZone.ceiling),
              avAutoNodeId('output_audio'),
              onLeft: false);
      routeDestination('output_audio', node, signals: _speakerAudio);
    } else {
      alreadyDrawn++;
    }
  }

  // --- the expansion bus -----------------------------------------------------
  //  'DMP EXP' is the ribbon between an Extron switcher with a DSP in it and
  //  the DMP racked beside it. The program audio never leaves the pair as
  //  analog — it stays on the bus — which is why `output_audio` draws no lead
  //  of its own and why drawing one into a MIC/LINE input was wrong twice
  //  over: the cable does not exist and the connector it landed on is not an
  //  input anybody patches.
  //
  //  Every box in the room carrying one is chained to the next, in rack
  //  order: the switcher, then the DSPs by their block number, then anything
  //  else that has the connector. A project with one such box has no link to
  //  draw and nothing happens.
  final expansion = <AvNode>[
    for (final node in [
      switcher,
      for (var n = 1; n <= 8; n++)
        if (nodesById['DSPDEVICE_$n'] != null) nodesById['DSPDEVICE_$n']!,
      ...provider.avNodes,
      ...newNodes,
    ])
      if (_expansionPort(node) != null) node,
  ];
  final chained = <String>{};
  final links = <AvNode>[];
  for (final node in expansion) {
    if (chained.add(node.id)) links.add(node);
  }
  for (var i = 0; i + 1 < links.length; i++) {
    final from = links[i];
    final to = links[i + 1];
    final fromPort = _expansionPort(from)!;
    final toPort = _expansionPort(to)!;
    draw(
      configKey: 'output_audio',
      value: audioValue,
      from: from,
      fromPort: fromPort,
      to: to,
      toPort: toPort,
      signal: fromPort.signal,
    );
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

  // --- the power controller --------------------------------------------------
  //  The APC's outlets are named in the config — power1_outlet_1 is 'PC',
  //  outlet 6 is 'Doc\rCam' — because those names are printed on the touch
  //  panel's power page, so somebody standing at the lectern can reboot the
  //  right thing. They are also, read the other way, a wiring list: the box
  //  called PC is plugged into outlet 1. Nobody had ever drawn it.
  //
  //  A name is matched onto a box only when every word of it lands (see
  //  [outletNameScore]), and never when two boxes fit equally well: a power
  //  lead drawn to the wrong box is a lead somebody unplugs the wrong thing
  //  by. The names that are not a coin toss at all, because the trade already
  //  agreed what they mean, are settled first — see [_outletAliases]. An
  //  outlet naming something the drawing does not show, the network switch or
  //  the intake fans, is normal and silent.
  final powered = <String>[];
  final outletKey = RegExp(r'^power(\d+)_outlet_(\d+)$');

  for (final entry in setup.entries) {
    final match = outletKey.firstMatch(entry.key.toString());
    if (match == null) continue;
    final name = entry.value?.toString().trim() ?? '';
    if (name.isEmpty || name.toLowerCase() == 'none') continue;

    final controller = nodesById['POWERDEVICE_${match.group(1)}'];
    if (controller == null) continue;

    final number = int.parse(match.group(2)!);
    final outlet = controller.portById('out_pwr_$number') ??
        controller.ports
            .where((p) =>
                p.signal == SignalType.power &&
                p.isOutput &&
                parsePortLabel(p.label).number == number)
            .firstOrNull;
    if (outlet == null) {
      unresolved.add(UnroutedTie(entry.key.toString(), name,
          '${controller.label} has no outlet $number to plug this into.'));
      continue;
    }

    final wanted = outletNameTokens(name);

    /// True when this box could be on a mains outlet at all. A box fed over
    /// the network is not, whatever the label says, and a passive one has no
    /// inlet to plug into.
    bool canBePlugged(AvNode node) =>
        node.id != controller.id &&
        !node.isJackField &&
        node.powerSource != PowerSource.poe &&
        node.portById(kPowerPortId) != null;

    // The names the trade has already settled. Lowest-numbered block placed:
    // the main switcher is SWITCHERDEVICE_1, and the ones with numbers after
    // it are the sub switchers hanging off it.
    final aliasPrefix = _outletAliases[wanted.join(' ')];
    AvNode? target;
    if (aliasPrefix != null) {
      for (var n = 1; n <= 8 && target == null; n++) {
        final node = nodesById['$aliasPrefix$n'];
        if (node != null && canBePlugged(node)) target = node;
      }
    }

    // Failing that — an aliased name in a room that has no such block, or any
    // other name — whichever box the label describes best, and nothing at all
    // when two describe it equally well.
    if (target == null) {
      var best = 0;
      final winners = <AvNode>[];
      for (final node in [...provider.avNodes, ...newNodes]) {
        if (!canBePlugged(node)) continue;
        final score = outletNameScore(wanted, node);
        if (score == 0 || score < best) continue;
        if (score > best) {
          best = score;
          winners.clear();
        }
        winners.add(node);
      }

      if (winners.isEmpty) continue;
      if (winners.length > 1) {
        unresolved.add(UnroutedTie(
            entry.key.toString(),
            name,
            '${winners.length} boxes answer to "$name" — '
            '${winners.map((n) => n.label).join(', ')}. Nothing is drawn '
            'rather than the wrong one; plug this outlet in by hand.'));
        continue;
      }
      target = winners.first;
    }

    draw(
      configKey: entry.key.toString(),
      value: name,
      from: controller,
      fromPort: outlet,
      to: target,
      toPort: target.portById(kPowerPortId)!,
      signal: SignalType.power,
    );
    powered.add(target.id);
  }

  return RoutingPlan(
    newNodes: newNodes,
    cables: cables,
    unresolved: unresolved,
    alreadyDrawn: alreadyDrawn,
    powered: powered,
  );
}

// ---------------------------------------------------------------------------
//  MATCHING AN OUTLET LABEL ONTO A DEVICE
// ---------------------------------------------------------------------------

/// The words in an outlet label or a device name.
///
/// `power1_outlet_6` holds `Doc\rCam`, and that \r is a
/// literal backslash and r — two characters put there to break the label
/// over two lines on the touch panel button. Splitting on punctuation
/// without stripping it first yields "doc" and "rcam", so the line break
/// goes before anything else does.
List<String> outletNameTokens(String raw) => raw
    .replaceAll(r'\r', ' ')
    .replaceAll(r'\n', ' ')
    .replaceAll('\r', ' ')
    .replaceAll('\n', ' ')
    .toLowerCase()
    .split(RegExp('[^a-z0-9]+'))
    .where((t) => t.isNotEmpty)
    .toList();

/// How well [wanted] describes [node]: 2 a word, 1 a word it starts, 0 when
/// any word is missing entirely.
///
/// Every word has to land. "Doc Cam" is not the doc camera and the camera
/// separately — an outlet label is a whole name, and half of one matching is
/// the way a power lead gets drawn to the wrong box. The prefix rule is what
/// makes "Doc Cam" reach "Document camera" and "Amp" reach "Amplifier", and it
/// is off for words under three letters: "PC" would otherwise find "PCs", and
/// the "C" of "USB-C" would find everything.
int outletNameScore(List<String> wanted, AvNode node) {
  if (wanted.isEmpty) return 0;
  final have = <String>{
    ...outletNameTokens(node.label),
    ...outletNameTokens(node.model),
  };
  var score = 0;
  for (final word in wanted) {
    if (have.contains(word)) {
      score += 2;
      continue;
    }
    if (word.length < 3) return 0;
    final near = have.any((h) =>
        h.length >= 3 && (h.startsWith(word) || word.startsWith(h)));
    if (!near) return 0;
    score += 1;
  }
  return score;
}

/// Outlet names that name a config device outright, whatever else on the
/// canvas happens to answer to the word.
///
/// 'Switch' is the one that needs saying. In a room built out of Extron gear
/// it means the switcher — the matrix everything is plugged into — and the
/// word alone is not enough for [outletNameScore] to know that, because 'USB
/// Switcher' and 'Switcher 2' and 'Switcher 3' all start with the same six
/// letters. Left to the scoring it was a tie and nothing was drawn, in every
/// room on the estate.
///
/// Keyed on the whole outlet name, so this decides 'Switch' and touches
/// nothing else: 'USB Switch' is two words, misses this table, and goes on
/// resolving onto the USB switcher the way it always did.
const Map<String, String> _outletAliases = {
  'switch': 'SWITCHERDEVICE_',
};

/// One end of a DTP run, cabled: the box, the socket the signal arrives on and
/// the socket it leaves by. Null when the catalog entry has no such pair, in
/// which case there is nothing to draw and saying so beats guessing.
({AvNode node, AvPort input, AvPort output})? _extenderPorts(
  AvNode node,
  SignalType inSignal,
  SignalType outSignal,
) {
  AvPort? input, output;
  for (final p in node.ports) {
    final takesIn = p.isInput || p.direction == PortDirection.bidirectional;
    if (input == null && takesIn && p.signal == inSignal) input = p;
    if (output == null && p.isOutput && p.signal == outSignal) output = p;
  }
  if (input == null || output == null) return null;
  return (node: node, input: input, output: output);
}

/// The DTP transmitter already fed by [source], for a diagram somebody drew
/// before this put them in. The mirror of [_receiverFeeding], and it refuses a
/// config box for the same reason.
AvNode? _transmitterFedBy(AppStateProvider provider, AvNode source) {
  for (final cable in provider.avCables) {
    if (cable.fromNodeId != source.id) continue;
    final to = provider.avNodeById(cable.toNodeId);
    if (to == null) continue;
    if (provider.roomConfig.containsKey(to.id)) continue;
    final takesHdmi = to.ports.any((p) =>
        p.signal == SignalType.hdmi &&
        (p.isInput || p.direction == PortDirection.bidirectional));
    final sendsDtp =
        to.ports.any((p) => p.signal == SignalType.hdbaset && p.isOutput);
    if (takesHdmi && sendsDtp) return to;
  }
  return null;
}

/// The DTP receiver already feeding [dest], for a diagram somebody drew before
/// this put them in. Matched on what it DOES — a box with a DTP input and a
/// cable into this display — rather than on its model, because the room end of
/// a run gets built with whatever receiver was on the shelf.
AvNode? _receiverFeeding(AppStateProvider provider, AvNode dest) {
  for (final cable in provider.avCables) {
    if (cable.toNodeId != dest.id) continue;
    final from = provider.avNodeById(cable.fromNodeId);
    if (from == null) continue;
    // Never a box the config describes. The switcher itself has DTP inputs
    // and HDMI outputs and would match this shape, and a diagram that already
    // ran the old direct DTP-to-HDMI cable would then have the switcher
    // cabled to itself. The config having no block for it is the whole reason
    // the receiver is being invented.
    if (provider.roomConfig.containsKey(from.id)) continue;
    final takesDtp = from.ports.any((p) =>
        p.signal == SignalType.hdbaset &&
        (p.isInput || p.direction == PortDirection.bidirectional));
    final sendsHdmi = from.ports
        .any((p) => p.signal == SignalType.hdmi && p.isOutput);
    if (takesDtp && sendsHdmi) return from;
  }
  return null;
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

/// The node id a box placed from a config field is given.
///
/// A generated `AVNODE_7` would be a different box every time the numbers were
/// read again. Keyed on the field that placed it, the PC that `input_pc` puts
/// on the canvas is the same node on every pass — which is what lets this run
/// by itself: a second pass recognises the box instead of drawing a second
/// one, and a box somebody deleted on purpose is remembered as deleted (see
/// [AppStateProvider.avDismissedDevices]).
String avAutoNodeId(String configKey) => 'AVSOURCE_${configKey.toUpperCase()}';

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

/// Nothing happened, because there was nothing to do.
const RoutingResult _noRouting =
    (nodesAdded: 0, cablesDrawn: 0, unresolved: 0);

/// Draws the room the config already describes — without asking.
///
/// The whole routing, both halves. `input_pc: "1"` means there is a PC and it
/// is on input 1; `output_proj_1: "3B"` and the projector's own `input:
/// "HDBaseT"` name the two ends of the run to the display. None of that is a
/// preference anybody has to be consulted about, so making somebody press a
/// button and read a review to find out what the file already says was a step
/// that only ever had one answer. The consequence reaches past the drawing:
/// the estimate counts the boxes on the canvas, so a room whose PC, doc cam
/// and DTP receivers were never placed was quoting a room without them in it.
///
/// Safe to call on every visit to any tab that reads the diagram:
///
///   * a box already on the canvas is recognised, not duplicated;
///   * a cable already drawn between the same two connectors is left alone;
///   * a box somebody deleted stays deleted;
///   * a room with no switcher on the canvas yet is left completely alone —
///     there is nothing for a cable to run to.
///
/// What it does NOT do is report. A number that resolves onto no connector is
/// counted and dropped here; **Draw the routing from config** is still the way
/// to see WHY, one line per tie with the key and the value behind it.
RoutingResult autoDrawRoutingFromConfig(AppStateProvider provider) {
  // ONCE PER CHANGE TO THE CONFIG, not once per visit. The drawing is a
  // document: after the conversion has put the room on the canvas, opening
  // the tab again should show it exactly as it was left. Re-running the pass
  // every time meant a room nobody had touched could still change under them
  // — a catalog revision moving a connector, or this file changing its mind
  // about which socket a tie lands on, is enough.
  //
  // The fingerprint covers everything the pass reads, so editing a device or
  // any of the routing values lets it run again, which is the case the repeat
  // pass existed for: a doc cam added to the config last week belongs on the
  // drawing this week.
  final fingerprint = routingFingerprint(provider);
  if (fingerprint.isNotEmpty && fingerprint == provider.avRoutedFingerprint) {
    return _noRouting;
  }
  final plan = planRoutingFromConfig(provider, respectDismissed: true);
  if (plan.isEmpty) return _noRouting;
  final result = applyRoutingFromConfig(provider, plan, quiet: true);
  provider.avRoutedFingerprint = fingerprint;
  return result;
}

/// Everything the routing pass reads out of the config, as one string.
///
/// The routing values in SYSTEM_SETUP (`input_*`, `output_*`, the outlet
/// names) and, for every device block, its key, model and the connector its
/// own `input` names — the three facts a tie is resolved from. Change any of
/// them and the drawing is out of date; change anything else in the room and
/// it is not.
String routingFingerprint(AppStateProvider provider) {
  final config = provider.roomConfig;
  final setup = config['SYSTEM_SETUP'];
  if (setup is! Map) return '';

  final parts = <String>[];
  final keys = setup.keys.map((k) => k.toString()).toList()..sort();
  for (final key in keys) {
    if (!key.startsWith('input_') &&
        !key.startsWith('output_') &&
        !key.startsWith('dev_') &&
        !RegExp(r'^power\d+_outlet_\d+$').hasMatch(key)) {
      continue;
    }
    parts.add('$key=${setup[key]?.toString().trim() ?? ''}');
  }

  final blocks = config.keys.map((k) => k.toString()).toList()..sort();
  for (final key in blocks) {
    final block = config[key];
    if (block is! Map || !block.containsKey('model')) continue;
    parts.add('$key/${block['model']?.toString().trim() ?? ''}'
        '/${block['input']?.toString().trim() ?? ''}');
  }
  return parts.join(';');
}

/// Draws [plan] onto the canvas.
///
/// Nothing is destructive: an existing cable between the same two connectors
/// is left alone (it was counted as `alreadyDrawn` when the plan was made),
/// and no cable somebody drew by hand is removed — a tie the config does not
/// mention is not a tie the config says is wrong.
RoutingResult applyRoutingFromConfig(
  AppStateProvider provider,
  RoutingPlan plan, {
  bool quiet = false,
}) {
  for (final node in plan.newNodes) {
    provider.addAvNode(node, recordUndo: false);
  }

  // What the diagram now says out loud: these are on a controller outlet.
  // recordUndo false because the batch has already taken its snapshot — one
  // press of Undo should put the room back, not twenty.
  for (final id in plan.powered) {
    final node = provider.avNodeById(id);
    if (node == null || node.powerSource == PowerSource.controller) continue;
    provider.updateAvNode(
      node.copyWith(powerSource: PowerSource.controller),
      recordUndo: false,
    );
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

  if (!quiet) {
    AppLogger.logInfo(
      'Drew the routing from the config: ${plan.newNodes.length} box(es) '
      'added, $drawn cable(s) drawn, ${plan.unresolved.length} tie(s) the '
      'numbers did not resolve.',
    );
  } else if (plan.newNodes.isNotEmpty || drawn > 0) {
    AppLogger.logInfo(
      'Drew the routing the config describes: ${plan.newNodes.length} '
      'box(es) added, $drawn cable(s) drawn.',
    );
  }

  return (
    nodesAdded: plan.newNodes.length,
    cablesDrawn: drawn,
    unresolved: plan.unresolved.length,
  );
}
