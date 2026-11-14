import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../models/simulation_info.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/spaced_list_view.dart';
import '../../shared/widgets/xy_chart_card.dart';
import '../run_detail/tabs/fields_tab.dart' show CurvesCards;
import 'simulation_text.dart';

/// Every value a simulation logged, each against simulated time (or the
/// iteration, for a steady solve): conserved quantities with how far they
/// drifted, residuals on a log scale, the CFL number with its limit, and
/// the time step. A diverged simulation's charts mark where it diverged.
class DiagnosticsTab extends ConsumerWidget {
  const DiagnosticsTab({super.key, required this.simulation});

  final Run simulation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncValueView(
      value: ref.watch(runMetricsProvider(simulation.id)),
      onRetry: () => ref.invalidate(runMetricsProvider(simulation.id)),
      data: (metrics) {
        final sim = simulation.simulation!;
        final times = SimulatedTimes.from(metrics);
        final monitor = sim.monitor;
        final names =
            [
              for (final name in metrics.keys)
                if (!MetricKeys.isSystem(name) &&
                    name != SimulationInfo.timeKey &&
                    name != SimulationInfo.timeStepKey)
                  name,
            ]..sort((a, b) {
              if (a == monitor) return -1;
              if (b == monitor) return 1;
              return a.compareTo(b);
            });
        final dt = metrics[SimulationInfo.timeStepKey];
        final hasCurves = (ref.watch(curvesProvider(simulation.id)).value ?? const []).any(
          (c) => c.steps.isNotEmpty,
        );
        if (names.isEmpty && dt == null && !hasCurves) {
          final theme = Theme.of(context);
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No values logged yet. Log them with sim.log({"energy": E}, t=t, dt=dt), '
                'or a result against a parameter with sim.log_curve(name, x, y).',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        final divergedAt = !sim.diverged
            ? null
            : times?.at(simulation.currentStep) ?? simulation.currentStep.toDouble();
        return SpacedListView(
          children: [
            for (final name in names)
              _ValueChart(
                series: metrics[name]!,
                times: times,
                limit: name.toLowerCase() == 'cfl' ? sim.cflLimit : null,
                divergedAt: divergedAt,
              ),
            if (dt != null) _ValueChart(series: dt, times: times, divergedAt: divergedAt),
            // Curves logged with sim.log_curve, e.g. a steady solve's result
            // against a parameter.
            if (hasCurves) CurvesCards(runId: simulation.id, stepLabel: simulationStepLabel(times)),
          ],
        );
      },
    );
  }
}

class _ValueChart extends StatelessWidget {
  const _ValueChart({required this.series, required this.times, this.limit, this.divergedAt});

  final MetricSeries series;
  final SimulatedTimes? times;

  /// A limit to draw, e.g. the CFL number's.
  final double? limit;

  /// Where the simulation diverged, on the x-axis.
  final double? divergedAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final points = [
      for (final p in series.points) (times?.at(p.step) ?? p.step.toDouble(), p.value),
    ];
    final finite = [
      for (final (_, v) in points)
        if (v.isFinite) v,
    ];
    final name = series.name.toLowerCase();
    final logY =
        (name.contains('residual') || name.contains('error')) &&
        finite.isNotEmpty &&
        finite.every((v) => v > 0);
    final xs = [for (final (x, _) in points) x];

    String? subtitle;
    if (finite.isNotEmpty) {
      final now = formatMetric(finite.last);
      final first = finite.first;
      final change = first == 0 || logY ? null : (finite.last - first) / first.abs();
      subtitle = [
        'Now $now',
        if (change != null)
          '${change >= 0 ? '+' : '−'}${formatRelativeError(change.abs())} since the start',
        if (points.isNotEmpty && !points.last.$2.isFinite) 'then ${formatMetric(points.last.$2)}',
      ].join(' · ');
    }

    return XYChartCard(
      title: describeValue(series.name),
      subtitle: subtitle,
      xLabel: times == null ? 'Iteration' : 'Simulated time t',
      logY: logY,
      formatX: formatCoordinate,
      band: divergedAt == null ? null : (divergedAt!, divergedAt!),
      bandLabel: divergedAt == null ? null : 'Diverged',
      series: [
        XYSeries(
          label: describeValue(series.name),
          color: series.name == SimulationInfo.timeStepKey ? ChartColors.other : ChartColors.train,
          points: points,
        ),
        if (limit != null && xs.isNotEmpty)
          XYSeries(
            label: 'Limit',
            color: scheme.error,
            points: [
              (xs.reduce((a, b) => a < b ? a : b), limit!),
              (xs.reduce((a, b) => a > b ? a : b), limit!),
            ],
          ),
      ],
    );
  }
}
