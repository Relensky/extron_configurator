import 'cost_estimate.dart';
import 'project_estimate.dart';
import 'report_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  PROJECT LABOR
/// ============================================================================
///  The job's labor read three ways: room by room, by job type (which rate
///  each crew is costed from), and by who provides it - the job paying for
///  it, our own staff in kind, or another department.
///
///  Built from the room estimates already in [ProjectEstimate], so these
///  figures always add up to the header's Labor total.
/// ============================================================================

/// Where an hourly rate comes from.
String _rateSource({required bool custom, required double rate}) =>
    custom ? 'Own rate' : (rate <= 0 ? 'No rate set' : 'Rate card');

String laborRateSource(LaborCostLine line) =>
    _rateSource(custom: line.customRate, rate: line.hourlyRate);

/// The provider label for labor the job pays for.
const String kLaborPaidByJob = 'Paid by this job';

/// Who provides a line: the job, or whoever gives it in kind.
String laborProvidedBy(LaborCostLine line) => line.furnishedBy == null
    ? kLaborPaidByJob
    : inKindSourceLabel(line.furnishedBy!);

/// A cost line charged with a crew - lumber, conduit, parts for the
/// contractor. See [CostEstimate.laborCharges].
class ProjectLaborFee {
  final String name;
  final String section;
  final double amount;

  /// The crew it is charged with.
  final LaborCostLine crew;

  const ProjectLaborFee({
    required this.name,
    required this.section,
    required this.amount,
    required this.crew,
  });
}

/// [estimate]'s labor charges, each with its crew.
List<ProjectLaborFee> laborFeesFor(CostEstimate estimate) {
  if (estimate.laborCharges.isEmpty) return const [];
  final crews = {
    for (final l in [...estimate.labor, ...estimate.optionalLabor]) l.id: l,
  };
  return [
    for (final c in estimate.laborCharges)
      if (crews[c.crewId] case final crew?)
        ProjectLaborFee(
          name: c.line.description.trim().isEmpty
              ? c.line.model
              : c.line.description.trim(),
          section: c.section,
          amount: c.line.total,
          crew: crew,
        ),
  ];
}

/// One room's labor.
class ProjectLaborRoom {
  final ProjectRoomCost room;

  /// Lines in the room's total.
  final List<LaborCostLine> lines;

  /// Optional lines listed apart, not in the total.
  final List<LaborCostLine> optional;

  /// Cost lines charged with this room's crews.
  final List<ProjectLaborFee> fees;

  ProjectLaborRoom({
    required this.room,
    required this.lines,
    this.optional = const [],
    this.fees = const [],
  });

  bool get included => room.ref.included;

  // Worked out once: the pane and the workbook read them several times.
  late final double total = lines.fold(0.0, (s, l) => s + l.total);
  late final double hours = lines.fold(0.0, (s, l) => s + l.totalHours);
  late final double crewHours = lines.fold(0.0, (s, l) => s + l.hours);

  /// What the in-kind hours are worth at their rates.
  late final double inKindValue = lines
      .where((l) => l.furnishedBy != null)
      .fold(0.0, (s, l) => s + l.listTotal);

  late final int unrated = lines.where((l) => l.unrated).length;

  /// The fees in the room's total.
  late final double feesTotal = room.estimate?.laborChargesIncluded == false
      ? 0
      : fees.fold(0.0, (s, f) => s + f.amount);

  /// The job types this room's crews are costed from, in order of first use.
  late final List<String> rateNames = {
    for (final l in [...lines, ...optional]) l.roleName,
  }.toList();
}

/// One job type across the counted rooms.
class ProjectLaborRate {
  final String roleName;
  final String rateId;
  final double hourlyRate;
  final bool customRate;
  double hours = 0;
  double total = 0;
  double inKindValue = 0;

  /// Cost lines charged with these crews.
  double fees = 0;

  /// Room code -> total hours on this job type.
  final Map<String, double> hoursByRoom = {};

  ProjectLaborRate({
    required this.roleName,
    required this.rateId,
    required this.hourlyRate,
    required this.customRate,
  });

  String get source => _rateSource(custom: customRate, rate: hourlyRate);
}

/// One provider - the job, our staff, another department - across the
/// counted rooms.
class ProjectLaborProvider {
  final String label;
  double hours = 0;
  double cost = 0;
  double value = 0;
  double fees = 0;

  /// Job type -> value at rate, hours and charged fees.
  final Map<String, double> costByRate = {};
  final Map<String, double> hoursByRate = {};
  final Map<String, double> feesByRate = {};

  /// Every job type this provider has hours or fees under.
  Iterable<String> get rateNames => {...hoursByRate.keys, ...feesByRate.keys};

  ProjectLaborProvider(this.label);

  bool get paid => label == kLaborPaidByJob;
}

class ProjectLaborSummary {
  final String currency;
  final List<ProjectLaborRoom> rooms;
  final List<ProjectLaborRate> rates;
  final List<ProjectLaborProvider> providers;

