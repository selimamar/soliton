import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';

/// A small label + big value block, e.g. "Parameters / 23.5M".
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon});

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppTheme.radiusOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 14, color: muted), const SizedBox(width: 4)],
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: AppText.tabular,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// A few figures in one bordered row, split by hairlines, e.g. progress,
/// epoch, elapsed and remaining. Lighter than a tile per figure. In Lab,
/// four figures make a two-by-two readout; in Ink, the row sits between two
/// rules like a table in a paper.
class StatStrip extends StatelessWidget {
  const StatStrip({super.key, required this.stats, this.footer});

  /// (label, value) pairs, left to right.
  final List<(String, String)> stats;

  /// Shown under the figures, inside the border (e.g. a progress line).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = AppTheme.styleOf(context);
    final hairline = BorderSide(color: scheme.outlineVariant);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontStyle: style == AppStyle.ink ? FontStyle.italic : null,
      letterSpacing: style == AppStyle.lab ? 1 : null,
    );
    final valueStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: AppText.tabular,
    );

    Widget cell(String label, String value, {bool left = false, bool top = false}) => Container(
      padding: EdgeInsets.fromLTRB(style == AppStyle.ink && !left ? 0 : 12, 10, 8, 10),
      decoration: left || top
          ? BoxDecoration(
              border: Border(
                left: left ? hairline : BorderSide.none,
                top: top ? hairline : BorderSide.none,
              ),
            )
          : null,
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              style == AppStyle.lab ? label.toUpperCase() : label,
              semanticsLabel: label,
              style: labelStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(value, style: valueStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );

    // Each figure after the first in a row gets a hairline on its left (not
    // in Ink, where columns are split by space alone).
    Widget row(List<(String, String)> figures, {bool top = false}) => Row(
      children: [
        for (final (i, (label, value)) in figures.indexed)
          Expanded(
            child: cell(label, value, left: i > 0 && style != AppStyle.ink, top: top),
          ),
      ],
    );

    final figures = style == AppStyle.lab && stats.length == 4
        ? [row(stats.sublist(0, 2)), row(stats.sublist(2), top: true)]
        : [row(stats)];

    final rule = BorderSide(color: scheme.onSurface, width: 1.2);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: style == AppStyle.ink
          ? BoxDecoration(
              border: Border(top: rule, bottom: rule),
            )
          : BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border.fromBorderSide(hairline),
              borderRadius: BorderRadius.circular(AppTheme.radiusOf(context)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...figures, ?footer],
      ),
    );
  }
}
