import 'health_warning.dart';
import 'layer_info.dart';
import 'model_flow.dart';
import 'model_helpers.dart';
import 'run_job.dart';
import 'simulation_info.dart';
import 'system_info.dart';

/// [queued]: a Slurm job still waiting to start (from `soliton sbatch`).
enum RunStatus { queued, live, finished, crashed }

/// A training run: what is shown in the runs list and in the Overview tab.
///
/// Time series (loss curves, layer statistics) are fetched separately, so
/// the runs list stays light.
class Run {
  /// Pass unmodifiable (e.g. `const`) collections: a run never changes.
  const Run({
    required this.id,
    required this.name,
    required this.project,
    required this.host,
    required this.status,
    required this.startedAt,
    required this.currentStep,
    this.resumedAtStep = 0,
    required this.totalSteps,
    required this.currentEpoch,
    required this.totalEpochs,
    required this.hyperparameters,
    required this.architecture,
    required this.lossPreview,
    this.flow,
    this.endedAt,
    this.statusMessage,
    this.stopRequestedAt,
    this.jobs = const [],
    this.health = const [],
    this.thinnedAt,
    this.thinnedTo,
    this.tags = const [],
    this.notes = '',
    this.system,
    this.simulation,
    this.datasets = const [],
  });

  factory Run.fromJson(Map<String, Object?> json) => Run(
    id: json['id']! as String,
    name: json['name']! as String,
    project: json['project']! as String,
    host: json['host']! as String,
    status: RunStatus.values.byName(json['status']! as String),
    startedAt: DateTime.parse(json['startedAt']! as String),
    endedAt: switch (json['endedAt']) {
      final String s => DateTime.parse(s),
      _ => null,
    },
    currentStep: (json['currentStep']! as num).toInt(),
    resumedAtStep: (json['resumedAtStep'] as num?)?.toInt() ?? 0, // Older servers don't send it.
    totalSteps: (json['totalSteps']! as num).toInt(),
    currentEpoch: (json['currentEpoch']! as num).toInt(),
    totalEpochs: (json['totalEpochs']! as num).toInt(),
    hyperparameters: Map.unmodifiable(
      (json['hyperparameters']! as Map).map((k, v) => MapEntry(k as String, v as String)),
    ),
    architecture: LayerInfo.fromJson(json['architecture']! as Map<String, Object?>),
    flow: ModelFlow.fromArchitectureJson(json['architecture']! as Map<String, Object?>),
    lossPreview: List.unmodifiable([for (final v in json['lossPreview']! as List) decodeDouble(v)]),
    statusMessage: json['statusMessage'] as String?,
    stopRequestedAt: switch (json['stopRequestedAt']) {
      final String s => DateTime.parse(s),
      _ => null,
    },
    // Older servers don't send it.
    jobs: List.unmodifiable([
      for (final job in (json['jobs'] as List?) ?? const [])
        RunJob.fromJson(job as Map<String, Object?>),
    ]),
    thinnedAt: switch (json['thinnedAt']) {
      final String s => DateTime.tryParse(s),
      _ => null,
    },
    thinnedTo: (json['thinnedTo'] as num?)?.toInt(),
    // Older servers don't send it.
    health: List.unmodifiable([
      for (final warning in (json['health'] as List?) ?? const [])
        ?HealthWarning.fromJson(warning as Map<String, Object?>),
    ]),
    // Older servers don't send these.
    tags: List.unmodifiable([for (final tag in (json['tags'] as List?) ?? const []) tag as String]),
    notes: json['notes'] as String? ?? '',
    system: switch (json['system']) {
      final Map<String, Object?> system => SystemInfo.fromJson(system),
      _ => null,
    },
    simulation: switch (json['simulation']) {
      final Map<String, Object?> simulation => SimulationInfo.fromJson(simulation),
      _ => null,
    },
    datasets: List.unmodifiable([
      for (final id in (json['datasets'] as List?) ?? const []) id as String,
    ]),
  );

  final String id;
  final String name;
  final String project;

  /// Where the job runs, e.g. `Sherlock`, `AWS`, `GCP`.
  final String host;

  final RunStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;

  final int currentStep;

  /// Where its latest process took over (a job continuing it from a
  /// checkpoint): its pace counts from here. 0 for a run that started there.
  final int resumedAtStep;

  final int totalSteps;
  final int currentEpoch;
  final int totalEpochs;

