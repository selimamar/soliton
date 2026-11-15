import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../data/providers.dart';
import '../../../models/run.dart';
import '../../../shared/widgets/section_card.dart';
import '../resource_fit.dart';
import '../system_usage.dart';

/// What an ended Slurm job asked for against what it used, and what to ask
/// for next time (see [ResourceFit]). Nothing for a run that isn't one.
class ResourcesCard extends ConsumerWidget {
  const ResourcesCard({super.key, required this.run});

  final Run run;

  /// Whether it can show anything, before its metrics load (so a list
  /// leaves no gap for it).
  static bool showsFor(Run run) => switch (run.system) {
    final system? when run.status == RunStatus.finished || run.status == RunStatus.crashed =>
      (system.slurm['jobId'] != null || system.timeLimitAt != null) &&
          // Something it can compare: a time limit to the time taken, or
          // the memory, CPUs or GPUs it asked for to what it used.
          ((system.timeLimitAt != null && run.endedAt != null) ||
              system.memoryGb != null ||
              system.cpuCores != null ||
              system.gpus.isNotEmpty),
    _ => false,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(runMetricsProvider(run.id)).value ?? const {};
    final fit = ResourceFit.of(run, SystemUsage.from(metrics));
    if (fit == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final command = fit.flags.join(' ');
    return SectionCard(
      title: 'Resources',
      trailing: Text('used of asked for', style: muted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final row in fit.rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 104,
                    child: Text(
                      row.label,
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.used, style: theme.textTheme.bodyMedium),
                        if (row.advice case final advice?)
                          Text(
                            advice,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: row.warning ? scheme.error : scheme.onSurfaceVariant,
                              fontWeight: row.warning ? FontWeight.w600 : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (command.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Next time, ask for', style: muted),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    command,
                    style: AppText.mono(context).copyWith(fontSize: 13),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 20),
                  tooltip: 'Copy',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: command));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text('Copied $command')));
                  },
                ),
              ],
            ),
            Text('Smaller requests usually start sooner.', style: muted),
          ],
        ],
      ),
    );
  }
}
