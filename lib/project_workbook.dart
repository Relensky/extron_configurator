import 'dart:typed_data';

import 'av_device_library.dart';
import 'base_costs.dart';
import 'building_project.dart';
import 'control_gaps.dart';
import 'cost_estimate.dart';
import 'equipment_lifecycle.dart';
import 'project_estimate.dart';
import 'project_schedule.dart';
import 'report_tools.dart';
import 'responsibility_matrix.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE PROJECT WORKBOOK, AND THE QUOTE REQUESTS THAT COME OUT OF IT
/// ============================================================================
///  Two documents, built from the same rollup so they cannot disagree:
///
///  THE PROJECT WORKBOOK — everything, for the file and for the stakeholder:
///
///    Summary       — what the building costs, and the same figure broken back
///                    down to one row per room
///    Core Components — every part once, quantities merged across rooms, with the
///                    vendor it is tagged to and which rooms it is for
///    <Vendor>      — one tab per vendor: exactly what that company is being
///                    asked to quote
///    <Room>        — one tab per room, its own estimate in full
///
///  THE VENDOR RFQ — one .xlsx per vendor, holding only that vendor's parts.
///  This is the file that gets emailed, which is why it is a separate document
///  rather than "the workbook, tell them to look at tab six": sending the whole
///  book sends every other vendor's pricing to a competitor, and sends the
///  stakeholder's labor rates and margins to a supplier. A quote request contains
///  what is being asked for and nothing else.
///
///  Both are dealt from [ProjectEstimate], and the room tabs from the SAME
///  [costReportSections] the room's own Cost tab and room workbook use — so a
///  room's numbers are identical in the room's book and in the building's.
/// ============================================================================

/// The fixed sheets, in workbook order. Vendor and room tabs follow.
const List<String> kProjectWorkbookSheets = ['Summary', 'Core Components'];

/// The building-wide control-gap sheet, added only when there is something on
/// it. Named here so the tests and the tab-order check can agree on it.
const String kProjectControlSheet = 'Control Gaps';

/// The tab the spares answer lands on — what is spared, and what is not.
const String kProjectSparesSheet = 'Spares';

/// The tab purchasing works down: what to order, in the order to order it.
const String kProjectTimelineSheet = 'Order Timeline';

/// The paperwork and the pallets: what each PO bought, what has landed against
/// it, and where every lot is now. Added only when the job has a purchase
/// order or a delivery on it.
const String kProjectPurchasingSheet = 'Purchasing';

/// Whose job each piece of scope is. Added only when the matrix has lines on
/// it — a blank sheet headed "Roles and Responsibilities" in an issued
/// workbook reads as "nothing is anybody's job".
const String kProjectResponsibilitySheet = 'Responsibility';

/// The building's replacement plan: how old every room's equipment is and the
/// year each of it falls due. Added only when something on the job has been
/// dated.
const String kProjectLifecycleSheet = 'Replacement Plan';

/// Who changed what, and when. Added only when there is something on it.
///
/// ON THE WORKBOOK, NOT ON A QUOTE REQUEST. The workbook is the internal
/// document — it already carries labor rates and margins, which is exactly why
/// the vendor RFQ is a separate file — so an audit trail belongs on it. The
/// RFQ is built from the vendor package alone and cannot pick this up.
const String kProjectHistorySheet = 'History';

// ---------------------------------------------------------------------------
//  SECTIONS
// ---------------------------------------------------------------------------