  /// Hyperparameters as display-ready strings, e.g. `{'Optimizer': 'AdamW'}`.
  final Map<String, String> hyperparameters;

  /// Root of the model's architecture tree.
  final LayerInfo architecture;

  /// The layers in the order they ran, for the network diagram. Null until
  /// the watched model has run once.
  final ModelFlow? flow;

  /// A short, downsampled training-loss history for the list sparkline.
  final List<double> lossPreview;

  /// Optional explanation, e.g. why the run crashed.
  final String? statusMessage;

  /// Each process (Slurm job) that ran it, in order: several for a run
  /// continued from checkpoints. Empty from an older server.
  final List<RunJob> jobs;

  /// The steps where a later job took over (marked on its charts).
  List<int> get jobStarts => [for (final job in jobs.skip(1)) job.startStep];

  /// Training problems the logger saw (a NaN loss, a diverging loss,
  /// exploding gradients), newest first. Empty from an older server.
  final List<HealthWarning> health;

  /// When it was thinned out on the server to save space (each curve keeps
  /// [thinnedTo] points, each field its latest snapshot); null if it keeps
  /// everything it logged.
  final DateTime? thinnedAt;
  final int? thinnedTo;

  /// When it was asked to stop from the app (its Stop button), while it
  /// runs; its script stops at its next `run.should_stop()` check.
  final DateTime? stopRequestedAt;

  /// Labels to organise runs by, e.g. `baseline`; edited in the app.
  final List<String> tags;

  /// Free text left on the run, e.g. what was tried; edited in the app.
  final String notes;

  /// The machine, GPUs, software and Slurm job it trains on; null if the
  /// logger didn't say (an older logger).
  final SystemInfo? system;

  /// Set for a simulation (shown under Compute) rather than a training run.
  final SimulationInfo? simulation;

  bool get isSimulation => simulation != null;

  /// The ids of the datasets it trains or is evaluated on.
  final List<String> datasets;

  int get parameterCount => architecture.totalParameters;

  double? get latestLoss => lossPreview.isEmpty ? null : lossPreview.last;

  /// How the training loss moved over the last tenth of [lossPreview]
  /// (negative: falling). Null when that is too short to tell, not finite,
  /// or under 0.1% of the loss: noise rather than a trend.
  double? get recentLossChange {
    final n = lossPreview.length;
    if (n < 2) return null;
    final latest = lossPreview[n - 1];
    final change = latest - lossPreview[n - 1 - (n ~/ 10).clamp(1, n - 1)];
    if (!change.isFinite || change.abs() < latest.abs() * 1e-3) return null;
    return change;
  }

  /// Whether it knows how far it has to go: training given `total_steps`,
  /// or a simulation with an end time or a maximum number of iterations.
  /// Only then do [progress], a progress bar and a time left mean anything.
  bool get hasEnd => (simulation?.tEnd ?? 0) > 0 || totalSteps > 0;

  /// The epoch, for labels: "42/100", "42" without a total, or null for a
  /// run that logs no epochs (show its step instead).
  String? get epochText => totalEpochs > 0
      ? '$currentEpoch/$totalEpochs'
      : currentEpoch > 0
      ? '$currentEpoch'
      : null;

  /// How far along it is (0–1): steps of [totalSteps], or a simulation's
  /// simulated time of its end time. 0 without either (see [hasEnd]).
  double get progress =>
      simulation?.timeProgress ??
      (totalSteps == 0 ? 0 : (currentStep / totalSteps).clamp(0.0, 1.0).toDouble());

  /// Time the run has been going, as of [now] (or until it ended).
  ///
  /// [now] is passed in (see `clockProvider`) so the value can keep moving
  /// on screen, and so tests can use a fixed time.
  Duration elapsedAt(DateTime now) => (endedAt ?? now).difference(startedAt);

  /// Naive estimate assuming a constant time per step (for a simulation
  /// with an end time, a constant pace of simulated time), at the pace of
  /// its latest process: from where it resumed ([resumedAtStep]), since
  /// [startedAt] is when that process started. Null if not live.
  Duration? estimatedRemainingAt(DateTime now) {
    if (status != RunStatus.live) return null;
    final elapsed = elapsedAt(now).inMilliseconds;
    if (simulation case SimulationInfo(:final tEnd?, :final time?) when tEnd > 0) {
      final done = time - (simulation!.resumedAtTime ?? 0);
      if (!time.isFinite || done <= 0) return null;
      if (time >= tEnd) return Duration.zero;
      return Duration(milliseconds: (elapsed * (tEnd - time) / done).round());
    }
    // No total steps (training without total_steps, a steady solve without
    // a maximum number of iterations): unknown.
    final done = currentStep - resumedAtStep;
    if (done <= 0 || totalSteps == 0) return null;
    if (currentStep >= totalSteps) return Duration.zero;
    return Duration(milliseconds: (elapsed / done * (totalSteps - currentStep)).round());
  }

