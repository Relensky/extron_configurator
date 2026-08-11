import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'room_locations.dart';

/// ============================================================================
///  EDITING WHERE THINGS ARE
/// ============================================================================
///  The dialogs behind the location field on every device editor, the Floor
///  Plan tab's location list, and the screen/shade control runs.
///
///  They live together because they are one small vocabulary — a place, and a
///  run between two places — and because the location editor has to be
///  reachable from inside other dialogs. Nobody switches tabs to define "front
///  floor box" halfway through adding a wall plate; if defining one is not
///  possible from where the field is, the field stays blank and every
///  per-location count in the reports counts nothing.
/// ============================================================================

/// Adds or edits one location. Returns the stored location, or null on cancel.
///
/// [existing] null means "add" — the dialog creates it on save and hands back
/// the stored copy so the caller can select it straight away.
Future<RoomLocation?> showLocationEditor(
  BuildContext context,
  AppStateProvider provider,
  RoomLocation? existing,
) async {
  final nameController = TextEditingController(text: existing?.name ?? '');
  final calloutController = TextEditingController(
    text: existing?.callout ?? _suggestCallout(provider),
  );
  final noteController = TextEditingController(text: existing?.note ?? '');
  RoomZone zone = existing?.zone ?? RoomZone.unspecified;

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(existing == null ? 'Add a location' : 'Edit location'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A place in the room that gear lands in. Devices, jack fields '
                'and control runs name one, so the reports can count jacks and '
                'cable per location and group them by mounting surface.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Front floor box, Ceiling over row 2',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<RoomZone>(
                      initialValue: zone,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Mounting surface',
                        helperText: 'What the counts are grouped by',
                      ),
                      items: [
                        for (final z in RoomZone.values)
                          DropdownMenuItem(
                            value: z,
                            child: Row(
                              children: [
                                Icon(kRoomZoneIcons[z] ?? Icons.place, size: 16),
                                const SizedBox(width: 8),
                                Text(kRoomZoneLabels[z] ?? z.name),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => zone = v ?? zone),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: calloutController,
                      decoration: const InputDecoration(
                        labelText: 'Callout',
                        helperText: 'Tag on the plan',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'Back box size, mounting height, who supplies it',
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(existing == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    ),
  );

  if (saved != true) return null;

  final name = nameController.text.trim();
  if (name.isEmpty) return null;

  if (existing == null) {
    return provider.addAvLocation(
      RoomLocation(
        id: '',
        name: name,
        zone: zone,
        callout: calloutController.text.trim(),
        note: noteController.text.trim(),
      ),
    );
  }

  final updated = existing.copyWith(
    name: name,
    zone: zone,
    callout: calloutController.text.trim(),
    note: noteController.text.trim(),
  );
  provider.updateAvLocation(updated);
  return updated;
}

/// The next unused single-letter callout — A, B, C … — so adding a location
/// does not start by asking which letters are already spoken for.
String _suggestCallout(AppStateProvider provider) {
  final used = {
    for (final l in provider.avLocations) l.callout.trim().toUpperCase(),
  };
  for (int i = 0; i < 26; i++) {
    final tag = String.fromCharCode(65 + i);
    if (!used.contains(tag)) return tag;
  }
  return '';
}

/// The room's location list: add, edit, remove, and see at a glance what has
/// landed in each place.
Future<void> showLocationManager(
  BuildContext context,
  AppStateProvider provider,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => const _LocationManagerDialog(),
  );
}

class _LocationManagerDialog extends StatefulWidget {
  const _LocationManagerDialog();

  @override
  State<_LocationManagerDialog> createState() => _LocationManagerDialogState();
}

class _LocationManagerDialogState extends State<_LocationManagerDialog> {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Locations in this room'),
      content: SizedBox(
        width: math.min(700, MediaQuery.of(context).size.width - 120),
        height: math.min(520, MediaQuery.of(context).size.height - 220),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Every device, jack field and control run can name one of these. '
              'The reports count jacks and cable runs per location and group '
              'them by mounting surface.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: provider.avLocations.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'No locations yet.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.playlist_add, size: 18),
                            label: const Text('Start with the usual five'),
                            onPressed: () => setState(
                              provider.seedDefaultAvLocations,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      children: [
                        for (final location in provider.avLocations)
                          _locationRow(provider, location, theme),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.add_location_alt_outlined, size: 18),
          label: const Text('Add a location'),
          onPressed: () async {
            await showLocationEditor(context, provider, null);
            if (mounted) setState(() {});
          },
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _locationRow(
    AppStateProvider provider,
    RoomLocation location,
    ThemeData theme,
  ) {
    final here = provider.avNodes.where((n) => n.locationId == location.id);
    final jacks = here
        .where((n) => n.isJackField)
        .fold(0, (sum, n) => sum + n.ports.length);
    final devices = here.where((n) => !n.isJackField).length;

    return ListTile(
      dense: true,
      leading: Icon(kRoomZoneIcons[location.zone] ?? Icons.place),
      title: Text(location.displayName),
      subtitle: Text(
        [
          kRoomZoneLabels[location.zone] ?? location.zone.name,
          '$devices device${devices == 1 ? '' : 's'}',
          '$jacks jack${jacks == 1 ? '' : 's'}',
          // Named rather than counted: a marker belongs to a sheet, so "which
          // one" is the only useful form of "yes".
          if (provider.isLocationOnAnySheet(location.id))
            'on ${provider.sheetsShowing(location.id).map((p) => p.name).join(', ')}',
          if (location.note.isNotEmpty) location.note,
        ].join(' · '),
        style: theme.textTheme.bodySmall,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: 'Edit',
            onPressed: () async {
              await showLocationEditor(context, provider, location);
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Remove',
            onPressed: () async {
              // Removing a location unsets it on everything that named it, so
              // the count of what is about to lose its place is the number
              // worth confirming against.
              final using = devices + here.where((n) => n.isJackField).length;
              final ok = using == 0
                  ? true
                  : await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('Remove ${location.name}?'),
                        content: Text(
                          '$using item${using == 1 ? '' : 's'} '
                          '${using == 1 ? 'is' : 'are'} recorded here. '
                          '${using == 1 ? 'It' : 'They'} will be left with no '
                          'location rather than being deleted.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('Cancel'),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    );
              if (ok != true) return;
              provider.removeAvLocation(location.id);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  SCREEN / SHADE CONTROL RUNS
// ---------------------------------------------------------------------------

/// Adds or edits one control run. Returns true when something was saved.
Future<bool> showScreenSwitchEditor(
  BuildContext context,
  AppStateProvider provider,
  ScreenSwitch? existing,
) async {
  final labelController = TextEditingController(
    text: existing?.label ?? 'Front screen',
  );
  final startNoteController = TextEditingController(
    text: existing?.startNote ?? '',
  );
  final endNoteController = TextEditingController(text: existing?.endNote ?? '');
  final cableController = TextEditingController(
    text: existing?.cableType ?? kScreenSwitchCableTypes.first,
  );
  final feetController = TextEditingController(
    text: (existing?.runFeet ?? 0) <= 0
        ? ''
        : existing!.runFeet.toStringAsFixed(0),
  );
  final noteController = TextEditingController(text: existing?.note ?? '');
  String startLocation = existing?.startLocationId ?? kNoLocationId;
  String endLocation = existing?.endLocationId ?? kNoLocationId;

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(
          existing == null ? 'Add a control run' : 'Edit control run',
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A low-voltage run with two ends and no signal — the screen '
                  'switch by the door and the motor above the board. Neither '
                  'end is a box on the signal flow, so this is where it gets '
                  'recorded, costed and pulled.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: labelController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'What it controls',
                    hintText: 'e.g. Front screen, Rear shades',
                  ),
                ),
                const SizedBox(height: 14),
                Text('Start — the switch', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 6),
                _ScreenSwitchEnd(
                  provider: provider,
                  locationId: startLocation,
                  noteController: startNoteController,
                  hint: 'e.g. by the corridor door',
                  onChanged: (v) => setLocal(() => startLocation = v),
                ),
                const SizedBox(height: 14),
                Text(
                  'End — the screen or motor',
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                _ScreenSwitchEnd(
                  provider: provider,
                  locationId: endLocation,
                  noteController: endNoteController,
                  hint: 'e.g. above the whiteboard',
                  onChanged: (v) => setLocal(() => endLocation = v),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        initialValue:
                            kScreenSwitchCableTypes.contains(
                              cableController.text,
                            )
                            ? cableController.text
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Cable',
                          helperText: 'Or type your own below',
                        ),
                        items: [
                          for (final c in kScreenSwitchCableTypes)
                            DropdownMenuItem(value: c, child: Text(c)),
                        ],
                        onChanged: (v) =>
                            setLocal(() => cableController.text = v ?? ''),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: feetController,
                        decoration: const InputDecoration(
                          labelText: 'Run (ft)',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: cableController,
                  decoration: const InputDecoration(
                    labelText: 'Cable (as it should read on the report)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(existing == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    ),
  );

  if (saved != true) return false;

  final built = ScreenSwitch(
    id: existing?.id ?? '',
    label: labelController.text.trim().isEmpty
        ? 'Screen switch'
        : labelController.text.trim(),
    startLocationId: startLocation,
    startNote: startNoteController.text.trim(),
    endLocationId: endLocation,
    endNote: endNoteController.text.trim(),
    cableType: cableController.text.trim(),
    runFeet: double.tryParse(feetController.text.trim()) ?? 0,
    note: noteController.text.trim(),
  );

  if (existing == null) {
    provider.addAvScreenSwitch(built);
  } else {
    provider.updateAvScreenSwitch(built);
  }
  return true;
}

/// One end of a control run: a location if the room has one for it, and free
/// text when it doesn't. Both, because "the switch by the door" is rarely
/// somewhere that has earned a location of its own, and forcing one would mean
/// a location list full of single-use entries.
class _ScreenSwitchEnd extends StatelessWidget {
  final AppStateProvider provider;
  final String locationId;
  final TextEditingController noteController;
  final String hint;
  final ValueChanged<String> onChanged;

  const _ScreenSwitchEnd({
    required this.provider,
    required this.locationId,
    required this.noteController,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final known = {for (final l in provider.avLocations) l.id};
    final safe = known.contains(locationId) ? locationId : kNoLocationId;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            initialValue: safe,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Location'),
            items: [
              const DropdownMenuItem(
                value: kNoLocationId,
                child: Text('Describe it instead'),
              ),
              for (final l in provider.avLocations)
                DropdownMenuItem(value: l.id, child: Text(l.displayName)),
            ],
            onChanged: (v) => onChanged(v ?? kNoLocationId),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: TextField(
            controller: noteController,
            decoration: InputDecoration(
              labelText: 'Description',
              hintText: hint,
              // Only consulted when no location is named — saying so beats
              // leaving somebody to wonder which of the two ends up on the
              // report.
              helperText: safe.isEmpty ? null : 'Location above wins',
            ),
          ),
        ),
      ],
    );
  }
}