/// What the building costs, and every room's share of it.
List<ReportSection> projectSummarySections(ProjectEstimate estimate) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);

  final project = estimate.project;

  final sections = <ReportSection>[
    (
      title: 'Project',
      header: const ['', ''],
      rows: [
        if (project.name.trim().isNotEmpty) ['Project', project.name],
        if (project.building.trim().isNotEmpty) ['Building', project.building],
        if (project.projectNumber.trim().isNotEmpty)
          ['Project number', project.projectNumber],
        if (project.stakeholder.trim().isNotEmpty)
          ['Stakeholder', project.stakeholder],
        ['Rooms quoted', estimate.costedRooms.length],
        if (project.deliveryDeadline != null)
          [
            'Delivery deadline',
            formatScheduleDate(project.deliveryDeadline!),
          ],
        // On the summary because it is a figure somebody decides about rather
        // than reads: a job with no spares on it is a decision, and one nobody
        // is asked to make is one that gets made by default.
        [
          'Spares',
          estimate.spareUnits == 0
              ? 'none on this job'
              : '${trimNumber(estimate.spareUnits)} unit'
                    '${estimate.spareUnits == 1 ? '' : 's'} across '
                    '${estimate.sparedParts.length} product'
                    '${estimate.sparedParts.length == 1 ? '' : 's'} '
                    '(${formatMoney(estimate.sparesTotal, currency)}) - '
                    'see the $kProjectSparesSheet sheet',
        ],
        if (project.rooms.length != estimate.costedRooms.length)
          [
            'Rooms not counted',
            '${project.rooms.length - estimate.costedRooms.length} '
                '(excluded or unreadable - see Rooms below)',
          ],
        if (project.notes.trim().isNotEmpty) ['Notes', project.notes],
      ],
    ),
    (
      title: 'Rooms',
      header: const [
        'Room',
        'Equipment',
        'Rack hardware',
        'Cabling',
        'Other items',
        'Labor hrs',
        'Labor',
        'Fees',
        'Tax',
        'Room total',
        'Status',
      ],
      rows: [
        for (final room in estimate.rooms)
          if (room.ok)
            [
              room.name,
              cash(room.estimate!.equipmentTotal),
              cash(room.estimate!.hardwareTotal),
              cash(room.estimate!.cablingTotal),
              cash(room.estimate!.extrasTotal),
              trimNumber(room.estimate!.laborHours),
              cash(room.estimate!.laborTotal),
              cash(room.estimate!.feeTotal),
              cash(room.estimate!.tax),
              cash(room.estimate!.grandTotal),
              _roomStatus(room),
            ]
          else
            // A room that could not be read still gets a row. A building whose
            // total is short by one room must say which one, in the same table
            // the total is in — a warning somewhere else gets skimmed past.
            [
              room.name,
              '', '', '', '', '', '', '', '',
              '',
              'NOT COUNTED - ${room.room.error}',
            ],
      ],
    ),
    (
      title: 'Building total',
      header: const ['', ''],
      rows: [
        ['Equipment', cash(estimate.equipmentTotal)],
        ['Rack hardware', cash(estimate.hardwareTotal)],
        ['Cabling', cash(estimate.cablingTotal)],
        ['Other items', cash(estimate.extrasTotal)],
        ['Parts subtotal', cash(estimate.partsTotal)],
        [
          'Labor (${trimNumber(estimate.laborHours)} hrs)',
          cash(estimate.laborTotal),
        ],
        ['Fees', cash(estimate.feeTotal)],
        ['Tax', cash(estimate.taxTotal)],
        ['PROJECT TOTAL', cash(estimate.grandTotal)],
      ],
    ),
  ];

  // Vendors get a summary block here as well as their own tabs: "who are we
  // buying from and for how much" is a question asked long before anybody
  // opens a per-vendor sheet, and it is the number that decides whether the
  // split is worth making at all.
  if (estimate.vendors.isNotEmpty) {
    sections.add((
      title: 'By vendor',
      header: const ['Vendor', 'Lines', 'Units', 'Parts total', 'Contact'],
      rows: [
        for (final p in estimate.vendors)
          [
            p.isUntagged ? 'UNTAGGED - no vendor rule matched' : p.name,
            p.lines.length,
            trimNumber(p.qty),
            cash(p.total),
            p.vendor?.contact ?? '',
          ],
        [
          'All parts',
          estimate.master.length,
          trimNumber(
            estimate.master.fold(0.0, (s, l) => s + l.qty),
          ),
          cash(estimate.partsTotal),
          '',
        ],
      ],
    ));
  }

  // THE DRAWINGS THE JOB WAS QUOTED AGAINST.
  //
  // On the summary rather than a sheet of its own, for the same reason the job
  // list below is: a drawing set is a handful of rows, and a tab nobody clicks
  // is a tab nobody reads.
  //
  // It is here at all because a quote is an answer to a QUESTION, and the
  // drawings are the question. "Which set was this priced from" is asked every
  // time a plan is reissued and a number stops matching, and up to now the
  // only answer was somebody's memory of an email.
  //
  // THE PATH AS STORED, not as resolved: it is what the project file says, so
  // a reader with the folder in front of them can follow it, and a reader
  // without it is not handed the absolute layout of somebody else's machine.
  // A file that has gone says so in the status column, exactly as an unreadable
  // room does in the Rooms table above.
  if (project.plans.isNotEmpty) {
    final missing = {for (final p in missingProjectPlans(estimate)) p.id};
    sections.add((
      title: 'Plans this job is quoted against (${project.plans.length})',
      header: const ['Sheet', 'File', 'Notes', 'Status'],
      rows: [
        for (final plan in project.plans)
          [
            plan.displayName,
            plan.filePath,
            plan.notes,
            missing.contains(plan.id)
                ? 'NOT FOUND - the file is not where the project says it is'
                : '',
          ],
      ],
    ));
  }

  // The job's own list, on the summary rather than a sheet of its own: it is
  // short, it is the thing somebody wants to see when they pick the job back
  // up, and a tab nobody clicks is a tab nobody reads. Open items only —
  // finished ones are history and belong on screen, not in a document that
  // gets sent out.
  final openTodos = project.openTodos;
  if (openTodos.isNotEmpty) {
    // The building code and number, the same as the tab shows — a note filed
    // against a room means the room on the door.
    //
    // Only here. The tables above are a QUOTE, and a quote says "Behavioral
    // And Social Science 103" because that is what the stakeholder calls it; a
    // job list is read by the people doing the work, who call it BSS 103.
    final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};
    // Dated items first, soonest due at the top — the same order the tab
    // shows them in, so the document and the screen agree about what matters.
    final ordered = [...openTodos]..sort((a, b) {
      final ad = a.due;
      final bd = b.due;
      if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
      if (ad == null && bd != null) return 1;
      if (ad != null && bd == null) return -1;
      return a.created.compareTo(b.created);
    });
    sections.add((
      title: 'Still to do on this job (${openTodos.length})',
      header: const ['Item', 'About', 'State', 'Due', 'Open since'],
      rows: [
        for (final t in ordered)
          [
            t.text,
            t.isWholeJob
                ? 'the job'
                : t.roomId.isNotEmpty
                    ? roomNames[t.roomId] ?? t.roomId
                    : t.scopeLabel,
            kProjectTodoStateLabels[t.state] ?? '',
            t.due == null
                ? ''
                // Late is spelled out rather than left to the reader to work
                // out from a date and today's date.
                : t.isOverdue()
                    ? '${formatScheduleDate(t.due!)} - PAST ITS DATE'
                    : formatScheduleDate(t.due!),
            formatScheduleDate(t.created),
          ],
      ],
    ));
  }

  final warnings = _projectWarnings(estimate);
  if (warnings.isNotEmpty) {
    sections.add((
      title: 'Check before this goes out',
      header: const ['Issue'],
      rows: [for (final w in warnings) [w]],
    ));
  }

  return sections;
}

/// Why a room's figure might not be what somebody expects. Blank when there is
/// nothing to say — a status column of "OK" on every row is noise.
String _roomStatus(ProjectRoomCost room) {
  final e = room.estimate!;
  final notes = <String>[
    if (!room.ref.included) 'EXCLUDED from the project total',
    if (room.room.isEmpty) 'nothing drawn yet',
    if (e.unpricedLines > 0)
      '${e.unpricedLines} line${e.unpricedLines == 1 ? '' : 's'} unpriced',
    if (e.unratedLabor > 0) '${e.unratedLabor} labor line at no rate',
    if (e.estimatedLines > 0) '${e.estimatedLines} at base cost (budgetary)',
    if (e.otherTierLines > 0) '${e.otherTierLines} priced at the other tier',
    if (e.excludedLines > 0) '${e.excludedLines} drawn but not bought',
    if (room.controlGaps.isNotEmpty)
      '${room.controlGaps.fold(0, (s, g) => s + g.qty)} device(s) with no '
          'control module',
    if (room.ref.notes.trim().isNotEmpty) room.ref.notes.trim(),
  ];
  return notes.join('; ');
}

/// The things that should stop a quote going out, in the order they matter.
List<String> _projectWarnings(ProjectEstimate estimate) {
  // Worked out once: every entry costs a stat of a file, and the list below
  // asks about it three times.
  final missingPlans = missingProjectPlans(estimate);
  return [
  if (estimate.failedRooms > 0)
    '${estimate.failedRooms} room${estimate.failedRooms == 1 ? '' : 's'} '
        'could not be read, so the project total is short by whatever '
        'they cost. See the Rooms table.',
  if (estimate.mixedCurrency)
    'Rooms in this project are quoted in different currencies. The totals '
        'add them as though they were the same one - fix the room currencies '
        'before relying on any figure here.',
  if (estimate.unpricedParts > 0)
    '${estimate.unpricedParts} part${estimate.unpricedParts == 1 ? '' : 's'} '
        'on the master list has no price anywhere. The total is short by '
        'whatever they cost.',
  if (estimate.untaggedParts > 0)
    '${estimate.untaggedParts} part'
        '${estimate.untaggedParts == 1 ? ' is' : 's are'} not tagged to any '
        'vendor, so '
        '${estimate.untaggedParts == 1 ? 'it is' : 'they are'} on no quote '
        'request. See the Untagged rows on Core Components.',
  // Not a pricing problem, and on the pricing sheet anyway. A building quoted
  // without anybody noticing that six of its boxes have no driver is a
  // building that arrives on site and cannot be commissioned, and the quote is
  // the document that actually gets read before that happens.
  if (estimate.undrivenDevices > 0)
    '${estimate.undrivenDevices} device'
        '${estimate.undrivenDevices == 1 ? '' : 's'} across '
        '${estimate.controlGaps.map((g) => g.room.ref.id).toSet().length} '
        'room(s) have no control module. They are quoted and they will not '
        'commission as they stand - see the $kProjectControlSheet sheet.',
  // Not a mistake, and not something the app should decide — but a building
  // where nothing at all is spared is a building where the first failure is
  // paid for out of a budget that has already closed, and nobody was ever
  // going to be reminded of that by a drawing.
  if (estimate.spareUnits == 0 && estimate.partsWithoutSpares.isNotEmpty)
    'Nothing on this job has a spare. '
        '${estimate.partsWithoutSpares.length} '
        'product${estimate.partsWithoutSpares.length == 1 ? '' : 's'} would '
        'be replaced out of the next budget rather than off the shelf - see '
        'the $kProjectSparesSheet sheet.',
  // The job's rule, broken: one spare of everything a room installs. Said as
  // a count of PARTS rather than as a percentage of the job, because it is the
  // parts somebody has to go and decide about.
  if (estimate.unsparedParts.isNotEmpty)
    '${estimate.unsparedParts.length} '
        'product${estimate.unsparedParts.length == 1 ? '' : 's'} '
        '${estimate.unsparedParts.length == 1 ? 'is' : 'are'} installed with '
        'nothing held spare - see the $kProjectSparesSheet sheet.',
  // Not a pricing problem either, and the last chance to catch it: the
  // workbook is usually built when the job is about to go somewhere, and a
  // drawing that has moved is found on the day it is wanted otherwise.
  if (missingPlans.isNotEmpty)
    '${missingPlans.length} building plan'
        '${missingPlans.length == 1 ? ' is' : 's are'} not where the project '
        'says ${missingPlans.length == 1 ? 'it is' : 'they are'} - see the '
        'Plans table above.',
  for (final c in estimate.project.vendorConflicts)
    '${c.kind} rule "${c.rule}" is claimed by '
        '${c.vendors.map((v) => v.name).join(' and ')}. '
        '${c.vendors.first.name} wins; the others never see those parts.',
  ];
}

