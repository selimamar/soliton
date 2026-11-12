import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/layer_stats.dart';
import '../formatters.dart';

/// Draws a [Histogram] as bars, optionally with min/max labels and the
/// share of exact zeros underneath.
class HistogramView extends StatelessWidget {
  const HistogramView({
    super.key,
    required this.histogram,
    required this.color,
    this.height = 80,
    this.showRange = true,
    this.semanticLabel,
  });

  final Histogram histogram;
  final Color color;
  final double height;
  final bool showRange;

  /// What screen readers announce for this chart. Without one, the chart is
  /// treated as decoration.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final bars = SizedBox(
      height: height,
      child: CustomPaint(painter: _HistogramPainter(histogram.counts, color)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (semanticLabel == null)
          bars
        else
          Semantics(container: true, label: semanticLabel, image: true, child: bars),
        if (showRange) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatMetric(histogram.min), style: labelStyle),
              Text(formatMetric(histogram.max), style: labelStyle),
            ],
          ),
          if (histogram.zeroCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${formatPercent(histogram.zeroFraction)} of values are exactly zero (not shown)',
              style: labelStyle,
            ),
          ],
        ],
      ],
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.counts, this.color);

  final List<int> counts;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (counts.isEmpty) return;
    final maxCount = counts.reduce((a, b) => a > b ? a : b);
    if (maxCount == 0) return;

    const gap = 1.5;
    final barWidth = size.width / counts.length;
    final paint = Paint()..color = color;

    for (var i = 0; i < counts.length; i++) {
      final barHeight = counts[i] / maxCount * size.height;
      final rect = Rect.fromLTWH(
        i * barWidth + gap / 2,
        size.height - barHeight,
        barWidth - gap,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      !listEquals(old.counts, counts) || old.color != color;
}
