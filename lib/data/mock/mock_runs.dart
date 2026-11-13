import 'dart:math' as math;

import '../../models/layer_info.dart';
import '../../models/layer_stats.dart';
import '../../models/metric_series.dart';
import '../../models/model_flow.dart';
import '../../models/run.dart';
import '../../models/run_insights.dart';
import '../../models/system_info.dart';
import 'curve_generator.dart';
import 'mock_architectures.dart';
import 'mock_fields.dart';
import 'mock_flows.dart';

/// Everything the mock repository knows about one run.
class MockRun {
  const MockRun({
    required this.run,
    required this.metrics,
    required this.layerStats,
    this.fields = const [],
    this.extras,
  });

  final Run run;
  final Map<String, MetricSeries> metrics;
  final List<LayerStats> layerStats;

  /// Field snapshots (for the neural operator runs).
  final List<MockField> fields;

  /// Validation sets and curves (for the neural operator runs).
  final MockExtras? extras;

  List<LoggedSeries<EvalStep>> get evals => extras?.evals ?? const [];
  List<LoggedSeries<CurveStep>> get curves => extras?.curves ?? const [];
}

/// The demo runs: four live, one crashed, and five finished (four of them a
/// small sweep over an FNO's modes and width).
List<MockRun> buildMockRuns(DateTime now) => [
  _buildRun(
    id: 'resnet50-cifar',
    project: 'image-classification',
    host: 'Sherlock',
    status: RunStatus.live,
    startedAt: now.subtract(const Duration(hours: 3, minutes: 12)),
    currentStep: 8232,
    totalSteps: 19600,
    totalEpochs: 100,
    architecture: resnet50Cifar(),
    flow: resnet50CifarFlow(),
    system: const SystemInfo(
      hostname: 'sh03-12n07.int',
      os: 'Rocky Linux 8.10 (Linux 4.18.0)',
      python: '3.12.4',
      cpu: 'AMD EPYC 7543 32-Core Processor',
      cpuCores: 16,
      memoryGb: 64,
      gpus: [GpuInfo(name: 'NVIDIA A100-SXM4-80GB', memoryGb: 80)],
      gpuDriver: '550.54.15',
      torch: '2.5.1',
      cuda: '12.4',
      cudnn: '9.1.0',
      slurm: {
        'jobId': '52091377',
        'jobName': 'resnet50-cifar',
        'partition': 'gpu',
        'nodes': 'sh03-12n07',
        'cluster': 'sherlock',
      },
    ),
    hyperparameters: const {
      'Training samples': '50,000',
      'Validation samples': '10,000',
      'Loss': 'CrossEntropyLoss(label_smoothing=0.1)',
      'Optimizer': 'AdamW',
      'Learning rate': '3e-4 (cosine)',
      'Batch size': '256',
      'Weight decay': '0.05',
      'Precision': 'bf16',
      'Dataset': 'CIFAR-10',
    },
    initialLoss: 2.3,
    finalLoss: 0.25,
    finalAccuracy: 0.93,
    peakLearningRate: 3e-4,
    seed: 1,
  ),
  _buildRun(
    id: 'gpt-tiny',
    project: 'language-models',
    host: 'AWS',
    status: RunStatus.live,
    startedAt: now.subtract(const Duration(hours: 9, minutes: 40)),
    currentStep: 18000,
    totalSteps: 50000,
    totalEpochs: 3,
    architecture: gptTiny(),
    flow: gptTinyFlow(),
    system: const SystemInfo(
      hostname: 'ip-172-31-8-41',
      os: 'Ubuntu 22.04.4 LTS (Linux 6.5.0)',
      python: '3.11.9',
      cpu: 'AMD EPYC 7R32',
      cpuCores: 48,
      memoryGb: 192,
      gpus: [
        GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
        GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
        GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
        GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
      ],
      gpuDriver: '550.90.07',
      torch: '2.5.1',
      cuda: '12.4',
      cudnn: '9.1.0',
    ),
    hyperparameters: const {
      'Training samples': '8,013,769',
      'Validation samples': '4,007',
      'Loss': 'cross_entropy',
      'Optimizer': 'AdamW (β₂ = 0.95)',
      'Learning rate': '6e-4 (cosine)',
      'Batch size': '64 × 1024 tokens',
      'Weight decay': '0.1',
      'Gradient clipping': '1.0',
      'Dataset': 'OpenWebText',
    },
    initialLoss: 10.8,
    finalLoss: 2.6,
    peakLearningRate: 6e-4,
    seed: 2,
  ),
  _buildRun(
    id: 'unet-seg',
    project: 'segmentation',
    host: 'Sherlock',
    status: RunStatus.crashed,
    startedAt: now.subtract(const Duration(hours: 5)),
    endedAt: now.subtract(const Duration(hours: 4, minutes: 18)),
    currentStep: 3412,
    totalSteps: 30000,
    totalEpochs: 60,
    architecture: unet(),
    flow: unetFlow(),
    system: const SystemInfo(
      hostname: 'sh02-14n03.int',
      os: 'Rocky Linux 8.10 (Linux 4.18.0)',
      python: '3.12.4',
      cpu: 'Intel(R) Xeon(R) Gold 5118 CPU @ 2.30GHz',
      cpuCores: 10,
      memoryGb: 48,
      gpus: [GpuInfo(name: 'Tesla V100-SXM2-32GB', memoryGb: 32)],
      gpuDriver: '550.54.15',
      torch: '2.4.1',
      cuda: '12.1',
      cudnn: '9.1.0',
      slurm: {
        'jobId': '52077120',
        'jobName': 'unet-seg',
        'partition': 'owners',
        'nodes': 'sh02-14n03',
        'cluster': 'sherlock',
      },
    ),
    hyperparameters: const {
      'Training samples': '4,580',
      'Validation samples': '508',
      'Loss': 'CrossEntropyLoss + Dice',
      'Optimizer': 'SGD (momentum 0.9)',
      'Learning rate': '0.1 (cosine)',
      'Batch size': '16',
      'Weight decay': '1e-4',
      'Dataset': 'Carvana',
    },
    initialLoss: 0.9,
    finalLoss: 0.08,
    peakLearningRate: 0.1,
    statusMessage:
        'Loss became NaN at step 3,412. '
        'The learning rate may be too high.',
    seed: 3,
  ),
  _buildRun(
    id: 'fno-navier-stokes',
    project: 'neural-operators',
    host: 'Sherlock',
    status: RunStatus.live,
    startedAt: now.subtract(const Duration(hours: 1, minutes: 47)),
    currentStep: 7000,
    totalSteps: 20000,
    totalEpochs: 400,
    architecture: fno2d(),
    system: const SystemInfo(
      hostname: 'sh04-01n05.int',
      os: 'Rocky Linux 8.10 (Linux 4.18.0)',
      python: '3.12.4',
      cpu: 'AMD EPYC 9124 16-Core Processor',
      cpuCores: 8,
      memoryGb: 32,
      gpus: [GpuInfo(name: 'NVIDIA L40S', memoryGb: 48)],
      gpuDriver: '550.54.15',
      torch: '2.5.1',
      cuda: '12.4',
      cudnn: '9.1.0',
      slurm: {
        'jobId': '52094410',
        'jobName': 'fno-ns',
        'partition': 'gpu',
        'nodes': 'sh04-01n05',
        'cluster': 'sherlock',
      },
    ),
    hyperparameters: const {
      'Training samples': '1,000',
      'Validation samples': '200',
      'Loss': 'LpLoss (relative L2)',
      'PDE': 'Navier–Stokes 2D, vorticity form',
      'Viscosity': '1e-3',
      'Resolution': '64 × 64',
      'Fourier modes': '12 × 12',
      'Width': '32',
      'Optimizer': 'Adam',
      'Learning rate': '1e-3 (step, ×0.5 every 100 epochs)',
      'Batch size': '20',
      'Dataset': 'Navier–Stokes 2D (FNO benchmark)',
    },
    initialLoss: 0.95,
    finalLoss: 0.012,
    peakLearningRate: 1e-3,
    fields: (current, total, seed) =>
        navierStokesFields(currentStep: current, totalSteps: total, every: 500, seed: seed),
    extras: (curves, fields, current, total, seed) => navierStokesExtras(
      curves: curves,
      fields: fields,
      currentStep: current,
      totalSteps: total,
      every: 500,
      seed: seed,
    ),
    seed: 5,
  ),
  _buildRun(
    id: 'fno3d-turbulence',
    project: 'neural-operators',
    host: 'Sherlock',
    status: RunStatus.live,
    startedAt: now.subtract(const Duration(hours: 4, minutes: 5)),
    currentStep: 4000,
    totalSteps: 12000,
    totalEpochs: 120,
    architecture: fno3d(),
    system: const SystemInfo(
      hostname: 'sh04-02n11.int',
      os: 'Rocky Linux 8.10 (Linux 4.18.0)',
      python: '3.12.4',
      cpu: 'AMD EPYC 9124 16-Core Processor',
      cpuCores: 16,
      memoryGb: 128,
      gpus: [GpuInfo(name: 'NVIDIA H100 80GB HBM3', memoryGb: 80)],
      gpuDriver: '550.54.15',
      torch: '2.5.1',
      cuda: '12.4',
      cudnn: '9.1.0',
      slurm: {
        'jobId': '52095102',
        'jobName': 'fno3d',
        'partition': 'gpu',
        'nodes': 'sh04-02n11',
        'cluster': 'sherlock',
      },
    ),
    hyperparameters: const {
      'Training samples': '800',
      'Validation samples': '100',
      'Loss': 'LpLoss (relative L2)',
      'PDE': 'Navier–Stokes 3D, periodic box',
      'Resolution': '64 × 64 × 64',
      'Fourier modes': '8 × 8 × 8',
      'Width': '20',
      'Optimizer': 'Adam',
      'Learning rate': '1e-3 (cosine)',
      'Batch size': '4',
      'Dataset': 'Navier–Stokes 3D (synthetic)',
    },
    initialLoss: 0.98,
    finalLoss: 0.03,
    peakLearningRate: 1e-3,
    fields: (current, total, seed) =>
        turbulence3dFields(currentStep: current, totalSteps: total, every: 500, seed: seed),
    extras: (curves, fields, current, total, seed) => turbulence3dExtras(
      curves: curves,
      fields: fields,
      currentStep: current,
      totalSteps: total,
      every: 500,
      seed: seed,
    ),
    seed: 6,
  ),
  _buildRun(
    id: 'vit-small',
    project: 'image-classification',
    host: 'GCP',
    status: RunStatus.finished,
    startedAt: now.subtract(const Duration(days: 2, hours: 14)),
    endedAt: now.subtract(const Duration(days: 2)),
    currentStep: 39000,
    totalSteps: 39000,
    totalEpochs: 200,
    architecture: vitSmall(),
    flow: vitSmallFlow(),
    system: const SystemInfo(
      hostname: 'vit-train-l4-1',
      os: 'Debian GNU/Linux 12 (bookworm) (Linux 6.1.0)',
      python: '3.11.9',
      cpu: 'Intel(R) Xeon(R) CPU @ 2.20GHz',
      cpuCores: 8,
      memoryGb: 32,
      gpus: [GpuInfo(name: 'NVIDIA L4', memoryGb: 24)],
      gpuDriver: '550.90.07',
      torch: '2.5.1',
      cuda: '12.4',
      cudnn: '9.1.0',
    ),
    hyperparameters: const {
      'Training samples': '50,000',
      'Validation samples': '10,000',
      'Loss': 'SoftTargetCrossEntropy',
      'Optimizer': 'AdamW',
      'Learning rate': '1e-3 (cosine)',
      'Batch size': '512',
      'Weight decay': '0.05',
      'Augmentation': 'RandAugment + Mixup',
      'Dataset': 'CIFAR-10',
    },
    initialLoss: 2.3,
    finalLoss: 0.35,
    finalAccuracy: 0.913,
    peakLearningRate: 1e-3,
    seed: 4,
  ),
  ..._sweepRuns(now),
];

