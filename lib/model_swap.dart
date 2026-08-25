import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_routing.dart' show withOutletNames;

/// ============================================================================
///  PUTTING A DIFFERENT PRODUCT UNDER A BOX — THE ARITHMETIC
/// ============================================================================
///  What a model swap DOES, with no provider, no undo stack and no widget
///  anywhere near it: given a box, the runs on it, and the catalog entry it is
///  becoming, work out what the box turns into and what happens to each cable.
///
///  This was inside `applyModelSwap`, which is a provider method, and that was
///  fine while a swap was always one box in the room on screen. A project
///  swapping the same projector in nine rooms it reads off disk cannot call a
///  provider method — so either the rule gets copied, or it gets lifted out.
///
///  Copying it was not survivable. The swap is not a one-liner: it renames
///  only the model-shaped part of the label, carries the power inlet and the
///  outlet names across, re-derives the power source only when the product
///  decides it, remaps every run onto its counterpart connector and drops the
///  ones with nowhere to go, and files the unit coming out in the position's
///  age record so the room can still say how old its equipment is. Two copies
///  of that drift, and the drift shows up as a room whose cables quietly went
///  missing.
///
///  So the arithmetic is here and both callers use it: `applyModelSwap` writes
///  the result through the provider so the room on screen gets one undo entry,
///  and the project writes it into the room's files.
/// ============================================================================

/// What a swap turns one box, and the runs on it, into.
class ModelSwapPlan {
  /// The box afterwards — same id, same position, same rack slot.
  final AvNode node;

  /// Cable id -> the cable with its end moved onto the new box's counterpart
  /// connector. Only runs that actually move are in here.
  final Map<String, AvCable> moved;

  /// Ids of runs whose connector has no counterpart on the new product.
  ///
  /// Removed rather than left behind: a cable pointing at a connector that is
  /// gone stops being drawn on the next build anyway, and a quiet
  /// disappearance is the thing worth avoiding. Counted so the caller can say
  /// what happened.
  final List<String> dropped;

  const ModelSwapPlan({
    required this.node,
    required this.moved,
    required this.dropped,
  });

  int get carried => moved.length;

  /// True when the box is a different height afterwards, so whoever is holding
  /// the rack elevation needs to look at it. The slot is kept either way — the
  /// U it starts at is a fact about this room, not about the product — but a
  /// 2U box in a 1U gap is worth saying out loud.
  bool rackHeightChanged(AvNode before) => before.rackUnits != node.rackUnits;
}

/// Works out the swap. Nothing is written.
///
/// [config] is only read, and only for the power outlet names: a mains block's
/// connector labels carry what this room plugs into them, and those are a fact
/// about the room that has to survive the box under them changing.
ModelSwapPlan planModelSwap({
  required AvNode node,
  required Iterable<AvCable> cables,
  required AvDeviceTemplate template,
  required Map<String, dynamic> config,

  /// The day the box was physically changed, for the age record. Defaults to
  /// today, which is right whenever the swap is being entered as it happens;
  /// a swap being recorded after the fact passes the day it actually went in.
  DateTime? swappedOn,

  /// Why the unit came out — 'failed', 'end of life', 'room refresh'. Kept
  /// with the outgoing unit; see [EquipmentSwap].
  String swapReason = '',
}) {
  final swapped = withOutletNames(
    withPowerInlet(template.ports, template.powerInput),
    node.id,
    config,
  );
  final remap = remapPorts(node.ports, swapped);

  // Only when the model DECIDES it — a mains box is plugged in wherever this
  // room plugs it in, and that is not the catalog's business.
  final implied = powerSourceForInput(template.powerInput);

  // THE POSITION'S AGE RECORD, BEFORE THE MODEL MOVES.
  //
  // A swap is the only moment the app can know that the unit in a position has
  // been replaced, so it is the only moment the previous one can be written
  // down. Doing it here rather than in each of the five callers means the
  // Signal Flow tab's swap, the Devices tab's, the rack's, the cost estimate's
  // and the project's swap-across-nine-rooms all keep the same record.
  //
  // A "swap" onto the model already under the box is a correction, not a
  // replacement — nothing was unplugged — so it leaves the dates alone.
  final sameModel = node.model.trim().toLowerCase() ==
      template.model.trim().toLowerCase();
  final aged = sameModel
      ? node
      : node.withSwapRecorded(
          on: swappedOn ?? DateTime.now(),
          reason: swapReason,
        );

  final after = aged.copyWith(
    model: template.model,
    // A box named after the product it is — "Projector 1 - PowerLite L630U" —
    // is named after the wrong product the moment the product changes, and
    // that name is what the schematic, the pack list and the person on site
    // all read. Only the model part moves; "Projector 1 - " is what this room
    // calls the position, and the position has not changed.
    label: renamedForModel(node.label, node.model, template.model),
    ports: swapped,
    rackUnits: template.rackUnits,
    powerWatts: template.powerWatts,
    btuPerHour: template.btuPerHour,
    powerSource: implied == PowerSource.unspecified
        ? node.powerSource
        : implied,
  );

  final moved = <String, AvCable>{};
  final dropped = <String>[];
  final orphanedPorts = node.ports
      .map((p) => p.id)
      .where((id) => !remap.containsKey(id))
      .toSet();

  for (final c in cables) {
    final touchesFrom = c.fromNodeId == node.id;
    final touchesTo = c.toNodeId == node.id;
    if (!touchesFrom && !touchesTo) continue;

    // A run on a connector the new product does not have. Checked before the
    // remap so a cable with one end orphaned and one end moving is dropped
    // rather than half-moved — half a run is not a run.
    if ((touchesFrom && orphanedPorts.contains(c.fromPortId)) ||
        (touchesTo && orphanedPorts.contains(c.toPortId))) {
      dropped.add(c.id);
      continue;
    }

    final fromMoved = touchesFrom ? remap[c.fromPortId] : null;
    final toMoved = touchesTo ? remap[c.toPortId] : null;
    if (fromMoved == null && toMoved == null) continue;
    moved[c.id] = c.copyWith(fromPortId: fromMoved, toPortId: toMoved);
  }

  return ModelSwapPlan(node: after, moved: moved, dropped: dropped);
}