  ProjectLaborSummary({
    required this.currency,
    required this.rooms,
    required this.rates,
    required this.providers,
  });

  late final List<ProjectLaborRoom> counted = [
    for (final r in rooms)
      if (r.included) r,
  ];
  late final double total = counted.fold(0.0, (s, r) => s + r.total);
  late final double hours = counted.fold(0.0, (s, r) => s + r.hours);
  late final double crewHours = counted.fold(0.0, (s, r) => s + r.crewHours);
  late final double inKindValue = counted.fold(
    0.0,
    (s, r) => s + r.inKindValue,
  );
  late final int unrated = counted.fold(0, (s, r) => s + r.unrated);
  late final double feesTotal = counted.fold(0.0, (s, r) => s + r.feesTotal);
  bool get isEmpty =>
      rooms.every((r) => r.lines.isEmpty && r.optional.isEmpty);
}

ProjectLaborSummary projectLaborSummary(ProjectEstimate estimate) {
  final rooms = <ProjectLaborRoom>[];
  final rates = <String, ProjectLaborRate>{};
  final providers = <String, ProjectLaborProvider>{};

  for (final room in estimate.rooms) {
    final e = room.estimate;
    if (e == null) continue;
    final entry = ProjectLaborRoom(
      room: room,
      lines: e.labor,
      optional: e.optionalLabor,
      fees: laborFeesFor(e),
    );
    rooms.add(entry);
    if (!entry.included) continue;
    // Same job type at a different rate is a different row: the rate is
    // what the question is about.
    ProjectLaborRate rateFor(LaborCostLine l) => rates.putIfAbsent(
      '${l.rateId}|${l.roleName}|${l.hourlyRate}',
      () => ProjectLaborRate(
        roleName: l.roleName,
        rateId: l.rateId,
        hourlyRate: l.hourlyRate,
        customRate: l.customRate,
      ),
    );
    ProjectLaborProvider providerFor(LaborCostLine l) {
      final by = laborProvidedBy(l);
      return providers.putIfAbsent(by, () => ProjectLaborProvider(by));
    }

    for (final f in entry.fees) {
      // Not in the total, or with an optional crew outside it.
      if (!e.laborChargesIncluded || !e.labor.contains(f.crew)) continue;
      rateFor(f.crew)
        ..fees += f.amount
        ..hoursByRoom.putIfAbsent(room.codeName, () => 0);
      final who = providerFor(f.crew)..fees += f.amount;
      who.feesByRate.update(
        f.crew.roleName,
        (v) => v + f.amount,
        ifAbsent: () => f.amount,
      );
    }
    for (final l in e.labor) {
      final rate = rateFor(l);
      rate
        ..hours += l.totalHours
        ..total += l.total;
      if (l.furnishedBy != null) rate.inKindValue += l.listTotal;
      rate.hoursByRoom.update(
        room.codeName,
        (h) => h + l.totalHours,
        ifAbsent: () => l.totalHours,
      );

      final who = providerFor(l);
      who
        ..hours += l.totalHours
        ..cost += l.total
        ..value += l.listTotal;
      who.costByRate.update(
        l.roleName,
        (v) => v + l.listTotal,
        ifAbsent: () => l.listTotal,
      );
      who.hoursByRate.update(
        l.roleName,
        (v) => v + l.totalHours,
        ifAbsent: () => l.totalHours,
      );
    }
  }

  final rateList = rates.values.toList()
    ..sort((a, b) {
      final byTotal = (b.total + b.inKindValue + b.fees).compareTo(
        a.total + a.inKindValue + a.fees,
      );
      return byTotal != 0 ? byTotal : a.roleName.compareTo(b.roleName);
    });
  // The job's own spend first, then whoever gives it.
  final providerList = providers.values.toList()
    ..sort((a, b) {
      if (a.paid != b.paid) return a.paid ? -1 : 1;
      return b.value.compareTo(a.value);
    });

  return ProjectLaborSummary(
    currency: estimate.currency,
    rooms: rooms,
    rates: rateList,
    providers: providerList,
  );
}

/// How the Labor page orders its rooms.
enum LaborRoomSort {
  project('Project order'),
  name('Room name'),
  priority('Priority'),
  amount('Labor amount');

  final String label;
  const LaborRoomSort(this.label);
}

/// [rooms] in [sort] order. Priority 1 first, unprioritized last; labor
/// amount biggest first, counting in-kind value and charged fees; ties keep
/// project order.
List<ProjectLaborRoom> sortLaborRooms(
  List<ProjectLaborRoom> rooms,
  LaborRoomSort sort,
) {
  final order = {for (var i = 0; i < rooms.length; i++) rooms[i]: i};
  int rank(int p) => p <= 0 ? 1 << 30 : p;
  return [...rooms]..sort((a, b) {
    final by = switch (sort) {
      LaborRoomSort.project => 0,
      LaborRoomSort.name => a.room.codeName.toLowerCase().compareTo(
        b.room.codeName.toLowerCase(),
      ),
      LaborRoomSort.priority => rank(
        a.room.ref.priority,
      ).compareTo(rank(b.room.ref.priority)),
      LaborRoomSort.amount => (b.total + b.inKindValue + b.feesTotal)
          .compareTo(a.total + a.inKindValue + a.feesTotal),
    };
    return by != 0 ? by : order[a]!.compareTo(order[b]!);
  });
}

