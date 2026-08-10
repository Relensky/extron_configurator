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
///    1. Per-node overrides saved in the `<config>_av_flow.json` sidecar (the
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
///        "manufacturer": "Extron", "partNumber": "60-1439-13",
///        "category": "Switcher", "rackUnits": 2,
///        "powerWatts": 90, "price": 8500,
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
///  `powerWatts` and `price` are what the power estimate and the room cost
///  estimate are built from; both default to 0, meaning "not recorded", and
///  the reports say how many devices are still missing them rather than
///  totalling a blank as free and cold. The **Device Editor** tab writes this
///  file, so none of it has to be typed by hand — and can merge another
///  engineer's copy of it into yours, one difference at a time.
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

/// A model's connector set, and everything else about the box that the room
/// config never records: how tall it is, what it draws, and what it costs.
///
/// [powerWatts] and [price] are estimates a room is planned from, not
/// measurements — 0 means "nobody has filled this in", which is why the
/// reports count unpriced and unmetered devices instead of quietly totalling
/// them as free and cold.
class AvDeviceTemplate {
  final String model;
  final String manufacturer;

  /// Manufacturer part / SKU, so a price list line can be matched to a quote.
  final String partNumber;

  /// Free-text grouping for the catalog list and the cost estimate
  /// ('Switcher', 'Camera', 'Cable & connectivity', ...).
  final String category;

  final int rackUnits;

  /// Typical draw in watts; 0 = not recorded.
  final double powerWatts;

  /// Unit price in the catalog's currency; 0 = not priced.
  final double price;

  final String notes;

  final List<AvPort> ports;

  /// True when this entry came from av_devices.json or was edited in the
  /// Device Editor — i.e. it is the user's, and gets written back on save.
  /// Built-in entries stay false so a later app build can still improve them.
  final bool custom;

  const AvDeviceTemplate({
    required this.model,
    this.manufacturer = '',
    this.partNumber = '',
    this.category = '',
    this.rackUnits = 0,
    this.powerWatts = 0,
    this.price = 0,
    this.notes = '',
    required this.ports,
    this.custom = false,
  });

  int get inputCount =>
      ports.where((p) => p.direction != PortDirection.output).length;
  int get outputCount =>
      ports.where((p) => p.direction != PortDirection.input).length;

  AvDeviceTemplate copyWith({
    String? model,
    String? manufacturer,
    String? partNumber,
    String? category,
    int? rackUnits,
    double? powerWatts,
    double? price,
    String? notes,
    List<AvPort>? ports,
    bool? custom,
  }) => AvDeviceTemplate(
    model: model ?? this.model,
    manufacturer: manufacturer ?? this.manufacturer,
    partNumber: partNumber ?? this.partNumber,
    category: category ?? this.category,
    rackUnits: rackUnits ?? this.rackUnits,
    powerWatts: powerWatts ?? this.powerWatts,
    price: price ?? this.price,
    notes: notes ?? this.notes,
    ports: ports ?? this.ports,
    custom: custom ?? this.custom,
  );

  Map<String, dynamic> toJson() => {
    'model': model,
    if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
    if (partNumber.isNotEmpty) 'partNumber': partNumber,
    if (category.isNotEmpty) 'category': category,
    'rackUnits': rackUnits,
    if (powerWatts > 0) 'powerWatts': powerWatts,
    if (price > 0) 'price': price,
    if (notes.isNotEmpty) 'notes': notes,
    'ports': ports.map((p) => p.toJson()).toList(),
  };

