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

/// What a chart's x-axis counts: training steps, or epochs.
class ChartXAxis {
  const ChartXAxis.steps() : stepsPerEpoch = null, label = 'Step';

  /// Epochs, assuming the same number of steps in each.
  const ChartXAxis.epochs(double this.stepsPerEpoch) : label = 'Epoch';

  /// Positions that aren't training steps, e.g. grid points of a 1D field
  /// (the series' "steps" are then the point indices).
  const ChartXAxis.positions(this.label) : stepsPerEpoch = null;

  final double? stepsPerEpoch;

  /// "Step", "Epoch", or what the positions are, for tooltips.
  final String label;

  double position(int step) => stepsPerEpoch == null ? step.toDouble() : step / stepsPerEpoch!;

  /// "1,200" for steps, "3.4" for epochs.
  String describe(double x) {
    if (stepsPerEpoch == null) return formatInt(x.round());
    final text = x.toStringAsFixed(2);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}

/// A titled card with an interactive line chart (drag to read values).
///
/// Each line is downsampled to [maxPoints] (keeping spikes) so charts stay
/// smooth on long runs. Non-finite values (NaN, ±∞, as logged by a
/// diverging run) leave a gap in the line and are ignored for the axis
/// range; on a [logScale], so are zero and negative values.
class LineChartCard extends StatelessWidget {
  const LineChartCard({
    super.key,
    required this.title,
    required this.lines,
    this.formatValue = formatMetric,
    this.formatTick = formatAxisTick,
    this.height = 180,
    this.maxPoints = 300,
    this.logScale = false,
    this.xAxis = const ChartXAxis.steps(),
    this.yRange,
    this.showLatest = true,
  });

  final String title;
  final List<ChartLine> lines;

  /// Formats values in the header and the tooltip.
  final String Function(double value) formatValue;

  /// Formats y-axis tick labels, given the tick spacing (linear scale only).
  final String Function(double value, double interval) formatTick;

  final double height;
  final int maxPoints;

  /// A logarithmic y-axis, with ticks at 1, 2 and 5 times powers of ten.
  final bool logScale;

  final ChartXAxis xAxis;

  /// A y-axis that always shows this range (widened if the data goes
  /// outside it), e.g. 0 to 100 for a percentage. Linear scale only.
  final ({double min, double max})? yRange;

  /// Shows the first line's latest value next to the title. Off for lines
  /// that aren't over time (e.g. a field along x).
  final bool showLatest;

  /// The value's height on the chart, or null if it can't be drawn.
  double? _plotY(double value) {
    if (!value.isFinite) return null;
    if (!logScale) return value;
    return value > 0 ? math.log(value) / math.ln10 : null;
  }

  double _valueAt(double y) => logScale ? math.pow(10, y).toDouble() : y;

