import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

/// What an in-app alert is about.
enum AlertKind {
  finished('finished'),
  crashed('crashed'),

  /// A live run that, at its pace, won't finish before its Slurm time limit.
  timeLimit('time-limit'),

  /// A training problem the logger saw: a NaN loss, a diverging loss,
  /// exploding gradients.
  health('health'),

  /// Its Slurm job left the queue (one queued with `soliton sbatch`, or
  /// one that waited a while).
  jobStarted('job-started');

  const AlertKind(this.event);

  /// The server's name for it in live updates.
  final String event;

  static final _byEvent = {for (final kind in values) kind.event: kind};

  static AlertKind? ofEvent(Object? event) => _byEvent[event];
}

/// Something about a run worth an in-app alert.
class RunAlert {
  const RunAlert({required this.runId, required this.name, required this.kind, this.message});

  final String runId;
  final String name;
  final AlertKind kind;

  /// Why it crashed, what went wrong in training, how long it was queued.
  final String? message;
}

/// The latest [RunAlert]. The app shows each one (see `RunAlertListener`).
final runAlertsProvider = NotifierProvider<RunAlerts, RunAlert?>(RunAlerts.new);

class RunAlerts extends Notifier<RunAlert?> {
  @override
  RunAlert? build() => null;

  void show(RunAlert alert) => state = alert;
}

/// Keeps a WebSocket open to the server (to every server, with "All
/// servers") and refreshes whatever changed.
///
/// The server pushes a message for every change to a run; the affected
/// providers are invalidated (at most every [refreshDelay], so a busy run
/// doesn't refetch on every batch) and screens update by themselves.
/// Reconnects with backoff when a connection drops. The status is live once
/// every connection is, and rejected if any server rejects its token.
final liveUpdatesProvider = NotifierProvider<LiveUpdates, LiveStatus>(LiveUpdates.new);

/// One server's connection: its socket, its retries, and the prefix its runs'
/// ids get in the app (see `CombinedRunRepository`).
class _Link {
  _Link(this.prefix, this.connection);

  final String? prefix;
  final ServerConnection connection;
  LiveSocket? socket;
  StreamSubscription<String>? subscription;
  Timer? retryTimer;
  var attempt = 0;
  var wasLive = false;
  var status = LiveStatus.connecting;

  String id(String raw) => prefix == null ? raw : '$prefix~$raw';

  void close() {
    subscription?.cancel().ignore();
    subscription = null;
    socket?.close();
    socket = null;
  }
}

class LiveUpdates extends Notifier<LiveStatus> {
  static const refreshDelay = Duration(milliseconds: 750);

  var _links = <_Link>[];
  Timer? _refreshTimer;
  final _changedRuns = <String>{};
  var _refreshList = false;
  var _generation = 0; // Ignores sockets from a previous set of connections.

  @override
  LiveStatus build() {
    final connections = ref.watch(liveConnectionsProvider);
    final generation = ++_generation;
    final links = [for (final (prefix, connection) in connections) _Link(prefix, connection)];
    _links = links;
    ref.onDispose(() {
      _generation++;
      for (final link in links) {
        link.retryTimer?.cancel();
        link.close();
      }
      _refreshTimer?.cancel();
      _refreshTimer = null;
    });
    if (links.isEmpty) return LiveStatus.off;
    for (final link in links) {
      _open(link, generation);
    }
    return LiveStatus.connecting;
  }

  /// The status of all connections together.
  void _update() {
    state = _links.any((l) => l.status == LiveStatus.rejected)
        ? LiveStatus.rejected
        : _links.every((l) => l.status == LiveStatus.live)
        ? LiveStatus.live
        : LiveStatus.connecting;
  }

  Future<void> _open(_Link link, int generation) async {
    try {
      final socket = await ref.read(liveSocketConnectorProvider)(link.connection.liveUri);
      if (generation != _generation) {
        socket.close();
        return;
      }
      link.socket = socket;
      link.subscription = socket.messages.listen(
        (text) => _onMessage(link, text),
        onError: (Object _) => _lost(link, generation),
        onDone: () => _lost(link, generation),
        cancelOnError: true,
      );
      socket.send(jsonEncode({'type': 'auth', 'token': link.connection.token}));
    } catch (_) {
      if (generation == _generation) _retryLater(link, generation);
    }
  }

  void _lost(_Link link, int generation) {
    if (generation != _generation || link.status == LiveStatus.rejected) return;
    link.close();
    _retryLater(link, generation);
  }

  void _retryLater(_Link link, int generation) {
    link.status = LiveStatus.connecting;
    _update();
    final delay = Duration(seconds: math.min(60, 1 << math.min(link.attempt, 6))); // 1 s … 60 s
    link.attempt++;
    link.retryTimer?.cancel();
    link.retryTimer = Timer(delay, () => _open(link, generation));
  }

  void _onMessage(_Link link, String text) {
    final Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (message is! Map<String, Object?>) return;
    switch (message['type']) {
      case 'ready':
        link.attempt = 0;
        // After a reconnect, changes may have been missed: refresh the list.
        if (link.wasLive) _scheduleRefresh(list: true);
        link.wasLive = true;
        link.status = LiveStatus.live;
        _update();
      case 'error':
        link.status = LiveStatus.rejected;
        link.close();
        _update();
      case 'dataset':
        ref.invalidate(datasetsProvider);
        if (message['datasetId'] case final String id) ref.invalidate(datasetProvider(link.id(id)));
      case 'run':
        _onRunChange(link, message);
    }
  }

  void _onRunChange(_Link link, Map<String, Object?> message) {
    final raw = message['runId'];
    if (raw is! String) return;
    final runId = link.id(raw);
    _changedRuns.add(runId);
    _scheduleRefresh(list: true);
    // Datasets list the runs that used them.
    if (message['event'] == 'deleted') ref.invalidate(datasetsProvider);

    final kind = AlertKind.ofEvent(message['event']);
    // Nothing to alert about, e.g. a queued job you cancelled yourself.
    if (kind != null && message['notify'] != false) {
      ref
          .read(runAlertsProvider.notifier)
          .show(
            RunAlert(
              runId: runId,
              name: message['name'] as String? ?? raw,
              kind: kind,
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
      ref.invalidate(runOutputProvider(runId));
    }
    _changedRuns.clear();
    _refreshList = false;
  }
}
