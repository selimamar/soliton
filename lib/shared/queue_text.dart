import '../models/run.dart';
import 'formatters.dart';

/// A queued job in a line: "Queued 2h 13m · Priority", or "Starting ·
/// waited 2h 13m" once Slurm has started it but its script hasn't logged.
String describeQueued(Run run, DateTime now) {
  final waited = formatRoughDuration(run.queuedFor(now) ?? Duration.zero);
  if (run.system?.jobStarting ?? false) return 'Starting · waited $waited';
  return ['Queued $waited', ?run.system?.queueReason].join(' · ');
}

/// What a Slurm pending reason means, in plain words; null for one it
/// doesn't know (show the reason as it is).
String? explainQueueReason(String reason) => switch (reason) {
  'Priority' =>
    'Other jobs are ahead of it. It starts when its priority (your fairshare, '
        'and how long it has waited) puts it first.',
  'Resources' =>
    "It's next in line, waiting for nodes with what it asked for to free up.",
  'Dependency' => 'Waiting for the jobs it depends on to finish.',
  'DependencyNeverSatisfied' =>
    'A job it depends on failed, so it will never start. Cancel it (scancel).',
  'BeginTime' => 'It was asked to start later (--begin).',
  'JobHeldUser' => 'Held by you: release it with scontrol release.',
  'JobHeldAdmin' => 'Held by an administrator.',
  'ReqNodeNotAvail' || 'ReqNodeNotAvail, Reserved for maintenance' =>
    'The nodes it can run on are unavailable, often for maintenance.',
  'PartitionTimeLimit' =>
    'Its --time is longer than the partition allows, so it will never start. '
        'Cancel it and ask for less time.',
  'PartitionDown' || 'PartitionInactive' => 'Its partition is down.',
  'None' => "Just submitted: Slurm hasn't looked at it yet.",
  _ when reason.startsWith('QOS') || reason.startsWith('Assoc') =>
    'You (or your group) are at a limit on running jobs or resources. It starts '
        'when some of them finish.',
  _ => null,
};

/// What a queued job asked Slurm for: "4 CPUs · 32 GB · 1 GPU · gpu
/// partition", from `soliton sbatch`'s `cpus`, `memory`, `gpus` and
/// `partition`.
String describeRequest(Map<String, String> slurm) {
  final cpus = int.tryParse(slurm['cpus'] ?? '');
  final gpus = int.tryParse(slurm['gpus'] ?? '');
  return [
    if (cpus != null && cpus > 0) cpus == 1 ? '1 CPU' : '$cpus CPUs',
    ?formatSlurmMemory(slurm['memory']),
    if (gpus != null && gpus > 0) gpus == 1 ? '1 GPU' : '$gpus GPUs',
    if (slurm['partition'] case final partition? when partition.isNotEmpty) '$partition partition',
  ].join(' · ');
}

/// Slurm's memory, e.g. "32G", "4000M", "1T" -> "32 GB", "3.9 GB", "1,024 GB"
/// (Slurm's units are binary). Null for anything else.
String? formatSlurmMemory(String? text) {
  final match = RegExp(r'^(\d+(?:\.\d+)?)([KMGT]?)$').firstMatch(text?.trim() ?? '');
  if (match == null) return null;
  final value = double.parse(match[1]!);
  final gb = switch (match[2]) {
    'K' => value / (1024 * 1024),
    'G' => value,
    'T' => value * 1024,
    _ => value / 1024, // M, Slurm's default unit.
  };
  if (gb <= 0) return null;
  return gb >= 10 || gb == gb.roundToDouble() ? '${formatInt(gb.round())} GB' : formatGb(gb);
}

/// Slurm's time, e.g. "1-00:00:00", "12:00:00", "30:00", "45" (minutes).
/// Null for "UNLIMITED" or anything else.
Duration? parseSlurmDuration(String? text) {
  final match = RegExp(r'^(?:(\d+)-)?(\d+)(?::(\d+))?(?::(\d+))?$').firstMatch(text?.trim() ?? '');
  if (match == null) return null;
  final days = int.parse(match[1] ?? '0');
  final parts = [match[2], match[3], match[4]].nonNulls.map(int.parse).toList();
  // D-HH[:MM[:SS]] counts from hours; otherwise MM, MM:SS or HH:MM:SS.
  final (hours, minutes, seconds) = switch ((match[1] != null, parts)) {
    (true, [final h]) => (h, 0, 0),
    (true, [final h, final m]) => (h, m, 0),
    (_, [final h, final m, final s]) => (h, m, s),
    (_, [final m, final s]) => (0, m, s),
    (_, [final m]) => (0, m, 0),
    _ => (0, 0, 0),
  };
  return Duration(days: days, hours: hours, minutes: minutes, seconds: seconds);
}
