import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../data/services/live_updates.dart';
import '../../models/run.dart';
import '../../shared/search.dart';
import '../../shared/selection.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/connection_banner.dart';
import '../../shared/widgets/delete_dialog.dart';
import '../../shared/widgets/picking_app_bar.dart';
import '../../shared/widgets/spaced_list_view.dart';
import 'run_groups.dart';
import 'widgets/run_card.dart';
import 'widgets/run_card_styles.dart';

/// Which status the list shows. `null` means all runs.
final runFilterProvider = NotifierProvider<RunFilter, RunStatus?>(RunFilter.new);

class RunFilter extends Notifier<RunStatus?> {
  @override
  RunStatus? build() => null;

  void select(RunStatus? status) => state = status;
}

/// Groups folded away, as `grouping:label` (until the app restarts).
final collapsedGroupsProvider = NotifierProvider<CollapsedGroups, Set<String>>(CollapsedGroups.new);

class CollapsedGroups extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  static String keyOf(RunGrouping grouping, RunGroup group) => '${grouping.name}:${group.label}';

  void toggle(String key) =>
      state = state.contains(key) ? ({...state}..remove(key)) : {...state, key};
}

/// The runs whose name, project, host, tags, notes, model, dataset or PDE
/// match [query] (see [matchesSearch]).
List<Run> searchRuns(List<Run> runs, String query) => query.trim().isEmpty
    ? runs
    : [
        for (final run in runs)
          if (matchesSearch(query, runSearchFields(run))) run,
      ];

/// More lines than this make a comparison chart unreadable.
const maxComparedRuns = 6;

/// Home screen: every run as a card, with status filters, optionally in
/// groups (by project, model, dataset, tag or host).
class RunsListScreen extends ConsumerWidget {
  const RunsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picked = ref.watch(runSelectionProvider);

    return Scaffold(
      appBar: picked == null ? _appBar(context, ref) : _pickingAppBar(context, ref, picked),
      body: AsyncValueView(
        value: ref.watch(runsProvider),
        onRetry: () => ref.invalidate(allRunsProvider),
        data: (runs) => _RunsList(runs: runs),
      ),
    );
  }

  AppBar _appBar(BuildContext context, WidgetRef ref) => AppBar(
    title: Row(
      // As narrow as its content, so Ink can centre it.
      mainAxisSize: MainAxisSize.min,
      children: [
        // The app icon, small. Decoded once at its display size.
        ExcludeSemantics(child: Image.asset('assets/branding/app_mark.png', width: 24, height: 24)),
        const SizedBox(width: 10),
        // Lab writes it like a prompt, with a cursor in its accent. On a
        // narrow phone the title gives way to the buttons.
        Flexible(
          child: AppTheme.styleOf(context) == AppStyle.lab
              ? Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'runs'),
                      TextSpan(
                        text: '_',
                        style: TextStyle(color: TabBarTheme.of(context).labelColor),
                      ),
                    ],
                  ),
                  semanticsLabel: 'Runs',
                  overflow: TextOverflow.ellipsis,
                )
              : const Text('Runs', overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
    actions: [
      const _LiveStatusButton(),
      const _GroupingButton(),
      IconButton(
        icon: const Icon(Icons.egg_outlined),
        tooltip: 'Farm: runs as ducks and eggs',
        onPressed: () => context.go(AppRoutes.farm),
      ),
      IconButton(
        icon: const Icon(Icons.grid_on),
        tooltip: 'Sweep: runs by hyperparameters',
        onPressed: () => context.go(AppRoutes.sweep),
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: 'Pick runs to compare or delete',
        onPressed: () => ref.read(runSelectionProvider.notifier).start(),
      ),
      IconButton(
        icon: const Icon(Icons.settings_outlined),
        tooltip: 'Settings',
        onPressed: () => context.go(AppRoutes.settings),
      ),
    ],
  );

  /// While picking runs: how many, and what to do with them.
  AppBar _pickingAppBar(BuildContext context, WidgetRef ref, List<String> picked) {
    final selection = ref.read(runSelectionProvider.notifier);
    final runs = ref.watch(runsProvider).value ?? const <Run>[];
    final filter = ref.watch(runFilterProvider);
    final byId = {for (final run in runs) run.id: run};
    return pickingAppBar(
      context,
      kind: DeleteKind.run,
      picked: picked,
      shown: [
        for (final run in searchRuns(runs, ref.watch(runSearchProvider)))
          if (filter == null || run.status == filter) run.id,
      ],
      selection: selection,
      describe: (id) =>
          (id: id, name: byId[id]?.name ?? id, live: byId[id]?.status == RunStatus.live),
      trailing: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 8),
          child: Tooltip(
            message: 'Compare 2 to $maxComparedRuns runs',
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: picked.length >= 2 && picked.length <= maxComparedRuns
                  ? () {
                      selection.cancel();
                      context.go(AppRoutes.compare(picked));
                    }
                  : null,
              child: const Text('Compare'),
            ),
          ),
        ),
      ],
    );
  }
}

