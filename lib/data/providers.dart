import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';
import 'mock/mock_run_repository.dart';
import 'run_repository.dart';

/// Which [RunRepository] the app uses. Swap this line to use a real backend.
final runRepositoryProvider = Provider<RunRepository>((ref) => MockRunRepository());

/// Retry policy for every data provider.
///
/// Riverpod retries failed providers automatically and shows them as loading
/// meanwhile. Its default (10 attempts, up to 6.4 s apart) would keep a
/// spinner up for about 40 s before showing an error, so this stops after 3
/// quick attempts, and never retries an unknown run.
Duration? retryDataRequest(int retryCount, Object error) {
  if (error is RunNotFoundException) return null;
  return ProviderContainer.defaultRetry(retryCount, error, maxRetries: 3);
}

final runsProvider = FutureProvider<List<Run>>(
  (ref) => ref.watch(runRepositoryProvider).fetchRuns(),
  retry: retryDataRequest,
);

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
