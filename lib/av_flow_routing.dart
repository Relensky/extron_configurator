import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'app_state.dart';
import 'flow_rules.dart';
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
///  A ROOM WITH NO MATRIX is the same idea with a different box in the middle.
///  A huddle space has one panel and a couple of things plugged into the back
///  of it, so `input_pc` is not a matrix tie — it is the socket on the
///  display, written the way it is silkscreened there ("HDMI 2"). The display
///  stands in for the switcher and every source is routed onto it exactly as
///  it would be onto a matrix input; the `output_*` half has no meaning in
///  such a room, because the run stops at the panel. See [_displayHub] and
///  [portForDisplayInput].
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

/// Line-level audio and speaker level. The line-audio set moved to
/// [kFlowLineAudio], where a rule can ask for it by name; this file still
/// needs the speaker set to tell an amplifier output from a DSP output.
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

// ---------------------------------------------------------------------------
//  WHERE THE RULES LIVE NOW
// ---------------------------------------------------------------------------
//  The tables that used to sit here — which box `input_pc` means, which block
//  `output_proj_2` feeds, the DTP receiver that goes between a twisted-pair
//  output and an HDMI display, what hangs off the Toggle — are in
//  [FlowRules], loaded from av_flow_rules.json and edited on the Flow Rules
//  tab. Every default in [FlowRules.builtIn] is the constant that used to be
//  here, so a room with no rule file draws exactly as it always did.
//
//  What stayed in this file is the part that is not a decision: which socket
//  the number "3B" names, whether a connector is already spoken for, how a
//  run with two different ends is split in three. A rule says WHICH box; this
//  says how it is cabled.

/// Every box passes, for [FlowTarget] lookups with no extra condition.
bool _anyBox(AvNode node) => true;

/// A rule's box, in the shape the placement code here works in.
_SourceSpec _specOf(FlowBoxRule rule) => _SourceSpec(
      rule.label,
      rule.model,
      flowZoneFromName(rule.zone),
      rule.excludeFromCost,
    );

/// An extender rule's box, the same way.
_SourceSpec _specOfExtender(FlowExtenderRule rule) => _SourceSpec(
      rule.label,
      rule.model,
      flowZoneFromName(rule.zone),
    );

