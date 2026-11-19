import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Shared by the Runs, Compute and Data lists: the "Group and order" menu,
/// grouping a list, and the header of each group.

/// Items that share a key (a project, a host…), in the order given.
class ItemGroup<T> {
  const ItemGroup({required this.label, required this.items, this.isRest = false});

  final String label;
  final List<T> items;

  /// The items without a key, e.g. "No project". Listed last.
  final bool isRest;
}

/// [items] in groups by [keysOf], sorted by name (ignoring case), the rest
/// (no key) last as [restLabel]. An item with several keys (tags, the
/// projects that used a dataset) is in each of their groups. Within a
/// group, items keep the order given.
List<ItemGroup<T>> groupItems<T>(
  List<T> items,
  Iterable<String?> Function(T item) keysOf,
  String restLabel,
) {
  // Keyed ignoring case; shown as first written.
  final labels = <String, String>{};
  final members = <String, List<T>>{};
  final rest = <T>[];
  for (final item in items) {
    final keys = {
      for (final key in keysOf(item))
        if (key != null && key.trim().isNotEmpty) key.trim(),
    };
    if (keys.isEmpty) rest.add(item);
    final seen = <String>{};
    for (final key in keys) {
      final id = key.toLowerCase();
      if (!seen.add(id)) continue;
      labels.putIfAbsent(id, () => key);
      (members[id] ??= []).add(item);
    }
  }
  final ids = members.keys.toList()
    ..sort((a, b) => labels[a]!.toLowerCase().compareTo(labels[b]!.toLowerCase()));
  return [
    for (final id in ids) ItemGroup(label: labels[id]!, items: members[id]!),
    if (rest.isNotEmpty) ItemGroup(label: restLabel, items: rest, isRest: true),
  ];
}

/// [items] sorted by [compare], keeping the given order for ties (Dart's
/// `List.sort` isn't stable).
List<T> stableSorted<T>(List<T> items, int Function(T a, T b) compare) {
  final indices = [for (var i = 0; i < items.length; i++) i]
    ..sort((a, b) {
      final c = compare(items[a], items[b]);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in indices) items[i]];
}

/// Groups folded away in one list, as `grouping:label` (until the app
/// restarts).
class CollapsedGroups extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  static String keyOf(Enum grouping, String label) => '${grouping.name}:$label';

  bool contains(Enum grouping, String label) => state.contains(keyOf(grouping, label));

  void toggle(String key) =>
      state = state.contains(key) ? ({...state}..remove(key)) : {...state, key};
}

/// The app bar's "Group and order" menu: what the list is grouped by, then
/// what it is ordered by, each with a check on the current choice.
class GroupOrderButton<G extends Enum, O extends Enum> extends StatelessWidget {
  const GroupOrderButton({
    super.key,
    required this.tooltip,
    required this.groupings,
    required this.grouping,
    required this.groupingLabel,
    required this.onGrouping,
    required this.orders,
    required this.order,
    required this.orderLabel,
    required this.onOrder,
  });

  /// E.g. "Group and order datasets".
  final String tooltip;

  final List<G> groupings;
  final G grouping;

  /// The menu line for a grouping, e.g. "By host".
  final String Function(G grouping) groupingLabel;
  final ValueChanged<G> onGrouping;

  final List<O> orders;
  final O order;

  /// The menu line for an order, e.g. "Largest first".
  final String Function(O order) orderLabel;
  final ValueChanged<O> onOrder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return PopupMenuButton<Enum>(
      icon: const Icon(Icons.workspaces_outline),
      tooltip: tooltip,
      onSelected: (choice) {
        if (choice is G) {
          onGrouping(choice);
        } else if (choice is O) {
          onOrder(choice);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(enabled: false, height: 32, child: Text('Group', style: heading)),
        for (final option in groupings)
          CheckedPopupMenuItem<Enum>(
            value: option,
            checked: option == grouping,
            child: Text(groupingLabel(option)),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(enabled: false, height: 32, child: Text('Order', style: heading)),
        for (final option in orders)
          CheckedPopupMenuItem<Enum>(
            value: option,
            checked: option == order,
            child: Text(orderLabel(option)),
          ),
      ],
    );
  }
}

/// A group's name and how many it holds; tap to fold it away.
class GroupHeader extends StatelessWidget {
  const GroupHeader({
    super.key,
    required this.label,
    required this.count,
    required this.collapsed,
    required this.onTap,
    this.isRest = false,
  });

  final String label;

  /// E.g. "3 runs".
  final String count;
  final bool collapsed;
  final VoidCallback onTap;

  /// The group of items without a key: in a quieter color.
  final bool isRest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      expanded: !collapsed,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isRest ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ),
              Text(
                count,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              ExcludeSemantics(child: Icon(collapsed ? Icons.expand_more : Icons.expand_less)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The menu line for grouping by [label]: "By project", "By PDE" (an
/// acronym keeps its capitals).
String groupByLabel(String label) =>
    'By ${label == label.toUpperCase() ? label : label.toLowerCase()}';

/// "1 run", "3 runs".
String countOf(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';
