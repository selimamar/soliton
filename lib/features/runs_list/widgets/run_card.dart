import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/run.dart';
import '../../../shared/clock.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/loss_change.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/sparkline.dart';
import '../../../shared/widgets/tag_label.dart';
import '../run_groups.dart';
import 'run_card_styles.dart';

/// One run in the runs list, in the current style: in Lab an instrument
/// card, in Ink a table row (see run_card_styles.dart). In Paper: a strip in its status colour, its name and
/// latest loss, where it runs and how the loss moved, its tags and the start
/// of its note, a loss sparkline and its progress.
class RunCard extends StatelessWidget {
  const RunCard({
    super.key,
    required this.run,
    this.onTap,
    this.onLongPress,
    this.selected,
    this.ranking,
  });

  final Run run;
  final VoidCallback? onTap;

  /// Starts picking runs, with this one picked.
  final VoidCallback? onLongPress;

  /// Non-null while picking runs to compare: whether this one is picked.
  final bool? selected;

  /// When the list is ordered by a metric: the run's rank, shown before
  /// its name, and its value of the metric, shown instead of the loss.
  final RunRanking? ranking;

  @override
  Widget build(BuildContext context) {
    switch (AppTheme.styleOf(context)) {
      case AppStyle.lab:
        return LabRunCard(
          run: run,
          onTap: onTap,
          onLongPress: onLongPress,
          selected: selected,
          ranking: ranking,
        );
      case AppStyle.ink:
        return JournalRunRow(
          run: run,
          onTap: onTap,
          onLongPress: onLongPress,
          selected: selected,
          ranking: ranking,
        );
      case AppStyle.paper:
        break;
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final crashed = run.status == RunStatus.crashed;
    final statusColor = run.status == RunStatus.finished
        ? scheme.outline
        : run.status.color(scheme);
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);
    final shown = rankedFigure(run, ranking);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(15, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (selected case final isSelected?) ...[
                Icon(
                  isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 18,
                  color: isSelected ? scheme.primary : muted,
                ),
                const SizedBox(width: 8),
              ],
              if (ranking?.score.rank case final rank?) ...[
                Text(
                  '$rank',
                  semanticsLabel: rank == 1 ? 'Best' : 'Rank $rank',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: AppText.tabular,
                    color: rank == 1 ? scheme.primary : muted,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  run.name,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (shown != null) ...[
                const SizedBox(width: 8),
                Text(
                  shown.text,
                  semanticsLabel: shown.semantics,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: AppText.tabular,
                    color: crashed
                        ? scheme.error
                        : ranking?.score.best ?? false
                        ? scheme.primary
                        : shown.missing
                        ? muted
                        : null,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  [run.host, run.project].where((s) => s.isNotEmpty).join(' · '),
                  style: small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!crashed) LossChange(run: run, style: small),
            ],
          ),
          if (run.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 4, children: [for (final tag in run.tags) TagLabel(tag)]),
          ],
          if (run.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.sticky_note_2_outlined, size: 14, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    run.notes.trim().split('\n').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Sparkline(
            values: run.lossPreview,
            color: crashed ? scheme.error : scheme.onSurface,
            height: 24,
            endDotColor: crashed ? null : statusColor,
            semanticLabel: 'Loss curve, ${trendOf(run.lossPreview)}',
          ),
          const SizedBox(height: 8),
          _ProgressLabel(
            run: run,
            style: theme.textTheme.labelMedium?.copyWith(color: crashed ? scheme.error : muted),
          ),
          if (run.status == RunStatus.live) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: run.progress,
              minHeight: 2,
              color: scheme.onSurface,
              semanticsLabel: 'Training progress',
              semanticsValue: formatPercent(run.progress),
            ),
          ],
        ],
      ),
    );

    return SectionCard(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selected,
      padding: EdgeInsets.zero,
      // The status strip is laid over the card's left edge; the card sizes
      // to its content alone, so the strip costs no extra layout pass.
      child: Stack(
        children: [
          content,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            // The strip's colour is the status; this says it for screen readers.
            child: Semantics(
              label: run.status.label,
              child: ColoredBox(color: statusColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// The figure a run card shows on the right: its latest loss, or with a
/// [ranking] its value of the ranking's metric ("–" if it logged none).
({String text, String semantics, bool missing})? rankedFigure(Run run, RunRanking? ranking) {
  if (ranking == null) {
    final loss = run.latestLoss;
    if (loss == null) return null;
    return (text: formatMetric(loss), semantics: 'loss ${formatMetric(loss)}', missing: false);
  }
  final value = ranking.score.value;
  final name = ranking.order.label.toLowerCase();
  if (value == null) return (text: '–', semantics: 'no $name logged', missing: true);
  final text = ranking.order.format(value);
  return (text: text, semantics: '$name $text', missing: false);
}

/// "Epoch 42/100 · 3h 12m", kept current by [clockProvider]. Only this
/// line rebuilds on each tick, not the whole card.
class _ProgressLabel extends ConsumerWidget {
  const _ProgressLabel({required this.run, this.style});

  final Run run;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider);
    final text = switch (run.status) {
      RunStatus.live =>
        'Epoch ${run.currentEpoch}/${run.totalEpochs} · ${formatDuration(run.elapsedAt(now))}',
      RunStatus.finished => 'Finished ${formatTimeAgo(run.endedAt ?? run.startedAt, now: now)}',
      RunStatus.crashed => 'Crashed at step ${formatInt(run.currentStep)}',
    };
    return Text(text, style: style);
  }
}