/// Every part on the job, once, with the rooms it is for.
///
/// [roomNames] maps room id to the name shown in the breakdown column. Passed
/// in rather than looked up so the same names appear here, on the Summary and
/// on the room tabs.
List<ReportSection> masterPartsSections(
  ProjectEstimate estimate, {
  bool includeVendorColumn = true,
}) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final roomNames = {
    for (final r in estimate.rooms) r.ref.id: r.name,
  };

  /// "Bessey 101 ×2, Bessey 103 ×4" — which rooms the units are for.
  ///
  /// This is the column that makes a merged list checkable. Eighteen switchers
  /// is a number a vendor can quote; it is not a number a project manager can
  /// verify against a delivery, or split across two phases, without knowing
  /// where they go.
  String rooms(MasterPartLine line) => [
    for (final id in line.roomIdsByQty())
      '${roomNames[id] ?? id} ×${trimNumber(line.qtyByRoom[id] ?? 0)}',
  ].join(', ');

  String unit(MasterPartLine line) {
    if (line.unpriced) return 'not priced';
    if (!line.priceVaries) return formatMoney(line.unitPrice, currency);
    // Two rooms bought the same part at different prices — a negotiated
    // override in one of them. Printing either figure alone would look like
    // the answer, so it prints as the range it is.
    return '${formatMoney(line.unitPrice, currency)}'
        '-${formatMoney(line.maxUnitPrice, currency)}';
  }

  final sections = <ReportSection>[];

  for (final kind in MasterPartKind.values) {
    final lines = [for (final l in estimate.master) if (l.kind == kind) l];
    if (lines.isEmpty) continue;
    sections.add((
      title: kMasterPartKindLabels[kind]!,
      header: [
        'Part',
        'Manufacturer',
        'Model',
        'Part number',
        'Qty',
        // Spares are tagged ON the line rather than split onto one of their
        // own, because they are the same product at the same price — see the
        // Spares sheet for the job's whole answer. Blank rather than 0 on a
        // part nobody spared: a column of zeroes reads as a column of
        // decisions, and these are the opposite.
        'Spares',
        'For install',
        'Unit price',
        'Extended',
        if (includeVendorColumn) 'Vendor',
        if (includeVendorColumn) 'Tagged',
        // Blank on everything that is driven, and on everything that was never
        // going to be. A column of "OK" would be a column nobody reads.
        if (includeVendorColumn) 'Control',
        'Rooms',
      ],
      rows: [
        for (final l in lines)
          [
            l.description,
            l.manufacturer,
            l.model,
            l.partNumber,
            l.qty,
            l.hasSpares ? l.spareQty : '',
            l.hasSpares ? l.drawnQty : '',
            unit(l),
            cash(l.total),
            if (includeVendorColumn) l.vendor?.name ?? 'UNTAGGED',
            if (includeVendorColumn)
              kVendorTagSourceLabels[l.tagSource] ?? '',
            if (includeVendorColumn) _controlNote(l, roomNames),
            rooms(l),
          ],
      ],
    ));
  }

  if (sections.isEmpty) return const [];

  sections.add((
    title: 'Parts total',
    header: const ['', ''],
    rows: [
      for (final kind in MasterPartKind.values)
        if (estimate.master.any((l) => l.kind == kind))
          [
            kMasterPartKindLabels[kind]!,
            cash(estimate.master
                .where((l) => l.kind == kind)
                .fold(0.0, (s, l) => s + l.total)),
          ],
      ['ALL PARTS', cash(estimate.partsTotal)],
    ],
  ));

  return sections;
}

