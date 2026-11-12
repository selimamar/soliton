import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';

/// The only way the UI gets data.
///
/// Today this is backed by [MockRunRepository]. Later, an implementation
/// talking to the backend server (HTTP + WebSocket) will replace it without
/// any screen having to change. Put the raw HTTP/WebSocket code in a service
/// class under `data/services/` and inject it into that repository, so the
/// repository only maps responses to models (see the `fromJson` constructors).
abstract interface class RunRepository {
  Future<List<Run>> fetchRuns();

  /// Throws [RunNotFoundException] if there is no run with this id.
  Future<Run> fetchRun(String runId);

  /// All scalar metrics of a run, keyed by metric name (see [MetricKeys]).
  Future<Map<String, MetricSeries>> fetchMetrics(String runId);

  /// Per-layer statistics, in the order the layers appear in the model.
  Future<List<LayerStats>> fetchLayerStats(String runId);

  /// The latest gradient norm of every layer, in model order. Much lighter
  /// than [fetchLayerStats] when only the comparison chart is needed.
  Future<List<LayerGradNorm>> fetchLayerGradNorms(String runId);
}

/// The requested run doesn't exist (e.g. a stale or mistyped link).
/// Retrying won't help.
class RunNotFoundException implements Exception {
  const RunNotFoundException(this.runId);

  final String runId;

  @override
  String toString() => 'RunNotFoundException: no run with id "$runId"';
}
