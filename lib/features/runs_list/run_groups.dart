import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/settings_store.dart';
import '../../models/run.dart';

/// What the runs list is grouped by, saved on the device.
enum RunGrouping {
  none('No grouping'),
  project('Project'),
  model('Model'),
  dataset('Dataset'),
  pde('PDE'),
  tag('Tag'),
  host('Host');

  const RunGrouping(this.label);

  final String label;
}

final runGroupingProvider = NotifierProvider<Setting<RunGrouping>, RunGrouping>(
  () => Setting.choice('runsGroupBy', RunGrouping.none, RunGrouping.values),
);

/// Runs that share a project, model, dataset, tag or host.
class RunGroup {
  const RunGroup({required this.label, required this.runs, this.isRest = false});

  final String label;

  /// In the order given (newest first in the list).
  final List<Run> runs;

  /// The runs without one, e.g. "No tags". Listed last.
  final bool isRest;
}

/// [runs] in groups, sorted by name, the rest last. With tags, a run with
/// several tags is in each of their groups.
List<RunGroup> groupRuns(List<Run> runs, RunGrouping by) {
  if (by == RunGrouping.none) return [RunGroup(label: '', runs: runs)];

  // Keyed ignoring case; shown as first written.
  final labels = <String, String>{};
  final members = <String, List<Run>>{};
  final rest = <Run>[];
  for (final run in runs) {
    final keys = _keysOf(run, by);
    if (keys.isEmpty) rest.add(run);
    for (final key in keys) {
      final id = key.toLowerCase();
      labels.putIfAbsent(id, () => key);
      (members[id] ??= []).add(run);
    }
  }
  final ids = members.keys.toList()..sort((a, b) => labels[a]!.compareTo(labels[b]!));
  return [
    for (final id in ids) RunGroup(label: labels[id]!, runs: members[id]!),
    if (rest.isNotEmpty) RunGroup(label: _restLabel(by), runs: rest, isRest: true),
  ];
}

List<String> _keysOf(Run run, RunGrouping by) {
  String? single = switch (by) {
    RunGrouping.project => run.project,
    RunGrouping.host => run.host,
    RunGrouping.dataset => datasetOf(run),
    RunGrouping.pde => pdeOf(run),
    // `Model` with nothing inside: the server's stand-in for a model it was
    // never shown (no `run.watch(model)`).
    RunGrouping.model =>
      run.architecture.isLeaf && run.architecture.type == 'Model' ? null : run.architecture.type,
    RunGrouping.tag || RunGrouping.none => null,
  };
  if (by == RunGrouping.tag) return run.tags;
  single = single?.trim();
  return single == null || single.isEmpty ? const [] : [single];
}

/// The `Dataset` hyperparameter (any case, possibly nested, e.g.
/// `data.dataset`), if the run logged one.
String? datasetOf(Run run) {
  for (final MapEntry(:key, :value) in run.hyperparameters.entries) {
    final name = key.toLowerCase();
    if (name == 'dataset' || name.endsWith('.dataset')) return value;
  }
  return null;
}

/// The `PDE` hyperparameter (as `modelsapp.init(pde=...)` sets it, any
/// case, possibly nested), if the run logged one.
String? pdeOf(Run run) {
  for (final MapEntry(:key, :value) in run.hyperparameters.entries) {
    final name = key.toLowerCase();
    if (name == 'pde' || name.endsWith('.pde')) return value;
  }
  return null;
}

String _restLabel(RunGrouping by) => switch (by) {
  RunGrouping.project => 'No project',
  RunGrouping.model => 'Model not logged',
  RunGrouping.dataset => 'No dataset logged',
  RunGrouping.pde => 'No PDE logged',
  RunGrouping.tag => 'No tags',
  RunGrouping.host => 'Unknown host',
  RunGrouping.none => '',
};
