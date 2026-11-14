import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import 'style_decor.dart';

/// The flat panel used for every block of content: a light surface, a
/// hairline border and small corners, titled with a [SectionLabel].
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(16),
    this.selected,
  });

  final String? title;

  /// Shown on the right of the title row (e.g. a latest value or a legend).
  final Widget? trailing;

  final Widget child;
  final VoidCallback? onTap;

  /// E.g. to start picking cards, with this one picked.
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;

  /// Non-null for a card that can be picked (e.g. runs to compare): a
  /// picked card gets a crimson outline, and screen readers announce the
  /// state.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasHeader = title != null || trailing != null;
    final style = AppTheme.styleOf(context);
    final isSelected = selected ?? false;
    // In Ink a panel is a section of the page: no fill, no border, its text
    // in line with the page's. A picked one gets a rule in the margin.
    final journal = style == AppStyle.ink;
    final inset = padding.resolve(Directionality.of(context));

    Widget card = Material(
      color: journal ? Colors.transparent : scheme.surfaceContainerLow,
      shape: journal
          ? Border(left: isSelected ? BorderSide(color: scheme.primary, width: 3) : BorderSide.none)
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusOf(context)),
              side: isSelected
                  ? BorderSide(color: scheme.primary, width: 2)
                  : BorderSide(color: scheme.outlineVariant),
            ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: journal
              ? EdgeInsets.fromLTRB(isSelected ? 12 : 0, inset.top, 0, inset.bottom)
              : padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasHeader) ...[
                // The title on the left and [trailing] on the right; on a
                // narrow screen, a wide [trailing] drops below the title.
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (title != null) SectionLabel(title!) else const SizedBox.shrink(),
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

    // Lab panels have viewfinder marks on two corners.
    if (style == AppStyle.lab) card = CornerMarks(color: scheme.primary, child: card);

    // A tappable card is one control for screen readers: one focus stop that
    // reads all of its text, announced as a button.
    if (onTap == null) return card;
    return MergeSemantics(
      child: Semantics(button: true, selected: selected, child: card),
    );
  }
}

/// A section heading. Paper: crimson after a short crimson bar, in sentence
/// case since some titles are long and read like data ("Step 7,000"). Ink:
/// a bold heading, as in a paper. Lab: small grey capitals, as on an
/// instrument panel.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    switch (AppTheme.styleOf(context)) {
      case AppStyle.ink:
        return Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
        );
      case AppStyle.lab:
        return Text(
          text.toUpperCase(),
          semanticsLabel: text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w500,
          ),
        );
      case AppStyle.paper:
        break;
    }
    return Container(
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.primary, width: 2)),
      ),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      ),
    );
  }
}
