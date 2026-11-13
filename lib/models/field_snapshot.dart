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
  const FieldSummary({required this.name, required this.shape, required this.steps});

  factory FieldSummary.fromJson(Map<String, Object?> json) => FieldSummary(
    name: json['name']! as String,
    shape: List.unmodifiable([for (final n in json['shape']! as List) (n as num).toInt()]),
    steps: List.unmodifiable([
      for (final s in json['steps']! as List) FieldStep.fromJson(s as Map<String, Object?>),
    ]),
  );

  final String name;

  /// [length] for a 1D field, [rows, columns] for a 2D one (as stored).
  final List<int> shape;

  /// In step order.
  final List<FieldStep> steps;

  bool get is2D => shape.length == 2;

  Map<String, Object?> toJson() => {
    'name': name,
    'shape': shape,
    'steps': [for (final s in steps) s.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is FieldSummary &&
      other.name == name &&
      deepListEquals(other.shape, shape) &&
      deepListEquals(other.steps, steps);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(shape), Object.hashAll(steps));
}

/// A field at one step: the model's prediction, and the true field
/// ([target]) if the run logged it. 1D or 2D, stored row by row.
class FieldSnapshot {
  FieldSnapshot({
    required this.name,
    required this.step,
    required this.shape,
    List<int>? originalShape,
    required this.prediction,
    this.target,
    this.stats = const {},
  }) : originalShape = originalShape ?? shape {
    final count = shape.fold(1, (a, b) => a * b);
    if (prediction.length != count || (target != null && target!.length != count)) {
      throw ArgumentError('Field data does not match its shape $shape');
    }
  }

  /// Reads the server's format: 16-bit codes between `min` and `max`
  /// (65535 is NaN), base64-encoded, little-endian.
  factory FieldSnapshot.fromJson(Map<String, Object?> json) {
    final shape = [for (final n in json['shape']! as List) (n as num).toInt()];
    final low = decodeDouble(json['min']);
    final high = decodeDouble(json['max']);
    final target = json['target'] as String?;
    return FieldSnapshot(
      name: json['name']! as String,
      step: (json['step']! as num).toInt(),
      shape: List.unmodifiable(shape),
      originalShape: switch (json['originalShape']) {
        final List<Object?> s => List.unmodifiable([for (final n in s) (n! as num).toInt()]),
        _ => null,
      },
      prediction: _decode(json['prediction']! as String, low, high),
      target: target == null ? null : _decode(target, low, high),
      stats: _stats(json['stats']),
    );
  }

  static const nanCode = 65535;
  static const levels = 65534;

  final String name;
  final int step;
  final List<int> shape;

  /// The shape the run logged, before it was averaged down to [shape].
  final List<int> originalShape;

  final Float32List prediction;
  final Float32List? target;
  final Map<String, double> stats;

  bool get is2D => shape.length == 2;
  int get rows => is2D ? shape[0] : 1;
  int get columns => shape.last;
  bool get hasTarget => target != null;

  /// Prediction minus target, point by point (null without a target).
  late final Float32List? error = switch (target) {
    final t? => Float32List.fromList([
      for (var i = 0; i < prediction.length; i++) prediction[i] - t[i],
    ]),
    null => null,
  };

  /// The finite range of the prediction and the target together, so both
  /// can be drawn on one colour scale.
  late final ({double min, double max}) valueRange = _range([prediction, ?target]);

  /// The largest finite |error|, for a colour scale centred on zero.
  late final double maxAbsError = () {
    if (error == null) return 0.0;
    final range = _range([error!]);
    return math.max(range.min.abs(), range.max.abs());
  }();

  /// The value at [row], [column] (row 0 for a 1D field).
  double at(Float32List data, int row, int column) => data[row * columns + column];

  /// Encodes as the server sends it (16-bit codes), e.g. for tests.
  Map<String, Object?> toJson() {
    final range = valueRange;
    return {
      'name': name,
      'step': step,
      'shape': shape,
      'originalShape': originalShape,
      'min': encodeDouble(range.min),
      'max': encodeDouble(range.max),
      'prediction': _encode(prediction, range.min, range.max),
      'target': target == null ? null : _encode(target!, range.min, range.max),
      'stats': _statsJson(stats),
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
