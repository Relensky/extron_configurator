import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import 'app_state.dart';
import 'cost_compare.dart';
import 'room_presets.dart';

/// App Config > Shared lists: the room presets and cost presets on the
/// shared Root Folder, with where they live and a way to delete one.
class PresetLibraryPanel extends StatefulWidget {
  final AppStateProvider provider;
  const PresetLibraryPanel({super.key, required this.provider});

  @override
  State<PresetLibraryPanel> createState() => _PresetLibraryPanelState();
}

class _PresetLibraryPanelState extends State<PresetLibraryPanel> {
  List<RoomPreset> _rooms = const [];
  List<CostPreset> _costs = const [];

  @override
  void initState() {
    super.initState();
    _read();
  }

  /// Both folders, read as the page is drawn - a handful of small files.
  void _read() {
    _rooms = widget.provider.availableRoomPresets();
    _costs = loadCostPresetsSync(widget.provider.effectiveRootFolder);
  }

  void _load() => setState(_read);

  Future<void> _open(String folder) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Directory(folder).create(recursive: true);
    } catch (_) {}
    final error = await widget.provider.openInDesktop(folder);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _delete(String name, String file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: Text(
          'Removes ${path.basename(file)} from the shared folder for '
          'everybody. Rooms already made from it keep what they have.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('preset_delete_go'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!deletePresetFile(file)) {
      messenger.showSnackBar(
        SnackBar(content: Text('"$name" could not be deleted - see the log.')),
      );
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final root = widget.provider.effectiveRootFolder;

    Widget folderRow(String label, String folder, int count) => Row(
      children: [
        Expanded(
          child: Text(
            '$label - $count in $folder',
            style: theme.textTheme.bodySmall,
          ),
        ),
        TextButton.icon(
          icon: const Icon(Icons.folder_open, size: 16),
          label: const Text('Open folder'),
          onPressed: () => _open(folder),
        ),
      ],
    );

    Widget tile({
      required String keyName,
      required IconData icon,
      required String title,
      required String subtitle,
      required String file,
    }) =>
        ListTile(
          key: ValueKey('preset_row_$keyName'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, size: 20),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: file.isEmpty
              ? null
              : IconButton(
                  key: ValueKey('preset_delete_$keyName'),
                  tooltip: 'Delete this preset',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _delete(title, file),
                ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Room and cost presets',
                  style: theme.textTheme.titleSmall),
            ),
            IconButton(
              tooltip: 'Read the folders again',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _load,
            ),
          ],
        ),
        Text(
          'Kept under the Root Folder, so everybody using it shares them. '
          'Save a room with File > Save Room as Preset, and a cost page '
          'with Cost items > Save as cost preset.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ...[
          folderRow(
            'Room presets',
            path.join(root, kRoomPresetFolder),
            _rooms.length,
          ),
          for (final p in _rooms)
            tile(
              keyName: 'room_${p.name}',
              icon: Icons.meeting_room_outlined,
              title: p.name,
              subtitle: [
                if (p.description.isNotEmpty) p.description,
                p.summary,
                if (p.builtIn) 'built in',
                if (p.savedBy.isNotEmpty) 'saved by ${p.savedBy}',
              ].join(' · '),
              file: p.file,
            ),
          const SizedBox(height: 8),
          folderRow(
            'Cost presets',
            path.join(root, kCostPresetFolder),
            _costs.length,
          ),
          for (final p in _costs)
            tile(
              keyName: 'cost_${p.name}',
              icon: Icons.request_quote_outlined,
              title: p.name,
              subtitle: [
                if (p.description.isNotEmpty) p.description,
                p.items.summary,
                if (p.savedBy.isNotEmpty) 'saved by ${p.savedBy}',
              ].join(' · '),
              file: p.file,
            ),
        ],
      ],
    );
  }
}
