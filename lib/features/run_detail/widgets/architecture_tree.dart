import 'package:material_ui/material_ui.dart';

import '../../../models/layer_info.dart';
import '../../../shared/formatters.dart';

/// The model's modules as a collapsible tree. Each row shows the module's
/// parameter count and its share of the whole model.
class ArchitectureTree extends StatelessWidget {
  const ArchitectureTree({super.key, required this.root});

  final LayerInfo root;

  @override
  Widget build(BuildContext context) {
    final total = root.totalParameters;
    return Column(
      children: [
        for (final layer in root.children)
          _LayerNode(layer: layer, modelParameters: total, depth: 0),
      ],
    );
  }
}

class _LayerNode extends StatelessWidget {
  const _LayerNode({required this.layer, required this.modelParameters, required this.depth});

  final LayerInfo layer;
  final int modelParameters;
  final int depth;

  static const _indent = 16.0;

  @override
  Widget build(BuildContext context) {
    final row = _LayerRow(layer: layer, modelParameters: modelParameters);

    if (layer.isLeaf) {
      return Padding(
        // Right padding lines leaf rows up with the expand arrow of groups.
        padding: EdgeInsets.fromLTRB(depth * _indent, 10, 40, 10),
        child: row,
      );
    }

    return ExpansionTile(
      tilePadding: EdgeInsets.only(left: depth * _indent),
      childrenPadding: EdgeInsets.zero,
      // Empty borders: no divider lines above and below an expanded group.
      shape: const Border(),
      collapsedShape: const Border(),
      title: row,
      children: [
        for (final child in layer.children)
          _LayerNode(layer: child, modelParameters: modelParameters, depth: depth + 1),
      ],
    );
  }
}

class _LayerRow extends StatelessWidget {
  const _LayerRow({required this.layer, required this.modelParameters});

  final LayerInfo layer;
  final int modelParameters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = modelParameters == 0 ? 0.0 : layer.totalParameters / modelParameters;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                layer.name,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                layer.type,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(formatCount(layer.totalParameters), style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            SizedBox(
              width: 56,
              child: LinearProgressIndicator(
                value: share,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                // Without a label this would be announced as "progress".
                semanticsLabel: 'Share of model parameters',
                semanticsValue: formatPercent(share),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