/// When each part has to be ordered, and what cannot be scheduled yet.
///
/// The Core Components list says what to buy; this says when. Kept as its own
/// set of sections because it is read by a different person for a different
/// reason — purchasing works down this in date order, and does not care which
/// vendor rule tagged what.
List<ReportSection> projectTimelineSections(
  ProjectEstimate estimate, {
  DateTime? asOf,
}) {
  final schedule = buildProjectSchedule(estimate: estimate, asOf: asOf);
  final sections = <ReportSection>[];

  sections.add((
    title: 'The dates',
    header: const ['', ''],
    rows: [
      [
        'Delivery deadline',
        schedule.deadline == null
            ? 'not set - nothing can be scheduled'
            : formatScheduleDate(schedule.deadline!),
      ],
      [
        'First order due',
        schedule.firstOrderDate == null
            ? '-'
            : formatScheduleDate(schedule.firstOrderDate!),
      ],
      ['Past their order date', schedule.lateCount],
      ['To order within $kOrderDueSoonDays days', schedule.dueSoonCount],
      ['No lead time recorded', schedule.unknownCount],
      ['On order', schedule.onOrderCount],
      if (schedule.arrivingLateCount > 0)
        [
          'On order but promised LATE',
          '${schedule.arrivingLateCount} - bought, and the room will not have '
              'them in time',
        ],
      ['Arrived', schedule.receivedCount],
      ['Worked out on', formatScheduleDate(schedule.asOf)],
    ],
  ));

  // The phases, when a job has split into them: each one's delivery date is
  // what its parts are worked back from, so a reader checking a date needs to
  // see them.
  if (estimate.project.tracks.isNotEmpty) {
    sections.add((
      title: 'Delivery phases',
      header: const ['Phase', 'On site by', 'Parts', 'First order', 'Notes'],
      rows: [
        for (final entry in schedule.byTrack(estimate.project))
          [
            entry.track?.name ?? 'With the job',
            // A phase with no date of its own falls back to the job's, and
            // says so — otherwise two phases print the same date and nothing
            // explains why.
            entry.track?.deadline != null
                ? formatScheduleDate(entry.track!.deadline!)
                : estimate.project.deliveryDeadline == null
                ? 'not set'
                : '${formatScheduleDate(estimate.project.deliveryDeadline!)}'
                      ' (from the job)',
            entry.parts.length,
            () {
              DateTime? first;
              for (final p in entry.parts) {
                final d = p.orderBy;
                if (d == null) continue;
                if (first == null || d.isBefore(first)) first = d;
              }
              return first == null ? '-' : formatScheduleDate(first);
            }(),
            entry.track?.notes ?? '',
          ],
      ],
    ));
  }

  // STILL TO BUY. A part already on order has no trip to purchasing left to
  // schedule, and leaving it here would put a date in front of somebody for an
  // order that went out last week. What HAS been bought gets its own table
  // below, because "is it bought" is the first thing anybody asks of this
  // sheet and a document that only lists what is outstanding cannot answer it.
  final dated = [
    for (final l in schedule.lines)
      if (l.orderBy != null && !l.isBought) l,
  ];
  if (dated.isNotEmpty) {
    sections.add((
      title: 'Order by',
      header: const [
        'Order by',
        'Part',
        'Qty',
        'Vendor',
        'Phase',
        'Lead time',
        'On site by',
        'Status',
      ],
      rows: [
        for (final l in dated)
          [
            formatScheduleDate(l.orderBy!),
            l.line.description,
            l.line.qty,
            l.line.vendor?.name ?? 'UNTAGGED',
            l.trackName,
            formatLeadTime(l.leadDays),
            // The early ones are called out: a part wanted ahead of the job is
            // the thing somebody has to remember.
            l.needByIsOwn
                ? '${formatScheduleDate(l.needBy!)} (ahead of the job)'
                : formatScheduleDate(l.needBy!),
            '${kOrderStatusLabels[l.status]} - '
                '${formatDayGap(l.daysUntilOrder ?? 0)}',
          ],
      ],
    ));
  }

  // What has been bought, and whether it is going to make it.
  final bought = [for (final l in schedule.lines) if (l.isBought) l];
  if (bought.isNotEmpty) {
    sections.add((
      title: 'Bought (${bought.length})',
      header: const [
        'Part',
        'Qty',
        'Vendor',
        'PO',
        'Ordered',
        'Vendor promised',
        'On site by',
        'Arrived',
        'Status',
      ],
      rows: [
        for (final l in bought)
          [
            l.line.description,
            l.line.qty,
            l.line.vendor?.name ?? 'UNTAGGED',
            l.order?.poNumber ?? '',
            l.order?.orderedOn == null
                ? ''
                : formatScheduleDate(l.order!.orderedOn!),
            l.order?.expectedOn == null
                ? ''
                : formatScheduleDate(l.order!.expectedOn!),
            l.needBy == null ? '' : formatScheduleDate(l.needBy!),
            l.order?.receivedOn == null
                ? ''
                : formatScheduleDate(l.order!.receivedOn!),
            // Spelled out rather than left to be worked out from two dates:
            // an order placed on time against a promise that lands after the
            // room needs it is the thing this table exists to surface.
            l.status == OrderStatus.arrivingLate
                ? 'ON ORDER - PROMISED AFTER IT IS NEEDED'
                : kOrderStatusLabels[l.status] ?? '',
          ],
      ],
    ));
  }

  // Listed rather than left out. A timeline that silently omits the parts
  // nobody has a lead time for reads as complete while being the opposite.
  final unscheduled = [
    for (final l in schedule.lines)
      if (l.orderBy == null && !l.isBought) l,
  ];
  if (unscheduled.isNotEmpty) {
    sections.add((
      title: 'Cannot be scheduled yet (${unscheduled.length})',
      header: const ['Part', 'Qty', 'Vendor', 'What is missing'],
      rows: [
        for (final l in unscheduled)
          [
            l.line.description,
            l.line.qty,
            l.line.vendor?.name ?? 'UNTAGGED',
            l.status == OrderStatus.noDeadline
                ? 'no delivery date for this part or the job'
                : 'nobody has asked the vendor how long it takes',
          ],
      ],
    ));
  }

  return sections;
}