  factory AvDeviceTemplate.fromJson(
    Map<String, dynamic> json, {
    bool custom = false,
  }) => AvDeviceTemplate(
    model: json['model']?.toString() ?? '',
    manufacturer: json['manufacturer']?.toString() ?? '',
    partNumber: json['partNumber']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    rackUnits: (json['rackUnits'] as num?)?.toInt() ?? 0,
    // 'watts' and 'cost' are read as aliases: they are what people write by
    // hand in a price list before they see the documented spelling.
    powerWatts:
        (json['powerWatts'] as num?)?.toDouble() ??
        (json['watts'] as num?)?.toDouble() ??
        0,
    price:
        (json['price'] as num?)?.toDouble() ??
        (json['cost'] as num?)?.toDouble() ??
        0,
    notes: json['notes']?.toString() ?? '',
    ports: [
      for (final p in (json['ports'] as List? ?? []))
        if (p is Map) AvPort.fromJson(Map<String, dynamic>.from(p)),
    ],
    custom: custom,
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

  /// The av_devices.json this library was READ from, or '' when nothing but
  /// the built-ins is loaded. [save] writes here when it is set.
  String filePath = '';

  int get modelCount => _byModel.length;

  /// Entries that belong to the user — loaded from av_devices.json or edited
  /// in the Device Editor. Only these are written back, so an untouched
  /// built-in can still be improved by a later app build.
  int get customCount => _byModel.values.where((t) => t.custom).length;

  /// Every entry, ordered the way the catalog list reads: manufacturer, then
  /// model.
  List<AvDeviceTemplate> get all {
    final list = _byModel.values.toList();
    list.sort((a, b) {
      final byMaker = a.manufacturer.toLowerCase().compareTo(
        b.manufacturer.toLowerCase(),
      );
      return byMaker != 0
          ? byMaker
          : a.model.toLowerCase().compareTo(b.model.toLowerCase());
    });
    return list;
  }

  /// The family fallbacks read from the file, kept so a save round-trips
  /// them instead of quietly dropping the block.
  Map<String, AvDeviceTemplate> get familyDefaults =>
      Map.unmodifiable(_familyDefaults);

  /// Every known model name, for the "add custom device" model picker.
  List<String> get knownModels {
    final names = _byModel.values.map((t) => t.model).toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  /// Categories in use, for the catalog filter and the "new device" form.
  List<String> get categories {
    final set = <String>{
      for (final t in _byModel.values)
        if (t.category.trim().isNotEmpty) t.category.trim(),
    };
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  static String _norm(String model) =>
      model.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

  /// The key an entry is stored under — exposed so callers comparing two
  /// libraries agree with this one on what "the same model" means.
  static String normalizeModel(String model) => _norm(model);

  AvDeviceLibrary.builtIn() {
    for (final t in _builtInTemplates) {
      _byModel[_norm(t.model)] = t;
    }
  }

  /// An empty library — the starting point when reading somebody else's file
  /// for a merge, where built-ins would masquerade as their entries.
  AvDeviceLibrary.empty();

  // -------------------------------------------------------------------------
  //  EDITING
  // -------------------------------------------------------------------------

  /// Adds or replaces an entry, marking it as the user's so it is saved.
  /// [previousModel] renames: the old key is dropped rather than left behind
  /// as a duplicate under its former name.
  void upsert(AvDeviceTemplate template, {String previousModel = ''}) {
    if (template.model.trim().isEmpty) return;
    if (previousModel.isNotEmpty &&
        _norm(previousModel) != _norm(template.model)) {
      _byModel.remove(_norm(previousModel));
    }
    _byModel[_norm(template.model)] = template.copyWith(custom: true);
  }

  /// Forgets an entry. A built-in comes back on the next launch — the file is
  /// a layer over the built-ins, not a replacement for them.
  void remove(String model) => _byModel.remove(_norm(model));

  /// Replaces the family fallbacks (the Device Editor round-trips these).
  void setFamilyDefault(String prefix, AvDeviceTemplate? template) {
    if (template == null) {
      _familyDefaults.remove(prefix);
    } else {
      _familyDefaults[prefix] = template;
    }
  }

  /// Writes the user's entries to [toPath] (defaults to [filePath]). Returns
  /// the file written, or '' when there was nowhere to write / the write
  /// failed.
  ///
  /// [rebind] false writes a COPY without adopting it: handing your catalog
  /// to a colleague shouldn't quietly repoint your own saves at their folder.
  Future<String> save({String toPath = '', bool rebind = true}) async {
    final target = toPath.isNotEmpty ? toPath : filePath;
    if (target.isEmpty) return '';
    try {
      final custom = all.where((t) => t.custom).toList();
      const encoder = JsonEncoder.withIndent('  ');
      await File(target).parent.create(recursive: true);
      await File(target).writeAsString(
        encoder.convert({
          '__readme':
              'AV device catalog for the Room Config Builder: connectors, '
              'rack height, estimated power draw and unit price per model. '
              'Edited on the Device Editor tab; entries here override the '
              "app's built-in models.",
          'devices': [for (final t in custom) t.toJson()],
          if (_familyDefaults.isNotEmpty)
            'familyDefaults': {
              for (final e in _familyDefaults.entries)
                e.key: e.value.toJson()..remove('model'),
            },
        }),
      );
      if (rebind) {
        filePath = target;
        source = target;
      }
      AppLogger.logInfo(
        'AV device catalog saved to $target (${custom.length} entries).',
      );
      return target;
    } catch (e, stack) {
      AppLogger.logError(
        'Failed to save the AV device catalog to $target',
        e,
        stack,
      );
      return '';
    }
  }

  /// Reads a catalog file on its own, with no built-ins underneath — what a
  /// merge needs, since a built-in in the other engineer's copy would
  /// otherwise read as something they had filled in.
  static Future<AvDeviceLibrary> readFile(String filePath) async {
    final library = AvDeviceLibrary.empty();
    final doc = jsonDecode(await File(filePath).readAsString());
    if (doc is! Map) {
      throw const FormatException('Root of the catalog file must be an object.');
    }
    for (final d in (doc['devices'] as List? ?? [])) {
      if (d is! Map) continue;
      final t = AvDeviceTemplate.fromJson(
        Map<String, dynamic>.from(d),
        custom: true,
      );
      if (t.model.isEmpty) continue;
      library._byModel[_norm(t.model)] = t;
    }
    library.filePath = filePath;
    library.source = filePath;
    return library;
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
          final t = AvDeviceTemplate.fromJson(
            Map<String, dynamic>.from(d),
            custom: true,
          );
          // A priced entry with no connectors is still worth keeping: a price
          // list is filled in long before anybody draws that model's ports.
          if (t.model.isEmpty) continue;
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
        library.filePath = candidate;
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
        return entry.value.copyWith(model: model.isEmpty ? entry.key : model);
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
