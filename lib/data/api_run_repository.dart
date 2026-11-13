import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';
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
