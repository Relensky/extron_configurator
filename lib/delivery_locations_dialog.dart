import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_port_editor.dart' show avRowIcon;
import 'contrast.dart';
import 'delivery_locations.dart';
import 'live_text_field.dart';

/// ============================================================================
///  THE DELIVERY LOCATION EDITOR
/// ============================================================================
///  The docks a truck can back up to and the rooms gear is held in, set up
///  once and then one click away on every delivery. Same shape as the base
///  cost card and the rate card, and for the same reason: a loading dock is a
///  fact about the estate rather than about one job.
///
///  The file is meant to be SHARED. Point the path on App Config at a drive
///  everybody reads and the whole shop logs deliveries against the same names,
///  which is the only thing that makes "everything at Central Stores" a
///  question a job can answer.
///
///  It never restricts a delivery. A row's location stays free text; this is
///  what the picker offers, not what it allows.
/// ============================================================================

Future<void> showDeliveryLocationsDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (_) => const DeliveryLocationsDialog(),
    );

class DeliveryLocationsDialog extends StatefulWidget {
  const DeliveryLocationsDialog({super.key});

  @override
  State<DeliveryLocationsDialog> createState() =>
      _DeliveryLocationsDialogState();
}

class _DeliveryLocationsDialogState extends State<DeliveryLocationsDialog> {
  /// Edits are in memory until Save, exactly as the rate cards work, so a
  /// half-typed address is not on everybody's share yet.
  bool _dirty = false;

  final TextEditingController _newName = TextEditingController();

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? snackErrorFill(context) : null,
      ),
    );
  }

  void _edit(AppStateProvider provider, DeliveryLocation place) {
    provider.deliveryLocations.upsert(place);
    setState(() => _dirty = true);
    provider.deliveryLocationsChanged();
  }

  void _add(AppStateProvider provider) {
    final name = _newName.text.trim();
    if (name.isEmpty) return;
    if (provider.deliveryLocations.byName(name) != null) {
      _snack('$name is already on the list.');
      return;
    }
    provider.deliveryLocations.add(name: name);
    _newName.clear();
    setState(() => _dirty = true);
    provider.deliveryLocationsChanged();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final book = provider.deliveryLocations;
    final theme = Theme.of(context);

    return AlertDialog(
      key: const ValueKey('delivery_locations_dialog'),
      title: Row(
        children: [
          const Text('Delivery locations'),
          const SizedBox(width: 12),
          if (_dirty)
            Chip(
              // A chip that overrides its fill has to override its ink: the
              // theme's label color was measured against the default fill.
              label: Text(
                'Unsaved',
                style: TextStyle(
                  color: errorTextOn(
                    theme.colorScheme,
                    theme.colorScheme.errorContainer,
                  ),
                ),
              ),
              backgroundColor: theme.colorScheme.errorContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 880,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The places a truck delivers to and the rooms gear is held in. '
              'The name is what gets written onto a delivery; the address is '
              'looked up here rather than retyped onto every row. Deliveries '
              'can still be logged to a place that is not on this list.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 230,
                  child: Text('Name', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 170,
                  child: Text('Used for', style: theme.textTheme.labelSmall),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 200,
                  child: Text(
                    'Address or room',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Anything the driver needs',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 108),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  if (book.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'No places saved yet. Add the docks a truck can reach '
                        'and the rooms gear waits in, and every delivery can '
                        'be filed against one of them in a click.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  for (final place in book.places)
                    Padding(
                      key: ValueKey('delivery_location_row_${place.id}'),
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 230,
                            child: LiveTextField(
                              fieldId: 'locname_${place.id}',
                              initial: place.name,
                              hint: 'MLIB loading dock',
                              onChanged: (v) =>
                                  _edit(provider, place.copyWith(name: v)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 170,
                            child: DropdownButtonFormField<DeliveryLocationUse>(
                              key: ValueKey('locuse_${place.id}'),
                              initialValue: place.use,
                              isExpanded: true,
                              decoration: const InputDecoration(isDense: true),
                              items: [
                                for (final u in DeliveryLocationUse.values)
                                  DropdownMenuItem(
                                    value: u,
                                    child: Text(
                                      u.label,
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) => v == null
                                  ? null
                                  : _edit(provider, place.copyWith(use: v)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 200,
                            child: LiveTextField(
                              fieldId: 'locaddr_${place.id}',
                              initial: place.address,
                              hint: '1 Campus Drive',
                              onChanged: (v) =>
                                  _edit(provider, place.copyWith(address: v)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LiveTextField(
                              fieldId: 'locnote_${place.id}',
                              initial: place.notes,
                              hint: 'hours, who to ring, which door',
                              onChanged: (v) =>
                                  _edit(provider, place.copyWith(notes: v)),
                            ),
                          ),
                          // THE ORDER IS THE ORDER THEY ARE OFFERED IN, so the
                          // two places most deliveries go to belong at the top
                          // and it has to be possible to put them there.
                          avRowIcon(
                            Icons.arrow_upward,
                            'Move up',
                            () {
                              provider.deliveryLocations
                                  .move(place.id, up: true);
                              setState(() => _dirty = true);
                              provider.deliveryLocationsChanged();
                            },
                          ),
                          avRowIcon(
                            Icons.arrow_downward,
                            'Move down',
                            () {
                              provider.deliveryLocations
                                  .move(place.id, up: false);
                              setState(() => _dirty = true);
                              provider.deliveryLocationsChanged();
                            },
                          ),
                          avRowIcon(
                            Icons.delete_outline,
                            'Remove this place',
                            () {
                              provider.deliveryLocations.remove(place.id);
                              setState(() => _dirty = true);
                              provider.deliveryLocationsChanged();
                            },
                            danger: true,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 230,
                        child: TextField(
                          key: const ValueKey('delivery_location_new'),
                          controller: _newName,
                          decoration: const InputDecoration(
                            labelText: 'New place',
                            hintText: 'e.g. Central Stores',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _add(provider),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        key: const ValueKey('delivery_location_add'),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add'),
                        onPressed: () => _add(provider),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    book.source.isEmpty ? 'Not saved yet' : book.source,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${book.count} place${book.count == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('Load...'),
          onPressed: () => _load(provider),
        ),
        TextButton.icon(
          icon: const Icon(Icons.save_as, size: 18),
          label: const Text('Save as...'),
          onPressed: () => _saveAs(provider),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ElevatedButton(
          key: const ValueKey('delivery_locations_save'),
          onPressed: () async {
            final saved = await provider.saveDeliveryLocations();
            if (saved.isEmpty) {
              _snack('Could not save the delivery locations.', error: true);
              return;
            }
            setState(() => _dirty = false);
            _snack('Delivery locations saved to $saved');
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _load(AppStateProvider provider) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Open a delivery location list',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    await provider.loadDeliveryLocations(explicitPath: path);
    if (!mounted) return;
    setState(() => _dirty = false);
    _snack('Loaded ${provider.deliveryLocations.count} places from $path');
  }

  Future<void> _saveAs(AppStateProvider provider) async {
    String? output = await FilePicker.saveFile(
      dialogTitle: 'Save the delivery locations as',
      fileName: 'delivery_locations.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (output == null) return;
    if (!output.toLowerCase().endsWith('.json')) output += '.json';
    final saved = await provider.deliveryLocations.save(toPath: output);
    if (!mounted) return;
    if (saved.isEmpty) {
      _snack('Could not write the delivery locations.', error: true);
      return;
    }
    setState(() => _dirty = false);
    provider.deliveryLocationsChanged();
    showSavedFileSnack(context, provider, 'Delivery locations', saved);
  }
}
