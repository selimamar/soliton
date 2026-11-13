import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../axis_scale.dart';
import '../formatters.dart';
import 'exportable.dart';
import 'section_card.dart';

/// One series of an [XYChartCard]: (x, y) points, any order.
class XYSeries {
  const XYSeries({required this.label, required this.color, required this.points});

  final String label;
  final Color color;
  final List<(double, double)> points;
}

/// A titled card with a chart of y against x, where x isn't a training step:
/// a spectrum (energy against wavenumber), an error against resolution, one
/// run's cost against its error. Axes can be logarithmic; [band] shades an x
/// range (e.g. the values seen in training); [scatter] draws points only.
/// Non-finite values (and non-positive ones on a log axis) are skipped.
class XYChartCard extends StatelessWidget {
  const XYChartCard({
    super.key,
    required this.title,
    required this.series,
    this.subtitle,
    this.xLabel = '',
    this.yLabel = '',
    this.logX = false,
    this.logY = false,
    this.band,
    this.bandLabel,
    this.scatter = false,
    this.height = 180,
    this.formatX = formatMetric,
    this.formatY = formatMetric,
    this.onTap,
    this.controls,
    this.formatYTick,
    this.tickPrefix = (x: '', y: ''),
  });

  final String title;
  final String? subtitle;
  final List<XYSeries> series;
  final String xLabel;
  final String yLabel;
  final bool logX;
  final bool logY;

  /// An x range to shade (both ends equal: a line).
  final (double, double)? band;
  final String? bandLabel;
  final bool scatter;
  final double height;
  final String Function(double) formatX;
  final String Function(double) formatY;

  /// Tapping a point: its series' index.
  final ValueChanged<int>? onTap;

  /// Shown above the chart, e.g. a choice of what to plot.
  final Widget? controls;

  /// Linear y-axis tick labels (default: round numbers), e.g. as percents.
  final String Function(double)? formatYTick;

  /// Put before every tick label on that axis, e.g. a currency sign.
  final ({String x, String y}) tickPrefix;

  double? _x(double v) => !v.isFinite || (logX && v <= 0) ? null : (logX ? _log10(v) : v);
  double? _y(double v) => !v.isFinite || (logY && v <= 0) ? null : (logY ? _log10(v) : v);
  static double _log10(double v) => math.log(v) / math.ln10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final shown = [
      for (final s in series)
        if (s.points.any((p) => _x(p.$1) != null && _y(p.$2) != null)) s,
    ];
    return Exportable(
      fileName: title,
      builder: (context, exportButton) => SectionCard(
        title: title,
        trailing: exportButton,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (subtitle != null) ...[Text(subtitle!, style: muted), const SizedBox(height: 8)],
            if (controls != null) ...[controls!, const SizedBox(height: 8)],
            SizedBox(
              height: height,
              child: shown.isEmpty
                  ? const Center(child: Text('No values to plot'))
                  : Semantics(
                      container: true,
                      image: true,
                      label: '$title chart: ${[for (final s in shown) s.label].join(', ')}',
                      child: ExcludeSemantics(child: LineChart(_data(context, shown))),
                    ),
            ),
            const SizedBox(height: 4),
            // The axis name on the left, the band's note on the right; both
            // wrap rather than overflow on a phone.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(xLabel, style: muted)),
                if (band != null && bandLabel != null) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      bandLabel!,
                      textAlign: TextAlign.end,
                      style: muted?.copyWith(fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ],
            ),
            if (shown.length > 1 && !scatter) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  for (final s in shown)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 10, height: 3, color: s.color),
                        const SizedBox(width: 6),
                        Text(s.label, style: theme.textTheme.labelSmall),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  LineChartData _data(BuildContext context, List<XYSeries> shown) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    final xs = <double>[], ys = <double>[];
    final bars = [
      for (final s in shown)
        LineChartBarData(
          spots: [
            for (final p in [...s.points]..sort((a, b) => a.$1.compareTo(b.$1)))
              if ((_x(p.$1), _y(p.$2)) case (final x?, final y?))
                () {
                  xs.add(x);
                  ys.add(y);
                  return FlSpot(x, y);
                }(),
          ],
          color: s.color,
          barWidth: scatter ? 0 : 2,
          dotData: FlDotData(
            show: scatter || s.points.length <= 12,
            getDotPainter: (_, _, _, _) =>
                FlDotCirclePainter(radius: scatter ? 5 : 3, color: s.color, strokeWidth: 0),
          ),
        ),
    ];
    var minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
    var minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
    if (band case (final a, final b)) {
      if (_x(a) case final x?) minX = math.min(minX, x);
      if (_x(b) case final x?) maxX = math.max(maxX, x);
    }
    // Room around single values and at the edges.
    (minX, maxX) = _pad(minX, maxX, scatter ? 0.08 : 0);
    (minY, maxY) = _pad(minY, maxY, 0.08);
    final xInterval = _interval(minX, maxX, logX);
    final yInterval = _interval(minY, maxY, logY);

