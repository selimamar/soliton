/// Where the Soliton server is, and the token to use with it.
class ServerConnection {
  const ServerConnection({required this.baseUri, required this.token});

  /// Parses what the user typed. Adds `https://` when no scheme is given
  /// and drops a trailing slash. Returns null if [address] isn't a usable
  /// http(s) address or [token] is empty.
  static ServerConnection? parse(String address, String token) {
    var text = address.trim();
    if (text.isEmpty || token.trim().isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https')) || uri.host.isEmpty) {
      return null;
    }
    final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
    return ServerConnection(
      baseUri: Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: path,
      ),
      token: token.trim(),
    );
  }

  /// E.g. `https://runs.example.com` (or with a path, behind a proxy).
  final Uri baseUri;
  final String token;

  /// The address as shown to the user.
  String get address => baseUri.toString();

  /// Plain http: fine on your own network, but the token travels unencrypted.
  bool get isInsecure => baseUri.isScheme('http');

  /// `<base>/api<path>`, e.g. `/runs/x` → `https://host/api/runs/x`.
  Uri api(String path, [Map<String, String>? query]) =>
      baseUri.replace(path: '${baseUri.path}/api$path', queryParameters: query);

  /// The live-updates WebSocket (`ws://` or `wss://`).
  Uri get liveUri => api('/live').replace(scheme: baseUri.isScheme('https') ? 'wss' : 'ws');

  @override
  bool operator ==(Object other) =>
      other is ServerConnection && other.baseUri == baseUri && other.token == token;

  @override
  int get hashCode => Object.hash(baseUri, token);
}
