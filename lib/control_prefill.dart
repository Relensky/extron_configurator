import 'dart:convert';

import 'app_logger.dart';
import 'app_state.dart';
import 'av_flow_model.dart';
import 'ui_schema.dart';

/// ============================================================================
///  BUILDING THE CONTROL SIDE OF A ROOM THAT WAS ONLY BUDGETED
/// ============================================================================
///  A room usually gets specified long before anybody writes its control
///  config: somebody walks the space, lists the gear, draws a rack and puts a
///  number on it. That work leaves a full signal-flow diagram and a priced
///  estimate, and NO control blocks at all — so when the control side finally
///  gets built, every device has to be typed in a second time, matched by hand
///  against the drawing, and named consistently by somebody's memory.
///
///  That second pass is what this file removes. The diagram already knows what
///  is in the room; the schema already knows what a device block looks like for
///  each family; the module library already knows which driver claims which
///  model. Putting the three together gives:
///
///    * one config block per drawn device, in the right family, carrying the
///      application's own defaults for that family (ui_schema `device_defaults`
///      and the family `template`) — the same defaults the Setup Wizard uses,
///      so a prefilled room and a hand-built one are the same document;
///    * SEQUENTIAL names inside each family — "Projector 1", "Projector 2" —
///      because a room where the names came from whatever was typed on the
///      canvas is a room where the config and the drawing disagree about which
///      display is which;
///    * the python module filled in wherever the library claims the model, and
///      LEFT BLANK AND FLAGGED where it doesn't.
///
///  That last part is the point of doing this at all rather than leaving it to
///  the Devices tab. A generic box — a projector, a power controller, a screen
///  — has no driver until somebody chooses one, and a room that quietly ships
///  with three of those is a room that does not commission. They are counted
///  here, shown before anything is written, and printed on the exported report.
///
///  Nothing is destructive: a device that already has a config block is left
///  alone, and the counts are RAISED rather than reset (the Setup Wizard's
///  [AppStateProvider.setDeviceCount] rebuilds a family from scratch, which
///  would throw away the blocks this is trying to add to).
/// ============================================================================

/// One device the prefill would create.
class ControlPrefillEntry {
  /// The AV node this came from.
  final String nodeId;
  final String nodeLabel;
  final String model;

  /// The family it landed in, or null when nothing claimed it.
  final DeviceTypeSpec? family;

  /// The config section key it will get ('PROJECTORDEVICE_2'). Empty when
  /// [family] is null and nothing can be created.
  final String sectionKey;

  /// The name that goes in the block — sequential inside the family.
  final String name;

  /// The python module the library claims for [model], or '' when none does.
  final String module;

  const ControlPrefillEntry({
    required this.nodeId,
    required this.nodeLabel,
    required this.model,
    required this.family,
    required this.sectionKey,
    required this.name,
    required this.module,
  });

  /// True when this device will be created but cannot be driven yet.
  bool get needsModule => family != null && module.isEmpty;

  /// True when no family claimed it, so there is nowhere to put a block.
  ///
  /// Not a failure of the device — a speaker or a wall plate never had a
  /// control block — but it IS the list somebody should look at, because a
  /// projector landing here means the catalog's category is wrong.
  bool get unplaceable => family == null;
}

/// What a prefill would do, worked out before anything is written.
class ControlPrefillPlan {
  final List<ControlPrefillEntry> entries;

  /// Devices already backed by a config block — left alone, counted so the
  /// dialog can say why the number is smaller than the diagram.
  final int alreadyConfigured;

  const ControlPrefillPlan({
    required this.entries,
    required this.alreadyConfigured,
  });

  List<ControlPrefillEntry> get creatable =>
      entries.where((e) => !e.unplaceable).toList();

  List<ControlPrefillEntry> get unplaceable =>
      entries.where((e) => e.unplaceable).toList();

  List<ControlPrefillEntry> get withoutModule =>
      entries.where((e) => e.needsModule).toList();

  bool get isEmpty => creatable.isEmpty;

  /// Creatable devices grouped by family, in schema order.
  Map<DeviceTypeSpec, List<ControlPrefillEntry>> get byFamily {
    final out = <DeviceTypeSpec, List<ControlPrefillEntry>>{};
    for (final e in creatable) {
      out.putIfAbsent(e.family!, () => []).add(e);
    }
    return out;
  }
}

