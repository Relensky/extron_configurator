import 'package:material_ui/material_ui.dart';

import 'cost_estimate.dart';
import 'project_estimate.dart';
import 'project_labor.dart';

/// ============================================================================
///  LABOR PANE
/// ============================================================================
///  Every room's labor and the rates it is costed from, then the same hours
///  by job type and by who provides them. Read-only: crews are edited on the
///  room's own Cost tab.
/// ============================================================================

List<Widget> laborSlivers(
  BuildContext context,
  ProjectEstimate estimate, {
  LaborRoomSort sort = LaborRoomSort.project,
  ValueChanged<LaborRoomSort>? onSort,
}) {
  final summary = projectLaborSummary(estimate);
  final rooms = sortLaborRooms(summary.rooms, sort);
  final currency = summary.currency;
  String cash(double v) => formatMoney(v, currency);

  if (summary.isEmpty) {
    return const [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 32, 16, 24),
          child: Center(
            child: Text(
              'No labor on this job yet. Add crews on each room\'s Cost tab.',
              key: ValueKey('project_labor_empty'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ];
  }

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Stat(label: 'Labor cost', value: cash(summary.total)),
                _Stat(
                  label: 'Total hours',
                  value: trimNumber(summary.hours),
                ),
                _Stat(
                  label: 'Crew hours',
                  value: trimNumber(summary.crewHours),
                ),
                if (summary.inKindValue > 0)
                  _Stat(label: 'In kind', value: cash(summary.inKindValue)),
                if (summary.feesTotal > 0) ...[
                  _Stat(
                    label: 'Fees charged with labor',
                    value: cash(summary.feesTotal),
                  ),
                  _Stat(
                    label: 'Labor and fees',
                    value: cash(summary.total + summary.feesTotal),
                  ),
                ],
                if (summary.unrated > 0)
                  _Stat(
                    label: 'No rate set',
                    value: '${summary.unrated} '
                        '${summary.unrated == 1 ? 'line' : 'lines'}',
                    warn: true,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const _Heading(
              icon: Icons.badge_outlined,
              text: 'BY JOB TYPE (DEPARTMENT / CONTRACTOR)',
              hint: 'Hours and cost per rate, across the rooms in the total.',
            ),
            const SizedBox(height: 6),
            _ScrollTable(
              key: const ValueKey('project_labor_rates'),
              columns: const [
                'Job type',
                'Rate',
                'Rate from',
                'Rooms',
                'Total hours',
                'Cost',
                'Fees',
              ],
              numeric: const {1, 4, 5, 6},
              rows: [
                for (final r in summary.rates)
                  [
                    r.roleName,
                    '${cash(r.hourlyRate)}/hr',
                    r.source,
                    r.hoursByRoom.entries
                        .map((e) => '${e.key} (${trimNumber(e.value)} h)')
                        .join(', '),
                    trimNumber(r.hours),
                    r.inKindValue > 0 && r.total == 0
                        ? 'In kind ${cash(r.inKindValue)}'
                        : cash(r.total),
                    r.fees > 0 ? cash(r.fees) : '-',
                  ],
              ],
            ),
            const SizedBox(height: 16),
            const _Heading(
              icon: Icons.handshake_outlined,
              text: 'BY WHO PROVIDES IT',
              hint: 'What the job pays for, and what our staff or another '
                  'department gives in kind.',
            ),
            const SizedBox(height: 6),
            for (final p in summary.providers)
              _ProviderCard(provider: p, cash: cash),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const _Heading(
                  icon: Icons.meeting_room,
                  text: 'BY ROOM',
                  hint: 'Each room\'s crews and the rates they are costed '
                      'from. Open a room to see its lines.',
                ),
                SegmentedButton<LaborRoomSort>(
                  key: const ValueKey('project_labor_sort'),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  showSelectedIcon: false,
                  segments: [
                    for (final s in LaborRoomSort.values)
                      ButtonSegment(
                        value: s,
                        label: Text(
                          s.label,
                          key: ValueKey('project_labor_sort_${s.name}'),
                        ),
                      ),
                  ],
                  selected: {sort},
                  onSelectionChanged: onSort == null
                      ? null
                      : (v) => onSort(v.first),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      sliver: SliverList.builder(
        itemCount: rooms.length,
        itemBuilder: (context, i) => _RoomCard(room: rooms[i], cash: cash),
      ),
    ),
  ];
}

class _RoomCard extends StatelessWidget {
  final ProjectLaborRoom room;
  final String Function(double) cash;

  const _RoomCard({required this.room, required this.cash});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final lines = [...room.lines, ...room.optional];
    return Card(
      key: ValueKey('project_labor_room_${room.room.ref.id}'),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                room.room.codeName == room.room.name
                    ? room.room.name
                    : '${room.room.codeName}  ·  ${room.room.name}',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              cash(room.total),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        subtitle: Text(
          [
            if (!room.included) 'Excluded from the total',
            if (room.room.ref.priority > 0)
              'Priority ${room.room.ref.priority}',
            lines.isEmpty
                ? 'No labor'
                : '${trimNumber(room.hours)} total h, '
                      '${trimNumber(room.crewHours)} crew h',
            if (room.rateNames.isNotEmpty)
              'Rates: ${room.rateNames.join(', ')}',
            if (room.unrated > 0)
              '${room.unrated} with no rate',
            if (room.fees.isNotEmpty)
              'Fees ${cash(room.fees.fold(0.0, (s, f) => s + f.amount))}'
                  '${room.feesTotal == 0 ? ' (not in the total)' : ''}',
          ].join('  ·  '),
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lines.isEmpty)
            Text('No crews on this room.', style: theme.textTheme.bodySmall)
          else
            _ScrollTable(
              columns: const [
                'Job type',
                'Rate from',
                'Description',
                'Techs',
                'Hours',
                'Rate',
                'Cost',
                'Provided by',
              ],
              numeric: const {3, 4, 5, 6},
              rows: [
                for (final l in room.lines) _lineCells(l, cash, ''),
                for (final l in room.optional)
                  _lineCells(l, cash, ' (optional, not in total)'),
              ],
            ),
          if (room.fees.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Fees charged with labor', style: theme.textTheme.labelMedium),
            _ScrollTable(
              columns: const ['Item', 'From', 'Job type', 'Amount'],
              numeric: const {3},
              rows: [
                for (final f in room.fees)
                  [f.name, f.section, f.crew.roleName, cash(f.amount)],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

List<String> _lineCells(
  LaborCostLine l,
  String Function(double) cash,
  String note,
) => [
  l.roleName,
  laborRateSource(l),
  l.description,
  trimNumber(l.techs),
  trimNumber(l.hours),
  '${cash(l.hourlyRate)}/hr',
  cash(l.total),
  '${laborProvidedBy(l)}$note',
];

class _ProviderCard extends StatelessWidget {
  final ProjectLaborProvider provider;
  final String Function(double) cash;

  const _ProviderCard({required this.provider, required this.cash});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paid = provider.paid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(provider.label, style: theme.textTheme.titleSmall),
                ),
                Text(
                  paid
                      ? cash(provider.cost)
                      : 'In kind ${cash(provider.value)}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _ScrollTable(
              columns: const [
                'Job type',
                'Total hours',
                'Value at rate',
                'Fees',
              ],
              numeric: const {1, 2, 3},
              rows: [
                for (final rate in provider.rateNames)
                  [
                    rate,
                    trimNumber(provider.hoursByRate[rate] ?? 0),
                    cash(provider.costByRate[rate] ?? 0),
                    provider.feesByRate[rate] == null
                        ? '-'
                        : cash(provider.feesByRate[rate]!),
                  ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain table that scrolls sideways when the window is narrow.
class _ScrollTable extends StatelessWidget {
  final List<String> columns;
  final List<List<String>> rows;
  final Set<int> numeric;

  const _ScrollTable({
    super.key,
    required this.columns,
    required this.rows,
    this.numeric = const {},
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 32,
        dataRowMinHeight: 28,
        dataRowMaxHeight: 44,
        columnSpacing: 20,
        horizontalMargin: 4,
        columns: [
          for (var i = 0; i < columns.length; i++)
            DataColumn(label: Text(columns[i]), numeric: numeric.contains(i)),
        ],
        rows: [
          for (final row in rows)
            DataRow(cells: [for (final cell in row) DataCell(Text(cell))]),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;

  const _Stat({required this.label, required this.value, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fill = warn ? scheme.errorContainer : scheme.surfaceContainerHighest;
    final ink = warn ? scheme.onErrorContainer : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: ink),
          ),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final IconData icon;
  final String text;
  final String hint;

  const _Heading({required this.icon, required this.text, required this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: muted),
            const SizedBox(width: 5),
            Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: muted,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 19, top: 1),
          child: Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}
