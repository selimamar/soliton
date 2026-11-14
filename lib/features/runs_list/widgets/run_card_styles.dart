import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/run.dart';
import '../../../shared/formatters.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/sparkline.dart';
import '../../../shared/widgets/style_decor.dart';
import '../../../shared/widgets/tag_label.dart';
import '../run_groups.dart';
import 'run_card.dart' show rankedFigure;

/// A run in the Lab style: an instrument card with a status light, a
/// readout of the latest loss, a gridded sparkline and a block progress bar.
class LabRunCard extends StatelessWidget {
  const LabRunCard({super.key, required this.run, this.onTap, this.selected, this.ranking});

  final Run run;
  final VoidCallback? onTap;
  final bool? selected;
  final RunRanking? ranking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final crashed = run.status == RunStatus.crashed;
    final light = run.status == RunStatus.finished ? scheme.outline : run.status.color(scheme);
    final shown = rankedFigure(run, ranking);
    final rank = ranking?.score.rank;
    final label = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      letterSpacing: 1,
    );
    final where = [run.host, run.project].where((s) => s.isNotEmpty).join(' · ');
    final state = switch (run.status) {
      RunStatus.live => 'EP ${run.currentEpoch}/${run.totalEpochs}',
      RunStatus.finished => 'DONE',
      RunStatus.crashed => 'FAIL @${formatInt(run.currentStep)}',
    };

    return SectionCard(
      onTap: onTap,
      selected: selected,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Semantics(
                label: run.status.label,
                child: Container(width: 7, height: 7, color: light),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  where.toUpperCase(),
                  semanticsLabel: where,
                  style: label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (rank == 1) ...[
                Text(
                  '[BEST]',
                  semanticsLabel: 'Best',
                  style: label?.copyWith(color: scheme.primary),
                ),
                const SizedBox(width: 6),
              ],
              Text(state, style: label?.copyWith(color: crashed ? scheme.error : null)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (selected case final isSelected?) ...[
                Icon(
                  isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                  color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
              ],
              if (rank != null) ...[
                Text(
                  rank.toString().padLeft(2, '0'),
                  semanticsLabel: rank == 1 ? null : 'Rank $rank',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: AppText.tabular,
                    color: rank == 1 ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  run.name,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (shown != null)
                Text(
                  shown.text,
                  semanticsLabel: shown.semantics,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 21,
                    fontFeatures: AppText.tabular,
                    color: crashed
                        ? scheme.error
                        : rank == 1
                        ? scheme.primary
                        : shown.missing
                        ? scheme.onSurfaceVariant
                        : null,
                  ),
                ),
            ],
          ),
          if (run.tags.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [for (final tag in run.tags) TagLabel(tag)]),
          ],
          const SizedBox(height: 6),
          Sparkline(
            values: run.lossPreview,
            color: crashed ? scheme.error : scheme.primary,
            grid: true,
            semanticLabel: 'Loss curve, ${trendOf(run.lossPreview)}',
          ),
          if (run.status == RunStatus.live) ...[
            const SizedBox(height: 8),
            BlockProgress(value: run.progress, label: 'Training progress'),
          ],
        ],
      ),
    );
  }
}

/// A run in the Ink style: one row of the runs table, as in a paper. Its
/// name, where it runs, a small curve with its progress, and the loss; a
/// crash gets a dagger pointing to a footnote under the table.
class JournalRunRow extends StatelessWidget {
  const JournalRunRow({super.key, required this.run, this.onTap, this.selected, this.ranking});

  final Run run;
  final VoidCallback? onTap;
  final bool? selected;

  /// Ordered by a metric, the last column holds it, the best in bold as in
  /// a paper's results table, and the rank comes before the name.
  final RunRanking? ranking;

  /// The widths of the Progress and Loss columns, shared with the table's
  /// header row.
  static const progressWidth = 84.0;
  static const lossWidth = 60.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final crashed = run.status == RunStatus.crashed;
    final small = theme.textTheme.bodySmall;
    final shown = rankedFigure(run, ranking);
    final rank = ranking?.score.rank;
    final progress = switch (run.status) {
      RunStatus.live => 'ep. ${run.currentEpoch}/${run.totalEpochs}',
      RunStatus.finished => 'finished',
      RunStatus.crashed => 'crashed',
    };

    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ?? false ? scheme.secondaryContainer : null,
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                if (selected case final isSelected?) ...[
                  Icon(
                    isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 18,
                    color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            if (rank != null)
                              TextSpan(
                                text: '$rank. ',
                                semanticsLabel: rank == 1 ? 'Best, ' : 'Rank $rank, ',
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            TextSpan(text: run.name),
                            if (crashed && run.statusMessage != null)
                              const TextSpan(text: '†', style: TextStyle(fontSize: 11)),
                          ],
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.primary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        run.host,
                        style: small?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: progressWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Sparkline(
                        values: run.lossPreview,
                        color: crashed ? scheme.error : scheme.onSurface,
                        height: 16,
                        strokeWidth: 1,
                        semanticLabel: 'Loss curve, ${trendOf(run.lossPreview)}',
                      ),
                      Text(
                        progress,
                        semanticsLabel: run.status == RunStatus.live
                            ? '${run.status.label}, $progress'
                            : progress,
                        style: small?.copyWith(color: crashed ? scheme.error : null),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: lossWidth,
                  child: Text(
                    shown?.text ?? '–',
                    semanticsLabel: shown?.semantics,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: AppText.tabular,
                      fontWeight: rank == 1 ? FontWeight.w700 : null,
                      color: crashed
                          ? scheme.error
                          : shown?.missing ?? false
                          ? scheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