/// The workbook's Labor tab.
const String kProjectLaborSheet = 'Labor';

/// The Labor tab: by room, every line, by job type, by who provides it.
List<ReportSection> projectLaborSections(ProjectEstimate estimate) {
  final summary = projectLaborSummary(estimate);
  if (summary.isEmpty) return const [];
  XlsxMoney cash(double v) => money(v, summary.currency);
  final anyInKind = summary.providers.any((p) => !p.paid);
  final anyFees = summary.rooms.any((r) => r.fees.isNotEmpty);

  return [
    (
      title: 'By job type (department / contractor)',
      header: [
        'Job type',
        'Rate',
        'Rate from',
        'Rooms',
        'Total hours',
        'Cost',
        if (anyInKind) 'In kind value',
        if (anyFees) ...['Fees', 'Labor and fees'],
      ],
      rows: [
        for (final r in summary.rates)
          [
            r.roleName,
            cash(r.hourlyRate),
            r.source,
            r.hoursByRoom.keys.join(', '),
            r.hours,
            cash(r.total),
            if (anyInKind) cash(r.inKindValue),
            if (anyFees) ...[cash(r.fees), cash(r.total + r.fees)],
          ],
      ],
    ),
    (
      title: 'By who provides it',
      header: [
        'Provided by',
        'Job type',
        'Total hours',
        'Value at rate',
        'Cost to this job',
        if (anyFees) 'Fees',
      ],
      rows: [
        for (final p in summary.providers) ...[
          for (final rate in p.rateNames)
            [
              p.label,
              rate,
              p.hoursByRate[rate] ?? 0,
              cash(p.costByRate[rate] ?? 0),
              cash(p.paid ? p.costByRate[rate] ?? 0 : 0),
              if (anyFees) cash(p.feesByRate[rate] ?? 0),
            ],
          [
            '${p.label} total',
            '',
            p.hours,
            cash(p.value),
            cash(p.cost),
            if (anyFees) cash(p.fees),
          ],
        ],
      ],
    ),
    (
      title: 'Labor by room',
      header: [
        'Room',
        'Status',
        'Crew hours',
        'Total hours',
        'Labor cost',
        if (anyInKind) 'In kind value',
        if (anyFees) 'Fees',
        'Rates used',
      ],
      rows: [
        for (final r in summary.rooms)
          [
            r.room.codeName,
            r.included ? 'Included' : 'Excluded from total',
            r.crewHours,
            r.hours,
            cash(r.total),
            if (anyInKind) cash(r.inKindValue),
            if (anyFees) cash(r.feesTotal),
            r.rateNames.join(', '),
          ],
        [
          'Total',
          '',
          summary.crewHours,
          summary.hours,
          cash(summary.total),
          if (anyInKind) cash(summary.inKindValue),
          if (anyFees) cash(summary.feesTotal),
          '',
        ],
      ],
    ),
    if (anyFees)
      (
        title: 'Fees charged with labor',
        header: const [
          'Room',
          'Item',
          'From',
          'Job type',
          'Provided by',
          'Amount',
          'In the total',
        ],
        rows: [
          for (final r in summary.rooms)
            for (final f in r.fees)
              [
                r.room.codeName,
                f.name,
                f.section,
                f.crew.roleName,
                laborProvidedBy(f.crew),
                cash(f.amount),
                r.included && r.room.estimate?.laborChargesIncluded != false
                    ? 'Yes'
                    : 'No',
              ],
        ],
      ),
    (
      title: 'Every labor line, room by room',
      header: const [
        'Room',
        'Job type',
        'Rate from',
        'Description',
        'Techs',
        'Hours',
        'Total hours',
        'Rate',
        'Cost',
        'Provided by',
      ],
      rows: [
        for (final r in summary.rooms) ...[
          for (final l in r.lines)
            _lineRow(r, l, cash, r.included ? '' : ' (room excluded)'),
          for (final l in r.optional)
            _lineRow(r, l, cash, ' (optional, not in total)'),
        ],
      ],
    ),
  ];
}

List<dynamic> _lineRow(
  ProjectLaborRoom r,
  LaborCostLine l,
  XlsxMoney Function(double) cash,
  String note,
) => [
  r.room.codeName,
  l.roleName,
  laborRateSource(l),
  l.description,
  l.techs,
  l.hours,
  l.totalHours,
  cash(l.hourlyRate),
  cash(l.total),
  '${laborProvidedBy(l)}$note',
];
