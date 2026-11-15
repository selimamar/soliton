import 'dart:math' as math;

import '../models/board_card.dart';
import 'services/api_client.dart';

/// Where one server's part of the board is kept. The app pools every
/// server's cards into one board (see `boardProvider`).
abstract interface class BoardSource {
  /// Every card. Throws [BoardNotSupportedException] for a server too old
  /// to keep a board.
  Future<List<BoardCard>> fetchCards();

  /// Adds [card], or replaces it whole; returns it as saved.
  Future<BoardCard> saveCard(BoardCard card);

  /// Already gone counts as done.
  Future<void> deleteCard(String cardId);
}

/// The server answered 404 for the board: it is older than the board.
class BoardNotSupportedException implements Exception {
  const BoardNotSupportedException();
}

/// A new card's id: unique enough across devices, and a valid id on the
/// server (letters, digits, `-`).
String newCardId([math.Random? random]) {
  final r = random ?? math.Random.secure();
  final suffix = List.generate(6, (_) => r.nextInt(36).toRadixString(36)).join();
  return 'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$suffix';
}

/// The board on a Soliton server (`/api/board`).
class ApiBoardSource implements BoardSource {
  ApiBoardSource(this._client);

  final ApiClient _client;

  @override
  Future<List<BoardCard>> fetchCards() async {
    final Object? json;
    try {
      json = await _client.getJson('/board');
    } on NotFoundException {
      throw const BoardNotSupportedException();
    }
    return [
      for (final item in json! as List)
        if (item is Map<String, Object?>) BoardCard.fromJson(item),
    ];
  }

  @override
  Future<BoardCard> saveCard(BoardCard card) async {
    try {
      final json = await _client.putJson(_path(card.id), card.toJson());
      return BoardCard.fromJson(json! as Map<String, Object?>);
    } on NotFoundException {
      throw const BoardNotSupportedException();
    }
  }

  @override
  Future<void> deleteCard(String cardId) => _client.delete(_path(cardId));

  static String _path(String cardId) => '/board/${Uri.encodeComponent(cardId)}';
}

/// A board kept in memory: demo data, and tests.
class MemoryBoardSource implements BoardSource {
  MemoryBoardSource([Iterable<BoardCard> cards = const []])
    : _cards = {for (final card in cards) card.id: card};

  /// Cards about the demo runs, simulations and datasets.
  factory MemoryBoardSource.demo() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return MemoryBoardSource([
      const BoardCard(
        id: 'demo-spectral-loss',
        title: 'Try a spectral loss on the 3D box',
        project: 'neural-operators',
        column: BoardColumn.ideas,
        notes: 'High wavenumbers are smoothed out. Weight the loss by |k|?',
        links: [BoardLink(kind: BoardLinkKind.dataset, id: 'turbulence-3d-box')],
      ),
      BoardCard(
        id: 'demo-sweep',
        title: 'Sweep Fourier modes and width',
        project: 'neural-operators',
        column: BoardColumn.todo,
        notes:
            'The 2D run plateaus. Check whether more modes help or just overfit. '
            'Keep the learning rate at 1e-3.',
        checklist: const [
          ChecklistItem(text: 'Copy settings from fno-navier-stokes', done: true),
          ChecklistItem(text: 'Submit the sweep (modes 8, 16; width 32, 64)', done: true),
          ChecklistItem(text: 'Compare validation loss'),
          ChecklistItem(text: 'Figure for the paper'),
        ],
        links: const [
          BoardLink(kind: BoardLinkKind.run, id: 'fno-navier-stokes'),
          BoardLink(kind: BoardLinkKind.dataset, id: 'ns2d-vorticity-v3'),
        ],
        tag: 'sweep',
        due: today.add(const Duration(days: 4)),
      ),
      const BoardCard(
        id: 'demo-fno3d',
        title: '3D turbulence model',
        project: 'neural-operators',
        column: BoardColumn.running,
        links: [
          BoardLink(kind: BoardLinkKind.run, id: 'fno3d-turbulence'),
          BoardLink(kind: BoardLinkKind.dataset, id: 'turbulence-3d-box'),
        ],
      ),
      const BoardCard(
        id: 'demo-convection',
        title: 'Rayleigh–Bénard reference run',
        project: 'convection',
        column: BoardColumn.running,
        links: [
          BoardLink(kind: BoardLinkKind.run, id: 'rayleigh-benard-3d'),
          BoardLink(kind: BoardLinkKind.dataset, id: 'rb3d-snapshots'),
        ],
      ),
      const BoardCard(
        id: 'demo-mesh',
        title: 'Mesh convergence for the wake',
        project: 'aerodynamics',
        column: BoardColumn.todo,
        notes: 'Three resolutions, compare the Strouhal number.',
        links: [
          BoardLink(kind: BoardLinkKind.run, id: 'cylinder-wake-re200'),
          BoardLink(kind: BoardLinkKind.dataset, id: 'cylinder-wake-fields'),
        ],
      ),
      const BoardCard(
        id: 'demo-darcy',
        title: 'Permeability contrast study',
        project: 'porous-media',
        column: BoardColumn.done,
        links: [BoardLink(kind: BoardLinkKind.run, id: 'darcy-heterogeneous')],
      ),
      const BoardCard(
        id: 'demo-quota',
        title: 'Ask about more A100 hours',
        column: BoardColumn.ideas,
      ),
    ]);
  }

  final Map<String, BoardCard> _cards;

  @override
  Future<List<BoardCard>> fetchCards() async => _cards.values.toList();

  @override
  Future<BoardCard> saveCard(BoardCard card) async {
    final now = DateTime.now();
    final old = _cards[card.id];
    final saved = BoardCard.fromJson({
      ...card.toJson(),
      'id': card.id,
      'createdAt': (old?.createdAt ?? now).toUtc().toIso8601String(),
      'updatedAt': now.toUtc().toIso8601String(),
    });
    _cards[card.id] = saved;
    return saved;
  }

  @override
  Future<void> deleteCard(String cardId) async => _cards.remove(cardId);
}
