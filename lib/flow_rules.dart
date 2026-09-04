import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'av_flow_model.dart';
import 'room_locations.dart';

/// ============================================================================
///  AV FLOW RULE BOOK
/// ============================================================================
///  What the routing pass knows about rooms, as data instead of as constants
///  compiled into it.
///
///  Drawing a room from its config takes two kinds of knowledge. One is
///  mechanical and belongs in code: which socket the number "3B" names, which
///  connector a lead can land on, whether a port is already spoken for. The
///  other is a set of decisions this shop has made about how its rooms are
///  built — the room PC is the box behind `input_pc`, a twisted-pair output
///  reaching an HDMI display needs a DTP 230 receiver between them, the
///  Toggle's DEVICE ports carry the DSP, the AV Bridge and the doc cam in that
///  order. Every one of those used to be a `const` map in av_flow_routing.dart,
///  which meant a new box, a new source key or a different extender was a code
///  change and a release.
///
///  This is that second half, loaded from `av_flow_rules.json` beside
///  `ui_schema.json` and `av_devices.json`, edited on the **Flow Rules** tab,
///  and shipped with defaults that reproduce exactly what the constants did.
///
///  ---------------------------------------------------------------------------
///  THE FAMILIES
///  ---------------------------------------------------------------------------
///  * SOURCE BOXES ([FlowBoxRule] in [FlowRules.sourceBoxes]) — an `input_*`
///    key whose box has no config block of its own: the room PC, the doc cam,
///    the laptop at a plate. The rule says what to call it, which catalog model
///    to give it, where it lives, and whether it is the room's to pay for.
///
///  * SOURCE DEVICES ([FlowDeviceRule] in [FlowRules.sourceDevices]) — an
///    `input_*` key naming a device the config DOES describe, so the box is
///    already on the canvas and only the cable is missing.
///
///  * DESTINATION DEVICES / BOXES — the same two ideas at the other end of the
///    matrix: `output_proj_1` is PROJECTORDEVICE_1, `output_monitor_1` is a
///    confidence monitor nobody wrote a block for.
///
///  * EXTENDERS ([FlowExtenderRule]) — "a switcher connector carrying X, a far
///    end that takes Y, and the box that goes between them". Both the receiver
///    on an output and the transmitter on an input are this one rule read in
///    the two directions, and so is every FORMAT CONVERTER: a VGA plate on an
///    HDMI input is a DVC RGB-HD A, a USB-C plate is a USB-C HD 101. A pair of
///    ends this family does not cover and that do not go straight together
///    ([flowSignalsInterchange]) is reported rather than drawn as a lead
///    nobody can buy.
///
///  * USB SWITCHERS ([FlowUsbRule]) — which peripheral lands on each DEVICE
///    port of a USB switcher, and which machine each HOST port feeds. Nothing
///    in the config states this; it is the way the rooms are wired.
///
///  * EXPANSION BUS, OUTLET ALIASES — the words that identify a DMP EXP
///    connector, and the outlet labels the trade has already settled ("Switch"
///    is the matrix).
///
///  ---------------------------------------------------------------------------
///  NAMING A BOX IN A RULE
///  ---------------------------------------------------------------------------
///  Several rules have to point at "whatever box in this room is the DSP". The
///  same small syntax does it everywhere — see [FlowTarget]:
///
///    `DSPDEVICE_`        a config section PREFIX: the first numbered block of
///                        that family that fits (trailing underscore)
///    `RECORDERDEVICE_1`  one exact config section
///    `input_doc_cam`     the box the source rules place for that config key
///    `Document Camera`   a catalog MODEL, matched against what is on the
///                        canvas
///
///  Alternatives are separated with `|` and tried in order, so the capture box
///  is `MEDIAPORTDEVICE_|RECORDERDEVICE_|USBDEVICE_` — whichever of the three
///  this room was built with.
/// ============================================================================

/// WHICH EDITION OF THE RULE BOOK A SAVED FILE WAS WRITTEN BY.
///
/// Stamped into every file this app writes, and read back for one purpose:
/// telling "this shop deleted that rule" apart from "that rule did not exist
/// when this file was saved".
///
/// The two are indistinguishable without it, and the difference matters,
/// because defining a family in the file REPLACES the built-in one. When the
/// room's speakers stopped being a constant in the routing pass and became a
/// `destinationBoxes` rule, every rule file already on a shared drive was a
/// file with a destinationBoxes block and no speakers in it - so every room
/// on every one of those installs would quietly have stopped drawing the run
/// to the ceiling. Version 2 is that rule arriving; a file older than it gets
/// it filled in, and a file newer than it is taken at its word.
const int kFlowRulesVersion = 3;

