import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'av_device_library.dart';
import 'building_project.dart';
import 'cost_compare.dart' show CostItemSet;
import 'cost_estimate.dart' show CostLineItem;
import 'export_tools.dart' show roomFolderName;

/// A room [addCatalogEntryToRoom] can put a part in.
typedef RoomChoice = ({String name, String configPath});

/// The rooms a catalog entry can go into right now: the open room, then the
/// open job's other rooms. Empty with neither open.
List<RoomChoice> roomChoicesFor(AppStateProvider p) {
  final out = <RoomChoice>[];
  final open = p.roomConfig.isNotEmpty;
  if (open) {
    out.add((
      name: 'This room - ${roomFolderName(p)}',
      configPath: p.currentConfigPath,
    ));
  }
  if (p.hasOpenProject) {
    for (final r in p.project.includedRooms) {
      final abs = BuildingProject.resolvePath(r.configPath, p.currentProjectPath);
      if (open && _same(abs, p.currentConfigPath)) continue;
      out.add((name: p.projectRoomLogName(r.id), configPath: abs));
    }
  }
  return out;
}

bool _same(String a, String b) =>
    a.replaceAll('/', '\\').toLowerCase() == b.replaceAll('/', '\\').toLowerCase();

/// [entry] as a line of the kind it is: equipment, rack hardware, cable, or
/// an item off the catalog.
CostItemSet costItemSetFor(AvDeviceTemplate entry, double qty) {
  final line = CostLineItem(
    id: 'CAT_1',
    description: entry.model,
    category: entry.category,
    qty: qty,
    catalogModel: entry.model,
    manufacturer: entry.manufacturer,
    partNumber: entry.partNumber,
  );
  if (entry.isCable) return CostItemSet(extraCables: [line]);
  if (entry.isRackHardware) return CostItemSet(extraHardware: [line]);
  if (entry.isMiscItem || entry.isConsumable) return CostItemSet(items: [line]);
  return CostItemSet(extraEquipment: [line]);
}

/// Asks which room and how many, then puts [entry] on that room's estimate:
/// the open room live (with Undo), another room by writing its cost file.
Future<void> addCatalogEntryToRoom(
  BuildContext context,
  AppStateProvider provider,
  AvDeviceTemplate entry,
) async {
  final rooms = roomChoicesFor(provider);
  if (rooms.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final qty = TextEditingController(text: '1');
  var pick = rooms.first;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        key: const ValueKey('catalog_add_to_room_dialog'),
        title: Text('Add ${entry.model} to a room'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rooms.length > 1)
                DropdownButtonFormField<RoomChoice>(
                  key: const ValueKey('catalog_add_room_pick'),
                  initialValue: pick,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Room'),
                  items: [
                    for (final r in rooms)
                      DropdownMenuItem(
                        value: r,
                        child: Text(r.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setLocal(() => pick = v ?? pick),
                )
              else
                Text(rooms.single.name),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('catalog_add_qty'),
                controller: qty,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'How many'),
              ),
              const SizedBox(height: 8),
              Text(
                'Quoted on the room\'s Cost page, priced from the catalog.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('catalog_add_go'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;
  final n = double.tryParse(qty.text.trim()) ?? 1;
  final added = await provider.addCostItemsToRoomFile(
    pick.configPath,
    costItemSetFor(entry, n <= 0 ? 1 : n),
  );
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(
        added < 0
            ? 'That room\'s cost file could not be written - nothing was added.'
            : '${entry.model} added to ${pick.name}.',
      ),
    ),
  );
}
