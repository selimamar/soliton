import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/metric_series.dart';
import '../axis_scale.dart';
import '../formatters.dart';
import 'section_card.dart';

/// One line of a [LineChartCard].
class ChartLine {
  const ChartLine({required this.label, required this.color, required this.series});

  final String label;
  final Color color;
  final MetricSeries series;
}

/// A titled card with an interactive line chart (drag to read values).
///
/// The x-axis is the training step. Each line is downsampled to [maxPoints]
/// (keeping spikes) so charts stay smooth on long runs. Non-finite values
/// (NaN, ±∞, as logged by a diverging run) leave a gap in the line and are
/// ignored for the axis range.
class LineChartCard extends StatelessWidget {
  const LineChartCard({
    super.key,
    required this.title,
    required this.lines,
    this.formatValue = formatMetric,
    this.formatTick = formatAxisTick,
    this.height = 180,
    this.maxPoints = 300,
  });

  final String title;
  final List<ChartLine> lines;

  /// Formats values in the header and the tooltip.
  final String Function(double value) formatValue;

  /// Formats y-axis tick labels, given the tick spacing.
  final String Function(double value, double interval) formatTick;

  final double height;
  final int maxPoints;

  @override
  Widget build(BuildContext context) {
    final hasData = lines.any((line) => !line.series.isEmpty);
    final plottable = [
      for (final line in lines)
        if (line.series.points.any((p) => p.value.isFinite)) line,
    ];
    final latest = plottable.isEmpty ? null : plottable.first.series.latest;

    return SectionCard(
      title: title,
      trailing: latest == null
          ? null
          : Text(
              formatValue(latest),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height,
            child: plottable.isEmpty
                ? Center(child: Text(hasData ? 'No finite values to plot' : 'No data yet'))
                : Semantics(
                    container: true,
                    label: _semanticSummary(plottable),
                    image: true,
                    // fl_chart exposes no semantics of its own.
                    child: ExcludeSemantics(child: LineChart(_buildChartData(context, plottable))),
                  ),
          ),
          if (plottable.length > 1) ...[const SizedBox(height: 8), _Legend(lines: plottable)],
        ],
      ),
    );
  }

  /// "Loss chart. Train: latest 0.501, range 0.25 to 2.3. Validation: ..."
  String _semanticSummary(List<ChartLine> lines) {
    final parts = ['$title chart.'];
    for (final line in lines) {
      final finite = [
        for (final p in line.series.points)
          if (p.value.isFinite) p.value,
      ];
      final latest = line.series.latest;
      parts.add(
        '${line.label}: latest ${latest == null ? 'none' : formatValue(latest)}, '
        'range ${formatValue(finite.reduce(math.min))} to ${formatValue(finite.reduce(math.max))}.',
      );
    }
    return parts.join(' ');
  }

  LineChartData _buildChartData(BuildContext context, List<ChartLine> lines) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);

    final series = [for (final line in lines) line.series.downsampled(maxPoints)];
    final bars = [
      for (final (i, s) in series.indexed)
        LineChartBarData(
          spots: [
            for (final p in s.points)
              p.value.isFinite ? FlSpot(p.step.toDouble(), p.value) : FlSpot.nullSpot,
          ],
          color: lines[i].color,
          barWidth: 2,
          isCurved: false,
          dotData: const FlDotData(show: false),
        ),
    ];

    // Axes with round bounds and tick spacing. The small padding keeps lines
    // off the top and bottom edges.
    final ys = [
      for (final s in series)
        for (final p in s.points)
          if (p.value.isFinite) p.value,
    ];
    final minY = ys.reduce(math.min);
    final maxY = ys.reduce(math.max);
    final pad = (maxY - minY) * 0.04;
    final yAxis = niceAxis(minY - pad, maxY + pad);

    final minX = series.map((s) => s.points.first.step).reduce(math.min).toDouble();
    final maxX = series.map((s) => s.points.last.step).reduce(math.max).toDouble();
    final xInterval = maxX > minX ? niceInterval((maxX - minX) / 4) : 1.0;

    return LineChartData(
      minX: minX,
      maxX: maxX,
      minY: yAxis.min,
      maxY: yAxis.max,
      lineBarsData: bars,
      borderData: FlBorderData(show: false),
      gridData: FlGridData(
        drawVerticalLine: false,
        horizontalInterval: yAxis.interval,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: scheme.outlineVariant.withValues(alpha: 0.6), strokeWidth: 0.5),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 52,
            interval: yAxis.interval,
            getTitlesWidget: (value, meta) =>
                _axisLabel(value, meta, formatTick(value, yAxis.interval), labelStyle),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: xInterval,
            getTitlesWidget: (value, meta) =>
                _axisLabel(value, meta, formatAxisTick(value, xInterval), labelStyle),
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => scheme.inverseSurface,
          getTooltipItems: (spots) => [
            for (final (i, spot) in spots.indexed)
              LineTooltipItem(
                _tooltipText(
                  spot,
                  lines[spot.barIndex].label,
                  headerStep: i == 0 ? spot.x : null,
                  firstStep: spots.first.x,
                ),
                TextStyle(color: scheme.onInverseSurface, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  /// "Step 1,200\nTrain: 0.412". Lines logged at different steps (e.g. train
  /// vs validation) get their own step appended.
  String _tooltipText(
    LineBarSpot spot,
    String label, {
    required double? headerStep,
    required double firstStep,
  }) {
    final header = headerStep == null ? '' : 'Step ${formatInt(headerStep.round())}\n';
    final ownStep = spot.x == firstStep ? '' : ' (step ${formatInt(spot.x.round())})';
    return '$header$label: ${formatValue(spot.y)}$ownStep';
  }

  /// Axis tick label. The extreme ticks are hidden: they usually collide
  /// with the neighbouring axis.
  static Widget _axisLabel(double value, TitleMeta meta, String text, TextStyle? style) {
    final tolerance = meta.appliedInterval * 1e-6;
    if ((value - meta.min).abs() < tolerance || (value - meta.max).abs() < tolerance) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(text, style: style, maxLines: 1),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.lines});

  final List<ChartLine> lines;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        for (final line in lines)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 3,
                decoration: BoxDecoration(
                  color: line.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(line.label, style: style),
            ],
          ),
      ],
    );
  }
}