/// The version at which each rule the app back-fills was introduced.
/// A rule missing from a file written BEFORE its version was never a choice.
const Map<String, int> kFlowRuleAddedIn = {'output_audio': 2};

/// The same, for the boxes in [FlowRules.extenders].
///
/// Version 3 is the format converters arriving - the run from a VGA plate to
/// an HDMI input, and the four beside it. Before it, an extender file was a
/// file about twisted pair and nothing else, so a saved rule book with two
/// entries in it is a shop that never had the converters rather than a shop
/// that deleted them.
const Map<String, int> kFlowExtenderAddedIn = {
  'vga_to_hdmi': 3,
  'usbc_to_hdmi': 3,
  'dp_to_hdmi': 3,
  'sdi_to_hdmi': 3,
  'hdmi_to_dp': 3,
};

/// How many numbered blocks of a family a rule looks through when it names one
/// by its prefix ('DSPDEVICE_'). The device counts in these rooms are single
/// digits; this is the point past which "the DSP" stops meaning anything.
const int kFlowFamilyDepth = 8;

/// Where a rule's box lives, as the zone names the room locations use.
const List<String> kFlowZones = ['lectern', 'rack', 'wall', 'ceiling'];

/// The source-box rule for the laptop plate in a VGA room.
///
/// `input_usb` is one config key with two meanings — the room has a USB-C
/// plate or it has a VGA plate, and `gui_usb_or_vga` says which — so the rule
/// book carries both boxes and the pass picks between them. This is the key
/// the VGA one is filed under; it is not a config key and nothing reads it out
/// of SYSTEM_SETUP.
const String kFlowVgaPlateKey = 'input_usb (VGA room)';

RoomZone flowZoneFromName(String name) => switch (name.trim().toLowerCase()) {
      'rack' => RoomZone.rack,
      'wall' => RoomZone.wall,
      'ceiling' => RoomZone.ceiling,
      _ => RoomZone.lectern,
    };

/// The signal groups a rule can ask for by name, for the connector a tie is
/// allowed to land on.
const List<String> kFlowSignalGroups = ['video', 'lineAudio', 'speaker', 'usb'];

const Set<SignalType> kFlowVideoSignals = {
  SignalType.hdmi,
  SignalType.hdbaset,
  SignalType.displayPort,
  SignalType.usbC,
  SignalType.sdi,
  SignalType.vga,
};

const Set<SignalType> kFlowLineAudio = {
  SignalType.analogAudio,
  SignalType.digitalAudio,
  SignalType.dante,
};

Set<SignalType> flowSignalsFromName(String name) =>
    switch (name.trim().toLowerCase()) {
      'lineaudio' => kFlowLineAudio,
      'speaker' => const {SignalType.speaker},
      'usb' => const {SignalType.usbData},
      _ => kFlowVideoSignals,
    };

/// The signals that go straight into one another, with nothing in between.
///
/// A run whose two ends disagree is normally a box the config forgot to
/// mention: a VGA plate on an HDMI input is a converter, not a lead. But not
/// every disagreement is. A line output landing on a MIC/LINE input is one
/// cable and always was — the connector takes either level and the trim on the
/// front panel is how the difference is dealt with — and a room that quoted a
/// converter for it would be quoting a box nobody sells.
///
/// So the families here are the exceptions, and everything outside them needs
/// a [FlowExtenderRule] or gets reported. Speaker level is deliberately NOT in
/// with the line audio: an amplifier's terminals into a line input is the one
/// audio mistake that costs a box, and it is worth saying out loud.
const List<Set<SignalType>> kFlowInterchangeable = [
  {SignalType.analogAudio, SignalType.micLine},
];

/// True when a lead can run from [from] to [to] with no box between them.
bool flowSignalsInterchange(SignalType from, SignalType to) {
  if (from == to) return true;
  for (final family in kFlowInterchangeable) {
    if (family.contains(from) && family.contains(to)) return true;
  }
  return false;
}

/// One `|`-separated reference to a box in the room — see the file header.
class FlowTarget {
  final String raw;

  const FlowTarget(this.raw);

  /// The alternatives, in the order they should be tried.
  List<String> get alternatives => [
        for (final part in raw.split('|'))
          if (part.trim().isNotEmpty) part.trim(),
      ];

