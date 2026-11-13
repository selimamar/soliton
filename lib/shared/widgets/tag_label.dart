import 'package:material_ui/material_ui.dart';

/// A run's tag, shown small and read-only (e.g. on a run card).
class TagLabel extends StatelessWidget {
  const TagLabel(this.tag, {super.key});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        tag,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}
