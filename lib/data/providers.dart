import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/field_snapshot.dart';
import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';
import '../models/run_insights.dart';
import 'api_run_repository.dart';
import 'mock/mock_run_repository.dart';
import 'run_repository.dart';
import 'services/api_client.dart';
import 'services/server_connection.dart';
import 'services/settings_store.dart';

/// The server the app is connected to, or null for demo data. Saved on the
/// device (the token too, in plain app storage).
final connectionProvider = NotifierProvider<ConnectionSetting, ServerConnection?>(
  ConnectionSetting.new,
);

class ConnectionSetting extends Notifier<ServerConnection?> {
  static const _addressKey = 'serverAddress';
  static const _tokenKey = 'serverToken';

  @override
  ServerConnection? build() {
    final store = ref.watch(settingsStoreProvider);
    final address = store.getString(_addressKey);
    final token = store.getString(_tokenKey);
    if (address == null || token == null) return null;
    return ServerConnection.parse(address, token);
  }

  void connect(ServerConnection connection) {
    state = connection;
    final store = ref.read(settingsStoreProvider);
    store.setString(_addressKey, connection.address).ignore();
    store.setString(_tokenKey, connection.token).ignore();
  }

  /// Back to demo data.
  void disconnect() {
    state = null;
    final store = ref.read(settingsStoreProvider);
    store.setString(_addressKey, null).ignore();
    store.setString(_tokenKey, null).ignore();
  }
}

/// Makes the HTTP client for a connection (tests swap in a fake one).
final apiClientFactoryProvider = Provider<ApiClient Function(ServerConnection)>(
  (ref) => ApiClient.new,
);

/// Which [RunRepository] the app uses: the server if connected, else demo
/// data. Everything below refetches when this changes.
final runRepositoryProvider = Provider<RunRepository>((ref) {
  final connection = ref.watch(connectionProvider);
  if (connection == null) return MockRunRepository();
  final client = ref.watch(apiClientFactoryProvider)(connection);
  ref.onDispose(client.close);
  return ApiRunRepository(client);
});

/// Retry policy for every data provider.
///
/// Riverpod retries failed providers automatically and shows them as loading
/// meanwhile. Its default (10 attempts, up to 6.4 s apart) would keep a
/// spinner up for about 40 s before showing an error, so this stops after 3
/// quick attempts, and never retries what retrying can't fix (an unknown
/// run, a rejected token).
Duration? retryDataRequest(int retryCount, Object error) {
  if (error is RunNotFoundException ||
      error is FieldNotFoundException ||
      error is UnauthorizedException) {
    return null;
  }
  return ProviderContainer.defaultRetry(retryCount, error, maxRetries: 3);
}

/// Everything the server has: training runs and simulations, newest first.
/// Screens read [runsProvider] or [simulationsProvider]; refresh this one.
final allRunsProvider = FutureProvider<List<Run>>(
  (ref) => ref.watch(runRepositoryProvider).fetchRuns(),
  retry: retryDataRequest,
);

/// The training runs (the runs list, compare, sweep, farm).
final runsProvider = FutureProvider<List<Run>>(
  (ref) async => [
    for (final run in await ref.watch(allRunsProvider.future))
      if (!run.isSimulation) run,
  ],
  // allRunsProvider has retried already.
  retry: _noRetry,
);

/// The simulations (the Compute section).
final simulationsProvider = FutureProvider<List<Run>>(
  (ref) async => [
    for (final run in await ref.watch(allRunsProvider.future))
      if (run.isSimulation) run,
  ],
  retry: _noRetry,
);

Duration? _noRetry(int retryCount, Object error) => null;

// Per-run providers are auto-disposed: a run's data (possibly large time
// series) is dropped as soon as no screen shows that run any more.

final runProvider = FutureProvider.autoDispose.family<Run, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchRun(runId),
  retry: retryDataRequest,
);

final runMetricsProvider = FutureProvider.autoDispose.family<Map<String, MetricSeries>, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchMetrics(runId),
  retry: retryDataRequest,
);

final layerStatsProvider = FutureProvider.autoDispose.family<List<LayerStats>, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchLayerStats(runId),
  retry: retryDataRequest,
);

final layerGradNormsProvider = FutureProvider.autoDispose.family<List<LayerGradNorm>, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchLayerGradNorms(runId),
  retry: retryDataRequest,
);

final fieldsProvider = FutureProvider.autoDispose.family<List<FieldSummary>, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchFields(runId),
  retry: retryDataRequest,
);

/// Which snapshot to fetch: a run's field at a step.
typedef FieldSnapshotKey = ({String runId, String name, int step});

/// A logged snapshot never changes, so live updates don't refetch it.
final fieldSnapshotProvider = FutureProvider.autoDispose.family<FieldSnapshot, FieldSnapshotKey>(
  (ref, key) => ref.watch(runRepositoryProvider).fetchFieldSnapshot(key.runId, key.name, key.step),
  retry: retryDataRequest,
);

final evalsProvider = FutureProvider.autoDispose.family<List<LoggedSeries<EvalStep>>, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchEvals(runId),
  retry: retryDataRequest,
);

final curvesProvider = FutureProvider.autoDispose.family<List<LoggedSeries<CurveStep>>, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchCurves(runId),
  retry: retryDataRequest,
);

/// Per run, the latest and lowest value of the metrics named in the key
/// (comma-separated, so equal requests share one fetch).
final latestMetricsProvider = FutureProvider.autoDispose
    .family<Map<String, Map<String, LatestMetric>>, String>(
      (ref, names) => ref.watch(runRepositoryProvider).fetchLatestMetrics(names.split(',')),
      retry: retryDataRequest,
    );

/// Saves what people add to runs (tags, notes).
final runNotesEditorProvider = Provider<RunNotesEditor>(RunNotesEditor.new);

class RunNotesEditor {
  RunNotesEditor(this._ref);

  final Ref _ref;

  /// Saves [tags] and/or [notes] (null: unchanged), then refreshes the
  /// screens that show them. Throws what the repository throws.
  Future<Run> save(String runId, {List<String>? tags, String? notes}) async {
    final run = await _ref.read(runRepositoryProvider).updateNotes(runId, tags: tags, notes: notes);
    _ref
      ..invalidate(allRunsProvider)
      ..invalidate(runProvider(runId));
    return run;
  }
}
