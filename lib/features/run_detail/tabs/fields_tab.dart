import 'dart:async';
import 'dart:math' as math;
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
import '../../../shared/widgets/exportable.dart';
import '../../../shared/widgets/line_chart_card.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/spaced_list_view.dart';
import '../../../shared/widgets/stat_tile.dart';
import '../../../shared/widgets/xy_chart_card.dart';
import '../../../models/run_insights.dart';
import '../volume/volume_card.dart';
import '../widgets/field_heatmap.dart';

/// Snapshots of the fields a run predicts (e.g. a PDE solution), logged with
/// `run.log_field(...)` and `run.log_rollout(...)`: the prediction, the true
/// field and their difference at any logged step (over time for a rollout,
/// in slices for 3D), the relative L2 error over training, and what each
/// layer makes of the field (`run.capture_layers(...)`).
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

  /// The frame of a rollout, and whether it is playing.
  int _frame = 0;
  Timer? _player;

  /// The axis a 3D field is cut across (null: its shortest, so the cut is
  /// as large as it gets: for an (x, y, t) volume, a snapshot in time), and
  /// where along it (null: the middle).
  int? _axis;
  int? _slice;

  /// 3D fields: slices instead of the 3D view.
  bool _sliced = false;

  /// The layer shown large below the filmstrip.
  String? _layer;

  /// The last snapshot loaded, shown while the next one loads (so the
  /// sliders don't flash a spinner at every step).
  FieldSnapshot? _shown;

  @override
  void dispose() {
    _player?.cancel();
    super.dispose();
  }

  void _togglePlay(int frames) {
    if (_player != null) {
      setState(() {
        _player!.cancel();
        _player = null;
      });
      return;
    }
    setState(() {
      if (_frame >= frames - 1) _frame = 0;
      _player = Timer.periodic(const Duration(milliseconds: 160), (timer) {
        if (!mounted) return timer.cancel();
        setState(() {
          final frames = _shown?.frames ?? 1;
          if (_frame >= frames - 1) {
            timer.cancel();
            _player = null;
          } else {
            _frame++;
          }
        });
      });
    });
  }

  void _stopPlaying() {
    _player?.cancel();
    _player = null;
  }

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
        final outputs = [
          for (final f in usable)
            if (f.kind == FieldKind.output) f,
        ];
        final layers = [
          for (final f in usable)
            if (f.kind == FieldKind.layer) f,
        ];
        final weights = [
          for (final f in usable)
            if (f.kind == FieldKind.weights) f,
        ];
        final choices = outputs.isNotEmpty
            ? outputs
            : layers.isNotEmpty
            ? layers
            : weights.isNotEmpty
            ? weights
            : usable;
        final field = choices.firstWhere((f) => f.name == _name, orElse: () => choices.first);
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
            if (choices.length > 1)
              _FieldPicker(
                fields: choices,
                selected: field.name,
                onSelected: (name) => setState(() {
                  _stopPlaying();
                  _name = name;
                  _point = null;
                  _frame = 0;
                  _axis = null;
                  _slice = null;
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
            else
              ..._snapshotViews(snapshot, loading),
            if (field.steps.any((s) => s.relL2 != null)) _ErrorOverTraining(field: field),
            if (snapshot?.spectrum case final spectrum?)
              _SpectrumCard(snapshot: snapshot!, spectrum: spectrum),
            _ValidationCard(
              runId: widget.runId,
              field: field.name,
              atStep: step.step,
              worstFields: [
                for (final f in usable)
                  if (f.kind == FieldKind.worst && f.worstOf == field.name) f,
              ],
            ),
            _CurvesCards(runId: widget.runId),
            if (outputs.isNotEmpty && layers.isNotEmpty)
              _LayersCard(
                runId: widget.runId,
                layers: layers,
                atStep: step.step,
                selected: _layer,
                onSelected: (layer) => setState(() => _layer = _layer == layer ? null : layer),
              ),
            if (choices != weights && weights.isNotEmpty)
              _LayersCard(
                runId: widget.runId,
                layers: weights,
                atStep: step.step,
                selected: _layer,
                onSelected: (layer) => setState(() => _layer = _layer == layer ? null : layer),
                title: 'Fourier weights',
                description:
                    'How large each layer\'s learned Fourier weights are, by mode (|w| '
                    'averaged over channels; low modes at the top left). Still large at '
                    'the edge: more modes may help.',
                arrows: false,
              ),
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

  List<Widget> _snapshotViews(FieldSnapshot snapshot, bool loading) {
    final frame = _frame.clamp(0, snapshot.frames - 1);
    final frameControls = snapshot.isRollout
        ? _FrameControls(
            snapshot: snapshot,
            frame: frame,
            playing: _player != null,
            onPlay: () => _togglePlay(snapshot.frames),
            onChanged: (f) => setState(() {
              _stopPlaying();
              _frame = f;
            }),
          )
        : null;
    final rolloutError = switch (snapshot.frameStats[FieldStatKeys.relL2]) {
      final errors? => _RolloutError(snapshot: snapshot, errors: errors, frame: frame),
      null => null,
    };

    if (snapshot.dimensions == 1 && !snapshot.isRollout) return _lineCharts(snapshot, frame: 0);

    final List<Widget> views;
    if (snapshot.dimensions == 1) {
      // A 1D rollout: space-time maps, then the current frame as lines.
      views = [
        _MapsCard(
          snapshot: snapshot,
          planes: (data) => snapshot.spaceTime(data),
          subtitle:
              'Time runs down, from t = ${_formatTime(snapshot.times.first)} '
              'to ${_formatTime(snapshot.times.last)}',
          loading: loading,
          point: _point,
          onSelect: (p) => setState(() {
            _stopPlaying();
            _point = p;
            _frame = p.row;
          }),
          describePoint: (p) =>
              't = ${_formatTime(snapshot.times[p.row.clamp(0, snapshot.frames - 1)])}, '
              '${_describe(snapshot, {0: p.column})}',
          axesNote: _axesNote(snapshot, columnAxis: 0, rows: 'time'),
          markedRow: frame,
          // Few frames of many points: stretch time so the map is readable.
          aspectRatio: (snapshot.shape.single / snapshot.frames).clamp(0.5, 1.6),
        ),
        ?frameControls,
        ..._lineCharts(snapshot, frame: frame),
      ];
    } else {
      final axis = (_axis ?? _shortestAxis(snapshot.shape)).clamp(0, snapshot.dimensions - 1);
      final slice = (_slice ?? snapshot.shape[axis] ~/ 2).clamp(0, snapshot.shape[axis] - 1);
      final toggle = _ViewToggle(sliced: _sliced, onChanged: (v) => setState(() => _sliced = v));
      if (snapshot.dimensions == 3 && !_sliced) {
        return [
          toggle,
          ?frameControls,
          VolumeCard(snapshot: snapshot, frame: frame, playing: _player != null, loading: loading),
          ?rolloutError,
          if (snapshot.isRollout) _PhysicsCard(snapshot: snapshot),
        ];
      }
      views = [
        if (snapshot.dimensions == 3) toggle,
        if (snapshot.dimensions == 3)
          _SliceControls(
            shape: snapshot.shape,
            axis: axis,
            index: slice,
            onAxis: (a) => setState(() {
              _axis = a;
              _slice = null;
              _point = null;
            }),
            onIndex: (i) => setState(() => _slice = i),
          ),
        ?frameControls,
        _MapsCard(
          snapshot: snapshot,
          planes: (data) => snapshot.plane(data, frame: frame, axis: axis, index: slice),
          subtitle: [
            if (snapshot.isRollout) 't = ${_formatTime(snapshot.times[frame])}',
            if (snapshot.dimensions == 3)
              'slice ${slice + 1} of ${snapshot.shape[axis]} across '
                  '${snapshot.domain.isEmpty ? 'axis $axis' : _describe(snapshot, {axis: slice})}',
          ].join(' · '),
          loading: loading,
          point: _point,
          onSelect: (p) => setState(() => _point = p),
          describePoint: (p) {
            if (snapshot.dimensions == 2) return _describe(snapshot, {0: p.row, 1: p.column});
            final (rowAxis, columnAxis) = _planeAxes(axis);
            return _describe(snapshot, {axis: slice, rowAxis: p.row, columnAxis: p.column});
          },
          axesNote: snapshot.dimensions == 2
              ? _axesNote(snapshot, rowAxis: 0, columnAxis: 1)
              : _axesNote(snapshot, rowAxis: _planeAxes(axis).$1, columnAxis: _planeAxes(axis).$2),
        ),
      ];
    }
    return [...views, ?rolloutError, if (snapshot.isRollout) _PhysicsCard(snapshot: snapshot)];
  }

  /// The first of the shortest axes.
  static int _shortestAxis(List<int> shape) {
    var best = 0;
    for (var a = 1; a < shape.length; a++) {
      if (shape[a] < shape[best]) best = a;
    }
    return best;
  }

  static List<Widget> _lineCharts(FieldSnapshot snapshot, {required int frame}) =>
      _fieldLineCharts(snapshot, frame: frame);
}

/// The rows and columns of a 3D field's slice across [axis].
(int, int) _planeAxes(int axis) => switch (axis) {
  0 => (1, 2),
  1 => (0, 2),
  _ => (0, 1),
};

/// Where a grid point is: "y = 0.42, x = 1.57" in the run's domain, else
/// "Row 3, column 7" (2D) or "Point (1, 2, 3)" (3D). [indices]: axis ->
/// grid index.
String _describe(FieldSnapshot s, Map<int, int> indices) {
  final axes = indices.keys.toList()..sort();
  if (s.domain.isEmpty) {
    if (axes.length == 2 && s.dimensions == 2) {
      return 'Row ${indices[0]}, column ${indices[1]}';
    }
    if (axes.length == 1) return 'point ${indices[axes.single]}';
    return 'Point (${[for (final a in axes) indices[a]].join(', ')})';
  }
  return [
    for (final a in axes)
      '${s.domain.axisName(a)} = '
          '${formatCoordinate(s.domain.coordinate(a, indices[a]!.toDouble(), s.shape[a]))}',
  ].join(', ');
}

/// Which way the axes run on a map, in the run's domain: "x 0 → 1 across,
/// y 0 → 1 down". Null without a domain.
String? _axesNote(FieldSnapshot s, {int? rowAxis, required int columnAxis, String? rows}) {
  if (s.domain.isEmpty) return null;
  String axis(int a) {
    final range = s.domain.extent?[a];
    return range == null
        ? s.domain.axisName(a)
        : '${s.domain.axisName(a)} ${formatCoordinate(range.$1)} → ${formatCoordinate(range.$2)}';
  }

  return [
    '${axis(columnAxis)} across',
    if (rowAxis != null) '${axis(rowAxis)} down' else if (rows != null) '$rows down',
  ].join(', ');
}

/// A 1D field (one frame of a rollout) as lines: prediction and truth, and
/// their difference.
List<Widget> _fieldLineCharts(FieldSnapshot snapshot, {required int frame}) {
  {
    MetricSeries series(String name, Float32List data) {
      final values = snapshot.plane(data, frame: frame).values;
      return MetricSeries(
        name: name,
        points: [for (var i = 0; i < values.length; i++) MetricPoint(i, values[i])],
      );
    }

    final when = snapshot.isRollout ? ' at t = ${_formatTime(snapshot.times[frame])}' : '';
    final domain = snapshot.domain;
    final xAxis = ChartXAxis.positions(
      domain.axes == null ? 'Point' : domain.axisName(0),
      coordinate: domain.extent == null
          ? null
          : (i) => domain.coordinate(0, i, snapshot.shape.single),
    );
    return [
      LineChartCard(
        title: '${snapshot.hasTarget ? 'Prediction and ground truth' : 'Prediction'}$when',
        xAxis: xAxis,
        showLatest: false,
        maxPoints: 512,
        height: 200,
        yRange: (min: snapshot.valueRange.min, max: snapshot.valueRange.max),
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
          title: 'Error (prediction − truth)$when',
          xAxis: xAxis,
          showLatest: false,
          maxPoints: 512,
          yRange: (min: -snapshot.maxAbsError, max: snapshot.maxAbsError),
          lines: [
            ChartLine(label: 'Error', color: ChartColors.gradient, series: series('error', error)),
          ],
        ),
    ];
  }
}

/// A frame's time: "0.3", "12", "1.5e-4".
String _formatTime(double t) {
  if (!t.isFinite) return formatMetric(t);
  if (t == t.roundToDouble() && t.abs() < 1e6) return t.toInt().toString();
  if (t.abs() < 1e-3 || t.abs() >= 1e4) return t.toStringAsExponential(2);
  // At most 3 decimals, without trailing zeros: 0.30000000000000004 -> "0.3".
  var text = t.toStringAsFixed(3);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
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
              'run.log_field("u", prediction, target), or a rollout with run.log_rollout.',
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
  const _FieldPicker({required this.fields, required this.selected, required this.onSelected});

  final List<FieldSummary> fields;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final field in fields)
        ChoiceChip(
          avatar: switch (field) {
            FieldSummary(isRollout: true) => const Icon(Icons.movie_outlined, size: 18),
            FieldSummary(shape: [_, _, _]) => const Icon(Icons.view_in_ar_outlined, size: 18),
            _ => null,
          },
          label: Text(field.label),
          tooltip: [
            if (field.isRollout) 'Rollout of ${field.frames} frames',
            '${field.shape.length}D, ${field.shape.join(' × ')}',
          ].join(', '),
          selected: field.name == selected,
          onSelected: (_) => onSelected(field.name),
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
            _IndexSlider(
              index: index,
              count: steps.length,
              previous: 'Previous snapshot',
              next: 'Next snapshot',
              label: (i) => 'Step ${formatInt(steps[i].step)}',
              onChanged: onChanged,
            ),
          const SizedBox(height: 8),
          if (hasTarget)
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: field.isRollout ? 'Relative L2, all frames' : 'Relative L2',
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
              field.kind == FieldKind.layer
                  ? 'A layer inside the model: there is no ground truth to compare with.'
                  : 'No ground truth logged: showing the prediction only.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// A slider over [count] positions, with buttons for one back and forward.
class _IndexSlider extends StatelessWidget {
  const _IndexSlider({
    required this.index,
    required this.count,
    required this.previous,
    required this.next,
    required this.label,
    required this.onChanged,
    this.leading,
  });

  final int index;
  final int count;
  final String previous;
  final String next;
  final String Function(int index) label;
  final ValueChanged<int> onChanged;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final last = count - 1;
    return Row(
      children: [
        ?leading,
        IconButton(
          tooltip: previous,
          icon: const Icon(Icons.chevron_left),
          onPressed: index > 0 ? () => onChanged(index - 1) : null,
        ),
        Expanded(
          child: Slider(
            value: index.toDouble(),
            max: last.toDouble(),
            divisions: last,
            label: label(index),
            semanticFormatterCallback: (value) => label(value.round()),
            onChanged: (value) {
              if (value.round() != index) onChanged(value.round());
            },
          ),
        ),
        IconButton(
          tooltip: next,
          icon: const Icon(Icons.chevron_right),
          onPressed: index < last ? () => onChanged(index + 1) : null,
        ),
      ],
    );
  }
}

/// Play a rollout, or pick one of its frames.
class _FrameControls extends StatelessWidget {
  const _FrameControls({
    required this.snapshot,
    required this.frame,
    required this.playing,
    required this.onPlay,
    required this.onChanged,
  });

  final FieldSnapshot snapshot;
  final int frame;
  final bool playing;
  final VoidCallback onPlay;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final relL2 = snapshot.frameStats[FieldStatKeys.relL2]?[frame];
    return SectionCard(
      title: 'Rollout: t = ${_formatTime(snapshot.times[frame])}',
      trailing: Text(
        [
          'Frame ${frame + 1} of ${snapshot.frames}',
          if (relL2 != null) 'rel. L2 ${formatRelativeError(relL2)}',
        ].join(' · '),
        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      child: _IndexSlider(
        index: frame,
        count: snapshot.frames,
        previous: 'Previous frame',
        next: 'Next frame',
        label: (i) => 't = ${_formatTime(snapshot.times[i])}',
        onChanged: onChanged,
        leading: IconButton.filledTonal(
          tooltip: playing ? 'Pause' : 'Play the rollout',
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: onPlay,
        ),
      ),
    );
  }
}

/// 3D fields: the 3D view, or slices.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.sliced, required this.onChanged});

  final bool sliced;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Center(
    child: SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, icon: Icon(Icons.view_in_ar_outlined), label: Text('3D view')),
        ButtonSegment(value: true, icon: Icon(Icons.layers_outlined), label: Text('Slices')),
      ],
      selected: {sliced},
      onSelectionChanged: (selection) => onChanged(selection.single),
    ),
  );
}

