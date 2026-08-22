import 'app_state.dart' show activeDeviceKeysIn;
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'cost_estimate.dart' show groupDevices;

/// ============================================================================
///  DEVICES NOTHING WILL DRIVE
/// ============================================================================
///  The catalog covers everything you can buy. The module library covers what
///  the control system can actually drive. A device in the first and not the
///  second is not necessarily wrong — a passive speaker never had a driver —
///  but it IS the list somebody needs before commissioning, because every entry
///  on it is a box the processor cannot touch.
///
///  This is that rule, on its own, as DATA rather than as a table.
///
///  It used to live inside the AV report's `driverGapSections`, reading its
///  answers off a live [AppStateProvider]. That was fine while the only thing
///  asking was the room in front of you. It stopped being fine the moment a
///  project wanted the same list for nine rooms it reads off disk and never
///  opens: the choice was to duplicate the rule or to lift it out. Duplicating
///  it would have given the building a second opinion about which devices are
///  undriven, and two disagreeing lists of "missing" devices is worse than
///  none — the whole point of the table is that somebody trusts it.
///
///  So the rule takes plain arguments — a config map, a diagram, the schema's
///  device-count map, the catalog, and a way to ask which module claims a model
///  — and both callers hand it what they have. `driverGapSections` renders
///  these into the sheet it always did; the project rolls them up per room.
/// ============================================================================

/// Why a device has no driver. The four are genuinely different problems with
/// different fixes, and a single "missing" flag made somebody work out which
/// one they were looking at every time.
enum ControlGapKind {
  /// On the diagram with no model on it, so no module can even be looked up.
  noModel,

  /// The config block has a module field, it is empty, and a module DOES claim
  /// the model. The sharpest case: one dropdown away from being fine.
  moduleUnset,

  /// Nothing in the module library claims this model. Either the driver has
  /// not been written yet or the product genuinely has no control interface —
  /// and if it is the latter, the catalog entry should say `neverControlled`
  /// so the room stops being asked about it.
  noModuleClaims,

  /// In the config with no module, and not on the signal flow either. Worth
  /// its own kind because a list built only from the drawing misses exactly
  /// the devices nobody has got round to drawing.
  notDrawn,
}

/// One undriven device, as the report and the project both need it.
class ControlGap {
  /// What the room calls it.
  final String device;

  /// '' when nobody has chosen one.
  final String model;

  /// How many of it — a group of three identical undriven displays is one
  /// entry of three, matching the pack list.
  final int qty;

  /// True when this came from a config device block, false when it is a box
  /// somebody added to the drawing by hand. The fix is different: one is a
  /// field to fill in, the other is a device to add to the config.
  final bool fromConfig;

  final ControlGapKind kind;

  /// The sentence the table prints, which says what to do about it.
  final String note;

  const ControlGap({
    required this.device,
    required this.model,
    required this.qty,
    required this.fromConfig,
    required this.kind,
    required this.note,
  });

  String get sourceLabel => fromConfig ? 'Room config' : 'Added by hand';
}

/// Every device in one room that no module will drive.
///
/// [moduleForModel] returns the python module claiming a model, or '' — the
/// app's own registry lookup, passed in because the registry is application
/// data and this rule is about a room.
///
/// [deviceCountMap] is the UI schema's device-count map: which `dev_*` key
/// names how many of which family the room has. Without it there is no way to
/// know which config sections are live, and a room with `dev_displays: 2`
/// would be read as having every DISPLAYDEVICE_n block ever left in the file.
List<ControlGap> controlGapsForRoom({
  required Map<String, dynamic> config,
  required AvFlowModel model,
  required Map<String, String> deviceCountMap,
  required AvDeviceLibrary library,
  required String Function(String model) moduleForModel,
}) {
  final gaps = <ControlGap>[];

  // A config block whose `module` field is blank is the sharper version of the
  // same problem: the device HAS a place for a driver and nobody has chosen
  // one, so it will not commission. Collected first so the config's own answer
  // wins over the catalog lookup for the same device.
  //
  // The distinction between "in this map with an empty value" and "not in this
  // map at all" carries the whole of [ControlGap.fromConfig] below, which is
  // why it is a map of strings rather than a set of keys.
  final assigned = <String, String>{};
  for (final key in activeDeviceKeysIn(config, deviceCountMap)) {
    final dev = config[key];
    if (dev is! Map) continue;
    assigned[key] = dev['module']?.toString().trim() ?? '';
  }

  /// True when nothing was ever going to talk to this box, from either
  /// direction that can say so: THIS box was excluded by hand on the diagram,
  /// or the PRODUCT has no control interface wherever it turns up. Listing
  /// these is what turns the table into one people skim past.
  bool uncontrolled(AvNode node) =>
      node.excludeFromControl ||
      (node.model.trim().isNotEmpty &&
          (library.templateForModel(node.model)?.neverControlled ?? false));

  for (final group in groupDevices(model)) {
    final node = group.first;
    if (node.isJackField) continue;
    if (uncontrolled(node)) continue;

    // Devices seeded from the config carry the config's verdict. A generic box
    // added by hand — a projector, a power controller, a screen — has no
    // config block, so the catalog lookup is the only answer available and it
    // is reported the same way rather than being left off.
    final configModule = assigned[node.id];
    if (configModule != null && configModule.isNotEmpty) continue;

    if (node.model.trim().isEmpty) {
      gaps.add(ControlGap(
        device: group.label,
        model: '',
        qty: group.qty,
        fromConfig: configModule != null,
        kind: ControlGapKind.noModel,
        note: 'No model recorded, so no module can be matched',
      ));
      continue;
    }

    final claimed = moduleForModel(node.model);
    if (claimed.isNotEmpty && configModule == null) continue;
    if (claimed.isNotEmpty && configModule != null && configModule.isEmpty) {
      gaps.add(ControlGap(
        device: group.label,
        model: node.model,
        qty: group.qty,
        fromConfig: true,
        kind: ControlGapKind.moduleUnset,
        note: 'No module set on the device — $claimed matches this model',
      ));
      continue;
    }
    gaps.add(ControlGap(
      device: group.label,
      model: node.model,
      qty: group.qty,
      fromConfig: configModule != null,
      kind: ControlGapKind.noModuleClaims,
      note: 'No Python module claims this model',
    ));
  }

  // Config devices with no module that never made it onto the diagram. They
  // are still in the room and still undriven, and a list that only covers what
  // somebody remembered to draw is a list that misses exactly the devices
  // nobody has got to yet.
  final drawn = {for (final n in model.nodes) n.id};
  for (final key in activeDeviceKeysIn(config, deviceCountMap)) {
    if (drawn.contains(key)) continue;
    final dev = config[key];
    if (dev is! Map) continue;
    if ((dev['module']?.toString().trim() ?? '').isNotEmpty) continue;
    gaps.add(ControlGap(
      device: dev['name']?.toString() ?? key,
      model: dev['model']?.toString() ?? '',
      qty: 1,
      fromConfig: true,
      kind: ControlGapKind.notDrawn,
      note: 'No module set on the device; not on the signal flow either',
    ));
  }

  return gaps;
}
