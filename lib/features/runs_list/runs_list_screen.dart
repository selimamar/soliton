import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../data/services/live_updates.dart';
import '../../models/run.dart';
import '../../shared/widgets/async_value_view.dart';
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

/// The runs picked for comparing, in the order they were picked; null when
/// not picking.
final compareSelectionProvider = NotifierProvider<CompareSelection, List<String>?>(
  CompareSelection.new,
);

class CompareSelection extends Notifier<List<String>?> {
  /// More lines than this make a chart unreadable.
  static const maxRuns = 6;

  @override
  List<String>? build() => null;

  void start() => state = const [];

  void cancel() => state = null;

  void toggle(String runId) {
    final picked = state;
    if (picked == null) return;
    if (picked.contains(runId)) {
      state = [...picked]..remove(runId);
    } else if (picked.length < maxRuns) {
      state = [...picked, runId];
    }
  }
}

/// Home screen: every run as a card, with status filters, optionally in
/// groups (by project, model, dataset, tag or host).
class RunsListScreen extends ConsumerWidget {
  const RunsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picked = ref.watch(compareSelectionProvider);

    return Scaffold(
      appBar: picked == null ? _appBar(context, ref) : _pickingAppBar(context, ref, picked),
      body: AsyncValueView(
        value: ref.watch(runsProvider),
        onRetry: () => ref.invalidate(runsProvider),
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
        icon: const Icon(Icons.grid_on),
        tooltip: 'Sweep: runs by hyperparameters',
        onPressed: () => context.go(AppRoutes.sweep),
      ),
      IconButton(
        icon: const Icon(Icons.compare_arrows),
        tooltip: 'Compare runs',
        onPressed: () => ref.read(compareSelectionProvider.notifier).start(),
      ),
      IconButton(
        icon: const Icon(Icons.settings_outlined),
        tooltip: 'Settings',
        onPressed: () => context.go(AppRoutes.settings),
      ),
    ],
  );

  AppBar _pickingAppBar(BuildContext context, WidgetRef ref, List<String> picked) => AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      tooltip: 'Stop comparing',
      onPressed: () => ref.read(compareSelectionProvider.notifier).cancel(),
    ),
    title: Text(picked.isEmpty ? 'Pick runs to compare' : '${picked.length} picked'),
    actions: [
      Padding(
        padding: const EdgeInsets.only(right: 12),
        child: FilledButton(
          onPressed: picked.length < 2
              ? null
              : () {
                  ref.read(compareSelectionProvider.notifier).cancel();
                  context.go(AppRoutes.compare(picked));
                },
          child: const Text('Compare'),
        ),
      ),
    ],
  );
}

class _RunsList extends ConsumerWidget {
  const _RunsList({required this.runs});

  final List<Run> runs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(runFilterProvider);
    final picked = ref.watch(compareSelectionProvider);
    final demo = ref.watch(connectionProvider) == null;
    final visibleRuns = filter == null ? runs : runs.where((r) => r.status == filter).toList();
    final grouping = ref.watch(runGroupingProvider);
    final collapsed = ref.watch(collapsedGroupsProvider);
    // Ink lays the runs out as a table in a paper: an abstract, a header
    // row, rows without gaps, and footnotes.
    final journal = AppTheme.styleOf(context) == AppStyle.ink;

    Widget card(Run run) => picked != null
        ? RunCard(
            run: run,
            selected: picked.contains(run.id),
            onTap: () => ref.read(compareSelectionProvider.notifier).toggle(run.id),
          )
        // `go` (not `push`) so the browser URL follows on the web. The
        // detail route is nested under '/', so Back still returns here.
        : RunCard(run: run, onTap: () => context.go(AppRoutes.run(run.id)));

    return RefreshIndicator(
      onRefresh: () => ref.refresh(runsProvider.future),
      child: SpacedListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        spacing: journal ? 0 : 8,
        children: [
          if (journal && picked == null && runs.isNotEmpty) _Abstract(runs: runs),
          _FilterBar(runs: runs),
          if (demo && picked == null) const _DemoBanner(),
          if (journal && visibleRuns.isNotEmpty) const _TableHeader(),
          if (runs.isEmpty)
            const _EmptyState(
              'No runs yet. Start one with the modelsapp Python logger: it appears here '
              'as soon as it logs.',
            )
          else if (visibleRuns.isEmpty)
            const _EmptyState('No runs with this status'),
          if (grouping == RunGrouping.none)
            for (final run in visibleRuns) card(run)
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
                for (final run in group.runs) card(run),
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

/// Picks what the list is grouped by.
class _GroupingButton extends ConsumerWidget {
  const _GroupingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(runGroupingProvider);
    return PopupMenuButton<RunGrouping>(
      icon: const Icon(Icons.workspaces_outline),
      tooltip: 'Group runs',
      onSelected: (grouping) => ref.read(runGroupingProvider.notifier).set(grouping),
      itemBuilder: (context) => [
        for (final grouping in RunGrouping.values)
          CheckedPopupMenuItem(
            value: grouping,
            checked: grouping == current,
            child: Text(
              grouping == RunGrouping.none ? grouping.label : 'By ${grouping.label.toLowerCase()}',
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

/// One quiet line saying the runs are made up, with a way to connect a
/// server.
class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(Icons.science_outlined, size: 16, color: muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Demo data. These runs are made up.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
        TextButton(
          onPressed: () => context.go(AppRoutes.server),
          child: const Text('Connect server'),
        ),
      ],
    );
  }
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
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.runs});

  final List<Run> runs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = AppTheme.styleOf(context);
    final selected = ref.watch(runFilterProvider);
    final options = <RunStatus?>[null, ...RunStatus.values];

    int countOf(RunStatus? status) =>
        status == null ? runs.length : runs.where((r) => r.status == status).length;
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
        child: InkWell(
          onTap: () => ref.read(runFilterProvider.notifier).select(status),
          child: label,
        ),
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

    final summary =
        '${_capital(_word(total))} ${total == 1 ? 'run' : 'runs'}: ${_word(live.length)} live, '
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
  const _TableHeader();

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
            child: Text('Loss', textAlign: TextAlign.end, style: style),
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