/// [name] with a mention of [oldModel] rewritten to [newModel], or [name]
/// unchanged when it does not mention it.
///
/// People name a device after what it is: "Projector 1 - PowerLite L630U",
/// "Rack DSP — DMP 128 Plus". Swap the product and that name is a lie that
/// nothing else in the room contradicts — it goes on the schematic, on the
/// pack list, on the touch panel, and it is the name somebody reads out on
/// site while looking at a different box.
///
/// Only the model part moves. "Projector 1 - " is what this room calls the
/// position, and the position has not changed.
///
/// Case-insensitive, because a name is typed by a person and the catalog
/// string is not ('powerlite l630u' is the same box). Bounded on both sides by
/// a non-alphanumeric character, so a model that is a PREFIX of the one in the
/// name cannot eat half of it: swapping a device recorded as "L630" must not
/// turn "L630U" into "PT-MZ682BU8U".
///
/// Lives here rather than on the provider so the headless swap can use it;
/// `AppStateProvider.renamedForModel` forwards to it, so there is still one
/// implementation and every existing caller is untouched.
String renamedForModel(String name, String oldModel, String newModel) {
  final needle = oldModel.trim();
  final replacement = newModel.trim();
  if (name.isEmpty || needle.isEmpty || replacement.isEmpty) return name;
  if (needle.toLowerCase() == replacement.toLowerCase()) return name;
  final pattern = RegExp(
    '(?<![A-Za-z0-9])${RegExp.escape(needle)}(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  return name.replaceAll(pattern, replacement);
}

// ---------------------------------------------------------------------------
//  THE CONTROL SIDE
// ---------------------------------------------------------------------------

/// What a swap did to one config device block.
enum ControlSwapOutcome {
  /// The block was pointed at the new model and at the module that claims it.
  /// Everything else the block holds — IP address, port, control id — is kept:
  /// those are facts about this install, and the box in front of them changing
  /// is not a reason to throw them away.
  moduleMatched,

  /// The block was pointed at the new model and its module was CLEARED,
  /// because nothing claims the new one.
  ///
  /// Clearing rather than leaving the old value is the whole point. A block
  /// that says `model: PT-MZ682BU8` over `module: modules.device.epson_l630u`
  /// reads as configured and would be commissioned as the wrong projector,
  /// where an empty module reads as what it is: a decision nobody has made
  /// yet. It is also what puts this device on the "no control module" list —
  /// which is exactly where a newly specified product belongs until somebody
  /// writes or picks its driver.
  moduleCleared,

  /// There is no config block for this box — it was added to the drawing by
  /// hand. Nothing to do on the control side, and not a problem.
  noBlock,
}

/// Points one config device block at [model], the way a swap should.
///
/// Mutates [block] in place and returns what it did. [moduleForModel] returns
/// the python module claiming a model, or '' — the app's registry, passed in
/// because it is application data and this is a room edit.
///
/// The rename runs last, mirroring the live path: a module's own DEVICE_INFO
/// default can supply a name on the way past, and that name already carries
/// the new model, so there is nothing left for the rename to match and the
/// driver's answer wins without either having to know about the other.
ControlSwapOutcome swapControlBlock(
  Map<dynamic, dynamic> block,
  String model,
  String Function(String model) moduleForModel,
) {
  final was = block['model']?.toString().trim() ?? '';
  block['model'] = model;

  final module = moduleForModel(model);
  final outcome = module.isEmpty
      ? ControlSwapOutcome.moduleCleared
      : ControlSwapOutcome.moduleMatched;
  block['module'] = module;

  final name = block['name']?.toString() ?? '';
  final renamed = renamedForModel(name, was, model);
  if (renamed != name) block['name'] = renamed;

  return outcome;
}
