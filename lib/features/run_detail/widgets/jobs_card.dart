import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../models/run.dart';
import '../../../models/run_job.dart';
import '../../../shared/clock.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/section_card.dart';

/// A run continued over several jobs (from checkpoints): each job's Slurm
/// id, how long it waited and ran, the steps it covered and how it ended.
/// Nothing for a run that ran in one job. Their starts are marked on the
/// Metrics charts.
class JobsCard extends ConsumerWidget {
  const JobsCard({super.key, required this.run});

  final Run run;

  static bool showsFor(Run run) => run.jobs.length > 1;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final waits = [for (final job in run.jobs) ?job.queueWait];
    final queued = waits.fold(Duration.zero, (a, b) => a + b);
    return SectionCard(
      title: 'Jobs',
      trailing: Text(
        [
          '${run.jobs.length} jobs',
          if (waits.isNotEmpty) '${formatRoughDuration(queued)} queued in all',
        ].join(' · '),
        style: muted,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, job) in run.jobs.indexed) ...[
            if (i > 0) const Divider(height: 16),
            Text(['Job ${i + 1}', ?job.jobId].join(' · '), style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(_facts(job, i == run.jobs.length - 1 ? run : null, now), style: muted),
            if (_ending(job) case final ending?)
              Text(
                ending,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: job.status == RunStatus.crashed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// "waited 20m · ran 7h 54m · steps 4,000 → 9,000" ([current] for the job
  /// still running: up to the run's step now).
  static String _facts(RunJob job, Run? current, DateTime now) {
    final end = job.endStep ?? current?.currentStep;
    return [
      if (job.queueWait case final wait?) 'waited ${formatRoughDuration(wait)}',
      job.endedAt == null
          ? 'running for ${formatRoughDuration(job.ranFor(now))}'
          : 'ran ${formatRoughDuration(job.ranFor(now))}',
      if (end != null) 'steps ${formatInt(job.startStep)} → ${formatInt(end)}',
    ].join(' · ');
  }

  static String? _ending(RunJob job) => switch (job.status) {
    null => null,
    RunStatus.finished => job.message ?? 'Finished',
    _ => job.message ?? 'Crashed',
  };
}
