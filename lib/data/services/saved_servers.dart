import 'dart:convert';

import 'server_connection.dart';

/// A server the app knows: its own id, a name to tell it apart (e.g.
/// "Sherlock test", "Lab server"), and its address. Its token is kept apart,
/// in secure storage (see [ServerList.tokens]).
class SavedServer {
  const SavedServer({required this.id, required this.name, required this.address});

  factory SavedServer.fromJson(Map<String, Object?> json) => SavedServer(
    id: json['id']! as String,
    name: json['name'] as String? ?? json['address']! as String,
    address: json['address']! as String,
  );

  final String id;
  final String name;
  final String address;

  SavedServer copyWith({String? name}) =>
      SavedServer(id: id, name: name ?? this.name, address: address);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'address': address};

  @override
  bool operator ==(Object other) =>
      other is SavedServer && other.id == id && other.name == name && other.address == address;

  @override
  int get hashCode => Object.hash(id, name, address);
}

/// The servers the app knows, which one it shows ([currentId]; none: demo
/// data or nothing), and each one's token, by server id.
class ServerList {
  const ServerList({this.servers = const [], this.currentId, this.tokens = const {}});

  /// Where the list is saved in the settings, and which one is shown.
  static const serversKey = 'servers';
  static const currentKey = 'currentServer';

  /// [currentId] when the app shows every server's runs together.
  static const allId = '*';

  /// Where an app from before several servers kept its one server.
  static const legacyAddressKey = 'serverAddress';
  static const legacyId = 'server-1';

  /// The list as saved: [servers] and [current] from the settings, and
  /// [savedTokens] as secure storage holds them (see [encodeTokens]). An
  /// older app's one server ([legacyAddress], with a plain token) becomes
  /// the first of the list, and the current one.
  factory ServerList.load({
    String? servers,
    String? current,
    String? legacyAddress,
    String? savedTokens,
  }) {
    var list = <SavedServer>[];
    String? currentId = current;
    if (servers != null) {
      try {
        list = [
          for (final item in jsonDecode(servers) as List)
            SavedServer.fromJson(item as Map<String, Object?>),
        ];
      } on Object {
        list = [];
      }
    } else if (legacyAddress != null) {
      list = [SavedServer(id: legacyId, name: hostOf(legacyAddress), address: legacyAddress)];
      currentId = legacyId;
    }
    final tokens = decodeTokens(
      savedTokens,
      fallbackId: currentId ?? (list.isEmpty ? null : list.first.id),
    );
    if (currentId != null && currentId != allId && !list.any((s) => s.id == currentId)) {
      currentId = null;
    }
    if (currentId == allId && list.isEmpty) currentId = null;
    return ServerList(
      servers: List.unmodifiable(list),
      currentId: currentId,
      tokens: Map.unmodifiable(tokens),
    );
  }

  final List<SavedServer> servers;
  final String? currentId;

  /// Server id → token.
  final Map<String, String> tokens;

  /// Whether the app shows every server's runs together ("All servers").
  bool get showsAll => currentId == allId;

  /// Every server with a usable token, and its connection (for "All
  /// servers").
  List<(SavedServer, ServerConnection)> get connections => [
    for (final server in servers)
      if (connectionFor(server) case final connection?) (server, connection),
  ];

  SavedServer? get current => switch (currentId) {
    final id? => servers.where((s) => s.id == id).firstOrNull,
    null => null,
  };

  /// The connection to the current server; null when none is chosen.
  ServerConnection? get connection => switch (current) {
    final server? => connectionFor(server),
    null => null,
  };

  ServerConnection? connectionFor(SavedServer server) => switch (tokens[server.id]) {
    final token? => ServerConnection.parse(server.address, token),
    null => null,
  };

  ServerList copyWith({
    List<SavedServer>? servers,
    String? Function()? currentId,
    Map<String, String>? tokens,
  }) => ServerList(
    servers: List.unmodifiable(servers ?? this.servers),
    currentId: currentId == null ? this.currentId : currentId(),
    tokens: Map.unmodifiable(tokens ?? this.tokens),
  );

  /// The servers as saved in the settings.
  String encodeServers() => jsonEncode([for (final s in servers) s.toJson()]);

  /// All the tokens, as one value for secure storage.
  String encodeTokens() => jsonEncode({'tokens': tokens});

  /// Tokens from secure storage: the map [encodeTokens] wrote, or an older
  /// app's one plain token, for [fallbackId].
  static Map<String, String> decodeTokens(String? saved, {String? fallbackId}) {
    if (saved == null || saved.isEmpty) return {};
    if (saved.startsWith('{')) {
      try {
        final map = (jsonDecode(saved) as Map<String, Object?>)['tokens'] as Map<String, Object?>;
        return {for (final MapEntry(:key, :value) in map.entries) key: value! as String};
      } on Object {
        return {};
      }
    }
    return fallbackId == null ? {} : {fallbackId: saved};
  }

  /// "runs.example.com", "localhost:8100": a name for a server until it is
  /// given one.
  static String hostOf(String address) {
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) return address;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }
}
