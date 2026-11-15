import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/models/layer_info.dart';
import 'package:soliton/models/layer_stats.dart';
import 'package:soliton/models/metric_series.dart';
import 'package:soliton/models/run.dart';

/// Round-trips [json] through an actual JSON string, like a network response.
Map<String, Object?> throughJson(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('MetricSeries.downsampled', () {
    final points = [for (var i = 0; i < 10000; i++) MetricPoint(i, 1.0 + (i % 7) * 0.01)];
    points[5123] = const MetricPoint(5123, 50); // A spike.
    points[7777] = const MetricPoint(7777, double.nan); // The step where it blew up.
    points[8888] = const MetricPoint(8888, double.negativeInfinity);
    final series = MetricSeries(name: 'loss', points: points);

    test('returns at most maxPoints, in step order', () {
      final sampled = series.downsampled(300).points;
      expect(sampled.length, lessThanOrEqualTo(300));
      expect(sampled.length, greaterThan(250));
      for (var i = 1; i < sampled.length; i++) {
        expect(sampled[i].step, greaterThan(sampled[i - 1].step));
      }
    });

    test('keeps the first and last points', () {
      final sampled = series.downsampled(300).points;
      expect(sampled.first, points.first);
      expect(sampled.last, points.last);
    });

    test('keeps spikes and non-finite values', () {
      final steps = series.downsampled(300).points.map((p) => p.step).toSet();
      expect(steps, contains(5123));
      expect(steps, contains(7777));
      expect(steps, contains(8888));
    });

    test('returns the series itself when it is already short enough', () {
      expect(identical(series.downsampled(20000), series), isTrue);
    });

    test('handles tiny budgets', () {
      expect(series.downsampled(1).points, [points.last]);
      expect(series.downsampled(2).points, [points.first, points.last]);
      expect(series.downsampled(4).points.length, lessThanOrEqualTo(4));
    });
  });

  group('Run', () {
    final start = DateTime(2026, 11, 11, 8);
    Run run({RunStatus status = RunStatus.live, int step = 250, DateTime? endedAt}) => Run(
      id: 'r',
      name: 'r',
      project: 'p',
      host: 'h',
      status: status,
      startedAt: start,
      endedAt: endedAt,
      currentStep: step,
      totalSteps: 1000,
      currentEpoch: 0,
      totalEpochs: 4,
      hyperparameters: const {},
      architecture: const LayerInfo(name: 'm', type: 'M'),
      lossPreview: const [],
    );

    test('progress is clamped to 0–1', () {
      expect(run().progress, 0.25);
      expect(run(step: 2000).progress, 1);
    });

    test('elapsedAt counts to now, or to the end of the run', () {
      final now = start.add(const Duration(hours: 1));
      expect(run().elapsedAt(now), const Duration(hours: 1));
      final ended = run(
        status: RunStatus.finished,
        endedAt: start.add(const Duration(minutes: 20)),
      );
      expect(ended.elapsedAt(now), const Duration(minutes: 20));
    });

    test('estimatedRemainingAt extrapolates the time per step', () {
      final now = start.add(const Duration(hours: 1));
      // 250 of 1000 steps in an hour -> 3 more hours.
      expect(run().estimatedRemainingAt(now), const Duration(hours: 3));
      expect(run(step: 1000).estimatedRemainingAt(now), Duration.zero);
      expect(run(step: 0).estimatedRemainingAt(now), isNull);
      expect(run(status: RunStatus.crashed).estimatedRemainingAt(now), isNull);
    });
  });

  test('LayerInfo.totalParameters sums the whole tree', () {
    const tree = LayerInfo(
      name: 'root',
      type: 'M',
      ownParameters: 1,
      children: [
        LayerInfo(name: 'a', type: 'L', ownParameters: 10),
        LayerInfo(
          name: 'b',
          type: 'G',
          children: [LayerInfo(name: 'b.0', type: 'L', ownParameters: 100)],
        ),
      ],
    );
    expect(tree.totalParameters, 111);
  });

  test('Histogram keeps exact zeros out of the bins', () {
    const histogram = Histogram(min: 0, max: 1, counts: [1, 2, 3, 4], zeroCount: 10);
    expect(histogram.total, 20);
    expect(histogram.zeroFraction, 0.5);
    expect(histogram.binWidth, 0.25);
  });

  group('equality', () {
    test('NaN values compare equal', () {
      expect(const MetricPoint(1, double.nan), const MetricPoint(1, double.nan));
      expect(const MetricPoint(1, double.nan).hashCode, const MetricPoint(1, double.nan).hashCode);
    });

    test('demo data built twice is equal', () {
      final now = DateTime(2026, 11, 11);
      final a = buildMockRuns(now);
      final b = buildMockRuns(now);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].run, b[i].run);
        expect(a[i].run.hashCode, b[i].run.hashCode);
        // A queued run has logged nothing.
        expect(a[i].metrics.values.firstOrNull, b[i].metrics.values.firstOrNull);
        expect(a[i].layerStats.firstOrNull, b[i].layerStats.firstOrNull);
      }
    });

    test('hyperparameter order does not matter', () {
      final now = DateTime(2026, 11, 11);
      final run = buildMockRuns(now).first.run;
      final json = run.toJson();
      final reversed = Map.fromEntries(
        (json['hyperparameters']! as Map<String, String>).entries.toList().reversed,
      );
      final other = Run.fromJson({...json, 'hyperparameters': reversed});
      expect(other, run);
      expect(other.hashCode, run.hashCode);
    });
  });

  group('JSON', () {
    final mock = buildMockRuns(DateTime(2026, 11, 11, 12, 30));

    test('every demo run survives a round trip', () {
      for (final m in mock) {
        expect(Run.fromJson(throughJson(m.run.toJson())), m.run);
      }
    });

    test('metrics and layer stats survive a round trip', () {
      for (final m in mock) {
        for (final series in m.metrics.values) {
          expect(MetricSeries.fromJson(throughJson(series.toJson())), series);
        }
        for (final stats in m.layerStats) {
          expect(LayerStats.fromJson(throughJson(stats.toJson())), stats);
        }
      }
    });

    test('NaN and infinity travel as strings', () {
      const series = MetricSeries(
        name: 'loss',
        points: [
          MetricPoint(0, 1),
          MetricPoint(1, double.nan),
          MetricPoint(2, double.infinity),
          MetricPoint(3, double.negativeInfinity),
        ],
      );
      final text = jsonEncode(series.toJson());
      expect(text, contains('"NaN"'));
      expect(text, contains('"Infinity"'));
      expect(MetricSeries.fromJson(jsonDecode(text) as Map<String, Object?>), series);
    });

    test('decoded collections are unmodifiable', () {
      final run = Run.fromJson(throughJson(mock.first.run.toJson()));
      expect(() => run.lossPreview.add(0), throwsUnsupportedError);
      expect(() => run.hyperparameters['x'] = 'y', throwsUnsupportedError);
    });

    test('LayerGradNorm round trip', () {
      const value = LayerGradNorm(layerName: 'fc', gradNorm: double.nan);
      expect(LayerGradNorm.fromJson(throughJson(value.toJson())), value);
    });
  });
}
