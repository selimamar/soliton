import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import 'style_decor.dart';

/// A label on the left and its value on the right (e.g. a system figure).
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                fontFeatures: AppText.tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings such as hyperparameters.
///
/// Paper: each label small above its value in monospace, so long values
/// (`CrossEntropyLoss(label_smoothing=0.1)`) wrap cleanly; short ones pair
/// up two to a row. Ink: a numbered table between rules, as in a paper. Lab:
/// config-file lines, `batch_size ........ 256`.
class KeyValueGrid extends StatelessWidget {
  const KeyValueGrid({super.key, required this.entries, this.caption});

  final Map<String, String> entries;

  /// Ink only: the table's caption, e.g. "Table 1. Settings of this run."
  final String? caption;

  /// Values up to this many characters fit in half the width on a phone.
  static const _shortValue = 18;

  @override
  Widget build(BuildContext context) => switch (AppTheme.styleOf(context)) {
    AppStyle.paper => _grid(context),
    AppStyle.ink => _table(context),
    AppStyle.lab => _config(context),
  };

  Widget _grid(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final valueStyle = AppText.mono(context);
    const gap = 16.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final full = constraints.maxWidth;
        final half = (full - gap) / 2;
        return Wrap(
          spacing: gap,
          children: [
            for (final MapEntry(key: label, value: value) in entries.entries)
              Container(
                width: value.length <= _shortValue && label.length <= 24 ? half : full,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
                ),
                child: MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: labelStyle),
                      const SizedBox(height: 2),
                      Text(value, style: valueStyle),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _table(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium;
    final thick = BorderSide(color: scheme.onSurface, width: 1.2);
    final thin = BorderSide(color: scheme.onSurface, width: 0.6);

    Widget row(String label, String value, {TextStyle? style, Border? border}) => Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: border == null ? null : BoxDecoration(border: border),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(label, style: style)),
            const SizedBox(width: 16),
            Flexible(
              child: Text(value, textAlign: TextAlign.end, style: style),
            ),
          ],
        ),
      ),
    );

    final rows = entries.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption case final text?) ...[
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: 'Table 1. ',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(text: text),
              ],
            ),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
        ],
        row(
          'Setting',
          'Value',
          style: body?.copyWith(fontWeight: FontWeight.w500),
          border: Border(top: thick, bottom: thin),
        ),
        for (final (i, MapEntry(key: label, value: value)) in rows.indexed)
          row(
            label,
            scientific(value),
            style: body,
            border: i == rows.length - 1 ? Border(bottom: thick) : null,
          ),
      ],
    );
  }

  Widget _config(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final keyStyle = AppText.mono(context).copyWith(color: scheme.onSurfaceVariant, fontSize: 12);
    final valueStyle = AppText.mono(context).copyWith(fontSize: 12);
    String snake(String label) =>
        label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');

    return Column(
      children: [
        for (final MapEntry(key: label, value: value) in entries.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: MergeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(snake(label), semanticsLabel: label, style: keyStyle),
                  const SizedBox(width: 6),
                  const Expanded(child: DottedLeader()),
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 3,
                    child: Text(value, textAlign: TextAlign.end, style: valueStyle),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
