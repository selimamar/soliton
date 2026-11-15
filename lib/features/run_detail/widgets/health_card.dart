import 'package:material_ui/material_ui.dart';

import '../../../app/theme.dart';
import '../../../models/health_warning.dart';
import '../../../models/run.dart';

/// What the logger saw go wrong in training: a NaN loss, a diverging loss or
/// exploding gradients, each with what usually helps. Shown at the top of a
/// run's Overview; nothing for a healthy run.
class HealthCard extends StatelessWidget {
  const HealthCard({super.key, required this.run});

  final Run run;

  static bool showsFor(Run run) => run.health.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Amber, as for a waiting job: a warning, not (yet) a crash.
    final accent = RunStatus.queued.color(scheme);
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.10), scheme.surface),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(AppTheme.radiusOf(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, warning) in run.health.indexed) ...[
                  if (i > 0) const SizedBox(height: 10),
                  Text(
                    warning.kind.label,
                    style: theme.textTheme.titleSmall?.copyWith(color: accent),
                  ),
                  const SizedBox(height: 2),
                  Text(warning.message, style: theme.textTheme.bodyMedium),
                  Text(_advice(warning.kind), style: small),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _advice(HealthKind kind) => switch (kind) {
    HealthKind.nan =>
      'Usually a learning rate too high or an unstable operation. '
          'stop_on_divergence=True ends such a run by itself.',
    HealthKind.divergence =>
      'Often a learning rate too high for this stage: restart from an earlier checkpoint '
          'with a lower one.',
    HealthKind.gradient => 'Clip the gradients (clip_grad_norm_) or lower the learning rate.',
  };
}
