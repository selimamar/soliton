import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../data/providers.dart';
import '../../../models/metric_series.dart';
import '../../../models/run.dart';
import '../../../shared/chart_settings.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/async_value_view.dart';
import '../../../shared/widgets/chart_controls.dart';
import '../../../shared/widgets/line_chart_card.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/spaced_list_view.dart';
import '../widgets/layer_grad_norm_chart.dart';

/// Scalar metrics over time: loss, accuracy, learning rate, gradient norms,
/// plus any other metric the run logs.
class MetricsTab extends ConsumerWidget {
  const MetricsTab({super.key, required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gradNorms = ref.watch(layerGradNormsProvider(runId));
    final log = ref.watch(logScaleProvider);
    final stepsPerEpoch = _stepsPerEpoch(ref.watch(runProvider(runId)).value);
    final xAxis = stepsPerEpoch != null && ref.watch(xAxisUnitProvider) == XAxisUnit.epochs
        ? ChartXAxis.epochs(stepsPerEpoch)
        : const ChartXAxis.steps();

    return AsyncValueView(
      value: ref.watch(runMetricsProvider(runId)),
      onRetry: () => ref.invalidate(runMetricsProvider(runId)),
      data: (metrics) {
        final trainLoss = metrics[MetricKeys.trainLoss];
        final valLoss = metrics[MetricKeys.valLoss];
        final accuracy = metrics[MetricKeys.valAccuracy];
        final learningRate = metrics[MetricKeys.learningRate];
        final gradNorm = metrics[MetricKeys.gradNorm];
        final otherMetrics = metrics.entries.where((e) => !MetricKeys.all.contains(e.key)).toList();

        return SpacedListView(
          children: [
            ChartControls(epochsAvailable: stepsPerEpoch != null),
            LineChartCard(
              title: 'Loss',
              logScale: log,
              xAxis: xAxis,
              lines: [
                if (trainLoss != null)
                  ChartLine(label: 'Train', color: ChartColors.train, series: trainLoss),
                if (valLoss != null)
                  ChartLine(label: 'Validation', color: ChartColors.validation, series: valLoss),
              ],
            ),
            if (accuracy != null)
              LineChartCard(
                title: 'Validation accuracy',
                xAxis: xAxis,
                formatValue: formatPercent,
                formatTick: formatPercentAxisTick,
                lines: [
                  ChartLine(label: 'Accuracy', color: ChartColors.accuracy, series: accuracy),
                ],
              ),
            if (learningRate != null)
              LineChartCard(
                title: 'Learning rate',
                height: 140,
                logScale: log,
                xAxis: xAxis,
                lines: [
                  ChartLine(
                    label: 'Learning rate',
                    color: ChartColors.learningRate,
                    series: learningRate,
                  ),
                ],
              ),
            if (gradNorm != null)
              LineChartCard(
                title: 'Gradient norm (global)',
                height: 140,
                logScale: log,
                xAxis: xAxis,
                lines: [
                  ChartLine(label: 'Grad norm', color: ChartColors.gradient, series: gradNorm),
                ],
              ),
            // Reserve the chart's space while it loads, so the cards below
            // don't jump when it arrives.
            if (gradNorms.isLoading && !gradNorms.hasValue)
              const SectionCard(
                title: LayerGradNormChart.title,
                child: SizedBox(
                  height: LayerGradNormChart.chartHeight,
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (gradNorms.value case final layers? when layers.isNotEmpty)
              LayerGradNormChart(layers: layers),
            if (otherMetrics.isNotEmpty) const _SectionTitle('Other metrics'),
            for (final entry in otherMetrics)
              LineChartCard(
                title: entry.key,
                height: 140,
                xAxis: xAxis,
                lines: [ChartLine(label: entry.key, color: ChartColors.other, series: entry.value)],
              ),
          ],
        );
      },
    );
  }
}

/// Steps per epoch, if the run says how many epochs it has.
double? _stepsPerEpoch(Run? run) {
  if (run == null || run.totalEpochs <= 0 || run.totalSteps <= 0) return null;
  return run.totalSteps / run.totalEpochs;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
        ),
      ),
    );
  }
}
