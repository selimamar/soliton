import 'dart:math' as math;

import '../../models/metric_series.dart';
import '../../models/system_info.dart';
import '../../shared/formatters.dart';

/// The `system/...` series of a run (see [MetricKeys.isSystem]), sorted
/// out by GPU.
class SystemUsage {
  const SystemUsage({required this.gpus, this.cpu, this.memory, this.memoryGb});

  /// Picks the system series out of all of a run's metrics.
  factory SystemUsage.from(Map<String, MetricSeries> metrics) {
    final gpus = <int, Map<String, MetricSeries>>{};
    for (final MapEntry(:key, :value) in metrics.entries) {
      if (_gpuName.firstMatch(key) case final match?) {
        (gpus[int.parse(match[1]!)] ??= {})[match[2]!] = value;
      }
    }
    return SystemUsage(
      gpus: Map.fromEntries(gpus.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      cpu: metrics[MetricKeys.cpu],
      memory: metrics[MetricKeys.memory],
      memoryGb: metrics[MetricKeys.memoryGb],
    );
  }

  static final _gpuName = RegExp(r'^system/gpu\.(\d+)\.([a-z_]+)$');

  /// GPU index → field (`utilization`, `memory`, `memory_gb`,
  /// `temperature`, `power`) → series, in GPU order.
  final Map<int, Map<String, MetricSeries>> gpus;

  /// CPU, as a percentage of the cores the job may use.
  final MetricSeries? cpu;

  /// Memory, as a percentage of what the job may use; and in GB.
  final MetricSeries? memory;
  final MetricSeries? memoryGb;

  bool get isEmpty => gpus.isEmpty && cpu == null && memory == null && memoryGb == null;

  /// One series per GPU that logged [field], by GPU index.
  Map<int, MetricSeries> gpuSeries(String field) => {
    for (final MapEntry(:key, :value) in gpus.entries) key: ?value[field],
  };

  /// The mean of each GPU's latest value of [field], or null.
  double? latestGpuMean(String field) {
    final values = [
      for (final series in gpuSeries(field).values)
        if (series.latest case final v? when v.isFinite) v,
    ];
    return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
  }

  /// The sum of each GPU's latest value of [field], or null.
  double? latestGpuSum(String field) {
    final values = [
      for (final series in gpuSeries(field).values)
        if (series.latest case final v? when v.isFinite) v,
    ];
    return values.isEmpty ? null : values.reduce((a, b) => a + b);
  }
}

/// The machine as label/value rows, most useful first.
List<(String, String)> describeSystem(SystemInfo info) {
  final slurm = info.slurm;
  final software = [
    if (info.python case final v?) 'Python $v',
    if (info.torch case final v?) 'PyTorch $v',
    if (info.cuda case final v?) 'CUDA $v',
    if (info.cudnn case final v?) 'cuDNN $v',
  ];
  return [
    if (info.gpus.isNotEmpty) (info.gpus.length == 1 ? 'GPU' : 'GPUs', describeGpus(info.gpus)),
    if (info.gpuDriver case final v?) ('GPU driver', v),
    if (info.cpu != null || info.cpuCores != null)
      (
        'CPU',
        [?info.cpu, if (info.cpuCores case final n?) n == 1 ? '1 core' : '$n cores'].join(' · '),
      ),
    if (info.memoryGb case final v?) ('Memory', formatCapacity(v)),
    if (software.isNotEmpty) ('Software', software.join(' · ')),
    if (info.os case final v?) ('OS', v),
    if (info.hostname case final v?) ('Machine', v),
    if (slurm['jobId'] case final id?) ('Slurm job', [id, ?slurm['jobName']].join(' · ')),
    if (slurm['arrayJobId'] case final array?)
      ('Array task', '${array}_${slurm['arrayTaskId'] ?? '?'}'),
    if (slurm['partition'] case final v?) ('Partition', v),
    if (slurm['cluster'] case final v?) ('Cluster', v),
  ];
}

/// "1 × NVIDIA A100-SXM4-80GB (80 GB)", "4 × NVIDIA A10G (24 GB)", or each
/// kind in turn when they differ.
String describeGpus(List<GpuInfo> gpus) {
  final counts = <String, int>{};
  final memory = <String, double>{};
  for (final gpu in gpus) {
    counts[gpu.name] = (counts[gpu.name] ?? 0) + 1;
    memory[gpu.name] = math.max(memory[gpu.name] ?? 0, gpu.memoryGb);
  }
  return [
    for (final MapEntry(key: name, value: count) in counts.entries)
      '$count × $name${memory[name]! > 0 ? ' (${formatCapacity(memory[name]!)})' : ''}',
  ].join(', ');
}

/// A size, e.g. of a GPU's memory: 80.0 -> "80 GB", 39.4 -> "39.4 GB".
String formatCapacity(double value) =>
    value == value.roundToDouble() ? '${formatInt(value.round())} GB' : formatGb(value);
