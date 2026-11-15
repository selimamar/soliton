import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_run_repository.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';
import 'package:soliton/models/run.dart';

import 'fake_server.dart';

class CountingRepository extends MockRunRepository {
  CountingRepository() : super(latency: Duration.zero);

  var runsFetched = 0;

  @override
  Future<List<Run>> fetchRuns() {
    runsFetched++;
    return super.fetchRuns();
  }
}

// testWidgets for its fake clock (reconnect delays, refresh throttling);
// the providers are used directly, without widgets.
void main() {
  late FakeLiveSockets sockets;
  late CountingRepository repository;
  final containers = <ProviderContainer>[];

  ProviderContainer containerWith(SettingsStore store, {String? token}) {
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        savedTokenProvider.overrideWithValue(token),
        runRepositoryProvider.overrideWithValue(repository),
        liveSocketConnectorProvider.overrideWithValue(sockets.connect),
      ],
    );
    containers.add(container);
    container.listen(liveUpdatesProvider, (_, _) {});
    container.listen(runsProvider, (_, _) {});
    return container;
  }

  /// A start with a saved login.
  ProviderContainer loggedIn() => containerWith(
    MemorySettingsStore({'serverAddress': 'https://runs.example.com'}),
    token: 'secret',
  );

  Map<String, Object?> change(String runId, String event) => {
    'type': 'run',
    'event': event,
    'runId': runId,
    'name': runId,
    'status': event == 'updated' ? 'live' : event,
    'statusMessage': event == 'crashed' ? 'Loss became NaN' : null,
  };

  setUp(() {
    sockets = FakeLiveSockets();
    repository = CountingRepository();
  });

  /// Ends a test: disposes the containers (cancelling their timers) while
  /// the fake clock still runs, so no timer is left pending.
  Future<void> done(WidgetTester tester) async {
    for (final container in containers) {
      container.dispose();
    }
    containers.clear();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('demo data opens no connection', (tester) async {
    final container = containerWith(MemorySettingsStore());
    await tester.pump();
    expect(container.read(liveUpdatesProvider), LiveStatus.off);
    expect(sockets.opened, isEmpty);
    await done(tester);
  });

  testWidgets('sends the token first, then goes live', (tester) async {
    final container = loggedIn();
    expect(container.read(liveUpdatesProvider), LiveStatus.connecting);
    await tester.pump();

    final socket = sockets.opened.single;
    expect(socket.uri.toString(), 'wss://runs.example.com/api/live');
    expect(jsonDecode(socket.sent.single), {'type': 'auth', 'token': 'secret'});
    socket.push({'type': 'ready'});
    await tester.pump();
    expect(container.read(liveUpdatesProvider), LiveStatus.live);
    await done(tester);
  });

  testWidgets('changes refresh the list, at most once per moment', (tester) async {
    loggedIn();
    await tester.pump();
    final socket = sockets.opened.single..push({'type': 'ready'});
    await tester.pump();
    expect(repository.runsFetched, 1);

    for (var i = 0; i < 5; i++) {
      socket.push(change('resnet50-cifar', 'updated'));
    }
    await tester.pump();
    expect(repository.runsFetched, 1, reason: 'not yet: changes are batched');
    await tester.pump(LiveUpdates.refreshDelay);
    await tester.pump();
    expect(repository.runsFetched, 2);
    await done(tester);
  });

  testWidgets('finished and crashed runs raise an alert', (tester) async {
    final container = loggedIn();
    await tester.pump();
    final socket = sockets.opened.single..push({'type': 'ready'});
    socket.push(change('unet-seg', 'crashed'));
    await tester.pump();

    final alert = container.read(runAlertsProvider)!;
    expect(
      (alert.runId, alert.kind, alert.message),
      ('unet-seg', AlertKind.crashed, 'Loss became NaN'),
    );
    socket.push(change('resnet50-cifar', 'updated'));
    await tester.pump();
    expect(container.read(runAlertsProvider)!.runId, 'unet-seg', reason: 'updates are no alert');
    await tester.pump(LiveUpdates.refreshDelay);
    await done(tester);
  });

  testWidgets('a time-limit warning alerts; a quiet end (a cancelled queued job) doesn\'t', (
    tester,
  ) async {
    final container = loggedIn();
    await tester.pump();
    final socket = sockets.opened.single..push({'type': 'ready'});
    socket.push({...change('resnet50-cifar', 'time-limit'), 'status': 'live'});
    await tester.pump();
    expect(container.read(runAlertsProvider)!.kind, AlertKind.timeLimit);
    socket.push({...change('resnet50-cifar', 'health'), 'status': 'live'});
    await tester.pump();
    expect(container.read(runAlertsProvider)!.kind, AlertKind.health);
    socket.push({...change('resnet50-cifar', 'job-started'), 'status': 'live'});
    await tester.pump();
    expect(container.read(runAlertsProvider)!.kind, AlertKind.jobStarted);
    socket.push({...change('queued-1', 'crashed'), 'notify': false});
    await tester.pump();
    expect(container.read(runAlertsProvider)!.runId, 'resnet50-cifar');
    await tester.pump(LiveUpdates.refreshDelay);
    await done(tester);
  });

  testWidgets('a dropped connection comes back, and catches up', (tester) async {
    final container = loggedIn();
    await tester.pump();
    sockets.opened.single.push({'type': 'ready'});
    await tester.pump();
    final fetched = repository.runsFetched;

    await sockets.opened.single.drop();
    await tester.pump();
    expect(container.read(liveUpdatesProvider), LiveStatus.connecting);

    await tester.pump(const Duration(seconds: 1)); // First retry after 1 s.
    expect(sockets.opened, hasLength(2));
    sockets.opened.last.push({'type': 'ready'});
    await tester.pump();
    expect(container.read(liveUpdatesProvider), LiveStatus.live);
    await tester.pump(LiveUpdates.refreshDelay);
    await tester.pump();
    expect(repository.runsFetched, fetched + 1, reason: 'changes may have been missed');
    await done(tester);
  });

  testWidgets('retries slow down while the server stays away', (tester) async {
    loggedIn();
    await tester.pump();
    for (final wait in [1, 2, 4]) {
      await sockets.opened.last.drop();
      await tester.pump();
      final count = sockets.opened.length;
      await tester.pump(Duration(seconds: wait) - const Duration(milliseconds: 1));
      expect(sockets.opened, hasLength(count), reason: 'not before $wait s');
      await tester.pump(const Duration(milliseconds: 1));
      expect(sockets.opened, hasLength(count + 1));
    }
    await done(tester);
  });

  testWidgets('a rejected token stops reconnecting', (tester) async {
    final container = loggedIn();
    await tester.pump();
    sockets.opened.single.push({'type': 'error', 'message': 'Missing or wrong token'});
    await tester.pump();
    expect(container.read(liveUpdatesProvider), LiveStatus.rejected);
    expect(sockets.opened.single.closed, isTrue);
    await tester.pump(const Duration(minutes: 5));
    expect(sockets.opened, hasLength(1));
    await done(tester);
  });

  testWidgets('a new login closes the old connection', (tester) async {
    final container = loggedIn();
    await tester.pump();
    container.read(serversProvider.notifier).disconnect();
    await tester.pump();
    // The status first: it settles the change from the server list.
    expect(container.read(liveUpdatesProvider), LiveStatus.off);
    expect(sockets.opened.single.closed, isTrue);
    await done(tester);
  });
}
