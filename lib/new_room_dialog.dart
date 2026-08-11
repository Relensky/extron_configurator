import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'room_presets.dart';

/// ============================================================================
///  NEW ROOM — THE TWO QUESTIONS WORTH ASKING UP FRONT
/// ============================================================================
///  Creating a room used to mean one thing: a config file for a processor,
///  with the control side filled in. In practice a room is specified long
///  before that. Somebody walks a space, lists what goes in it, draws a rack
///  and puts a number on it — and only later does anyone sit down to write the
///  control config. Forcing that work to start with a processor's JSON schema
///  is why it was being done in a spreadsheet instead.
///
///  So a new room answers two questions:
///
///    1. IS THERE A CONTROL SYSTEM YET? "Not yet" gives an AV-only room: the
///       building, the room number and the devices, with the System and Raw
///       JSON tabs out of the way. Everything else — schematic, signal flow,
///       racks, costs — works exactly as it does for a full room, because none
///       of it depends on the processor. Devices are still recorded in normal
///       config blocks, so nothing is re-entered when the control side is
///       finally built; the app just flags which ones still need a python
///       module.
///
///    2. WHERE DO THE DEVICES COME FROM? Starting from the cost estimator —
///       picking parts out of the catalog with quantities — is how a room
///       actually gets specified, and those picks are the same devices the
///       flow diagram, the racks and the estimate all need. One list, entered
///       once.
///
///    3. WHAT KIND OF ROOM IS IT? Most of what goes in a basic classroom is
///       the same as the last basic classroom — the same locations, the same
///       jack numbering scheme, very nearly the same cable count. A ROOM TYPE
///       stamps all of that in at once, so two rooms of the same kind come out
///       comparable instead of diverging by whoever drew them. The types are
///       files in the project root, so a shop edits ours or saves its own.
///
///  All three default to the old behavior, so pressing Create without reading
///  anything gives exactly what it always gave.
/// ============================================================================

/// What the user chose. Null when they canceled.
///
/// [preset] null means "start empty", which is the default.
typedef NewRoomChoice = ({
  RoomMode mode,
  bool startFromEstimator,
  RoomPreset? preset,
});

Future<NewRoomChoice?> showNewRoomDialog(BuildContext context) =>
    showDialog<NewRoomChoice>(
      context: context,
      builder: (ctx) => const _NewRoomDialog(),
    );

class _NewRoomDialog extends StatefulWidget {
  const _NewRoomDialog();

  @override
  State<_NewRoomDialog> createState() => _NewRoomDialogState();
}

class _NewRoomDialogState extends State<_NewRoomDialog> {
  RoomMode _mode = RoomMode.full;
  bool _startFromEstimator = false;
  RoomPreset? _preset;

  /// Read once. Touching the disk on every rebuild of a dialog that rebuilds
  /// on every radio press is not something to do to a network drive.
  List<RoomPreset>? _presets;

  List<RoomPreset> _availablePresets(AppStateProvider provider) =>
      _presets ??= provider.availableRoomPresets();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final presets = _availablePresets(provider);

    return AlertDialog(
      title: const Text('New room'),
      content: SizedBox(
        width: 620,
        height: math.min(620, MediaQuery.of(context).size.height - 180),
        child: ListView(
          children: [
            Text(
              'Will a control system be set up for this room?',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            RadioGroup<RoomMode>(
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v ?? _mode),
              child: const Column(
                children: [
                  RadioListTile<RoomMode>(
                    value: RoomMode.full,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Yes — configure it now'),
                    subtitle: Text(
                      'The full room: system settings, device control blocks '
                      'and the processor config, as well as the drawings and '
                      'costs.',
                    ),
                  ),
                  RadioListTile<RoomMode>(
                    value: RoomMode.avOnly,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Not yet — AV only'),
                    subtitle: Text(
                      'Building, room number and the devices. The System and '
                      'Raw JSON tabs step aside; the schematic, signal flow, '
                      'racks and costs all work as normal. Devices with no '
                      'python module are flagged, so the control side has a '
                      'list waiting when it is built.',
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 28),
            Text('What kind of room is it?', style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              'A room type brings its usual equipment, locations, jack '
              'numbering and cable runs. The room number, the building and the '
              'control config are left alone.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            RadioGroup<String>(
              // Keyed on the name rather than the object: the list is rebuilt
              // from disk, and a radio group comparing instances would lose
              // its selection the moment anything reloaded it.
              groupValue: _preset?.name ?? '',
              onChanged: (v) => setState(
                () => _preset = (v == null || v.isEmpty)
                    ? null
                    : presets.where((p) => p.name == v).firstOrNull,
              ),
              child: Column(
                children: [
                  const RadioListTile<String>(
                    value: '',
                    contentPadding: EdgeInsets.zero,
                    title: Text('Start empty'),
                    subtitle: Text(
                      'Just the room. Add the equipment yourself.',
                    ),
                  ),
                  for (final preset in presets)
                    RadioListTile<String>(
                      value: preset.name,
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          Text(preset.name),
                          if (!preset.builtIn) ...[
                            const SizedBox(width: 8),
                            Chip(
                              label: const Text('yours'),
                              visualDensity: VisualDensity.compact,
                              labelStyle: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        [
                          preset.description,
                          '${preset.deviceCount} device'
                              '${preset.deviceCount == 1 ? '' : 's'} · '
                              '${preset.jackCount} jack'
                              '${preset.jackCount == 1 ? '' : 's'} · '
                              '${preset.cables.length} run'
                              '${preset.cables.length == 1 ? '' : 's'}',
                        ].where((s) => s.isNotEmpty).join('\n'),
                      ),
                      isThreeLine: preset.description.isNotEmpty,
                    ),
                ],
              ),
            ),
            if (presets.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: Text(
                  'No room types found in the project root. They are written '
                  'to "$kRoomPresetFolder" under the Root Folder set in App '
                  'Config, and the four shipped ones appear there the first '
                  'time this dialog can reach it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const Divider(height: 28),
            CheckboxListTile(
              value: _startFromEstimator,
              onChanged: (v) =>
                  setState(() => _startFromEstimator = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Start from the cost estimator'),
              subtitle: const Text(
                'Pick the devices out of the catalog with quantities and a '
                'running total first. They become the boxes on the signal '
                'flow, the gear in the racks and the lines on the estimate — '
                'one list, entered once. Runs after the room type, so both '
                'can be used together.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop((
            mode: _mode,
            startFromEstimator: _startFromEstimator,
            preset: _preset,
          )),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
