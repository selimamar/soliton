import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../shared/chart_settings.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/chart_controls.dart';
import '../../shared/widgets/line_chart_card.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';
import '../../shared/widgets/status_chip.dart';

/// Two or more runs side by side: a summary, then their loss and accuracy
/// curves in the same charts. Open it from the runs list ("Compare runs").
class CompareScreen extends ConsumerWidget {
  const CompareScreen({super.key, required this.runIds});

  final List<String> runIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = runIds.toSet().take(ChartColors.runs.length).toList();
    if (ids.length < 2) {
      return Scaffold(
        appBar: AppBar(title: const Text('Compare runs')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Pick at least two runs to compare.'),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => context.go(AppRoutes.runs),
                child: const Text('Go to runs'),
              ),
            ],
          ),
        ),
      );
    }

    final combined = _combine([
      for (final id in ids) (ref.watch(runProvider(id)), ref.watch(runMetricsProvider(id))),
    ]);

    return Scaffold(
      appBar: AppBar(title: const Text('Compare runs')),
      body: AsyncValueView(
        value: combined,
        onRetry: () {
          for (final id in ids) {
            ref.invalidate(runProvider(id));
            ref.invalidate(runMetricsProvider(id));
          }
        },
        data: (runs) => _Comparison(runs: runs),
      ),
    );
  }
}

/// One run with its metrics, its colour and a label that tells it apart.
typedef _ComparedRun = ({Run run, Map<String, MetricSeries> metrics, Color color, String label});

/// All runs and metrics once everything has loaded; the first error
/// otherwise.
AsyncValue<List<_ComparedRun>> _combine(
  List<(AsyncValue<Run>, AsyncValue<Map<String, MetricSeries>>)> values,
) {
  for (final (run, metrics) in values) {
    if (run.hasError && !run.hasValue) return AsyncError(run.error!, run.stackTrace!);
    if (metrics.hasError && !metrics.hasValue) {
      return AsyncError(metrics.error!, metrics.stackTrace!);
    }
  }
  if (values.any((v) => !v.$1.hasValue || !v.$2.hasValue)) return const AsyncLoading();
  final runs = [for (final (run, _) in values) run.requireValue];
  return AsyncData([
    for (final (i, (run, metrics)) in values.indexed)
      (
        run: run.requireValue,
        metrics: metrics.requireValue,
        color: ChartColors.runs[i],
        // Same name twice (e.g. a rerun): fall back to the unique id.
        label: runs.where((r) => r.name == run.requireValue.name).length > 1
            ? run.requireValue.id
            : run.requireValue.name,
      ),
  ]);
}

class _Comparison extends ConsumerWidget {
  const _Comparison({required this.runs});

  final List<_ComparedRun> runs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(logScaleProvider);

    List<ChartLine> linesFor(String metric) => [
      for (final r in runs)
        if (r.metrics[metric] case final series?)
          ChartLine(label: r.label, color: r.color, series: series),
    ];

    final valLoss = linesFor(MetricKeys.valLoss);
    final accuracy = linesFor(MetricKeys.valAccuracy);

    return SpacedListView(
      children: [
        _Summary(runs: runs),
        // Epoch counts differ between runs, so the x-axis is always steps.
        const ChartControls(showXAxis: false),
        LineChartCard(title: 'Train loss', logScale: log, lines: linesFor(MetricKeys.trainLoss)),
        if (valLoss.isNotEmpty)
          LineChartCard(title: 'Validation loss', logScale: log, lines: valLoss),
        if (accuracy.isNotEmpty)
          LineChartCard(
            title: 'Validation accuracy',
            formatValue: formatPercent,
            formatTick: formatPercentAxisTick,
            lines: accuracy,
          ),
      ],
    );
  }
}

/// Per run: status, progress and the headline numbers.
class _Summary extends StatelessWidget {
  const _Summary({required this.runs});

  final List<_ComparedRun> runs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SectionCard(
      title: 'Summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in runs.indexed) ...[
            if (i > 0) const Divider(height: 20),
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: r.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.label,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                StatusChip(status: r.run.status),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Text(_numbers(r), style: muted),
            ),
          ],
        ],
      ),
    );
  }

  /// "Step 12,000 · train loss 0.412 · best val loss 0.520 · best accuracy 91.3%".
  /// Best values skip NaN; the latest train loss shows it.
  static String _numbers(_ComparedRun r) {
    final finite = <String, List<double>>{
      for (final key in [MetricKeys.valLoss, MetricKeys.valAccuracy])
        key: [
          for (final p in r.metrics[key]?.points ?? const <MetricPoint>[])
            if (p.value.isFinite) p.value,
        ],
    };
    // The latest train loss as logged, NaN included: that's how a crash ends.
    final train = r.metrics[MetricKeys.trainLoss]?.latest;
    final val = finite[MetricKeys.valLoss]!;
    final accuracy = finite[MetricKeys.valAccuracy]!;
    return [
      'Step ${formatInt(r.run.currentStep)}',
      if (train != null) 'train loss ${formatMetric(train)}',
      if (val.isNotEmpty) 'best val loss ${formatMetric(val.reduce(math.min))}',
      if (accuracy.isNotEmpty) 'best accuracy ${formatPercent(accuracy.reduce(math.max))}',
    ].join(' · ');
  }
}
