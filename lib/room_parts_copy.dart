import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_swap_dialogs.dart' show applyModelSwap;
import 'cost_compare_view.dart' show pickOtherRoom;
import 'placed_devices.dart';
import 'project_estimate.dart';
import 'room_locations.dart';
import 'room_presets.dart';

/// ============================================================================
///  COPYING A ROOM'S DRAWING PARTS FROM ANOTHER ROOM
/// ============================================================================
///  Rooms of one type are drawn the same way, so the AV flow, racks, floor
///  plan sheets and cabling sheet of one are a fair start for the next. The
///  other room's parts are read off disk as a room type (see room_presets.dart)
///  and applied the way a room type is: fresh ids, wiring kept, jacks
///  renumbered for this room.
///
///  Its devices are checked against this PC's catalog first. One the catalog
///  lacks prices at nothing here, so each is either added to the catalog or
///  left out of the copy, with its cables and rack place.
///
///  Then each copied box is added, left out, or put in place of one of this
///  room's boxes: that box keeps its spot, cables, rack place and floor plan
///  icon, and takes the copied model. Last, each piece of gear placed on the
///  copied sheets is ticked to add or not.
/// ============================================================================

/// The parts this copies, in the order they are offered.
const List<RoomPresetPart> kCopyableRoomParts = [
  RoomPresetPart.flow,
  RoomPresetPart.racks,
  RoomPresetPart.floorPlans,
  RoomPresetPart.cabling,
];

const Map<RoomPresetPart, String> _kPartLabels = {
  RoomPresetPart.flow: 'AV flow - devices, jacks, cables and locations',
  RoomPresetPart.racks: 'Racks and the hardware in them',
  RoomPresetPart.floorPlans: 'Floor plan sheets, with their drawings',
  RoomPresetPart.cabling: 'Cabling sheet layout (only into a room with none)',
};

/// The room [doc] as a room type holding only [include]'s parts. [doc] is a
/// room's whole document - see [readRoomDocumentAsync].
RoomPreset roomPresetFromDocument(
  Map<String, dynamic> doc, {
  required String name,
  required Set<RoomPresetPart> include,
}) {
  bool has(RoomPresetPart p) => include.contains(p);
  return RoomPreset.fromJson({
    'name': name,
    if (has(RoomPresetPart.flow) || has(RoomPresetPart.floorPlans))
      'locations': doc['locations'],
    if (has(RoomPresetPart.flow)) ...{
      'nodes': doc['nodes'],
      'cables': doc['cables'],
      'screenSwitches': doc['screenSwitches'],
      'roomSettings': {
        for (final k in const [
          'signalColors',
          'roomMode',
          'roomLight',
          'throwDistanceFt',
        ])
          if (doc[k] != null) k: doc[k],
      },
    },
    if (has(RoomPresetPart.racks)) ...{
      'racks': doc['racks'],
      'rackItems': doc['rackItems'],
      'rackSlots': doc['rackSlots'],
    },
    if (has(RoomPresetPart.floorPlans)) 'floorPlans': doc['floorPlans'],
    if (has(RoomPresetPart.cabling) && doc['cablingSchematic'] is Map)
      'cabling': doc['cablingSchematic'],
  });
}

/// A model the copy would bring in that this PC's catalog does not have.
typedef MissingCatalogItem = ({
  String model,
  int count,
  String category,
  AvDeviceTemplate entry,
});

/// What [preset] draws or racks that [library] has no entry for, by model.
List<MissingCatalogItem> missingFromCatalog(
  RoomPreset preset,
  AvDeviceLibrary library,
) {
  final found = <String, MissingCatalogItem>{};
  void note(String model, AvDeviceTemplate Function() entry, String category) {
    final key = model.trim().toLowerCase();
    if (key.isEmpty || library.templateForModel(model) != null) return;
    final was = found[key];
    found[key] = was == null
        ? (model: model.trim(), count: 1, category: category, entry: entry())
        : (
            model: was.model,
            count: was.count + 1,
            category: was.category,
            entry: was.entry,
          );
  }

  for (final n in preset.nodes) {
    if (n.kind != AvNodeKind.device) continue;
    note(n.model, () => templateFromNode(n), guessCategory(n.label));
  }
  for (final i in preset.rackItems) {
    note(
      i.catalogModel,
      () => AvDeviceTemplate(
        model: i.catalogModel.trim(),
        category: i.category,
        partNumber: i.partNumber,
        rackUnits: i.rackUnits,
        price: i.price,
        ports: const [],
        custom: true,
        addedByUser: true,
      ),
      i.category,
    );
  }
  return found.values.toList()
    ..sort((a, b) => a.model.toLowerCase().compareTo(b.model.toLowerCase()));
}

