import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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

/// Raw HTTP access to the Soliton server. Returns decoded JSON; mapping it
/// to models is the repository's job.
class ApiClient {
  ApiClient(this.connection, {http.Client? httpClient, this.timeout = const Duration(seconds: 20)})
    : _http = httpClient ?? http.Client();

  final ServerConnection connection;
  final Duration timeout;
  final http.Client _http;

  Future<Object?> getJson(String path, {Map<String, String>? query}) =>
      _send(() => _http.get(connection.api(path, query), headers: _headers));

  /// Asks the server to do something (no body); returns its answer.
  Future<Object?> postJson(String path) =>
      _send(() => _http.post(connection.api(path), headers: _headers));

  /// Changes part of a resource; returns the server's answer.
  Future<Object?> patchJson(String path, Map<String, Object?> body) => _send(
    () => _http.patch(
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

  void close() => _http.close();
}
