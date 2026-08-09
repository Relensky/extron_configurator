import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'av_flow_model.dart';

/// ============================================================================
///  AV DEVICE LIBRARY
/// ============================================================================
///  Answers the one question config.json cannot: "what connectors does this
///  box actually have?" Ports for a node are resolved in this order:
///
///    1. Per-node overrides saved in the `<config>_avflow.json` sidecar (the
///       port editor's output) — handled by the caller, not here.
///    2. An exact model match in an external `av_devices.json`.
///    3. An exact model match in the built-in table below.
///    4. A family-generic fallback derived from the config section prefix,
///       with the port COUNT inferred from the model number where the naming
///       makes that possible (a "CrossPoint 108" is 10 in / 8 out).
///
///  The external file follows the same convention as ui_schema.json — drop
///  `av_devices.json` in the Root Folder and it wins over the built-ins, so
///  a new model can be described without rebuilding the app:
///
///  {
///    "devices": [
///      { "model": "DTP CrossPoint 108 4K IPCP MA 70",
///        "manufacturer": "Extron", "rackUnits": 2,
///        "ports": [
///          {"id":"in_hdmi_1","label":"HDMI IN 1","signal":"hdmi","direction":"input"},
///          {"id":"out_dtp_1","label":"DTP OUT 1","signal":"hdbaset","direction":"output"}
///        ] }
///    ],
///    "familyDefaults": {
///      "CAMERADEVICE_": { "rackUnits": 0, "ports": [ ... ] }
///    }
///  }
///
///  "signal" accepts any [SignalType] name plus the friendly aliases in
///  [signalFromName] (dtp, hdbt, dp, aes, rs232, ...). "direction" is
///  input/output/bidirectional; "side" is optional and defaults to left for
///  inputs and right for outputs.
///
///  THE BUILT-IN TABLE IS A STARTING POINT, NOT A SPEC SHEET. It covers the
///  models present in the shipped config.json with a sensible connector set
///  so the tab is usable out of the box. Correct anything that doesn't match
///  your hardware in av_devices.json (or in the per-node port editor, which
///  can export a ready-made entry).
/// ============================================================================

/// A model's connector set.
class AvDeviceTemplate {
  final String model;
  final String manufacturer;
  final int rackUnits;

  final List<AvPort> ports;

  const AvDeviceTemplate({
    required this.model,
    this.manufacturer = '',
    this.rackUnits = 0,
    required this.ports,
  });

  Map<String, dynamic> toJson() => {
    'model': model,
    if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
    'rackUnits': rackUnits,
    'ports': ports.map((p) => p.toJson()).toList(),
  };

  factory AvDeviceTemplate.fromJson(Map<String, dynamic> json) =>
      AvDeviceTemplate(
        model: json['model']?.toString() ?? '',
        manufacturer: json['manufacturer']?.toString() ?? '',
        rackUnits: (json['rackUnits'] as num?)?.toInt() ?? 0,
        ports: [
          for (final p in (json['ports'] as List? ?? []))
            if (p is Map) AvPort.fromJson(Map<String, dynamic>.from(p)),
        ],
      );
}

class AvDeviceLibrary {
  /// Model (normalized) -> template.
  final Map<String, AvDeviceTemplate> _byModel = {};

  /// Config section prefix ('CAMERADEVICE_') -> template used when no model
  /// matches. Overrides the built-in family fallbacks.
  final Map<String, AvDeviceTemplate> _familyDefaults = {};

  /// Where the library came from, for the App Config / toolbar hint.
  String source = 'Built-in defaults';

  int get modelCount => _byModel.length;

