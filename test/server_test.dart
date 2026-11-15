import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/api_run_repository.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/run_repository.dart';
import 'package:soliton/data/services/api_client.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';
import 'package:soliton/models/run.dart';

import 'fake_server.dart';
import 'test_app.dart';

ServerConnection connection([
  String address = 'https://runs.example.com',
  String token = 'secret',
]) => ServerConnection.parse(address, token)!;

/// Settings with a saved server address (its token is in a [MemoryTokenStore]).
MemorySettingsStore loggedIn() =>
    MemorySettingsStore({'serverAddress': 'https://runs.example.com'});

void main() {
  group('ServerConnection', () {
    test('cleans up what the user typed', () {
      expect(connection('runs.example.com').address, 'https://runs.example.com');
      expect(connection(' https://runs.example.com/ ').address, 'https://runs.example.com');
      expect(connection('http://192.168.1.5:8000').address, 'http://192.168.1.5:8000');
      expect(connection('https://example.com/soliton/').address, 'https://example.com/soliton');
      expect(ServerConnection.parse('runs.example.com', ' token ')!.token, 'token');
    });

    test('rejects unusable addresses and empty tokens', () {
      expect(ServerConnection.parse('', 'secret'), isNull);
      expect(ServerConnection.parse('ftp://example.com', 'secret'), isNull);
      expect(ServerConnection.parse('https://', 'secret'), isNull);
      expect(ServerConnection.parse('runs.example.com', '  '), isNull);
    });

    test('builds API and live-update addresses', () {
      final c = connection('https://example.com/soliton');
      expect(c.api('/runs/a b').toString(), 'https://example.com/soliton/api/runs/a%20b');
      expect(c.api('/runs', {'maxPoints': '10'}).query, 'maxPoints=10');
      expect(c.liveUri.toString(), 'wss://example.com/soliton/api/live');
      expect(
        connection('http://localhost:8000').liveUri.toString(),
        'ws://localhost:8000/api/live',
      );
      expect(connection('http://localhost:8000').isInsecure, isTrue);
      expect(connection('runs.example.com').isInsecure, isFalse);
    });
  });

  group('ApiClient', () {
    ApiClient clientReturning(http.Response Function(http.Request) handler) =>
        ApiClient(connection(), httpClient: MockClient((r) async => handler(r)));

    test('sends the token and decodes JSON', () async {
      late http.Request seen;
      final client = clientReturning((r) {
        seen = r;
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      expect(await client.getJson('/session'), {'ok': true});
      expect(seen.headers['Authorization'], 'Bearer secret');
      expect(seen.url.toString(), 'https://runs.example.com/api/session');
    });

    test('turns failures into typed errors', () async {
      Future<Object?> get(int status, [String body = '{}']) =>
          clientReturning((_) => http.Response(body, status)).getJson('/runs');
      await expectLater(get(401), throwsA(isA<UnauthorizedException>()));
      await expectLater(get(404), throwsA(isA<NotFoundException>()));
      await expectLater(
        get(502),
        throwsA(isA<ServerErrorException>().having((e) => e.statusCode, 'statusCode', 502)),
      );
      await expectLater(get(200, '<html>'), throwsA(isA<ServerErrorException>()));
      final offline = ApiClient(
        connection(),
        httpClient: MockClient((r) async => throw http.ClientException('refused', r.url)),
      );
      await expectLater(offline.getJson('/runs'), throwsA(isA<ServerUnreachableException>()));
    });

    test('deletes: 204 and 404 are done, other failures throw', () async {
      Future<void> delete(int status) => clientReturning((r) {
        expect(r.method, 'DELETE');
        return http.Response('', status);
      }).delete('/runs/x');
      await delete(204);
      await delete(404);
      await expectLater(delete(500), throwsA(isA<ServerErrorException>()));
      await expectLater(delete(401), throwsA(isA<UnauthorizedException>()));
    });
  });

  group('ApiRunRepository', () {
    final server = FakeServer();
    final repository = ApiRunRepository(server.clientFor(connection()));

    test('reads runs, metrics and layers in the server format', () async {
      final runs = await repository.fetchRuns();
      expect(runs.map((r) => r.id), ['resnet50-cifar', 'unet-seg']);
      final crashed = await repository.fetchRun('unet-seg');
      expect(crashed.status, RunStatus.crashed);
      expect(crashed.statusMessage, contains('NaN'));
      final metrics = await repository.fetchMetrics('resnet50-cifar');
      expect(metrics.keys, contains('train/loss'));
      expect(await repository.fetchLayerStats('resnet50-cifar'), isNotEmpty);
      expect(await repository.fetchLayerGradNorms('resnet50-cifar'), isNotEmpty);
    });

    test('deletes a run and a dataset; already gone counts as done', () async {
      final server = FakeServer();
      final repository = ApiRunRepository(server.clientFor(connection()));
      await repository.deleteRun('unet-seg');
      expect((await repository.fetchRuns()).map((r) => r.id), ['resnet50-cifar']);
      await expectLater(repository.fetchRun('unet-seg'), throwsA(isA<RunNotFoundException>()));
      await repository.deleteRun('unet-seg');
      await repository.deleteDataset('cifar10');
      expect(server.deletes, ['runs/unet-seg', 'runs/unet-seg', 'datasets/cifar10']);
    });

    test('a 404 for a run means the run does not exist', () async {
      await expectLater(repository.fetchRun('gpt-tiny'), throwsA(isA<RunNotFoundException>()));
      await expectLater(repository.fetchMetrics('nope'), throwsA(isA<RunNotFoundException>()));
    });

    test('reads the real server\'s JSON (sample from server/tests)', () async {
      // Exactly what soliton-server returns for GET /api/runs/{id}.
      const body = '''
{"id":"tiny-1","name":"tiny","project":"tests","host":"Sherlock","status":"finished",
 "startedAt":"2026-11-12T09:00:00Z","endedAt":"2026-11-12T09:05:00.123456Z",
 "currentStep":99,"totalSteps":1000,"currentEpoch":9,"totalEpochs":10,
 "hyperparameters":{"Optimizer":"AdamW"},
 "architecture":{"name":"TinyNet","type":"TinyNet","ownParameters":0,"children":[
   {"name":"fc1","type":"Linear","ownParameters":80,"children":[]}]},
 "lossPreview":[2.0,1.5,"NaN","Infinity"],"statusMessage":null}''';
      final repo = ApiRunRepository(
        ApiClient(connection(), httpClient: MockClient((_) async => http.Response(body, 200))),
      );
      final run = await repo.fetchRun('tiny-1');
      expect(run.endedAt, DateTime.utc(2026, 11, 12, 9, 5, 0, 123, 456));
      expect(run.parameterCount, 80);
      expect(run.lossPreview[3], double.infinity);
    });
  });

  group('connecting in the app', () {
    late FakeServer server;
    late FakeLiveSockets sockets;

    Widget app(SettingsStore store, [MemoryTokenStore? tokens]) => buildApp(
      store: store,
      tokens: tokens,
      overrides: [
        apiClientFactoryProvider.overrideWithValue(server.clientFor),
        liveSocketConnectorProvider.overrideWithValue(sockets.connect),
      ],
    );

    setUp(() {
      server = FakeServer();
      sockets = FakeLiveSockets();
    });

    Future<void> fillIn(WidgetTester tester, String address, String token) async {
      await tester.enterText(find.widgetWithText(TextField, 'Server address'), address);
      await tester.enterText(find.widgetWithText(TextField, 'Token'), token);
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the server\'s runs, and remembers the login', (tester) async {
      final store = MemorySettingsStore({'demoData': true});
      final tokens = MemoryTokenStore();
      await tester.pumpWidget(app(store, tokens));
      await tester.pumpAndSettle();
      expect(find.text('All · 11'), findsOneWidget, reason: 'demo data first');
      expect(find.textContaining('Demo data.'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Connect server'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/settings/server');
      await fillIn(tester, 'runs.example.com', 'secret');

      expect(locationOf(tester), '/');
      expect(find.text('All · 2'), findsOneWidget);
      expect(find.textContaining('Demo data.'), findsNothing);
      expect(store.getString('serverAddress'), 'https://runs.example.com');
      expect(tokens.token, 'secret');
      expect(store.getString('serverToken'), isNull, reason: 'the token is kept apart');
      expect(sockets.opened.single.uri.toString(), 'wss://runs.example.com/api/live');

      // A fresh start uses the saved login.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store, tokens));
      await tester.pumpAndSettle();
      expect(find.text('All · 2'), findsOneWidget);
    });

    testWidgets('a wrong token is reported, and nothing is saved', (tester) async {
      final store = MemorySettingsStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      routerOf(tester).go('/settings/server');
      await tester.pumpAndSettle();
      await fillIn(tester, 'runs.example.com', 'wrong');

      expect(find.text('The server rejected this token.'), findsOneWidget);
      expect(locationOf(tester), '/settings/server');
      expect(store.getString('serverAddress'), isNull);
    });

    testWidgets('an unreachable server is reported', (tester) async {
      server.down = true;
      await tester.pumpWidget(app(MemorySettingsStore()));
      await tester.pumpAndSettle();
      routerOf(tester).go('/settings/server');
      await tester.pumpAndSettle();
      await fillIn(tester, 'runs.example.com', 'secret');
      expect(find.textContaining("Can't reach https://runs.example.com"), findsOneWidget);

      await fillIn(tester, '', 'secret');
      expect(find.textContaining('Enter an address like'), findsOneWidget);
    });

    testWidgets('disconnecting shows nothing, with demo data off', (tester) async {
      final store = loggedIn();
      final tokens = MemoryTokenStore('secret');
      await tester.pumpWidget(app(store, tokens));
      await tester.pumpAndSettle();
      expect(find.text('All · 2'), findsOneWidget);

      routerOf(tester).go('/settings/server');
      await tester.pumpAndSettle();
      expect(find.text('Connected server'), findsOneWidget);
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();

      expect(find.text('All · 0'), findsOneWidget);
      expect(find.text('Not connected to a server.'), findsOneWidget);
      for (final section in ['/compute', '/data']) {
        routerOf(tester).go(section);
        await tester.pumpAndSettle();
        expect(find.text('Not connected to a server.'), findsOneWidget, reason: section);
      }
      expect(store.getString('serverAddress'), isNull);
      expect(tokens.token, isNull);
      expect(sockets.opened.single.closed, isTrue);
    });

    testWidgets('a run from the server opens with all its tabs', (tester) async {
      await tester.pumpWidget(app(loggedIn(), MemoryTokenStore('secret')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('resnet50-cifar'));
      await tester.pumpAndSettle();
      expect(find.text('Tags and notes'), findsOneWidget);
      await tester.tap(find.text('Metrics'));
      await tester.pumpAndSettle();
      expect(find.text('Loss'), findsOneWidget);
      await tester.tap(find.text('Layers'));
      await tester.pumpAndSettle();
      expect(find.text('conv1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a revoked token shows plain words and no Retry', (tester) async {
      await tester.pumpWidget(app(loggedIn(), MemoryTokenStore('revoked')));
      await tester.pumpAndSettle();
      expect(find.text('Not allowed'), findsOneWidget);
      expect(find.textContaining('rejected the token'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(server.requests, 1, reason: 'a rejected token is not retried');
    });

    testWidgets('a server that goes down offers Retry, which recovers', (tester) async {
      server.down = true;
      await tester.pumpWidget(app(loggedIn(), MemoryTokenStore('secret')));
      await tester.pump(const Duration(seconds: 5)); // Through the automatic retries.
      await tester.pumpAndSettle();
      expect(find.text("Can't reach the server"), findsOneWidget);

      server.down = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('All · 2'), findsOneWidget);
    });
  });

  group('the saved token', () {
    test('the memory store reads, writes and deletes it', () async {
      final tokens = MemoryTokenStore();
      expect(await tokens.read(), isNull);
      await tokens.write('secret');
      expect(await tokens.read(), 'secret');
      await tokens.delete();
      expect(await tokens.read(), isNull);
      expect(MemoryTokenStore('given').token, 'given');
    });

    test('is read from the token store at startup', () async {
      final settings = MemorySettingsStore({'serverAddress': 'https://runs.example.com'});
      expect(await loadServerToken(MemoryTokenStore('secret'), settings), 'secret');
      expect(await loadServerToken(MemoryTokenStore(), settings), isNull);
    });

    test('an old one in the settings moves to the token store', () async {
      final settings = MemorySettingsStore({
        'serverAddress': 'https://runs.example.com',
        'serverToken': 'old',
      });
      final tokens = MemoryTokenStore('older');
      expect(await loadServerToken(tokens, settings), 'old');
      expect(tokens.token, 'old');
      expect(settings.getString('serverToken'), isNull);
      expect(settings.getString('serverAddress'), 'https://runs.example.com');
    });

    test('stays in the settings if secure storage fails, and is still used', () async {
      final settings = MemorySettingsStore({'serverToken': 'old'});
      expect(await loadServerToken(_BrokenTokenStore(), settings), 'old');
      expect(settings.getString('serverToken'), 'old', reason: 'moved on a later launch');
      expect(await loadServerToken(_BrokenTokenStore(), MemorySettingsStore()), isNull);
    });

    test('connecting saves it apart; disconnecting deletes it everywhere', () async {
      // As if moving an old token failed at startup: it's still in the settings.
      final settings = MemorySettingsStore({'serverToken': 'old'});
      final tokens = MemoryTokenStore();
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(settings),
          tokenStoreProvider.overrideWithValue(tokens),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(connectionProvider.notifier);

      notifier.connect(connection());
      await pumpEventQueue();
      expect(tokens.token, 'secret');
      expect(settings.getString('serverToken'), isNull);
      expect(settings.getString('serverAddress'), 'https://runs.example.com');

      settings.setString('serverToken', 'old').ignore();
      notifier.disconnect();
      await pumpEventQueue();
      expect(container.read(connectionProvider), isNull);
      expect(tokens.token, isNull);
      expect(settings.getString('serverToken'), isNull);
      expect(settings.getString('serverAddress'), isNull);
    });

    test('a keyring that never answers gives up, so the app still starts', () async {
      expect(
        await loadServerToken(_HangingTokenStore(), MemorySettingsStore(), timeout: Duration.zero),
        isNull,
      );
    });

    test('a failed save keeps the connection for this session', () async {
      final container = ProviderContainer(
        overrides: [tokenStoreProvider.overrideWithValue(_BrokenTokenStore())],
      );
      addTearDown(container.dispose);
      container.read(connectionProvider.notifier).connect(connection());
      await pumpEventQueue();
      expect(container.read(connectionProvider)?.token, 'secret');
    });
  });
}

/// Secure storage that fails, like a refused keychain prompt.
class _BrokenTokenStore implements TokenStore {
  @override
  Future<String?> read() => Future.error(StateError('no keychain'));

  @override
  Future<void> write(String token) => Future.error(StateError('no keychain'));

  @override
  Future<void> delete() => Future.error(StateError('no keychain'));
}

/// Secure storage that never answers (a Linux desktop without a keyring).
class _HangingTokenStore implements TokenStore {
  @override
  Future<String?> read() => Completer<String?>().future;

  @override
  Future<void> write(String token) => Completer<void>().future;

  @override
  Future<void> delete() => Completer<void>().future;
}