class _RunsList extends ConsumerWidget {
  const _RunsList({required this.runs});

  final List<Run> runs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(runFilterProvider);
    final picked = ref.watch(runSelectionProvider);
    final query = ref.watch(runSearchProvider);
    // The status counts are of the runs that match the search.
    final found = searchRuns(runs, query);
    final visibleRuns = filter == null ? found : found.where((r) => r.status == filter).toList();
    final grouping = ref.watch(runGroupingProvider);
    final collapsed = ref.watch(collapsedGroupsProvider);
    // Ordered by a metric, each group (or the whole list) is ranked by it,
    // best first. Until the values arrive, the list stays newest first.
    final order = ref.watch(runOrderProvider);
    final logged = switch (order.metric) {
      final metric? => ref.watch(latestMetricsProvider(metric)).value,
      null => null,
    };
    List<(Run, RunRanking?)> ranked(List<Run> runs) => logged == null
        ? [for (final run in runs) (run, null)]
        : [
            for (final (run, score) in rankRuns(runs, order, logged))
              (run, (order: order, score: score)),
          ];
    // Ink lays the runs out as a table in a paper: an abstract, a header
    // row, rows without gaps, and footnotes.
    final journal = AppTheme.styleOf(context) == AppStyle.ink;

    Widget card((Run, RunRanking?) entry) {
      final (run, ranking) = entry;
      return picked != null
          ? RunCard(
              run: run,
              ranking: ranking,
              selected: picked.contains(run.id),
              onTap: () => ref.read(runSelectionProvider.notifier).toggle(run.id),
            )
          // `go` (not `push`) so the browser URL follows on the web. The
          // detail route is nested under '/', so Back still returns here.
          : RunCard(
              run: run,
              ranking: ranking,
              onTap: () => context.go(AppRoutes.run(run.id)),
              onLongPress: () => ref.read(runSelectionProvider.notifier).start(run.id),
            );
    }

    return RefreshIndicator(
      onRefresh: () => ref.refresh(allRunsProvider.future),
      child: SpacedListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        spacing: journal ? 0 : 8,
        children: [
          if (journal && picked == null && runs.isNotEmpty) _Abstract(runs: runs),
          if (runs.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: journal ? 12 : 8),
              child: ListSearchField(
                provider: runSearchProvider,
                hint: 'Search name, tag, project, host…',
              ),
            ),
          StatusFilterBar(
            runs: found,
            selected: ref.watch(runFilterProvider),
            onSelected: ref.read(runFilterProvider.notifier).select,
          ),
          if (picked == null) const ConnectionBanner(),
          if (journal && visibleRuns.isNotEmpty)
            _TableHeader(value: logged == null ? 'Loss' : order.shortLabel),
          if (runs.isEmpty)
            const _EmptyState(
              'No runs yet. Start one with the soliton Python logger: it appears here '
              'as soon as it logs.',
            )
          else if (visibleRuns.isEmpty)
            _EmptyState(switch ((query.trim(), found.isEmpty)) {
              ('', _) => 'No runs with this status',
              (final q, true) => 'No runs match "$q"',
              (final q, false) => 'No runs with this status match "$q"',
            }),
          if (grouping == RunGrouping.none)
            for (final entry in ranked(visibleRuns)) card(entry)
          else
            for (final group in groupRuns(visibleRuns, grouping)) ...[
              _GroupHeader(
                group: group,
                collapsed: collapsed.contains(CollapsedGroups.keyOf(grouping, group)),
                onTap: () => ref
                    .read(collapsedGroupsProvider.notifier)
                    .toggle(CollapsedGroups.keyOf(grouping, group)),
              ),
              if (!collapsed.contains(CollapsedGroups.keyOf(grouping, group)))
                for (final entry in ranked(group.runs)) card(entry),
            ],
          if (journal && visibleRuns.isNotEmpty) _TableFooter(runs: visibleRuns),
        ],
      ),
    );
  }
}