  bool get isEmpty => alternatives.isEmpty;

  @override
  String toString() => raw;
}

/// A box the config names but has no block for: the room PC, the doc cam, the
/// laptop at the HDMI plate, a confidence monitor.
class FlowBoxRule {
  /// The SYSTEM_SETUP key this box hangs off ('input_pc', 'output_monitor_1').
  final String configKey;

  /// What the box is called on the drawing.
  final String label;

  /// Catalog model, which is where its connectors, price and rack height come
  /// from. A model the catalog has never heard of still draws — it falls back
  /// to the family template — so a new box can be described here first and
  /// priced later.
  final String model;

  /// 'lectern', 'rack' or 'wall'.
  final String zone;

  /// True for a box the room does not buy: somebody's own laptop.
  final bool excludeFromCost;

  /// Which connectors the tie may land on — 'video' unless the rule says
  /// otherwise. The assisted-listening feed is the reason this exists: it is a
  /// line-audio output, and looking for a video socket on it finds nothing.
  final String signals;

  /// Boxes whose presence means this one is NOT placed, in the [FlowTarget]
  /// syntax. Empty for most rules.
  ///
  /// The room's speakers are the reason this exists. `output_audio` in a room
  /// with no DSP is the amplifier inside the switcher and the run is speaker
  /// level to the ceiling; in a room WITH a DSP the same key is the number of
  /// the tie across the expansion bus, and the pair are joined by their EXP
  /// connectors instead. So the rule is "speakers, unless this room has a
  /// DSP" — `unless: 'DSPDEVICE_'` — rather than a condition compiled into
  /// the routing pass where nobody can see or change it.
  final String unless;

  const FlowBoxRule({
    required this.configKey,
    required this.label,
    required this.model,
    this.zone = 'lectern',
    this.excludeFromCost = false,
    this.signals = 'video',
    this.unless = '',
  });

  /// The boxes [unless] names, in the order they should be looked for.
  FlowTarget get blockedBy => FlowTarget(unless);

  factory FlowBoxRule.fromJson(String configKey, Map<String, dynamic> json) =>
      FlowBoxRule(
        configKey: configKey,
        label: json['label']?.toString() ?? configKey,
        model: json['model']?.toString() ?? '',
        zone: json['zone']?.toString() ?? 'lectern',
        excludeFromCost: json['excludeFromCost'] == true,
        signals: json['signals']?.toString() ?? 'video',
        unless: json['unless']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'model': model,
        if (zone != 'lectern') 'zone': zone,
        if (excludeFromCost) 'excludeFromCost': true,
        if (signals != 'video') 'signals': signals,
        if (unless.isNotEmpty) 'unless': unless,
      };

  FlowBoxRule copyWith({
    String? configKey,
    String? label,
    String? model,
    String? zone,
    bool? excludeFromCost,
    String? signals,
    String? unless,
  }) =>
      FlowBoxRule(
        configKey: configKey ?? this.configKey,
        label: label ?? this.label,
        model: model ?? this.model,
        zone: zone ?? this.zone,
        excludeFromCost: excludeFromCost ?? this.excludeFromCost,
        signals: signals ?? this.signals,
        unless: unless ?? this.unless,
      );
}

/// A config key naming a device the config already describes: only the cable
/// is missing.
class FlowDeviceRule {
  final String configKey;

  /// Which block, in the [FlowTarget] syntax — one section, a family prefix,
  /// or several alternatives.
  final String target;

  const FlowDeviceRule({required this.configKey, required this.target});

  FlowTarget get resolved => FlowTarget(target);

  factory FlowDeviceRule.fromJson(String configKey, dynamic json) =>
      FlowDeviceRule(
        configKey: configKey,
        target: json is Map
            ? (json['target']?.toString() ?? '')
            : json.toString(),
      );

  dynamic toJson() => target;

  FlowDeviceRule copyWith({String? configKey, String? target}) =>
      FlowDeviceRule(
        configKey: configKey ?? this.configKey,
        target: target ?? this.target,
      );
}

/// The box that goes in the middle of a run whose two ends do not take the
/// same cable.
///
/// A DTP output does not plug into a display: it is twisted pair, and it lands
/// on a receiver at the room end which turns it back into a foot of HDMI.
/// Nobody writes that in the config because everybody knows it, and a drawing
/// that joins the two directly draws a cable that cannot exist — and an
/// estimate taken off it is missing a $600 box per display.
class FlowExtenderRule {
  /// Stable id, so the box it places keeps its name across passes.
  final String id;

