import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/field_snapshot.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../shared/chart_settings.dart';
import '../../shared/colormaps.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/chart_controls.dart';
import '../../shared/widgets/line_chart_card.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';
import '../../shared/widgets/exportable.dart';
import '../../shared/widgets/status_chip.dart';
import '../run_detail/widgets/field_heatmap.dart';

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
        _FieldsComparison(runs: runs),
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

/// The same field from each run at its latest step: the truth once (from
/// the first run), then each run's prediction and error, on colour scales
/// shared by all runs so their maps compare. 3D fields show their middle
/// slice across the shortest axis, rollouts their last frame. Only when two
/// or more runs log a field of the same name.
class _FieldsComparison extends ConsumerStatefulWidget {
  const _FieldsComparison({required this.runs});

  final List<_ComparedRun> runs;

  @override
  ConsumerState<_FieldsComparison> createState() => _FieldsComparisonState();
}

class _FieldsComparisonState extends ConsumerState<_FieldsComparison> {
  String? _name;

  @override
  Widget build(BuildContext context) {
    final perRun = <String, Map<String, FieldSummary>>{
      for (final r in widget.runs)
        r.run.id: {
          for (final f in ref.watch(fieldsProvider(r.run.id)).value ?? const <FieldSummary>[])
            if (f.kind == FieldKind.output && f.steps.isNotEmpty) f.name: f,
        },
    };
    final counts = <String, int>{};
    for (final fields in perRun.values) {
      for (final name in fields.keys) {
        counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    final shared = [
      for (final e in counts.entries)
        if (e.value >= 2) e.key,
    ];
    if (shared.isEmpty) return const SizedBox.shrink();
    final name = shared.contains(_name) ? _name! : shared.first;
    final snapshots = [
      for (final r in widget.runs)
        if (perRun[r.run.id]![name] case final field?)
          (
            run: r,
            snapshot: ref
                .watch(
                  fieldSnapshotProvider((runId: r.run.id, name: name, step: field.steps.last.step)),
                )
                .value,
          ),
    ];
    final loaded = [
      for (final s in snapshots)
        if (s.snapshot != null) (run: s.run, snapshot: s.snapshot!),
    ];
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Exportable(
      fileName: 'compare $name',
      builder: (context, exportButton) => SectionCard(
        title: 'Fields',
        trailing: exportButton,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (shared.length > 1) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final n in shared)
                    ChoiceChip(
                      label: Text(n),
                      selected: n == name,
                      onSelected: (_) => setState(() => _name = n),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text('Each run at its latest step, on shared colour scales.', style: muted),
            const SizedBox(height: 12),
            if (loaded.length < snapshots.length)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              _ComparedFields(entries: loaded),
          ],
        ),
      ),
    );
  }
}

class _ComparedFields extends StatelessWidget {
  const _ComparedFields({required this.entries});

  final List<({_ComparedRun run, FieldSnapshot snapshot})> entries;

  /// What to draw of a snapshot: its last frame, the middle slice of 3D.
  static FieldPlane _plane(FieldSnapshot s, Float32List data) {
    final frame = s.frames - 1;
    if (s.dimensions != 3) return s.plane(data, frame: frame);
    var axis = 0;
    for (var a = 1; a < 3; a++) {
      if (s.shape[a] < s.shape[axis]) axis = a;
    }
    return s.plane(data, frame: frame, axis: axis, index: s.shape[axis] ~/ 2);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var low = double.infinity, high = double.negativeInfinity, error = 0.0;
    for (final e in entries) {
      low = math.min(low, e.snapshot.valueRange.min);
      high = math.max(high, e.snapshot.valueRange.max);
      error = math.max(error, e.snapshot.maxAbsError);
    }
    Widget map(FieldPlane plane, Colormap colormap, double lo, double hi, String label) =>
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: FieldHeatmap(
            data: plane.values,
            rows: plane.rows,
            columns: plane.columns,
            low: lo,
            high: hi,
            colormap: colormap,
            aspectRatio: plane.rows == 1 ? 6 : null,
            semanticLabel: label,
          ),
        );

    final truth = entries.first.snapshot;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(220.0, (constraints.maxWidth - 12) / 2);
        Widget column(String title, Widget child) => SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: theme.textTheme.labelMedium, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              child,
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (truth.target case final target?) ...[
              // Its own size, like the maps below (not the card's width).
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: column(
                  'Ground truth (${entries.first.run.label})',
                  map(_plane(truth, target), Colormap.viridis, low, high, 'Ground truth'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            for (final e in entries) ...[
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: e.run.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      e.run.label,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    [
                      'step ${formatInt(e.snapshot.step)}',
                      if (e.snapshot.stats[FieldStatKeys.relL2] case final v?)
                        'rel. L2 ${formatRelativeError(v)}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  column(
                    'Prediction',
                    map(
                      _plane(e.snapshot, e.snapshot.prediction),
                      Colormap.viridis,
                      low,
                      high,
                      'Prediction of ${e.run.label}',
                    ),
                  ),
                  if (e.snapshot.error case final err?)
                    column(
                      'Error',
                      map(
                        _plane(e.snapshot, err),
                        Colormap.diverging,
                        -error,
                        error,
                        'Error of ${e.run.label}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            Row(
              children: [
                Expanded(
                  child: ColorBar(colormap: Colormap.viridis, low: low, high: high),
                ),
                const SizedBox(width: 12),
                if (error > 0)
                  Expanded(
                    child: ColorBar(colormap: Colormap.diverging, low: -error, high: error),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