MockRun _buildRun({
  required String id,
  required String project,
  required String host,
  required RunStatus status,
  required DateTime startedAt,
  DateTime? endedAt,
  required int currentStep,
  required int totalSteps,
  required int totalEpochs,
  required LayerInfo architecture,
  ModelFlow? flow,
  SystemInfo? system,
  required Map<String, String> hyperparameters,
  required double initialLoss,
  required double finalLoss,
  double? finalAccuracy,
  required double peakLearningRate,
  String? statusMessage,
  List<String> tags = const [],
  List<MockField> Function(int currentStep, int totalSteps, int seed)? fields,
  MockExtras Function(
    CurveGenerator curves,
    List<MockField> fields,
    int currentStep,
    int totalSteps,
    int seed,
  )?
  extras,
  required int seed,
}) {
  final crashed = status == RunStatus.crashed;
  final logEvery = math.max(1, totalSteps ~/ 400);
  final evalEvery = logEvery * 10;
  final curves = CurveGenerator(
    seed: seed,
    currentStep: currentStep,
    totalSteps: totalSteps,
    every: logEvery,
  );

  var trainLoss = curves.decay(MetricKeys.trainLoss, start: initialLoss, end: finalLoss);
  var gradNorm = curves.spiky(MetricKeys.gradNorm, start: 4, end: 0.8);
  if (crashed) {
    trainLoss = curves.diverge(trainLoss);
    gradNorm = curves.diverge(gradNorm);
  }

  final metrics = <String, MetricSeries>{
    MetricKeys.trainLoss: trainLoss,
    MetricKeys.valLoss: curves.decay(
      MetricKeys.valLoss,
      start: initialLoss,
      end: finalLoss * 1.15,
      noise: 0.02,
      interval: evalEvery,
    ),
    if (finalAccuracy != null)
      MetricKeys.valAccuracy: curves.approach(
        MetricKeys.valAccuracy,
        start: 0.1,
        end: finalAccuracy,
        interval: evalEvery,
      ),
    MetricKeys.learningRate: curves.cosineSchedule(
      MetricKeys.learningRate,
      peak: peakLearningRate,
      warmupSteps: totalSteps ~/ 20,
    ),
    MetricKeys.gradNorm: gradNorm,
    // A metric without a dedicated chart, to exercise "Other metrics".
    'train/tokens_per_second': curves.approach(
      'train/tokens_per_second',
      start: 9000,
      end: 11500,
      rate: 40,
      noise: 300,
    ),
    if (system != null) ..._systemMetrics(curves, system),
  };

  final statLayers = _layersForStats(architecture);
  final layerStats = [
    for (final (i, layer) in statLayers.indexed)
      curves.layer(layer.name, depth: i / math.max(1, statLayers.length - 1), crashed: crashed),
  ];

  final runFields = fields?.call(currentStep, totalSteps, seed) ?? const <MockField>[];
  final runExtras = extras?.call(curves, runFields, currentStep, totalSteps, seed);

  final run = Run(
    id: id,
    name: id,
    project: project,
    host: host,
    status: status,
    startedAt: startedAt,
    endedAt: endedAt,
    currentStep: currentStep,
    totalSteps: totalSteps,
    currentEpoch: (currentStep / totalSteps * totalEpochs).floor(),
    totalEpochs: totalEpochs,
    hyperparameters: hyperparameters,
    architecture: architecture,
    flow: flow,
    system: system,
    lossPreview: [for (final p in trainLoss.downsampled(40).points) p.value],
    statusMessage: statusMessage,
    tags: tags,
  );

  return MockRun(
    run: run,
    metrics: {...metrics, ...?runExtras?.metrics},
    layerStats: layerStats,
    fields: [...runFields, ...?runExtras?.fields],
    extras: runExtras,
  );
}