/// The `input_*` keys this pass handles itself rather than off the plain
/// source-box loop: the PC has a second lead (`input_pc_extended`), and the
/// laptop plate is one key with two meanings — USB-C or VGA, as
/// `gui_usb_or_vga` says — so its rule is chosen at plan time.
const Set<String> _handledElsewhere = {
  'input_pc',
  'input_usb',
  kFlowVgaPlateKey,
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
///
/// The room's own note on the label is stripped first: `OUTLET 3 · Via` is
/// outlet 3, not an unreadable label, and naming an outlet must never change
/// which socket a lead resolves to.
ConnectorRef parsePortLabel(String label) {
  final trimmed = basePortLabel(label);
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

  // 2b. The number with a letter, against a label that carries the number and
  //     spells no letter after it.
  //
  //     The letter is a CONNECTOR TYPE — A is that output's HDMI socket, B its
  //     twisted-pair one — so a label naming the socket by signal answers the
  //     same question: 'DTP OUT 007' IS output 7's B connector, because output
  //     7 has no other kind. Only when exactly one connector of that signal
  //     carries the number, so an output that really does have both still has
  //     to be asked for by letter.
  if (want.number != null && want.letter.isNotEmpty) {
    final wantSignal = _signalForLetter(want.letter);
    if (wantSignal != null) {
      final matches = [
        for (final e in refs.entries)
          if (e.value.number == want.number &&
              e.value.letter.isEmpty &&
              e.key.signal == wantSignal)
            e.key,
      ];
      if (matches.length == 1) return matches.first;
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
    // A bare number is the output's PRIMARY connector. The letter suffix is
    // what asks for the twisted-pair one — '3B' is output 3's B socket — so
    // '3' is the HDMI socket of that output, including on a catalog entry
    // that spells the DTP connector with no letter at all ('DTP OUT 1' beside
    // 'HDMI 001A' on a CrossPoint 82). Without this the bare number picked
    // the DTP socket, because it was the one that looked letterless, and a
    // display on the HDMI connector was drawn onto twisted pair.
    if (sameNumber.length > 1) {
      final hdmi = [
        for (final p in sameNumber)
          if (p.signal == SignalType.hdmi) p,
      ];
      if (hdmi.length == 1) return hdmi.first;
    }
    for (final p in sameNumber) {
      if (refs[p]!.letter.isEmpty) return p;
    }
    if (sameNumber.length == 1) return sameNumber.first;
    return null;
  }

  // 6. The connector convention, for a catalog entry that counts connectors.
  final signal = _signalForLetter(want.letter);
  if (signal == null || declaredOutputs <= 0) return null;
  // Only for the block at the END of the connector list. The convention says
  // "this group of connectors is the last k outputs", which is true of the DTP
  // block on every one of these boxes and false of the HDMI block: asking a
  // DTP CrossPoint 86 for '5A' otherwise walked its four HDMI outputs and
  // answered 'HDMI 3', a socket that has nothing to do with output 5.
  if (refs.keys.last.signal != signal) return null;
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

/// The input on a DISPLAY that a source key names, in a room with no matrix.
///
/// A huddle space has no switcher: the PC and the meeting bar go straight into
/// the back of the panel, so `input_pc` is not "switcher input 1" — it is the
/// socket on the display, and people write it the way it is silkscreened
/// there: `HDMI 2`, `HDBaseT`, sometimes just `2`.
///
/// So all three are read, in the order that a stated answer beats an inferred
/// one:
///
///   1. a CONNECTOR KIND AND A NUMBER — 'HDMI 2' onto 'HDMI 2', 'HDMI IN 2'
///      or 'HDMI 002', whichever way the catalog spells the panel. Both halves
///      have to agree, so 'HDMI 2' never lands on 'HDMI 1' and never on the
///      DisplayPort socket beside it. Naming a kind the panel does not have,
///      or a number it does not go up to, resolves to nothing rather than to
///      the nearest thing — the same rule the switcher numbers follow.
///   2. a CONNECTOR KIND alone — 'HDBaseT' on a panel with one of those, which
///      is [portForDeviceInput], the same reading the display's own `input`
///      field gets.
///   3. a BARE NUMBER — '2' onto the second video input, read exactly as a
///      switcher input number is.
AvPort? portForDisplayInput(AvNode display, String value) {
  final want = value.trim();
  if (want.isEmpty || want.toLowerCase() == 'none') return null;

  // 1. The kind and the number, both.
  final signal = _signalForInputName(_flatten(want));
  final number = parsePortLabel(want).number;
  if (signal != null && number != null) {
    for (final p in display.ports) {
      if (!p.isInput && p.direction != PortDirection.bidirectional) continue;
      if (p.signal != signal) continue;
      if (parsePortLabel(p.label).number == number) return p;
    }
    // 'HDMI 2' on a panel whose HDMI sockets carry no numbers at all, which is
    // what a two-input display drawn from the generic template looks like:
    // count them instead, in the order the catalog lists them.
    final ofKind = [
      for (final p in display.ports)
        if (p.signal == signal &&
            (p.isInput || p.direction == PortDirection.bidirectional))
          p,
    ];
    if (ofKind.every((p) => parsePortLabel(p.label).number == null) &&
        number >= 1 &&
        number <= ofKind.length) {
      return ofKind[number - 1];
    }
    return null;
  }

  // 2. The kind on its own.
  final named = portForDeviceInput(display, want);
  if (named != null) return named;

  // 3. A bare number.
  return portForIoValue(display, want, wantOutput: false);
}

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

/// The box's USB data connector, in the direction asked for.
///
/// A bidirectional socket answers to both: the wireless plate's single USB
/// connector is the same connector whichever way the lead is drawn.
AvPort? _usbPort(AvNode node, {required bool wantOutput}) {
  for (final p in node.ports) {
    if (p.signal != SignalType.usbData) continue;
    if (p.direction == PortDirection.bidirectional) return p;
    if (wantOutput ? p.isOutput : p.isInput) return p;
  }
  return null;
}

/// The video inputs on a box, by name — for telling somebody which sockets a
/// value could have named.
List<String> _videoInputLabels(AvNode node) => [
      for (final p in node.ports)
        if (_videoSignals.contains(p.signal) &&
            (p.isInput || p.direction == PortDirection.bidirectional))
          p.label,
    ];

/// The display a room with no matrix routes its sources onto, or null.
///
/// The lowest-numbered PROJECTORDEVICE on the canvas: `dev_projectors` counts
/// projectors and flat panels as one family, and in a room built this way
/// there is one of them. A room with several displays and no switcher has
/// nothing routing between them, so the first is the one the sources land on
/// and the rest are drawn by hand.
AvNode? _displayHub(Map<String, AvNode> nodesById) {
  for (int n = 1; n <= kFlowFamilyDepth; n++) {
    final node = nodesById['PROJECTORDEVICE_$n'];
    if (node != null) return node;
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

  final rules = provider.flowRules;
  final nodesById = {for (final n in provider.avNodes) n.id: n};
  final matrix = nodesById['SWITCHERDEVICE_1'];

  // THE ROOM WITH NO MATRIX. A huddle space is one display with a couple of
  // things plugged into the back of it: no switcher, no rack, and the source
  // buttons pick the DISPLAY's input rather than a matrix tie — which is what
  // `dev_source_control: Display` says. The `input_*` keys still say where
  // each source is wired; they are just numbers on the panel instead of
  // numbers on a matrix ('HDMI 2', or plain '2').
  //
  // So the display stands in for the switcher: every source is routed onto it
  // exactly as it would be routed onto a matrix input. Only when the config
  // has no SWITCHERDEVICE_1 at all — a room whose switcher is simply not
  // placed yet is a room to press "Place all from config" in, not a huddle
  // space.
  final displayHub = matrix == null && !config.containsKey('SWITCHERDEVICE_1')
      ? _displayHub(nodesById)
      : null;
  final switcher = matrix ?? displayHub;
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
              : 'This room has no SWITCHERDEVICE_1 and no display on the '
                  'canvas, and every input_ and output_ number is a number on '
                  'one of those.',
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
  // say — see [portForIoValue] pass 5. Read off the MODEL, so it is only
  // asked of a switcher: `switcherSize` answers "4 in, 1 out" for anything it
  // does not recognise, and a display is not a four-input matrix.
  final declaredInputs =
      matrix == null ? 0 : AvDeviceLibrary.switcherSize(matrix.model).$1;
  final declaredOutputs =
      matrix == null ? 0 : AvDeviceLibrary.switcherSize(matrix.model).$2;

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
      ports: withOutletNames(
        withPowerInlet(template.ports, template.powerInput),
        nodeId,
        provider.roomConfig,
      ),
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

  /// The box a rule names — see [FlowTarget].
  ///
  /// Alternatives are tried in the order they are written, so the capture rule
  /// `MEDIAPORTDEVICE_|RECORDERDEVICE_|USBDEVICE_` finds whichever of the
  /// three this room was built with. [where] narrows a family to the block
  /// that fits: "the DSP with a USB socket on it", not "DSP 1, whatever is on
  /// the back of it".
  AvNode? boxFor(FlowTarget target, {bool Function(AvNode) ok = _anyBox}) {
    AvNode? placed(String id) {
      final node =
          nodesById[id] ?? newNodes.where((n) => n.id == id).firstOrNull;
      return node != null && ok(node) ? node : null;
    }

    for (final name in target.alternatives) {
      // A family, named by its section prefix: the lowest-numbered block of it
      // that fits, which is the one the trade means by "the DSP".
      if (name.endsWith('_')) {
        for (var n = 1; n <= kFlowFamilyDepth; n++) {
          final node = placed('$name$n');
          if (node != null) return node;
        }
        continue;
      }
      // One config section, or the box this pass placed for a config key.
      final exact = placed(name) ?? placed(avAutoNodeId(name));
      if (exact != null) return exact;
      // Failing both, a catalog model already on the canvas — which is how a
      // rule reaches a box somebody drew by hand.
      final byModel = _existingByModelOrLabel(provider, [name], name);
      if (byModel != null && ok(byModel)) return byModel;
    }
    return null;
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

  /// How many cables a box may be from the switcher and still count as
  /// already joined to it.
  ///
  /// Two on a matrix — straight onto it, or through ONE box: a camera reaches
  /// the matrix through a transmitter and a display through a receiver, and a
  /// drawing that shows either of those is a drawing that has ALREADY made
  /// this connection.
  ///
  /// Three when the display is standing in for the matrix, because there the
  /// run has no matrix in the middle of it to be counted from: the huddle
  /// space's wireless box goes transmitter, twisted pair, receiver and then
  /// into the panel, which is three cables and two boxes.
  final int hubReach = displayHub == null ? 2 : 3;

  /// True when [nodeId] is already joined to the switcher, by any run of at
  /// most [hubReach] cables.
  ///
  /// What such a drawing does not tell you is which numbered socket it landed
  /// on, which is exactly the thing the config states and the thing two people
  /// spell differently — so a room whose drawing already says "this camera is
  /// on the matrix" is not a room with a question to answer.
  bool joinedToSwitcher(String nodeId) {
    if (nodeId == switcher.id) return true;
    final seen = {nodeId};
    var edge = {nodeId};
    for (int hop = 0; hop < hubReach && edge.isNotEmpty; hop++) {
      final next = <String>{};
      for (final c in provider.avCables) {
        String? other;
        if (edge.contains(c.fromNodeId)) other = c.toNodeId;
        if (edge.contains(c.toNodeId)) other = c.fromNodeId;
        if (other == null || !seen.add(other)) continue;
        if (other == switcher.id) return true;
        next.add(other);
      }
      edge = next;
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
  ({AvNode node, AvPort input, AvPort output})? transmitterFor(
    String key,
    AvNode source,
    FlowExtenderRule rule,
  ) {
    final txId = avAutoNodeId('${key}_tx');

    AvNode? existing = nodesById[txId];
    for (final n in newNodes) {
      if (n.id == txId) existing = n;
    }
    existing ??= _extenderBetween(provider, source,
        takes: rule.farType!, sends: rule.switcherType!, fedBySource: true);

    final node = existing ??
        place(
          _specOfExtender(rule),
          txId,
          onLeft: true,
          label: '${rule.label} — ${source.label}',
        );
    return _extenderPorts(node, rule.farType!, rule.switcherType!);
  }

  void routeSource(String key, AvNode source, {AvPort? fromPort}) {
    final value = setup[key]?.toString().trim() ?? '';
    if (value.isEmpty) return;
    // On a matrix the value is a number printed on the box; on a display
    // standing in for one it is the socket's own name as well ('HDMI 2').
    final switcherPort = displayHub == null
        ? portForIoValue(
            switcher,
            value,
            wantOutput: false,
            declaredInputs: declaredInputs,
          )
        : portForDisplayInput(switcher, value);
    if (switcherPort == null) {
      unresolved.add(UnroutedTie(
          key,
          value,
          displayHub == null
              ? 'No input on ${switcher.label} is labelled $value.'
              : 'This room has no switcher, so $key is a socket on '
                  '${switcher.label} — and it has no input called "$value". '
                  'Its inputs are '
                  '${_videoInputLabels(switcher).join(', ')}.'));
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
    // A SOCKET ON THE DISPLAY TAKES ONE LEAD. On a matrix the input the
    // config names is the matrix's business — the drawing shows the run and
    // the number says where it lands. On a display it is a socket on the back
    // of a panel with two of them, and the meeting bar is usually already in
    // one: `input_pc: HDMI 1` when the bar is on HDMI 1 is a disagreement
    // between the config and the drawing, not a second cable into that
    // socket. Anything already joined to this source is this same run, drawn
    // before or drawn by this pass.
    if (displayHub != null) {
      final onHubSocket = feedsInto(switcher.id, switcherPort.id)
          .where((f) => f.node != source.id && !joined(f.node, source.id))
          .map((f) => nodesById[f.node]?.label ?? f.node)
          .toSet();
      if (onHubSocket.isNotEmpty) {
        unresolved.add(UnroutedTie(
            key,
            value,
            '${switcherPort.label} on ${switcher.label} already has '
            '${onHubSocket.join(', ')} on it, so ${source.label} cannot go '
            'there too. The drawing is left as it is — check which of the two '
            'is right.'));
        return;
      }
    }
    // The other half of what the receiver rule fixes, and the more common:
    // the cameras land on DTP inputs and a camera has an HDMI socket. Twisted
    // pair into the switcher, a short HDMI lead at the camera, and a
    // transmitter where the two meet.
    final txRule = rules.extenderFor(
      switcherSignal: switcherPort.signal,
      farSignal: out.signal,
      onOutput: false,
    );
    if (txRule != null &&
        txRule.switcherType != null &&
        txRule.farType != null) {
      // Deleted by hand takes both its cables with it — half a run drawn to a
      // box that is not there is worse than the gap it leaves.
      if (dismissed('${key}_tx')) return;
      final tx = transmitterFor(key, source, txRule);
      if (tx == null) {
        unresolved.add(UnroutedTie(
            key,
            value,
            '${source.label} leaves by ${out.label} and '
            '${switcherPort.label} takes '
            '${kSignalLabels[switcherPort.signal] ?? switcherPort.signal.name}'
            ', so the run needs a ${txRule.label} — and the catalog entry for '
            '${txRule.model} has no matching input and output to cable it by. '
            'Draw this one by hand.'));
        return;
      }
      draw(
        configKey: key,
        value: value,
        from: source,
        fromPort: out,
        to: tx.node,
        toPort: tx.input,
        signal: txRule.farType!,
      );
      draw(
        configKey: key,
        value: value,
        from: tx.node,
        fromPort: tx.output,
        to: switcher,
        toPort: switcherPort,
        signal: txRule.switcherType!,
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
    final pcRule = rules.sourceBoxFor('input_pc');
    pc = _existingByModelOrLabel(provider, const ['PC', 'PC Micro'], 'pc') ??
        (pcRule == null
            ? null
            : place(_specOf(pcRule), avAutoNodeId('input_pc'), onLeft: true));
    // A room whose rule book has no input_pc box, and no PC already drawn,
    // gets no PC — which is a rule somebody wrote, not a failure.
    final placedPc = pc;
    if (placedPc != null && pcExtended.isNotEmpty) {
      final outs = placedPc.ports
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
        pc = placedPc.copyWith(ports: [...placedPc.ports, added]);
        final at = newNodes.indexWhere((n) => n.id == placedPc.id);
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

  for (final rule in rules.sourceBoxes) {
    if (_handledElsewhere.contains(rule.configKey)) continue;
    final value = setup[rule.configKey]?.toString().trim() ?? '';
    if (value.isEmpty || dismissed(rule.configKey)) continue;
    final existing =
        _existingByModelOrLabel(provider, [rule.model], rule.configKey);
    final node = existing ??
        place(_specOf(rule), avAutoNodeId(rule.configKey), onLeft: true);
    routeSource(rule.configKey, node);
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
    final rule = rules.sourceBoxFor(isVga ? kFlowVgaPlateKey : 'input_usb');
    if (rule != null) {
      final existing =
          _existingByModelOrLabel(provider, [rule.model], 'input_usb');
      final node = existing ??
          place(_specOf(rule), avAutoNodeId('input_usb'), onLeft: true);
      routeSource('input_usb', node);
    }
  }

  for (final rule in rules.sourceDevices) {
    final value = setup[rule.configKey]?.toString().trim() ?? '';
    if (value.isEmpty) continue;
    final node = boxFor(rule.resolved);
    if (node == null) {
      unresolved.add(UnroutedTie(rule.configKey, value,
          '${rule.target} is not on the canvas.'));
      continue;
    }
    routeSource(rule.configKey, node);
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

  // The program-audio number, read out here because the expansion bus below
  // labels its link with it whether or not the destinations run.
  final audioValue = setup['output_audio']?.toString().trim() ?? '';

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
  ({AvNode node, AvPort input, AvPort output})? receiverFor(
    String key,
    AvNode dest,
    FlowExtenderRule rule,
  ) {
    final rxId = avAutoNodeId('${key}_rx');

    AvNode? existing = nodesById[rxId];
    for (final n in newNodes) {
      if (n.id == rxId) existing = n;
    }
    existing ??= _extenderBetween(provider, dest,
        takes: rule.switcherType!, sends: rule.farType!, fedBySource: false);

    final node = existing ??
        place(
          _specOfExtender(rule),
          rxId,
          onLeft: false,
          // Immediately upstream of what it feeds, which is where it is in
          // the room: the receiver is on the wall behind the display.
          at: Offset(
            math.max(kAvAutoOriginX, dest.pos.dx - kAvAutoColumnPitch),
            dest.pos.dy,
          ),
          label: '${rule.label} — ${dest.label}',
        );

    return _extenderPorts(node, rule.switcherType!, rule.farType!);
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
    // receiver. The config states both ends and leaves the box between them
    // unsaid, so it is put in here rather than drawn as a lead that cannot be
    // bought. WHICH box, and for which pair of connectors, is a rule — see
    // [FlowExtenderRule].
    final rxRule = rules.extenderFor(
      switcherSignal: switcherPort.signal,
      farSignal: landing.signal,
      onOutput: true,
    );
    if (rxRule != null &&
        rxRule.switcherType != null &&
        rxRule.farType != null) {
      // Before inventing a box: does the far end take twisted pair itself?
      //
      // A projector with an HDBaseT socket needs no receiver, whatever its
      // config block's `input` happens to name — that field records which
      // connector somebody plugged into, and a room whose matrix output is
      // DTP and whose display has a DTP socket is a room where the answer is
      // that socket. Drawing a receiver into it quotes a box the room does
      // not need and puts a join in a run that has none.
      //
      // But only a socket the box REALLY has. A display whose model the
      // catalog does not carry falls back to the generic family template, and
      // that template hands every PROJECTORDEVICE an HDMI 1, an HDMI 2 and an
      // HDBaseT — sockets nobody has confirmed. Flat panels on outputs 3 and 4
      // are the usual case: the matrix output is twisted pair, the panel has
      // no DTP socket on the back of it, and the run was drawn straight into a
      // connector that does not exist while the receiver it needs went
      // unquoted. So a fallback template's HDBaseT only counts when the config
      // itself names it; otherwise the receiver goes in and the room-end lead
      // lands on the input the config DOES name.
      final native = dest.ports
          .where((p) =>
              p.signal == rxRule.switcherType! &&
              (p.isInput || p.direction == PortDirection.bidirectional))
          .firstOrNull;
      final catalogued =
          provider.avDeviceLibrary.templateForModel(dest.model) != null;
      if (native != null && (catalogued || toPort?.id == native.id)) {
        draw(
          configKey: key,
          value: value,
          from: switcher,
          fromPort: switcherPort,
          to: dest,
          toPort: native,
          signal: rxRule.switcherType!,
        );
        return;
      }

      // The receiver taken off the canvas by hand takes its two cables with
      // it: half a run drawn to a box that is not there is worse than none.
      if (dismissed('${key}_rx')) return;
      final rx = receiverFor(key, dest, rxRule);
      if (rx == null) {
        unresolved.add(UnroutedTie(
            key,
            value,
            '${switcherPort.label} carries '
            '${kSignalLabels[rxRule.switcherType!] ?? rxRule.switcherSignal} '
            'and ${dest.label} takes ${landing.label}, so the run needs a '
            '${rxRule.label} — and the catalog entry for ${rxRule.model} has '
            'no matching input and output to cable it by. Draw this one by '
            'hand.'));
        return;
      }
      draw(
        configKey: key,
        value: value,
        from: switcher,
        fromPort: switcherPort,
        to: rx.node,
        toPort: rx.input,
        signal: rxRule.switcherType!,
      );
      draw(
        configKey: key,
        value: value,
        from: rx.node,
        fromPort: rx.output,
        to: dest,
        toPort: landing,
        signal: rxRule.farType!,
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

  // ONLY IN A ROOM WITH A MATRIX. The `output_*` keys are numbers on the
  // switcher's OUTPUT side, and a display standing in for the switcher has no
  // output side to number: the run stops at the panel. So a huddle space's
  // destination keys are left alone rather than resolved against a box that
  // cannot answer them — and no confidence monitor and no speaker pair is
  // placed for a number that names nothing.
  if (displayHub == null) {
    final projectorCount =
        int.tryParse(setup['dev_projectors']?.toString().trim() ?? '') ?? 0;

    for (final rule in rules.destinationDevices) {
      final value = setup[rule.configKey]?.toString().trim() ?? '';
      if (value.isEmpty || value.toLowerCase() == 'none') continue;
      final node = boxFor(rule.resolved);
      if (node == null) {
        // A display output for a display the room does not have. Worth saying
        // out loud rather than reporting as a missing box: the number is dead
        // config left behind when the room shrank, and it will go on looking
        // like a second projector to everyone who reads the file.
        final number = int.tryParse(
                rule.target.substring(rule.target.lastIndexOf('_') + 1)) ??
            0;
        if (rule.target.startsWith('PROJECTORDEVICE_') &&
            number > projectorCount &&
            projectorCount > 0) {
          unresolved.add(UnroutedTie(
              rule.configKey,
              value,
              'This room has $projectorCount display'
              '${projectorCount == 1 ? '' : 's'} (dev_projectors), so there is '
              'no ${rule.target} for output $value to feed — the key is left '
              'over and nothing is drawn for it.'));
        } else {
          unresolved.add(UnroutedTie(rule.configKey, value,
              '${rule.target} is not on the canvas.'));
        }
        continue;
      }
      // The display's OWN config says which socket the lead goes into. That is
      // the fact this whole feature turns on: 'HDBaseT' on the projector block
      // is not a preference, it is the connector somebody plugged into.
      final block = config[node.id];
      final declared =
          (block is Map ? block['input']?.toString() : null)?.trim() ?? '';
      AvPort? landing =
          declared.isEmpty ? null : portForDeviceInput(node, declared);
      if (declared.isNotEmpty && landing == null) {
        unresolved.add(UnroutedTie(
            '${node.id}.input',
            declared,
            '${node.label} has no connector called "$declared" — the cable is '
            'drawn on its first video input instead.'));
      }
      routeDestination(rule.configKey, node, toPort: landing);
    }

    for (final rule in rules.destinationBoxes) {
      final value = setup[rule.configKey]?.toString().trim() ?? '';
      if (value.isEmpty ||
          value.toLowerCase() == 'none' ||
          dismissed(rule.configKey)) {
        continue;
      }
      // Which connectors the tie may land on. The assisted-listening feed is
      // line audio and everything else here is video, and a rule says which
      // rather than the key being special-cased by name.
      final signals = flowSignalsFromName(rule.signals);
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
          _existingByModelOrLabel(provider, [rule.model], rule.configKey);
      final node = existing ??
          place(_specOf(rule), avAutoNodeId(rule.configKey), onLeft: false);
      routeDestination(rule.configKey, node, signals: signals);
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

  // Capture: whichever box this room makes its USB feed with. A MediaPort in
  // one build and an AV Bridge in another, so the rule names the alternatives
  // in the order they should be looked for. A switcher output like the rest,
  // so a room with no switcher has none of it.
  if (displayHub == null) {
    for (final rule in rules.captureDestinations) {
      final value = setup[rule.configKey]?.toString().trim() ?? '';
      if (value.isEmpty || value.toLowerCase() == 'none') continue;
      final node = boxFor(rule.resolved);
      if (node == null) {
        unresolved.add(UnroutedTie(
            rule.configKey,
            value,
            'This room has none of ${rule.resolved.alternatives.join(', ')} on '
            'the canvas for the capture feed to land on.'));
        continue;
      }
      routeDestination(rule.configKey, node);
    }
  }

  // --- the USB switchers ------------------------------------------------------
  //  The Toggle, and every box like it: the room's peripherals hang off its
  //  DEVICE ports and the machines that can take them off its HOST ports, and
  //  the button on the panel decides which machine has them at any moment.
  //
  //  None of that is in the config. `dev_usb_switchers` is a count, and the
  //  block underneath it is control settings — there is no `input_` number for
  //  a USB lead anywhere in the file — so the drawing showed a Toggle with
  //  nothing plugged into it and the conferencing path stopped at the DSP.
  //  What lands where is a [FlowUsbRule]: an ordered list of what feeds DEVICE
  //  1, 2, 3 … and what HOST 1, 2 … feed, which is the way this shop wires
  //  them and the thing a shop that wires them differently edits.
  //
  //  Fixed positions, not a queue: a room with no doc cam leaves DEVICE 3
  //  empty rather than moving the AV Bridge down onto it, because the port a
  //  lead lands on is what the tech reads off the drawing. A peripheral the
  //  room does not have, or one whose catalog entry has no USB connector, is
  //  simply not drawn. A connector somebody has already plugged something
  //  else into is left exactly as they left it.
  for (final rule in rules.usbSwitchers) {
    final usbSwitcher = boxFor(FlowTarget(rule.switcher));
    if (usbSwitcher == null) continue;

    final devicePorts = [
      for (final p in usbSwitcher.ports)
        if (p.signal == SignalType.usbData && p.isInput) p,
    ];
    final hostPorts = [
      for (final p in usbSwitcher.ports)
        if (p.signal == SignalType.usbData && p.isOutput) p,
    ];

    /// True when this pass should stay off these two connectors, because one
    /// of them already has a lead on it going somewhere else. A USB socket
    /// takes one lead: a doc cam somebody has plugged into DEVICE 2 by hand is
    /// not also plugged into DEVICE 3 by this. The exact tie already drawn is
    /// not a clash — [draw] counts that one and moves on.
    bool clashes(String aNode, String aPort, String bNode, String bPort) {
      for (final c in provider.avCables) {
        final atA = (c.fromNodeId == aNode && c.fromPortId == aPort) ||
            (c.toNodeId == aNode && c.toPortId == aPort);
        final atB = (c.fromNodeId == bNode && c.fromPortId == bPort) ||
            (c.toNodeId == bNode && c.toPortId == bPort);
        if (atA != atB) return true;
      }
      return false;
    }

    /// One lead between the switcher and whatever a rule entry names, in the
    /// direction the port list says: a DEVICE port is fed, a HOST port feeds.
    void wire(String target, AvPort port, {required bool intoSwitcher}) {
      if (target.trim().isEmpty) return;
      final far = boxFor(
        FlowTarget(target),
        // The box has to have a USB socket of the right kind, or naming a
        // family finds the first block of it and stops — the DSP with no USB
        // output would silently take the DSP-with-one's place.
        ok: (node) => _usbPort(node, wantOutput: intoSwitcher) != null,
      );
      if (far == null) return;
      final farPort = _usbPort(far, wantOutput: intoSwitcher);
      if (farPort == null) return;
      if (clashes(far.id, farPort.id, usbSwitcher.id, port.id)) return;
      draw(
        configKey: usbSwitcher.id,
        value: port.label,
        from: intoSwitcher ? far : usbSwitcher,
        fromPort: intoSwitcher ? farPort : port,
        to: intoSwitcher ? usbSwitcher : far,
        toPort: intoSwitcher ? port : farPort,
        signal: SignalType.usbData,
      );
    }

    for (var i = 0; i < rule.devicePorts.length && i < devicePorts.length; i++) {
      wire(rule.devicePorts[i], devicePorts[i], intoSwitcher: true);
    }
    for (var i = 0; i < rule.hostPorts.length && i < hostPorts.length; i++) {
      wire(rule.hostPorts[i], hostPorts[i], intoSwitcher: false);
    }
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
  //  agreed what they mean, are settled first — see
  //  [FlowRules.outletAliases]. An
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
    final aliasPrefix = rules.outletAliases[wanted.join(' ')];
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

/// An outlet name as it should READ, rather than as it is tokenized.
///
/// Same `\r` problem as [outletNameTokens] — `Doc\rCam` is a two-line touch
/// panel button — but here the words are kept whole and in their original
/// case, because this is what gets printed on the drawing.
String outletDisplayName(String raw) => raw
    .replaceAll(r'\r', ' ')
    .replaceAll(r'\n', ' ')
    .replaceAll('\r', ' ')
    .replaceAll('\n', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Which controller and outlet a flow port is, or null when it is neither.
///
/// The node id is the config section (`POWERDEVICE_1`) and the port id the
/// catalog's outlet (`out_pwr_3`), so between them they name exactly one
/// `power1_outlet_3` key.
({int controller, int outlet})? powerOutletRef(String nodeId, String portId) {
  final device = RegExp(r'^POWERDEVICE_(\d+)$').firstMatch(nodeId);
  final port = RegExp(r'^out_pwr_(\d+)$').firstMatch(portId);
  if (device == null || port == null) return null;
  return (
    controller: int.parse(device.group(1)!),
    outlet: int.parse(port.group(1)!),
  );
}

/// What this room calls the outlet [portId] on [nodeId], or '' when it has no
/// name — an outlet nobody filled in, or a port that is not an outlet at all.
///
/// Read live from the config rather than off the port label, so renaming an
/// outlet on the System tab reaches a drawing that is already made.
String powerOutletName(
  Map<String, dynamic> config,
  String nodeId,
  String portId,
) {
  final ref = powerOutletRef(nodeId, portId);
  if (ref == null) return '';
  final setup = config['SYSTEM_SETUP'];
  if (setup is! Map) return '';
  final raw = setup['power${ref.controller}_outlet_${ref.outlet}'];
  final name = outletDisplayName(raw?.toString() ?? '');
  // 'None' is how a config says an outlet is spare; it is not what the outlet
  // is called.
  return name.toLowerCase() == 'none' ? '' : name;
}

/// [ports] with a power controller's outlets carrying the names this room
/// gives them — `OUTLET 3` becomes `OUTLET 3 · Via`.
///
/// Applied wherever a box gets its connectors from the catalog, because the
/// catalog knows a controller has eight outlets and nothing about which is
/// which. Anything that is not a power controller comes back untouched, and so
/// does an outlet the room has not named.
List<AvPort> withOutletNames(
  List<AvPort> ports,
  String configKey,
  Map<String, dynamic> config,
) {
  if (!configKey.startsWith('POWERDEVICE_')) return ports;
  return [
    for (final port in ports)
      port.copyWith(
        label: portLabelWithNote(
          port.label,
          powerOutletName(config, configKey, port.id),
        ),
      ),
  ];
}

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

// The outlet names the trade has already settled — 'Switch' is the matrix —
// are [FlowRules.outletAliases], because which words a shop has settled is a
// fact about that shop. 'Switch' alone was a tie between the matrix, the USB
// switcher and every 'Switcher 2' on the canvas, and a tie drew nothing at
// all in every room on the estate. Keyed on the WHOLE outlet name, so it
// decides 'Switch' and touches nothing else: 'USB Switch' is two words,
// misses the table, and goes on being scored the way it always was.


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

/// The extender already cabled onto [box], for a diagram somebody drew before
/// this feature put them in.
///
/// Matched on what the box DOES — it [takes] one signal and [sends] another,
/// and there is a cable between it and this source or destination — rather
/// than on its model, because the room end of a run gets built with whatever
/// receiver was on the shelf. [fedBySource] true looks downstream of a source
/// (the transmitter beside a camera); false looks upstream of a destination
/// (the receiver behind a display).
///
/// Never a box the config describes. The switcher itself takes twisted pair
/// and sends HDMI and would match this shape, and a diagram that already ran
/// the old direct DTP-to-HDMI cable would then have the switcher cabled to
/// itself. The config having no block for it is the whole reason the extender
/// is being invented.
AvNode? _extenderBetween(
  AppStateProvider provider,
  AvNode box, {
  required SignalType takes,
  required SignalType sends,
  required bool fedBySource,
}) {
  for (final cable in provider.avCables) {
    final id = fedBySource ? cable.fromNodeId : cable.toNodeId;
    if (id != box.id) continue;
    final other = provider
        .avNodeById(fedBySource ? cable.toNodeId : cable.fromNodeId);
    if (other == null) continue;
    if (provider.roomConfig.containsKey(other.id)) continue;
    final accepts = other.ports.any((p) =>
        p.signal == takes &&
        (p.isInput || p.direction == PortDirection.bidirectional));
    final emits = other.ports.any((p) => p.signal == sends && p.isOutput);
    if (accepts && emits) return other;
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
///   * a room whose switcher is not on the canvas yet is left completely
///     alone — there is nothing for a cable to run to;
///   * a room with no switcher AT ALL routes its sources onto the display
///     instead, which is how a huddle space is wired.
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

  // The controller's outlets, named the way the room names them. Refreshed
  // here rather than only when the box is placed, because an outlet renamed on
  // the System tab is part of what this pass is triggered by (see
  // [routingFingerprint]) — without this, a controller drawn last month would
  // keep printing the name the outlet used to have.
  for (final node in [...provider.avNodes]) {
    if (!node.id.startsWith('POWERDEVICE_')) continue;
    final named = withOutletNames(node.ports, node.id, provider.roomConfig);
    if (named.length != node.ports.length) continue;
    var changed = false;
    for (var i = 0; i < named.length; i++) {
      if (named[i].label != node.ports[i].label) changed = true;
    }
    if (!changed) continue;
    provider.updateAvNode(node.copyWith(ports: named), recordUndo: false);
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
