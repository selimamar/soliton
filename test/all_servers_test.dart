import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/api_run_repository.dart';
import 'package:soliton/data/combined_run_repository.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/run_repository.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/saved_servers.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';

import 'fake_server.dart';
import 'test_app.dart';

const lab = SavedServer(id: 's1', name: 'Lab', address: 'https://lab.example.com');
const laptop = SavedServer(id: 's2', name: 'Laptop', address: 'https://laptop.example.com');

void main() {
  late FakeServer labServer, laptopServer;

  setUp(() {
    labServer = FakeServer(runIds: const {'resnet50-cifar'});
    laptopServer = FakeServer(runIds: const {'unet-seg'});
  });

  CombinedRunRepository combined({void Function(List<String>)? onUnreachable}) {
    RunRepository repo(FakeServer server, SavedServer saved) =>
        ApiRunRepository(server.clientFor(ServerConnection.parse(saved.address, 'secret')!));
    return CombinedRunRepository([
      (lab, repo(labServer, lab)),
      (laptop, repo(laptopServer, laptop)),
    ], onUnreachable: onUnreachable);
  }

  test('runs from every server, each id carrying its server', () async {
    final runs = await combined().fetchRuns();
    expect(
      {for (final r in runs) r.id: r.host},
      {'s1~resnet50-cifar': 'Lab · Sherlock', 's2~unet-seg': 'Laptop · Sherlock'},
    );
    final run = await combined().fetchRun('s2~unet-seg');
    expect((run.id, run.name), ('s2~unet-seg', 'unet-seg'));
  });

  test('requests go to the run\'s own server', () async {
    await combined().deleteRun('s2~unet-seg');
    expect(laptopServer.deletes, ['runs/unet-seg']);
    expect(labServer.deletes, isEmpty);
    await expectLater(combined().fetchRun('s9~x'), throwsA(isA<RunNotFoundException>()));
    await expectLater(combined().fetchRun('s1~nope'), throwsA(isA<RunNotFoundException>()));
  });

  test('a server that can\'t be reached is left out, and named', () async {
    laptopServer.down = true;
    List<String>? unreachable;
    final runs = await combined(onUnreachable: (names) => unreachable = names).fetchRuns();
    expect(runs.map((r) => r.id), ['s1~resnet50-cifar']);
    expect(unreachable, ['Laptop']);
    labServer.down = true;
    await expectLater(combined().fetchRuns(), throwsA(anything), reason: 'none reachable');
  });

  testWidgets('All servers shows every server\'s runs, opens each, and follows them live', (
    tester,
  ) async {
    final sockets = FakeLiveSockets();
    const list = ServerList(
      servers: [lab, laptop],
      currentId: ServerList.allId,
      tokens: {'s1': 'secret', 's2': 'secret'},
    );
    await tester.pumpWidget(
      buildApp(
        store: MemorySettingsStore({
          ServerList.serversKey: list.encodeServers(),
          ServerList.currentKey: ServerList.allId,
        }),
        tokens: MemoryTokenStore(list.encodeTokens()),
        overrides: [
          apiClientFactoryProvider.overrideWithValue(
            (connection) => connection.address == lab.address
                ? labServer.clientFor(connection)
                : laptopServer.clientFor(connection),
          ),
          liveSocketConnectorProvider.overrideWithValue(sockets.connect),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('All · 2'), findsOneWidget);
    expect(find.text('All 2 servers.'), findsOneWidget);
    expect(find.textContaining('Lab · Sherlock'), findsOneWidget);
    expect(find.textContaining('Laptop · Sherlock'), findsOneWidget);

    // Live updates from both servers, each run under its own id.
    expect(sockets.opened.map((s) => s.uri.host), ['lab.example.com', 'laptop.example.com']);
    for (final socket in sockets.opened) {
      socket.push({'type': 'ready'});
    }
    await tester.pump();
    expect(containerOf(tester).read(liveUpdatesProvider), LiveStatus.live);
    sockets.opened[1].push({
      'type': 'run',
      'event': 'crashed',
      'runId': 'unet-seg',
      'name': 'unet-seg',
      'status': 'crashed',
      'statusMessage': 'Loss became NaN',
    });
    await tester.pump();
    expect(containerOf(tester).read(runAlertsProvider)?.runId, 's2~unet-seg');
    await tester.pump(LiveUpdates.refreshDelay);
    await tester.pumpAndSettle();

    await tester.tap(find.text('unet-seg').first);
    await tester.pumpAndSettle();
    expect(locationOf(tester), '/runs/s2~unet-seg');
    expect(find.text('Overview'), findsOneWidget);
  });

  test('All servers is a choice once there are servers, and goes when they do', () {
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemorySettingsStore()),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
      ],
    );
    addTearDown(container.dispose);
    final servers = container.read(serversProvider.notifier);
    servers.switchTo(ServerList.allId);
    expect(container.read(serversProvider).showsAll, isFalse, reason: 'no servers yet');
    servers.connect(ServerConnection.parse(lab.address, 'a')!, name: 'Lab');
    servers.connect(ServerConnection.parse(laptop.address, 'b')!, name: 'Laptop');
    servers.switchTo(ServerList.allId);
    expect(container.read(serversProvider).showsAll, isTrue);
    expect(container.read(connectionProvider), isNull, reason: 'no single server');
    expect(container.read(liveConnectionsProvider), hasLength(2));
    final ids = [for (final s in container.read(serversProvider).servers) s.id];
    servers.remove(ids.first);
    expect(container.read(serversProvider).showsAll, isFalse, reason: 'one server left');
  });
}
