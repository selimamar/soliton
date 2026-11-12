import 'dart:math' as math;

import '../../models/layer_stats.dart';
import '../../models/metric_series.dart';

/// Synthesizes realistic-looking training curves for the demo data.
///
/// All curves are defined over the *full* run ([totalSteps]) but only
/// generated up to [currentStep], so live runs show partial curves.
/// A fixed [seed] makes the demo data identical on every launch.
class CurveGenerator {
  CurveGenerator({
    required int seed,
    required this.currentStep,
    required this.totalSteps,
    required this.every,
  }) : _random = math.Random(seed);

  final math.Random _random;
  final int currentStep;
  final int totalSteps;

  /// Default logging interval, in steps.
  final int every;

  /// Uniform noise in [-scale, scale].
  double _noise(double scale) => (_random.nextDouble() * 2 - 1) * scale;

  Iterable<int> _steps(int interval) sync* {
    for (var s = 0; s <= currentStep; s += interval) {
      yield s;
    }
  }

  double _t(int step) => step / totalSteps;

  /// Exponential decay from [start] to [end], with multiplicative noise.
  /// Good for losses.
  MetricSeries decay(
    String name, {
    required double start,
    required double end,
    double rate = 5,
    double noise = 0.04,
    int? interval,
  }) {
    return MetricSeries(
      name: name,
      points: [
        for (final s in _steps(interval ?? every))
          MetricPoint(s, (end + (start - end) * math.exp(-rate * _t(s))) * (1 + _noise(noise))),
      ],
    );
  }

  /// Moves from [start] towards [end], with additive noise.
  /// Good for accuracies and activation statistics.
  MetricSeries approach(
    String name, {
    required double start,
    required double end,
    double rate = 4,
    double noise = 0.01,
    int? interval,
  }) {
    return MetricSeries(
      name: name,
      points: [
        for (final s in _steps(interval ?? every))
          MetricPoint(s, start + (end - start) * (1 - math.exp(-rate * _t(s))) + _noise(noise)),
      ],
    );
  }

  /// Linear warmup followed by cosine decay to zero.
  MetricSeries cosineSchedule(String name, {required double peak, required int warmupSteps}) {
    double lr(int s) {
      if (s < warmupSteps) return peak * s / warmupSteps;
      final progress = (s - warmupSteps) / (totalSteps - warmupSteps);
      return peak * 0.5 * (1 + math.cos(math.pi * progress));
    }

    return MetricSeries(name: name, points: [for (final s in _steps(every)) MetricPoint(s, lr(s))]);
  }

  /// A noisy, slowly decaying level with occasional spikes.
  /// Good for gradient norms.
  MetricSeries spiky(
    String name, {
    required double start,
    required double end,
    double spikeChance = 0.02,
    int? interval,
  }) {
    double sample(int s) {
      final base = end + (start - end) * math.exp(-3 * _t(s));
      final value = base * (1 + _noise(0.25));
      final isSpike = _random.nextDouble() < spikeChance;
      return isSpike ? value * (2 + 3 * _random.nextDouble()) : value;
    }

    return MetricSeries(
      name: name,
      points: [for (final s in _steps(interval ?? every)) MetricPoint(s, sample(s))],
    );
  }

  /// Makes the last [lastPoints] values blow up, as before a NaN crash.
  MetricSeries diverge(MetricSeries series, {int lastPoints = 12}) {
    final n = series.points.length;
    return MetricSeries(
      name: series.name,
      points: [
        for (final (i, p) in series.points.indexed)
          i < n - lastPoints
              ? p
              : MetricPoint(p.step, p.value * math.exp(0.3 * (i - (n - lastPoints)))),
      ],
    );
  }

  /// Samples a (optionally ReLU-rectified) normal distribution into a
  /// histogram. With [relu], negative samples become exact zeros and are
  /// counted in [Histogram.zeroCount], like a real logger would.
  Histogram histogram({
    required double mean,
    required double std,
    bool relu = false,
    int bins = 32,
    int samples = 4000,
  }) {
    final min = relu ? 0.0 : mean - 4 * std;
    final max = mean + 4 * std;
    final width = (max - min) / bins;
    final counts = List<int>.filled(bins, 0);
    var zeros = 0;

    for (var i = 0; i < samples; i++) {
      // Box–Muller transform: two uniforms -> one standard normal.
      final u1 = 1 - _random.nextDouble();
      final u2 = _random.nextDouble();
      final z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
      final x = mean + std * z;
      if (relu && x <= 0) {
        zeros++;
        continue;
      }
      final bin = math.min(bins - 1, math.max(0, ((x - min) / width).floor()));
      counts[bin]++;
    }
    return Histogram(min: min, max: max, counts: List.unmodifiable(counts), zeroCount: zeros);
  }

  /// Statistics for one layer. [depth] goes from 0 (input) to 1 (output).
  LayerStats layer(String name, {required double depth, bool crashed = false}) {
    final interval = every * 5;
    final gradLevel = 0.05 + 0.6 * (1 - 0.7 * depth);
    final activationMean = 0.3 + 0.4 * depth;
    final activationStd = 0.5 + depth;

    var gradNorm = spiky(
      '$name/grad_norm',
      start: gradLevel * 3,
      end: gradLevel,
      spikeChance: 0.01,
      interval: interval,
    );
    if (crashed) gradNorm = diverge(gradNorm, lastPoints: 4);

    return LayerStats(
      layerName: name,
      activationMean: approach(
        '$name/act_mean',
        start: 0,
        end: activationMean,
        noise: 0.03,
        interval: interval,
      ),
      activationStd: approach(
        '$name/act_std',
        start: 1,
        end: activationStd,
        noise: 0.03,
        interval: interval,
      ),
      gradNorm: gradNorm,
      activationHistogram: histogram(mean: activationMean, std: activationStd, relu: depth < 1),
      deadFraction: 0.02 + 0.25 * depth * _random.nextDouble(),
    );
  }
}