/// Which axis a 3D field is cut across, and where.
class _SliceControls extends StatelessWidget {
  const _SliceControls({
    required this.shape,
    required this.axis,
    required this.index,
    required this.onAxis,
    required this.onIndex,
  });

  final List<int> shape;
  final int axis;
  final int index;
  final ValueChanged<int> onAxis;
  final ValueChanged<int> onIndex;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: '3D field: a slice across axis $axis',
    trailing: Text('${index + 1} of ${shape[axis]}'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<int>(
          segments: [
            for (var a = 0; a < 3; a++)
              ButtonSegment(value: a, label: Text('Axis $a (${shape[a]})')),
          ],
          selected: {axis},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onAxis(selection.single),
        ),
        const SizedBox(height: 8),
        _IndexSlider(
          index: index,
          count: shape[axis],
          previous: 'Previous slice',
          next: 'Next slice',
          label: (i) => 'Slice ${i + 1}',
          onChanged: onIndex,
        ),
      ],
    ),
  );
}

/// Prediction, ground truth and error side by side as heatmaps of the same
/// 2D cut ([planes]), with the values at a tapped point.
class _MapsCard extends StatelessWidget {
  const _MapsCard({
    required this.snapshot,
    required this.planes,
    required this.subtitle,
    required this.loading,
    required this.point,
    required this.onSelect,
    required this.describePoint,
    this.markedRow,
    this.aspectRatio,
    this.axesNote,
    this.title,
  });

