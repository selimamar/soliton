import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../chart_settings.dart';

/// Chart options above a list of charts: steps or epochs on the x-axis,
/// and a log scale. Both are saved settings.
class ChartControls extends ConsumerWidget {
  const ChartControls({super.key, this.showXAxis = true, this.epochsAvailable = true});

  final bool showXAxis;

  /// False for runs that don't say how many epochs they have.
  final bool epochsAvailable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unit = epochsAvailable ? ref.watch(xAxisUnitProvider) : XAxisUnit.steps;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showXAxis)
          SegmentedButton<XAxisUnit>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: XAxisUnit.steps, label: Text('Steps')),
              ButtonSegment(
                value: XAxisUnit.epochs,
                label: const Text('Epochs'),
                enabled: epochsAvailable,
              ),
            ],
            selected: {unit},
            onSelectionChanged: (selection) =>
                ref.read(xAxisUnitProvider.notifier).set(selection.first),
          ),
        FilterChip(
          label: const Text('Log scale'),
          selected: ref.watch(logScaleProvider),
          onSelected: (value) => ref.read(logScaleProvider.notifier).set(value),
        ),
      ],
    );
  }
}