  /// Every known model name, for the "add custom device" model picker.
  List<String> get knownModels {
    final names = _byModel.values.map((t) => t.model).toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  static String _norm(String model) =>
      model.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

  AvDeviceLibrary.builtIn() {
    for (final t in _builtInTemplates) {
      _byModel[_norm(t.model)] = t;
    }
  }

  /// Loads `av_devices.json`, layering it over the built-ins. Mirrors
  /// [UiSchema.load]: an explicit path wins, otherwise the working directory
  /// then the executable's folder are searched.
  static Future<AvDeviceLibrary> load({String explicitPath = ''}) async {
    final library = AvDeviceLibrary.builtIn();

    final List<String> candidates = [];
    if (explicitPath.isNotEmpty) {
      candidates.add(explicitPath);
    } else {
      candidates.add(path.join(Directory.current.path, 'av_devices.json'));
      try {
        candidates.add(
          path.join(
            File(Platform.resolvedExecutable).parent.path,
            'av_devices.json',
          ),
        );
      } catch (_) {}
    }

    for (final candidate in candidates) {
      try {
        final file = File(candidate);
        if (!await file.exists()) continue;

        final doc = jsonDecode(await file.readAsString());
        if (doc is! Map) {
          throw const FormatException(
            'Root of av_devices.json must be an object.',
          );
        }
        int added = 0;
        for (final d in (doc['devices'] as List? ?? [])) {
          if (d is! Map) continue;
          final t = AvDeviceTemplate.fromJson(Map<String, dynamic>.from(d));
          if (t.model.isEmpty || t.ports.isEmpty) continue;
          library._byModel[_norm(t.model)] = t;
          added++;
        }
        final families = doc['familyDefaults'];
        if (families is Map) {
          families.forEach((prefix, value) {
            if (value is! Map) return;
            final t = AvDeviceTemplate.fromJson({
              'model': prefix.toString(),
              ...Map<String, dynamic>.from(value),
            });
            if (t.ports.isNotEmpty) {
              library._familyDefaults[prefix.toString()] = t;
            }
          });
        }
        library.source = candidate;
        AppLogger.logInfo(
          'AV device library loaded from $candidate ($added models, '
          '${library._familyDefaults.length} family defaults).',
        );
        return library;
      } catch (e, stack) {
        AppLogger.logError(
          'Failed to load av_devices.json from $candidate — using built-in '
          'defaults.',
          e,
          stack,
        );
        library.source = 'Built-in defaults (failed to load $candidate: $e)';
        return library;
      }
    }

    if (explicitPath.isNotEmpty) {
      library.source = 'Built-in defaults (file not found: $explicitPath)';
    }
    return library;
  }

  /// Exact model lookup, or null.
  AvDeviceTemplate? templateForModel(String model) {
    if (model.trim().isEmpty) return null;
    return _byModel[_norm(model)];
  }

  /// The connector set for a device: its model's template when one exists,
  /// otherwise a family-generic set sized from the model number when that is
  /// readable. [configKey] is the section key ('SWITCHERDEVICE_1') and drives
  /// the family fallback.
  AvDeviceTemplate resolve({required String configKey, required String model}) {
    final exact = templateForModel(model);
    if (exact != null) return exact;

    for (final entry in _familyDefaults.entries) {
      if (configKey.startsWith(entry.key)) {
        return AvDeviceTemplate(
          model: model.isEmpty ? entry.key : model,
          rackUnits: entry.value.rackUnits,
          ports: entry.value.ports,
        );
      }
    }
    return _familyFallback(configKey, model);
  }

  // -------------------------------------------------------------------------
  //  FAMILY FALLBACKS
  // -------------------------------------------------------------------------

  /// Generic connectors by device family. Sizes matrix switchers from the
  /// model number when it reads as one ("CrossPoint 108" -> 10x8, "SW4" -> 4
  /// in / 1 out) and otherwise picks a conservative default.
  static AvDeviceTemplate _familyFallback(String configKey, String model) {
    if (configKey.startsWith('SWITCHERDEVICE_')) {
      final (ins, outs) = _switcherSize(model);
      return AvDeviceTemplate(
        model: model,
        rackUnits: ins > 4 ? 2 : 1,
        ports: [
          for (int i = 1; i <= ins; i++)
            AvPort(
              id: 'in_$i',
              label: 'IN $i',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          for (int i = 1; i <= outs; i++)
            AvPort(
              id: 'out_$i',
              label: 'OUT $i',
              signal: SignalType.hdmi,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
          _audioIn('in_aud_1', 'AUDIO IN'),
          _audioOut('out_aud_1', 'AUDIO OUT'),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('CAMERADEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
          AvPort(
            id: 'out_usb_1',
            label: 'USB',
            signal: SignalType.usbData,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('PROJECTORDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
          _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
          _videoIn('in_hdbt_1', 'HDBaseT', SignalType.hdbaset),
          _audioIn('in_aud_1', 'AUDIO IN'),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('DSPDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        rackUnits: 1,
        ports: [
          for (int i = 1; i <= 6; i++) _micIn('in_mic_$i', 'MIC/LINE $i'),
          for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'OUT $i'),
          _dante(),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('USBDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          for (int i = 1; i <= 2; i++)
            AvPort(
              id: 'in_usb_$i',
              label: 'HOST $i',
              signal: SignalType.usbData,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          for (int i = 1; i <= 2; i++)
            AvPort(
              id: 'out_usb_$i',
              label: 'DEVICE $i',
              signal: SignalType.usbData,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
        ],
      );
    }
    if (configKey.startsWith('MEDIAPORTDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
          _audioIn('in_aud_1', 'AUDIO IN'),
          AvPort(
            id: 'out_usb_1',
            label: 'USB OUT',
            signal: SignalType.usbData,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('WIRELESSDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        rackUnits: 1,
        ports: [
          _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
          AvPort(
            id: 'out_usb_1',
            label: 'USB',
            signal: SignalType.usbData,
            direction: PortDirection.bidirectional,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('RECORDERDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
          _audioIn('in_aud_1', 'AUDIO IN'),
          _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
          AvPort(
            id: 'out_usb_1',
            label: 'USB OUT',
            signal: SignalType.usbData,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('POWERDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        rackUnits: 1,
        ports: [
          for (int i = 1; i <= 8; i++)
            AvPort(
              id: 'out_pwr_$i',
              label: 'OUTLET $i',
              signal: SignalType.power,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('SCREENDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          AvPort(
            id: 'in_ctrl_1',
            label: 'CONTROL',
            signal: SignalType.serial,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
        ],
      );
    }
    // Unknown family: one in, one out, so it can at least be cabled.
    return AvDeviceTemplate(
      model: model,
      ports: [
        _videoIn('in_1', 'IN 1', SignalType.hdmi),
        _videoOut('out_1', 'OUT 1', SignalType.hdmi),
      ],
    );
  }

  /// Reads an input/output count out of a switcher model name.
  ///
  /// Extron matrix naming packs the size into one number — "CrossPoint 108"
  /// is 10x8, "CrossPoint 84" is 8x4 — so a 3-digit group splits 2+1 and a
  /// 2-digit group splits 1+1. "SW4", "IN1804" and similar name only their
  /// input count, which lands on the single-output default.
  static (int, int) _switcherSize(String model) {
    final upper = model.toUpperCase();

    final crossPoint = RegExp(r'CROSS\s*POINT\s+(\d{2,3})').firstMatch(upper);
    if (crossPoint != null) {
      final digits = crossPoint.group(1)!;
      if (digits.length == 3) {
        return (int.parse(digits.substring(0, 2)), int.parse(digits[2]));
      }
      return (int.parse(digits[0]), int.parse(digits[1]));
    }

    // "SW4 HD 4K PLUS", "SW6" — the digit right after SW is the input count.
    final sw = RegExp(r'\bSW\s*(\d{1,2})\b').firstMatch(upper);
    if (sw != null) return (int.parse(sw.group(1)!), 1);

    // "IN1804" — an input-series scaler; the trailing digit is the inputs.
    final inSeries = RegExp(r'\bIN\s*\d{2}(\d)\d\b').firstMatch(upper);
    if (inSeries != null) {
      final n = int.parse(inSeries.group(1)!);
      return (n == 0 ? 4 : n, 2);
    }

    return (4, 1);
  }

  // --- port shorthands, so the built-in table stays readable ---------------

  static AvPort _videoIn(String id, String label, SignalType s) => AvPort(
    id: id,
    label: label,
    signal: s,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  static AvPort _videoOut(String id, String label, SignalType s) => AvPort(
    id: id,
    label: label,
    signal: s,
    direction: PortDirection.output,
    side: PortSide.right,
  );

  static AvPort _audioIn(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.analogAudio,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  static AvPort _audioOut(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.analogAudio,
    direction: PortDirection.output,
    side: PortSide.right,
  );

  static AvPort _micIn(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.micLine,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  static AvPort _usbOut(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.usbData,
    direction: PortDirection.output,
    side: PortSide.right,
  );

  static AvPort _dante() => const AvPort(
    id: 'dante_1',
    label: 'DANTE',
    signal: SignalType.dante,
    direction: PortDirection.bidirectional,
    side: PortSide.bottom,
  );

  static AvPort _lan() => const AvPort(
    id: 'lan_1',
    label: 'LAN',
    signal: SignalType.network,
    direction: PortDirection.bidirectional,
    side: PortSide.bottom,
  );

  // -------------------------------------------------------------------------
  //  BUILT-IN MODELS
  // -------------------------------------------------------------------------
  //  Covers the models in the shipped config.json. Treat these as a head
  //  start, not gospel — override in av_devices.json where your hardware
  //  differs.

  static final List<AvDeviceTemplate> _builtInTemplates = [
    // --- Extron matrix switchers ---
    AvDeviceTemplate(
      model: 'DTP CrossPoint 108 4K IPCP MA 70',
      manufacturer: 'Extron',
      rackUnits: 2,
      ports: [
        for (int i = 1; i <= 6; i++)
          _videoIn('in_hdmi_$i', 'HDMI IN $i', SignalType.hdmi),
        for (int i = 1; i <= 4; i++)
          _videoIn('in_dtp_$i', 'DTP IN $i', SignalType.hdbaset),
        for (int i = 1; i <= 2; i++)
          _videoOut('out_hdmi_$i', 'HDMI OUT $i', SignalType.hdmi),
        for (int i = 1; i <= 4; i++)
          _videoOut('out_dtp_$i', 'DTP OUT $i', SignalType.hdbaset),
        for (int i = 1; i <= 4; i++) _micIn('in_mic_$i', 'MIC $i'),
        for (int i = 1; i <= 2; i++) _audioIn('in_aud_$i', 'LINE IN $i'),
        for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'AUDIO OUT $i'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'DTP CrossPoint 84 4K IPCP MA 70',
      manufacturer: 'Extron',
      rackUnits: 2,
      ports: [
        for (int i = 1; i <= 5; i++)
          _videoIn('in_hdmi_$i', 'HDMI IN $i', SignalType.hdmi),
        for (int i = 1; i <= 3; i++)
          _videoIn('in_dtp_$i', 'DTP IN $i', SignalType.hdbaset),
        for (int i = 1; i <= 2; i++)
          _videoOut('out_hdmi_$i', 'HDMI OUT $i', SignalType.hdmi),
        for (int i = 1; i <= 2; i++)
          _videoOut('out_dtp_$i', 'DTP OUT $i', SignalType.hdbaset),
        for (int i = 1; i <= 4; i++) _micIn('in_mic_$i', 'MIC $i'),
        for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'AUDIO OUT $i'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'IN1804',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI IN 2', SignalType.hdmi),
        _videoIn('in_hdmi_3', 'HDMI IN 3', SignalType.hdmi),
        _videoIn('in_vga_1', 'VGA IN', SignalType.vga),
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _videoOut('out_dtp_1', 'DTP OUT', SignalType.hdbaset),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _audioOut('out_aud_1', 'AUDIO OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'SW4 HD 4K PLUS',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 4; i++)
          _videoIn('in_hdmi_$i', 'HDMI IN $i', SignalType.hdmi),
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
      ],
    ),

    // --- DSPs ---
    AvDeviceTemplate(
      model: 'DMP 64 Plus C AT',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 6; i++) _micIn('in_mic_$i', 'MIC/LINE $i'),
        for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'OUT $i'),
        _dante(),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'DMP 128 Plus C AT',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 12; i++) _micIn('in_mic_$i', 'MIC/LINE $i'),
        for (int i = 1; i <= 8; i++) _audioOut('out_aud_$i', 'OUT $i'),
        _dante(),
        _lan(),
      ],
    ),

    // --- USB / streaming interfaces ---
    AvDeviceTemplate(
      model: 'MediaPort 200',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _videoOut('out_hdmi_1', 'HDMI LOOP', SignalType.hdmi),
        _usbOut('out_usb_1', 'USB OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'ShareLink Pro 2000',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _audioOut('out_aud_1', 'AUDIO OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'AV Bridge',
      manufacturer: 'Vaddio',
      rackUnits: 1,
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
        _micIn('in_mic_1', 'MIC IN 1'),
        _micIn('in_mic_2', 'MIC IN 2'),
        _audioOut('out_aud_1', 'AUDIO OUT'),
        _usbOut('out_usb_1', 'USB OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Toggle',
      manufacturer: 'iGen',
      ports: [
        AvPort(
          id: 'in_usb_1',
          label: 'HOST 1',
          signal: SignalType.usbData,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
        AvPort(
          id: 'in_usb_2',
          label: 'HOST 2',
          signal: SignalType.usbData,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
        _usbOut('out_usb_1', 'DEVICE OUT'),
      ],
    ),

    // --- Cameras ---
    AvDeviceTemplate(
      model: 'TR311HW',
      manufacturer: 'AVer',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _usbOut('out_usb_1', 'USB'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Cam570',
      manufacturer: 'AVer',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _usbOut('out_usb_1', 'USB'),
        _lan(),
      ],
    ),

    // --- Displays / projectors ---
    AvDeviceTemplate(
      model: 'VPL-PHZ60',
      manufacturer: 'Sony',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
        _videoIn('in_hdbt_1', 'HDBaseT', SignalType.hdbaset),
        _videoIn('in_vga_1', 'VGA', SignalType.vga),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'PowerLite L610U',
      manufacturer: 'Epson',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
        _videoIn('in_hdbt_1', 'HDBaseT', SignalType.hdbaset),
        _videoIn('in_vga_1', 'COMPUTER', SignalType.vga),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'LC-90LE657U',
      manufacturer: 'Sharp',
      ports: [
        for (int i = 1; i <= 4; i++)
          _videoIn('in_hdmi_$i', 'HDMI $i', SignalType.hdmi),
        _audioOut('out_aud_1', 'AUDIO OUT'),
      ],
    ),

    // --- Power / screen control ---
    AvDeviceTemplate(
      model: 'AP7900B',
      manufacturer: 'APC',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 8; i++)
          AvPort(
            id: 'out_pwr_$i',
            label: 'OUTLET $i',
            signal: SignalType.power,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'SCB-100',
      manufacturer: 'Extron',
      ports: [
        AvPort(
          id: 'in_ctrl_1',
          label: 'CONTROL',
          signal: SignalType.serial,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
      ],
    ),

    // --- Common room gear the control config never sees, offered when
    //     adding a device by hand. ---
    AvDeviceTemplate(
      model: 'Display (generic)',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
        _audioOut('out_aud_1', 'AUDIO OUT'),
      ],
    ),
    AvDeviceTemplate(
      model: 'Laptop / BYOD input',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI', SignalType.hdmi),
        _videoOut('out_usbc_1', 'USB-C', SignalType.usbC),
      ],
    ),
    AvDeviceTemplate(
      model: 'Room PC',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI', SignalType.hdmi),
        _videoOut('out_dp_1', 'DisplayPort', SignalType.displayPort),
        AvPort(
          id: 'in_usb_1',
          label: 'USB',
          signal: SignalType.usbData,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Wall plate / TX',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
        _videoOut('out_dtp_1', 'DTP OUT', SignalType.hdbaset),
      ],
    ),
    AvDeviceTemplate(
      model: 'Receiver / RX',
      ports: [
        _videoIn('in_dtp_1', 'DTP IN', SignalType.hdbaset),
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
      ],
    ),
    AvDeviceTemplate(
      model: 'Amplifier',
      rackUnits: 1,
      ports: [
        _audioIn('in_aud_1', 'LINE IN L'),
        _audioIn('in_aud_2', 'LINE IN R'),
        AvPort(
          id: 'out_spk_1',
          label: 'SPKR OUT L',
          signal: SignalType.speaker,
          direction: PortDirection.output,
          side: PortSide.right,
        ),
        AvPort(
          id: 'out_spk_2',
          label: 'SPKR OUT R',
          signal: SignalType.speaker,
          direction: PortDirection.output,
          side: PortSide.right,
        ),
      ],
    ),
    AvDeviceTemplate(
      model: 'Speaker',
      ports: [
        AvPort(
          id: 'in_spk_1',
          label: 'SPKR IN',
          signal: SignalType.speaker,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
      ],
    ),
    AvDeviceTemplate(
      model: 'Ceiling microphone',
      ports: [
        _audioOut('out_mic_1', 'MIC OUT').copyWith(signal: SignalType.micLine),
        _dante(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Network switch',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 8; i++)
          AvPort(
            id: 'lan_$i',
            label: 'PORT $i',
            signal: SignalType.network,
            direction: PortDirection.bidirectional,
            side: i <= 4 ? PortSide.left : PortSide.right,
          ),
      ],
    ),
    AvDeviceTemplate(
      model: 'Patch panel',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 12; i++)
          AvPort(
            id: 'p_$i',
            label: 'P$i',
            signal: SignalType.network,
            direction: PortDirection.bidirectional,
            side: i <= 6 ? PortSide.left : PortSide.right,
          ),
      ],
    ),
  ];
}
