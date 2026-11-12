import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/layer_stats.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/histogram_view.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/sparkline.dart';

/// Compact summary of one layer for the Layers tab.
class LayerCard extends StatelessWidget {
  const LayerCard({super.key, required this.stats, this.onTap});

  final LayerStats stats;
  final VoidCallback? onTap;

  /// Above this fraction of dead units, the badge turns into a warning.
  static const _deadWarningThreshold = 0.2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(color: muted);
    final latestGrad = stats.gradNorm.latest;
    final histogram = stats.activationHistogram;
    final gradValues = [for (final p in stats.gradNorm.downsampled(40).points) p.value];

    return SectionCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  stats.layerName,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _DeadUnitsBadge(
                fraction: stats.deadFraction,
                isWarning: stats.deadFraction > _deadWarningThreshold,
              ),
              Icon(Icons.chevron_right, color: muted),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      histogram.zeroCount > 0
                          ? 'Activations · ${formatPercent(histogram.zeroFraction)} zero'
                          : 'Activations',
                      style: labelStyle,
                    ),
                    const SizedBox(height: 6),
                    HistogramView(
                      histogram: histogram,
                      color: ChartColors.activation,
                      height: 44,
                      showRange: false,
                      semanticLabel:
                          'Activation distribution from ${formatMetric(histogram.min)} '
                          'to ${formatMetric(histogram.max)}',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      latestGrad == null ? 'Grad norm' : 'Grad norm · ${formatMetric(latestGrad)}',
                      style: labelStyle,
                    ),
                    const SizedBox(height: 6),
                    Sparkline(
                      values: gradValues,
                      color: ChartColors.gradient,
                      height: 44,
                      semanticLabel: 'Gradient norm over time, ${trendOf(gradValues)}',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeadUnitsBadge extends StatelessWidget {
  const _DeadUnitsBadge({required this.fraction, required this.isWarning});

  final double fraction;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isWarning ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${formatPercent(fraction)} dead',
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