/// Works out what building the control side would create, without writing it.
///
/// Jack fields and patch panels are skipped: they are passive, and a processor
/// was never going to talk to one.
ControlPrefillPlan planControlSide(AppStateProvider provider) {
  final configured = activeDeviceKeysIn(
    provider.roomConfig,
    provider.uiSchema.deviceCountMap,
  ).toSet();

  // Where each family's numbering has to start: past whatever is already
  // there, so a prefill run twice does not renumber the first run's devices.
  final nextIndex = <String, int>{};
  for (final spec in provider.uiSchema.deviceTypes) {
    nextIndex[spec.prefix] = _existingCount(provider, spec) + 1;
  }

  final entries = <ControlPrefillEntry>[];
  int alreadyConfigured = 0;

  for (final node in provider.avNodes) {
    if (node.isJackField) continue;
    if (configured.contains(node.id)) {
      alreadyConfigured++;
      continue;
    }

    final family = familyForNode(provider, node);
    if (family == null) {
      entries.add(
        ControlPrefillEntry(
          nodeId: node.id,
          nodeLabel: node.label,
          model: node.model,
          family: null,
          sectionKey: '',
          name: node.label,
          module: '',
        ),
      );
      continue;
    }

    final index = nextIndex[family.prefix] ?? 1;
    nextIndex[family.prefix] = index + 1;

    entries.add(
      ControlPrefillEntry(
        nodeId: node.id,
        nodeLabel: node.label,
        model: node.model,
        family: family,
        sectionKey: '${family.prefix}$index',
        name: sequentialName(family, index),
        module: provider.moduleForModel(node.model),
      ),
    );
  }

  return ControlPrefillPlan(
    entries: entries,
    alreadyConfigured: alreadyConfigured,
  );
}

/// How many blocks a family already has in the room.
int _existingCount(AppStateProvider provider, DeviceTypeSpec spec) {
  final setup = provider.roomConfig['SYSTEM_SETUP'];
  final raw = setup is Map ? setup[spec.countKey]?.toString() : null;
  final declared = raw == null
      ? 0
      : (raw.toLowerCase() == 'yes' ? 1 : (int.tryParse(raw) ?? 0));
  // The count and the blocks can disagree in a hand-edited config, and
  // numbering past the SMALLER of the two would overwrite a block. The larger
  // is the only safe answer.
  int present = 0;
  for (final key in provider.roomConfig.keys) {
    if (!key.startsWith(spec.prefix)) continue;
    final n = int.tryParse(key.substring(spec.prefix.length));
    if (n != null && n > present) present = n;
  }
  return declared > present ? declared : present;
}

/// The name a family's Nth device gets: the family's own label, singular,
/// with the index — 'Projector 2', 'Camera 1'.
///
/// From the family rather than from the node's label on purpose. A canvas
/// carries whatever somebody typed while drawing — "Epson", "front proj",
/// "PROJ-A" — and a config where the names came from that is a config nobody
/// can cross-reference against a second room. The drawn label is not lost: it
/// stays on the diagram, and the report prints both.
String sequentialName(DeviceTypeSpec family, int index) {
  // 'Projectors / Displays' -> 'Projector'. The first word of the label is
  // the family's own name for itself; anything after a slash is the alias.
  var base = family.label.split('/').first.trim();
  if (base.isEmpty) base = family.countKey.replaceFirst('dev_', '');
  if (base.endsWith('s') && base.length > 1) {
    base = base.substring(0, base.length - 1);
  }
  // Title case the first letter so 'usb switchers' reads as a name.
  if (base.isNotEmpty) base = base[0].toUpperCase() + base.substring(1);
  return '$base $index';
}

