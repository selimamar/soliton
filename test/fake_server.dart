import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:models_app/data/mock/mock_run_repository.dart';
import 'package:models_app/data/run_repository.dart';
import 'package:models_app/data/services/api_client.dart';
import 'package:models_app/data/services/live_updates.dart';
import 'package:models_app/data/services/server_connection.dart';
import 'package:models_app/models/run.dart';

/// A stand-in for the ModelsApp server, answering like the real one (see
/// server/README.md) with demo data. Serves [runIds] only, so tests can
/// tell its runs from the app's own demo data.
class FakeServer {
  FakeServer({this.token = 'secret', this.runIds = const {'resnet50-cifar', 'unet-seg'}});

  final String token;
  final Set<String> runIds;

  /// Simulates a network failure for every request.
  var down = false;
  var requests = 0;

  /// The bodies of the edits (PATCH requests) it received.
  final edits = <Map<String, Object?>>[];

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
      return switch (path.sublist(1)) {
        ['session'] => _json({'ok': true, 'version': '0.1.0'}),
        ['runs'] => _json([
          for (final run in await _data.fetchRuns())
            if (runIds.contains(run.id)) run.toJson(),
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
        _ => _json({'detail': 'Not Found'}, status: 404),
      };
    } on RunNotFoundException catch (error) {
      return _json({'detail': "No run with id '${error.runId}'"}, status: 404);
    }
  }

  Future<Run> _run(String id) async {
    if (!runIds.contains(id)) throw RunNotFoundException(id);
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