  /// The signal at the SWITCHER end of the run.
  final String switcherSignal;

  /// The signal the far end takes.
  final String farSignal;

  /// True when this sits on an OUTPUT of the switcher (a receiver at the
  /// display); false for an INPUT (a transmitter at the camera).
  final bool onOutput;

  final String model;
  final String label;
  final String zone;

  const FlowExtenderRule({
    required this.id,
    required this.switcherSignal,
    required this.farSignal,
    required this.onOutput,
    required this.model,
    required this.label,
    this.zone = 'wall',
  });

  SignalType? get switcherType => signalFromName(switcherSignal);
  SignalType? get farType => signalFromName(farSignal);

  factory FlowExtenderRule.fromJson(String id, Map<String, dynamic> json) =>
      FlowExtenderRule(
        id: id,
        switcherSignal: json['switcherSignal']?.toString() ?? 'hdbaset',
        farSignal: json['farSignal']?.toString() ?? 'hdmi',
        onOutput: json['onOutput'] != false,
        model: json['model']?.toString() ?? '',
        label: json['label']?.toString() ?? id,
        zone: json['zone']?.toString() ?? 'wall',
      );

  Map<String, dynamic> toJson() => {
        'switcherSignal': switcherSignal,
        'farSignal': farSignal,
        'onOutput': onOutput,
        'model': model,
        'label': label,
        'zone': zone,
      };

  FlowExtenderRule copyWith({
    String? id,
    String? switcherSignal,
    String? farSignal,
    bool? onOutput,
    String? model,
    String? label,
    String? zone,
  }) =>
      FlowExtenderRule(
        id: id ?? this.id,
        switcherSignal: switcherSignal ?? this.switcherSignal,
        farSignal: farSignal ?? this.farSignal,
        onOutput: onOutput ?? this.onOutput,
        model: model ?? this.model,
        label: label ?? this.label,
        zone: zone ?? this.zone,
      );
}

/// What hangs off a USB switcher, in port order.
///
/// The Toggle is the case this was written for: the room's peripherals arrive
/// on its DEVICE ports and the machines that can take them hang off its HOST
/// ports, and the panel button decides which machine has them. None of it is
/// in the config — `dev_usb_switchers` is a count — so the order is stated
/// here instead, and a room wired differently states its own.
class FlowUsbRule {
  /// The USB switcher this describes, in [FlowTarget] syntax.
  final String switcher;

  /// What lands on DEVICE 1, DEVICE 2, DEVICE 3 … in order. Each entry is a
  /// [FlowTarget]; an empty one leaves that port free.
  final List<String> devicePorts;

  /// What HOST 1, HOST 2 … feed, same syntax.
  final List<String> hostPorts;

  const FlowUsbRule({
    required this.switcher,
    this.devicePorts = const [],
    this.hostPorts = const [],
  });

  factory FlowUsbRule.fromJson(Map<String, dynamic> json) => FlowUsbRule(
        switcher: json['switcher']?.toString() ?? 'USBDEVICE_1',
        devicePorts: [
          for (final v in (json['devicePorts'] as List? ?? const []))
            v.toString(),
        ],
        hostPorts: [
          for (final v in (json['hostPorts'] as List? ?? const []))
            v.toString(),
        ],
      );

  Map<String, dynamic> toJson() => {
        'switcher': switcher,
        'devicePorts': devicePorts,
        'hostPorts': hostPorts,
      };

  FlowUsbRule copyWith({
    String? switcher,
    List<String>? devicePorts,
    List<String>? hostPorts,
  }) =>
      FlowUsbRule(
        switcher: switcher ?? this.switcher,
        devicePorts: devicePorts ?? this.devicePorts,
        hostPorts: hostPorts ?? this.hostPorts,
      );
}

/// The whole rule book.
///
/// Every list is ordered, and the order is the order the pass tries things in.
/// A rule the file does not mention keeps its built-in value only when the
/// file leaves the WHOLE family out: defining `"sources"` at all replaces the
/// built-in sources, the same way `device_types` works in ui_schema.json. That
/// is what makes a rule removable — a shop that does not put doc cams in can
/// say so.
class FlowRules {
  final List<FlowBoxRule> sourceBoxes;
  final List<FlowDeviceRule> sourceDevices;
  final List<FlowDeviceRule> destinationDevices;
  final List<FlowBoxRule> destinationBoxes;

  /// `output_cc`-style keys, whose box is whichever of several this room has.
  final List<FlowDeviceRule> captureDestinations;

