import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dataset.dart';
import '../models/field_snapshot.dart';
import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';
import '../models/run_insights.dart';
import '../models/run_output.dart';
import 'api_run_repository.dart';
import 'combined_run_repository.dart';
import 'empty_run_repository.dart';
import 'mock/mock_run_repository.dart';
import 'run_repository.dart';
import 'services/api_client.dart';
import 'services/saved_servers.dart';
import 'services/server_connection.dart';
import 'services/settings_store.dart';
import 'services/token_store.dart';

/// The servers the app knows, which one it shows, and their tokens. Saved
/// on the device: the list in the settings, the tokens in secure storage
/// ([SecureTokenStore]; not secure on the web). Changing the current server
/// changes [connectionProvider], which everything else follows.
final serversProvider = NotifierProvider<Servers, ServerList>(Servers.new);

/// The server the app shows, or null (demo data, or nothing).
final connectionProvider = Provider<ServerConnection?>(
  (ref) => ref.watch(serversProvider).connection,
);

class Servers extends Notifier<ServerList> {
  @override
  ServerList build() {
    final settings = ref.watch(settingsStoreProvider);
    return ServerList.load(
      servers: settings.getString(ServerList.serversKey),
      current: settings.getString(ServerList.currentKey),
      legacyAddress: settings.getString(ServerList.legacyAddressKey),
      savedTokens: ref.watch(savedTokenProvider),
    );
  }

  /// Shows [connection]'s server, adding it to the list (named [name], or
  /// after its host) unless it is there; its token is replaced either way.
  void connect(ServerConnection connection, {String? name}) {
    final known = state.servers.where((s) => s.address == connection.address).firstOrNull;
    final server =
        known?.copyWith(name: name?.trim().isEmpty ?? true ? null : name!.trim()) ??
        SavedServer(
          id: 's${DateTime.now().microsecondsSinceEpoch}',
          name: name?.trim().isNotEmpty ?? false
              ? name!.trim()
              : ServerList.hostOf(connection.address),
          address: connection.address,
        );
    _save(
      state.copyWith(
        servers: [
          for (final s in state.servers) s.id == server.id ? server : s,
          if (known == null) server,
        ],
        currentId: () => server.id,
        tokens: {...state.tokens, server.id: connection.token},
      ),
    );
  }

  /// Shows [id]'s server instead ([ServerList.allId]: every server's runs).
  void switchTo(String id) {
    if (state.servers.any((s) => s.id == id) ||
        (id == ServerList.allId && state.servers.isNotEmpty)) {
      _save(state.copyWith(currentId: () => id));
    }
  }

  /// Stops showing a server (demo data, or nothing); the list stays.
  void disconnect() => _save(state.copyWith(currentId: () => null));

  void rename(String id, String name) {
    if (name.trim().isEmpty) return;
    _save(
      state.copyWith(
        servers: [for (final s in state.servers) s.id == id ? s.copyWith(name: name.trim()) : s],
      ),
    );
  }

  /// Forgets a server and its token.
  void remove(String id) => _save(
    state.copyWith(
      servers: [
        for (final s in state.servers)
          if (s.id != id) s,
      ],
      currentId: () => switch (state.currentId) {
        final current when current == id => null,
        // "All servers" with one left is just that server's runs: stop.
        ServerList.allId when state.servers.length <= 2 => null,
        final current => current,
      },
      tokens: {...state.tokens}..remove(id),
    ),
  );

  void _save(ServerList list) {
    state = list;
    final settings = ref.read(settingsStoreProvider);
    settings.setString(ServerList.serversKey, list.encodeServers()).ignore();
    settings.setString(ServerList.currentKey, list.currentId).ignore();
    // What an older app saved, now in the list.
    settings.setString(ServerList.legacyAddressKey, null).ignore();
    settings.setString(legacyTokenKey, null).ignore();
    final tokens = ref.read(tokenStoreProvider);
    _report(list.tokens.isEmpty ? tokens.delete() : tokens.write(list.encodeTokens()));
  }

  /// Secure storage can fail (a keychain prompt was refused, say); the
  /// servers still work until the app quits.
  void _report(Future<void> saving) => saving.catchError((Object error) {
    debugPrint('Could not save the server tokens ($error).');
  }).ignore();
}

/// Makes the HTTP client for a connection (tests swap in a fake one).
final apiClientFactoryProvider = Provider<ApiClient Function(ServerConnection)>(
  (ref) => ApiClient.new,
);

/// Whether the app shows made-up runs while no server is connected. Off by
/// default: unconnected, the lists are empty. A setting, but kept here
/// rather than in `features/settings/settings_providers.dart` because it
/// picks the repository, like [connectionProvider].
final demoDataProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('demoData', false),
);

