import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'room_presets.dart';

/// "Save Room as Preset": the whole open room - AV flow, racks, floor plan
/// sheets, cabling sheet, cost page, control schematic and setup values -
/// saved as a room type in the shared room_presets folder, with its name and
/// details set here first.
Future<void> showSaveRoomPresetDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final existing = provider.availableRoomPresets();
  final setup = provider.roomConfig['SYSTEM_SETUP'];
  final roomName =
      setup is Map ? (setup['gui_full_room_name']?.toString() ?? '') : '';
  final result = await showDialog<RoomPreset>(
    context: context,
    builder: (_) => _SaveRoomPresetDialog(
      provider: provider,
      existing: existing,
      suggestedName: roomName.trim(),
    ),
  );
  if (result == null) return;
  final written = saveRoomPreset(provider.effectiveRootFolder, result);
  messenger.showSnackBar(SnackBar(
    content: Text(written.isEmpty
        ? 'The preset could not be written - see the log.'
        : 'Saved "${result.name}" - ${result.summary}. It is offered when a '
              'room is created.'),
  ));
}

class _SaveRoomPresetDialog extends StatefulWidget {
  final AppStateProvider provider;
  final List<RoomPreset> existing;
  final String suggestedName;

  const _SaveRoomPresetDialog({
    required this.provider,
    required this.existing,
    required this.suggestedName,
  });

  @override
  State<_SaveRoomPresetDialog> createState() => _SaveRoomPresetDialogState();
}

class _SaveRoomPresetDialogState extends State<_SaveRoomPresetDialog> {
  late final _name = TextEditingController(text: widget.suggestedName);
  final _description = TextEditingController();
  final _sourceName = TextEditingController();
  late final _jackPrefix =
      TextEditingController(text: widget.provider.roomJackPrefix);
  final Set<RoomPresetPart> _parts = {...RoomPresetPart.values};

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _sourceName.dispose();
    _jackPrefix.dispose();
    super.dispose();
  }

  /// What each part holds in this room, so an empty one is visible as such.
  String _count(RoomPresetPart part) {
    final p = widget.provider;
    String n(int count, String what) =>
        '$count $what${count == 1 ? '' : 's'}';
    final cost = p.avCost;
    return switch (part) {
      RoomPresetPart.flow => [
        n(p.avNodes.length, 'device'),
        n(p.avCables.length, 'cable'),
        n(p.avLocations.length, 'location'),
      ].join(', '),
      RoomPresetPart.racks => [
        n(p.avRacks.length, 'rack'),
        n(p.avRackItems.length, 'rack part'),
      ].join(', '),
      RoomPresetPart.floorPlans => n(p.avFloorPlans.length, 'sheet'),
      RoomPresetPart.cabling => p.avCabling.isEmpty ? 'as drawn' : 'laid out',
      RoomPresetPart.cost => [
        n(cost.extraEquipment.length + cost.extraHardware.length +
            cost.extraCables.length + cost.items.length, 'added line'),
        n(cost.labor.length, 'labor line'),
        n(cost.fees.length, 'fee'),
        n(cost.priceOverrides.length, 'room price'),
      ].join(', '),
      RoomPresetPart.schematic => p.schematicPositions.isEmpty
          ? 'not laid out'
          : n(p.schematicPositions.length, 'placed block'),
      RoomPresetPart.setup => 'input and output numbers',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _name.text.trim();
    final clash = widget.existing.any(
      (p) => p.name.trim().toLowerCase() == name.toLowerCase(),
    );
    final builtInClash = widget.existing.any(
      (p) => p.builtIn && p.name.trim().toLowerCase() == name.toLowerCase(),
    );
    return AlertDialog(
      title: const Text('Save Room as Preset'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Saves this room as a room type anybody can start a room '
                'from. The room number, building, addresses and control '
                'config stay with this room.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('room_preset_name'),
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Preset name',
                  hintText: 'e.g. 1 Projector, 2 Camera, Multi-mic',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  helperText: builtInClash
                      ? 'Replaces the built-in preset of this name.'
                      : clash
                      ? 'Replaces the preset of this name.'
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('room_preset_description'),
                controller: _description,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'What this room type is for',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              // Top-aligned: the jack prefix has a note under it, and
              // centered the two boxes sat at different heights.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('room_preset_source'),
                      controller: _sourceName,
                      decoration: const InputDecoration(
                        labelText: 'Name on the estate sheet (optional)',
                        hintText: 'e.g. 2 Projector',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 150,
                    child: TextField(
                      key: const ValueKey('room_preset_jacks'),
                      controller: _jackPrefix,
                      decoration: const InputDecoration(
                        labelText: 'Jack prefix',
                        helperText: 'Renumbered per room',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('What goes in', style: theme.textTheme.titleSmall),
              for (final part in RoomPresetPart.values)
                CheckboxListTile(
                  key: ValueKey('room_preset_part_${part.name}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _parts.contains(part),
                  title: Text(kRoomPresetPartLabels[part]!),
                  subtitle: Text(_count(part)),
                  onChanged: (v) => setState(
                    () => v == true ? _parts.add(part) : _parts.remove(part),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Saved to ${widget.provider.roomPresetFolder}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('room_preset_save'),
          onPressed: name.isEmpty || _parts.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    widget.provider.currentRoomAsPreset(
                      name: name,
                      description: _description.text.trim(),
                      sourceName: _sourceName.text.trim(),
                      jackPrefix: _jackPrefix.text.trim(),
                      include: _parts,
                    ),
                  ),
          child: Text(clash ? 'Replace' : 'Save'),
        ),
      ],
    );
  }
}