  final FieldSnapshot snapshot;
  final FieldPlane Function(Float32List data) planes;

  /// Which way the domain's axes run on the maps (see [_axesNote]).
  final String? axesNote;

  /// Default: the field's name.
  final String? title;
  final String subtitle;
  final bool loading;
  final GridPoint? point;
  final ValueChanged<GridPoint> onSelect;
  final String Function(GridPoint point) describePoint;

  /// A row to mark (the current frame of a space-time map).
  final int? markedRow;

  /// Width over height of the maps; default: square grid cells.
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final range = snapshot.valueRange;
    final errorScale = snapshot.maxAbsError;
    final shape = snapshot.shape.join(' × ');
    final original = snapshot.originalShape.join(' × ');
    final prediction = planes(snapshot.prediction);
    final target = snapshot.target == null ? null : planes(snapshot.target!);
    final error = snapshot.error == null ? null : planes(snapshot.error!);
    final rows = prediction.rows, columns = prediction.columns;
    final picked = switch (point) {
      final p? => (row: p.row.clamp(0, rows - 1), column: p.column.clamp(0, columns - 1)),
      null => null,
    };

    Widget map(String label, FieldPlane plane, Colormap colormap, double low, double high) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: FieldHeatmap(
                data: plane.values,
                rows: rows,
                columns: columns,
                low: low,
                high: high,
                colormap: colormap,
                selected: picked,
                onSelect: onSelect,
                markedRow: markedRow,
                aspectRatio: aspectRatio,
                semanticLabel:
                    '$label of ${snapshot.name} at step ${formatInt(snapshot.step)}, '
                    '$rows by $columns, values ${formatMetric(low)} to ${formatMetric(high)}',
              ),
            ),
            const SizedBox(height: 6),
            ColorBar(colormap: colormap, low: low, high: high),
          ],
        );

    final maps = [
      map('Prediction', prediction, Colormap.viridis, range.min, range.max),
      if (target != null) map('Ground truth', target, Colormap.viridis, range.min, range.max),
      if (error != null) map('Error', error, Colormap.diverging, -errorScale, errorScale),
    ];

    String readout(GridPoint p) {
      String value(FieldPlane plane) => formatMetric(plane.values[p.row * columns + p.column]);
      return [
        describePoint(p),
        'prediction ${value(prediction)}',
        if (target != null) 'truth ${value(target)}',
        if (error != null) 'error ${value(error)}',
      ].join(' · ');
    }

    return Exportable(
      fileName: '${title ?? snapshot.name} step ${snapshot.step}',
      builder: (context, exportButton) => SectionCard(
        title: title ?? snapshot.name,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(shape == original ? shape : '$shape (of $original)', style: muted),
            ),
            exportButton,
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (subtitle.isNotEmpty) ...[Text(subtitle, style: muted), const SizedBox(height: 10)],
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final perRow = constraints.maxWidth >= 560
                    ? maps.length
                    : (maps.length == 1 ? 1 : 2);
                final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
                return Wrap(
                  spacing: gap,
                  runSpacing: 16,
                  children: [for (final m in maps) SizedBox(width: width, child: m)],
                );
              },
            ),
            if (axesNote != null) ...[const SizedBox(height: 8), Text(axesNote!, style: muted)],
            const SizedBox(height: 12),
            SizedBox(height: 3, child: loading ? const LinearProgressIndicator() : null),
            const SizedBox(height: 6),
            Text(
              point == null ? 'Tap a map to read the values at a point.' : readout(picked!),
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// The relative L2 error of each frame of a rollout: how error builds up.
class _RolloutError extends StatelessWidget {
  const _RolloutError({required this.snapshot, required this.errors, required this.frame});

  final FieldSnapshot snapshot;
  final List<double> errors;
  final int frame;

  @override
  Widget build(BuildContext context) => LineChartCard(
    title: 'Error along the rollout (step ${formatInt(snapshot.step)})',
    formatValue: formatRelativeError,
    xAxis: const ChartXAxis.positions('Frame'),
    showLatest: false,
    lines: [
      ChartLine(
        label: 'Relative L2',
        color: ChartColors.validation,
        series: MetricSeries(
          name: '${snapshot.name}/frameRelL2',
          points: [for (final (i, e) in errors.indexed) MetricPoint(i, e)],
        ),
      ),
    ],
  );
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
    title: 'Relative L2 error over training',
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

// Inside the model ---------------------------------------------------------------

/// The step of [layer] to show next to output step [step]: the latest one
/// at or before it, else its first.
int _layerStep(FieldSummary layer, int step) {
  var chosen = layer.steps.first.step;
  for (final s in layer.steps) {
    if (s.step <= step) chosen = s.step;
  }
  return chosen;
}

/// A filmstrip of what each layer outputs, input to output, for the step
/// shown (or the nearest one before it); tap one to see it large.
class _LayersCard extends StatelessWidget {
  const _LayersCard({
    required this.runId,
    required this.layers,
    required this.atStep,
    required this.selected,
    required this.onSelected,
    this.title = 'Inside the model',
    this.description =
        'What each layer outputs for one sample, in order through the network. '
        'Channels are averaged; each map has its own colour scale.',
    this.arrows = true,
  });

  final String title;
  final String description;

  /// Arrows between the tiles: they follow each other through the network.
  final bool arrows;
  final String runId;
  final List<FieldSummary> layers;
  final int atStep;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final steps = {for (final l in layers) _layerStep(l, atStep)};
    final open = layers.where((l) => l.name == selected).firstOrNull;
    return SectionCard(
      title: title,
      trailing: Text(
        steps.length == 1 ? 'Step ${formatInt(steps.single)}' : 'Nearest steps',
        style: muted,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(description, style: muted),
          const SizedBox(height: 12),
          SizedBox(
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: layers.length,
              separatorBuilder: (_, _) => arrows
                  ? const Padding(
                      padding: EdgeInsets.only(top: 50),
                      child: Icon(Icons.arrow_forward, size: 16),
                    )
                  : const SizedBox(width: 8),
              itemBuilder: (context, i) => _LayerTile(
                runId: runId,
                layer: layers[i],
                step: _layerStep(layers[i], atStep),
                selected: layers[i].name == selected,
                onTap: () => onSelected(layers[i].name),
              ),
            ),
          ),
          if (open != null) ...[
            const SizedBox(height: 12),
            _LayerDetail(runId: runId, layer: open, step: _layerStep(open, atStep)),
          ],
        ],
      ),
    );
  }
}

