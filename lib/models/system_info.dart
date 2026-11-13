import 'model_helpers.dart';

/// What a run trains on: machine, GPUs, software and Slurm job, as the
/// logger records them when the run starts. Every field is optional: what
/// the logger couldn't find out (or an older logger) is left out.
class SystemInfo {
  const SystemInfo({
    this.hostname,
    this.os,
    this.python,
    this.cpu,
    this.cpuCores,
    this.memoryGb,
    this.gpus = const [],
    this.gpuDriver,
    this.torch,
    this.cuda,
    this.cudnn,
    this.slurm = const {},
  });

  factory SystemInfo.fromJson(Map<String, Object?> json) => SystemInfo(
    hostname: json['hostname'] as String?,
    os: json['os'] as String?,
    python: json['python'] as String?,
    cpu: json['cpu'] as String?,
    cpuCores: (json['cpuCores'] as num?)?.toInt(),
    memoryGb: (json['memoryGb'] as num?)?.toDouble(),
    gpus: List.unmodifiable([
      for (final gpu in (json['gpus'] as List?) ?? const [])
        GpuInfo.fromJson(gpu as Map<String, Object?>),
    ]),
    gpuDriver: json['gpuDriver'] as String?,
    torch: json['torch'] as String?,
    cuda: json['cuda'] as String?,
    cudnn: json['cudnn'] as String?,
    slurm: Map.unmodifiable({
      for (final MapEntry(:key, :value) in ((json['slurm'] as Map?) ?? const {}).entries)
        key as String: '$value',
    }),
  );

  /// The node, e.g. `sh03-12n07.int`.
  final String? hostname;

  /// E.g. `Rocky Linux 8.10 (Linux 4.18.0)`.
  final String? os;
  final String? python;

  /// CPU model, e.g. `AMD EPYC 7543 32-Core Processor`.
  final String? cpu;

  /// Cores the job may use (its Slurm allocation), not the whole node's.
  final int? cpuCores;

  /// Memory the job may use: its Slurm limit, else the machine's RAM.
  final double? memoryGb;

  /// The job's GPUs, in CUDA's order (`gpu.0` is `cuda:0`).
  final List<GpuInfo> gpus;
  final String? gpuDriver;

  /// PyTorch, CUDA and cuDNN versions, if the script used PyTorch.
  final String? torch;
  final String? cuda;
  final String? cudnn;

  /// `jobId`, `jobName`, `partition`, `nodes`, `cluster`, `arrayJobId`,
  /// `arrayTaskId`: whichever Slurm set.
  final Map<String, String> slurm;

  /// GPU memory across all the job's GPUs, if known.
  double? get gpuMemoryGb => gpus.isEmpty || gpus.any((g) => g.memoryGb <= 0)
      ? null
      : gpus.fold<double>(0, (sum, g) => sum + g.memoryGb);

  Map<String, Object?> toJson() => {
    'hostname': ?hostname,
    'os': ?os,
    'python': ?python,
    'cpu': ?cpu,
    'cpuCores': ?cpuCores,
    'memoryGb': ?memoryGb,
    'gpus': [for (final gpu in gpus) gpu.toJson()],
    'gpuDriver': ?gpuDriver,
    'torch': ?torch,
    'cuda': ?cuda,
    'cudnn': ?cudnn,
    if (slurm.isNotEmpty) 'slurm': slurm,
  };

  @override
  bool operator ==(Object other) =>
      other is SystemInfo &&
      other.hostname == hostname &&
      other.os == os &&
      other.python == python &&
      other.cpu == cpu &&
      other.cpuCores == cpuCores &&
      other.memoryGb == memoryGb &&
      deepListEquals(other.gpus, gpus) &&
      other.gpuDriver == gpuDriver &&
      other.torch == torch &&
      other.cuda == cuda &&
      other.cudnn == cudnn &&
      deepMapEquals(other.slurm, slurm);

  @override
  int get hashCode => Object.hash(
    hostname,
    os,
    python,
    cpu,
    cpuCores,
    memoryGb,
    Object.hashAll(gpus),
    gpuDriver,
    torch,
    cuda,
    cudnn,
    Object.hashAllUnordered(slurm.entries.map((e) => Object.hash(e.key, e.value))),
  );
}

class GpuInfo {
  const GpuInfo({required this.name, required this.memoryGb});

  factory GpuInfo.fromJson(Map<String, Object?> json) => GpuInfo(
    name: json['name'] as String? ?? 'GPU',
    memoryGb: (json['memoryGb'] as num?)?.toDouble() ?? 0,
  );

  /// E.g. `NVIDIA A100-SXM4-80GB`.
  final String name;
  final double memoryGb;

  Map<String, Object?> toJson() => {'name': name, 'memoryGb': memoryGb};

  @override
  bool operator ==(Object other) =>
      other is GpuInfo && other.name == name && other.memoryGb == memoryGb;

  @override
  int get hashCode => Object.hash(name, memoryGb);
}
