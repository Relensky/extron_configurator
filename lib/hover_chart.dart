import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'pinned_grid.dart' show gridMetric;

/// ============================================================================
///  A LINE YOU CAN ASK QUESTIONS OF
/// ============================================================================
///  Three tabs draw money or work against time - the timeline's order dates,
///  the building's replacement plan, the campus budget - and each of them drew
///  it by hand. A hand-painted plot shows a SHAPE, which is most of the value,
///  but it cannot answer the question somebody asks straight after seeing the
///  shape: "what IS that spike". The only way to find out was to leave the
///  picture and go read the table under it.
///
///  So the plot got a real chart beside it. [HoverLineChart] is one line over
///  one axis with a READOUT ON IT: put the pointer anywhere along the line and
///  the point nearest it says what it is, what it comes to, and whatever else
///  the caller wants said about it - every job in that year, every part on
///  that order date - without leaving the picture.
///
///  THE HOVER IS THE POINT, so the caller supplies the rows rather than the
///  chart guessing them: see [HoverPoint.rows]. A tooltip that only repeats
///  the number already printed on the axis is a tooltip nobody hovers twice.
///
///  IT IS STILL READABLE WITHOUT A MOUSE. Everything the readout says is also
///  in the table or the grid the chart sits above - this is a faster way to
///  the same answer, never the only way. The tab gets printed and photographed
///  and neither of those has a pointer on it.
/// ============================================================================

/// One line of the readout: a name on the left, a figure on the right.
typedef HoverRow = ({String label, String value});

/// A figure short enough to sit on an axis: $1.2M, $412k, $940.
///
/// The axis has about six characters before it starts eating the plot, and a
/// campus year runs to seven digits. Rounded HARD and only ever used on the
/// axis - every readout, table and document says the figure in full, so
/// nothing is being decided off the rounded one.
String shortMoney(double value, String currency) {
  final v = value.abs();
  final sign = value < 0 ? '-' : '';
  if (v >= 1000000) {
    final m = v / 1000000;
    return '$sign$currency${m.toStringAsFixed(m < 10 ? 1 : 0)}M';
  }
  if (v >= 1000) {
    final k = v / 1000;
    return '$sign$currency${k.toStringAsFixed(k < 10 ? 1 : 0)}k';
  }
  return '$sign$currency${v.round()}';
}

/// One point on the line, and everything the readout says about it.
class HoverPoint {
  /// Where it sits along the axis. A year (2031), or days from the start of a
  /// job - whatever the caller's axis is measured in.
  final double x;

  /// How high it is: the money, or the count.
  final double y;

  /// What the axis calls it - '2031', '14 Mar'. Also the readout's heading
  /// when the caller gives no [title].
  final String axisLabel;

  /// The heading over the readout, when it says more than [axisLabel] does.
  final String? title;

  /// The readout itself, in the order it should be read.
  final List<HoverRow> rows;

  /// The dot's own color, where the point carries a status - a late order date
  /// is red on the rail above and has to be red here too.
  final Color? color;

  const HoverPoint({
    required this.x,
    required this.y,
    required this.axisLabel,
    this.title,
    this.rows = const [],
    this.color,
  });
}

/// A line with a hover readout on it.
///
/// Draws nothing at all under two points: one point with a line through it is
/// not a chart, it is a number with decoration.
class HoverLineChart extends StatelessWidget {
  final List<HoverPoint> points;

  /// The ink the line is drawn in. The dots may differ - see [HoverPoint.color].
  final Color lineColor;

  /// How the left-hand axis says a figure. Kept short: the axis has about six
  /// characters before it starts eating the plot.
  final String Function(double) formatY;

  /// A flat line across the chart, and what to call it. What the campus draws
  /// its level spend with, against the peaks that spend would flatten.
  final double? levelY;
  final String? levelLabel;

  /// A rule down the chart, and what to call it - 'Today' on a date axis.
  final double? markerX;
  final String? markerXLabel;

  /// How tall the plot is drawn, before the reader's text size is applied.
  ///
  /// GROWN WITH THE TYPE, like every other fixed dimension in this app - see
  /// [gridMetric]. An axis whose labels are half again as big inside a box
  /// that did not move is an axis with its figures clipped, which is the one
  /// thing a chart cannot afford: the shape is readable without them and the
  /// FIGURES are the reason it is here rather than a sparkline.
  final double height;

  /// A curve through the points rather than straight segments. Off by
  /// default: a budget that bulges through years it was never in is a lie the
  /// eye believes.
  final bool curved;

  const HoverLineChart({
    super.key,
    required this.points,
    required this.lineColor,
    required this.formatY,
    this.levelY,
    this.levelLabel,
    this.markerX,
    this.markerXLabel,
    this.height = 190,
    this.curved = false,
  });

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final sorted = [...points]..sort((a, b) => a.x.compareTo(b.x));
    final minX = sorted.first.x;
    final maxX = sorted.last.x;