/// A layer snapshot as one plane, for its filmstrip tile: a 1D output as a
/// strip, 2D as is, the middle slice of a 3D one across its shortest axis.
FieldPlane _layerPlane(FieldSnapshot s) {
  if (s.dimensions != 3) return s.plane(s.prediction);
  final axis = _FieldsTabState._shortestAxis(s.shape);
  return s.plane(s.prediction, axis: axis, index: s.shape[axis] ~/ 2);
}

class _LayerTile extends ConsumerWidget {
  const _LayerTile({
    required this.runId,
    required this.layer,
    required this.step,
    required this.selected,
    required this.onTap,
  });

  final String runId;
  final FieldSummary layer;
  final int step;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final value = ref.watch(fieldSnapshotProvider((runId: runId, name: layer.name, step: step)));
    final snapshot = value.value;
    return SizedBox(
      width: 120,
      child: Material(
        color: selected ? theme.colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  layer.label,
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 108,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: switch (snapshot) {
                          final s? => Center(
                            child: _LayerMap(snapshot: s, plane: _layerPlane(s)),
                          ),
                          null when value.hasError => const Center(
                            child: Icon(Icons.error_outline),
                          ),
                          null => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        },
                      ),
                      // A 3D output: the tile is a slice; tapping opens it in 3D.
                      if (layer.shape.length == 3)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: Tooltip(
                            message: '3D output: tap to see it in 3D',
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Icon(Icons.view_in_ar_outlined, size: 14),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  snapshot?.reduction ?? '',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LayerMap extends StatelessWidget {
  const _LayerMap({required this.snapshot, required this.plane, this.onSelect, this.selected});

  final FieldSnapshot snapshot;
  final FieldPlane plane;
  final ValueChanged<GridPoint>? onSelect;
  final GridPoint? selected;

  @override
  Widget build(BuildContext context) {
    final range = snapshot.valueRange;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: FieldHeatmap(
        data: plane.values,
        rows: plane.rows,
        columns: plane.columns,
        low: range.min,
        high: range.max,
        colormap: Colormap.viridis,
        aspectRatio: plane.rows == 1 ? 6 : null,
        onSelect: onSelect,
        selected: selected,
        semanticLabel:
            'Output of layer ${snapshot.layer ?? snapshot.name}, ${snapshot.reduction ?? ''}, '
            'values ${formatMetric(range.min)} to ${formatMetric(range.max)}',
      ),
    );
  }
}

class _LayerDetail extends ConsumerStatefulWidget {
  const _LayerDetail({required this.runId, required this.layer, required this.step});

  final String runId;
  final FieldSummary layer;
  final int step;

  @override
  ConsumerState<_LayerDetail> createState() => _LayerDetailState();
}

class _LayerDetailState extends ConsumerState<_LayerDetail> {
  GridPoint? _point;

  /// 3D layers: slices instead of the 3D view, and which slice (null: the
  /// middle, across the shortest axis).
  bool _sliced = false;
  int? _axis;
  int? _slice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final snapshot = ref
        .watch(
          fieldSnapshotProvider((runId: widget.runId, name: widget.layer.name, step: widget.step)),
        )
        .value;
    if (snapshot == null) return const SizedBox(height: 40);
    final is3D = snapshot.dimensions == 3;
    final axis = is3D ? (_axis ?? _FieldsTabState._shortestAxis(snapshot.shape)) : 0;
    final slice = is3D
        ? (_slice ?? snapshot.shape[axis] ~/ 2).clamp(0, snapshot.shape[axis] - 1)
        : 0;
    final plane = snapshot.plane(snapshot.prediction, axis: axis, index: slice);
    final range = snapshot.valueRange;
    final point = switch (_point) {
      final p? => (
        row: p.row.clamp(0, plane.rows - 1),
        column: p.column.clamp(0, plane.columns - 1),
      ),
      null => null,
    };
    final caption = Text(
      [
        if (snapshot.layerShape case final s?)
          snapshot.kind == FieldKind.weights
              ? 'weights ${s.join(' × ')}'
              : 'output ${s.join(' × ')} per sample',
        ?snapshot.reduction,
        if (is3D) '3D: ${snapshot.shape.join(' × ')}',
      ].join(' · '),
      style: muted,
    );

    if (is3D && !_sliced) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.layer.label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          caption,
          const SizedBox(height: 8),
          _ViewToggle(sliced: false, onChanged: (v) => setState(() => _sliced = v)),
          const SizedBox(height: 8),
          VolumeCard(
            // A new layer starts from the default view.
            key: ValueKey(widget.layer.name),
            snapshot: snapshot,
            frame: 0,
            playing: false,
            loading: false,
            framed: false,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.layer.label, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        caption,
        const SizedBox(height: 8),
        if (is3D) ...[
          _ViewToggle(sliced: true, onChanged: (v) => setState(() => _sliced = v)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (var a = 0; a < 3; a++)
                ButtonSegment(value: a, label: Text('Axis $a (${snapshot.shape[a]})')),
            ],
            selected: {axis},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => setState(() {
              _axis = selection.single;
              _slice = null;
              _point = null;
            }),
          ),
          _IndexSlider(
            index: slice,
            count: snapshot.shape[axis],
            previous: 'Previous slice',
            next: 'Next slice',
            label: (i) => 'Slice ${i + 1}',
            onChanged: (i) => setState(() => _slice = i),
          ),
          Text('Slice ${slice + 1} of ${snapshot.shape[axis]} across axis $axis', style: muted),
          const SizedBox(height: 8),
        ],
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LayerMap(
                  snapshot: snapshot,
                  plane: plane,
                  selected: point,
                  onSelect: (p) => setState(() => _point = p),
                ),
                const SizedBox(height: 6),
                ColorBar(colormap: Colormap.viridis, low: range.min, high: range.max),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          point == null
              ? 'Tap the map to read a value.'
              : 'Row ${point.row}, column ${point.column} · '
                    '${formatMetric(plane.values[point.row * plane.columns + point.column])}',
          style: muted,
        ),
      ],
    );
  }
}

