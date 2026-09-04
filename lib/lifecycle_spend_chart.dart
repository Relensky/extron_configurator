import 'package:flutter/material.dart';

import 'equipment_lifecycle.dart' show formatLifecycleMoney;
import 'hover_chart.dart';

/// ============================================================================
///  WHAT THE PLAN COSTS, YEAR BY YEAR
/// ============================================================================
///  The year grid on a replacement plan is the document: a row per room, a
///  column per year, and the money in the cell it lands in. It is complete and
///  it is exactly what a budget request is written from - and it is also forty
///  rows wide, which means the SHAPE of the plan, the thing anybody asks about
///  first, has to be reconstructed by eye from the cells.
///
///  So the same figures get drawn as a line. One point per year, and a readout
///  on every point naming what is in it - which rooms, which buildings - so
///  the question the shape provokes can be answered without going back to the
///  grid.
///
///  IT IS THE SAME ARITHMETIC AS THE GRID, taken from the same lifecycle. A
///  chart that could disagree with the table under it would be worse than no
///  chart at all.
///
///  THE LEVEL LINE IS THE OTHER HALF OF THE QUESTION. A plan is a demand
///  curve, and a demand curve with one bad year in it is the reason phasing
///  exists - so the chart also draws what the SAME plan would cost every year
///  if the peaks were pushed off and the whole thing spread evenly across the
///  years it covers. The gap between the spike and the flat line is the size
///  of the deferral being argued about.
/// ============================================================================

/// What falls due in one year, and what it is made of.
typedef SpendYear = ({
  int year,

  /// The money falling due that year.
  double amount,

  /// Who it is for - room names on a building, job names on a campus. Named
  /// rather than counted, because 'which rooms' is the question the shape
  /// provokes and a count cannot answer it.
  List<({String name, double amount})> parts,
});

/// The plan as a line with a readout on it.
///
/// Draws nothing under two years, or when nothing on the plan is priced: a
/// flat line at zero says the estate is free.
class LifecycleSpendChart extends StatelessWidget {
  final List<SpendYear> years;
  final String currency;

  /// The year the reader is standing in, ruled down the chart.
  final int asOfYear;

  /// What the whole plan would cost per year if it were spread evenly over
  /// the years still in front of the reader. Null leaves the line off.
  final double? levelAmount;

  /// The heading over the chart.
  final String title;

  /// The ink the line is drawn in. Defaults to the scheme's primary.
  final Color? lineColor;

  final double height;

  const LifecycleSpendChart({
    super.key,
    required this.years,
    required this.currency,
    required this.asOfYear,
    this.levelAmount,
    this.title = 'WHAT FALLS DUE, YEAR BY YEAR',
    this.lineColor,
    this.height = 210,
  });

  /// The level annual spend for [plan] over the years from [asOfYear] to the
  /// last year on it - what it would cost a year to stop having peaks.
  ///
  /// Worked out over the FUTURE only. Years already gone cannot be budgeted
  /// for, and dividing a plan by twenty years when twelve of them are behind
  /// the reader produces a comfortable figure nobody can actually spend to.
  /// Null when there is no future left on the plan to spread anything over.
  static double? levelSpendFor(List<SpendYear> plan, int asOfYear) {
    var total = 0.0;
    var last = asOfYear;
    for (final y in plan) {
      if (y.year < asOfYear) continue;
      total += y.amount;
      if (y.year > last) last = y.year;
    }
    final span = last - asOfYear + 1;
    if (total <= 0 || span < 2) return null;
    return total / span;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (years.length < 2) return const SizedBox.shrink();
    if (years.every((y) => y.amount <= 0)) return const SizedBox.shrink();

    // The running total is in the readout because 'what has it come to by
    // 2031' is the second question every time, and adding six columns of a
    // grid in your head is how it used to be answered.
    var running = 0.0;
    final points = <HoverPoint>[];
    for (final year in years) {
      running += year.amount;
      final named = [...year.parts]..sort((a, b) => b.amount.compareTo(a.amount));
      points.add(HoverPoint(
        x: year.year.toDouble(),
        y: year.amount,
        axisLabel: '${year.year}',
        title: '${year.year}'
            '${year.year == asOfYear ? '  ·  this year' : ''}',
        rows: [
          (
            label: 'Falls due',
            value: year.amount <= 0
                ? 'nothing'
                : formatLifecycleMoney(year.amount, currency),
          ),
          (
            label: 'Plan to date',
            value: formatLifecycleMoney(running, currency),
          ),
          if (levelAmount != null && year.year >= asOfYear)
            (
              label: year.amount > levelAmount!
                  ? 'Over a level year by'
                  : 'Under a level year by',
              value: formatLifecycleMoney(
                (year.amount - levelAmount!).abs(),
                currency,
              ),
            ),
          for (final part in named.take(8))
            (
              label: '· ${part.name}',
              value: formatLifecycleMoney(part.amount, currency),
            ),
          if (named.length > 8)
            (label: '· and ${named.length - 8} more', value: ''),
        ],
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          levelAmount == null
              ? 'Hover any year to see what is in it.'
              : 'Hover any year to see what is in it. The dashed line is what '
                  'the same plan costs a year if the peaks are pushed off and '
                  'the whole of it is spread evenly from here to the end.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        HoverLineChart(
          points: points,
          lineColor: lineColor ?? theme.colorScheme.primary,
          formatY: (v) => shortMoney(v, currency),
          levelY: levelAmount,
          levelLabel: levelAmount == null
              ? null
              : 'level ${formatLifecycleMoney(levelAmount!, currency)} a year',
          markerX: asOfYear.toDouble(),
          markerXLabel: 'Today',
          height: height,
        ),
      ],
    );
  }
}