  final List<FlowExtenderRule> extenders;
  final List<FlowUsbRule> usbSwitchers;

  /// Words on a connector label that mean "expansion bus" ('EXP', 'EXPANSION').
  final List<String> expansionKeywords;

  /// Outlet labels the trade has already settled: 'switch' is the matrix, not
  /// a coin toss between the matrix and the USB switcher.
  final Map<String, String> outletAliases;

  /// Where this came from, for the tab to show.
  String source;

  FlowRules({
    required this.sourceBoxes,
    required this.sourceDevices,
    required this.destinationDevices,
    required this.destinationBoxes,
    required this.captureDestinations,
    required this.extenders,
    required this.usbSwitchers,
    required this.expansionKeywords,
    required this.outletAliases,
    this.source = 'Built-in defaults',
  });

  /// The rules as they were when they were constants in av_flow_routing.dart.
  /// Changing anything here changes what a room draws with no rule file, so
  /// this is the shipped behavior and the "Reset to built-in" button both.
  factory FlowRules.builtIn() => FlowRules(
        sourceBoxes: const [
          FlowBoxRule(
              configKey: 'input_pc', label: 'Room PC', model: 'PC'),
          FlowBoxRule(
              configKey: 'input_doc_cam',
              label: 'Document camera',
              model: 'Document Camera'),
          FlowBoxRule(
              configKey: 'input_hdmi',
              label: 'Laptop at the HDMI plate',
              model: 'HDMI Laptop',
              excludeFromCost: true),
          FlowBoxRule(
              configKey: 'input_dvd',
              label: 'DVD player',
              model: 'DVD Player',
              zone: 'rack'),
          FlowBoxRule(
              configKey: 'input_blu_ray',
              label: 'Blu-ray player',
              model: 'Blu-ray Player',
              zone: 'rack'),
          // The laptop plate, both ways round — see [kFlowVgaPlateKey].
          FlowBoxRule(
              configKey: 'input_usb',
              label: 'Laptop at the USB-C plate',
              model: 'USB-C Laptop',
              excludeFromCost: true),
          FlowBoxRule(
              configKey: kFlowVgaPlateKey,
              label: 'Laptop at the VGA plate',
              model: 'VGA Laptop',
              excludeFromCost: true),
        ],
        sourceDevices: const [
          FlowDeviceRule(
              configKey: 'input_wireless', target: 'WIRELESSDEVICE_1'),
          FlowDeviceRule(
              configKey: 'input_inst_cam', target: 'CAMERADEVICE_1'),
          FlowDeviceRule(configKey: 'input_aud_cam', target: 'CAMERADEVICE_2'),
        ],
        destinationDevices: const [
          FlowDeviceRule(
              configKey: 'output_proj_1', target: 'PROJECTORDEVICE_1'),
          FlowDeviceRule(
              configKey: 'output_proj_2', target: 'PROJECTORDEVICE_2'),
          FlowDeviceRule(
              configKey: 'output_proj_3', target: 'PROJECTORDEVICE_3'),
          FlowDeviceRule(
              configKey: 'output_proj_4', target: 'PROJECTORDEVICE_4'),
        ],
        destinationBoxes: const [
          FlowBoxRule(
              configKey: 'output_monitor_1',
              label: 'Confidence monitor',
              model: 'Confidence Monitor'),
          FlowBoxRule(
              configKey: 'output_monitor_2',
              label: 'Confidence monitor 2',
              model: 'Confidence Monitor'),
          FlowBoxRule(
              configKey: 'output_audio_ald',
              label: 'Assisted listening',
              model: 'Assisted Listening',
              zone: 'rack',
              signals: 'lineAudio'),
          // The room's speakers, on the amplifier inside the switcher. See
          // [FlowBoxRule.unless] for why a room with a DSP draws none: there
          // the program audio never leaves the pair as analog, and the run
          // this rule would draw does not exist.
          FlowBoxRule(
              configKey: 'output_audio',
              label: 'Ceiling speakers',
              model: 'Ceiling Speakers',
              zone: 'ceiling',
              signals: 'speaker',
              unless: 'DSPDEVICE_'),
        ],
        captureDestinations: const [
          FlowDeviceRule(
              configKey: 'output_cc',
              target: 'MEDIAPORTDEVICE_1|RECORDERDEVICE_1|USBDEVICE_1'),
          FlowDeviceRule(
              configKey: 'output_cc2',
              target: 'MEDIAPORTDEVICE_1|RECORDERDEVICE_1|USBDEVICE_1'),
        ],
        extenders: const [
          FlowExtenderRule(
            id: 'rx',
            switcherSignal: 'hdbaset',
            farSignal: 'hdmi',
            onOutput: true,
            model: 'DTP HDMI 4K 230 Rx',
            label: 'Room-end DTP receiver',
            zone: 'wall',
          ),
          FlowExtenderRule(
            id: 'tx',
            switcherSignal: 'hdbaset',
            farSignal: 'hdmi',
            onOutput: false,
            model: 'DTP HDMI 4K 230 Tx',
            label: 'DTP transmitter',
            zone: 'lectern',
          ),
          // THE FORMAT CONVERTERS. Same rule, same shape, a different reason
          // for the box: twisted pair needs a receiver because of the
          // DISTANCE, and these need one because of the FORMAT. A VGA plate
          // does not go into an HDMI input at any length.
          //
          // All five run toward HDMI or away from it, because that is what
          // the switchers in these rooms take and give. A pair with no rule
          // here is not drawn as a lead that cannot be bought - it is
          // reported, so somebody picks the box and adds it. See
          // [flowSignalsInterchange].
          FlowExtenderRule(
            id: 'vga_to_hdmi',
            switcherSignal: 'hdmi',
            farSignal: 'vga',
            onOutput: false,
            model: 'DVC RGB-HD A',
            label: 'VGA to HDMI converter',
            zone: 'lectern',
          ),
          FlowExtenderRule(
            id: 'usbc_to_hdmi',
            switcherSignal: 'hdmi',
            farSignal: 'usbC',
            onOutput: false,
            model: 'USB-C HD 101',
            label: 'USB-C to HDMI interface',
            zone: 'lectern',
          ),
          FlowExtenderRule(
            id: 'dp_to_hdmi',
            switcherSignal: 'hdmi',
            farSignal: 'displayPort',
            onOutput: false,
            model: 'DPH 101 4K PLUS',
            label: 'DisplayPort to HDMI converter',
            zone: 'lectern',
          ),
          FlowExtenderRule(
            id: 'sdi_to_hdmi',
            switcherSignal: 'hdmi',
            farSignal: 'sdi',
            onOutput: false,
            model: 'DSC 3G-HD A',
            label: 'SDI to HDMI converter',
            zone: 'lectern',
          ),
          // The one that goes the other way: a panel with only a DisplayPort
          // socket on an HDMI output.
          FlowExtenderRule(
            id: 'hdmi_to_dp',
            switcherSignal: 'hdmi',
            farSignal: 'displayPort',
            onOutput: true,
            model: 'HDP 101 4K',
            label: 'HDMI to DisplayPort converter',
            zone: 'wall',
          ),
        ],
        usbSwitchers: const [
          FlowUsbRule(
            switcher: 'USBDEVICE_1',
            devicePorts: [
              'DSPDEVICE_',
              'RECORDERDEVICE_|MEDIAPORTDEVICE_',
              'input_doc_cam',
            ],
            hostPorts: ['input_pc'],
          ),
        ],
        expansionKeywords: const ['EXP', 'EXPANSION'],
        outletAliases: const {'switch': 'SWITCHERDEVICE_'},
      );