/// A group's name and size; tap to fold it away.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, required this.collapsed, required this.onTap});

  final RunGroup group;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = group.runs.length;
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
                  group.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: group.isRest ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ),
              Text(
                count == 1 ? '1 run' : '$count runs',
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

/// Picks what the list is grouped by, and what it's ordered by: grouped,
/// then ordered by a metric, each group is a small leaderboard.
class _GroupingButton extends ConsumerWidget {
  const _GroupingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(runGroupingProvider);
    final order = ref.watch(runOrderProvider);
    final heading = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return PopupMenuButton<Enum>(
      icon: const Icon(Icons.workspaces_outline),
      tooltip: 'Group and order runs',
      onSelected: (choice) => switch (choice) {
        final RunGrouping grouping => ref.read(runGroupingProvider.notifier).set(grouping),
        final RunOrder order => ref.read(runOrderProvider.notifier).set(order),
        _ => null,
      },
      itemBuilder: (context) => [
        PopupMenuItem(enabled: false, height: 32, child: Text('Group', style: heading)),
        for (final grouping in RunGrouping.values)
          CheckedPopupMenuItem(
            value: grouping,
            checked: grouping == current,
            child: Text(
              grouping == RunGrouping.none ? grouping.label : 'By ${grouping.label.toLowerCase()}',
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(enabled: false, height: 32, child: Text('Order', style: heading)),
        for (final option in RunOrder.values)
          CheckedPopupMenuItem(
            value: option,
            checked: option == order,
            child: Text(
              option.metric == null
                  ? option.label
                  : '${option.label}, ${option.lowerIsBetter ? 'lowest' : 'highest'} first',
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
    child: Center(child: Text(text, textAlign: TextAlign.center)),
  );
}

/// Whether live updates are flowing; opens the server settings. Hidden on
/// demo data.
class _LiveStatusButton extends ConsumerWidget {
  const _LiveStatusButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, tooltip) = switch (ref.watch(liveUpdatesProvider)) {
      LiveStatus.off => (null, ''),
      LiveStatus.live => (Icons.sensors, 'Live updates on'),
      LiveStatus.connecting => (Icons.sensors_off, 'Reconnecting to the server…'),
      LiveStatus.rejected => (Icons.key_off_outlined, 'The server rejected the token'),
    };
    if (icon == null) return const SizedBox.shrink();
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: () => context.go(AppRoutes.server),
    );
  }
}

/// Status filters, each showing how many runs it matches: underlined
/// labels in Paper, bracketed buttons in Lab, text links in Ink.
class StatusFilterBar extends StatelessWidget {
  const StatusFilterBar({
    super.key,
    required this.runs,
    required this.selected,
    required this.onSelected,
  });

  final List<Run> runs;

  /// The status shown; null for all.
  final RunStatus? selected;
  final ValueChanged<RunStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = AppTheme.styleOf(context);
    int countOf(RunStatus? status) =>
        status == null ? runs.length : runs.where((r) => r.status == status).length;
    // Queued only while some are (from `soliton sbatch`).
    final options = <RunStatus?>[
      null,
      for (final status in RunStatus.values)
        if (status != RunStatus.queued || selected == status || countOf(status) > 0) status,
    ];
    String nameOf(RunStatus? status) => status?.label ?? 'All';

    Widget option(RunStatus? status) {
      final isSelected = selected == status;
      final name = nameOf(status);
      final count = countOf(status);
      final base = theme.textTheme.labelLarge?.copyWith(fontFeatures: AppText.tabular);
      final Widget label = switch (style) {
        AppStyle.paper => Container(
          margin: const EdgeInsets.only(right: 20),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: isSelected ? scheme.primary : Colors.transparent, width: 2),
            ),
          ),
          child: Text(
            '$name · $count',
            style: base?.copyWith(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
        AppStyle.lab => Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          color: isSelected ? scheme.primary : null,
          child: Text(
            isSelected ? '[${name.toUpperCase()} $count]' : '${name.toUpperCase()} $count',
            semanticsLabel: '$name · $count',
            style: base?.copyWith(
              fontSize: 12,
              letterSpacing: 0.5,
              color: isSelected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
        AppStyle.ink => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '$name $count',
            semanticsLabel: '$name · $count',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
              decoration: isSelected ? TextDecoration.underline : null,
              decorationColor: scheme.primary,
            ),
          ),
        ),
      };
      return Semantics(
        button: true,
        selected: isSelected,
        child: InkWell(onTap: () => onSelected(status), child: label),
      );
    }

    final row = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, status) in options.indexed) ...[
            if (style == AppStyle.ink && i > 0)
              ExcludeSemantics(
                child: Text(
                  ' · ',
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            option(status),
          ],
        ],
      ),
    );

    return switch (style) {
      AppStyle.paper => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: row,
      ),
      AppStyle.lab => Padding(padding: const EdgeInsets.only(top: 10), child: row),
      AppStyle.ink => row,
    };
  }
}

