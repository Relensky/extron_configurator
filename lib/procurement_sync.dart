import 'building_project.dart';
import 'cost_estimate.dart';
import 'procurement_log.dart';
import 'project_estimate.dart';

/// ============================================================================
///  THE LOG FOLLOWS THE ROOMS
/// ============================================================================
///  A procurement line typed as text goes stale the day a part is renamed or
///  swapped on the job. So a line can be LINKED to the room line it is about,
///  and then what the log shows for its room and device is read off the job
///  every time - on the page, in the picture and in the spreadsheet.
///
///  Every piece of equipment and hardware on a room is on the log whether or
///  not anybody has touched it: a room line with no entry yet is shown as one
///  with nothing filled in, and becomes a stored entry the first time it is
///  edited. Nothing is written to the project just by looking.
/// ============================================================================

/// One thing a room buys, as the log names it.
typedef ProcurementLine = ({
  String roomId,
  String room,
  String key,
  String device,
  String category,
});

/// What the log calls a room line: the name it has on the estimate, with its
/// maker in front when the name does not already say it.
String procurementDeviceName(CostLine line) {
  final maker = line.manufacturer.trim();
  final named = line.description.trim().isNotEmpty
      ? line.description.trim()
      : line.model.trim();
  if (maker.isEmpty) return named;
  if (named.isEmpty) return maker;
  return named.toLowerCase().contains(maker.toLowerCase())
      ? named
      : '$maker $named';
}

/// Every equipment and hardware line on the job's rooms, room by room.
List<ProcurementLine> procurementLinesOf(ProjectEstimate estimate) => [
  for (final room in estimate.rooms)
    if (room.ok && room.ref.included)
      for (final line in [
        ...room.estimate!.equipment,
        ...room.estimate!.hardware,
      ])
        (
          roomId: room.ref.id,
          room: room.codeName,
          key: line.key,
          device: procurementDeviceName(line),
          category: line.category,
        ),
];

String _linkOf(String roomId, String key) => '$roomId\u0000$key';

/// The id of a room line that has no stored entry yet.
String autoProcurementId(String roomId, String key) => 'auto:$roomId:$key';

/// True for an entry that is shown but not stored - see [liveProcurement].
bool procurementIsAuto(ProcurementEntry entry) => entry.id.startsWith('auto:');

/// True when [entry] follows a room line that is no longer on the job.
bool procurementIsOrphan(ProcurementEntry entry, ProjectEstimate estimate) {
  if (!entry.linked) return false;
  return !procurementLinesOf(estimate).any(
    (l) => l.roomId == entry.roomId && l.key == entry.lineKey,
  );
}

/// The log as it stands today: the stored entries with their room and device
/// read off the job, then every room line nobody has an entry for.
///
/// Entries taken off the log on purpose are left out, and so are the room
/// lines they name.
List<ProcurementEntry> liveProcurement(
  BuildingProject project,
  ProjectEstimate estimate,
) {
  final lines = {
    for (final l in procurementLinesOf(estimate)) _linkOf(l.roomId, l.key): l,
  };
  final covered = <String>{};
  final out = <ProcurementEntry>[];
  for (final e in project.procurement) {
    final line = e.linked ? lines[_linkOf(e.roomId, e.lineKey)] : null;
    if (e.linked) covered.add(_linkOf(e.roomId, e.lineKey));
    if (e.excluded) continue;
    out.add(
      line == null ? e : e.copyWith(room: line.room, device: line.device),
    );
  }
  for (final l in lines.values) {
    if (covered.contains(_linkOf(l.roomId, l.key))) continue;
    out.add(
      ProcurementEntry(
        id: autoProcurementId(l.roomId, l.key),
        room: l.room,
        device: l.device,
        description: l.category,
        roomId: l.roomId,
        lineKey: l.key,
      ),
    );
  }
  return out;
}
