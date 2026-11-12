import '../../models/layer_stats.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../run_repository.dart';
import 'mock_runs.dart';

/// A [RunRepository] serving generated demo data, with a fake network delay.
class MockRunRepository implements RunRepository {
  MockRunRepository({this.latency = const Duration(milliseconds: 350)})
    : _runs = buildMockRuns(DateTime.now());

  final Duration latency;
  final List<MockRun> _runs;

  @override
  Future<List<Run>> fetchRuns() async {
    await Future<void>.delayed(latency);
    return [for (final r in _runs) r.run];
  }

  @override
  Future<Run> fetchRun(String runId) async {
    await Future<void>.delayed(latency);
    return _find(runId).run;
  }

  @override
  Future<Map<String, MetricSeries>> fetchMetrics(String runId) async {
    await Future<void>.delayed(latency);
    return _find(runId).metrics;
  }

  @override
  Future<List<LayerStats>> fetchLayerStats(String runId) async {
    await Future<void>.delayed(latency);
    return _find(runId).layerStats;
  }

  @override
  Future<List<LayerGradNorm>> fetchLayerGradNorms(String runId) async {
    await Future<void>.delayed(latency);
    return [
      for (final layer in _find(runId).layerStats)
        LayerGradNorm(layerName: layer.layerName, gradNorm: layer.gradNorm.latest ?? double.nan),
    ];
  }

  MockRun _find(String runId) =>
      _runs.firstWhere((r) => r.run.id == runId, orElse: () => throw RunNotFoundException(runId));
}
