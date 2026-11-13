import '../models/field_snapshot.dart';
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

  /// The fields the run logs snapshots of (e.g. a PDE solution), each with
  /// the steps it was logged at and their errors; empty for most runs.
  Future<List<FieldSummary>> fetchFields(String runId);

  /// One snapshot of field [name] at [step]. Throws
  /// [FieldNotFoundException] if there is none.
  Future<FieldSnapshot> fetchFieldSnapshot(String runId, String name, int step);

  /// Replaces a run's [tags] and/or [notes] (null: unchanged) and returns
  /// the run as saved (tags trimmed, each once).
  Future<Run> updateNotes(String runId, {List<String>? tags, String? notes});
}

/// The run has no snapshot of that field at that step. Retrying won't help.
class FieldNotFoundException implements Exception {
  const FieldNotFoundException(this.name, this.step);

  final String name;
  final int step;

  @override
  String toString() => 'FieldNotFoundException: no field "$name" at step $step';
}

/// The requested run doesn't exist (e.g. a stale or mistyped link).
/// Retrying won't help.
class RunNotFoundException implements Exception {
  const RunNotFoundException(this.runId);

  final String runId;

  @override
  String toString() => 'RunNotFoundException: no run with id "$runId"';
}
