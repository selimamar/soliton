import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/board_card.dart';
import '../models/dataset.dart';
import '../models/run.dart';
import 'api_run_repository.dart';
import 'board_repository.dart';
import 'combined_run_repository.dart';
import 'empty_run_repository.dart';
import 'providers.dart';
import 'run_repository.dart';
import 'services/saved_servers.dart';
import 'services/server_connection.dart';
import 'services/settings_store.dart';

/// One place cards are kept: a server ([server]; null on demo data) with
/// its part of the board and its runs.
class BoardPlace {
  const BoardPlace({required this.server, required this.source, required this.runs});

  final SavedServer? server;
  final BoardSource source;
  final RunRepository runs;
}

/// A card and the server it is saved on (null on demo data).
class PlacedCard {
  const PlacedCard(this.server, this.card);

  final SavedServer? server;
  final BoardCard card;

  /// Unique on the whole board: `<server id>~<card id>` (see
  /// [CombinedRunRepository.combinedId]), or the card's id on demo data.
  String get key =>
      server == null ? card.id : CombinedRunRepository.combinedId(server!.id, card.id);

  PlacedCard withCard(BoardCard card) => PlacedCard(server, card);
}

/// The whole board: every server's cards, and which servers are missing.
class BoardState {
  const BoardState({this.cards = const [], this.unreachable = const [], this.outdated = const []});

  final List<PlacedCard> cards;

  /// Names of servers that couldn't be reached (their cards aren't shown).
  final List<String> unreachable;

  /// Names of servers too old to keep a board.
  final List<String> outdated;

  PlacedCard? byKey(String key) => cards.where((c) => c.key == key).firstOrNull;

  /// The projects, in order: named ones alphabetically, then "" (no project).
  List<String> get projects {
    final names = {for (final c in cards) c.card.project}.toList()
      ..sort((a, b) {
        if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return names;
  }

  /// The cards of [project] in [column], in order.
  List<PlacedCard> cell(String project, BoardColumn column) =>
      [
        for (final c in cards)
          if (c.card.project == project && c.card.column == column) c,
      ]..sort((a, b) {
        final byPosition = a.card.position.compareTo(b.card.position);
        if (byPosition != 0) return byPosition;
        return (a.card.createdAt ?? DateTime(0)).compareTo(b.card.createdAt ?? DateTime(0));
      });

  BoardState replace(PlacedCard card) => BoardState(
    cards: [
      for (final c in cards)
        if (c.key != card.key) c,
      card,
    ],
    unreachable: unreachable,
    outdated: outdated,
  );

  BoardState without(String key) => BoardState(
    cards: [
      for (final c in cards)
        if (c.key != key) c,
    ],
    unreachable: unreachable,
    outdated: outdated,
  );
}

/// The demo board (kept while the app runs, so edits stay).
final demoBoardSourceProvider = Provider<BoardSource>((ref) => MemoryBoardSource.demo());

/// Where the board's cards are: every saved server with a token, whichever
/// one the runs list shows, so there is one board for all of them. With no
/// server, the demo board while demo data is on, else nothing.
final boardPlacesProvider = Provider<List<BoardPlace>>((ref) {
  final connections = ref.watch(serversProvider).connections;
  if (connections.isEmpty) {
    final runs = ref.watch(runRepositoryProvider);
    if (runs is EmptyRunRepository) return const [];
    return [BoardPlace(server: null, source: ref.watch(demoBoardSourceProvider), runs: runs)];
  }
  final factory = ref.watch(apiClientFactoryProvider);
  final clients = [for (final (server, connection) in connections) (server, factory(connection))];
  ref.onDispose(() {
    for (final (_, client) in clients) {
      client.close();
    }
  });
  return [
    for (final (server, client) in clients)
      BoardPlace(server: server, source: ApiBoardSource(client), runs: ApiRunRepository(client)),
  ];
});

final boardProvider = AsyncNotifierProvider<Board, BoardState>(Board.new);

/// The board, and changes to it. Changes show at once and are then saved
/// on the card's server; if saving fails, the board reloads and the error
/// is rethrown (for a message).
class Board extends AsyncNotifier<BoardState> {
  @override
  Future<BoardState> build() async {
    final places = ref.watch(boardPlacesProvider);
    final results = await Future.wait([
      for (final place in places)
        place.source.fetchCards().then<(List<BoardCard>?, Object?)>(
          (cards) => (cards, null),
          onError: (Object error) => (null, error),
        ),
    ]);
    final cards = <PlacedCard>[];
    final unreachable = <String>[];
    final outdated = <String>[];
    Object? firstError;
    for (final (i, (found, error)) in results.indexed) {
      final server = places[i].server;
      if (found != null) {
        cards.addAll([for (final card in found) PlacedCard(server, card)]);
      } else if (error is BoardNotSupportedException) {
        outdated.add(server?.name ?? '');
      } else {
        firstError ??= error;
        unreachable.add(server?.name ?? '');
      }
    }
    // Nothing at all could be read: show the error instead of an empty board.
    if (firstError != null && unreachable.length == places.length) throw firstError;
    return BoardState(
      cards: cards,
      unreachable: List.unmodifiable(unreachable),
      outdated: List.unmodifiable(outdated),
    );
  }

  /// The servers a new card can be saved on (those that keep a board),
  /// the one the runs list shows first.
  List<SavedServer?> get homes {
    final current = ref.read(serversProvider).current;
    final outdated = state.value?.outdated ?? const [];
    final servers = [
      for (final place in ref.read(boardPlacesProvider))
        if (!outdated.contains(place.server?.name ?? '')) place.server,
    ];
    final index = servers.indexWhere((s) => s != null && s.id == current?.id);
    if (index > 0) servers.insert(0, servers.removeAt(index));
    return servers;
  }

  BoardSource? _sourceFor(SavedServer? server) =>
      ref.read(boardPlacesProvider).where((p) => p.server?.id == server?.id).firstOrNull?.source;

  /// Adds a card at the end of [project]'s [column], on [server].
  Future<PlacedCard> add({
    required SavedServer? server,
    required String title,
    String project = '',
    BoardColumn column = BoardColumn.todo,
  }) {
    final card = BoardCard(
      id: newCardId(),
      title: title.trim(),
      project: project.trim(),
      column: column,
      position: endOf(project.trim(), column),
    );
    return save(PlacedCard(server, card));
  }

  /// Moves a card to the end of [project]'s [column].
  Future<PlacedCard?> move(String key, {required String project, required BoardColumn column}) {
    final placed = state.value?.byKey(key);
    if (placed == null) return Future.value();
    if (placed.card.project == project && placed.card.column == column) return Future.value(placed);
    return save(
      placed.withCard(
        placed.card.copyWith(project: project, column: column, position: endOf(project, column)),
      ),
    );
  }

  /// A position after every card of [project]'s [column].
  double endOf(String project, BoardColumn column) {
    final cell = state.value?.cell(project, column) ?? const [];
    return cell.isEmpty ? 0 : cell.last.card.position + 1;
  }

  /// Saves [placed] whole (adding it if it is new).
  Future<PlacedCard> save(PlacedCard placed) async {
    final source = _sourceFor(placed.server);
    if (source == null) throw StateError('No server for this card');
    final before = state.value ?? const BoardState();
    state = AsyncData(before.replace(placed));
    try {
      final saved = placed.withCard(await source.saveCard(placed.card));
      if (state.value case final now?) state = AsyncData(now.replace(saved));
      return saved;
    } catch (_) {
      ref.invalidateSelf();
      rethrow;
    }
  }

  Future<void> delete(String key) async {
    final placed = state.value?.byKey(key);
    if (placed == null) return;
    final source = _sourceFor(placed.server);
    if (source == null) return;
    state = AsyncData(state.value!.without(key));
    try {
      await source.deleteCard(placed.card.id);
    } catch (_) {
      ref.invalidateSelf();
      rethrow;
    }
  }
}

/// The repository over every board place's runs: ids as in [boardRunsProvider].
RunRepository _pooledRuns(List<BoardPlace> places) => switch (places) {
  [BoardPlace(server: null, :final runs)] => runs,
  _ => CombinedRunRepository([for (final p in places) (p.server!, p.runs)]),
};

/// Every server's runs and simulations, for the board's links (ids as
/// [CombinedRunRepository] makes them, or plain on demo data). Refreshed
/// whenever the runs list is.
final boardRunsProvider = FutureProvider<List<Run>>((ref) async {
  final places = ref.watch(boardPlacesProvider);
  if (places.isEmpty) return const [];
  ref.listen(allRunsProvider, (_, next) {
    if (next.hasValue && !next.isLoading) ref.invalidateSelf();
  });
  return _pooledRuns(places).fetchRuns();
}, retry: retryDataRequest);

/// Every server's datasets, for linking them to cards.
final boardDatasetsProvider = FutureProvider.autoDispose<List<Dataset>>((ref) async {
  final places = ref.watch(boardPlacesProvider);
  if (places.isEmpty) return const [];
  return _pooledRuns(places).fetchDatasets();
}, retry: retryDataRequest);

/// Whether the board leaves out the Done column (a setting).
final boardHideDoneProvider = NotifierProvider<Setting<bool>, bool>(
  () => Setting.boolean('boardHideDone', false),
);

/// Projects folded away on the board (while the app runs).
final boardCollapsedProvider = NotifierProvider<BoardCollapsed, Set<String>>(BoardCollapsed.new);

class BoardCollapsed extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String project) =>
      state = state.contains(project) ? ({...state}..remove(project)) : {...state, project};
}