/// A small sweep over an FNO's Fourier modes and width on the 2D
/// Navier–Stokes problem: finished runs with only what a sweep compares.
List<MockRun> _sweepRuns(DateTime now) => [
  for (final (i, (modes, width)) in const [(8, 32), (8, 64), (16, 32), (16, 64)].indexed)
    _buildRun(
      id: 'fno-ns-m$modes-w$width',
      project: 'neural-operators',
      host: 'Sherlock',
      status: RunStatus.finished,
      startedAt: now.subtract(Duration(days: 1, hours: 6 - i)),
      endedAt: now.subtract(Duration(hours: 20 - 2 * i)),
      currentStep: 6000,
      totalSteps: 6000,
      totalEpochs: 120,
      architecture: fno2d(),
      hyperparameters: {
        'Training samples': '1,000',
        'Validation samples': '200',
        'Loss': 'LpLoss (relative L2)',
        'PDE': 'Navier–Stokes 2D, vorticity form',
        'PDE viscosity': '1e-3',
        'Fourier modes': '$modes × $modes',
        'Width': '$width',
        'Optimizer': 'Adam',
        'Dataset': 'Navier–Stokes 2D (FNO benchmark)',
      },
      tags: const ['sweep'],
      initialLoss: 0.95,
      finalLoss: 0.02 * (12 / modes) * (32 / width),
      peakLearningRate: 1e-3,
      extras: (curves, _, _, _, _) => sweepExtras(curves: curves, modes: modes, width: width),
      seed: 20 + i,
    ),
];

