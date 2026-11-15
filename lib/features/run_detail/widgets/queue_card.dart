import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../models/run.dart';
import '../../../shared/clock.dart';
import '../../../shared/formatters.dart';
import '../../../shared/queue_text.dart';
import '../../../shared/widgets/key_value_row.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/stat_tile.dart';
import 'job_times.dart' show timeOfDay;

/// A queued Slurm job (from `soliton sbatch`): how long it has waited, when
/// Slurm expects to start it, why it's waiting and what it asked for. What
/// Slurm said is as of `soliton sbatch`, or the last `soliton queue`; the
/// wait is counted here. Kept current by [clockProvider].
class QueueCard extends ConsumerWidget {
  const QueueCard({super.key, required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final system = run.system;
    final slurm = system?.slurm ?? const {};
    String clock(DateTime t) => formatClock(t, now: now, timeOfDay: (t) => timeOfDay(context, t));

    final starting = system?.jobStarting ?? false;
    final expected = system?.expectedStartAt;
    final limit = parseSlurmDuration(slurm['timeLimit']);
    final reason = system?.queueReason;
    final asked = describeRequest(slurm);
    final checked = system?.queueCheckedAt;
    return SectionCard(
      title: starting ? 'Starting' : 'In the queue',
      trailing: switch (slurm['jobId']) {
        final id? => Text('Job $id', style: muted),
        null => null,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatStrip(
            stats: [
              (
                starting ? 'Waited' : 'Waiting',
                formatRoughDuration(run.queuedFor(now) ?? Duration.zero),
              ),
              if (!starting)
                (
                  'Expected start',
                  switch (expected) {
                    final at? when at.isAfter(now) => '~${clock(at)}',
                    final _? => 'Any moment',
                    null => 'Not estimated',
                  },
                ),
              if (limit != null) ('Time limit', formatDuration(limit)),
            ],
          ),
          const SizedBox(height: 12),
          if (starting)
            Text(
              'Slurm has started the job; this turns into the run when its script starts '
              'logging.',
              style: theme.textTheme.bodyMedium,
            )
          else if (reason != null) ...[
            KeyValueRow(label: 'Waiting for', value: reason),
            if (explainQueueReason(reason) case final why?)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(why, style: theme.textTheme.bodyMedium),
              ),
          ],
          if (asked.isNotEmpty) KeyValueRow(label: 'Asked for', value: asked),
          if (expected == null && !starting)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                "Slurm often doesn't estimate a start until the job is near the front of "
                'the queue.',
                style: muted,
              ),
            ),
          if (checked != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Slurm last asked ${formatTimeAgo(checked, now: now)}. Run soliton queue '
                'on the cluster to update it.',
                style: muted,
              ),
            ),
        ],
      ),
    );
  }
}
