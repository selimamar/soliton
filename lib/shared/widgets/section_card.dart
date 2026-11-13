import 'package:material_ui/material_ui.dart';

/// The rounded, softly tinted card used for every block of content.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.selected,
  });

  final String? title;

  /// Shown on the right of the title row (e.g. a latest value or a legend).
  final Widget? trailing;

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// Non-null for a card that can be picked (e.g. runs to compare): a
  /// picked card gets an outline, and screen readers announce the state.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasHeader = title != null || trailing != null;

    final card = Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected ?? false
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasHeader) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title ?? '',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: 12),
              ],
              child,
            ],
          ),
        ),
      ),
    );

    // A tappable card is one control for screen readers: one focus stop that
    // reads all of its text, announced as a button.
    if (onTap == null) return card;
    return MergeSemantics(
      child: Semantics(button: true, selected: selected, child: card),
    );
  }
}
