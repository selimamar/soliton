import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/layer_stats.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/histogram_view.dart';
import '../../../shared/widgets/line_chart_card.dart';
import '../../../shared/widgets/section_card.dart';

/// Opens a tall bottom sheet with all statistics of one layer.
Future<void> showLayerDetailSheet(BuildContext context, LayerStats stats) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) =>
          _LayerDetail(stats: stats, scrollController: scrollController),
    ),
  );
}

class _LayerDetail extends StatelessWidget {
  const _LayerDetail({required this.stats, required this.scrollController});

  final LayerStats stats;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Text(stats.layerName, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${formatPercent(stats.deadFraction)} of units never activate',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Activation distribution (latest)',
          child: HistogramView(
            histogram: stats.activationHistogram,
            color: ChartColors.activation,
            height: 140,
            semanticLabel:
                'Activation distribution from ${formatMetric(stats.activationHistogram.min)} '
                'to ${formatMetric(stats.activationHistogram.max)}',
          ),
        ),
        const SizedBox(height: 12),
        LineChartCard(
          title: 'Activation statistics',
          lines: [
            ChartLine(label: 'Mean', color: ChartColors.activation, series: stats.activationMean),
            ChartLine(label: 'Std', color: ChartColors.train, series: stats.activationStd),
          ],
        ),
        const SizedBox(height: 12),
        LineChartCard(
          title: 'Gradient norm',
          lines: [
            ChartLine(label: 'Grad norm', color: ChartColors.gradient, series: stats.gradNorm),
          ],
        ),
      ],
    );
  }
}
