import 'layer_info.dart';
import 'model_flow.dart';
import 'model_helpers.dart';
import 'system_info.dart';

enum RunStatus { live, finished, crashed }

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
    required this.totalSteps,
    required this.currentEpoch,
    required this.totalEpochs,
    required this.hyperparameters,
    required this.architecture,
    required this.lossPreview,
    this.flow,
    this.endedAt,
    this.statusMessage,
    this.tags = const [],
    this.notes = '',
    this.system,
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
    // Older servers don't send these.
    tags: List.unmodifiable([for (final tag in (json['tags'] as List?) ?? const []) tag as String]),
    notes: json['notes'] as String? ?? '',
    system: switch (json['system']) {
      final Map<String, Object?> system => SystemInfo.fromJson(system),
      _ => null,
    },
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

  /// Labels to organise runs by, e.g. `baseline`; edited in the app.
  final List<String> tags;

  /// Free text left on the run, e.g. what was tried; edited in the app.
  final String notes;

  /// The machine, GPUs, software and Slurm job it trains on; null if the
  /// logger didn't say (an older logger).
  final SystemInfo? system;

  int get parameterCount => architecture.totalParameters;

  double? get latestLoss => lossPreview.isEmpty ? null : lossPreview.last;

  double get progress =>
      totalSteps == 0 ? 0 : (currentStep / totalSteps).clamp(0.0, 1.0).toDouble();

  /// Time the run has been going, as of [now] (or until it ended).
  ///
  /// [now] is passed in (see `clockProvider`) so the value can keep moving
  /// on screen, and so tests can use a fixed time.
  Duration elapsedAt(DateTime now) => (endedAt ?? now).difference(startedAt);

  /// Naive estimate assuming a constant time per step. Null if not live.
  Duration? estimatedRemainingAt(DateTime now) {
    if (status != RunStatus.live || currentStep == 0) return null;
    if (currentStep >= totalSteps) return Duration.zero;
    final msPerStep = elapsedAt(now).inMilliseconds / currentStep;
    return Duration(milliseconds: (msPerStep * (totalSteps - currentStep)).round());
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'project': project,
    'host': host,
    'status': status.name,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'currentStep': currentStep,
    'totalSteps': totalSteps,
    'currentEpoch': currentEpoch,
    'totalEpochs': totalEpochs,
    'hyperparameters': hyperparameters,
    'architecture': {...architecture.toJson(), ...?flow?.toArchitectureJson()},
    'lossPreview': [for (final v in lossPreview) encodeDouble(v)],
    'statusMessage': statusMessage,
    'tags': tags,
    'notes': notes,
    'system': system?.toJson(),
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
      other.totalSteps == totalSteps &&
      other.currentEpoch == currentEpoch &&
      other.totalEpochs == totalEpochs &&
      deepMapEquals(other.hyperparameters, hyperparameters) &&
      other.architecture == architecture &&
      other.flow == flow &&
      sameDoubles(other.lossPreview, lossPreview) &&
      other.statusMessage == statusMessage &&
      deepListEquals(other.tags, tags) &&
      other.notes == notes &&
      other.system == system;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    project,
    host,
    status,
    startedAt,
    endedAt,
    currentStep,
    totalSteps,
    currentEpoch,
    totalEpochs,
    // Unordered, to match the order-insensitive map comparison above.
    Object.hashAllUnordered(hyperparameters.entries.map((e) => Object.hash(e.key, e.value))),
    architecture,
    flow,
    Object.hashAll(lossPreview.map(doubleHash)),
    statusMessage,
    Object.hashAll(tags),
    notes,
    system,
  );
}