  /// Reads a rule file. A family the document leaves out keeps its built-in
  /// rules; a family it defines replaces them outright.
  factory FlowRules.fromJson(Map<String, dynamic> doc) {
    final rules = FlowRules.builtIn();
    // Absent on every file written before the stamp existed, which is exactly
    // what "0" should mean - see [kFlowRulesVersion].
    final writtenBy = (doc['__rulesVersion'] as num?)?.toInt() ?? 0;

    List<FlowBoxRule> boxes(String key, List<FlowBoxRule> fallback) {
      final raw = doc[key];
      if (raw is! Map) return fallback;
      final read = [
        for (final e in raw.entries)
          if (!e.key.toString().startsWith('__') && e.value is Map)
            FlowBoxRule.fromJson(
              e.key.toString(),
              (e.value as Map).map((k, v) => MapEntry(k.toString(), v)),
            ),
      ];
      // A rule this file is simply too old to have had an opinion about. Not
      // a deletion - see [kFlowRuleAddedIn].
      return [
        ...read,
        for (final builtIn in fallback)
          if (writtenBy < (kFlowRuleAddedIn[builtIn.configKey] ?? 0) &&
              !read.any((r) => r.configKey == builtIn.configKey))
            builtIn,
      ];
    }

    List<FlowDeviceRule> devices(String key, List<FlowDeviceRule> fallback) {
      final raw = doc[key];
      if (raw is! Map) return fallback;
      return [
        for (final e in raw.entries)
          if (!e.key.toString().startsWith('__'))
            FlowDeviceRule.fromJson(e.key.toString(), e.value),
      ];
    }

    final extendersRaw = doc['extenders'];
    final usbRaw = doc['usbSwitchers'];
    final keywordsRaw = doc['expansionKeywords'];
    final aliasesRaw = doc['outletAliases'];

    return FlowRules(
      sourceBoxes: boxes('sourceBoxes', rules.sourceBoxes),
      sourceDevices: devices('sourceDevices', rules.sourceDevices),
      destinationDevices:
          devices('destinationDevices', rules.destinationDevices),
      destinationBoxes: boxes('destinationBoxes', rules.destinationBoxes),
      captureDestinations:
          devices('captureDestinations', rules.captureDestinations),
      extenders: extendersRaw is! Map
          ? rules.extenders
          : () {
              final read = [
                for (final e in extendersRaw.entries)
                  if (!e.key.toString().startsWith('__') && e.value is Map)
                    FlowExtenderRule.fromJson(
                      e.key.toString(),
                      (e.value as Map).map((k, v) => MapEntry(k.toString(), v)),
                    ),
              ];
              // A converter this file is simply too old to have had an
              // opinion about - see [kFlowExtenderAddedIn].
              return [
                ...read,
                for (final builtIn in rules.extenders)
                  if (writtenBy < (kFlowExtenderAddedIn[builtIn.id] ?? 0) &&
                      !read.any((r) => r.id == builtIn.id))
                    builtIn,
              ];
            }(),
      usbSwitchers: usbRaw is! List
          ? rules.usbSwitchers
          : [
              for (final e in usbRaw)
                if (e is Map)
                  FlowUsbRule.fromJson(
                      e.map((k, v) => MapEntry(k.toString(), v))),
            ],
      expansionKeywords: keywordsRaw is! List
          ? rules.expansionKeywords
          : [for (final k in keywordsRaw) k.toString().toUpperCase()],
      outletAliases: aliasesRaw is! Map
          ? rules.outletAliases
          : {
              for (final e in aliasesRaw.entries)
                if (!e.key.toString().startsWith('__'))
                  e.key.toString().toLowerCase(): e.value.toString(),
            },
    );
  }

