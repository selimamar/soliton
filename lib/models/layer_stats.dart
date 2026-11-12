import 'metric_series.dart';
import 'model_helpers.dart';

/// A histogram with equal-width bins between [min] and [max].
///
/// Values that are exactly zero (e.g. ReLU outputs) are counted in
/// [zeroCount] instead of a bin: they are often the majority, and as a bar
/// they would dwarf the rest of the distribution.
class Histogram {
  /// Pass an unmodifiable (e.g. `const`) [counts] list.
  const Histogram({required this.min, required this.max, required this.counts, this.zeroCount = 0});

  factory Histogram.fromJson(Map<String, Object?> json) => Histogram(
    min: decodeDouble(json['min']),
    max: decodeDouble(json['max']),
    counts: List.unmodifiable([for (final c in json['counts']! as List) (c as num).toInt()]),
    zeroCount: (json['zeroCount'] as num?)?.toInt() ?? 0,
  );

  final double min;
  final double max;
  final List<int> counts;

  /// Number of values that were exactly zero (not included in [counts]).
  final int zeroCount;

  double get binWidth => counts.isEmpty ? 0 : (max - min) / counts.length;

  /// All values, including the zeros.
  int get total => counts.fold(zeroCount, (sum, c) => sum + c);

  /// Fraction of all values that were exactly zero, 0–1.
  double get zeroFraction => total == 0 ? 0 : zeroCount / total;

  Map<String, Object?> toJson() => {
    'min': encodeDouble(min),
    'max': encodeDouble(max),
    'counts': counts,
    'zeroCount': zeroCount,
  };

  @override
  bool operator ==(Object other) =>
      other is Histogram &&
      sameDouble(other.min, min) &&
      sameDouble(other.max, max) &&
      other.zeroCount == zeroCount &&
      deepListEquals(other.counts, counts);

  @override
  int get hashCode =>
      Object.hash(doubleHash(min), doubleHash(max), zeroCount, Object.hashAll(counts));
}

/// Per-layer statistics logged during training.
class LayerStats {
  const LayerStats({
    required this.layerName,
    required this.activationMean,
    required this.activationStd,
    required this.gradNorm,
    required this.activationHistogram,
    required this.deadFraction,
  });

  factory LayerStats.fromJson(Map<String, Object?> json) => LayerStats(
    layerName: json['layerName']! as String,
    activationMean: MetricSeries.fromJson(json['activationMean']! as Map<String, Object?>),
    activationStd: MetricSeries.fromJson(json['activationStd']! as Map<String, Object?>),
    gradNorm: MetricSeries.fromJson(json['gradNorm']! as Map<String, Object?>),
    activationHistogram: Histogram.fromJson(json['activationHistogram']! as Map<String, Object?>),
    deadFraction: decodeDouble(json['deadFraction']),
  );

  final String layerName;

  /// Mean of the layer's output activations over time.
  final MetricSeries activationMean;

  /// Standard deviation of the layer's output activations over time.
  final MetricSeries activationStd;

  /// L2 norm of the gradient of this layer's parameters over time.
  final MetricSeries gradNorm;

  /// Distribution of activations at the most recent logged step.
  final Histogram activationHistogram;

  /// Fraction of units whose output is always zero (e.g. dead ReLUs), 0–1.
  final double deadFraction;

  Map<String, Object?> toJson() => {
    'layerName': layerName,
    'activationMean': activationMean.toJson(),
    'activationStd': activationStd.toJson(),
    'gradNorm': gradNorm.toJson(),
    'activationHistogram': activationHistogram.toJson(),
    'deadFraction': encodeDouble(deadFraction),
  };

  @override
  bool operator ==(Object other) =>
      other is LayerStats &&
      other.layerName == layerName &&
      other.activationMean == activationMean &&
      other.activationStd == activationStd &&
      other.gradNorm == gradNorm &&
      other.activationHistogram == activationHistogram &&
      sameDouble(other.deadFraction, deadFraction);

  @override
  int get hashCode => Object.hash(
    layerName,
    activationMean,
    activationStd,
    gradNorm,
    activationHistogram,
    doubleHash(deadFraction),
  );
}

/// The latest gradient norm of one layer. A light summary of [LayerStats]
/// for charts that compare layers.
class LayerGradNorm {
  const LayerGradNorm({required this.layerName, required this.gradNorm});

  factory LayerGradNorm.fromJson(Map<String, Object?> json) => LayerGradNorm(
    layerName: json['layerName']! as String,
    gradNorm: decodeDouble(json['gradNorm']),
  );

  final String layerName;

  /// May be NaN or infinite when training diverged.
  final double gradNorm;

  Map<String, Object?> toJson() => {'layerName': layerName, 'gradNorm': encodeDouble(gradNorm)};

  @override
  bool operator ==(Object other) =>
      other is LayerGradNorm &&
      other.layerName == layerName &&
      sameDouble(other.gradNorm, gradNorm);

  @override
  int get hashCode => Object.hash(layerName, doubleHash(gradNorm));
}
