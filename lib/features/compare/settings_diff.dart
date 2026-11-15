import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../models/run.dart';
import '../../shared/widgets/section_card.dart';

/// The hyperparameters of [runs] that differ (a setting some runs don't have
/// counts as differing), in the order they first appear, and how many are the
/// same in all of them.
({List<String> differ, List<String> same}) diffSettings(List<Run> runs) {
  // Every setting once, in the order the runs first list them.
  final keys = <String>{for (final run in runs) ...run.hyperparameters.keys}.toList();
  final differ = <String>[], same = <String>[];
  for (final key in keys) {
    final values = {for (final run in runs) run.hyperparameters[key]};
    (values.length == 1 && values.single != null ? same : differ).add(key);
  }
  return (differ: differ, same: same);
}

/// Compare's "Settings that differ": one column per run, only the
/// hyperparameters that aren't the same in all of them, so what changed
/// between the curves is plain. The rest fold away behind a button.
class SettingsDiffCard extends StatefulWidget {
  const SettingsDiffCard({
    super.key,
    required this.runs,
    required this.labels,
    required this.colors,
  });

  final List<Run> runs;
  final List<String> labels;
  final List<Color> colors;

  @override
  State<SettingsDiffCard> createState() => _SettingsDiffCardState();
}

class _SettingsDiffCardState extends State<SettingsDiffCard> {
  var _showSame = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final (:differ, :same) = diffSettings(widget.runs);
    if (differ.isEmpty && same.isEmpty) return const SizedBox.shrink();
    final rows = [
      for (final key in differ) (key, true),
      if (_showSame)
        for (final key in same) (key, false),
    ];
    final mono = AppText.mono(context).copyWith(fontSize: 12);
    // Left-aligned at its own width, not stretched across the column.
    Widget cell(String text, {TextStyle? style}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Align(alignment: Alignment.centerLeft, child: Text(text, style: style)),
    );
    return SectionCard(
      title: 'Settings that differ',
      trailing: Text(same.isEmpty ? 'none the same' : '${same.length} the same', style: muted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (differ.isEmpty)
            Text(
              'All ${same.length} settings are the same: the difference is elsewhere '
              '(data, seed, code).',
              style: theme.textTheme.bodyMedium,
            ),
          if (rows.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
                    ),
                    children: [
                      cell('Setting', style: muted),
                      for (final (i, label) in widget.labels.indexed)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: widget.colors[i],
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(label, style: theme.textTheme.labelMedium),
                            ],
                          ),
                        ),
                    ],
                  ),
                  for (final (key, differs) in rows)
                    TableRow(
                      children: [
                        cell(key, style: differs ? theme.textTheme.bodyMedium : muted),
                        for (final run in widget.runs)
                          cell(
                            run.hyperparameters[key] ?? '—',
                            style: differs ? mono.copyWith(fontWeight: FontWeight.w600) : mono,
                          ),
                      ],
                    ),
                ],
              ),
            ),
          if (same.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _showSame = !_showSame),
                child: Text(
                  _showSame
                      ? 'Hide the ${same.length} the same'
                      : 'Show the ${same.length} the same',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