// Diagnostics: spectrum, physics, the validation set, curves ---------------------

/// The energy spectrum of the prediction and the truth, log-log: missing
/// energy at high wavenumbers is a neural operator's typical failure.
class _SpectrumCard extends StatelessWidget {
  const _SpectrumCard({required this.snapshot, required this.spectrum});

  final FieldSnapshot snapshot;
  final FieldSpectrum spectrum;

  @override
  Widget build(BuildContext context) => XYChartCard(
    title: 'Energy spectrum',
    subtitle: [
      'step ${formatInt(snapshot.step)}',
      if (snapshot.isRollout) 'last frame, t = ${_formatTime(snapshot.times.last)}',
      'on the full grid',
    ].join(' · '),
    xLabel: 'Wavenumber |k|',
    logX: true,
    logY: true,
    series: [
      XYSeries(
        label: 'Prediction',
        color: ChartColors.train,
        points: [for (final (i, k) in spectrum.k.indexed) (k, spectrum.prediction[i])],
      ),
      if (spectrum.target case final target?)
        XYSeries(
          label: 'Ground truth',
          color: ChartColors.validation,
          points: [for (final (i, k) in spectrum.k.indexed) (k, target[i])],
        ),
    ],
  );
}

/// What a rollout should conserve, frame by frame, for the prediction and
/// the truth: its mean (mass), mean square (energy) and minimum.
class _PhysicsCard extends StatefulWidget {
  const _PhysicsCard({required this.snapshot});

