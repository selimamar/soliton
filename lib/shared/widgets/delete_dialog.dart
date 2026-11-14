import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/providers.dart';
import 'async_value_view.dart' show describeError;

/// What is being deleted, for the words around it.
enum DeleteKind {
  run('run', 'runs'),
  simulation('simulation', 'simulations'),
  dataset('dataset', 'datasets');

  const DeleteKind(this.singular, this.plural);

  final String singular;
  final String plural;

  String count(int n) => n == 1 ? '1 $singular' : '$n $plural';
}

/// Something to delete: its id, its name for the dialog, and whether it is
/// still running (its logger would bring it back).
typedef Deletable = ({String id, String name, bool live});

/// Asks whether to delete [items]; if yes, deletes them, goes to [then]
/// (e.g. off the page of a deleted run), and says how it went in a
/// snack bar. Returns whether everything was deleted.
Future<bool> confirmAndDelete(
  BuildContext context, {
  required DeleteKind kind,
  required List<Deletable> items,
  String? then,
}) async {
  if (items.isEmpty) return false;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => DeleteDialog(kind: kind, items: items),
  );
  if (yes != true || !context.mounted) return false;

  // The page may be gone when the deletion ends: hold on to what outlives it.
  final deleter = ProviderScope.containerOf(context, listen: false).read(deleterProvider);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.maybeOf(context);
  final ids = [for (final item in items) item.id];
  final outcome = kind == DeleteKind.dataset
      ? await deleter.deleteDatasets(ids)
      : await deleter.deleteRuns(ids);

  if (then != null && outcome.deleted > 0) router?.go(then);
  final String message;
  if (outcome.error case final error?) {
    final reason = describeError(error).title;
    message = outcome.deleted == 0
        ? "Couldn't delete ${items.length == 1 ? items.single.name : kind.count(items.length)}: "
              '$reason'
        : 'Deleted ${outcome.deleted} of ${kind.count(items.length)}, then stopped: $reason';
  } else {
    message = items.length == 1
        ? 'Deleted ${items.single.name}'
        : 'Deleted ${kind.count(items.length)}';
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  return outcome.error == null;
}

/// "Delete 3 runs?", what goes and what doesn't, and a red Delete button.
class DeleteDialog extends StatelessWidget {
  const DeleteDialog({super.key, required this.kind, required this.items});

  final DeleteKind kind;
  final List<Deletable> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final one = items.length == 1;
    final live = items.where((i) => i.live).length;
    final what = switch (kind) {
      DeleteKind.run =>
        '${one ? 'Its' : 'Their'} metrics, layer statistics, fields and notes are removed from '
            "the server. This can't be undone.",
      DeleteKind.simulation =>
        '${one ? 'Its' : 'Their'} logged values and fields are removed from the server. This '
            "can't be undone.",
      DeleteKind.dataset =>
        'Only ${one ? 'its description goes' : 'their descriptions go'}: the files '
            "aren't touched, and runs that trained on ${one ? 'it' : 'them'} keep "
            "${one ? 'its name' : 'their names'}. Registering ${one ? 'it' : 'them'} again "
            "brings ${one ? 'it' : 'them'} back.",
    };
    final running = switch (live) {
      0 => null,
      _ when one => "It's still running: what it logs next brings it back, from then on.",
      1 => '1 of them is still running: what it logs next brings it back, from then on.',
      _ => '$live of them are still running: what they log next brings them back, from then on.',
    };
    return AlertDialog(
      title: Text(
        one
            ? 'Delete ${kind.singular} "${items.single.name}"?'
            : 'Delete ${kind.count(items.length)}?',
      ),
      content: Text([what, ?running].join('\n\n')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

/// The delete button on a run, simulation or dataset page.
class DeleteButton extends StatelessWidget {
  const DeleteButton({super.key, required this.kind, required this.item, required this.then});

  final DeleteKind kind;
  final Deletable? item;

  /// Where to go once it's deleted (its section's list).
  final String then;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.delete_outline),
    tooltip: 'Delete ${kind.singular}',
    onPressed: switch (item) {
      final item? => () => confirmAndDelete(context, kind: kind, items: [item], then: then),
      null => null,
    },
  );
}
