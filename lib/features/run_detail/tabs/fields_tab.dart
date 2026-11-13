import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../data/providers.dart';
import '../../../models/field_snapshot.dart';
import '../../../models/metric_series.dart';
import '../../../shared/colormaps.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/async_value_view.dart';
import '../../../shared/widgets/line_chart_card.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/spaced_list_view.dart';
import '../../../shared/widgets/stat_tile.dart';
import '../widgets/field_heatmap.dart';

/// Snapshots of the fields a run predicts (e.g. a PDE solution), logged with
/// `run.log_field(...)`: the prediction, the true field and their
/// difference at any logged step, and the relative L2 error over training.
class FieldsTab extends ConsumerStatefulWidget {
  const FieldsTab({super.key, required this.runId});

  final String runId;

  @override
  ConsumerState<FieldsTab> createState() => _FieldsTabState();
}

class _FieldsTabState extends ConsumerState<FieldsTab> {
  String? _name;

  /// The step shown; null follows the latest one as new snapshots arrive.
  int? _step;

  GridPoint? _point;

  /// The last snapshot loaded, shown while the next one loads (so the
  /// slider doesn't flash a spinner at every step).
  FieldSnapshot? _shown;

  @override
  Widget build(BuildContext context) {
    return AsyncValueView(
      value: ref.watch(fieldsProvider(widget.runId)),
      onRetry: () => ref.invalidate(fieldsProvider(widget.runId)),
      data: (fields) {
        final usable = [
          for (final f in fields)
            if (f.steps.isNotEmpty) f,
        ];
        if (usable.isEmpty) return const _NoFields();
        final field = usable.firstWhere((f) => f.name == _name, orElse: () => usable.first);
        final index = _stepIndex(field);
        final step = field.steps[index];
        final key = (runId: widget.runId, name: field.name, step: step.step);
        final snapshotValue = ref.watch(fieldSnapshotProvider(key));
        if (snapshotValue.value case final loaded?) _shown = loaded;
        final snapshot = switch (_shown) {
          final s? when s.name == field.name => s,
          _ => null,
        };
        final loading = snapshotValue.isLoading || snapshot?.step != step.step;

        return SpacedListView(
          children: [
            if (usable.length > 1)
              _FieldPicker(
                names: [for (final f in usable) f.name],
                selected: field.name,
                onSelected: (name) => setState(() {
                  _name = name;
                  _point = null;
                }),
              ),
            _StepCard(
              field: field,
              index: index,
              hasTarget: snapshot?.hasTarget ?? step.stats.isNotEmpty,
              onChanged: (i) =>
                  setState(() => _step = i == field.steps.length - 1 ? null : field.steps[i].step),
            ),
            if (snapshotValue.hasError && !loading)
              _SnapshotError(onRetry: () => ref.invalidate(fieldSnapshotProvider(key)))
            else if (snapshot == null)
              const SectionCard(
                child: SizedBox(height: 240, child: Center(child: CircularProgressIndicator())),
              )
            else if (snapshot.is2D)
              _HeatmapsCard(
                snapshot: snapshot,
                loading: loading,
                point: _clamp(_point, snapshot),
                onSelect: (point) => setState(() => _point = point),
              )
            else
              ..._lineCharts(snapshot),
            if (field.steps.any((s) => s.relL2 != null)) _ErrorOverTraining(field: field),
          ],
        );
      },
    );
  }

  /// The index of the step shown: [_step] if it was logged, else the latest.
  int _stepIndex(FieldSummary field) {
    if (_step == null) return field.steps.length - 1;
    final i = field.steps.indexWhere((s) => s.step == _step);
    return i < 0 ? field.steps.length - 1 : i;
  }

  static GridPoint? _clamp(GridPoint? point, FieldSnapshot snapshot) {
    if (point == null) return null;
    return (
      row: point.row.clamp(0, snapshot.rows - 1),
      column: point.column.clamp(0, snapshot.columns - 1),
    );
  }

  static List<Widget> _lineCharts(FieldSnapshot snapshot) {
    MetricSeries series(String name, Float32List values) => MetricSeries(
      name: name,
      points: [for (var i = 0; i < values.length; i++) MetricPoint(i, values[i])],
    );
    const xAxis = ChartXAxis.positions('Point');
    return [
      LineChartCard(
        title: snapshot.hasTarget ? 'Prediction and ground truth' : 'Prediction',
        xAxis: xAxis,
        showLatest: false,
        maxPoints: 512,
        height: 200,
        lines: [
          ChartLine(
            label: 'Prediction',
            color: ChartColors.train,
            series: series('prediction', snapshot.prediction),
          ),
          if (snapshot.target case final target?)
            ChartLine(
              label: 'Ground truth',
              color: ChartColors.validation,
              series: series('target', target),
            ),
        ],
      ),
      if (snapshot.error case final error?)
        LineChartCard(
          title: 'Error (prediction − truth)',
          xAxis: xAxis,
          showLatest: false,
          maxPoints: 512,
          lines: [
            ChartLine(label: 'Error', color: ChartColors.gradient, series: series('error', error)),
          ],
        ),
    ];
  }
}

/// "3.2%", "0.45%", "0.0031%": relative errors span orders of magnitude.
String formatRelativeError(double fraction) {
  if (!fraction.isFinite) return formatMetric(fraction);
  final percent = fraction * 100;
  if (percent == 0) return '0%';
  return '${percent >= 1 ? percent.toStringAsFixed(1) : percent.toStringAsPrecision(2)}%';
}

