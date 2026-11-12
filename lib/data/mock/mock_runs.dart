import 'dart:math' as math;

import '../../models/layer_info.dart';
import '../../models/layer_stats.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import 'curve_generator.dart';
import 'mock_architectures.dart';

/// Everything the mock repository knows about one run.
class MockRun {
  const MockRun({required this.run, required this.metrics, required this.layerStats});

  final Run run;
  final Map<String, MetricSeries> metrics;
  final List<LayerStats> layerStats;
}

/// The four demo runs: two live, one crashed, one finished.
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
    hyperparameters: const {
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
    hyperparameters: const {
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
    hyperparameters: const {
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
    hyperparameters: const {
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
  required Map<String, String> hyperparameters,
  required double initialLoss,
  required double finalLoss,
  double? finalAccuracy,
  required double peakLearningRate,
  String? statusMessage,
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
    'system/gpu_memory_gb': curves.approach(
      'system/gpu_memory_gb',
      start: 18,
      end: 21,
      rate: 40,
      noise: 0.2,
    ),
  };

  final statLayers = _layersForStats(architecture);
  final layerStats = [
    for (final (i, layer) in statLayers.indexed)
      curves.layer(layer.name, depth: i / math.max(1, statLayers.length - 1), crashed: crashed),
  ];

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
    lossPreview: [for (final p in trainLoss.downsampled(40).points) p.value],
    statusMessage: statusMessage,
  );

  return MockRun(run: run, metrics: metrics, layerStats: layerStats);
}

/// The layers we pretend to log statistics for: the model's top-level
/// modules, with `ModuleList`s (e.g. transformer blocks) expanded.
List<LayerInfo> _layersForStats(LayerInfo root) => [
  for (final child in root.children)
    if (child.type == 'ModuleList') ...child.children else child,
];
