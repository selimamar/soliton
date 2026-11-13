import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/run.dart';
import '../../../shared/clock.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/sparkline.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../../shared/widgets/tag_label.dart';

/// One run in the runs list: name, status, where it runs, its tags and the
/// start of its note, a loss sparkline and its progress.
class RunCard extends StatelessWidget {
  const RunCard({super.key, required this.run, this.onTap, this.selected});

  final Run run;
  final VoidCallback? onTap;

  /// Non-null while picking runs to compare: whether this one is picked.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final latestLoss = run.latestLoss;
    final lossColor = run.status == RunStatus.crashed ? theme.colorScheme.error : ChartColors.train;

    return SectionCard(
      onTap: onTap,
      selected: selected,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (selected case final isSelected?) ...[
                Icon(
                  isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: isSelected ? theme.colorScheme.primary : muted,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  run.name,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(status: run.status),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [run.host, run.project].where((s) => s.isNotEmpty).join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          if (run.tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 4, children: [for (final tag in run.tags) TagLabel(tag)]),
          ],
          if (run.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.sticky_note_2_outlined, size: 14, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    run.notes.trim().split('\n').first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Sparkline(
            values: run.lossPreview,
            color: lossColor,
            semanticLabel: 'Loss curve, ${trendOf(run.lossPreview)}',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ProgressLabel(
                  run: run,
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
              ),
              if (latestLoss != null)
                Text(
                  'loss ${formatMetric(latestLoss)}',
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
            ],
          ),
          if (run.status == RunStatus.live) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: run.progress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(4),
              semanticsLabel: 'Training progress',
              semanticsValue: formatPercent(run.progress),
            ),
          ],
        ],
      ),
    );
  }
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