/// What the logger's system monitor would have sampled on [system]: GPUs
/// kept busy, memory filling up early, then steady.
Map<String, MetricSeries> _systemMetrics(CurveGenerator curves, SystemInfo system) {
  final series = <String, MetricSeries>{};
  void add(String name, MetricSeries values, {double low = 0, double high = double.infinity}) {
    series[name] = MetricSeries(
      name: name,
      points: [for (final p in values.points) MetricPoint(p.step, p.value.clamp(low, high))],
    );
  }

  for (final (i, gpu) in system.gpus.indexed) {
    final memory = curves.approach('', start: 1, end: gpu.memoryGb * 0.78, rate: 120, noise: 0.15);
    add(
      MetricKeys.gpu(i, 'utilization'),
      curves.approach('', start: 5, end: 94 - 2.0 * i, rate: 80, noise: 4),
      high: 100,
    );
    add(MetricKeys.gpu(i, 'memory_gb'), memory, high: gpu.memoryGb);
    add(
      MetricKeys.gpu(i, 'memory'),
      MetricSeries(
        name: '',
        points: [for (final p in memory.points) MetricPoint(p.step, 100 * p.value / gpu.memoryGb)],
      ),
      high: 100,
    );
    add(
      MetricKeys.gpu(i, 'temperature'),
      curves.approach('', start: 34, end: 70 + 1.0 * i, rate: 25, noise: 1.2),
    );
    add(MetricKeys.gpu(i, 'power'), curves.approach('', start: 60, end: 240, rate: 60, noise: 18));
  }
  add(MetricKeys.cpu, curves.approach('', start: 12, end: 41, rate: 50, noise: 5), high: 100);
  final ram = system.memoryGb ?? 32;
  final used = curves.approach('', start: 2.5, end: ram * 0.3, rate: 60, noise: 0.15);
  add(MetricKeys.memoryGb, used, high: ram);
  add(
    MetricKeys.memory,
    MetricSeries(
      name: '',
      points: [for (final p in used.points) MetricPoint(p.step, 100 * p.value / ram)],
    ),
    high: 100,
  );
  return series;
}

/// The layers we pretend to log statistics for: the model's top-level
/// modules, with `ModuleList`s (e.g. transformer blocks) expanded.
List<LayerInfo> _layersForStats(LayerInfo root) => [
  for (final child in root.children)
    if (child.type == 'ModuleList') ...child.children else child,
];