/// The paperwork and the pallets: what was bought on each purchase order, what
/// has turned up against it, and where every lot of it is now.
///
/// THE QUESTION THIS SHEET ANSWERS IS ASKED BY SOMEBODY STANDING IN A
/// CORRIDOR. The Order Timeline says what to buy and when; it stops at the day
/// a part arrives, and the weeks between the loading dock and the finished room
/// are where a job actually loses things. Eighteen wall plates arrive in March,
/// six go into 103 in April, and in June the workbook that was filed is the
/// only record of whether the other twelve are in a basement or were never
/// delivered at all.
///
/// ONE ROW PER LOT, NOT PER PART. A part that turned up in three shipments is
/// three rows, each with its own date, its own quantity and its own place,
/// because that is what happened and a single "received" tick cannot hold it.
///
/// THE PO IS THE SPINE. Every table here is filed under the number the vendor,
/// the finance system and the packing slip all already use — see [ProjectPo] —
/// so a PO on this sheet can be read straight against the paperwork in
/// somebody's hand.
List<ReportSection> projectPurchasingSections(ProjectEstimate estimate) {
  final project = estimate.project;
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final lines = {for (final m in estimate.master) m.key: m};
  final vendorNames = {for (final v in project.vendors) v.id: v.name};
  final roomNames = estimate.roomCodeNames;

  /// Who a PO went to: the vendor row it points at, or whatever was typed.
  String vendorOf(ProjectPo po) =>
      vendorNames[po.vendorId] ?? po.vendor.trim();

  /// What a part is called, as the job calls it now. A key that has dropped
  /// off the master list still prints — as the key — rather than vanishing:
  /// the PO bought it, and a purchase that no longer matches the equipment
  /// list is the single most useful thing this sheet can say.
  String partName(String key) => lines[key]?.description ?? key;

  final sections = <ReportSection>[];

  // Every PO number the job mentions anywhere, not just the rows somebody
  // entered: a number typed onto a part or read off a packing slip is a PO
  // this sheet has to account for. See [BuildingProject.poNumbersInUse].
  final numbers = project.poNumbersInUse;

  if (numbers.isNotEmpty) {
    sections.add((
      title: 'Purchase orders (${numbers.length})',
      header: const [
        'PO',
        'Vendor',
        'Raised',
        'Vendor promised',
        'Raised for',
        'Parts on it',
        'Marked arrived',
        'Deliveries logged',
        'Units landed',
      ],
      rows: [
        for (final number in numbers)
          () {
            final po = project.poByNumber(number);
            final parts = project.partsOnPo(number);
            final landed = project.deliveriesForPo(number);
            var units = 0.0;
            for (final d in landed) {
              if (d.isOnHand) units += d.qty;
            }
            return [
              number,
              po == null ? '' : vendorOf(po),
              po?.issuedOn == null ? '' : formatScheduleDate(po!.issuedOn!),
              po?.expectedOn == null ? '' : formatScheduleDate(po!.expectedOn!),
              (po?.amount ?? 0) > 0 ? cash(po!.amount) : '',
              parts.length,
              [
                for (final key in parts)
                  if (project.orderForPart(key)?.isReceived == true) key,
              ].length,
              landed.length,
              units == 0 ? '' : trimNumber(units),
            ];
          }(),
      ],
    ));
  }

  // WHAT EACH ONE BOUGHT. The Order Timeline's bought table is filed under the
  // PART, which is the right way round for "has this been ordered" and the
  // wrong way round for "what is on PO-1188" — the question somebody rings up
  // with, holding the PO.
  final byPo = <List<dynamic>>[];
  for (final number in numbers) {
    for (final key in project.partsOnPo(number)) {
      final order = project.orderForPart(key);
      final line = lines[key];
      byPo.add([
        number,
        partName(key),
        line == null ? '' : trimNumber(line.qty),
        line?.vendor?.name ?? '',
        order?.orderedOn == null ? '' : formatScheduleDate(order!.orderedOn!),
        order?.expectedOn == null ? '' : formatScheduleDate(order!.expectedOn!),
        order?.receivedOn == null ? '' : formatScheduleDate(order!.receivedOn!),
        trimNumber(project.deliveredQty(key)),
      ]);
    }
  }
  if (byPo.isNotEmpty) {
    sections.add((
      title: 'What each PO bought (${byPo.length})',
      header: const [
        'PO',
        'Part',
        'Qty on the job',
        'Vendor',
        'Ordered',
        'Vendor promised',
        'Marked arrived',
        'Units logged in',
      ],
      rows: byPo,
    ));
  }

  // What was bought on a card, and what was bought against nothing anybody
  // has written down. Worked out here because the rollup below counts them
  // and the tables at the foot of the sheet list them.
  final oneOffs = project.oneOffDeliveries;
  final loose = project.deliveriesNeedingPaperwork;

  // WHERE IT IS. Newest first, the way the pane reads and the way anybody
  // scanning for "what landed this week" reads it.
  final deliveries = [...project.deliveries]..sort((a, b) {
    final ad = a.deliveredOn;
    final bd = b.deliveredOn;
    if (ad == null && bd == null) return b.id.compareTo(a.id);
    if (ad == null) return 1;
    if (bd == null) return -1;
    final byDate = bd.compareTo(ad);
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });

  if (deliveries.isNotEmpty) {
    sections.add((
      title: 'Deliveries (${deliveries.length}, newest first)',
      header: const [
        'Arrived',
        'What',
        'Qty',
        'Bought on',
        'Where it is',
        'Delivered to / held at',
        'Room',
        'Installed',
        'Notes',
      ],
      rows: [
        for (final d in deliveries)
          [
            d.deliveredOn == null ? '' : formatScheduleDate(d.deliveredOn!),
            d.itemName.trim().isEmpty
                ? (d.partKey.isEmpty
                      ? 'not on the equipment list'
                      : partName(d.partKey))
                : d.itemName.trim(),
            d.qty == 0 ? '' : trimNumber(d.qty),
            // WHAT BOUGHT IT, in one column with three answers. A PO number;
            // a card purchase that was never going to have one; or a row
            // nobody has said anything about, which is called out in capitals
            // rather than left as a blank cell that reads as "no data".
            d.poNumber.trim().isNotEmpty
                ? d.poNumber.trim()
                : d.oneOff
                ? 'One-off - P-Card'
                : 'NOT RECORDED',
            d.state.label,
            // The ADDRESS, in its own column rather than folded into the
            // state: 'delivered' with nowhere after it is the answer that
            // sends somebody walking round a campus looking for a pallet.
            d.location.trim(),
            roomNames[d.roomId] ?? '',
            d.installedOn == null ? '' : formatScheduleDate(d.installedOn!),
            // One per line, so a lot with three notes on it reads as three
            // lines in one cell rather than as one paragraph.
            [
              for (final n in d.notes)
                '${formatIsoDate(n.at)} ${n.user.isEmpty ? '' : '${n.user}: '}'
                    '${n.text}',
            ].join('\n'),
          ],
      ],
    ));

    // THE ROLLUP. The tables above are read a row at a time; this is the
    // paragraph somebody quotes in a meeting.
    var onHand = 0.0;
    var installed = 0.0;
    var stored = 0.0;
    var returned = 0.0;
    for (final d in deliveries) {
      if (!d.isOnHand) {
        returned += d.qty;
        continue;
      }
      onHand += d.qty;
      if (d.isInstalled) {
        installed += d.qty;
      } else if (d.state == DeliveryState.stored) {
        stored += d.qty;
      }
    }
    sections.add((
      title: 'Where the kit is',
      header: const ['', ''],
      rows: [
        ['Units delivered and still the job\'s', trimNumber(onHand)],
        ['In a room', trimNumber(installed)],
        ['In storage', trimNumber(stored)],
        ['On site, nowhere named', trimNumber(onHand - installed - stored)],
        ['Sent back', trimNumber(returned)],
        if (oneOffs.isNotEmpty)
          ['Deliveries bought outside the PO process', oneOffs.length],
        if (loose.isNotEmpty)
          ['Deliveries on no PO and not marked one-off', loose.length],
        for (final place in project.deliveryLocations)
          [
            'At $place',
            trimNumber(
              deliveries
                  .where(
                    (d) =>
                        d.isOnHand &&
                        !d.isInstalled &&
                        d.location.trim() == place,
                  )
                  .fold<double>(0, (sum, d) => sum + d.qty),
            ),
          ],
      ],
    ));
  }

  // BOUGHT OUTSIDE THE PROCESS. Its own table because it is the spend nothing
  // else in this app knows about: a card purchase is on no estimate, in no
  // vendor package and on no purchase order, and "what did we buy outside the
  // process" is a question somebody in finance asks at the end of a job.
  if (oneOffs.isNotEmpty) {
    sections.add((
      title: 'Bought outside the PO process (${oneOffs.length})',
      header: const [
        'Arrived',
        'What',
        'Qty',
        'Where it is',
        'Delivered to / held at',
        'Room',
        'Notes',
      ],
      rows: [
        for (final d in oneOffs)
          [
            d.deliveredOn == null ? '' : formatScheduleDate(d.deliveredOn!),
            d.itemName.trim().isEmpty
                ? (d.partKey.isEmpty
                      ? 'not on the equipment list'
                      : partName(d.partKey))
                : d.itemName.trim(),
            d.qty == 0 ? '' : trimNumber(d.qty),
            d.state.label,
            d.location.trim(),
            roomNames[d.roomId] ?? '',
            [
              for (final n in d.notes)
                '${formatIsoDate(n.at)} ${n.user.isEmpty ? '' : '${n.user}: '}'
                    '${n.text}',
            ].join('\n'),
          ],
      ],
    ));
  }

  // AND THE ONES THAT SAY NOTHING. Listed rather than left in the log to be
  // found by reading it: a row with no PO and no card behind it cannot be
  // reconciled against an order, an invoice or a statement, and a document
  // that quietly carries three of them reads as complete while being the
  // opposite. See [ProjectDelivery.needsPaperwork].
  if (loose.isNotEmpty) {
    sections.add((
      title: 'Arrived against nothing (${loose.length})',
      header: const ['Arrived', 'What', 'Qty', 'Where it is', 'What is missing'],
      rows: [
        for (final d in loose)
          [
            d.deliveredOn == null ? '' : formatScheduleDate(d.deliveredOn!),
            d.itemName.trim().isEmpty
                ? (d.partKey.isEmpty
                      ? 'not on the equipment list'
                      : partName(d.partKey))
                : d.itemName.trim(),
            d.qty == 0 ? '' : trimNumber(d.qty),
            d.whereText,
            'no PO, and not marked as a one-off purchase',
          ],
      ],
    ));
  }

  // The commentary a PO attracts, signed. Its own table rather than a column,
  // because these are written by several people over several weeks and the
  // name and the date on each are the reason they are worth keeping.
  final poNotes = <List<dynamic>>[];
  for (final po in project.purchaseOrders) {
    for (final n in po.notes) {
      poNotes.add([
        formatIsoDate(n.at),
        po.number.trim().isEmpty ? 'PO' : po.number.trim(),
        n.text,
        n.user,
      ]);
    }
  }
  if (poNotes.isNotEmpty) {
    poNotes.sort((a, b) => b[0].toString().compareTo(a[0].toString()));
    sections.add((
      title: 'What has been said about the purchase orders (${poNotes.length})',
      header: const ['Date', 'PO', 'Note', 'By'],
      rows: poNotes,
    ));
  }

  return sections;
}