    final bandRange = switch (band) {
      (final a, final b) => (_x(a), _x(b)),
      null => null,
    };
    return LineChartData(
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      lineBarsData: bars,
      borderData: FlBorderData(show: false),
      rangeAnnotations: RangeAnnotations(
        verticalRangeAnnotations: [
          if (bandRange case (final a?, final b?) when b > a)
            VerticalRangeAnnotation(x1: a, x2: b, color: scheme.primary.withValues(alpha: 0.1)),
        ],
      ),
      extraLinesData: ExtraLinesData(
        verticalLines: [
          if (bandRange case (final a?, final b?) when b == a)
            VerticalLine(x: a, color: scheme.primary.withValues(alpha: 0.5), dashArray: [4, 4]),
        ],
      ),
      gridData: FlGridData(
        drawVerticalLine: false,
        horizontalInterval: yInterval,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: scheme.outlineVariant.withValues(alpha: 0.6), strokeWidth: 0.5),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 48,
            interval: yInterval,
            getTitlesWidget: (v, meta) => _axisLabel(
              v,
              meta,
              tickPrefix.y +
                  (logY ? _logTick(v) : (formatYTick?.call(v) ?? formatAxisTick(v, yInterval))),
              labelStyle,
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 22,
            interval: xInterval,
            getTitlesWidget: (v, meta) => _axisLabel(
              v,
              meta,
              tickPrefix.x + (logX ? _logTick(v) : formatAxisTick(v, xInterval)),
              labelStyle,
            ),
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchCallback: onTap == null
            ? null
            : (event, response) {
                if (event is FlTapUpEvent) {
                  final spot = response?.lineBarSpots?.firstOrNull;
                  if (spot != null) onTap!(spot.barIndex);
                }
              },
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => scheme.inverseSurface,
          getTooltipItems: (spots) => [
            for (final (i, spot) in spots.indexed)
              LineTooltipItem(
                [
                  if (i == 0) '${xLabel.isEmpty ? 'x' : xLabel} ${formatX(_unlog(spot.x, logX))}',
                  '${shown[spot.barIndex].label}: ${formatY(_unlog(spot.y, logY))}',
                ].join('\n'),
                TextStyle(color: scheme.onInverseSurface, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  static double _unlog(double v, bool log) => log ? math.pow(10, v).toDouble() : v;

  /// A log axis tick at 10^[v]: "10", "0.001"; between decades, one
  /// significant digit ("3", "3e-4") rather than "3.162".
  static String _logTick(double v) {
    final value = math.pow(10, v).toDouble();
    if ((v - v.round()).abs() < 1e-6) return formatLogTick(value);
    final digits = (math.log(value) / math.ln10).floor();
    final scale = math.pow(10, digits).toDouble();
    return formatCoordinate((value / scale).round() * scale);
  }

  static (double, double) _pad(double low, double high, double fraction) {
    if (high - low < 1e-12) return (low - 0.5, high + 0.5);
    final pad = (high - low) * fraction;
    return (low - pad, high + pad);
  }

  /// Decades on a log axis (or half decades when it spans less than two);
  /// round steps otherwise.
  static double _interval(double low, double high, bool log) {
    final span = high - low;
    if (log) return span <= 2 ? 0.5 : (span / 4).ceilToDouble();
    return niceInterval(span / 4);
  }

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
