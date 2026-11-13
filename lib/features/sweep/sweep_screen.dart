import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../models/run_cost.dart';
import '../../models/run_insights.dart';
import '../../shared/clock.dart';
import '../../shared/colormaps.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/exportable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';
import '../../shared/widgets/xy_chart_card.dart';

/// The metrics a sweep can compare, and whether lower is better (then a
/// run's best value counts; else its latest).
const sweepMetrics = {
  MetricKeys.relL2: 'Relative L2 (validation)',
  MetricKeys.valLoss: 'Validation loss',
  MetricKeys.trainLoss: 'Train loss',
  MetricKeys.inferenceSeconds: 'Inference time per sample',
  sweepCost: 'Training cost (estimated)',
};

/// Not a logged metric: each run's estimated cost (see [estimateCost]).
const sweepCost = 'estimate/cost';

/// Runs of one project side by side by what they varied: a grid of a
/// metric over two hyperparameters (e.g. Fourier modes × width), or a
/// scatter of two metrics (e.g. error against inference time). Tap a cell
/// or point to open its run.
class SweepScreen extends ConsumerStatefulWidget {
  const SweepScreen({super.key});

  @override
  ConsumerState<SweepScreen> createState() => _SweepScreenState();
}

enum _Mode { grid, scatter }

class _SweepScreenState extends ConsumerState<SweepScreen> {
  String? _project;
  var _mode = _Mode.grid;
  String? _rowsParam;
  String? _columnsParam;
  var _metric = MetricKeys.relL2;
  var _xMetric = MetricKeys.inferenceSeconds;
  var _yMetric = MetricKeys.relL2;