/// Every recorded change on this job, newest first.
///
/// The document answer to the question the History pane answers on screen:
/// "this says four weeks, it said eight in March — who changed it, and when".
/// A workbook filed at the end of a job is what somebody reads a year later,
/// and a file holding only the current values cannot settle that.
///
/// One row per change, with the item NAMED as it read at the time. A part that
/// has since been renamed or dropped off the job still reads correctly here,
/// which is the whole point of storing the name with the entry rather than
/// resolving it when the sheet is written.
List<ReportSection> projectHistorySections(ProjectEstimate estimate) {
  final entries = estimate.project.recentHistory;
  if (entries.isEmpty) return const [];

  return [
    (
      title: 'Changes (${entries.length}, newest first)',
      header: const ['Date', 'Time', 'Item', 'Kind', 'What', 'Change', 'By'],
      rows: [
        for (final e in entries)
          [
            formatIsoDate(e.at),
            // 24 hour, so the sheet sorts and reads the same on both sides of
            // the Atlantic.
            '${e.at.hour.toString().padLeft(2, '0')}:'
                '${e.at.minute.toString().padLeft(2, '0')}',
            e.itemName,
            e.itemKind,
            e.field,
            e.summary,
            // A blank login is left blank rather than dressed up as a name.
            e.user,
          ],
      ],
    ),
    (
      title: 'Who has worked on this job',
      header: const ['Login', 'Changes'],
      rows: [
        for (final user in estimate.project.historyUsers)
          [
            user,
            entries
                .where((e) => e.user.toLowerCase() == user.toLowerCase())
                .length,
          ],
        if (entries.any((e) => e.user.isEmpty))
          [
            '(not recorded)',
            entries.where((e) => e.user.isEmpty).length,
          ],
      ],
    ),
  ];
}

/// The job's spares: what is spared, how many, and what is NOT.
///
/// Two tables, and the second is the one worth having. A list of the spares
/// somebody remembered to ask for reads as a job with spares on it; the list of
/// products with none is the one that turns into a decision — and it is the
/// list nothing in this app was ever going to produce on its own, because a
/// spare is not on any drawing and nothing was ever going to notice its
/// absence.
///
/// Equipment only in the second table, deliberately. Nobody wants a report
/// nagging about a spare blanking plate, and a list long enough to include them
/// is a list whose real rows — the boxes with power supplies in them — go
/// unread.
List<ReportSection> projectSparesSections(ProjectEstimate estimate) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.name};

  /// Which rooms asked for the spares — "who wanted this" is the question
  /// that follows every spare on a quote somebody is trimming.
  String askedBy(MasterPartLine line) => [
    for (final id in line.spareRoomIdsByQty())
      '${roomNames[id] ?? id} ×${trimNumber(line.spareByRoom[id] ?? 0)}',
  ].join(', ');

  final spared = estimate.sparedParts;
  final without = estimate.partsWithoutSpares;
  final sections = <ReportSection>[];

  sections.add((
    title: 'Spares on this job',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'Part number',
      'Spares',
      'For install',
      'Total bought',
      'Unit price',
      'Spares cost',
      'Asked for by',
    ],
    rows: spared.isEmpty
        ? [
            [
              'Nothing on this job is spared.',
              '', '', '', '', '', '', '', '', '',
            ],
          ]
        : [
            for (final l in spared)
              [
                l.description,
                l.manufacturer,
                l.model,
                l.partNumber,
                l.spareQty,
                l.drawnQty,
                l.qty,
                l.unpriced ? 'not priced' : formatMoney(l.unitPrice, currency),
                cash(l.spareQty * l.unitPrice),
                askedBy(l),
              ],
          ],
  ));

  // HOW MUCH OF THE JOB IS SPARED, part by part. The table above says what
  // was asked for; this one says whether it is enough, which is the question
  // the first table cannot be read for - "two spare projectors" is a row
  // nobody can approve until they know two out of how many.
  final cover = estimate.spareCover;
  sections.add((
    title: estimate.unsparedParts.isEmpty
        ? 'Spare cover, part by part'
        : 'Spare cover, part by part '
              '(${estimate.unsparedParts.length} with no spare)',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'Installed',
      'Spares',
      'Cover',
      'Any spare',
    ],
    rows: cover.isEmpty
        ? [
            ['Nothing on this job is installed yet.', '', '', '', '', '', ''],
          ]
        : [
            for (final c in cover)
              [
                c.line.description,
                c.line.manufacturer,
                c.line.model,
                c.installed,
                c.spares,
                // A percentage as text rather than as a number: the column
                // holds "5%" beside "0%", and a spreadsheet that formatted one
                // of them as 0.05 would be read as five units.
                formatSpareCover(c.coverage),
                c.short ? 'none' : 'yes',
              ],
          ],
  ));

  sections.add((
    title: 'Equipment with NO spare (${without.length})',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'Part number',
      'Units on the job',
      'Unit price',
      'One spare would cost',
      'Rooms',
    ],
    rows: without.isEmpty
        ? [
            ['Every product on this job has a spare.', '', '', '', '', '', '', ''],
          ]
        : [
            for (final l in without)
              [
                l.description,
                l.manufacturer,
                l.model,
                l.partNumber,
                l.qty,
                l.unpriced ? 'not priced' : formatMoney(l.unitPrice, currency),
                l.unpriced ? '' : cash(l.unitPrice),
                [
                  for (final id in l.roomIdsByQty())
                    '${roomNames[id] ?? id} '
                        '×${trimNumber(l.qtyByRoom[id] ?? 0)}',
                ].join(', '),
              ],
          ],
  ));

  // THE BUILDING'S OWN, which no room's table can carry: a switcher on a shelf
  // for the campus belongs to no room, and the figure it is approved on is not
  // its price but its COVERAGE. Two spare projectors is a number nobody can
  // weigh until they know two out of how many.
  final shelf = estimate.buildingSpares;
  sections.add((
    title: 'Spares for the building (${shelf.length})',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'On the shelf',
      'Installed on the job',
      'Coverage',
      'Cost',
      'A spare for',
    ],
    rows: shelf.isEmpty
        ? [
            [
              'Nothing is spared for the building as a whole.',
              '', '', '', '', '', '', '',
            ],
          ]
        : [
            for (final row in shelf)
              [
                row.line.description,
                row.line.manufacturer,
                row.line.model,
                row.qty,
                row.installed,
                // A part no room is having covers nothing measurable, and
                // both '0%' and 'infinity%' would be saying something untrue.
                row.coverage == null
                    ? 'nothing installed'
                    : '${(row.coverage! * 100).toStringAsFixed(
                        row.coverage! >= 0.1 ? 0 : 1,
                      )}%',
                cash(row.cost),
                [
                  for (final id in row.roomIds)
                    '${roomNames[id] ?? id} '
                        '×${trimNumber(row.line.qtyByRoom[id] ?? 0)}',
                ].join(', '),
              ],
          ],
  ));

  // WHOSE SPARES THEY ARE. The two tables above are per PART, which is what a
  // vendor is quoting; this one is per ROOM, which is what gets approved or
  // trimmed. A spares bill nobody can break back down to a room is one that
  // gets cut whole because no one could defend any part of it.
  final byRoom = estimate.sparesByRoom;
  sections.add((
    title: 'Spares by room (${byRoom.length})',
    header: const [
      'Room',
      'Spare units',
      'Products spared',
      'Spares cost',
      'What was spared',
    ],
    rows: byRoom.isEmpty
        ? [
            ['No room on this job asked for a spare.', '', '', '', ''],
          ]
        : [
            for (final r in byRoom)
              [
                r.name,
                r.units,
                r.parts,
                cash(r.cost),
                [
                  for (final l in estimate.sparedPartsForRoom(r.roomId))
                    '${l.description} '
                        '×${trimNumber(l.spareByRoom[r.roomId] ?? 0)}',
                ].join(', '),
              ],
          ],
  ));

  sections.add((
    title: 'Spares total',
    header: const ['', ''],
    rows: [
      ['Products with a spare', spared.length],
      ['Equipment with none', without.length],
      ['Spare units bought', estimate.spareUnits],
      // Split out because the two are approved by different people: a room's
      // spare is that room's contingency, and the building's is the job's.
      ['Of those, for the building', estimate.buildingSpareUnits],
      ['Spares cost', cash(estimate.sparesTotal)],
      ['Of that, for the building', cash(estimate.buildingSparesTotal)],
    ],
  ));

  return sections;
}

