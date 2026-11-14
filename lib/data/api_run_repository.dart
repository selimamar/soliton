import '../models/dataset.dart';
import '../models/field_snapshot.dart';
import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';
import '../models/run_insights.dart';
import 'run_repository.dart';
import 'services/api_client.dart';

/// Runs from the ModelsApp server (see server/README.md for the API).
class ApiRunRepository implements RunRepository {
  ApiRunRepository(this._client);

  final ApiClient _client;

  /// Points per metric the server sends; enough for any screen width.
  static const maxPoints = 1000;

  @override
  Future<List<Run>> fetchRuns() async => [
    for (final json in await _list('/runs')) Run.fromJson(json),
  ];

  @override
  Future<Run> fetchRun(String runId) async =>
      Run.fromJson(await _object(runId, _runPath(runId)) as Map<String, Object?>);

  @override
  Future<Map<String, MetricSeries>> fetchMetrics(String runId) async {
    final list = await _object(runId, '${_runPath(runId)}/metrics', {'maxPoints': '$maxPoints'});
    return {
      for (final json in (list as List).cast<Map<String, Object?>>())
        json['name']! as String: MetricSeries.fromJson(json),
    };
  }

  @override
  Future<List<LayerStats>> fetchLayerStats(String runId) async {
    final list = await _object(runId, '${_runPath(runId)}/layers');
    return [
      for (final json in (list as List).cast<Map<String, Object?>>()) LayerStats.fromJson(json),
    ];
  }

  @override
  Future<List<LayerGradNorm>> fetchLayerGradNorms(String runId) async {
    final list = await _object(runId, '${_runPath(runId)}/grad-norms');
    return [
      for (final json in (list as List).cast<Map<String, Object?>>()) LayerGradNorm.fromJson(json),
    ];
  }

  @override
  Future<List<FieldSummary>> fetchFields(String runId) async {
    final list = await _object(runId, '${_runPath(runId)}/fields');
    return [
      for (final json in (list as List).cast<Map<String, Object?>>()) FieldSummary.fromJson(json),
    ];
  }

  @override
  Future<FieldSnapshot> fetchFieldSnapshot(String runId, String name, int step) async {
    try {
      final json = await _client.getJson(
        '${_runPath(runId)}/fields/snapshot',
        query: {'name': name, 'step': '$step'},
      );
      return FieldSnapshot.fromJson(json! as Map<String, Object?>);
    } on NotFoundException {
      // The run or the snapshot: either way, there is nothing to show.
      throw FieldNotFoundException(name, step);
    }
  }

  @override
  Future<List<LoggedSeries<EvalStep>>> fetchEvals(String runId) async {
    final list = await _object(runId, '${_runPath(runId)}/evals');
    return [
      for (final json in (list as List).cast<Map<String, Object?>>())
        LoggedSeries.fromJson(json, EvalStep.fromJson),
    ];
  }

  @override
  Future<List<LoggedSeries<CurveStep>>> fetchCurves(String runId) async {
    final list = await _object(runId, '${_runPath(runId)}/curves');
    return [
      for (final json in (list as List).cast<Map<String, Object?>>())
        LoggedSeries.fromJson(json, CurveStep.fromJson),
    ];
  }

  @override
  Future<Map<String, Map<String, LatestMetric>>> fetchLatestMetrics(List<String> names) async {
    final json = await _client.getJson('/metrics/latest', query: {'names': names.join(',')});
    return {
      for (final run in (json! as Map<String, Object?>).entries)
        run.key: {
          for (final metric in (run.value! as Map<String, Object?>).entries)
            metric.key: LatestMetric.fromJson(metric.value! as Map<String, Object?>),
        },
    };
  }

  @override
  Future<Run> updateNotes(String runId, {List<String>? tags, String? notes}) async {
    try {
      final json = await _client.patchJson(_runPath(runId), {'tags': ?tags, 'notes': ?notes});
      return Run.fromJson(json! as Map<String, Object?>);
    } on NotFoundException {
      throw RunNotFoundException(runId);
    }
  }

  @override
  Future<List<Dataset>> fetchDatasets() async => [
    for (final json in await _list('/datasets')) Dataset.fromJson(json),
  ];

  @override
  Future<Dataset> fetchDataset(String datasetId) async {
    try {
      final json = await _client.getJson('/datasets/${Uri.encodeComponent(datasetId)}');
      return Dataset.fromJson(json! as Map<String, Object?>);
    } on NotFoundException {
      throw DatasetNotFoundException(datasetId);
    }
  }

  static String _runPath(String runId) => '/runs/${Uri.encodeComponent(runId)}';

  Future<List<Map<String, Object?>>> _list(String path) async =>
      ((await _client.getJson(path)) as List).cast<Map<String, Object?>>();

  /// A run's resource; a 404 means the run doesn't exist.
  Future<Object?> _object(String runId, String path, [Map<String, String>? query]) async {
    try {
      return await _client.getJson(path, query: query);
    } on NotFoundException {
      throw RunNotFoundException(runId);
    }
  }
}
