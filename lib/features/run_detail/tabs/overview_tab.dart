import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../data/providers.dart';
import '../../../models/metric_series.dart';
import '../../../app/theme.dart';
import '../../../models/run.dart';
import '../../../models/run_cost.dart';
import '../../../shared/clock.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/key_value_row.dart';
import '../../../shared/widgets/loss_change.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/spaced_list_view.dart';
import '../../../shared/widgets/sparkline.dart';
import '../../../shared/widgets/stat_tile.dart';
import '../../../shared/widgets/style_decor.dart';
import '../widgets/architecture_tree.dart';
import '../widgets/network_diagram.dart';
import '../widgets/run_notes_card.dart';

/// Key facts about a run: size, timing, progress, tags and notes,
/// hyperparameters and architecture.
class OverviewTab extends StatelessWidget {
  const OverviewTab({super.key, required this.run});

  final Run run;

  @override
  Widget build(BuildContext context) {
    return SpacedListView(
      children: [
        if (run.statusMessage case final message?)
          _StatusBanner(message: message, isError: run.status == RunStatus.crashed),
        if (run.latestLoss != null) _LossHero(run: run),
        // Ink says the progress in the loss sentence instead.
        if (AppTheme.styleOf(context) != AppStyle.ink || run.latestLoss == null)
          _ProgressStrip(run: run),
        _SpeedStrip(runId: run.id),
        if (HourlyPrice.of(run.system) case final price?) _CostStrip(run: run, price: price),
        RunNotesCard(run: run),
        SectionCard(
          title: 'Hyperparameters',
          child: KeyValueGrid(entries: run.hyperparameters, caption: 'Settings of this run.'),
        ),
        SectionCard(
          title: 'Architecture · ${run.architecture.type}',
          trailing: Text('${formatCount(run.parameterCount)} params'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NetworkSection(run: run),
              const SizedBox(height: 8),
              ArchitectureTree(root: run.architecture),
            ],
          ),
        ),
      ],
    );
  }
}

/// How fast the model is per sample, and how much faster than the solver
/// it stands in for (`perf/inference_s`, `perf/solver_s`): only when the run
/// logs them.
class _SpeedStrip extends ConsumerWidget {
  const _SpeedStrip({required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(runMetricsProvider(runId)).value;
    final inference = metrics?[MetricKeys.inferenceSeconds]?.latest;
    if (inference == null) return const SizedBox.shrink();
    final solver = metrics?[MetricKeys.solverSeconds]?.latest;
    final speedup = solver != null && inference > 0 ? solver / inference : null;
    return StatStrip(
      stats: [
        ('Model, per sample', formatSeconds(inference)),
        if (solver != null) ('Solver', formatSeconds(solver)),
        ('Speed-up', speedup == null ? 'Solver not logged' : '${formatCount(speedup)}× faster'),
      ],
    );
  }
}

/// Roughly what the run has cost, and will cost if it is still going, from
/// its machine's price per hour (see [HourlyPrice]). Rounded: it's an
/// estimate. Kept current by [clockProvider].
class _CostStrip extends ConsumerWidget {
  const _CostStrip({required this.run, required this.price});