/// Translating links between a card's server and the pooled ids the board
/// shows ([boardRunsProvider]).
abstract final class BoardLinks {
  static String? _normalized(String address) =>
      ServerConnection.parse(address, 'x')?.address ?? address;

  /// The pooled id of what [link] on [placed] points at; null when it is on
  /// a server this device doesn't know.
  static String? pooledId(PlacedCard placed, BoardLink link, ServerList servers) {
    final home = placed.server;
    if (home == null) return link.id;
    if (link.server.isEmpty) return CombinedRunRepository.combinedId(home.id, link.id);
    final wanted = _normalized(link.server);
    for (final server in servers.servers) {
      if (_normalized(server.address) == wanted) {
        return CombinedRunRepository.combinedId(server.id, link.id);
      }
    }
    return null;
  }

  /// A link, saved on [placed]'s server, to [pooledId] (a run's or
  /// dataset's id as [boardRunsProvider] gives them).
  static BoardLink linkTo(
    PlacedCard placed,
    BoardLinkKind kind,
    String pooledId,
    ServerList servers,
  ) {
    final (serverId, id) = split(pooledId);
    if (placed.server == null || serverId == null) return BoardLink(kind: kind, id: id);
    if (serverId == placed.server!.id) return BoardLink(kind: kind, id: id);
    final address = servers.servers.where((s) => s.id == serverId).firstOrNull?.address ?? '';
    return BoardLink(kind: kind, id: id, server: address);
  }

  /// The server id (null for a plain id) and the id on that server.
  static (String?, String) split(String pooledId) {
    final at = pooledId.indexOf(CombinedRunRepository.separator);
    if (at <= 0) return (null, pooledId);
    return (pooledId.substring(0, at), pooledId.substring(at + 1));
  }
}
