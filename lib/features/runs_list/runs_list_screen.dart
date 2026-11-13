import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../data/services/live_updates.dart';
import '../../models/run.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';
import 'widgets/run_card.dart';

/// Which status the list shows. `null` means all runs.
final runFilterProvider = NotifierProvider<RunFilter, RunStatus?>(RunFilter.new);

class RunFilter extends Notifier<RunStatus?> {
  @override
  RunStatus? build() => null;

  void select(RunStatus? status) => state = status;
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

/// Home screen: every run as a card, with status filters.
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
    title: const Text('Runs'),
    actions: [
      const _LiveStatusButton(),
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

    return RefreshIndicator(
      onRefresh: () => ref.refresh(runsProvider.future),
      child: SpacedListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (demo && picked == null) const _DemoBanner(),
          _FilterBar(runs: runs),
          if (runs.isEmpty)
            const _EmptyState(
              'No runs yet. Start one with the modelsapp Python logger: it appears here '
              'as soon as it logs.',
            )
          else if (visibleRuns.isEmpty)
            const _EmptyState('No runs with this status'),
          for (final run in visibleRuns)
            if (picked != null)
              RunCard(
                run: run,
                selected: picked.contains(run.id),
                onTap: () => ref.read(compareSelectionProvider.notifier).toggle(run.id),
              )
            else
              // `go` (not `push`) so the browser URL follows on the web. The
              // detail route is nested under '/', so Back still returns here.
              RunCard(run: run, onTap: () => context.go(AppRoutes.run(run.id))),
        ],
      ),
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

/// Says that the runs are made up, with a way to connect a server.
class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.science_outlined),
          const SizedBox(width: 12),
          const Expanded(child: Text('Demo data. Connect your server to see your own runs.')),
          TextButton(onPressed: () => context.go(AppRoutes.server), child: const Text('Connect')),
        ],
      ),
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

/// Chips to filter by status, each showing how many runs it matches.
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.runs});

  final List<Run> runs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(runFilterProvider);
    final options = <RunStatus?>[null, ...RunStatus.values];

    String labelFor(RunStatus? status) {
      final count = status == null ? runs.length : runs.where((r) => r.status == status).length;
      return '${status?.label ?? 'All'} · $count';
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final status in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(labelFor(status)),
                selected: selected == status,
                showCheckmark: false,
                onSelected: (_) => ref.read(runFilterProvider.notifier).select(status),
              ),
            ),
        ],
      ),
    );
  }
}
