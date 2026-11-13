import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'model_helpers.dart';

/// Keys of the error statistics the logger computes for a field snapshot
/// (on the full-resolution arrays).
abstract final class FieldStatKeys {
  static const relL2 = 'relL2';
  static const rmse = 'rmse';
  static const maxError = 'maxError';
}

/// What a field shows: the model's output (next to the true field), or
/// what one layer outputs inside the model.
enum FieldKind {
  output,
  layer;

  static FieldKind parse(Object? json) => json == 'layer' ? layer : output;
}

/// One step at which a field was logged, with its error statistics.
class FieldStep {
  const FieldStep({required this.step, this.stats = const {}});

  factory FieldStep.fromJson(Map<String, Object?> json) =>
      FieldStep(step: (json['step']! as num).toInt(), stats: _stats(json['stats']));

  final int step;

  /// E.g. `relL2`, `rmse`, `maxError` (see [FieldStatKeys]); may be NaN.
  final Map<String, double> stats;

  double? get relL2 => stats[FieldStatKeys.relL2];

  Map<String, Object?> toJson() => {'step': step, 'stats': _statsJson(stats)};

  @override
  bool operator ==(Object other) =>
      other is FieldStep && other.step == step && _sameStats(other.stats, stats);

  @override
  int get hashCode => Object.hash(step, stats.length);
}

/// A field a run logs snapshots of (e.g. `vorticity`), and when. The data
/// itself comes per step, as a [FieldSnapshot].
class FieldSummary {
  /// Pass unmodifiable lists: a summary never changes.
  const FieldSummary({
    required this.name,
    required this.shape,
    required this.steps,
    this.kind = FieldKind.output,
    this.frames = 1,
    this.layer,
    this.position,
  });

  factory FieldSummary.fromJson(Map<String, Object?> json) => FieldSummary(
    name: json['name']! as String,
    kind: FieldKind.parse(json['kind']),
    shape: List.unmodifiable([for (final n in json['shape']! as List) (n as num).toInt()]),
    frames: (json['frames'] as num?)?.toInt() ?? 1,
    layer: json['layer'] as String?,
    position: (json['position'] as num?)?.toInt(),
    steps: List.unmodifiable([
      for (final s in json['steps']! as List) FieldStep.fromJson(s as Map<String, Object?>),
    ]),
  );

  final String name;
  final FieldKind kind;

  /// One frame's shape: 1 to 3 axes (as stored).
  final List<int> shape;

  /// More than one for a rollout (a field over time).
  final int frames;

  /// The layer, for a [FieldKind.layer] field, and its order in the model.
  final String? layer;
  final int? position;

  /// In step order.
  final List<FieldStep> steps;

  bool get isRollout => frames > 1;

  /// What to call it on screen: the layer's name for a layer.
  String get label => layer ?? name;