  final FieldSnapshot snapshot;

  @override
  State<_PhysicsCard> createState() => _PhysicsCardState();
}

class _PhysicsCardState extends State<_PhysicsCard> {
  var _quantity = FieldStatKeys.mean;

  static const _quantities = {
    FieldStatKeys.mean: ('Mean', FieldStatKeys.targetMean),
    FieldStatKeys.meanSquare: ('Mean square', FieldStatKeys.targetMeanSquare),
    FieldStatKeys.min: ('Minimum', FieldStatKeys.targetMin),
  };

  @override
  Widget build(BuildContext context) {
    final stats = widget.snapshot.frameStats;
    final available = [
      for (final key in _quantities.keys)
        if (stats[key] != null) key,
    ];
    if (available.isEmpty) return const SizedBox.shrink();
    final key = available.contains(_quantity) ? _quantity : available.first;
    final (label, targetKey) = _quantities[key]!;
    final times = widget.snapshot.times;
    List<(double, double)> along(List<double> values) => [
      for (final (i, v) in values.indexed) (times[i], v),
    ];
    return XYChartCard(
      title: 'Physics along the rollout',
      subtitle: 'What should be conserved stays flat; the truth shows what to expect.',
      xLabel: 'Time',
      controls: SegmentedButton<String>(
        segments: [
          for (final k in available) ButtonSegment(value: k, label: Text(_quantities[k]!.$1)),
        ],
        selected: {key},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() => _quantity = s.single),
      ),
      series: [
        XYSeries(label: '$label, prediction', color: ChartColors.train, points: along(stats[key]!)),
        if (stats[targetKey] case final target?)
          XYSeries(label: '$label, truth', color: ChartColors.validation, points: along(target)),
      ],
    );
  }
}