  @override
  Widget build(BuildContext context) {
    final hasData = lines.any((line) => !line.series.isEmpty);
    final hasFinite = lines.any((line) => line.series.points.any((p) => p.value.isFinite));
    final plottable = [
      for (final line in lines)
        if (line.series.points.any((p) => _plotY(p.value) != null)) line,
    ];
    final latest = plottable.isEmpty || !showLatest ? null : plottable.first.series.latest;
    final emptyText = !hasData
        ? 'No data yet'
        : hasFinite && logScale
        ? 'No positive values to plot on a log scale'
        : 'No finite values to plot';

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
                ? Center(child: Text(emptyText))
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
    final parts = ['$title chart${logScale ? ', log scale' : ''}.'];
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
              if (_plotY(p.value) case final y?)
                FlSpot(xAxis.position(p.step), y)
              else
                FlSpot.nullSpot,
          ],
          color: lines[i].color,
          barWidth: 2,
          isCurved: false,
          dotData: const FlDotData(show: false),
        ),
    ];

    final ys = [
      for (final s in series)
        for (final p in s.points) ?_plotY(p.value),
    ];
    final y = switch ((logScale, yRange)) {
      (true, _) => _LogYAxis(ys.reduce(math.min), ys.reduce(math.max)),
      (false, final range?) => _LinearYAxis(
        math.min(range.min, ys.reduce(math.min)),
        math.max(range.max, ys.reduce(math.max)),
        formatTick,
        pad: false,
      ),
      (false, null) => _LinearYAxis(ys.reduce(math.min), ys.reduce(math.max), formatTick),
    };

    // Lines need not start at the same step (e.g. a resumed run).
    final xs = [
      for (final s in series)
        if (s.points.isNotEmpty) ...[s.points.first.step, s.points.last.step],
    ];
    final minX = xAxis.position(xs.reduce(math.min));
    final maxX = xAxis.position(xs.reduce(math.max));
    final xInterval = maxX > minX ? niceInterval((maxX - minX) / 4) : 1.0;

    return LineChartData(
      minX: minX,
      maxX: maxX,
      minY: y.min,
      maxY: y.max,
      lineBarsData: bars,
      borderData: FlBorderData(show: false),
      gridData: FlGridData(
        drawVerticalLine: false,
        horizontalInterval: y.interval,
        checkToShowHorizontalLine: (value) => y.label(value) != null,
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
            interval: y.interval,
            getTitlesWidget: (value, meta) => switch (y.label(value)) {
              final text? => _axisLabel(value, meta, text, labelStyle),
              null => const SizedBox.shrink(),
            },
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
                  headerX: i == 0 ? spot.x : null,
                  firstX: spots.first.x,
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
    required double? headerX,
    required double firstX,
  }) {
    final header = headerX == null ? '' : '${xAxis.label} ${xAxis.describe(headerX)}\n';
    final own = spot.x == firstX ? '' : ' (${xAxis.label.toLowerCase()} ${xAxis.describe(spot.x)})';
    return '$header$label: ${formatValue(_valueAt(spot.y))}$own';
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

/// The y-axis bounds, the spacing at which fl_chart asks for ticks and grid
/// lines, and which of those get a label.
sealed class _YAxis {
  double get min;
  double get max;
  double get interval;

  /// The label at [value], or null for no tick (and no grid line) there.
  String? label(double value);
}

/// Round bounds and evenly spaced ticks. The small padding keeps lines off
/// the top and bottom edges.
class _LinearYAxis implements _YAxis {
  _LinearYAxis(double low, double high, this._format, {bool pad = true}) {
    final padding = pad ? (high - low) * 0.04 : 0.0;
    final scale = niceAxis(low - padding, high + padding);
    min = scale.min;
    max = scale.max;
    interval = scale.interval;
  }

  final String Function(double value, double interval) _format;

  @override
  late final double min;
  @override
  late final double max;
  @override
  late final double interval;

  @override
  String? label(double value) => _format(value, interval);
}

/// Plotted in log10 units. fl_chart only spaces ticks evenly, so it is
/// asked at a fine spacing, and only the spots nearest a round value
/// (1, 2, 5 × 10ⁿ) get a label and a grid line.
class _LogYAxis implements _YAxis {
  _LogYAxis(double lowLog, double highLog) {
    final scale = logAxis(math.pow(10, lowLog).toDouble(), math.pow(10, highLog).toDouble());
    min = _log10(scale.min);
    max = _log10(scale.max);
    interval = (max - min) / _steps;
    _ticks = [for (final t in scale.ticks) (_log10(t), t)];
  }

  static const _steps = 200;

  @override
  late final double min;
  @override
  late final double max;
  @override
  late final double interval;
  late final List<(double, double)> _ticks;

  static double _log10(double value) => math.log(value) / math.ln10;

  @override
  String? label(double value) {
    for (final (position, tick) in _ticks) {
      if ((value - position).abs() <= interval / 2) return formatLogTick(tick);
    }
    return null;
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
