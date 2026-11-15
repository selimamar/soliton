import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../data/providers.dart';
import '../../models/run.dart';
import '../../models/run_cost.dart';
import '../../models/simulation_info.dart';
import '../../shared/clock.dart';
import '../../shared/formatters.dart';
import '../../shared/widgets/key_value_row.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/spaced_list_view.dart';
import '../../shared/widgets/stat_tile.dart';
import '../run_detail/tabs/overview_tab.dart' show CostStrip, StatusBanner;
import '../run_detail/widgets/run_notes_card.dart';
import 'simulation_text.dart';
import '../run_detail/widgets/job_times.dart';
import '../run_detail/widgets/output_card.dart';
import '../run_detail/widgets/queue_card.dart';
import '../run_detail/widgets/resources_card.dart';
import '../run_detail/widgets/stop_button.dart';

/// Where a simulation is (simulated time, or iterations for a steady
/// solve), how long it has taken and has left, its cost, and its setup.
class SimulationOverviewTab extends StatelessWidget {
  const SimulationOverviewTab({super.key, required this.simulation});

  final Run simulation;

  @override
  Widget build(BuildContext context) {
    final run = simulation;
    if (run.status == RunStatus.queued) {
      return SpacedListView(children: [QueueCard(run: run), RunNotesCard(run: run)]);
    }
    return SpacedListView(
      children: [
        if (run.statusMessage case final message?)
          StatusBanner(message: message, isError: run.status == RunStatus.crashed),
        if (run.stopRequestedAt != null && run.status == RunStatus.live)
          StopRequestedBanner(run: run),
        if (run.status == RunStatus.crashed) OutputCard(run: run),
        _Progress(simulation: run),
        _Timing(simulation: run),
        if (JobTimes.showsFor(run)) JobTimes(run: run),
        if (ResourcesCard.showsFor(run)) ResourcesCard(run: run),
        if (HourlyPrice.of(run.system) case final price?) CostStrip(run: run, price: price),
        RunNotesCard(run: run),
        if (run.status != RunStatus.crashed) OutputCard(run: run),
        SectionCard(
          title: 'Setup',
          child: run.hyperparameters.isEmpty
              ? Text(
                  'Pass setup={...} to soliton.simulate() to show the equation, method, '
                  'grid and parameters here.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              : KeyValueGrid(entries: run.hyperparameters, caption: 'How it is set up.'),
        ),
      ],
    );
  }
}

/// The simulated time, large, of its end time, and how fast it advances;
/// for a steady solve, its iterations.
class _Progress extends ConsumerWidget {
  const _Progress({required this.simulation});

  final Run simulation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final now = ref.watch(clockProvider);
    final run = simulation;
    final sim = run.simulation!;
    final time = sim.time;
    final hours = run.elapsedAt(now).inSeconds / 3600;
    final failed = run.status == RunStatus.crashed;

    final (String title, String big, String detail, double? progress) = time != null
        ? (
            'Simulated time',
            formatSimulatedTime(time),
            [
              if (sim.tEnd case final end?) 'of ${formatCoordinate(end)}',
              if (hours > 0 && time > 0) '${formatCoordinate(time / hours)} per hour',
            ].join(' · '),
            sim.tEnd == null ? null : run.progress,
          )
        : (
            'Iterations',
            formatInt(run.currentStep),
            run.totalSteps > 0 ? 'of at most ${formatInt(run.totalSteps)}' : '',
            run.totalSteps > 0 ? run.progress : null,
          );

    return SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            big,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.displaySmall?.copyWith(
              fontFeatures: AppText.tabular,
              color: failed ? theme.colorScheme.error : null,
            ),
          ),
          if (detail.isNotEmpty) ...[const SizedBox(height: 2), Text(detail, style: muted)],
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              semanticsLabel: 'Simulation progress',
              semanticsValue: formatPercent(progress),
            ),
          ],
        ],
      ),
    );
  }
}

/// Step, time step, elapsed and remaining (or ended) time in one strip.
class _Timing extends ConsumerWidget {
  const _Timing({required this.simulation});

  final Run simulation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider);
    final run = simulation;
    final dt = ref.watch(runMetricsProvider(run.id)).value?[SimulationInfo.timeStepKey]?.latest;
    final remaining = run.estimatedRemainingAt(now);
    final endedAt = run.endedAt;
    return StatStrip(
      stats: [
        // A steady solve's steps are its iterations.
        (run.simulation?.time == null ? 'Iteration' : 'Step', formatInt(run.currentStep)),
        if (dt != null) ('Time step', formatMetric(dt)),
        ('Elapsed', formatDuration(run.elapsedAt(now))),
        if (remaining != null)
          ('Remaining', '~${formatDuration(remaining)}')
        else if (run.status == RunStatus.live)
          ('Remaining', 'Unknown')
        else
          ('Ended', endedAt != null ? formatTimeAgo(endedAt, now: now) : '—'),
      ],
    );
  }
}