/// A catalog entry for [n]'s model as it is drawn: its connectors, rack
/// height, power and heat.
AvDeviceTemplate templateFromNode(AvNode n) => AvDeviceTemplate(
  model: n.model.trim(),
  category: guessCategory(n.label),
  rackUnits: n.rackUnits,
  powerWatts: n.powerWatts,
  btuPerHour: n.btuPerHour,
  ports: n.ports,
  custom: true,
  addedByUser: true,
);

/// A catalog category from a box's label: 'Display 2 - Custom Model' ->
/// 'Display'.
String guessCategory(String label) => label
    .split(' - ')
    .first
    .replaceAll(RegExp(r'\s*\d+$'), '')
    .trim();

/// [preset] without the devices and rack hardware of [models] (lower case),
/// and without the cables, rack places and placed gear that went with them.
RoomPreset presetWithout(RoomPreset preset, Set<String> models) {
  if (models.isEmpty) return preset;
  bool dropped(String model) => models.contains(model.trim().toLowerCase());
  final goneItems = {
    for (final i in preset.rackItems)
      if (dropped(i.catalogModel)) i.id,
  };
  final trimmed = presetWithoutNodes(preset, {
    for (final n in preset.nodes)
      if (n.kind == AvNodeKind.device && dropped(n.model)) n.id,
  });
  return trimmed.copyWith(
    rackItems: [
      for (final i in trimmed.rackItems)
        if (!goneItems.contains(i.id)) i,
    ],
    rackSlots: {
      for (final e in trimmed.rackSlots.entries)
        if (!goneItems.contains(e.key)) e.key: e.value,
    },
  );
}

/// [preset] without the boxes [ids], their cables and rack places, and the
/// gear placed for them on its sheets. [keepGear] leaves the gear, for boxes
/// that stand for one this room already has.
RoomPreset presetWithoutNodes(
  RoomPreset preset,
  Set<String> ids, {
  bool keepGear = false,
}) {
  if (ids.isEmpty) return preset;
  return preset.copyWith(
    nodes: [
      for (final n in preset.nodes)
        if (!ids.contains(n.id)) n,
    ],
    cables: [
      for (final c in preset.cables)
        if (!ids.contains(c.fromNodeId) && !ids.contains(c.toNodeId)) c,
    ],
    rackSlots: {
      for (final e in preset.rackSlots.entries)
        if (!ids.contains(e.key)) e.key: e.value,
    },
    floorPlans: keepGear
        ? null
        : [
            for (final sheet in preset.floorPlans)
              sheet.copyWith(devices: [
                for (final d in sheet.devices)
                  if (!ids.contains(nodeIdOfDeviceKey(d.deviceKey))) d,
              ]),
          ],
  );
}

/// What one piece of gear on a copied sheet is ticked under.
String planGearKey(FloorPlan sheet, PlanDevice d) => '${sheet.id}|${d.id}';

/// [preset] with only the placed gear in [keep] (see [planGearKey]).
RoomPreset presetWithPlanGear(RoomPreset preset, Set<String> keep) =>
    preset.copyWith(floorPlans: [
      for (final sheet in preset.floorPlans)
        sheet.copyWith(devices: [
          for (final d in sheet.devices)
            if (keep.contains(planGearKey(sheet, d))) d,
        ]),
    ]);

/// Each copied box matched to one of this room's boxes of the same kind
/// ([kindOf]), one each, in order. Copied box id -> this room's box id.
Map<String, String> matchBoxesByKind(
  List<AvNode> copied,
  List<AvNode> here,
  String Function(AvNode) kindOf,
) {
  final out = <String, String>{};
  final used = <String>{};
  for (final c in copied) {
    final kind = kindOf(c);
    if (kind.isEmpty) continue;
    for (final h in here) {
      if (used.contains(h.id) || kindOf(h) != kind) continue;
      out[c.id] = h.id;
      used.add(h.id);
      break;
    }
  }
  return out;
}

