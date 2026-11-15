import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/storage_report.dart';
import 'server_connection.dart';

/// Why a request to the server failed. The UI turns these into words (see
/// `describeError`); retrying only helps for [ServerUnreachableException]
/// and [ServerErrorException].
sealed class ApiException implements Exception {
  const ApiException();
}

/// No answer: offline, wrong address, server down, or a timeout.
class ServerUnreachableException extends ApiException {
  const ServerUnreachableException(this.address);

  final String address;

  @override
  String toString() => 'ServerUnreachableException: $address';
}

/// The server rejected the token; [jobToken] when it is the job token
/// (Settings → Advanced security), which can only add and update runs and data.
class UnauthorizedException extends ApiException {
  const UnauthorizedException({this.jobToken = false});

  final bool jobToken;
}

/// The server has nothing at this address (e.g. a deleted run).
class NotFoundException extends ApiException {
  const NotFoundException();
}

/// The server answered with an error, or with something unexpected.
class ServerErrorException extends ApiException {
  const ServerErrorException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'ServerErrorException: HTTP $statusCode';
}

/// The server can't do what was asked, and says why in words meant for
/// people (e.g. not enough disk space for a backup).
class ServerRefusedException extends ApiException {
  const ServerRefusedException(this.reason);

  final String reason;
}

/// A backup coming from the server: its bytes as they arrive, and its size
/// in bytes (null if the server didn't say).
typedef BackupDownload = ({Stream<List<int>> bytes, int? length});

/// Raw HTTP access to the Soliton server. Returns decoded JSON; mapping it
/// to models is the repository's job.
class ApiClient {
  ApiClient(
    this.connection, {
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.stallLimit = const Duration(minutes: 1),
  }) : _http = httpClient ?? http.Client();

  final ServerConnection connection;
  final Duration timeout;

  /// A download (a backup) that gets no bytes for this long has lost its
  /// connection; null never gives up.
  final Duration? stallLimit;
  final http.Client _http;

  Future<Object?> getJson(String path, {Map<String, String>? query}) =>
      _send(() => _http.get(connection.api(path, query), headers: _headers));

  /// Asks the server to do something (no body); returns its answer.
  Future<Object?> postJson(String path, {Map<String, String>? query}) =>
      _send(() => _http.post(connection.api(path, query), headers: _headers));

  /// Changes part of a resource; returns the server's answer.
  Future<Object?> patchJson(String path, Map<String, Object?> body) => _send(
    () => _http.patch(
      connection.api(path),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  /// Creates or replaces a resource whole; returns the server's answer.
  Future<Object?> putJson(String path, Map<String, Object?> body) => _send(
    () => _http.put(
      connection.api(path),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  /// Removes a resource. Already gone (404) counts as done.
  Future<void> delete(String path) async {
    try {
      await _send(() => _http.delete(connection.api(path), headers: _headers));
    } on NotFoundException {
      return;
    }
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${connection.token}',
    'Accept': 'application/json',
  };

  Future<Object?> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw ServerUnreachableException(connection.address);
    } on http.ClientException {
      throw ServerUnreachableException(connection.address);
    }
    switch (response.statusCode) {
      case 200:
        try {
          return jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          throw ServerErrorException(response.statusCode);
        }
      case 204:
        return null;
      case 401:
        throw const UnauthorizedException();
      case 403:
        throw UnauthorizedException(
          jobToken: utf8.decode(response.bodyBytes).contains('job token'),
        );
      case 404:
        throw const NotFoundException();
      default:
        throw ServerErrorException(response.statusCode);
    }
  }

  /// Checks the address and token (the "Connect" button).
  Future<void> checkSession() => getJson('/session');

  /// Whether the server has a job token (Settings → Advanced security);
  /// null for a server too old to have them.
  Future<bool?> jobTokenEnabled() async {
    final session = await getJson('/session');
    return session is Map && session['jobToken'] is bool ? session['jobToken'] as bool : null;
  }

  /// A new job token, replacing any earlier one. The server keeps only its
  /// hash: this is the one time it can be read.
  Future<String> createJobToken() async {
    if (await postJson('/job-token') case {'token': final String token}) return token;
    throw const ServerErrorException(200);
  }

  /// A new main token, replacing the current one, which stops working at
  /// once (on every device and in every script using it). Shown this once.
  Future<String> rotateToken() async {
    if (await postJson('/token/rotate') case {'token': final String token}) return token;
    throw const ServerErrorException(200);
  }

  /// Removes the job token: jobs need the main token again.
  Future<void> deleteJobToken() =>
      _send(() => _http.delete(connection.api('/job-token'), headers: _headers));

  /// How much space the database takes, and each run's share.
  Future<StorageReport> storage() async {
    if (await getJson('/storage') case final Map<String, Object?> json) {
      return StorageReport.fromJson(json);
    }
    throw const ServerErrorException(200);
  }

  /// Thins out an ended run (each curve keeps as many points as its charts
  /// show, each field its latest snapshot); returns about how many bytes
  /// that freed.
  Future<int> thinRun(String runId) async {
    final reply = await postJson('/runs/${Uri.encodeComponent(runId)}/thin');
    return reply is Map && reply['freed'] is num ? (reply['freed'] as num).toInt() : 0;
  }

  /// Thins every run that ended more than [days] days ago; returns how many
  /// and about how many bytes that freed.
  Future<(int, int)> thinOlder(int days) async {
    final reply = await postJson('/storage/thin', query: {'olderThanDays': '$days'});
    if (reply case {'thinned': final num count, 'freed': final num freed}) {
      return (count.toInt(), freed.toInt());
    }
    throw const ServerErrorException(200);
  }

  /// Gives freed space back to the disk (SQLite); returns the database's
  /// size before and after.
  Future<(int?, int?)> compact() async {
    final reply = await postJson('/storage/compact');
    if (reply case {'before': final Map before, 'after': final Map after}) {
      return ((before['bytes'] as num?)?.toInt(), (after['bytes'] as num?)?.toInt());
    }
    throw const ServerErrorException(200);
  }

  /// A backup of the server's whole database (`GET /api/storage/backup`,
  /// main token only). The server first makes the copy, which can take a
  /// while on a big database; then the bytes come as they are read (a pause
  /// of [stallLimit] counts as a lost connection). Closing this client stops it.
  Future<BackupDownload> downloadBackup() async {
    final request = http.Request('GET', connection.api('/storage/backup'))
      ..headers['Authorization'] = 'Bearer ${connection.token}';
    final http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(const Duration(minutes: 10));
    } on TimeoutException {
      throw ServerUnreachableException(connection.address);
    } on http.ClientException {
      throw ServerUnreachableException(connection.address);
    }
    if (response.statusCode == 200) {
      return (
        bytes: switch (stallLimit) {
          final limit? => response.stream.timeout(limit),
          null => response.stream,
        },
        length: response.contentLength,
      );
    }
    String body;
    try {
      body = await response.stream.bytesToString().timeout(timeout);
    } catch (_) {
      body = '';
    }
    throw switch (response.statusCode) {
      401 => const UnauthorizedException(),
      403 => UnauthorizedException(jobToken: body.contains('job token')),
      404 => const ServerRefusedException(
        'This server is too old to make backups: update soliton-server.',
      ),
      409 => ServerRefusedException(_detail(body) ?? "The server couldn't make a backup."),
      _ => ServerErrorException(response.statusCode),
    };
  }

  static String? _detail(String body) {
    try {
      if (jsonDecode(body) case {'detail': final String detail}) return detail;
    } on FormatException {
      return null;
    }
    return null;
  }

  void close() => _http.close();
}
