import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../shared/widgets/async_value_view.dart';
import '../../../shared/widgets/spaced_list_view.dart';
import '../widgets/layer_card.dart';
import '../widgets/layer_detail_sheet.dart';

/// One card per layer with its activation distribution and gradient norm.
/// Tapping a card opens the full statistics for that layer.
class LayersTab extends ConsumerWidget {
  const LayersTab({super.key, required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncValueView(
      value: ref.watch(layerStatsProvider(runId)),
      onRetry: () => ref.invalidate(layerStatsProvider(runId)),
      data: (layers) {
        if (layers.isEmpty) {
          return const Center(child: Text('This run has no layer statistics'));
        }
        return SpacedListView(
          children: [
            for (final layer in layers)
              LayerCard(stats: layer, onTap: () => showLayerDetailSheet(context, layer)),
          ],
        );
      },
    );
  }
}