/// What the master list's Control column says for one part: nothing when every
/// one of them has a driver, otherwise how many do not and where.
///
/// The rooms are named rather than counted. "3 undriven" is a number somebody
/// has to go and investigate; "no module: Bessey 101 ×2, Bessey 105 ×1" is a
/// list they can work through.
String _controlNote(MasterPartLine line, Map<String, String> roomNames) {
  if (!line.hasControlGap) return '';
  final where = line.undrivenByRoom.entries.toList()
    ..sort((a, b) {
      final byQty = b.value.compareTo(a.value);
      return byQty != 0 ? byQty : a.key.compareTo(b.key);
    });
  return 'no module: ${[
    for (final e in where) '${roomNames[e.key] ?? e.key} ×${e.value}',
  ].join(', ')}';
}

/// Every device on the job that no control module will drive, room by room.
///
/// The building's version of the sheet a room's own AV and Cost exports carry,
/// built from the same rule (control_gaps.dart) so the two cannot disagree
/// about which devices are undriven.
///
/// Room first in the sort, because this list is worked THROUGH: somebody opens
/// one room, fixes everything on it, and moves to the next. Sorted by device it
/// would be a list that sends them back and forth across the building.
List<ReportSection> projectControlGapSections(ProjectEstimate estimate) {
  if (estimate.controlGaps.isEmpty) return const [];

  final byKind = <ControlGapKind, int>{};
  for (final entry in estimate.controlGaps) {
    byKind[entry.gap.kind] = (byKind[entry.gap.kind] ?? 0) + entry.gap.qty;
  }

  return [
    (
      title: 'Devices Without a Control Module',
      header: const ['Room', 'Device', 'Model', 'Qty', 'From', 'Note'],
      rows: [
        for (final entry in estimate.controlGaps)
          [
            entry.room.name,
            entry.gap.device,
            entry.gap.model.isEmpty ? '(no model set)' : entry.gap.model,
            entry.gap.qty,
            entry.gap.sourceLabel,
            entry.gap.note,
          ],
      ],
    ),
    (
      title: 'What needs doing',
      header: const ['', ''],
      rows: [
        if ((byKind[ControlGapKind.moduleUnset] ?? 0) > 0)
          [
            'Pick the module',
            '${byKind[ControlGapKind.moduleUnset]} device(s) - a module '
                'already claims the model; the field is just empty.',
          ],
        if ((byKind[ControlGapKind.noModuleClaims] ?? 0) > 0)
          [
            'No driver exists',
            '${byKind[ControlGapKind.noModuleClaims]} device(s) - write or '
                'import a module, or mark the product as never controlled on '
                'the Catalog tab if it genuinely has no interface.',
          ],
        if ((byKind[ControlGapKind.noModel] ?? 0) > 0)
          [
            'Choose a model',
            '${byKind[ControlGapKind.noModel]} device(s) have no model, so '
                'nothing can be matched to them.',
          ],
        if ((byKind[ControlGapKind.notDrawn] ?? 0) > 0)
          [
            'In the config, not on the drawing',
            '${byKind[ControlGapKind.notDrawn]} device(s) - undriven and not '
                'on the signal flow either.',
          ],
        ['Total', '${estimate.undrivenDevices} device(s)'],
      ],
    ),
  ];
}

/// One vendor's quote request: what they are being asked to price, and where
/// it goes.
///
/// Deliberately NOT a copy of the master list filtered down. It carries no
/// labor, no fees, no tax, no other vendor's parts and no project total —
/// those are the stakeholder's numbers, and a quote request that leaks them is
/// a negotiating position handed to a supplier.
List<ReportSection> vendorPackageSections(
  ProjectEstimate estimate,
  VendorPackage package,
) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final project = estimate.project;
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.name};

  String rooms(MasterPartLine line) => [
    for (final id in line.roomIdsByQty())
      '${roomNames[id] ?? id} ×${trimNumber(line.qtyByRoom[id] ?? 0)}',
  ].join(', ');

  final sections = <ReportSection>[
    (
      title: 'Quote request',
      header: const ['', ''],
      rows: [
        ['Vendor', package.name],
        if ((package.vendor?.contact ?? '').isNotEmpty)
          ['Contact', package.vendor!.contact],
        if (project.name.trim().isNotEmpty) ['Project', project.name],
        if (project.building.trim().isNotEmpty) ['Building', project.building],
        if (project.projectNumber.trim().isNotEmpty)
          ['Project number', project.projectNumber],
        ['Line items', package.lines.length],
        ['Total units', trimNumber(package.qty)],
        if ((package.vendor?.notes ?? '').isNotEmpty)
          ['Notes', package.vendor!.notes],
      ],
    ),
  ];

  for (final kind in MasterPartKind.values) {
    final lines = [for (final l in package.lines) if (l.kind == kind) l];
    if (lines.isEmpty) continue;
    sections.add((
      title: kMasterPartKindLabels[kind]!,
      header: const [
        'Item',
        'Manufacturer',
        'Model',
        'Part number',
        'Qty',
        // The prices we HOLD, so a returned quote can be compared against
        // them line by line. A blank column would make the sheet unreadable
        // on the way back in, which is the half of an RFQ that matters.
        'Our estimate (unit)',
        'Our estimate (ext)',
        // Left empty on purpose: this is where the vendor writes.
        'Your unit price',
        'Your extended',
        'Lead time',
        'Rooms',
      ],
      rows: [
        for (final l in lines)
          [
            l.description,
            l.manufacturer,
            l.model,
            l.partNumber,
            l.qty,
            l.unpriced ? '' : cash(l.unitPrice),
            l.unpriced ? '' : cash(l.total),
            '',
            '',
            '',
            rooms(l),
          ],
      ],
    ));
  }

  return sections;
}

