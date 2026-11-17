import 'building_project.dart';
import 'cost_estimate.dart';
import 'procurement_log.dart';
import 'project_estimate.dart';
import 'project_schedule.dart' show formatScheduleDate;

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
  String manufacturer,
  String model,
  String partNumber,
  String category,
  String partKey,
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

/// Every item the job's rooms buy - equipment, rack hardware, cabling and
/// other items - room by room, each with its equipment-list part key.
List<ProcurementLine> procurementLinesOf(ProjectEstimate estimate) => [
  for (final room in estimate.rooms)
    if (room.ok && room.ref.included)
      for (final (kind, lines) in [
        (MasterPartKind.equipment, room.estimate!.equipment),
        (MasterPartKind.hardware, room.estimate!.hardware),
        (MasterPartKind.cabling, room.estimate!.cabling),
        (MasterPartKind.other, room.estimate!.extras),
      ])
        for (final line in lines)
          if (line.qty > 0)
            (
              roomId: room.ref.id,
              room: room.codeName,
              key: line.key,
              device: procurementDeviceName(line),
              manufacturer: line.manufacturer.trim(),
              model: line.model.trim(),
              partNumber: line.partNumber.trim(),
              category: line.category,
              partKey: masterPartKey(
                kind: kind.name,
                partNumber: line.partNumber,
                model: line.model,
                manufacturer: line.manufacturer,
                description: line.description,
              ),
            ),
];

/// What the job's order record says about [partKey], for the Ordered column.
String procurementOrderText(BuildingProject project, String partKey) {
  final order = partKey.isEmpty ? null : project.orderForPart(partKey);
  if (order == null) return '';
  // Installed without an order here: a contractor's, ready to go.
  if (!order.isOrdered) {
    return order.isInstalled
        ? 'Installed ${formatScheduleDate(order.installedOn!)}'
        : '';
  }
  final po = order.poNumber.trim();
  final on = formatScheduleDate(order.orderedOn!);
  final text = po.isEmpty ? on : '$po, $on';
  return [
    text,
    if (order.withoutQuote) 'no quote',
    if (order.isInstalled)
      'installed ${formatScheduleDate(order.installedOn!)}',
  ].join(', ');
}

/// What the delivery log says about [partKey], for the Delivered column:
/// how many of [needed] have arrived and when the last lot did.
String procurementDeliveryText(
  BuildingProject project,
  String partKey,
  double needed,
) {
  if (partKey.isEmpty) return '';
  final lots = [
    for (final d in project.deliveriesForPart(partKey))
      if (d.isOnHand) d,
  ];
  final order = project.orderForPart(partKey);
  if (lots.isEmpty) {
    return order != null && order.isReceived
        ? 'Received ${formatScheduleDate(order.receivedOn!)}'
        : '';
  }
  final got = project.deliveredOf(partKey, needed);
  final last = lots.first.deliveredOn;
  final count = needed > 0 && got < needed
      ? '${trimNumber(got)} of ${trimNumber(needed)}'
      : 'All ${trimNumber(got)}';
  return last == null ? count : '$count, ${formatScheduleDate(last)}';
}

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

/// The room line key [key] becomes when [fromModel] is swapped for [toModel],
/// or null when the swap does not touch it. Equipment lines are keyed by
/// model (see deviceGroupKey), so without this a swap leaves the log's line
/// on the old key and its status and dates behind.
String? swappedProcurementKey(String key, String fromModel, String toModel) {
  final from = fromModel.trim().toLowerCase();
  final to = toModel.trim().toLowerCase();
  if (from.isEmpty || to.isEmpty || from == to) return null;
  if (key == 'model:$from') return 'model:$to';
  if (key == 'nocost:model:$from') return 'nocost:model:$to';
  return null;
}

/// [entries] with every line in [roomIds] that followed [fromModel] moved to
/// [toModel]. A room already logging [toModel] keeps its own line, and the
/// old one is left as it was rather than doubling it.
List<ProcurementEntry> swapProcurementModel(
  List<ProcurementEntry> entries,
  Set<String> roomIds,
  String fromModel,
  String toModel,
) {
  final taken = {for (final e in entries) if (e.linked) '${e.roomId}|${e.lineKey}'};
  return [
    for (final e in entries)
      () {
        if (!e.linked || !roomIds.contains(e.roomId)) return e;
        final next = swappedProcurementKey(e.lineKey, fromModel, toModel);
        if (next == null || taken.contains('${e.roomId}|$next')) return e;
        return e.copyWith(lineKey: next);
      }(),
  ];
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
  final needed = {for (final m in estimate.master) m.key: m.qty};
  ProcurementEntry follow(ProcurementEntry e, String partKey) => e.copyWith(
    partKey: partKey,
    ordered: procurementOrderText(project, partKey),
    delivered: procurementDeliveryText(
      project,
      partKey,
      needed[partKey] ?? 0,
    ),
  );
  final covered = <String>{};
  final out = <ProcurementEntry>[];
  for (final raw in project.procurement) {
    // A line typed here that names a room line IS that line: linked in what
    // is shown (and stored on its next edit), so the room line is not listed
    // twice and the part takes its company. See matchProcurementLines.
    final match = raw.linked || raw.excluded
        ? null
        : estimate.procurementMatches[raw.id];
    final e = match == null
        ? raw
        : raw.copyWith(roomId: match.roomId, lineKey: match.lineKey);
    final line = e.linked ? lines[_linkOf(e.roomId, e.lineKey)] : null;
    if (e.linked) covered.add(_linkOf(e.roomId, e.lineKey));
    if (e.excluded) continue;
    // A line typed here is on the equipment list too - see
    // [ProjectEstimate.handLineKeys] - and follows that part's orders.
    final hand = e.linked ? null : estimate.handLineKeys[e.id];
    out.add(
      line == null
          ? (hand == null ? e : follow(e, hand))
          : follow(
              e.copyWith(
                room: line.room,
                device: line.device,
                manufacturer: line.manufacturer,
                model: line.model,
                partNumber: line.partNumber,
              ),
              line.partKey,
            ),
    );
  }
  for (final l in lines.values) {
    if (covered.contains(_linkOf(l.roomId, l.key))) continue;
    out.add(
      follow(
        ProcurementEntry(
          id: autoProcurementId(l.roomId, l.key),
          room: l.room,
          device: l.device,
          manufacturer: l.manufacturer,
          model: l.model,
          partNumber: l.partNumber,
          description: l.category,
          roomId: l.roomId,
          lineKey: l.key,
        ),
        l.partKey,
      ),
    );
  }
  return out;
}
