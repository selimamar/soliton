import 'dart:math' as math;

import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../shared/formatters.dart';
import 'system_usage.dart';

/// How well an ended Slurm job's request fit what it used: memory, CPUs,
/// GPUs and time, each as "used of asked for", with what to ask for next
/// time ([flags], e.g. `--mem=16G`) where it asked for much more than it
/// needed, or a warning where it came close to a limit. Smaller requests
/// usually start sooner, and use less of a group's fairshare.
class ResourceFit {
  const ResourceFit({required this.rows, required this.flags});

  final List<ResourceRow> rows;

  /// sbatch options for next time, e.g. `['--mem=16G', '--time=03:00:00']`;
  /// empty when the request fit.
  final List<String> flags;

  /// For a run that has ended in a Slurm job (it knows its job id or time
  /// limit) and recorded what it ran on; null otherwise. [usage] is what
  /// the logger sampled; without it, only the time is compared.
  static ResourceFit? of(Run run, SystemUsage usage) {
    final system = run.system;
    if (system == null || run.status == RunStatus.live || run.status == RunStatus.queued) {
      return null;
    }
    if (system.slurm['jobId'] == null && system.timeLimitAt == null) return null;
    final rows = <ResourceRow>[];
    final flags = <String>[];

    // Memory: what Slurm enforces --mem on (the job's cgroup).
    final requested = system.memoryGb;
    final peak = _max(usage.memoryGb);
    if (requested != null && requested > 0 && peak != null) {
      final enough = _memoryFor(peak);
      final used = '${formatGb(peak)} peak of ${_gb(requested)}';
      if (peak > requested * 0.9) {
        rows.add(
          ResourceRow(
            'Memory',
            used,
            advice: 'Close to its limit: ask for more (--mem=${_memoryFor(peak * 1.2).round()}G).',
            warning: true,
          ),
        );
      } else if (peak < requested * 0.5 && requested - enough >= 4) {
        flags.add('--mem=${enough.round()}G');
        rows.add(ResourceRow('Memory', used, advice: '${_gb(enough)} would do.'));
      } else {
        rows.add(ResourceRow('Memory', used));
      }
    }

    // CPUs: system/cpu is a percentage of the cores the job may use.
    final cores = system.cpuCores;
    final cpu = usage.cpu;
    if (cores != null && cores >= 1 && cpu != null && !cpu.isEmpty) {
      final mean = _mean(cpu)! / 100 * cores;
      final busiest = _max(cpu)! / 100 * cores;
      final used =
          '${_cores(mean)} busy on average (at most ${_cores(busiest)}) of ${_cores(cores)}';
      final enough = math.max(1, (busiest * 1.25).ceil());
      if (cores >= 2 && enough <= cores / 2) {
        flags.add('-c $enough');
        rows.add(ResourceRow('CPUs', used, advice: '$enough would do.'));
      } else {
        rows.add(ResourceRow('CPUs', used));
      }
    }

    // GPUs: how busy each was, and how much of its memory it used.
    final utilization = usage.gpuSeries('utilization');
    if (utilization.isNotEmpty) {
      final means = {
        for (final MapEntry(:key, :value) in utilization.entries) key: _mean(value) ?? 0,
      };
      final idle = [
        for (final MapEntry(:key, :value) in means.entries)
          if (value < 5) key,
      ];
      final average = means.values.reduce((a, b) => a + b) / means.length;
      final count = means.length;
      final used = count == 1
          ? '${average.round()}% busy on average'
          : '$count GPUs, ${average.round()}% busy on average';
      if (count > 1 && idle.isNotEmpty && idle.length < count) {
        final keep = count - idle.length;
        flags.add('-G $keep');
        rows.add(
          ResourceRow(
            'GPUs',
            used,
            advice:
                '${idle.length == 1 ? 'GPU ${idle.single} was' : 'GPUs ${idle.join(', ')} were'} '
                'nearly idle: $keep would do, unless the script is meant to use them all.',
          ),
        );
      } else if (average < 30) {
        rows.add(
          ResourceRow(
            'GPUs',
            used,
            advice:
                'Mostly waiting: loading data may be holding it back (more DataLoader workers, '
                'with the CPUs for them).',
          ),
        );
      } else {
        rows.add(ResourceRow('GPUs', used));
      }
      final memory = [
        for (final (i, gpu) in system.gpus.indexed)
          if (_max(usage.gpus[i]?['memory_gb']) case final peak? when gpu.memoryGb > 0)
            (peak, gpu.memoryGb),
      ];
      if (memory.isNotEmpty) {
        final (peak, capacity) = memory.reduce((a, b) => a.$1 >= b.$1 ? a : b);
        rows.add(
          ResourceRow(
            'GPU memory',
            '${formatGb(peak)} peak of ${_gb(capacity)}',
            advice: peak < capacity * 0.3 && capacity >= 40
                ? 'A GPU with less memory would do, and may start sooner.'
                : null,
          ),
        );
      }
    }

    // Time: only a finished run's says how long the job needs.
    final started = system.jobStartedAt ?? run.startedAt;
    final limitAt = system.timeLimitAt;
    final endedAt = run.endedAt;
    if (limitAt != null && endedAt != null) {
      final took = endedAt.difference(started);
      final limit = limitAt.difference(started);
      final used = '${formatDuration(took)} of ${formatDuration(limit)}';
      if (run.status != RunStatus.finished || took.isNegative || limit <= Duration.zero) {
        rows.add(ResourceRow('Time', used));
      } else if (took > limit * 0.9) {
        rows.add(
          ResourceRow(
            'Time',
            used,
            advice: 'Finished with little to spare: ask for more next time.',
            warning: true,
          ),
        );
      } else {
        final enough = _timeFor(took);
        if (enough < limit * 0.6) {
          flags.add('--time=${formatSlurmTime(enough)}');
          rows.add(ResourceRow('Time', used, advice: '${formatRoughDuration(enough)} would do.'));
        } else {
          rows.add(ResourceRow('Time', used));
        }
      }
    }
    if (rows.isEmpty) return null;
    return ResourceFit(rows: List.unmodifiable(rows), flags: List.unmodifiable(flags));
  }
}

