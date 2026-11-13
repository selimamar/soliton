// Reads a real ModelsApp server through the app's own code, so the app and
// the server can't drift apart. Skipped unless a server is given:
//
//   MODELSAPP_TEST_SERVER=http://127.0.0.1:8000 MODELSAPP_TEST_TOKEN=... \
//     flutter test test/server_contract_test.dart
//
// The server needs at least one run (e.g. from `modelsapp demo`).
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models_app/data/api_run_repository.dart';
import 'package:models_app/data/run_repository.dart';
import 'package:models_app/data/services/api_client.dart';
import 'package:models_app/data/services/live_updates.dart';
import 'package:models_app/data/services/server_connection.dart';
import 'package:models_app/data/services/settings_store.dart';

void main() {
  final address = Platform.environment['MODELSAPP_TEST_SERVER'];
  final token = Platform.environment['MODELSAPP_TEST_TOKEN'];
  final skip = address == null || token == null
      ? 'set MODELSAPP_TEST_SERVER and MODELSAPP_TEST_TOKEN to test against a real server'
      : null;
  ServerConnection connection() => ServerConnection.parse(address!, token!)!;

  test('the app reads every run the server has', () async {
    final client = ApiClient(connection());
    addTearDown(client.close);
    await client.checkSession();
    final repository = ApiRunRepository(client);

    final runs = await repository.fetchRuns();
    expect(runs, isNotEmpty, reason: 'log a run first, e.g. with `modelsapp demo`');
    for (final summary in runs) {
      final run = await repository.fetchRun(summary.id);
      expect(run.id, summary.id);
      final metrics = await repository.fetchMetrics(run.id);
      final layers = await repository.fetchLayerStats(run.id);
      final gradNorms = await repository.fetchLayerGradNorms(run.id);
      printOnFailure(
        '${run.id}: ${run.status.name}, ${metrics.length} metrics, ${layers.length} layers',
      );
      for (final layer in layers) {
        expect(layer.activationHistogram.counts, isNotEmpty);
      }
      expect(gradNorms.length, lessThanOrEqualTo(layers.length));
    }
    await expectLater(
      repository.fetchRun('no-such-run-${DateTime.now().millisecondsSinceEpoch}'),
      throwsA(isA<RunNotFoundException>()),
    );
  }, skip: skip);

  test('a wrong token is rejected', () async {
    final client = ApiClient(ServerConnection.parse(address!, 'wrong-token')!);
    addTearDown(client.close);
    await expectLater(client.checkSession(), throwsA(isA<UnauthorizedException>()));
  }, skip: skip);

  test('live updates connect with the token', () async {
    final c = connection();
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(
          MemorySettingsStore({'serverAddress': c.address, 'serverToken': c.token}),
        ),
      ],
    );
    addTearDown(container.dispose);
    final live = Completer<void>();
    container.listen(liveUpdatesProvider, (_, status) {
      if (status == LiveStatus.live && !live.isCompleted) live.complete();
    });
    await live.future.timeout(const Duration(seconds: 10));
  }, skip: skip);
}