  final Run run;
  final HourlyPrice price;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cost = estimateCost(run, ref.watch(clockProvider), price)!;
    final live = run.status == RunStatus.live;
    return StatStrip(
      stats: [
        (live ? 'Cost so far' : 'Cost', formatCost(cost.soFar)),
        if (cost.total case final total?) ('Expected total', formatCost(total)),
        ('Price', '${formatCost(price.dollars)}/h'),
      ],
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Text(
          'Estimated: run time × ${price.basis}.',
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// The run's latest training loss, large, over its curve: whether the run
/// is healthy at a glance.
class _LossHero extends StatelessWidget {
  const _LossHero({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = AppTheme.styleOf(context);
    final crashed = run.status == RunStatus.crashed;
    final loss = formatMetric(run.latestLoss!);
    final curveColor = crashed
        ? scheme.error
        : (style == AppStyle.lab ? scheme.primary : scheme.onSurface);
    final dot = crashed ? null : run.status.color(scheme);

    // Ink: a sentence, then the curve as a captioned figure.
    if (style == AppStyle.ink) {
      return SectionCard(
        title: 'Training loss',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LossSentence(run: run),
            const SizedBox(height: 12),
            FigureChart(
              values: run.lossPreview,
              color: crashed ? scheme.error : scheme.primary,
              lastStep: run.currentStep,
              semanticLabel: 'Figure 1, training loss curve, ${trendOf(run.lossPreview)}',
            ),
            const SizedBox(height: 6),
            Text.rich(
              const TextSpan(
                children: [
                  TextSpan(
                    text: 'Figure 1. ',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: 'Training loss against step.'),
                ],
              ),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    final lab = style == AppStyle.lab;
    return SectionCard(
      title: lab ? 'Train loss · readout' : 'Training loss',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                loss,
                semanticsLabel: 'Training loss $loss',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontFeatures: AppText.tabular,
                  color: crashed ? scheme.error : scheme.onSurface,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: LossChange(
                  run: run,
                  style: theme.textTheme.bodySmall,
                  suffix: ' over the last 10%',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (lab)
            FigureChart(
              values: run.lossPreview,
              color: curveColor,
              endDotColor: dot,
              lastStep: run.currentStep,
              semanticLabel: 'Training loss curve, ${trendOf(run.lossPreview)}',
            )
          else
            Sparkline(
              values: run.lossPreview,
              color: curveColor,
              height: 64,
              strokeWidth: 2,
              endDotColor: dot,
              semanticLabel: 'Training loss curve, ${trendOf(run.lossPreview)}',
            ),
        ],
      ),
    );
  }
}

/// Ink: the loss and progress in a sentence, as a paper would put it, e.g.
/// "The loss is now 0.501, down 0.065 lately. Training is 42% done (epoch
/// 42 of 100, step 8,232 of 19,600); about 4h 25m remain." Kept current by
/// [clockProvider].
class _LossSentence extends ConsumerWidget {
  const _LossSentence({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = ref.watch(clockProvider);
    final loss = formatMetric(run.latestLoss!);
    final change = run.recentLossChange;
    final trend = change == null
        ? ''
        : ', ${change < 0 ? 'down' : 'up'} ${formatMetric(change.abs())} lately';
    final remaining = run.estimatedRemainingAt(now);
    final endedAt = run.endedAt;

    final (before, after) = switch (run.status) {
      RunStatus.live => (
        'The loss is now ',
        '$trend. Training is ${formatPercent(run.progress)} done (epoch ${run.currentEpoch} of '
            '${run.totalEpochs}, step ${formatInt(run.currentStep)} of '
            '${formatInt(run.totalSteps)})'
            '${remaining == null ? '' : '; about ${formatDuration(remaining)} remain'}.',
      ),
      RunStatus.finished => (
        'The final loss was ',
        '. Training finished${endedAt == null ? '' : ' ${formatTimeAgo(endedAt, now: now)}'} '
            'after ${run.currentEpoch} epochs (${formatInt(run.currentStep)} steps).',
      ),
      RunStatus.crashed => (
        'The loss reached ',
        ' before the run crashed at step ${formatInt(run.currentStep)} '
            '(epoch ${run.currentEpoch} of ${run.totalEpochs}).',
      ),
    };

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: before),
          TextSpan(
            text: loss,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: after),
        ],
      ),
      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
    );
  }
}

/// The network diagram, or what it takes to get one.
class _NetworkSection extends StatelessWidget {
  const _NetworkSection({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final flow = run.flow;
    if (flow == null || !flow.layers.any((layer) => layer.isDrawn)) {
      return Text(
        'The network diagram appears once the model has run with run.watch(model).',
        style: note,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NetworkDiagram(flow: flow, tree: run.architecture),
        const SizedBox(height: 4),
        Text(
          'Layers in the order they run; numbers are output features or channels. '
          'Skip connections aren\'t shown. Hold or hover over a layer for details.',
          style: note,
        ),
      ],
    );
  }
}

/// Progress, epoch, elapsed and remaining (or ended) time in one strip,
/// with a progress line and the step count under it. Kept current by
/// [clockProvider].
class _ProgressStrip extends ConsumerWidget {
  const _ProgressStrip({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = AppTheme.styleOf(context);
    final lab = style == AppStyle.lab;
    final theme = Theme.of(context);
    final now = ref.watch(clockProvider);
    final remaining = run.estimatedRemainingAt(now);
    final endedAt = run.endedAt;
    // Lab shows times like a clock, 03:12:04.
    final time = lab ? _clock : formatDuration;

    return StatStrip(
      stats: [
        ('Progress', formatPercent(run.progress)),
        ('Epoch', '${run.currentEpoch}/${run.totalEpochs}'),
        ('Elapsed', time(run.elapsedAt(now))),
        if (remaining != null)
          (lab ? 'ETA' : 'Remaining', lab ? time(remaining) : '~${time(remaining)}')
        else
          ('Ended', endedAt != null ? formatTimeAgo(endedAt, now: now) : '—'),
      ],
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lab)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: BlockProgress(value: run.progress, label: 'Training progress'),
            )
          else
            LinearProgressIndicator(
              value: run.progress,
              minHeight: 2,
              semanticsLabel: 'Training progress',
              semanticsValue: formatPercent(run.progress),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Text(
              'Step ${formatInt(run.currentStep)} of ${formatInt(run.totalSteps)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: AppText.tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "03:12:04": hours, minutes and seconds, for Lab's readouts.
String _clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isError ? scheme.errorContainer : scheme.secondaryContainer;
    final foreground = isError ? scheme.onErrorContainer : scheme.onSecondaryContainer;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radiusOf(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isError ? Icons.error_outline : Icons.info_outline, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: foreground)),
          ),
        ],
      ),
    );
  }
}
