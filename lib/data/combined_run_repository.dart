import '../models/dataset.dart';
import '../models/field_snapshot.dart';
import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';
import '../models/run_insights.dart';
import '../models/run_output.dart';
import 'run_repository.dart';
import 'services/saved_servers.dart';

/// Every saved server's runs together ("All servers"). A run's id in the
/// app is its server's id, `~`, and its id on that server (run ids never
/// contain `~`), so every request goes to the right server; its host shows
/// the server's name first ("Lab · Sherlock"). Datasets likewise. A server
/// that can't be reached is left out of the lists (see [onUnreachable]).
class CombinedRunRepository implements RunRepository {
  CombinedRunRepository(this._sources, {this.onUnreachable});

  final List<(SavedServer, RunRepository)> _sources;

  /// The names of the servers that couldn't be reached, after each list.
  final void Function(List<String> names)? onUnreachable;

  static const separator = '~';

  /// "s1~resnet-3fa9c1" for run "resnet-3fa9c1" on server "s1".
  static String combinedId(String serverId, String id) => '$serverId$separator$id';

  /// The server and the id on it, or null for an id that isn't combined
  /// (or names a server no longer saved).
  (SavedServer, RunRepository, String)? _split(String id) {
    final at = id.indexOf(separator);
    if (at <= 0) return null;
    final serverId = id.substring(0, at);
    for (final (server, repository) in _sources) {
      if (server.id == serverId) return (server, repository, id.substring(at + 1));
    }
    return null;
  }

  /// Runs [request] on the server [id] belongs to; an unknown id is an
  /// unknown run.
  Future<T> _onServer<T>(
    String id,
    Future<T> Function(SavedServer server, RunRepository repository, String localId) request,
  ) async {
    final target = _split(id);
    if (target == null) throw RunNotFoundException(id);
    final (server, repository, localId) = target;
    try {
      return await request(server, repository, localId);
    } on RunNotFoundException {
      throw RunNotFoundException(id);
    }
  }

  /// [run] as the app shows it here: its combined id, its server's name in
  /// front of its host, its datasets' combined ids.
  static Run tag(SavedServer server, Run run) => Run.fromJson({
    ...run.toJson(),
    'id': combinedId(server.id, run.id),
    'host': run.host.isEmpty ? server.name : '${server.name} · ${run.host}',
    'datasets': [for (final d in run.datasets) combinedId(server.id, d)],
  });

  static Dataset _tagDataset(SavedServer server, Dataset dataset) => dataset.withIds(
    (id) => combinedId(server.id, id),
    host: dataset.host.isEmpty ? server.name : '${server.name} · ${dataset.host}',
  );

  /// Asks every server; leaves out (and reports) those that fail, unless
  /// they all do.
  Future<List<T>> _fromAll<T>(Future<List<T>> Function(SavedServer, RunRepository) request) async {
    final results = await Future.wait([
      for (final (server, repository) in _sources)
        request(server, repository).then<(List<T>?, Object?)>(
          (value) => (value, null),
          onError: (Object error) => (null, error),
        ),
    ]);
    final unreachable = [
      for (final (i, (_, error)) in results.indexed)
        if (error != null) _sources[i].$1.name,
    ];
    onUnreachable?.call(unreachable);
    if (_sources.isNotEmpty && unreachable.length == _sources.length) throw results.first.$2!;
    return [for (final (value, _) in results) ...?value];
  }

  @override
  Future<List<Run>> fetchRuns() async {
    final runs = await _fromAll(
      (server, repository) async => [
        for (final run in await repository.fetchRuns()) tag(server, run),
      ],
    );
    // Newest first, as each server sends them.
    return runs..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  @override
  Future<Run> fetchRun(String runId) => _onServer(
    runId,
    (server, repository, id) async => tag(server, await repository.fetchRun(id)),
  );

  @override
  Future<Map<String, MetricSeries>> fetchMetrics(String runId) =>
      _onServer(runId, (_, repository, id) => repository.fetchMetrics(id));

  @override
  Future<List<LayerStats>> fetchLayerStats(String runId) =>
      _onServer(runId, (_, repository, id) => repository.fetchLayerStats(id));

  @override
  Future<List<LayerGradNorm>> fetchLayerGradNorms(String runId) =>
      _onServer(runId, (_, repository, id) => repository.fetchLayerGradNorms(id));

  @override
  Future<List<FieldSummary>> fetchFields(String runId) =>
      _onServer(runId, (_, repository, id) => repository.fetchFields(id));

  @override
  Future<FieldSnapshot> fetchFieldSnapshot(String runId, String name, int step) =>
      _onServer(runId, (_, repository, id) => repository.fetchFieldSnapshot(id, name, step));

  @override
  Future<List<LoggedSeries<EvalStep>>> fetchEvals(String runId) =>
      _onServer(runId, (_, repository, id) => repository.fetchEvals(id));

  @override
  Future<List<LoggedSeries<CurveStep>>> fetchCurves(String runId) =>
      _onServer(runId, (_, repository, id) => repository.fetchCurves(id));

  @override
  Future<Map<String, Map<String, LatestMetric>>> fetchLatestMetrics(List<String> names) async {
    final all = await _fromAll(
      (server, repository) async => [
        for (final MapEntry(:key, :value) in (await repository.fetchLatestMetrics(names)).entries)
          MapEntry(combinedId(server.id, key), value),
      ],
    );
    return Map.fromEntries(all);
  }

  @override
  Future<RunOutput> fetchOutput(String runId) =>
      _onServer(runId, (_, repository, id) => repository.fetchOutput(id));

  @override
  Future<List<Dataset>> fetchDatasets() => _fromAll(
    (server, repository) async => [
      for (final dataset in await repository.fetchDatasets()) _tagDataset(server, dataset),
    ],
  );

  @override
  Future<Dataset> fetchDataset(String datasetId) async {
    final target = _split(datasetId);
    if (target == null) throw DatasetNotFoundException(datasetId);
    final (server, repository, id) = target;
    try {
      return _tagDataset(server, await repository.fetchDataset(id));
    } on DatasetNotFoundException {
      throw DatasetNotFoundException(datasetId);
    }
  }

  @override
  Future<Run> updateNotes(String runId, {List<String>? tags, String? notes}) => _onServer(
    runId,
    (server, repository, id) async =>
        tag(server, await repository.updateNotes(id, tags: tags, notes: notes)),
  );

  @override
  Future<void> deleteRun(String runId) =>
      _onServer(runId, (_, repository, id) => repository.deleteRun(id));

  @override
  Future<Run> requestStop(String runId) => _onServer(
    runId,
    (server, repository, id) async => tag(server, await repository.requestStop(id)),
  );

  @override
  Future<void> deleteDataset(String datasetId) async {
    final target = _split(datasetId);
    if (target == null) throw DatasetNotFoundException(datasetId);
    final (_, repository, id) = target;
    await repository.deleteDataset(id);
  }
}
