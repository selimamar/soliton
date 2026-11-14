import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The items picked in a list, in the order they were picked; null when the
/// list isn't in picking mode.
class Selection extends Notifier<List<String>?> {
  @override
  List<String>? build() => null;

  /// Starts picking, with [first] already picked (a long press on it).
  void start([String? first]) => state = [?first];

  void cancel() => state = null;

  void toggle(String id) {
    final picked = state;
    if (picked == null) return;
    state = picked.contains(id) ? ([...picked]..remove(id)) : [...picked, id];
  }

  /// Picks all of [ids]; if they are all picked already, none of them.
  void toggleAll(List<String> ids) {
    final picked = state ?? const [];
    state = ids.every(picked.contains)
        ? [
            for (final id in picked)
              if (!ids.contains(id)) id,
          ]
        : [
            ...picked,
            for (final id in ids)
              if (!picked.contains(id)) id,
          ];
  }
}

/// Runs picked in the runs list, to compare or delete.
final runSelectionProvider = NotifierProvider<Selection, List<String>?>(Selection.new);

/// Simulations picked in Compute, to delete.
final simulationSelectionProvider = NotifierProvider<Selection, List<String>?>(Selection.new);

/// Datasets picked in Data, to delete.
final datasetSelectionProvider = NotifierProvider<Selection, List<String>?>(Selection.new);
