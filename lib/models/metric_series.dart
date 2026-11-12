import 'model_helpers.dart';

/// A single logged value at a given training step.
///
/// [value] may be NaN or infinite: that is exactly what a diverging run logs.
class MetricPoint {
  const MetricPoint(this.step, this.value);

  factory MetricPoint.fromJson(Map<String, Object?> json) =>
      MetricPoint((json['step']! as num).toInt(), decodeDouble(json['value']));

  final int step;
  final double value;

  Map<String, Object?> toJson() => {'step': step, 'value': encodeDouble(value)};

  @override
  bool operator ==(Object other) =>
      other is MetricPoint && other.step == step && sameDouble(other.value, value);

  @override
  int get hashCode => Object.hash(step, doubleHash(value));

  @override
  String toString() => 'MetricPoint($step, $value)';
}

/// A time series of one scalar metric (e.g. `train/loss`).
class MetricSeries {
  /// Pass an unmodifiable (e.g. `const`) list: the series never changes.
  const MetricSeries({required this.name, required this.points});

  factory MetricSeries.fromJson(Map<String, Object?> json) => MetricSeries(
    name: json['name']! as String,
    points: List.unmodifiable([
      for (final p in json['points']! as List) MetricPoint.fromJson(p as Map<String, Object?>),
    ]),
  );

  final String name;
  final List<MetricPoint> points;

  bool get isEmpty => points.isEmpty;

  double? get latest => points.isEmpty ? null : points.last.value;

  Map<String, Object?> toJson() => {
    'name': name,
    'points': [for (final p in points) p.toJson()],
  };

  /// Returns at most [maxPoints] points that keep the shape of the curve,
  /// so charts stay fast even for runs with millions of steps.
  ///
  /// The points are split into buckets and each bucket keeps its lowest and
  /// its highest value, so spikes survive. Non-finite values (NaN, ±∞) count
  /// as extremes, so the step where a run blew up survives too. The first and
  /// last points are always kept.
  MetricSeries downsampled(int maxPoints) {
    if (points.length <= maxPoints) return this;
    if (maxPoints < 4) {
      return MetricSeries(name: name, points: [if (maxPoints >= 2) points.first, points.last]);
    }

    final inner = points.length - 2; // Points between the first and the last.
    final buckets = (maxPoints - 2) ~/ 2;
    final sampled = <MetricPoint>[points.first];
    for (var b = 0; b < buckets; b++) {
      final start = 1 + b * inner ~/ buckets;
      final end = 1 + (b + 1) * inner ~/ buckets; // Exclusive.
      if (start >= end) continue;

      var low = start;
      var high = start;
      for (var i = start + 1; i < end; i++) {
        final rank = _rank(points[i].value);
        if (rank < _rank(points[low].value)) low = i;
        if (rank > _rank(points[high].value)) high = i;
      }
      // Keep step order inside the bucket.
      if (low != high) sampled.add(points[low < high ? low : high]);
      sampled.add(points[low < high ? high : low]);
    }
    sampled.add(points.last);
    return MetricSeries(name: name, points: List.unmodifiable(sampled));
  }

  /// Orders values for [downsampled]: NaN sorts as the highest value, so it
  /// is always picked as an extreme instead of being skipped by `<` and `>`.
  static double _rank(double value) => value.isNaN ? double.infinity : value;

  @override
  bool operator ==(Object other) =>
      other is MetricSeries && other.name == name && deepListEquals(other.points, points);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(points));
}

/// Well-known metric names. The UI gives these dedicated charts; any other
/// metric a run logs is shown in a generic "Other metrics" section.
abstract final class MetricKeys {
  static const trainLoss = 'train/loss';
  static const valLoss = 'val/loss';
  static const valAccuracy = 'val/accuracy';
  static const learningRate = 'optim/lr';
  static const gradNorm = 'optim/grad_norm';

  static const all = {trainLoss, valLoss, valAccuracy, learningRate, gradNorm};
}