/// The device family [node] belongs to, or null when nothing claims it.
///
/// Tried in the order the answers are trustworthy:
///   1. the node's own id, when it was seeded from a config block already;
///   2. the catalog entry's declared device types, which is the fact the
///      catalog exists to record;
///   3. the catalog's category, then the model and the drawn label as words —
///      the fallbacks that catch a generic box somebody typed in by hand
///      ("Projector", "Power controller") and never gave a catalog entry.
DeviceTypeSpec? familyForNode(AppStateProvider provider, AvNode node) {
  final byId = provider.uiSchema.deviceTypeForSection(node.id);
  if (byId != null) return byId;

  final template = provider.avDeviceLibrary.templateForModel(node.model);

  // Every token this device offers about what it is, best evidence first.
  final candidates = <String>[
    if (template != null) template.category,
    ...node.model.split(RegExp(r'[^A-Za-z0-9]+')),
    ...node.label.split(RegExp(r'[^A-Za-z0-9]+')),
  ].where((s) => s.trim().isNotEmpty).toList();

  for (final candidate in candidates) {
    final token = AppStateProvider.normalizeDeviceTypeToken(candidate);
    if (token.isEmpty) continue;
    for (final spec in provider.uiSchema.deviceTypes) {
      if (_familyTokens(spec).contains(token)) return spec;
    }
  }

  // The model as the registry knows it. Last because it means asking the
  // module library what something is, and the library only knows about models
  // some driver already claims — which is exactly the set this is trying to
  // find the gaps in.
  final entry = provider.modelEntryFor(node.model);
  if (entry != null) {
    for (final spec in provider.uiSchema.deviceTypes) {
      if (provider.modelMatchesDevice(entry, spec.prefix)) return spec;
    }
  }
  return null;
}

/// The words a family answers to.
Set<String> _familyTokens(DeviceTypeSpec spec) => {
  AppStateProvider.normalizeDeviceTypeToken(spec.prefix),
  AppStateProvider.normalizeDeviceTypeToken(
    spec.countKey.replaceFirst('dev_', ''),
  ),
  for (final w in spec.label.split(RegExp(r'[^A-Za-z0-9]+')))
    if (w.isNotEmpty) AppStateProvider.normalizeDeviceTypeToken(w),
}..remove('');

/// What a prefill actually did.
typedef ControlPrefillResult = ({
  int created,
  int withoutModule,
  int skipped,
  List<String> sectionKeys,
});

/// Writes the planned blocks into the room config.
///
/// Each block starts from the same place a wizard-created one does —
/// [AppStateProvider.getDefaultDeviceBlock] for the family, then the schema's
/// `device_defaults` for anything it left out — so the two routes cannot
/// produce different documents. On top of that:
///
///   * the name is the sequential one from the plan;
///   * `model` comes off the diagram, because the drawing is where the model
///     was chosen;
///   * `module` is filled in only where the library claims the model, and left
///     blank otherwise so the app's own missing-module list catches it;
///   * the AV node is RE-KEYED to the new section key, which is what makes the
///     diagram and the config the same device rather than two records of it.
///
/// The family counts are raised, never reset — [AppStateProvider.setDeviceCount]
/// rebuilds a family from scratch and would discard the blocks being added.
ControlPrefillResult applyControlSide(
  AppStateProvider provider,
  ControlPrefillPlan plan,
) {
  final setup = provider.roomConfig['SYSTEM_SETUP'];
  if (setup is! Map) {
    return (created: 0, withoutModule: 0, skipped: 0, sectionKeys: const []);
  }

  final created = <String>[];
  int withoutModule = 0;

  for (final entry in plan.creatable) {
    final family = entry.family!;
    final block = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(provider.getDefaultDeviceBlock(family.prefix))),
    );

    block['name'] = entry.name;
    if (entry.model.trim().isNotEmpty) block['model'] = entry.model.trim();
    if (entry.module.isNotEmpty) {
      block['module'] = entry.module;
    } else {
      // Blank rather than a plausible-looking guess. A wrong module is worse
      // than an empty one: the empty one is on every missing-module list in
      // the app, and the wrong one looks finished.
      block['module'] = '';
      withoutModule++;
    }

    provider.roomConfig[entry.sectionKey] = block;
    provider.applyDeviceBlockDefaults(entry.sectionKey);
    created.add(entry.sectionKey);
  }

  // Counts last, and raised to what is actually present.
  for (final spec in provider.uiSchema.deviceTypes) {
    final present = _existingCount(provider, spec);
    if (present <= 0) continue;
    setup[spec.countKey] = present.toString();
  }

  // Re-key the diagram onto the blocks, so the two are one device.
  for (final entry in plan.creatable) {
    provider.rekeyAvNode(entry.nodeId, entry.sectionKey);
  }

  AppLogger.logInfo(
    'Built the control side: ${created.length} device block(s) created, '
    '$withoutModule without a module, ${plan.unplaceable.length} device(s) '
    'with no matching family.',
  );

  return (
    created: created.length,
    withoutModule: withoutModule,
    skipped: plan.unplaceable.length,
    sectionKeys: created,
  );
}
