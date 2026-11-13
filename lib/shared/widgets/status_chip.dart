import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../models/run.dart';

/// A run's status as a coloured mark and small capitals: "● LIVE" in Paper,
/// a square light in Lab, plain small capitals in Ink.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.inHeader = false});

  final RunStatus status;

  /// Whether it sits in the app bar, which is dark in Lab whatever the theme.
  final bool inHeader;

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.styleOf(context);
    var scheme = Theme.of(context).colorScheme;
    if (inHeader && AppTheme.headerColorsOf(context).dark) {
      scheme = AppTheme.of(style, Brightness.dark).colorScheme;
    }
    final color = status.color(scheme);
    final label = Text(
      AppText.eyebrowCase(status.label),
      semanticsLabel: status.label,
      style: AppText.eyebrow(scheme, color: color).copyWith(
        letterSpacing: style == AppStyle.ink ? 0.8 : null,
        fontWeight: style == AppStyle.ink ? FontWeight.w500 : null,
      ),
    );
    if (style == AppStyle.ink) return label;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            shape: style == AppStyle.lab ? BoxShape.rectangle : BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        label,
      ],
    );
  }
}