  Map<String, dynamic> toJson() => {
        '__readme':
            'AV flow rules for the Room Config Builder: which box each config '
                'key means, what goes between two ends that do not take the '
                'same cable - a DTP receiver for the distance, a format '
                'converter for a VGA or USB-C source on an HDMI input - and '
                'what hangs off a USB switcher. Edited on the Flow Rules tab. '
                "A family left out of this file keeps the app's built-in "
                'rules.',
        // Which edition of the rule book wrote this - see [kFlowRulesVersion].
        // It is how a rule somebody DELETED is told from one that did not
        // exist yet, and nothing else reads it.
        '__rulesVersion': kFlowRulesVersion,
        'sourceBoxes': {
          for (final r in sourceBoxes) r.configKey: r.toJson(),
        },
        'sourceDevices': {
          for (final r in sourceDevices) r.configKey: r.toJson(),
        },
        'destinationDevices': {
          for (final r in destinationDevices) r.configKey: r.toJson(),
        },
        'destinationBoxes': {
          for (final r in destinationBoxes) r.configKey: r.toJson(),
        },
        'captureDestinations': {
          for (final r in captureDestinations) r.configKey: r.toJson(),
        },
        'extenders': {
          for (final r in extenders) r.id: r.toJson(),
        },
        'usbSwitchers': [for (final r in usbSwitchers) r.toJson()],
        'expansionKeywords': expansionKeywords,
        'outletAliases': outletAliases,
      };

