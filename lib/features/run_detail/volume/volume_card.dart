import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../../models/field_snapshot.dart';
import '../../../shared/colormaps.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/section_card.dart';
import '../widgets/field_heatmap.dart';
import 'volume_renderer.dart';
import 'volume_view.dart';

/// A 3D field (one frame of it, for a 3D rollout) as prediction, ground
/// truth and error side by side in 3D, turning together.
class VolumeCard extends StatefulWidget {
  const VolumeCard({
    super.key,
    required this.snapshot,
    required this.frame,
    required this.playing,
    required this.loading,
  });

  final FieldSnapshot snapshot;
  final int frame;

  /// A rollout playing: render drafts, to keep up.
  final bool playing;
  final bool loading;

  @override
  State<VolumeCard> createState() => _VolumeCardState();
}

class _VolumeCardState extends State<VolumeCard> {
  VolumeMode _mode = VolumeMode.volume;
  double _opacity = 0.5;
  double _level = 0.5;
  VolumeCamera _camera = const VolumeCamera();
  bool _turning = false;

  /// One frame of each array, kept so a render can tell nothing changed.
  final _frames = Expando<Map<int, Float32List>>();

  Float32List _frameOf(Float32List data, int frame) {
    final size = widget.snapshot.frameSize;
    final frames = _frames[data] ??= {};
    return frames[frame] ??= Float32List.sublistView(data, frame * size, (frame + 1) * size);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final snapshot = widget.snapshot;
    final range = snapshot.valueRange;
    final errorScale = snapshot.maxAbsError;
    final shape = snapshot.shape.join(' × ');
    final original = snapshot.originalShape.join(' × ');
    final draft = _turning || widget.playing;

    VolumeStyle style(Colormap colormap, double low, double high) => VolumeStyle(
      mode: _mode,
      low: low,
      high: high,
      colors: colormap.table,
      opacity: _opacity,
      level: _level,
    );

    Widget view(String label, Float32List data, Colormap colormap, double low, double high) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: VolumeView(
                volume: Volume(_frameOf(data, widget.frame), snapshot.shape),
                style: style(colormap, low, high),
                camera: _camera,
                onCamera: (camera) => setState(() => _camera = camera),
                onInteracting: (turning) => setState(() => _turning = turning),
                draft: draft,
                semanticLabel:
                    '$label of ${snapshot.name} in 3D at step ${formatInt(snapshot.step)}, '
                    '$shape, values ${formatMetric(low)} to ${formatMetric(high)}',
              ),
            ),
            const SizedBox(height: 6),
            ColorBar(colormap: colormap, low: low, high: high),
          ],
        );

    final views = [
      view('Prediction', snapshot.prediction, Colormap.viridis, range.min, range.max),
      if (snapshot.target case final target?)
        view('Ground truth', target, Colormap.viridis, range.min, range.max),
      if (snapshot.error case final error?)
        view('Error', error, Colormap.diverging, -errorScale, errorScale),
    ];

    final (sliderLabel, sliderValue, onSlider) = switch (_mode) {
      VolumeMode.volume => ('Opacity', _opacity, (double v) => setState(() => _opacity = v)),
      VolumeMode.isosurface => ('Level', _level, (double v) => setState(() => _level = v)),
      VolumeMode.maxProjection => (null, 0.0, null),
    };

    return SectionCard(
      title: snapshot.name,
      trailing: Text(shape == original ? shape : '$shape (of $original)', style: muted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<VolumeMode>(
            segments: const [
              ButtonSegment(value: VolumeMode.volume, label: Text('Volume')),
              ButtonSegment(value: VolumeMode.maxProjection, label: Text('Max')),
              ButtonSegment(value: VolumeMode.isosurface, label: Text('Surface')),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => setState(() => _mode = selection.single),
          ),
          const SizedBox(height: 4),
          Text(switch (_mode) {
            VolumeMode.volume =>
              'See-through: values far from ${_referenceName(range.min, range.max)} show most.',
            VolumeMode.maxProjection => 'The most extreme value along each line of sight.',
            VolumeMode.isosurface =>
              'Surfaces where values reach the level'
                  '${range.min < 0 && range.max > 0 ? ' (both signs)' : ''}.',
          }, style: muted),
          if (sliderLabel != null)
            Row(
              children: [
                SizedBox(width: 64, child: Text(sliderLabel, style: theme.textTheme.labelLarge)),
                Expanded(
                  child: Slider(
                    value: sliderValue,
                    min: 0.02,
                    max: 0.98,
                    label: _mode == VolumeMode.isosurface
                        ? _levelText(sliderValue, range.min, range.max)
                        : '${(sliderValue * 100).round()}%',
                    semanticFormatterCallback: (v) => '$sliderLabel ${(v * 100).round()}%',
                    // Drafts while dragging the slider too.
                    onChangeStart: (_) => setState(() => _turning = true),
                    onChangeEnd: (_) => setState(() => _turning = false),
                    onChanged: onSlider,
                  ),
                ),
                if (_mode == VolumeMode.isosurface)
                  Text(_levelText(_level, range.min, range.max), style: muted),
              ],
            ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 12.0;
              final perRow = constraints.maxWidth >= 560
                  ? views.length
                  : (views.length == 1 ? 1 : 2);
              final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
              return Wrap(
                spacing: gap,
                runSpacing: 16,
                children: [for (final v in views) SizedBox(width: width, child: v)],
              );
            },
          ),
          const SizedBox(height: 12),
          SizedBox(height: 3, child: widget.loading ? const LinearProgressIndicator() : null),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Drag to turn; pinch or Ctrl/⌘ + scroll to zoom. Axes are numbered as in the array.',
                  style: muted,
                ),
              ),
              TextButton.icon(
                onPressed: _camera == const VolumeCamera()
                    ? null
                    : () => setState(() => _camera = const VolumeCamera()),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset view'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// What "nothing" is for this field (see [VolumeStyle.reference]).
  static String _referenceName(double low, double high) => low < 0 && high > 0
      ? 'zero'
      : low >= 0
      ? 'the lowest value'
      : 'the highest value';

  /// The isosurface level as a value: "±1.2" for a signed field.
  static String _levelText(double level, double low, double high) {
    final style = VolumeStyle(mode: VolumeMode.isosurface, low: low, high: high, colors: const []);
    final distance = level * style.maxDeviation;
    if (low < 0 && high > 0) return '±${formatMetric(distance)}';
    return formatMetric(style.reference + (low >= 0 ? distance : -distance));
  }
}
