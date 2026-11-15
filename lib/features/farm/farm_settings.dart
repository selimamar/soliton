import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/settings_store.dart';
import 'farm_sky.dart';

/// The animals a finished run can be on the farm. Which one a run is
/// depends on its model family, chosen in the farm's settings; a duck
/// unless chosen otherwise.
enum FarmAnimal {
  duck('Duck', 'ducks', size: 1, centre: 24, head: Offset(9.5, 53), width: 32, speed: 1),
  moose('Moose', 'moose', size: 0.9, centre: 36, head: Offset(30, 74), width: 60, speed: 0.7),
  goose('Goose', 'geese', size: 0.95, centre: 30, head: Offset(17, 68), width: 38, speed: 0.9),
  beaver('Beaver', 'beavers', size: 1, centre: 12, head: Offset(17, 28), width: 52, speed: 0.75),
  bear('Bear', 'bears', size: 0.95, centre: 26, head: Offset(25, 52), width: 54, speed: 0.8);

  const FarmAnimal(
    this.label,
    this.plural, {
    required this.size,
    required this.centre,
    required this.head,
    required this.width,
    required this.speed,
  });

  final String label;

  /// For "FNO (moose)" in the farm's legend.
  final String plural;

  /// Drawn this much smaller or larger than a duck of the same model size,
  /// so a moose doesn't look like a bigger model than it is.
  final double size;

  /// How high its body's middle is above its feet, in drawing units (a
  /// duck is about 50 tall): where it's tapped and marked.
  final double centre;

  /// Over its head, where its label goes: forward and up from its feet.
  final Offset head;

  /// Its shadow's width on the ground.
  final double width;

  /// How fast it walks, relative to a duck.
  final double speed;

  /// Whether it swims in the pond (a moose and a bear stay on land).
  bool get swims => this == duck || this == goose || this == beaver;
}

/// Which animal each model family is on the farm, saved on the device as
/// `family=animal` pairs. Families not in it are ducks.
final farmAnimalsProvider = NotifierProvider<FarmAnimals, Map<String, FarmAnimal>>(FarmAnimals.new);

class FarmAnimals extends Notifier<Map<String, FarmAnimal>> {
  static const key = 'farmAnimals';

  @override
  Map<String, FarmAnimal> build() => decode(ref.watch(settingsStoreProvider).getString(key));

  /// Makes [family] a [animal]; a duck takes it off the list.
  void set(String family, FarmAnimal animal) {
    final next = {...state}..remove(family);
    if (animal != FarmAnimal.duck) next[family] = animal;
    _save(next);
  }

  /// Every family back to a duck.
  void reset() => _save(const {});

  void _save(Map<String, FarmAnimal> value) {
    state = value;
    ref.read(settingsStoreProvider).setString(key, value.isEmpty ? null : encode(value)).ignore();
  }

  /// `FNO=beaver\nResNet=bear`: one per line, since a family name (a
  /// Python class name) never has a newline or an `=`.
  static String encode(Map<String, FarmAnimal> value) =>
      [for (final MapEntry(:key, :value) in value.entries) '$key=${value.name}'].join('\n');

  static Map<String, FarmAnimal> decode(String? saved) {
    final animals = FarmAnimal.values.asNameMap();
    return {
      for (final line in (saved ?? '').split('\n'))
        if (line.lastIndexOf('=') case final i when i > 0)
          line.substring(0, i): ?animals[line.substring(i + 1)],
    };
  }
}

/// Whether the farm's light follows the clock.
final farmTimeOfDayProvider = NotifierProvider<Setting<FarmTimeOfDay>, FarmTimeOfDay>(
  () => Setting.choice('farmTimeOfDay', FarmTimeOfDay.clock, FarmTimeOfDay.values),
);

/// The farm's hemisphere, for its seasons and day length.
final farmHemisphereProvider = NotifierProvider<Setting<FarmHemisphere>, FarmHemisphere>(
  () => Setting.choice('farmHemisphere', FarmHemisphere.north, FarmHemisphere.values),
);
