import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/run.dart';
import '../providers.dart';
import 'server_connection.dart';

/// A WebSocket, reduced to what live updates need (so tests can fake it).
abstract interface class LiveSocket {
  Stream<String> get messages;
  void send(String message);
  void close();
}

typedef LiveSocketConnector = Future<LiveSocket> Function(Uri uri);

final liveSocketConnectorProvider = Provider<LiveSocketConnector>((ref) => _connectWebSocket);

Future<LiveSocket> _connectWebSocket(Uri uri) async {
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  return _ChannelSocket(channel);
}

class _ChannelSocket implements LiveSocket {
  _ChannelSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages => _channel.stream.where((m) => m is String).cast<String>();

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  void close() => _channel.sink.close().ignore();
}

enum LiveStatus {
  /// Demo data: nothing to listen to.
  off,
  connecting,
  live,

  /// The server rejected the token; not retried until the login changes.
  rejected,
}

/// A run finished or crashed, for an in-app alert.
class RunAlert {
  const RunAlert({required this.runId, required this.name, required this.status, this.message});

  final String runId;
  final String name;
  final RunStatus status;
  final String? message;
}

/// The latest [RunAlert]. The app shows each one (see `RunAlertListener`).
final runAlertsProvider = NotifierProvider<RunAlerts, RunAlert?>(RunAlerts.new);

class RunAlerts extends Notifier<RunAlert?> {
  @override
  RunAlert? build() => null;

  void show(RunAlert alert) => state = alert;
}

/// Keeps a WebSocket open to the server and refreshes whatever changed.
///
/// The server pushes a message for every change to a run; the affected
/// providers are invalidated (at most every [refreshDelay], so a busy run
/// doesn't refetch on every batch) and screens update by themselves.
/// Reconnects with backoff when the connection drops.
final liveUpdatesProvider = NotifierProvider<LiveUpdates, LiveStatus>(LiveUpdates.new);

class LiveUpdates extends Notifier<LiveStatus> {
  static const refreshDelay = Duration(milliseconds: 750);

  LiveSocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  Timer? _refreshTimer;
  final _changedRuns = <String>{};
  var _refreshList = false;
  var _attempt = 0;
  var _wasLive = false;
  var _generation = 0; // Ignores sockets from a previous connection.

  @override
  LiveStatus build() {
    final connection = ref.watch(connectionProvider);
    final generation = ++_generation;
    ref.onDispose(() {
      _generation++;
      _retryTimer?.cancel();
      _refreshTimer?.cancel();
      _refreshTimer = null;
      _closeSocket();
    });
    _attempt = 0;
    _wasLive = false;
    if (connection == null) return LiveStatus.off;
    _open(connection, generation);
    return LiveStatus.connecting;
  }

  Future<void> _open(ServerConnection connection, int generation) async {
    try {
      final socket = await ref.read(liveSocketConnectorProvider)(connection.liveUri);
      if (generation != _generation) {
        socket.close();
        return;
      }
      _socket = socket;
      _subscription = socket.messages.listen(
        _onMessage,
        onError: (Object _) => _lost(connection, generation),
        onDone: () => _lost(connection, generation),
        cancelOnError: true,
      );
      socket.send(jsonEncode({'type': 'auth', 'token': connection.token}));
    } catch (_) {
      if (generation == _generation) _retryLater(connection, generation);
    }
  }

  void _lost(ServerConnection connection, int generation) {
    if (generation != _generation || state == LiveStatus.rejected) return;
    _closeSocket();
    _retryLater(connection, generation);
  }

  void _retryLater(ServerConnection connection, int generation) {
    state = LiveStatus.connecting;
    final delay = Duration(seconds: math.min(60, 1 << math.min(_attempt, 6))); // 1 s … 60 s
    _attempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => _open(connection, generation));
  }

  void _onMessage(String text) {
    final Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (message is! Map<String, Object?>) return;
    switch (message['type']) {
      case 'ready':
        _attempt = 0;
        // After a reconnect, changes may have been missed: refresh the list.
        if (_wasLive) _scheduleRefresh(list: true);
        _wasLive = true;
        state = LiveStatus.live;
      case 'error':
        state = LiveStatus.rejected;
        _closeSocket();
      case 'dataset':
        ref.invalidate(datasetsProvider);
        if (message['datasetId'] case final String id) ref.invalidate(datasetProvider(id));
      case 'run':
        _onRunChange(message);
    }
  }

  void _onRunChange(Map<String, Object?> message) {
    final runId = message['runId'];
    if (runId is! String) return;
    _changedRuns.add(runId);
    _scheduleRefresh(list: true);
    // Datasets list the runs that used them.
    if (message['event'] == 'deleted') ref.invalidate(datasetsProvider);

    final status = switch (message['event']) {
      'finished' => RunStatus.finished,
      'crashed' => RunStatus.crashed,
      _ => null,
    };
    if (status != null) {
      ref
          .read(runAlertsProvider.notifier)
          .show(
            RunAlert(
              runId: runId,
              name: message['name'] as String? ?? runId,
              status: status,
              message: message['statusMessage'] as String?,
            ),
          );
    }
  }

  void _scheduleRefresh({required bool list}) {
    _refreshList |= list;
    _refreshTimer ??= Timer(refreshDelay, _refresh);
  }

  void _refresh() {
    _refreshTimer = null;
    if (_refreshList) ref.invalidate(allRunsProvider);
    if (_changedRuns.isNotEmpty) ref.invalidate(latestMetricsProvider);
    for (final runId in _changedRuns) {
      ref.invalidate(runProvider(runId));
      ref.invalidate(runMetricsProvider(runId));
      ref.invalidate(layerStatsProvider(runId));
      ref.invalidate(layerGradNormsProvider(runId));
      ref.invalidate(fieldsProvider(runId));
      ref.invalidate(evalsProvider(runId));
      ref.invalidate(curvesProvider(runId));
    }
    _changedRuns.clear();
    _refreshList = false;
  }

  void _closeSocket() {
    _subscription?.cancel().ignore();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }
}
