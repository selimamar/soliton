import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../models/run.dart';
import '../formatters.dart';

/// "↓ 0.012": how a run's loss moved recently ([Run.recentLossChange]),
/// green when it fell and in the alert colour when it rose. Empty when there is no
/// clear change.
class LossChange extends StatelessWidget {
  const LossChange({super.key, required this.run, this.style, this.suffix = ''});

  final Run run;
  final TextStyle? style;

  /// Appended to the figure, e.g. " over the last 10%".
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final change = run.recentLossChange;
    if (change == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final falling = change < 0;
    final size = formatMetric(change.abs());
    // Lab writes it like an instrument, "Δ −0.065", with no words.
    final lab = AppTheme.styleOf(context) == AppStyle.lab;
    return Text(
      lab ? 'Δ ${falling ? '−' : '+'}$size' : '${falling ? '↓' : '↑'} $size$suffix',
      semanticsLabel: 'loss ${falling ? 'down' : 'up'} $size recently',
      style: (style ?? const TextStyle()).copyWith(
        fontFeatures: AppText.tabular,
        color: falling ? RunStatus.live.color(scheme) : scheme.error,
      ),
    );
  }
}
