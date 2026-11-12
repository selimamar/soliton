import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/run.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/spaced_list_view.dart';
import 'widgets/run_card.dart';

/// Which status the list shows. `null` means all runs.
final runFilterProvider = NotifierProvider<RunFilter, RunStatus?>(RunFilter.new);

class RunFilter extends Notifier<RunStatus?> {
  @override
  RunStatus? build() => null;

  void select(RunStatus? status) => state = status;
}

/// Home screen: every run as a card, with status filters.
class RunsListScreen extends ConsumerWidget {
  const RunsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Runs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.go(AppRoutes.settings),
          ),
        ],
      ),
      body: AsyncValueView(
        value: ref.watch(runsProvider),
        onRetry: () => ref.invalidate(runsProvider),
        data: (runs) => _RunsList(runs: runs),
      ),
    );
  }
}

class _RunsList extends ConsumerWidget {
  const _RunsList({required this.runs});

  final List<Run> runs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(runFilterProvider);
    final visibleRuns = filter == null ? runs : runs.where((r) => r.status == filter).toList();

    return RefreshIndicator(
      onRefresh: () => ref.refresh(runsProvider.future),
      child: SpacedListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _FilterBar(runs: runs),
          if (visibleRuns.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: Text('No runs with this status')),
            ),
          for (final run in visibleRuns)
            // `go` (not `push`) so the browser URL follows on the web. The
            // detail route is nested under '/', so Back still returns here.
            RunCard(run: run, onTap: () => context.go(AppRoutes.run(run.id))),
        ],
      ),
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
