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
    this.pricePerHour,
    this.repro,
  });

  factory SystemInfo.fromJson(Map<String, Object?> json) => SystemInfo(
    hostname: json['hostname'] as String?,
    os: json['os'] as String?,
    python: json['python'] as String?,
    cpu: json['cpu'] as String?,
    cpuCores: (json['cpuCores'] as num?)?.toDouble(),
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
    pricePerHour: (json['pricePerHour'] as num?)?.toDouble(),
    repro: switch (json['repro']) {
      final Map<String, Object?> repro => ReproInfo.fromJson(repro),
      _ => null,
    },
  );

  /// The node, e.g. `sh03-12n07.int`.
  final String? hostname;

  /// E.g. `Rocky Linux 8.10 (Linux 4.18.0)`.
  final String? os;
  final String? python;

  /// CPU model, e.g. `AMD EPYC 7543 32-Core Processor`.
  final String? cpu;

  /// Cores the job may use (its Slurm allocation, or a container's CPU
  /// quota, e.g. 0.5), not the whole machine's.
  final double? cpuCores;

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
  /// `arrayTaskId`: whichever Slurm set. Also `submitTime`, `startTime` and
  /// `timeLimitAt` (UTC, ISO 8601), from Slurm when the job started.
  ///
  /// For a queued job (`soliton sbatch`), what Slurm said of it in the
  /// queue: `state`, `reason`, `expectedStart`, `queueCheckedAt` (when it
  /// last looked), and what it asked for: `cpus`, `memory`, `gpus` and
  /// `timeLimit` (as Slurm writes them, e.g. "32G", "1-00:00:00").
  final Map<String, String> slurm;

  /// Why Slurm hasn't started a queued job, e.g. `Priority`, `Resources`.
  String? get queueReason => switch (slurm['reason']) {
    final reason? when reason.isNotEmpty && reason != 'None' => reason,
    _ => null,
  };

  /// When Slurm expects to start a queued job, if it has worked that out.
  DateTime? get expectedStartAt => _slurmTime('expectedStart');

  /// When Slurm was last asked about a queued job.
  DateTime? get queueCheckedAt => _slurmTime('queueCheckedAt');

  /// The job has left the queue, but its script hasn't started a run yet.
  bool get jobStarting => slurm['state'] == 'RUNNING';

  /// When the job was submitted to Slurm's queue.
  DateTime? get submittedAt => _slurmTime('submitTime');

  /// When Slurm started the job (a little before the script started the run).
  DateTime? get jobStartedAt => _slurmTime('startTime');

  /// When Slurm stops the job, finished or not: its time limit.
  DateTime? get timeLimitAt => _slurmTime('timeLimitAt');

  DateTime? _slurmTime(String key) => switch (slurm[key]) {
    final text? => DateTime.tryParse(text),
    null => null,
  };

  /// What the job's machine costs per hour in US dollars, if the run said
  /// (`soliton.init(price_per_hour=...)`); see `HourlyPrice` for the
  /// estimate otherwise.
  final double? pricePerHour;

  /// What it takes to run it again (code version, command, job script,
  /// packages), if the logger recorded it.
  final ReproInfo? repro;

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
    'pricePerHour': ?pricePerHour,
    'repro': ?repro?.toJson(),
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
      deepMapEquals(other.slurm, slurm) &&
      other.pricePerHour == pricePerHour &&
      other.repro == repro;

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
    pricePerHour,
    repro,
  );
}

/// What the logger recorded to run a computation again: the working
/// directory and command line, the git commit (with the files that had
/// uncommitted changes), the Slurm job script and the Python packages.
/// Secrets are hidden by the logger.
class ReproInfo {
  const ReproInfo({
    this.cwd,
    this.command,
    this.commit,
    this.branch,
    this.remote,
    this.dirty = const [],
    this.dirtyCount,
    this.jobScript,
    this.packages = const [],
  });