    var peak = 0.0;
    for (final p in sorted) {
      if (p.y > peak) peak = p.y;
    }
    if (levelY != null && levelY! > peak) peak = levelY!;
    // HEADROOM FOR THE READOUT. The tooltip pops up ABOVE the point it is
    // about, and a chart drawn to the exact height of its tallest point has
    // nowhere to put the one that matters most.
    final maxY = peak <= 0 ? 1.0 : peak * 1.25;

    // A LABEL ON EVERY POINT IS UNREADABLE past about a dozen of them, so they
    // thin out rather than print over each other.
    final step = (sorted.length / 12).ceil().clamp(1, 500);
    final labelAt = <double, String>{
      for (var i = 0; i < sorted.length; i += step)
        sorted[i].x: sorted[i].axisLabel,
    };

    final line = LineChartBarData(
      spots: [for (final p in sorted) FlSpot(p.x, p.y)],
      isCurved: curved,
      preventCurveOverShooting: true,
      color: lineColor,
      barWidth: 2.5,
      isStrokeCapRound: true,
      dotData: FlDotData(
        getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
          radius: 3.5,
          color: sorted[index.clamp(0, sorted.length - 1)].color ?? lineColor,
          strokeWidth: 1.5,
          strokeColor: theme.cardColor,
        ),
      ),
      belowBarData: BarAreaData(
        show: true,
        color: lineColor.withValues(alpha: 0.14),
      ),
    );

    return SizedBox(
      height: gridMetric(context, height),
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: 0,
          maxY: maxY,
          lineBarsData: [line],
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => FlLine(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              left: BorderSide(color: scheme.outlineVariant),
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              if (levelY != null)
                HorizontalLine(
                  y: levelY!,
                  color: scheme.tertiary,
                  strokeWidth: 1.6,
                  dashArray: const [6, 4],
                  label: HorizontalLineLabel(
                    show: levelLabel != null,
                    alignment: Alignment.topRight,
                    labelResolver: (line) => levelLabel ?? '',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.tertiary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
            verticalLines: [
              if (markerX != null)
                VerticalLine(
                  x: markerX!,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                  strokeWidth: 1,
                  dashArray: const [4, 4],
                  label: VerticalLineLabel(
                    show: markerXLabel != null,
                    alignment: Alignment.topLeft,
                    labelResolver: (line) => markerXLabel ?? '',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                // Room for '$1.2M' at the reader's own text size.
                reservedSize: gridMetric(context, 62),
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    // The top gridline is headroom for the readout rather than
                    // a figure anybody is reading, so it goes unlabelled.
                    value > peak ? '' : formatY(value),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: gridMetric(context, 26),
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final label = labelAt[value];
                  if (label == null) return const SizedBox.shrink();
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            // On Windows this fires on HOVER as well as on a press, which is
            // the whole reason the chart is here.
            handleBuiltInTouches: true,
            touchSpotThreshold: 24,
            getTouchedSpotIndicator: (bar, indexes) => [
              for (final _ in indexes)
                TouchedSpotIndicatorData(
                  FlLine(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    strokeWidth: 1,
                  ),
                  FlDotData(
                    getDotPainter: (spot, percent, data, index) =>
                        FlDotCirclePainter(
                      radius: 5.5,
                      color:
                          sorted[index.clamp(0, sorted.length - 1)].color ??
                          lineColor,
                      strokeWidth: 2,
                      strokeColor: theme.cardColor,
                    ),
                  ),
                ),
            ],
            touchTooltipData: LineTouchTooltipData(
              // The readout is a list of names and figures, and its longest
              // line decides how wide it has to be - which grows with the
              // type like everything else on it.
              maxContentWidth: gridMetric(context, 320),
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              tooltipBorder: BorderSide(color: scheme.outlineVariant),
              getTooltipColor: (spot) => scheme.surfaceContainerHighest,
              getTooltipItems: (spots) => [
                for (final spot in spots)
                  _readout(context, sorted, spot.spotIndex),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The point, as the readout prints it: a heading and the caller's rows,
  /// one per line.
  LineTooltipItem? _readout(
    BuildContext context,
    List<HoverPoint> sorted,
    int index,
  ) {
    if (index < 0 || index >= sorted.length) return null;
    final point = sorted[index];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurface,
      height: 1.45,
    );

    return LineTooltipItem(
      point.title ?? point.axisLabel,
      theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: point.color ?? scheme.onSurface,
          ) ??
          const TextStyle(fontWeight: FontWeight.bold),
      textAlign: TextAlign.left,
      children: [
        for (final row in point.rows)
          TextSpan(
            text: '\n${row.label}${row.value.isEmpty ? '' : '   ${row.value}'}',
            style: body,
          ),
      ],
    );
  }
}