/// Picks another room, the parts to take from it, settles what the catalog
/// lacks, and copies them into the open room.
Future<void> copyRoomPartsFromRoom(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text, {bool error = false}) => showTimedSnackBar(
    messenger,
    SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(text),
      backgroundColor: error ? snackErrorFillOn(messenger) : null,
    ),
  );

  final other = await pickOtherRoom(
    context,
    provider,
    title: 'Copy drawing parts from another room',
    action: 'Next',
  );
  if (other == null || !context.mounted) return;
  final doc = await readRoomDocumentAsync(other.configPath);
  Object? setup;
  try {
    final config = jsonDecode(await File(other.configPath).readAsString());
    if (config is Map) setup = config['SYSTEM_SETUP'];
  } catch (_) {}
  if (!context.mounted) return;
  if (doc == null) {
    say('${other.label} has no drawing to copy.', error: true);
    return;
  }

  final parts = await showDialog<Set<RoomPresetPart>>(
    context: context,
    builder: (_) => _PartsDialog(room: other.label, doc: doc),
  );
  if (parts == null || parts.isEmpty || !context.mounted) return;

  var preset = roomPresetFromDocument(doc, name: other.label, include: parts);
  final missing = missingFromCatalog(preset, provider.avDeviceLibrary);
  if (missing.isNotEmpty) {
    final choice = await showDialog<_MissingChoice>(
      context: context,
      builder: (_) => _MissingDialog(room: other.label, missing: missing),
    );
    if (choice == null || !context.mounted) return;
    if (choice.add.isNotEmpty) {
      for (final m in choice.add) {
        provider.avDeviceLibrary.upsert(m);
      }
      await provider.saveAvDeviceLibrary();
      provider.avDeviceLibraryChanged();
    }
    preset = presetWithout(preset, choice.drop);
    if (!context.mounted) return;
  }

  // Each copied box: added, left out, or in place of one of this room's.
  final library = provider.avDeviceLibrary;
  String kindOf(AvNode n) {
    final category = library.templateForModel(n.model)?.category.trim() ?? '';
    return (category.isNotEmpty ? category : guessCategory(n.label))
        .toLowerCase();
  }

  final copied = [
    for (final n in preset.nodes)
      if (n.kind == AvNodeKind.device) n,
  ];
  final here = [
    for (final n in provider.avNodes)
      if (n.kind == AvNodeKind.device) n,
  ];
  var swaps = <String, String>{};
  if (parts.contains(RoomPresetPart.flow) &&
      copied.isNotEmpty &&
      here.isNotEmpty) {
    final match = await showDialog<_MatchChoice>(
      context: context,
      builder: (_) => _MatchDialog(
        room: other.label,
        copied: copied,
        here: here,
        kindOf: kindOf,
      ),
    );
    if (match == null || !context.mounted) return;
    swaps = match.swaps;
    preset = presetWithoutNodes(preset, match.skip);
    preset = presetWithoutNodes(preset, swaps.keys.toSet(), keepGear: true);
  }

  // Each piece of gear on the copied sheets: added or not.
  final hasGear = preset.floorPlans.any((s) => s.devices.isNotEmpty);
  if (parts.contains(RoomPresetPart.floorPlans) && hasGear) {
    final keep = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _GearDialog(
        room: other.label,
        sheets: preset.floorPlans,
        sheetsHere: {
          for (final p in provider.avFloorPlans) p.name.trim().toLowerCase(),
        },
        swaps: swaps,
        names: {for (final n in here) n.id: n.label},
      ),
    );
    if (keep == null || !context.mounted) return;
    preset = presetWithPlanGear(preset, keep);
  }

  // The swaps first, as their own undo step: Undo takes the copy off, and
  // again puts the old models back.
  var replaced = 0, lostCables = 0;
  final copiedById = {for (final n in copied) n.id: n};
  for (final e in swaps.entries) {
    final from = copiedById[e.key];
    final to = provider.avNodeById(e.value);
    if (from == null || to == null) continue;
    if (from.model.trim().toLowerCase() == to.model.trim().toLowerCase()) {
      continue;
    }
    final r = applyModelSwap(
      provider,
      to,
      library.templateForModel(from.model) ?? templateFromNode(from),
      recordUndo: replaced == 0,
    );
    replaced++;
    lostCables += r.dropped;
  }

  final done = await provider.copyRoomPartsFrom(
    other.configPath,
    preset,
    fromSetup: setup,
    linkedNodes: swaps,
  );
  say([
    'Copied from ${other.label}:',
    [
      if (done.devices > 0) '${done.devices} device(s)',
      if (replaced > 0) '$replaced replaced in place',
      if (lostCables > 0)
        '$lostCables cable(s) taken off a connector the new model lacks',
      if (done.jacks > 0) '${done.jacks} jack(s)',
      if (done.cables > 0) '${done.cables} cable(s)',
      if (done.racks > 0) '${done.racks} rack(s)',
      if (preset.floorPlans.isNotEmpty) '${preset.floorPlans.length} sheet(s)',
      if (preset.cabling.isNotEmpty) 'cabling sheet',
    ].join(', '),
    replaced > 0
        ? '- Undo takes the copy off, and Undo again puts the old models back.'
        : '- Undo takes it back off.',
  ].join(' '));
}