  factory ReproInfo.fromJson(Map<String, Object?> json) {
    final git = (json['git'] as Map?)?.cast<String, Object?>() ?? const {};
    return ReproInfo(
      cwd: json['cwd'] as String?,
      command: json['command'] as String?,
      commit: git['commit'] as String?,
      branch: git['branch'] as String?,
      remote: git['remote'] as String?,
      dirty: List.unmodifiable([for (final f in (git['dirty'] as List?) ?? const []) f as String]),
      dirtyCount: (git['dirtyCount'] as num?)?.toInt(),
      jobScript: json['jobScript'] as String?,
      packages: List.unmodifiable([
        for (final p in (json['packages'] as List?) ?? const []) p as String,
      ]),
    );
  }

  final String? cwd;

  /// E.g. `python3 train.py --lr 3e-4`.
  final String? command;
  final String? commit;
  final String? branch;
  final String? remote;

  /// Files with uncommitted changes (the first ones; [dirtyCount] all).
  final List<String> dirty;
  final int? dirtyCount;

  /// The Slurm job's batch script.
  final String? jobScript;

  /// E.g. `numpy==2.1.0`.
  final List<String> packages;

  /// "045e08c", or "045e08c + changes" when files weren't committed.
  String? get codeVersion => switch (commit) {
    final c? => '${c.length > 7 ? c.substring(0, 7) : c}${dirty.isEmpty ? '' : ' + changes'}',
    null => null,
  };

  int get changedFiles => dirtyCount ?? dirty.length;

  /// What to paste in a shell to run it again from where it ran; null
  /// when the command isn't [isPlainCommand].
  String? get rerun => switch ((cwd, command)) {
    (_, final cmd?) when !isPlainCommand(cmd) => null,
    (final dir?, final cmd?) => 'cd ${_quote(dir)} && $cmd',
    (null, final cmd?) => cmd,
    _ => null,
  };

  /// Whether [command] is only words, as the logger writes it (Python's
  /// `shlex.join`): plain words, or words in single quotes. Nothing a shell
  /// would run on its own (`;`, `&&`, `|`, `$(...)`, backticks, redirections,
  /// a new line), so a command planted on the server can't be passed off as
  /// the run's: the app doesn't offer it to copy.
  static bool isPlainCommand(String command) => _plainCommand.hasMatch(command);

  // shlex.quote keeps [\w@%+=:,./-] as they are, puts anything else in
  // single quotes, and writes a quote inside as '"'"'.
  static final _plainCommand = RegExp(
    r"""^(?:[\w@%+=:,./-]|'[^']*'|"'")+(?: (?:[\w@%+=:,./-]|'[^']*'|"'")+)*$""",
  );

  static String _quote(String path) =>
      RegExp(r'^[A-Za-z0-9_./~+-]+$').hasMatch(path) ? path : "'${path.replaceAll("'", r"'\''")}'";

  Map<String, Object?> toJson() => {
    'cwd': ?cwd,
    'command': ?command,
    if (commit != null)
      'git': {
        'commit': commit,
        'branch': ?branch,
        'remote': ?remote,
        if (dirty.isNotEmpty) 'dirty': dirty,
        'dirtyCount': ?dirtyCount,
      },
    'jobScript': ?jobScript,
    if (packages.isNotEmpty) 'packages': packages,
  };

  @override
  bool operator ==(Object other) =>
      other is ReproInfo &&
      other.cwd == cwd &&
      other.command == command &&
      other.commit == commit &&
      other.branch == branch &&
      other.remote == remote &&
      deepListEquals(other.dirty, dirty) &&
      other.dirtyCount == dirtyCount &&
      other.jobScript == jobScript &&
      deepListEquals(other.packages, packages);

  @override
  int get hashCode => Object.hash(
    cwd,
    command,
    commit,
    branch,
    remote,
    Object.hashAll(dirty),
    dirtyCount,
    jobScript,
    Object.hashAll(packages),
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
