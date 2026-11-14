import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../selection.dart';
import 'delete_dialog.dart';

/// The app bar of a list while picking items in it: how many are picked,
/// pick all (or none) of those shown, delete the picked ones, and
/// [trailing] (e.g. Compare).
AppBar pickingAppBar(
  BuildContext context, {
  required DeleteKind kind,
  required List<String> picked,
  required List<String> shown,
  required Selection selection,
  required Deletable Function(String id) describe,
  List<Widget> trailing = const [],
}) {
  final all = shown.isNotEmpty && shown.every(picked.contains);
  return AppBar(
    // Room for the count beside the buttons on a phone.
    titleSpacing: 0,
    leading: IconButton(
      icon: const Icon(Icons.close),
      tooltip: 'Stop picking',
      onPressed: selection.cancel,
    ),
    title: Text(picked.isEmpty ? 'Pick ${kind.plural}' : '${picked.length} picked'),
    actions: [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: all ? 'Pick none' : 'Pick all shown',
        onPressed: shown.isEmpty ? null : () => selection.toggleAll(shown),
      ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete picked ${kind.plural}',
        onPressed: picked.isEmpty
            ? null
            : () async {
                final done = await confirmAndDelete(
                  context,
                  kind: kind,
                  items: [for (final id in picked) describe(id)],
                );
                if (done) selection.cancel();
              },
      ),
      ...trailing,
      if (trailing.isEmpty) const SizedBox(width: 4),
    ],
  );
}

/// A tick before a card's name while picking: filled when picked.
class PickMark extends StatelessWidget {
  const PickMark({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// A card's outline when picked, in the style's corner radius.
ShapeBorder? pickedCardShape(BuildContext context, {required bool? selected}) => selected == true
    ? RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusOf(context)),
        side: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
      )
    : null;