/// Which parts to copy, each with what the other room has of it.
class _PartsDialog extends StatefulWidget {
  final String room;
  final Map<String, dynamic> doc;

  const _PartsDialog({required this.room, required this.doc});

  @override
  State<_PartsDialog> createState() => _PartsDialogState();
}

class _PartsDialogState extends State<_PartsDialog> {
  late final Map<RoomPresetPart, String> _has = {
    for (final p in kCopyableRoomParts)
      if (_describe(p) case final d? when d.isNotEmpty) p: d,
  };
  late final Set<RoomPresetPart> _picked = {..._has.keys};

  int _count(String key) {
    final v = widget.doc[key];
    return v is List ? v.length : (v is Map ? v.length : 0);
  }

  String? _describe(RoomPresetPart p) {
    String n(int c, String w) => '$c $w${c == 1 ? '' : 's'}';
    return switch (p) {
      RoomPresetPart.flow => _count('nodes') == 0
          ? null
          : '${n(_count('nodes'), 'box')}, ${n(_count('cables'), 'cable')}',
      RoomPresetPart.racks => _count('racks') == 0
          ? null
          : '${n(_count('racks'), 'rack')}, '
                '${n(_count('rackItems'), 'piece')} of hardware',
      RoomPresetPart.floorPlans =>
        _count('floorPlans') == 0 ? null : n(_count('floorPlans'), 'sheet'),
      RoomPresetPart.cabling =>
        widget.doc['cablingSchematic'] is Map ? 'laid out' : null,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('copy_parts_dialog'),
      title: Text('Copy from ${widget.room}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Added to this room alongside what it has. Jacks are '
              'renumbered for this room. Next, each device can replace one '
              'this room has, and each piece of floor plan gear can be '
              'ticked or left out.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_has.isEmpty)
              const Text('That room has nothing drawn to copy.')
            else
              for (final p in kCopyableRoomParts)
                if (_has[p] != null)
                  CheckboxListTile(
                    key: ValueKey('copy_part_${p.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _picked.contains(p),
                    title: Text(_kPartLabels[p]!),
                    subtitle: Text(_has[p]!),
                    onChanged: (v) => setState(
                      () => v == true ? _picked.add(p) : _picked.remove(p),
                    ),
                  ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('copy_parts_go'),
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.pop(context, {..._picked}),
          child: const Text('Next'),
        ),
      ],
    );
  }
}

typedef _MissingChoice = ({List<AvDeviceTemplate> add, Set<String> drop});

/// Each model the catalog lacks: add it to the catalog, or leave it out.
class _MissingDialog extends StatefulWidget {
  final String room;
  final List<MissingCatalogItem> missing;

  const _MissingDialog({required this.room, required this.missing});

  @override
  State<_MissingDialog> createState() => _MissingDialogState();
}

class _MissingDialogState extends State<_MissingDialog> {
  /// Lower-case model -> true to add it, false to drop it.
  late final Map<String, bool> _add = {
    for (final m in widget.missing) m.model.toLowerCase(): true,
  };
  late final Map<String, TextEditingController> _category = {
    for (final m in widget.missing)
      m.model.toLowerCase(): TextEditingController(text: m.category),
  };