/// The whole validation set at the step shown (or the nearest before it):
/// how the error is spread over samples, and the worst ones, to open.
class _ValidationCard extends ConsumerWidget {
  const _ValidationCard({
    required this.runId,
    required this.field,
    required this.atStep,
    required this.worstFields,
  });

  final String runId;
  final String field;
  final int atStep;
  final List<FieldSummary> worstFields;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final series = ref
        .watch(evalsProvider(runId))
        .value
        ?.where((e) => e.name == field && e.steps.isNotEmpty)
        .firstOrNull;
    if (series == null) return const SizedBox.shrink();
    final eval = series.atOrBefore(atStep, (s) => s.step);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    String stat(String key) => switch (eval.stats[key]) {
      final v? => formatRelativeError(v),
      null => '–',
    };
    final nonFinite = eval.stats['nonFinite'] ?? 0;
    return Exportable(
      fileName: '$field validation set step ${eval.step}',
      builder: (context, exportButton) => SectionCard(
        title: 'Validation set',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '${formatInt(eval.count)} samples · step ${formatInt(eval.step)}',
                style: muted,
              ),
            ),
            exportButton,
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: StatTile(label: 'Median', value: stat('median')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(label: '90% under', value: stat('p90')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: StatTile(label: 'Worst', value: stat('max')),
                ),
              ],
            ),
            if (nonFinite > 0) ...[
              const SizedBox(height: 6),
              Text(
                '${formatInt(nonFinite.round())} samples have no finite error (NaN or ∞).',
                style: muted?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (eval.histogram case final histogram?) ...[
              const SizedBox(height: 12),
              _ErrorHistogramView(histogram: histogram),
            ],
            if (eval.worst.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Worst samples', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              SizedBox(
                height: 150,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: eval.worst.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final worst = eval.worst[i];
                    final summary = worstFields
                        .where((f) => f.name == worst.fieldName(field))
                        .firstOrNull;
                    return _WorstTile(
                      runId: runId,
                      worst: worst,
                      name: worst.fieldName(field),
                      step: summary == null ? eval.step : _layerStep(summary, eval.step),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// How many samples have each error (relative L2, log scale).
class _ErrorHistogramView extends StatelessWidget {
  const _ErrorHistogramView({required this.histogram});

  final ErrorHistogram histogram;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final counts = histogram.counts;
    final most = counts.fold(0, math.max);
    final total = counts.fold(0, (a, b) => a + b);
    return Semantics(
      label:
          'Error histogram: $total samples, from ${formatRelativeError(histogram.edges.first)} '
          'to ${formatRelativeError(histogram.edges.last)}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 72,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final c in counts)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 0.5),
                        child: FractionallySizedBox(
                          heightFactor: most == 0 ? 0 : math.max(c / most, c > 0 ? 0.04 : 0),
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            decoration: BoxDecoration(
                              color: ChartColors.validation.withValues(alpha: 0.75),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(formatRelativeError(histogram.edges.first), style: muted),
                Expanded(
                  child: Text(
                    'relative L2 per sample (log scale)',
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                ),
                Text(formatRelativeError(histogram.edges.last), style: muted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the worst samples: its error map, rank, index and error. Tap to
/// see it in full.
class _WorstTile extends ConsumerWidget {
  const _WorstTile({
    required this.runId,
    required this.worst,
    required this.name,
    required this.step,
  });

  final String runId;
  final WorstSample worst;
  final String name;
  final int step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final value = ref.watch(fieldSnapshotProvider((runId: runId, name: name, step: step)));
    final snapshot = value.value;
    return SizedBox(
      width: 112,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: snapshot == null
              ? null
              : () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => _WorstSheet(snapshot: snapshot, worst: worst),
                ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 92,
                  child: switch (snapshot) {
                    final s? when s.error != null => Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: () {
                          final plane = _layerPlaneOf(s, s.error!);
                          return FieldHeatmap(
                            data: plane.values,
                            rows: plane.rows,
                            columns: plane.columns,
                            low: -s.maxAbsError,
                            high: s.maxAbsError,
                            colormap: Colormap.diverging,
                            aspectRatio: plane.rows == 1 ? 6 : null,
                            semanticLabel:
                                'Error map of sample ${worst.sample}, '
                                'relative L2 ${formatRelativeError(worst.relL2)}',
                          );
                        }(),
                      ),
                    ),
                    null when value.hasError => const Center(child: Icon(Icons.error_outline)),
                    _ => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  '#${worst.rank} · sample ${worst.sample}',
                  style: theme.textTheme.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  formatRelativeError(worst.relL2),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A plane of [data] for a small tile: 1D as a strip, 2D as is, a 3D
/// field's middle slice across its shortest axis.
FieldPlane _layerPlaneOf(FieldSnapshot s, Float32List data) {
  if (s.dimensions != 3) return s.plane(data);
  final axis = _FieldsTabState._shortestAxis(s.shape);
  return s.plane(data, axis: axis, index: s.shape[axis] ~/ 2);
}

/// A worst sample in full: prediction, truth and error, like the main view.
class _WorstSheet extends StatefulWidget {
  const _WorstSheet({required this.snapshot, required this.worst});

  final FieldSnapshot snapshot;
  final WorstSample worst;

  @override
  State<_WorstSheet> createState() => _WorstSheetState();
}

class _WorstSheetState extends State<_WorstSheet> {
  GridPoint? _point;

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final title =
        'Sample ${widget.worst.sample} · #${widget.worst.rank} worst · '
        '${formatRelativeError(widget.worst.relL2)}';
    final List<Widget> views;
    if (s.dimensions == 1) {
      views = _fieldLineCharts(s, frame: 0);
    } else if (s.dimensions == 3) {
      views = [VolumeCard(snapshot: s, frame: 0, playing: false, loading: false)];
    } else {
      views = [
        _MapsCard(
          snapshot: s,
          title: title,
          planes: (data) => s.plane(data),
          subtitle: '',
          loading: false,
          point: _point,
          onSelect: (p) => setState(() => _point = p),
          describePoint: (p) => _describe(s, {0: p.row, 1: p.column}),
          axesNote: _axesNote(s, rowAxis: 0, columnAxis: 1),
        ),
      ];
    }
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          if (s.dimensions != 2) ...[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
          ],
          for (final v in views) ...[v, const SizedBox(height: 12)],
        ],
      ),
    );
  }
}

/// Every curve the run logs (`run.log_curve`), at its latest step: e.g. the
/// error against resolution, or against a PDE parameter, with the range
/// seen in training shaded.
class _CurvesCards extends ConsumerWidget {
  const _CurvesCards({required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final curves = ref.watch(curvesProvider(runId)).value ?? const [];
    final shown = [
      for (final c in curves)
        if (c.steps.isNotEmpty) c,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, curve) in shown.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          _curveCard(curve),
        ],
      ],
    );
  }

  static Widget _curveCard(LoggedSeries<CurveStep> curve) {
    final latest = curve.steps.last;
    bool spansDecades(List<double> v) {
      final positive = [
        for (final x in v)
          if (x.isFinite && x > 0) x,
      ];
      return positive.length == v.where((x) => x.isFinite).length &&
          positive.length > 1 &&
          positive.reduce(math.max) / positive.reduce(math.min) >= 10;
    }

    final relative = latest.yLabel.toLowerCase().contains('relative');
    final train = latest.trainRange;
    return XYChartCard(
      title: '${curve.name[0].toUpperCase()}${curve.name.substring(1)}',
      subtitle: 'step ${formatInt(latest.step)}',
      xLabel: latest.xLabel,
      logX: spansDecades(latest.x),
      logY: spansDecades(latest.y),
      band: train,
      bandLabel: train == null
          ? null
          : train.$1 == train.$2
          ? 'Dashed: trained at ${formatCoordinate(train.$1)}'
          : 'Shaded: seen in training',
      formatY: relative ? formatRelativeError : formatMetric,
      formatYTick: relative ? formatRelativeError : null,
      series: [
        XYSeries(
          label: latest.yLabel.isEmpty ? curve.name : latest.yLabel,
          color: ChartColors.validation,
          points: [for (final (i, x) in latest.x.indexed) (x, latest.y[i])],
        ),
      ],
    );
  }
}
