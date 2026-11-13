import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/data/api_run_repository.dart';
import 'package:models_app/data/providers.dart';
import 'package:models_app/data/run_repository.dart';
import 'package:models_app/data/services/api_client.dart';
import 'package:models_app/data/services/live_updates.dart';
import 'package:models_app/data/services/server_connection.dart';
import 'package:models_app/data/services/settings_store.dart';
import 'package:models_app/models/run.dart';

import 'fake_server.dart';
import 'test_app.dart';

ServerConnection connection([
  String address = 'https://runs.example.com',
  String token = 'secret',
]) => ServerConnection.parse(address, token)!;

/// Settings with a saved login.
MemorySettingsStore loggedIn({String token = 'secret'}) =>
    MemorySettingsStore({'serverAddress': 'https://runs.example.com', 'serverToken': token});

void main() {
  group('ServerConnection', () {
    test('cleans up what the user typed', () {
      expect(connection('runs.example.com').address, 'https://runs.example.com');
      expect(connection(' https://runs.example.com/ ').address, 'https://runs.example.com');
      expect(connection('http://192.168.1.5:8000').address, 'http://192.168.1.5:8000');
      expect(connection('https://example.com/modelsapp/').address, 'https://example.com/modelsapp');
      expect(ServerConnection.parse('runs.example.com', ' token ')!.token, 'token');
    });

    test('rejects unusable addresses and empty tokens', () {
      expect(ServerConnection.parse('', 'secret'), isNull);
      expect(ServerConnection.parse('ftp://example.com', 'secret'), isNull);
      expect(ServerConnection.parse('https://', 'secret'), isNull);
      expect(ServerConnection.parse('runs.example.com', '  '), isNull);
    });

    test('builds API and live-update addresses', () {
      final c = connection('https://example.com/modelsapp');
      expect(c.api('/runs/a b').toString(), 'https://example.com/modelsapp/api/runs/a%20b');
      expect(c.api('/runs', {'maxPoints': '10'}).query, 'maxPoints=10');
      expect(c.liveUri.toString(), 'wss://example.com/modelsapp/api/live');
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

    test('a 404 for a run means the run does not exist', () async {
      await expectLater(repository.fetchRun('gpt-tiny'), throwsA(isA<RunNotFoundException>()));
      await expectLater(repository.fetchMetrics('nope'), throwsA(isA<RunNotFoundException>()));
    });

    test('reads the real server\'s JSON (sample from server/tests)', () async {
      // Exactly what modelsapp-server returns for GET /api/runs/{id}.
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

    Widget app(SettingsStore store) => buildApp(
      store: store,
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
      final store = MemorySettingsStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.text('All · 10'), findsOneWidget, reason: 'demo data first');
      expect(find.textContaining('Demo data.'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/settings/server');
      await fillIn(tester, 'runs.example.com', 'secret');

      expect(locationOf(tester), '/');
      expect(find.text('All · 2'), findsOneWidget);
      expect(find.textContaining('Demo data.'), findsNothing);
      expect(store.getString('serverAddress'), 'https://runs.example.com');
      expect(store.getString('serverToken'), 'secret');
      expect(sockets.opened.single.uri.toString(), 'wss://runs.example.com/api/live');

      // A fresh start uses the saved login.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store));
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

    testWidgets('disconnecting goes back to demo data', (tester) async {
      final store = loggedIn();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.text('All · 2'), findsOneWidget);

      routerOf(tester).go('/settings/server');
      await tester.pumpAndSettle();
      expect(find.text('Connected server'), findsOneWidget);
      await tester.tap(find.text('Disconnect and use demo data'));
      await tester.pumpAndSettle();

      expect(find.text('All · 10'), findsOneWidget);
      expect(store.getString('serverToken'), isNull);
      expect(sockets.opened.single.closed, isTrue);
    });

    testWidgets('a run from the server opens with all its tabs', (tester) async {
      await tester.pumpWidget(app(loggedIn()));
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
      await tester.pumpWidget(app(loggedIn(token: 'revoked')));
      await tester.pumpAndSettle();
      expect(find.text('Not allowed'), findsOneWidget);
      expect(find.textContaining('rejected the token'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(server.requests, 1, reason: 'a rejected token is not retried');
    });

    testWidgets('a server that goes down offers Retry, which recovers', (tester) async {
      server.down = true;
      await tester.pumpWidget(app(loggedIn()));
      await tester.pump(const Duration(seconds: 5)); // Through the automatic retries.
      await tester.pumpAndSettle();
      expect(find.text("Can't reach the server"), findsOneWidget);

      server.down = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('All · 2'), findsOneWidget);
    });
  });
}