  @override
  void dispose() {
    for (final c in _category.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _setAll(bool add) => setState(() {
    for (final k in _add.keys) {
      _add[k] = add;
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final adding = _add.values.where((v) => v).length;
    return AlertDialog(
      key: const ValueKey('copy_missing_dialog'),
      title: Text(
        '${widget.missing.length} model${widget.missing.length == 1 ? '' : 's'} '
        'not in your catalog',
      ),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.room} uses these, and this catalog has no entry for '
              'them, so they would price at nothing here. Add each to the '
              'catalog - with the connectors drawn in ${widget.room} and no '
              'price yet - or leave it out of the copy with its cables.',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                TextButton(
                  key: const ValueKey('copy_missing_add_all'),
                  onPressed: () => _setAll(true),
                  child: const Text('Add all'),
                ),
                TextButton(
                  key: const ValueKey('copy_missing_drop_all'),
                  onPressed: () => _setAll(false),
                  child: const Text('Leave all out'),
                ),
              ],
            ),
            const Divider(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in widget.missing)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.model,
                                      style: theme.textTheme.titleSmall),
                                  Text(
                                    '${m.count} in ${widget.room}',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: muted),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                key: ValueKey('copy_missing_category_${m.model}'),
                                controller: _category[m.model.toLowerCase()],
                                enabled: _add[m.model.toLowerCase()]!,
                                decoration: const InputDecoration(
                                  labelText: 'Category',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SegmentedButton<bool>(
                              key: ValueKey('copy_missing_${m.model}'),
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment(value: true, label: Text('Add')),
                                ButtonSegment(
                                  value: false,
                                  label: Text('Leave out'),
                                ),
                              ],
                              selected: {_add[m.model.toLowerCase()]!},
                              onSelectionChanged: (v) => setState(
                                () => _add[m.model.toLowerCase()] = v.single,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('copy_missing_go'),
          onPressed: () => Navigator.pop(context, (
            add: [
              for (final m in widget.missing)
                if (_add[m.model.toLowerCase()]!)
                  m.entry.copyWith(
                    category: _category[m.model.toLowerCase()]!.text.trim(),
                  ),
            ],
            drop: {
              for (final m in widget.missing)
                if (!_add[m.model.toLowerCase()]!) m.model.toLowerCase(),
            },
          )),
          child: Text(
            adding == widget.missing.length
                ? 'Add and copy'
                : adding == 0
                ? 'Copy without them'
                : 'Add $adding and copy',
          ),
        ),
      ],
    );
  }
}

typedef _MatchChoice = ({Map<String, String> swaps, Set<String> skip});

/// Each copied box: add it, leave it out, or put it in place of one of this
/// room's boxes.
class _MatchDialog extends StatefulWidget {
  final String room;
  final List<AvNode> copied;
  final List<AvNode> here;
  final String Function(AvNode) kindOf;

  const _MatchDialog({
    required this.room,
    required this.copied,
    required this.here,
    required this.kindOf,
  });

  @override
  State<_MatchDialog> createState() => _MatchDialogState();
}

class _MatchDialogState extends State<_MatchDialog> {
  static const String _add = '<add>';
  static const String _skip = '<skip>';

  /// Copied box id -> [_add], [_skip] or this room's box id.
  late final Map<String, String> _pick = {
    for (final c in widget.copied) c.id: _add,
  };

  /// This room's boxes, the same kind as [c] first.
  List<AvNode> _choicesFor(AvNode c) {
    final kind = widget.kindOf(c);
    return [
      for (final h in widget.here)
        if (widget.kindOf(h) == kind) h,
      for (final h in widget.here)
        if (widget.kindOf(h) != kind) h,
    ];
  }

  void _matchByKind() => setState(() {
    final m = matchBoxesByKind(widget.copied, widget.here, widget.kindOf);
    for (final c in widget.copied) {
      _pick[c.id] = m[c.id] ?? _add;
    }
  });

  void _addAll() => setState(() {
    for (final k in _pick.keys) {
      _pick[k] = _add;
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final swapped = _pick.values.where((v) => v != _add && v != _skip).length;
    return AlertDialog(
      key: const ValueKey('copy_match_dialog'),
      title: Text('Devices from ${widget.room}'),
      content: SizedBox(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add each as a new box, leave it out, or put it in place of '
              'one of this room\'s. A replaced box keeps its spot, cables, '
              'rack place and floor plan icon, and takes the model and part '
              'number from ${widget.room}.',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                TextButton(
                  key: const ValueKey('copy_match_by_kind'),
                  onPressed: _matchByKind,
                  child: const Text('Replace matching types'),
                ),
                TextButton(
                  key: const ValueKey('copy_match_add_all'),
                  onPressed: _addAll,
                  child: const Text('Add all as new'),
                ),
              ],
            ),
            const Divider(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in widget.copied) _row(c, theme, muted),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('copy_match_go'),
          onPressed: () => Navigator.pop(context, (
            swaps: {
              for (final e in _pick.entries)
                if (e.value != _add && e.value != _skip) e.key: e.value,
            },
            skip: {
              for (final e in _pick.entries)
                if (e.value == _skip) e.key,
            },
          )),
          child: Text(swapped == 0 ? 'Next' : 'Replace $swapped and go on'),
        ),
      ],
    );
  }

