import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/run.dart';
import '../../shared/clock.dart';
import '../../shared/search.dart';
import '../../shared/selection.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/delete_dialog.dart';
import '../../shared/widgets/picking_app_bar.dart';
import '../../shared/widgets/sparkline.dart';
import '../../shared/widgets/status_chip.dart';
import '../runs_list/runs_list_screen.dart' show StatusFilterBar, searchRuns;
import 'simulation_text.dart';

/// The status the simulations list is filtered to (null: all).
final simulationFilterProvider = NotifierProvider<SimulationFilter, RunStatus?>(
  SimulationFilter.new,
);

class SimulationFilter extends Notifier<RunStatus?> {
  @override
  RunStatus? build() => null;

  void select(RunStatus? status) => state = status;
}

/// The Compute section: every simulation (`soliton.simulate()`), newest
/// first, with where it is and its monitored value.
class SimulationsScreen extends ConsumerWidget {
  const SimulationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picked = ref.watch(simulationSelectionProvider);
    return Scaffold(
      appBar: picked == null ? _appBar(context, ref) : _pickingAppBar(context, ref, picked),
      body: AsyncValueView(
        value: ref.watch(simulationsProvider),
        onRetry: () => ref.invalidate(allRunsProvider),
        data: (simulations) => _SimulationsList(simulations: simulations),
      ),
    );
  }

  AppBar _pickingAppBar(BuildContext context, WidgetRef ref, List<String> picked) {
    final simulations = ref.watch(simulationsProvider).value ?? const <Run>[];
    final filter = ref.watch(simulationFilterProvider);
    final byId = {for (final s in simulations) s.id: s};
    return pickingAppBar(
      context,
      kind: DeleteKind.simulation,
      picked: picked,
      shown: [
        for (final s in searchRuns(simulations, ref.watch(simulationSearchProvider)))
          if (filter == null || s.status == filter) s.id,
      ],
      selection: ref.read(simulationSelectionProvider.notifier),
      describe: (id) =>
          (id: id, name: byId[id]?.name ?? id, live: byId[id]?.status == RunStatus.live),
    );
  }

  AppBar _appBar(BuildContext context, WidgetRef ref) {
    return AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Image.asset('assets/branding/app_mark.png', width: 24, height: 24),
          ),
          const SizedBox(width: 10),
          const Flexible(child: Text('Simulations', overflow: TextOverflow.ellipsis)),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.checklist),
          tooltip: 'Pick simulations to delete',
          onPressed: () => ref.read(simulationSelectionProvider.notifier).start(),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          onPressed: () => context.go(AppRoutes.settings),
        ),
      ],
    );
  }
}

class _SimulationsList extends ConsumerWidget {
  const _SimulationsList({required this.simulations});

  final List<Run> simulations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (simulations.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No simulations yet. Monitor one from Python with '
            'soliton.simulate(name, t_end=...), then sim.log({...}, t=t).',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final filter = ref.watch(simulationFilterProvider);
    final picked = ref.watch(simulationSelectionProvider);
    final query = ref.watch(simulationSearchProvider);
    final found = searchRuns(simulations, query);
    final shown = [
      for (final s in found)
        if (filter == null || s.status == filter) s,
    ];
    return RefreshIndicator(
      onRefresh: () => ref.refresh(allRunsProvider.future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  ListSearchField(
                    provider: simulationSearchProvider,
                    hint: 'Search name, project, host…',
                  ),
                  StatusFilterBar(
                    runs: found,
                    selected: filter,
                    onSelected: ref.read(simulationFilterProvider.notifier).select,
                  ),
                  const SizedBox(height: 12),
                  if (shown.isEmpty) _NoMatch(query: query),
                  for (final s in shown) ...[
                    SimulationCard(simulation: s, selected: picked?.contains(s.id)),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Why the list is empty: nothing matches the search, or the status.
class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
    child: Text(
      query.trim().isEmpty
          ? 'No simulations with this status'
          : 'No simulations match "${query.trim()}"',
      textAlign: TextAlign.center,
    ),
  );
}

/// A simulation in the list: name, where it runs, where it is (simulated
/// time or iterations, or why it stopped), and its monitored value.
class SimulationCard extends ConsumerWidget {
  const SimulationCard({super.key, required this.simulation, this.selected});

  final Run simulation;

  /// Non-null while picking simulations: whether this one is picked. A tap
  /// then picks it (or not) instead of opening it.
  final bool? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = ref.watch(clockProvider);
    final run = simulation;
    final sim = run.simulation!;
    final failed = run.status == RunStatus.crashed;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final summary = describeSimulation(run, now);

    final selection = ref.read(simulationSelectionProvider.notifier);
    // One focus stop that says whether it's picked.
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        child: Card(
          clipBehavior: Clip.antiAlias,
          shape: pickedCardShape(context, selected: selected),
          child: InkWell(
            onTap: selected == null
                ? () => context.go(AppRoutes.simulation(run.id))
                : () => selection.toggle(run.id),
            onLongPress: selected == null ? () => selection.start(run.id) : null,
            child: Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: run.status.color(scheme), width: 3)),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (selected case final isSelected?) PickMark(selected: isSelected),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              run.name,
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [run.host, run.project].where((s) => s.isNotEmpty).join(' · '),
                              style: muted,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusChip(status: run.status, label: simulationStatusLabel(run)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          summary,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFeatures: AppText.tabular,
                            color: failed ? scheme.error : scheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (sim.preview.length > 1) ...[
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 96,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Sparkline(
                                values: sim.preview,
                                color: failed ? scheme.error : scheme.onSurface,
                                endDotColor: failed ? null : run.status.color(scheme),
                                semanticLabel: '${describeValue(sim.monitor!)} over the simulation',
                              ),
                              const SizedBox(height: 2),
                              Text(
                                describeValue(sim.monitor!),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (run.status == RunStatus.live) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: run.progress,
                      minHeight: 2,
                      semanticsLabel: 'Simulation progress',
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
