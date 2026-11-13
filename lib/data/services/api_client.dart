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

/// The server rejected the token.
class UnauthorizedException extends ApiException {
  const UnauthorizedException();
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

/// Raw HTTP access to the ModelsApp server. Returns decoded JSON; mapping it
/// to models is the repository's job.
class ApiClient {
  ApiClient(this.connection, {http.Client? httpClient, this.timeout = const Duration(seconds: 20)})
    : _http = httpClient ?? http.Client();

  final ServerConnection connection;
  final Duration timeout;
  final http.Client _http;

  Future<Object?> getJson(String path, {Map<String, String>? query}) async {
    final http.Response response;
    try {
      response = await _http
          .get(
            connection.api(path, query),
            headers: {'Authorization': 'Bearer ${connection.token}', 'Accept': 'application/json'},
          )
          .timeout(timeout);
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
      case 401 || 403:
        throw const UnauthorizedException();
      case 404:
        throw const NotFoundException();
      default:
        throw ServerErrorException(response.statusCode);
    }
  }

  /// Checks the address and token (the "Connect" button).
  Future<void> checkSession() => getJson('/session');

  void close() => _http.close();
}