class _NoFields extends StatelessWidget {
  const _NoFields();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_on, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('This run logs no fields', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'To see a predicted field next to the true one, log snapshots with '
              'run.log_field("u", prediction, target).',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldPicker extends StatelessWidget {
  const _FieldPicker({required this.names, required this.selected, required this.onSelected});

  final List<String> names;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final name in names)
        ChoiceChip(
          label: Text(name),
          selected: name == selected,
          onSelected: (_) => onSelected(name),
        ),
    ],
  );
}

/// Which step is shown, with a slider through the logged ones, and its
/// errors.
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.field,
    required this.index,
    required this.hasTarget,
    required this.onChanged,
  });

  final FieldSummary field;
  final int index;
  final bool hasTarget;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = field.steps;
    final step = steps[index];
    final last = steps.length - 1;
    String stat(String key, String Function(double) format) => switch (step.stats[key]) {
      final v? => format(v),
      null => '–',
    };

    return SectionCard(
      title: 'Step ${formatInt(step.step)}',
      trailing: Text(
        index == last ? 'Latest of ${steps.length}' : '${index + 1} of ${steps.length}',
        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (steps.length > 1)
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous snapshot',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: index > 0 ? () => onChanged(index - 1) : null,
                ),
                Expanded(
                  child: Slider(
                    value: index.toDouble(),
                    max: last.toDouble(),
                    divisions: last,
                    label: 'Step ${formatInt(step.step)}',
                    semanticFormatterCallback: (value) =>
                        'Step ${formatInt(steps[value.round()].step)}',
                    onChanged: (value) {
                      if (value.round() != index) onChanged(value.round());
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Next snapshot',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: index < last ? () => onChanged(index + 1) : null,
                ),
              ],
            ),
          const SizedBox(height: 8),
          if (hasTarget)
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Relative L2',
                    value: stat(FieldStatKeys.relL2, formatRelativeError),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(label: 'RMSE', value: stat(FieldStatKeys.rmse, formatMetric)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(
                    label: 'Max error',
                    value: stat(FieldStatKeys.maxError, formatMetric),
                  ),
                ),
              ],
            )
          else
            Text(
              'No ground truth logged: showing the prediction only.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// Prediction, ground truth and error side by side as heatmaps, with the
/// values at a tapped point.
class _HeatmapsCard extends StatelessWidget {
  const _HeatmapsCard({
    required this.snapshot,
    required this.loading,
    required this.point,
    required this.onSelect,
  });

  final FieldSnapshot snapshot;
  final bool loading;
  final GridPoint? point;
  final ValueChanged<GridPoint> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final range = snapshot.valueRange;
    final errorScale = snapshot.maxAbsError;
    final shape = snapshot.shape.join(' × ');
    final original = snapshot.originalShape.join(' × ');

    Widget map(String label, Float32List data, Colormap colormap, double low, double high) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: FieldHeatmap(
                data: data,
                rows: snapshot.rows,
                columns: snapshot.columns,
                low: low,
                high: high,
                colormap: colormap,
                selected: point,
                onSelect: onSelect,
                semanticLabel:
                    '$label of ${snapshot.name} at step ${formatInt(snapshot.step)}, '
                    '$shape grid, values ${formatMetric(low)} to ${formatMetric(high)}',
              ),
            ),
            const SizedBox(height: 6),
            ColorBar(colormap: colormap, low: low, high: high),
          ],
        );

    final maps = [
      map('Prediction', snapshot.prediction, Colormap.viridis, range.min, range.max),
      if (snapshot.target case final target?)
        map('Ground truth', target, Colormap.viridis, range.min, range.max),
      if (snapshot.error case final error?)
        map('Error', error, Colormap.diverging, -errorScale, errorScale),
    ];

    return SectionCard(
      title: snapshot.name,
      trailing: Text(shape == original ? shape : '$shape (of $original)', style: muted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 12.0;
              final perRow = constraints.maxWidth >= 560 ? maps.length : (maps.length == 1 ? 1 : 2);
              final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
              return Wrap(
                spacing: gap,
                runSpacing: 16,
                children: [for (final m in maps) SizedBox(width: width, child: m)],
              );
            },
          ),
          const SizedBox(height: 12),
          SizedBox(height: 3, child: loading ? const LinearProgressIndicator() : null),
          const SizedBox(height: 6),
          _PointReadout(snapshot: snapshot, point: point, style: muted),
        ],
      ),
    );
  }
}

class _PointReadout extends StatelessWidget {
  const _PointReadout({required this.snapshot, required this.point, required this.style});

  final FieldSnapshot snapshot;
  final GridPoint? point;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final p = point;
    if (p == null) return Text('Tap a map to read the values at a point.', style: style);
    String value(Float32List data) => formatMetric(snapshot.at(data, p.row, p.column));
    return Text(
      [
        'Row ${p.row}, column ${p.column}',
        'prediction ${value(snapshot.prediction)}',
        if (snapshot.target case final t?) 'truth ${value(t)}',
        if (snapshot.error case final e?) 'error ${value(e)}',
      ].join(' · '),
      style: style,
    );
  }
}

class _SnapshotError extends StatelessWidget {
  const _SnapshotError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SectionCard(
    child: Row(
      children: [
        const Expanded(child: Text("Couldn't load this snapshot.")),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

/// The relative L2 error at every logged step.
class _ErrorOverTraining extends StatelessWidget {
  const _ErrorOverTraining({required this.field});

  final FieldSummary field;

  @override
  Widget build(BuildContext context) => LineChartCard(
    title: 'Relative L2 error',
    logScale: true,
    formatValue: formatRelativeError,
    lines: [
      ChartLine(
        label: 'Relative L2',
        color: ChartColors.validation,
        series: MetricSeries(
          name: '${field.name}/relL2',
          points: [
            for (final s in field.steps)
              if (s.relL2 case final v?) MetricPoint(s.step, v),
          ],
        ),
      ),
    ],
  );
}
