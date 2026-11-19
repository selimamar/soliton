import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/settings_store.dart';
import '../../models/run.dart';
import '../../shared/widgets/group_order.dart';
import '../runs_list/run_groups.dart';

/// The groupings that make sense for simulations (they have no model or
/// training dataset).
const simulationGroupings = [
  RunGrouping.none,
  RunGrouping.project,
  RunGrouping.pde,
  RunGrouping.tag,
  RunGrouping.host,
];

/// What the Compute list is grouped by, saved on the device.
final simulationGroupingProvider = NotifierProvider<Setting<RunGrouping>, RunGrouping>(
  () => Setting.choice('simulationsGroupBy', RunGrouping.none, simulationGroupings),
);

/// What the Compute list is ordered by, saved on the device.
enum SimulationOrder {
  newest('Newest first'),
  name('Name, A to Z'),
  longest('Longest running first'),
  progress('Furthest along first');

  const SimulationOrder(this.label);

  final String label;
}

final simulationOrderProvider = NotifierProvider<Setting<SimulationOrder>, SimulationOrder>(
  () => Setting.choice('simulationsOrderBy', SimulationOrder.newest, SimulationOrder.values),
);

/// Compute groups folded away.
final collapsedSimulationGroupsProvider = NotifierProvider<CollapsedGroups, Set<String>>(
  CollapsedGroups.new,
);

/// [simulations] in [order], as of [now] (for how long each has run). Ties
/// keep the order given.
List<Run> orderSimulations(
  List<Run> simulations,
  SimulationOrder order,
  DateTime now,
) => switch (order) {
  SimulationOrder.newest => stableSorted(simulations, (a, b) => b.startedAt.compareTo(a.startedAt)),
  SimulationOrder.name => stableSorted(
    simulations,
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  ),
  SimulationOrder.longest => stableSorted(
    simulations,
    (a, b) => b.elapsedAt(now).compareTo(a.elapsedAt(now)),
  ),
  SimulationOrder.progress => stableSorted(simulations, (a, b) => b.progress.compareTo(a.progress)),
};