// ---------------------------------------------------------------------------
//  THE BOOKS
// ---------------------------------------------------------------------------

/// The whole project: summary, master list, a tab per vendor, a tab per room.
Uint8List buildProjectWorkbookBytes({
  required ProjectEstimate estimate,
  DateTime? generated,

  /// The catalog and the base card, for pricing the replacement plan. Both
  /// optional because the estimate does not carry either and a caller that
  /// only wants the quote should not have to find them — without them the plan
  /// still says WHEN each room falls due, and simply prices nothing.
  AvDeviceLibrary? library,
  BaseCostBook? baseCosts,
  PricingTier tier = PricingTier.msrp,
}) {
  final stamp = generated ?? DateTime.now();
  final title = _projectTitle(estimate.project);

  // Vendor and room names become tab names, and both are free text the user
  // typed. Excel refuses a book with two sheets of one name and refuses one
  // whose names run past 31 characters — and "Behavioral and Social Science
  // 101" and "...102" clip to the same thing — so every name goes through the
  // same settling the location report's per-drawing tabs use.
  final taken = <String>{};
  String tab(String proposed) => uniqueXlsxSheetName(proposed, taken);

  final sheets = <XlsxSheet>[
    buildStackedReportSheet(
      sheetName: tab(kProjectWorkbookSheets[0]),
      title: title,
      sections: projectSummarySections(estimate),
      generated: stamp,
    ),
  ];

  final master = masterPartsSections(estimate);
  if (master.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectWorkbookSheets[1]),
      title: '$title - core components list',
      sections: master,
      generated: stamp,
    ));
  }

  // Purchasing works down this in date order and does not care which vendor
  // rule tagged what, so it is a sheet rather than more columns on the parts
  // list.
  if (estimate.master.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectTimelineSheet),
      title: '$title - when to order',
      sections: projectTimelineSections(estimate, asOf: stamp),
      generated: stamp,
    ));
  }

  // Its own sheet rather than a block at the foot of the parts list: "what is
  // not spared" is a list of things that are NOT on the order, and a table of
  // absences buried under a table of purchases is a table nobody reads.
  if (estimate.master.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectSparesSheet),
      title: '$title - spares',
      sections: projectSparesSections(estimate),
      generated: stamp,
    ));
  }

  // WHAT WAS BOUGHT AND WHERE IT IS. Its own sheet next to the timeline,
  // because the two are the same job read at two different moments: the
  // timeline is what has to be ordered, this is what was ordered and what
  // came of it. Written only when there is something to write — a blank sheet
  // headed "Purchasing" in an issued workbook reads as a job nobody has
  // bought anything for.
  final purchasing = projectPurchasingSections(estimate);
  if (purchasing.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectPurchasingSheet),
      title: '$title - purchase orders and deliveries',
      sections: purchasing,
      generated: stamp,
    ));
  }

  final gaps = projectControlGapSections(estimate);
  if (gaps.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectControlSheet),
      title: '$title - devices without a control module',
      sections: gaps,
      generated: stamp,
    ));
  }

  // Whose job each piece of scope is. On the workbook because it is agreed
  // with the contractor off the same document the quantities are read from,
  // and a matrix that only exists as a separate file is one that goes out of
  // step with the rooms the moment either changes.
  final matrix = responsibilityMatrixSections(
    estimate.project.responsibility,
    roomNames: estimate.project.responsibilityRoomColumns(
      names: estimate.roomCodeNames,
    ),
  );
  if (matrix.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectResponsibilitySheet),
      title: '$title - roles and responsibilities',
      sections: matrix,
      generated: stamp,
    ));
  }

  // The job AFTER this one: what is already in the building, and the year it
  // has to come out. On the workbook because that is the document a budget
  // request is assembled from, and beside the order timeline because the two
  // are the same calendar read forward and back.
  final lifecycle = buildingLifecycleSections(
    buildProjectLifecycle(
      estimate: estimate,
      library: library,
      baseCosts: baseCosts,
      tier: tier,
      asOf: stamp,
    ),
  );
  if (lifecycle.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectLifecycleSheet),
      title: '$title - when it has to be replaced',
      sections: lifecycle,
      generated: stamp,
    ));
  }

  // After the job's own sheets and before the vendor tabs: it is a record
  // about the JOB, and it should not push the tabs somebody actually sends
  // anywhere further along than they already are.
  final changes = projectHistorySections(estimate);
  if (changes.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectHistorySheet),
      title: '$title - who changed what',
      sections: changes,
      generated: stamp,
    ));
  }

  for (final package in estimate.vendors) {
    sheets.add(buildStackedReportSheet(
      // The vendor's name is the tab, so the book is navigable by the thing
      // somebody is looking for.
      sheetName: tab(package.isUntagged ? 'Untagged' : package.name),
      title: '$title - ${package.name}',
      sections: vendorPackageSections(estimate, package),
      generated: stamp,
    ));
  }

  // Every room that priced, including the excluded ones: an alternate that is
  // out of the total is still work somebody did and still gets read.
  for (final room in estimate.rooms) {
    if (!room.ok) continue;
    final sections = costReportSections(room.estimate!);
    if (sections.isEmpty) continue;
    sheets.add(buildStackedReportSheet(
      sheetName: tab(room.name),
      title: room.ref.included
          ? room.name
          : '${room.name} - EXCLUDED from the project total',
      sections: sections,
      generated: stamp,
    ));
  }

  return buildXlsx(sheets);
}

/// One vendor's quote request, as its own file.
Uint8List buildVendorRfqBytes({
  required ProjectEstimate estimate,
  required VendorPackage package,
  DateTime? generated,
}) => buildXlsx([
  buildStackedReportSheet(
    sheetName: xlsxSheetName(
      package.isUntagged ? 'Untagged' : package.name,
    ),
    title: '${_projectTitle(estimate.project)} - quote request',
    sections: vendorPackageSections(estimate, package),
    generated: generated ?? DateTime.now(),
  ),
]);

/// What the documents are headed with: the project name, the building, or
/// failing both something that is at least not blank.
String _projectTitle(BuildingProject project) {
  final name = project.name.trim();
  final building = project.building.trim();
  if (name.isNotEmpty && building.isNotEmpty && name != building) {
    return '$name - $building';
  }
  if (name.isNotEmpty) return name;
  if (building.isNotEmpty) return building;
  return 'Project';
}

/// A file name stem for one vendor's RFQ, safe on every platform: the project
/// and the vendor, so a folder of them can be read without opening any.
String vendorRfqFileStem(BuildingProject project, VendorPackage package) {
  String clean(String s) => s
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
  final job = clean(
    project.name.trim().isNotEmpty ? project.name : project.building,
  );
  final vendor = clean(package.name);
  final stem = [
    if (job.isNotEmpty) job,
    if (vendor.isNotEmpty) vendor,
    'RFQ',
  ].join('_');
  return stem.isEmpty ? 'RFQ' : stem;
}