  Map<String, Object?> toJson() => {
    'name': name,
    'kind': kind.name,
    'shape': shape,
    'frames': frames,
    'layer': layer,
    'position': position,
    'steps': [for (final s in steps) s.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is FieldSummary &&
      other.name == name &&
      other.kind == kind &&
      other.frames == frames &&
      other.layer == layer &&
      other.position == position &&
      deepListEquals(other.shape, shape) &&
      deepListEquals(other.steps, steps);

  @override
  int get hashCode => Object.hash(name, kind, frames, Object.hashAll(shape), Object.hashAll(steps));
}

/// A 2D cut of a field, ready to draw: [rows] × [columns] values, row by
/// row.
typedef FieldPlane = ({Float32List values, int rows, int columns});

/// A field at one step: the model's prediction, and the true field
/// ([target]) if the run logged it. Each frame is 1D, 2D or 3D, stored row
/// by row (the last axis fastest); a rollout has several frames, one after
/// the other.
class FieldSnapshot {
  FieldSnapshot({
    required this.name,
    required this.step,
    required this.shape,
    List<int>? originalShape,
    this.kind = FieldKind.output,
    this.frames = 1,
    List<double>? times,
    required this.prediction,
    this.target,
    this.stats = const {},
    this.frameStats = const {},
    this.layer,
    this.reduction,
    this.layerShape,
  }) : originalShape = originalShape ?? shape,
       times = times ?? List.unmodifiable([for (var i = 0; i < frames; i++) i.toDouble()]) {
    if (shape.isEmpty || shape.length > 3) {
      throw ArgumentError('A field has 1 to 3 axes, not $shape');
    }
    final count = frames * frameSize;
    if (prediction.length != count || (target != null && target!.length != count)) {
      throw ArgumentError('Field data does not match $frames frame(s) of shape $shape');
    }
    if (this.times.length != frames) {
      throw ArgumentError('${this.times.length} times for $frames frames');
    }
  }

  /// Reads the server's format: 16-bit codes between `min` and `max`
  /// (65535 is NaN), base64-encoded, little-endian.
  factory FieldSnapshot.fromJson(Map<String, Object?> json) {
    List<int>? ints(Object? list) => switch (list) {
      final List<Object?> l => List.unmodifiable([for (final n in l) (n! as num).toInt()]),
      _ => null,
    };
    final low = decodeDouble(json['min']);
    final high = decodeDouble(json['max']);
    final target = json['target'] as String?;
    return FieldSnapshot(
      name: json['name']! as String,
      step: (json['step']! as num).toInt(),
      kind: FieldKind.parse(json['kind']),
      shape: ints(json['shape'])!,
      originalShape: ints(json['originalShape']),
      frames: (json['frames'] as num?)?.toInt() ?? 1,
      times: switch (json['times']) {
        final List<Object?> t => List.unmodifiable([for (final v in t) decodeDouble(v)]),
        _ => null,
      },
      prediction: _decode(json['prediction']! as String, low, high),
      target: target == null ? null : _decode(target, low, high),
      stats: _stats(json['stats']),
      frameStats: Map.unmodifiable({
        for (final e in ((json['frameStats'] as Map?) ?? const {}).entries)
          e.key as String: List<double>.unmodifiable([
            for (final v in e.value as List) decodeDouble(v),
          ]),
      }),
      layer: json['layer'] as String?,
      reduction: json['reduction'] as String?,
      layerShape: ints(json['layerShape']),
    );
  }

  static const nanCode = 65535;
  static const levels = 65534;

  final String name;
  final int step;
  final FieldKind kind;

  /// One frame's shape: 1 to 3 axes.
  final List<int> shape;

  /// The shape the run logged, before it was averaged down to [shape].
  final List<int> originalShape;

  final int frames;

  /// The time of each frame (0, 1, 2, ... unless the run said).
  final List<double> times;

  final Float32List prediction;
  final Float32List? target;
  final Map<String, double> stats;

  /// Per frame of a rollout, e.g. `relL2` → one value per frame.
  final Map<String, List<double>> frameStats;

  /// For a layer snapshot: the layer, how its channels were reduced (e.g.
  /// "mean of 32 channels") and the shape of its output for one sample.
  final String? layer;
  final String? reduction;
  final List<int>? layerShape;

  int get dimensions => shape.length;
  bool get isRollout => frames > 1;
  bool get hasTarget => target != null;
  int get frameSize => shape.fold(1, (a, b) => a * b);

  /// Prediction minus target, point by point (null without a target).
  late final Float32List? error = switch (target) {
    final t? => () {
      final e = Float32List(prediction.length);
      for (var i = 0; i < e.length; i++) {
        e[i] = prediction[i] - t[i];
      }
      return e;
    }(),
    null => null,
  };

  /// The finite range of the prediction and the target together, over all
  /// frames: one colour scale for everything, so colours compare across
  /// time, slices and the two maps.
  late final ({double min, double max}) valueRange = _range([prediction, ?target]);

  /// The largest finite |error|, for a colour scale centred on zero.
  late final double maxAbsError = () {
    if (error == null) return 0.0;
    final range = _range([error!]);
    return math.max(range.min.abs(), range.max.abs());
  }();

  /// What to draw of [data] (the prediction, target or error) at [frame]:
  /// a 1D frame as one row; a 2D frame as is; a 3D frame cut across [axis]
  /// at [index] (axis 0: the plane of axes 1 and 2, and so on).
  FieldPlane plane(Float32List data, {int frame = 0, int axis = 0, int index = 0}) {
    final offset = frame * frameSize;
    switch (shape) {
      case [final n]:
        return (values: Float32List.sublistView(data, offset, offset + n), rows: 1, columns: n);
      case [final rows, final columns]:
        return (
          values: Float32List.sublistView(data, offset, offset + rows * columns),
          rows: rows,
          columns: columns,
        );
      case [final a, final b, final c]:
        final i = index.clamp(0, shape[axis] - 1);
        final (rows, columns) = switch (axis) {
          0 => (b, c),
          1 => (a, c),
          _ => (a, b),
        };
        final values = Float32List(rows * columns);
        for (var r = 0; r < rows; r++) {
          for (var col = 0; col < columns; col++) {
            final (x, y, z) = switch (axis) {
              0 => (i, r, col),
              1 => (r, i, col),
              _ => (r, col, i),
            };
            values[r * columns + col] = data[offset + (x * b + y) * c + z];
          }
        }
        return (values: values, rows: rows, columns: columns);
      default:
        throw StateError('Unexpected shape $shape');
    }
  }

  /// A 1D rollout as a space-time plane: one row per frame, time going
  /// down.
  FieldPlane spaceTime(Float32List data) {
    assert(dimensions == 1);
    return (values: data, rows: frames, columns: shape.single);
  }

  /// Encodes as the server sends it (16-bit codes), e.g. for tests.
  Map<String, Object?> toJson() {
    final range = valueRange;
    return {
      'name': name,
      'step': step,
      'kind': kind.name,
      'shape': shape,
      'originalShape': originalShape,
      'frames': frames,
      'times': [for (final t in times) encodeDouble(t)],
      'min': encodeDouble(range.min),
      'max': encodeDouble(range.max),
      'prediction': _encode(prediction, range.min, range.max),
      'target': target == null ? null : _encode(target!, range.min, range.max),
      'stats': _statsJson(stats),
      'frameStats': {
        for (final e in frameStats.entries) e.key: [for (final v in e.value) encodeDouble(v)],
      },
      'layer': layer,
      'reduction': reduction,
      'layerShape': layerShape,
    };
  }

  static Float32List _decode(String data, double low, double high) {
    final bytes = base64.decode(data);
    if (bytes.length.isOdd) throw const FormatException('Field data has an odd number of bytes');
    final view = ByteData.sublistView(bytes);
    final span = high - low;
    final values = Float32List(bytes.length ~/ 2);
    for (var i = 0; i < values.length; i++) {
      final code = view.getUint16(2 * i, Endian.little);
      values[i] = code == nanCode ? double.nan : low + code / levels * span;
    }
    return values;
  }

  static String _encode(Float32List values, double low, double high) {
    final span = high - low;
    final view = ByteData(values.length * 2);
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final code = !v.isFinite
          ? nanCode
          : span <= 0
          ? 0
          : ((v - low) / span * levels).round().clamp(0, levels);
      view.setUint16(2 * i, code, Endian.little);
    }
    return base64.encode(view.buffer.asUint8List());
  }

  static ({double min, double max}) _range(List<Float32List> arrays) {
    var low = double.infinity;
    var high = double.negativeInfinity;
    for (final array in arrays) {
      for (final v in array) {
        if (!v.isFinite) continue;
        if (v < low) low = v;
        if (v > high) high = v;
      }
    }
    return low > high ? (min: 0, max: 0) : (min: low, max: high);
  }
}

Map<String, double> _stats(Object? json) => Map.unmodifiable({
  for (final e in ((json as Map?) ?? const {}).entries) e.key as String: decodeDouble(e.value),
});

Map<String, Object?> _statsJson(Map<String, double> stats) => {
  for (final e in stats.entries) e.key: encodeDouble(e.value),
};

bool _sameStats(Map<String, double> a, Map<String, double> b) =>
    a.length == b.length &&
    a.entries.every((e) => b.containsKey(e.key) && sameDouble(e.value, b[e.key]!));
