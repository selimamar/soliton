import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';

/// The only way the UI gets data.
///
/// Backed by the server ([ApiRunRepository], with the raw HTTP in
/// `services/api_client.dart`) or by demo data ([MockRunRepository]);
/// screens don't know which.
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

  /// Replaces a run's [tags] and/or [notes] (null: unchanged) and returns
  /// the run as saved (tags trimmed, each once).
  Future<Run> updateNotes(String runId, {List<String>? tags, String? notes});
}

/// The requested run doesn't exist (e.g. a stale or mistyped link).
/// Retrying won't help.
class RunNotFoundException implements Exception {
  const RunNotFoundException(this.runId);

  final String runId;

  @override
  String toString() => 'RunNotFoundException: no run with id "$runId"';
}