/// Ink: the runs summed up like a paper's abstract, e.g. "Ten runs: four
/// live, five finished and one crashed. Three of the four live runs are
/// still improving."
class _Abstract extends StatelessWidget {
  const _Abstract({required this.runs});

  final List<Run> runs;

  static const _words = [
    'no', 'one', 'two', 'three', 'four', 'five', 'six', //
    'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve',
  ];

  static String _word(int n) => n < _words.length ? _words[n] : '$n';

  static String _capital(String s) => s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    int count(RunStatus s) => runs.where((r) => r.status == s).length;
    final live = runs.where((r) => r.status == RunStatus.live).toList();
    final improving = live.where((r) => (r.recentLossChange ?? 0) < 0).length;
    final total = runs.length;

    final queued = count(RunStatus.queued);
    final summary =
        '${_capital(_word(total))} ${total == 1 ? 'run' : 'runs'}: '
        '${queued > 0 ? '${_word(queued)} queued, ' : ''}${_word(live.length)} live, '
        '${_word(count(RunStatus.finished))} finished and ${_word(count(RunStatus.crashed))} '
        'crashed.';
    final trend = switch (live.length) {
      0 => '',
      1 => improving == 1 ? ' The live run is still improving.' : ' The live run has levelled off.',
      _ when improving == live.length =>
        ' All ${_word(live.length)} live runs are still improving.',
      _ =>
        ' ${_capital(_word(improving))} of the ${_word(live.length)} live runs are still improving.',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: 'Abstract. ',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: '$summary$trend'),
          ],
        ),
        textAlign: TextAlign.justify,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      ),
    );
  }
}

/// Ink: the runs table's header row, between a heavy and a light rule.
class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.value});

  /// The last column's heading: "Loss", or the metric the runs are
  /// ordered by.
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.onSurface, width: 1.2),
          bottom: BorderSide(color: scheme.onSurface, width: 0.6),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: Text('Run', style: style)),
          SizedBox(
            width: JournalRunRow.progressWidth,
            child: Text('Progress', style: style),
          ),
          SizedBox(
            width: JournalRunRow.lossWidth,
            child: Text(value, textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }
}

/// Ink: the heavy rule that closes the runs table, and a footnote for each
/// crash that left a message.
class _TableFooter extends StatelessWidget {
  const _TableFooter({required this.runs});

  final List<Run> runs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = [
      for (final run in runs)
        if (run.status == RunStatus.crashed && run.statusMessage != null)
          '† ${run.name}: ${run.statusMessage}',
    ];
    return Container(
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.onSurface, width: 1.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final note in notes) Text(note, style: theme.textTheme.bodySmall)],
      ),
    );
  }
}