  @override
  Widget build(BuildContext context) {
    final names = sweepMetrics.keys.where((k) => k != sweepCost).join(',');
    final now = ref.watch(clockProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Sweep')),
      body: AsyncValueView(
        value: ref.watch(runsProvider),
        onRetry: () => ref.invalidate(runsProvider),
        data: (runs) {
          final projects = _projects(runs);
          if (projects.isEmpty) {
            return const _Message('A sweep compares two or more runs of the same project.');
          }
          final project = projects.contains(_project) ? _project! : projects.first;
          final inProject = [
            for (final r in runs)
              if (r.project == project) r,
          ];
          final params = _varying(inProject);
          final latest = ref.watch(latestMetricsProvider(names));
          return SpacedListView(
            children: [
              _Controls(
                projects: projects,
                project: project,
                onProject: (p) => setState(() {
                  _project = p;
                  _rowsParam = _columnsParam = null;
                }),
                mode: _mode,
                onMode: (m) => setState(() => _mode = m),
                children: _mode == _Mode.grid
                    ? [
                        _Picker(
                          label: 'Rows',
                          value: _pick(_rowsParam, params, 0),
                          options: {for (final p in params) p: p},
                          onChanged: (v) => setState(() => _rowsParam = v),
                        ),
                        _Picker(
                          label: 'Columns',
                          value: _pick(_columnsParam, params, 1),
                          options: {for (final p in params) p: p},
                          onChanged: (v) => setState(() => _columnsParam = v),
                        ),
                        _Picker(
                          label: 'Metric',
                          value: _metric,
                          options: sweepMetrics,
                          onChanged: (v) => setState(() => _metric = v),
                        ),
                      ]
                    : [
                        _Picker(
                          label: 'Across',
                          value: _xMetric,
                          options: sweepMetrics,
                          onChanged: (v) => setState(() => _xMetric = v),
                        ),
                        _Picker(
                          label: 'Up',
                          value: _yMetric,
                          options: sweepMetrics,
                          onChanged: (v) => setState(() => _yMetric = v),
                        ),
                      ],
              ),
              AsyncValueView(
                value: latest,
                onRetry: () => ref.invalidate(latestMetricsProvider(names)),
                data: (logged) {
                  final values = {
                    ...logged,
                    for (final r in inProject)
                      if (estimateCost(r, now) case final cost?)
                        r.id: {...?logged[r.id], sweepCost: LatestMetric(latest: cost.soFar)},
                  };
                  return _mode == _Mode.grid
                      ? _Grid(
                          runs: inProject,
                          rows: _pick(_rowsParam, params, 0),
                          columns: _pick(_columnsParam, params, 1),
                          metric: _metric,
                          values: values,
                        )
                      : _Scatter(runs: inProject, x: _xMetric, y: _yMetric, values: values);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  /// [chosen] if it is still an option, else the [index]th one.
  static String? _pick(String? chosen, List<String> options, int index) {
    if (chosen != null && options.contains(chosen)) return chosen;
    if (options.isEmpty) return null;
    return options[math.min(index, options.length - 1)];
  }

  /// Projects with two or more runs, most runs first.
  static List<String> _projects(List<Run> runs) {
    final counts = <String, int>{};
    for (final r in runs) {
      if (r.project.isNotEmpty) counts[r.project] = (counts[r.project] ?? 0) + 1;
    }
    return [
      for (final e in counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        if (e.value >= 2) e.key,
    ];
  }

  /// Hyperparameters that differ between [runs], likeliest sweep axes
  /// first: logged by most runs, with several values (but not one per run,
  /// like a label would be).
  static List<String> _varying(List<Run> runs) {
    final values = <String, Set<String>>{};
    final logged = <String, int>{};
    for (final r in runs) {
      for (final e in r.hyperparameters.entries) {
        (values[e.key] ??= {}).add(e.value);
        logged[e.key] = (logged[e.key] ?? 0) + 1;
      }
    }
    final most = runs.length > 3 ? runs.length - 1 : runs.length;
    final varying = [
      for (final e in values.entries)
        if (e.value.length >= 2 && e.value.length <= most && logged[e.key]! * 2 >= runs.length)
          e.key,
    ];
    int score(String key) => values[key]!.length * 100 + logged[key]!;
    return varying..sort((a, b) {
      final byScore = score(b).compareTo(score(a));
      return byScore != 0 ? byScore : a.compareTo(b);
    });
  }
}

/// A run's value of [metric] for a sweep: its best (lowest) for an error or
/// loss, its latest for a time.
double? sweepValue(Map<String, Map<String, LatestMetric>> values, String runId, String metric) {
  final value = values[runId]?[metric];
  if (value == null) return null;
  return metric.startsWith('perf/') ? value.latest : (value.min ?? value.latest);
}

String _formatSweep(String metric, double value) => switch (metric) {
  MetricKeys.relL2 => formatRelativeError(value),
  MetricKeys.inferenceSeconds => formatSeconds(value),
  sweepCost => formatCost(value),
  _ => formatMetric(value),
};

/// Numbers in a hyperparameter's text, for sorting: "8 × 8" -> 8, "1e-3
/// (cosine)" -> 0.001; else null (sorted as text, after numbers).
double? _leadingNumber(String text) =>
    double.tryParse(RegExp(r'-?\d+(\.\d+)?([eE]-?\d+)?').firstMatch(text)?.group(0) ?? '');

int _compareValues(String a, String b) {
  final x = _leadingNumber(a), y = _leadingNumber(b);
  if (x != null && y != null && x != y) return x.compareTo(y);
  if (x != null && y == null) return -1;
  if (x == null && y != null) return 1;
  return a.compareTo(b);
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.projects,
    required this.project,
    required this.onProject,
    required this.mode,
    required this.onMode,
    required this.children,
  });

  final List<String> projects;
  final String project;
  final ValueChanged<String> onProject;
  final _Mode mode;
  final ValueChanged<_Mode> onMode;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SectionCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Picker(
          label: 'Project',
          value: project,
          options: {for (final p in projects) p: p},
          onChanged: onProject,
        ),
        const SizedBox(height: 8),
        SegmentedButton<_Mode>(
          segments: const [
            ButtonSegment(value: _Mode.grid, icon: Icon(Icons.grid_on), label: Text('Grid')),
            ButtonSegment(
              value: _Mode.scatter,
              icon: Icon(Icons.scatter_plot_outlined),
              label: Text('Scatter'),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (s) => onMode(s.single),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}

class _Picker extends StatelessWidget {
  const _Picker({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 80, child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
      Expanded(
        child: DropdownButton<String>(
          isExpanded: true,
          value: options.containsKey(value) ? value : null,
          hint: const Text('Nothing to choose'),
          items: [
            for (final e in options.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    ],
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SectionCard(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

/// [metric] over two hyperparameters: each cell the best run with those
/// values, coloured from best (yellow) to worst (purple) on a log scale.
class _Grid extends StatelessWidget {
  const _Grid({
    required this.runs,
    required this.rows,
    required this.columns,
    required this.metric,
    required this.values,
  });

  final List<Run> runs;
  final String? rows;
  final String? columns;
  final String metric;
  final Map<String, Map<String, LatestMetric>> values;

  @override
  Widget build(BuildContext context) {
    if (rows == null || columns == null || rows == columns) {
      return const _Message('Pick two hyperparameters that differ between these runs.');
    }
    final theme = Theme.of(context);
    final rowValues = {for (final r in runs) ?r.hyperparameters[rows]}.toList()
      ..sort(_compareValues);
    final columnValues = {for (final r in runs) ?r.hyperparameters[columns]}.toList()
      ..sort(_compareValues);
    // The best run per cell.
    final cells = <(String, String), (Run, double)>{};
    for (final run in runs) {
      final (row, column) = (run.hyperparameters[rows], run.hyperparameters[columns]);
      final value = sweepValue(values, run.id, metric);
      if (row == null || column == null || value == null || !value.isFinite) continue;
      final best = cells[(row, column)];
      if (best == null || value < best.$2) cells[(row, column)] = (run, value);
    }
    if (cells.isEmpty) {
      return _Message('None of these runs logged ${sweepMetrics[metric] ?? metric}.');
    }
    final logged = [for (final c in cells.values) c.$2];
    final positive = logged.every((v) => v > 0);
    double scale(double v) => positive ? math.log(v) : v;
    final low = logged.map(scale).reduce(math.min), high = logged.map(scale).reduce(math.max);
    final best = cells.values.reduce((a, b) => a.$2 <= b.$2 ? a : b).$1;

    return Exportable(
      fileName: 'sweep $metric by $rows and $columns',
      builder: (context, exportButton) => SectionCard(
        title: sweepMetrics[metric] ?? metric,
        trailing: exportButton,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$rows (rows) × $columns (columns) · ${metric.startsWith('perf/') ? 'latest' : 'best'} '
              'value per run · tap a cell to open it',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    children: [
                      const SizedBox.shrink(),
                      for (final c in columnValues)
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(c, style: theme.textTheme.labelMedium),
                        ),
                    ],
                  ),
                  for (final r in rowValues)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(r, style: theme.textTheme.labelMedium),
                        ),
                        for (final c in columnValues)
                          _Cell(
                            entry: cells[(r, c)],
                            metric: metric,
                            // Lower is better: the best value gets the brightest colour.
                            shade: switch (cells[(r, c)]) {
                              final e? => high > low ? 1 - (scale(e.$2) - low) / (high - low) : 1,
                              null => null,
                            },
                            isBest: cells[(r, c)]?.$1 == best,
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.entry,
    required this.metric,
    required this.shade,
    required this.isBest,
  });

  final (Run, double)? entry;
  final String metric;
  final double? shade;
  final bool isBest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entry == null) {
      return Container(
        margin: const EdgeInsets.all(3),
        width: 88,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('–', style: theme.textTheme.bodySmall),
      );
    }
    final (run, value) = entry!;
    final color = Colormap.viridis.at(shade!);
    final dark = color.computeLuminance() < 0.4;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => context.go(AppRoutes.run(run.id)),
          child: Tooltip(
            message: run.name,
            child: Container(
              width: 88,
              height: 52,
              alignment: Alignment.center,
              decoration: isBest
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: theme.colorScheme.onSurface, width: 2),
                    )
                  : null,
              child: Text(
                _formatSweep(metric, value),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: dark ? Colors.white : Colors.black,
                  fontWeight: isBest ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One point per run: [y] against [x], e.g. error against cost. Log axes
/// when the values span a decade or more.
class _Scatter extends StatelessWidget {
  const _Scatter({required this.runs, required this.x, required this.y, required this.values});

  final List<Run> runs;
  final String x;
  final String y;
  final Map<String, Map<String, LatestMetric>> values;

  @override
  Widget build(BuildContext context) {
    final points = [
      for (final run in runs)
        if ((sweepValue(values, run.id, x), sweepValue(values, run.id, y))
            case (final vx?, final vy?) when vx.isFinite && vy.isFinite)
          (run, vx, vy),
    ];
    if (points.length < 2) {
      return _Message(
        'Fewer than two of these runs logged both ${sweepMetrics[x]} and ${sweepMetrics[y]}.',
      );
    }
    bool decades(Iterable<double> v) =>
        v.every((e) => e > 0) && v.reduce(math.max) / v.reduce(math.min) >= 10;
    return XYChartCard(
      title: '${sweepMetrics[y]} against ${sweepMetrics[x]?.toLowerCase()}',
      subtitle: 'One point per run · tap one to open it',
      xLabel: sweepMetrics[x] ?? x,
      scatter: true,
      logX: decades(points.map((p) => p.$2)),
      logY: decades(points.map((p) => p.$3)),
      formatX: (v) => _formatSweep(x, v),
      formatY: (v) => _formatSweep(y, v),
      tickPrefix: (x: x == sweepCost ? r'$' : '', y: y == sweepCost ? r'$' : ''),
      height: 220,
      onTap: (i) => context.go(AppRoutes.run(points[i].$1.id)),
      series: [
        for (final (i, (run, vx, vy)) in points.indexed)
          XYSeries(
            label: run.name,
            color: ChartColors.runs[i % ChartColors.runs.length],
            points: [(vx, vy)],
          ),
      ],
    );
  }
}