  Widget _row(AvNode c, ThemeData theme, Color muted) {
    final taken = {
      for (final e in _pick.entries)
        if (e.key != c.id) e.value,
    };
    String nameOf(AvNode h) =>
        h.model.trim().toLowerCase() == c.model.trim().toLowerCase()
        ? 'Use ${h.label} - same model'
        : 'Replace ${h.label} (${h.model})';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.label, style: theme.textTheme.titleSmall),
                Text(c.model,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: DropdownButton<String>(
              key: ValueKey('copy_match_${c.id}'),
              isExpanded: true,
              value: _pick[c.id],
              items: [
                const DropdownMenuItem(
                    value: _add, child: Text('Add as a new box')),
                const DropdownMenuItem(
                    value: _skip, child: Text('Leave out')),
                for (final h in _choicesFor(c))
                  DropdownMenuItem(
                    value: h.id,
                    enabled: !taken.contains(h.id),
                    child: Text(
                      nameOf(h),
                      overflow: TextOverflow.ellipsis,
                      style: taken.contains(h.id)
                          ? TextStyle(color: theme.disabledColor)
                          : null,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _pick[c.id] = v ?? _add),
            ),
          ),
        ],
      ),
    );
  }
}

/// Each piece of gear on the copied sheets, ticked to add.
class _GearDialog extends StatefulWidget {
  final String room;
  final List<FloorPlan> sheets;

  /// This room's sheet names, lower case: gear goes onto those as they are.
  final Set<String> sheetsHere;

  /// Copied box id -> this room's box it was put in place of.
  final Map<String, String> swaps;

  /// This room's box id -> label.
  final Map<String, String> names;

  const _GearDialog({
    required this.room,
    required this.sheets,
    required this.sheetsHere,
    required this.swaps,
    required this.names,
  });

  @override
  State<_GearDialog> createState() => _GearDialogState();
}

class _GearDialogState extends State<_GearDialog> {
  late final Set<String> _all = {
    for (final s in widget.sheets)
      for (final d in s.devices) planGearKey(s, d),
  };
  late final Set<String> _keep = {..._all};

  /// Which of this room's boxes a replaced box's icon now stands for.
  String? _note(PlanDevice d) {
    final id = nodeIdOfDeviceKey(d.deviceKey);
    final to = id == null ? null : widget.swaps[id];
    if (to == null) return null;
    return 'For this room\'s ${widget.names[to] ?? 'box'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return AlertDialog(
      key: const ValueKey('copy_gear_dialog'),
      title: Text('Floor plan gear from ${widget.room}'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tick the gear to place. A sheet this room already has keeps '
              'its drawing and gets the ticked gear it does not have yet.',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                TextButton(
                  key: const ValueKey('copy_gear_all'),
                  onPressed: () => setState(() => _keep.addAll(_all)),
                  child: const Text('Tick all'),
                ),
                TextButton(
                  key: const ValueKey('copy_gear_none'),
                  onPressed: () => setState(_keep.clear),
                  child: const Text('Tick none'),
                ),
              ],
            ),
            const Divider(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in widget.sheets)
                      if (s.devices.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 2),
                          child: Text(
                            widget.sheetsHere
                                    .contains(s.name.trim().toLowerCase())
                                ? '${s.name} - onto this room\'s sheet'
                                : '${s.name} - new sheet',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        for (final d in s.devices)
                          CheckboxListTile(
                            key: ValueKey('copy_gear_${planGearKey(s, d)}'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _keep.contains(planGearKey(s, d)),
                            title: Text(d.label),
                            subtitle: _note(d) == null
                                ? null
                                : Text(_note(d)!,
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: muted)),
                            onChanged: (v) => setState(() => v == true
                                ? _keep.add(planGearKey(s, d))
                                : _keep.remove(planGearKey(s, d))),
                          ),
                      ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('copy_gear_go'),
          onPressed: () => Navigator.pop(context, {..._keep}),
          child: Text(_keep.length == _all.length
              ? 'Copy'
              : 'Copy with ${_keep.length} of ${_all.length}'),
        ),
      ],
    );
  }
}
