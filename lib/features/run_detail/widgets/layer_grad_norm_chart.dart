import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/layer_stats.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/section_card.dart';

/// Bar chart of the latest gradient norm of every layer, input to output.
/// Useful to spot vanishing or exploding gradients at a glance.
///
/// Layers whose gradient norm is NaN or infinite get a full-height bar in
/// the error colour, so a diverged layer stands out instead of vanishing.
class LayerGradNormChart extends StatelessWidget {
  const LayerGradNormChart({super.key, required this.layers});

  final List<LayerGradNorm> layers;

  static const title = 'Gradient norm by layer (latest)';
  static const chartHeight = 160.0;

  /// Above this many layers, bar labels would overlap: rely on tooltips.
  static const _maxLabelledLayers = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final barWidth = (160 / layers.length).clamp(4.0, 18.0).toDouble();
    final showLabels = layers.length <= _maxLabelledLayers;

    final finite = [
      for (final l in layers)
        if (l.gradNorm.isFinite) l.gradNorm,
    ];
    final tallest = finite.isEmpty ? 1.0 : finite.reduce(math.max);

    return SectionCard(
      title: title,
      child: SizedBox(
        height: chartHeight,
        child: Semantics(
          container: true,
          label: _semanticSummary(),
          image: true,
          // fl_chart exposes no semantics of its own.
          child: ExcludeSemantics(
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                barGroups: [
                  for (final (i, layer) in layers.indexed)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: layer.gradNorm.isFinite ? layer.gradNorm : tallest,
                          color: layer.gradNorm.isFinite ? ChartColors.gradient : scheme.error,
                          width: barWidth,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ],
                    ),
                ],
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: showLabels,
                      reservedSize: 22,
                      getTitlesWidget: (value, meta) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          layers[value.toInt()].layerName,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => scheme.inverseSurface,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final layer = layers[group.x];
                      return BarTooltipItem(
                        '${layer.layerName}\n${formatMetric(layer.gradNorm)}',
                        TextStyle(color: scheme.onInverseSurface, fontSize: 12),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "Gradient norm by layer, 10 layers. Highest: inc, 3.606. Lowest: ..."
  String _semanticSummary() {
    final finite = [
      for (final l in layers)
        if (l.gradNorm.isFinite) l,
    ];
    final parts = ['Gradient norm by layer, ${layers.length} layers.'];
    if (finite.isNotEmpty) {
      final highest = finite.reduce((a, b) => a.gradNorm >= b.gradNorm ? a : b);
      final lowest = finite.reduce((a, b) => a.gradNorm <= b.gradNorm ? a : b);
      parts
        ..add('Highest: ${highest.layerName}, ${formatMetric(highest.gradNorm)}.')
        ..add('Lowest: ${lowest.layerName}, ${formatMetric(lowest.gradNorm)}.');
    }
    final broken = layers.length - finite.length;
    if (broken > 0) {
      parts.add('$broken ${broken == 1 ? 'layer has' : 'layers have'} no finite value.');
    }
    return parts.join(' ');
  }
}
