import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/settings_store.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../models/run_insights.dart';
import '../../shared/formatters.dart';

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

/// The `PDE` hyperparameter (as `soliton.init(pde=...)` sets it, any
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

/// What the runs list is ordered by, saved on the device: newest first, or
/// a metric, best first. With a grouping, runs are ranked within each group,
/// which makes each group a small leaderboard.
enum RunOrder {
  newest('Newest first', 'Newest', null),
  valLoss('Validation loss', 'Val. loss', MetricKeys.valLoss),
  relL2('Relative L2 error', 'Rel. L2', MetricKeys.relL2),
  valAccuracy('Validation accuracy', 'Accuracy', MetricKeys.valAccuracy, lowerIsBetter: false),
  trainLoss('Train loss', 'Train loss', MetricKeys.trainLoss);

  const RunOrder(this.label, this.shortLabel, this.metric, {this.lowerIsBetter = true});

  final String label;

  /// For a column header, e.g. "Val. loss".
  final String shortLabel;

  /// The logged metric, e.g. `val/loss`; null for [newest].
  final String? metric;

  /// Then a run's best (lowest) value counts; else its latest, as on the
  /// Sweep screen.
  final bool lowerIsBetter;

  /// [value] as it reads in a card: accuracy as a percentage.
  String format(double value) => this == valAccuracy ? formatPercent(value) : formatMetric(value);
}

final runOrderProvider = NotifierProvider<Setting<RunOrder>, RunOrder>(
  () => Setting.choice('runsOrderBy', RunOrder.newest, RunOrder.values),
);

/// A run's place in a list ordered by [order], for its card.
typedef RunRanking = ({RunOrder order, RunScore score});

/// Where a run stands when the list is ordered by a metric.
class RunScore {
  const RunScore({required this.rank, required this.value});

  /// 1 for the best run; null when it isn't ranked (it crashed, or never
  /// logged the metric).
  final int? rank;

  /// Its value of the metric, if it logged one.
  final double? value;

  bool get best => rank == 1;
}

/// [runs] best first by [order]'s metric, with each one's [RunScore]. Runs
/// that crashed or have no finite value aren't ranked: they come last, in
/// the order given. Ties keep the order given. [logged] is the latest
/// metrics by run (`latestMetricsProvider`).
List<(Run, RunScore)> rankRuns(
  List<Run> runs,
  RunOrder order,
  Map<String, Map<String, LatestMetric>> logged,
) {
  final metric = order.metric;
  if (metric == null) {
    return [for (final run in runs) (run, const RunScore(rank: null, value: null))];
  }
  double? valueOf(Run run) {
    final m = logged[run.id]?[metric];
    final v = m == null ? null : (order.lowerIsBetter ? (m.min ?? m.latest) : m.latest);
    return v != null && v.isFinite ? v : null;
  }

  final ranked = <(Run, double)>[];
  final rest = <(Run, RunScore)>[];
  for (final run in runs) {
    final value = valueOf(run);
    if (value == null || run.status == RunStatus.crashed) {
      rest.add((run, RunScore(rank: null, value: value)));
    } else {
      ranked.add((run, value));
    }
  }
  // A stable sort: `List.sort` isn't, so sort indices and break ties by them.
  final order0 = [for (var i = 0; i < ranked.length; i++) i]
    ..sort((a, b) {
      final c = order.lowerIsBetter
          ? ranked[a].$2.compareTo(ranked[b].$2)
          : ranked[b].$2.compareTo(ranked[a].$2);
      return c != 0 ? c : a.compareTo(b);
    });
  return [
    for (final (place, i) in order0.indexed)
      (ranked[i].$1, RunScore(rank: place + 1, value: ranked[i].$2)),
    ...rest,
  ];
}