/// The servers whose live updates the app follows, each with the prefix its
/// runs' ids get in the app (null: one server, ids as they are; see
/// [CombinedRunRepository]).
final liveConnectionsProvider = Provider<List<(String?, ServerConnection)>>((ref) {
  final list = ref.watch(serversProvider);
  if (list.showsAll) {
    return [for (final (server, connection) in list.connections) (server.id, connection)];
  }
  final connection = ref.watch(connectionProvider);
  return connection == null ? const [] : [(null, connection)];
});

/// With "All servers": the names of servers that couldn't be reached the
/// last time the lists loaded (their runs aren't shown).
final unreachableServersProvider = NotifierProvider<UnreachableServers, List<String>>(
  UnreachableServers.new,
);

class UnreachableServers extends Notifier<List<String>> {
  @override
  List<String> build() {
    ref.watch(serversProvider);
    return const [];
  }

  void set(List<String> names) {
    if (!listEquals(names, state)) state = List.unmodifiable(names);
  }
}

/// Which [RunRepository] the app uses: the server if connected, every
/// server together with "All servers", else demo data (or nothing, with
/// [demoDataProvider] off). Everything below refetches when this changes.
final runRepositoryProvider = Provider<RunRepository>((ref) {
  final list = ref.watch(serversProvider);
  if (list.showsAll) {
    final factory = ref.watch(apiClientFactoryProvider);
    final sources = [
      for (final (server, connection) in list.connections) (server, factory(connection)),
    ];
    ref.onDispose(() {
      for (final (_, client) in sources) {
        client.close();
      }
    });
    return CombinedRunRepository([
      for (final (server, client) in sources) (server, ApiRunRepository(client)),
    ], onUnreachable: (names) => ref.read(unreachableServersProvider.notifier).set(names));
  }
  final connection = ref.watch(connectionProvider);
  if (connection == null) {
    return ref.watch(demoDataProvider) ? MockRunRepository() : const EmptyRunRepository();
  }
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
      error is DatasetNotFoundException ||
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

/// The datasets (the Data section), most recently updated first.
final datasetsProvider = FutureProvider.autoDispose<List<Dataset>>(
  (ref) => ref.watch(runRepositoryProvider).fetchDatasets(),
  retry: retryDataRequest,
);

final datasetProvider = FutureProvider.autoDispose.family<Dataset, String>(
  (ref, datasetId) => ref.watch(runRepositoryProvider).fetchDataset(datasetId),
  retry: retryDataRequest,
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

/// The latest lines a run's script printed.
final runOutputProvider = FutureProvider.autoDispose.family<RunOutput, String>(
  (ref, runId) => ref.watch(runRepositoryProvider).fetchOutput(runId),
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

/// Asks live runs to stop (the Stop button on a run's page).
final runStopperProvider = Provider<RunStopper>(RunStopper.new);

class RunStopper {
  RunStopper(this._ref);

  final Ref _ref;

  /// Asks [runId] to stop, then refreshes what shows it. Throws what the
  /// repository throws.
  Future<Run> stop(String runId) async {
    final run = await _ref.read(runRepositoryProvider).requestStop(runId);
    _ref
      ..invalidate(allRunsProvider)
      ..invalidate(runProvider(runId));
    return run;
  }
}

/// Deletes runs, simulations and datasets from the server.
final deleterProvider = Provider<Deleter>(Deleter.new);

/// What a deletion did: how many went, and the first error (null if none).
typedef DeleteOutcome = ({int deleted, Object? error});

class Deleter {
  Deleter(this._ref);

  final Ref _ref;

  /// Deletes each run (or simulation) in turn, stopping at the first
  /// error, then refreshes the lists (datasets list who used them).
  Future<DeleteOutcome> deleteRuns(List<String> runIds) async {
    final outcome = await _each(runIds, _ref.read(runRepositoryProvider).deleteRun);
    _ref
      ..invalidate(allRunsProvider)
      ..invalidate(latestMetricsProvider)
      ..invalidate(datasetsProvider)
      ..invalidate(datasetProvider);
    return outcome;
  }

  /// Forgets each dataset in turn (their files aren't touched), stopping
  /// at the first error, then refreshes the list.
  Future<DeleteOutcome> deleteDatasets(List<String> datasetIds) async {
    final outcome = await _each(datasetIds, _ref.read(runRepositoryProvider).deleteDataset);
    _ref.invalidate(datasetsProvider);
    return outcome;
  }

  static Future<DeleteOutcome> _each(List<String> ids, Future<void> Function(String) delete) async {
    var deleted = 0;
    for (final id in ids) {
      try {
        await delete(id);
        deleted++;
      } catch (error) {
        return (deleted: deleted, error: error);
      }
    }
    return (deleted: deleted, error: null);
  }
}