  FlowRules copyWith({
    List<FlowBoxRule>? sourceBoxes,
    List<FlowDeviceRule>? sourceDevices,
    List<FlowDeviceRule>? destinationDevices,
    List<FlowBoxRule>? destinationBoxes,
    List<FlowDeviceRule>? captureDestinations,
    List<FlowExtenderRule>? extenders,
    List<FlowUsbRule>? usbSwitchers,
    List<String>? expansionKeywords,
    Map<String, String>? outletAliases,
  }) =>
      FlowRules(
        sourceBoxes: sourceBoxes ?? this.sourceBoxes,
        sourceDevices: sourceDevices ?? this.sourceDevices,
        destinationDevices: destinationDevices ?? this.destinationDevices,
        destinationBoxes: destinationBoxes ?? this.destinationBoxes,
        captureDestinations: captureDestinations ?? this.captureDestinations,
        extenders: extenders ?? this.extenders,
        usbSwitchers: usbSwitchers ?? this.usbSwitchers,
        expansionKeywords: expansionKeywords ?? this.expansionKeywords,
        outletAliases: outletAliases ?? this.outletAliases,
        source: source,
      );

  // --- lookups the routing pass uses ----------------------------------------

  FlowBoxRule? sourceBoxFor(String configKey) {
    for (final r in sourceBoxes) {
      if (r.configKey == configKey) return r;
    }
    return null;
  }

  FlowBoxRule? destinationBoxFor(String configKey) {
    for (final r in destinationBoxes) {
      if (r.configKey == configKey) return r;
    }
    return null;
  }

  /// The extender for a run whose switcher end carries [switcherSignal] and
  /// whose far end takes [farSignal], or null when the two ends need no box
  /// between them.
  FlowExtenderRule? extenderFor({
    required SignalType switcherSignal,
    required SignalType farSignal,
    required bool onOutput,
  }) {
    for (final r in extenders) {
      if (r.onOutput != onOutput) continue;
      if (r.switcherType != switcherSignal) continue;
      if (r.farType != farSignal) continue;
      return r;
    }
    return null;
  }

  /// True when [label]'s words name an expansion-bus connector.
  bool isExpansionLabel(String label) {
    final words = label.toUpperCase().split(RegExp(r'[^A-Z0-9]+'));
    return expansionKeywords.any((k) => words.contains(k.toUpperCase()));
  }

  /// Every config key any rule mentions, for the editor's "what is covered"
  /// view and for the tests that keep this in step with the schema.
  Set<String> get configKeys => {
        for (final r in sourceBoxes) r.configKey,
        for (final r in sourceDevices) r.configKey,
        for (final r in destinationDevices) r.configKey,
        for (final r in destinationBoxes) r.configKey,
        for (final r in captureDestinations) r.configKey,
      };

  /// Every catalog model a rule would place, so the editor can say which of
  /// them the device catalog does not carry yet.
  Set<String> get referencedModels => {
        for (final r in sourceBoxes) r.model,
        for (final r in destinationBoxes) r.model,
        for (final r in extenders) r.model,
      }..removeWhere((m) => m.trim().isEmpty);

  // --- loading and saving ----------------------------------------------------

  /// The rule file that belongs beside [rootFolder] (or the working directory).
  static String pathFor(String rootFolder) => path.join(
        rootFolder.trim().isEmpty ? Directory.current.path : rootFolder.trim(),
        'av_flow_rules.json',
      );

  /// Reads the rule file, falling back to the built-in rules — which is the
  /// normal state of a fresh install, not an error.
  static Future<FlowRules> load({String explicitPath = ''}) async {
    final candidates = <String>[
      if (explicitPath.isNotEmpty)
        explicitPath
      else ...[
        path.join(Directory.current.path, 'av_flow_rules.json'),
        path.join(File(Platform.resolvedExecutable).parent.path,
            'av_flow_rules.json'),
      ],
    ];

    for (final candidate in candidates) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      try {
        final doc = jsonDecode(await file.readAsString());
        if (doc is! Map<String, dynamic>) {
          throw const FormatException(
              'Root of av_flow_rules.json must be an object.');
        }
        final rules = FlowRules.fromJson(doc)..source = candidate;
        AppLogger.logInfo('AV flow rules loaded from $candidate.');
        return rules;
      } catch (e, stack) {
        AppLogger.logError(
            'Failed to read $candidate - using the built-in flow rules.',
            e,
            stack);
        return FlowRules.builtIn()
          ..source = 'Built-in defaults (failed to read $candidate: $e)';
      }
    }
    return FlowRules.builtIn();
  }

  /// Writes the rule book. Returns the path written, or '' on failure.
  Future<String> save(String targetPath) async {
    try {
      final file = File(targetPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(toJson()));
      source = targetPath;
      AppLogger.logInfo('AV flow rules saved to $targetPath.');
      return targetPath;
    } catch (e, stack) {
      AppLogger.logError('Failed to save the AV flow rules', e, stack);
      return '';
    }
  }
}