  /// When it should finish, from [estimatedRemainingAt]. Null if not live.
  DateTime? estimatedEndAt(DateTime now) => switch (estimatedRemainingAt(now)) {
    final remaining? => now.add(remaining),
    null => null,
  };

  /// How long its Slurm job waited in the queue before it started, if the
  /// logger found out.
  Duration? get queueWait {
    final submitted = system?.submittedAt;
    if (submitted == null) return null;
    final wait = (system?.jobStartedAt ?? startedAt).difference(submitted);
    return wait.isNegative ? null : wait;
  }

  /// While it's queued: how long it has waited so far (from when it was
  /// submitted, which is also its [startedAt] until it starts).
  Duration? queuedFor(DateTime now) {
    if (status != RunStatus.queued) return null;
    final waited = now.difference(system?.submittedAt ?? startedAt);
    return waited.isNegative ? Duration.zero : waited;
  }

  /// Its Slurm time limit, while that can still stop it.
  DateTime? get liveTimeLimitAt => status == RunStatus.live ? system?.timeLimitAt : null;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'project': project,
    'host': host,
    'status': status.name,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'currentStep': currentStep,
    'resumedAtStep': resumedAtStep,
    'totalSteps': totalSteps,
    'currentEpoch': currentEpoch,
    'totalEpochs': totalEpochs,
    'hyperparameters': hyperparameters,
    'architecture': {...architecture.toJson(), ...?flow?.toArchitectureJson()},
    'lossPreview': [for (final v in lossPreview) encodeDouble(v)],
    'statusMessage': statusMessage,
    'stopRequestedAt': stopRequestedAt?.toIso8601String(),
    'jobs': [for (final job in jobs) job.toJson()],
    'health': [for (final warning in health) warning.toJson()],
    'thinnedAt': thinnedAt?.toIso8601String(),
    'thinnedTo': thinnedTo,
    'tags': tags,
    'notes': notes,
    'system': system?.toJson(),
    'simulation': simulation?.toJson(),
    'datasets': datasets,
  };

  @override
  bool operator ==(Object other) =>
      other is Run &&
      other.id == id &&
      other.name == name &&
      other.project == project &&
      other.host == host &&
      other.status == status &&
      other.startedAt == startedAt &&
      other.endedAt == endedAt &&
      other.currentStep == currentStep &&
      other.resumedAtStep == resumedAtStep &&
      other.totalSteps == totalSteps &&
      other.currentEpoch == currentEpoch &&
      other.totalEpochs == totalEpochs &&
      deepMapEquals(other.hyperparameters, hyperparameters) &&
      other.architecture == architecture &&
      other.flow == flow &&
      sameDoubles(other.lossPreview, lossPreview) &&
      other.statusMessage == statusMessage &&
      other.stopRequestedAt == stopRequestedAt &&
      deepListEquals(other.jobs, jobs) &&
      deepListEquals(other.health, health) &&
      other.thinnedAt == thinnedAt &&
      other.thinnedTo == thinnedTo &&
      deepListEquals(other.tags, tags) &&
      other.notes == notes &&
      other.system == system &&
      other.simulation == simulation &&
      deepListEquals(other.datasets, datasets);

  @override
  int get hashCode => Object.hashAll([
    id,
    name,
    project,
    host,
    status,
    startedAt,
    endedAt,
    currentStep,
    resumedAtStep,
    totalSteps,
    currentEpoch,
    totalEpochs,
    // Unordered, to match the order-insensitive map comparison above.
    Object.hashAllUnordered(hyperparameters.entries.map((e) => Object.hash(e.key, e.value))),
    architecture,
    flow,
    Object.hashAll(lossPreview.map(doubleHash)),
    statusMessage,
    stopRequestedAt,
    Object.hashAll(jobs),
    Object.hashAll(health),
    thinnedAt,
    thinnedTo,
    Object.hashAll(tags),
    notes,
    system,
    simulation,
    Object.hashAll(datasets),
  ]);
}