/// One resource: what it used of what it asked for, and maybe advice.
class ResourceRow {
  const ResourceRow(this.label, this.used, {this.advice, this.warning = false});

  final String label;
  final String used;
  final String? advice;

  /// It came close to a limit (the job may be stopped next time).
  final bool warning;
}

/// Enough memory for a peak of [peakGb]: a quarter more and a GB, in whole
/// GB up to 16, then in 4 GB steps.
double _memoryFor(double peakGb) {
  final wanted = peakGb * 1.25 + 1;
  return wanted <= 16 ? wanted.ceilToDouble() : (wanted / 4).ceil() * 4.0;
}

/// Enough time for a job that took [took]: a third more and a quarter of an
/// hour, rounded up to the quarter hour.
Duration _timeFor(Duration took) {
  final minutes = took.inSeconds / 60 * 1.3 + 15;
  return Duration(minutes: (minutes / 15).ceil() * 15);
}

/// Slurm's time format: "03:00:00", or "1-06:00:00" past a day.
String formatSlurmTime(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(d.inHours % 24)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return d.inDays > 0 ? '${d.inDays}-$clock' : clock;
}

String _gb(double gb) => gb == gb.roundToDouble() ? '${formatInt(gb.round())} GB' : formatGb(gb);

/// "1 core", "1.6 cores", "16 cores": to a tenth below 10 ("1.0" is "1").
String _cores(double n) {
  final rounded = n >= 10 ? n.roundToDouble() : (n * 10).round() / 10;
  final text = rounded == rounded.roundToDouble() ? '${rounded.round()}' : '$rounded';
  return text == '1' ? '1 core' : '$text cores';
}

double? _max(MetricSeries? series) {
  final values = [
    for (final p in series?.points ?? const <MetricPoint>[])
      if (p.value.isFinite) p.value,
  ];
  return values.isEmpty ? null : values.reduce(math.max);
}

/// The server's mean over every value when it sent one (see
/// [MetricSeries.mean]), else the mean of the points.
double? _mean(MetricSeries? series) {
  if (series?.mean case final mean?) return mean;
  final values = [
    for (final p in series?.points ?? const <MetricPoint>[])
      if (p.value.isFinite) p.value,
  ];
  return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
}
