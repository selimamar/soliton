import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:soliton/data/mock/mock_run_repository.dart';
import 'package:soliton/data/run_repository.dart';
import 'package:soliton/data/services/api_client.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/models/run.dart';

/// A stand-in for the Soliton server, answering like the real one (see
/// server/README.md) with demo data. Serves [runIds] only, so tests can
/// tell its runs from the app's own demo data.
class FakeServer {
  FakeServer({this.token = 'secret', this.runIds = const {'resnet50-cifar', 'unet-seg'}});

  final String token;
  final Set<String> runIds;

  /// Simulates a network failure for every request.
  var down = false;

  /// Whether it has a job token (Settings → Advanced security); null: a
  /// server too old to have them.
  bool? jobToken = false;
  var jobTokensMade = 0;
  var requests = 0;

  /// The bodies of the edits (PATCH requests) it received.
  final edits = <Map<String, Object?>>[];

  /// The paths it was asked to delete (DELETE requests), e.g. `runs/x`.
  final deletes = <String>[];
  final _deleted = <String>{};

  final _data = MockRunRepository(latency: Duration.zero);

  /// For `apiClientFactoryProvider.overrideWithValue(server.clientFor)`.
  ApiClient clientFor(ServerConnection connection) =>
      ApiClient(connection, httpClient: MockClient(_handle));

  Future<http.Response> _handle(http.Request request) async {
    requests++;
    if (down) throw http.ClientException('connection refused', request.url);
    if (request.headers['Authorization'] != 'Bearer $token') {
      return _json({'detail': 'Missing or wrong token'}, status: 401);
    }
    final path = request.url.pathSegments;
    if (path.length < 2 || path[0] != 'api') return _json({'detail': 'Not Found'}, status: 404);
    try {
      if (request.method == 'PATCH' && path.length == 3 && path[1] == 'runs') {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        edits.add(body);
        final run = await _run(path[2]);
        return _json(
          (await _data.updateNotes(
            run.id,
            tags: (body['tags'] as List?)?.cast<String>(),
            notes: body['notes'] as String?,
          )).toJson(),
        );
      }
      if (path.sublist(1) case ['job-token'] when jobToken != null) {
        if (request.method == 'POST') {
          jobToken = true;
          return _json({'token': 'job-token-${++jobTokensMade}'});
        }
        if (request.method == 'DELETE') {
          jobToken = false;
          return http.Response('', 204);
        }
      }
      if (request.method == 'DELETE' && path.length == 3) {
        deletes.add('${path[1]}/${path[2]}');
        if (path[1] == 'runs') await _run(path[2]);
        if (!_deleted.add(path[2])) throw RunNotFoundException(path[2]);
        return http.Response('', 204);
      }
      return switch (path.sublist(1)) {
        ['session'] => _json({'ok': true, 'version': '0.1.0', 'jobToken': ?jobToken}),
        ['runs'] => _json([
          for (final run in await _data.fetchRuns())
            if (runIds.contains(run.id) && !_deleted.contains(run.id)) run.toJson(),
        ]),
        ['runs', final id] => _json((await _run(id)).toJson()),
        ['runs', final id, 'metrics'] => _json([
          for (final series in (await _data.fetchMetrics((await _run(id)).id)).values)
            series.toJson(),
        ]),
        ['runs', final id, 'layers'] => _json([
          for (final layer in await _data.fetchLayerStats((await _run(id)).id)) layer.toJson(),
        ]),
        ['runs', final id, 'grad-norms'] => _json([
          for (final layer in await _data.fetchLayerGradNorms((await _run(id)).id)) layer.toJson(),
        ]),
        ['runs', final id, 'fields'] => _json([
          for (final field in await _data.fetchFields((await _run(id)).id)) field.toJson(),
        ]),
        ['runs', final id, 'fields', 'snapshot'] => _json(
          (await _data.fetchFieldSnapshot(
            (await _run(id)).id,
            request.url.queryParameters['name']!,
            int.parse(request.url.queryParameters['step']!),
          )).toJson(),
        ),
        ['runs', final id, 'evals'] => _json([
          for (final series in await _data.fetchEvals((await _run(id)).id))
            {
              'name': series.name,
              'steps': [for (final s in series.steps) s.toJson()],
            },
        ]),
        ['runs', final id, 'curves'] => _json([
          for (final series in await _data.fetchCurves((await _run(id)).id))
            {
              'name': series.name,
              'steps': [for (final s in series.steps) s.toJson()],
            },
        ]),
        ['runs', final id, 'output'] => _json(
          (await _data.fetchOutput((await _run(id)).id)).toJson(),
        ),
        ['metrics', 'latest'] => _json({
          for (final run in (await _data.fetchLatestMetrics(
            request.url.queryParameters['names']!.split(','),
          )).entries)
            if (runIds.contains(run.key))
              run.key: {for (final m in run.value.entries) m.key: m.value.toJson()},
        }),
        _ => _json({'detail': 'Not Found'}, status: 404),
      };
    } on FieldNotFoundException catch (error) {
      return _json({'detail': "No field '${error.name} at step ${error.step}'"}, status: 404);
    } on RunNotFoundException catch (error) {
      return _json({'detail': "No run with id '${error.runId}'"}, status: 404);
    }
  }

  Future<Run> _run(String id) async {
    if (!runIds.contains(id) || _deleted.contains(id)) throw RunNotFoundException(id);
    return _data.fetchRun(id);
  }

  static http.Response _json(Object body, {int status = 200}) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

/// A live-updates socket the test drives by hand.
class FakeLiveSocket implements LiveSocket {
  FakeLiveSocket(this.uri);

  final Uri uri;
  final sent = <String>[];
  var closed = false;
  final _incoming = StreamController<String>();

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  void close() => closed = true;

  /// A message from the server.
  void push(Map<String, Object?> message) => _incoming.add(jsonEncode(message));

  /// The connection drops.
  Future<void> drop() => _incoming.close();
}

/// Records every socket the app opens, for `liveSocketConnectorProvider`.
class FakeLiveSockets {
  final opened = <FakeLiveSocket>[];

  Future<LiveSocket> connect(Uri uri) async {
    final socket = FakeLiveSocket(uri);
    opened.add(socket);
    return socket;
  }
}
