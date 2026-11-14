import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/run.dart';
import '../../shared/redirect.dart';
import '../../shared/widgets/async_value_view.dart';
import '../../shared/widgets/delete_dialog.dart';
import '../../shared/widgets/status_chip.dart';
import '../run_detail/fields_wording.dart';
import '../run_detail/run_detail_screen.dart' show KeepAliveTab;
import '../run_detail/tabs/fields_tab.dart';
import '../run_detail/tabs/system_tab.dart';
import 'diagnostics_tab.dart';
import 'simulation_overview_tab.dart';
import 'simulation_text.dart';

/// A simulation's tabs, in order; their names are what `?tab=` takes in its
/// link (e.g. `/compute/kelvin-helmholtz-2048?tab=fields`).
enum SimulationTab { overview, diagnostics, fields, system }

/// One simulation: Overview (where it is, its cost and setup), Diagnostics
/// (every logged value against simulated time), Fields and System.
class SimulationScreen extends ConsumerWidget {
  const SimulationScreen({
    super.key,
    required this.simulationId,
    this.initialTab = SimulationTab.overview,
  });

  final String simulationId;
  final SimulationTab initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(runProvider(simulationId));
    final loaded = value.value;
    // A training run's id under /compute opens it as a run.
    if (loaded != null && !loaded.isSimulation) {
      final tab = switch (initialTab) {
        SimulationTab.overview => null,
        SimulationTab.diagnostics => 'metrics',
        SimulationTab.fields => 'fields',
        SimulationTab.system => 'system',
      };
      final page = AppRoutes.run(simulationId);
      goAfterFrame(context, tab == null ? page : '$page?tab=$tab');
      return const Scaffold();
    }
    // Fields at a step are shown at their simulated time.
    final metrics = ref.watch(runMetricsProvider(simulationId)).value;
    final times = metrics == null ? null : SimulatedTimes.from(metrics);

    return DefaultTabController(
      key: ValueKey(initialTab),
      length: SimulationTab.values.length,
      initialIndex: initialTab.index,
      child: Scaffold(
        appBar: AppBar(
          title: loaded == null
              ? Text(simulationId)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(loaded.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [loaded.host, loaded.project].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: AppTheme.headerColorsOf(context).muted),
                    ),
                  ],
                ),
          actions: [
            if (loaded != null) ...[
              StatusChip(
                status: loaded.status,
                inHeader: true,
                label: simulationStatusLabel(loaded),
              ),
              const SizedBox(width: 4),
              DeleteButton(
                kind: DeleteKind.simulation,
                item: (id: loaded.id, name: loaded.name, live: loaded.status == RunStatus.live),
                then: AppRoutes.compute,
              ),
              const SizedBox(width: 4),
            ],
          ],
          bottom: loaded == null
              ? null
              : TabBar(
                  isScrollable: MediaQuery.sizeOf(context).width < 420,
                  tabAlignment: MediaQuery.sizeOf(context).width < 420
                      ? TabAlignment.start
                      : TabAlignment.fill,
                  tabs: [
                    for (final name in ['Overview', 'Diagnostics', 'Fields', 'System'])
                      AppTheme.styleOf(context) == AppStyle.lab
                          ? Tab(child: Text(name.toUpperCase(), semanticsLabel: name))
                          : Tab(text: name),
                  ],
                ),
        ),
        body: AsyncValueView(
          value: value,
          onRetry: () => ref.invalidate(runProvider(simulationId)),
          data: (run) => TabBarView(
            // As on a run's page: a drag on a chart reads its values.
            physics: const NeverScrollableScrollPhysics(),
            children: [
              KeepAliveTab(child: SimulationOverviewTab(simulation: run)),
              KeepAliveTab(child: DiagnosticsTab(simulation: run)),
              KeepAliveTab(
                child: FieldsWording(
                  prediction: 'Field',
                  compares: false,
                  stepLabel: simulationStepLabel(times),
                  child: FieldsTab(runId: run.id),
                ),
              ),
              KeepAliveTab(child: SystemTab(run: run)),
            ],
          ),
        ),
      ),
    );
  }
}
