import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/providers.dart';
import 'farm_settings.dart';
import 'farm_sky.dart';
import 'farm_world.dart';

/// Opens the farm's settings in a sheet, from the farm.
Future<void> showFarmSettings(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.7,
    minChildSize: 0.4,
    maxChildSize: 0.95,
    builder: (context, scrollController) => ListView(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      children: const [FarmSettingsSection()],
    ),
  ),
);

/// The farm's settings: which animal each model family is, and how its
/// light and seasons follow the clock. Only on the farm, in a sheet from
/// its app bar (not in the app's Settings).
class FarmSettingsSection extends ConsumerWidget {
  const FarmSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final animals = ref.watch(farmAnimalsProvider);
    final runs = ref.watch(runsProvider).value ?? const [];
    // The families in the runs, and any set earlier that aren't there now.
    final counts = <String, int>{};
    for (final run in runs) {
      if (FarmWorld.familyOf(run) case final family?) {
        counts[family] = (counts[family] ?? 0) + 1;
      }
    }
    final families = {...counts.keys, ...animals.keys}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final note = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('Farm animals', style: theme.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            families.isEmpty
                ? 'Finished runs are ducks. Runs that log their model '
                      '(run.watch(model)) can be other animals, by model family.'
                : 'Finished runs of each model family are this animal on the farm. '
                      'Families not listed are ducks.',
            style: note,
          ),
        ),
        for (final family in families)
          ListTile(
            title: Text(family, overflow: TextOverflow.ellipsis),
            subtitle: Text(switch (counts[family] ?? 0) {
              0 => 'No runs now',
              1 => '1 run',
              final n => '$n runs',
            }),
            trailing: DropdownButton<FarmAnimal>(
              value: animals[family] ?? FarmAnimal.duck,
              underline: const SizedBox.shrink(),
              items: [
                for (final animal in FarmAnimal.values)
                  DropdownMenuItem(value: animal, child: Text(animal.label)),
              ],
              onChanged: (animal) {
                if (animal != null) ref.read(farmAnimalsProvider.notifier).set(family, animal);
              },
            ),
          ),
        if (animals.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton(
                onPressed: () => ref.read(farmAnimalsProvider.notifier).reset(),
                child: const Text('Make them all ducks'),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Day and night', style: theme.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'The farm follows the clock: it gets dark after sunset and the animals '
            'sleep. Sunrise, sunset and the season follow the date.',
            style: note,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: SegmentedButton<FarmTimeOfDay>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: FarmTimeOfDay.clock, label: Text('Clock')),
              ButtonSegment(value: FarmTimeOfDay.day, label: Text('Always day')),
              ButtonSegment(value: FarmTimeOfDay.night, label: Text('Always night')),
            ],
            selected: {ref.watch(farmTimeOfDayProvider)},
            onSelectionChanged: (v) => ref.read(farmTimeOfDayProvider.notifier).set(v.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Hemisphere, for the seasons', style: theme.textTheme.bodyMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: SegmentedButton<FarmHemisphere>(
            showSelectedIcon: false,
            segments: [
              for (final h in FarmHemisphere.values) ButtonSegment(value: h, label: Text(h.label)),
            ],
            selected: {ref.watch(farmHemisphereProvider)},
            onSelectionChanged: (v) => ref.read(farmHemisphereProvider.notifier).set(v.first),
          ),
        ),
      ],
    );
  }
}
