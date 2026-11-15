import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/features/farm/farm_settings.dart';
import 'package:soliton/features/farm/farm_sky.dart';
import 'package:soliton/features/farm/farm_world.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/shared/clock.dart';

import 'test_app.dart';

List<Run> _runs() => [for (final mock in buildMockRuns(DateTime(2026, 11, 13))) mock.run];

FarmWorld _world({FarmSky sky = FarmSky.day, Map<String, FarmAnimal> animals = const {}}) =>
    FarmWorld(seed: 3)
      ..resize(const Size(360, 600))
      ..setAnimals(animals)
      ..sync(_runs())
      ..setSky(sky);

void main() {
  group('sky', () {
    test('noon is day, midnight is night, and dusk fades in between', () {
      final day = DateTime(2026, 6, 21);
      expect(FarmSky.at(day.add(const Duration(hours: 13))).light, 1);
      expect(FarmSky.at(day).light, 0);
      final (_, sunset) = FarmSky.sunTimes(day, FarmHemisphere.north);
      // Minute by minute through dusk, the light only ever drops a little.
      var last = 1.0;
      var fading = false;
      for (var m = 0; m < 180; m++) {
        final t = day.add(Duration(minutes: ((sunset - 1.5) * 60).round() + m));
        final light = FarmSky.at(t).light;
        expect(light, lessThanOrEqualTo(last));
        expect(last - light, lessThan(0.05), reason: 'no jump at $t');
        fading |= light > 0.1 && light < 0.9;
        last = light;
      }
      expect(fading, isTrue);
      expect(last, 0);
    });

    test('winter days are short, summer ones long; the south has them the other way', () {
      double length(DateTime d, FarmHemisphere h) {
        final (rise, set) = FarmSky.sunTimes(d, h);
        return set - rise;
      }

      final june = DateTime(2026, 6, 21), december = DateTime(2026, 12, 21);
      expect(length(june, FarmHemisphere.north), greaterThan(15));
      expect(length(december, FarmHemisphere.north), lessThan(9.5));
      expect(length(december, FarmHemisphere.south), greaterThan(15));
      expect(FarmSky.seasonOf(december, FarmHemisphere.north), FarmSeason.winter);
      expect(FarmSky.seasonOf(december, FarmHemisphere.south), FarmSeason.summer);
      expect(FarmSky.seasonOf(DateTime(2026, 4, 2), FarmHemisphere.north), FarmSeason.spring);
      expect(FarmSky.seasonOf(DateTime(2026, 10, 2), FarmHemisphere.north), FarmSeason.autumn);
      // A winter afternoon at five is already dark.
      expect(FarmSky.at(DateTime(2026, 12, 21, 17, 15)).asleep, isTrue);
      expect(FarmSky.at(DateTime(2026, 6, 21, 17, 15)).light, 1);
    });

    test('always day or always night ignore the clock but keep the season', () {
      final midnight = DateTime(2026, 1, 10);
      final day = FarmSky.at(midnight, timeOfDay: FarmTimeOfDay.day);
      expect((day.light, day.season), (1.0, FarmSeason.winter));
      final night = FarmSky.at(DateTime(2026, 7, 1, 12), timeOfDay: FarmTimeOfDay.night);
      expect((night.light, night.season), (0.0, FarmSeason.summer));
    });
  });

  group('animals', () {
    test('saved as family=animal lines, ducks left out', () {
      const animals = {'FNO': FarmAnimal.beaver, 'VisionTransformer': FarmAnimal.moose};
      expect(FarmAnimals.decode(FarmAnimals.encode(animals)), animals);
      expect(FarmAnimals.decode('Bad\nGPT=bear\nX=unicorn'), {'GPT': FarmAnimal.bear});
      expect(FarmAnimals.decode(null), isEmpty);
    });

    test('everyone is a duck until a family is set to another animal', () {
      final world = _world();
      expect(world.ducks.every((d) => d.animal == FarmAnimal.duck), isTrue);
      final vit = world.ducks.firstWhere((d) => d.id == 'vit-small');
      final duckScale = vit.scale;

      world.setAnimals({'VisionTransformer': FarmAnimal.moose});
      expect(vit.animal, FarmAnimal.moose);
      expect(vit.scale, closeTo(duckScale * FarmAnimal.moose.size, 1e-9));
      expect(
        world.ducks.where((d) => d.id != vit.id).every((d) => d.animal == FarmAnimal.duck),
        isTrue,
      );
      // A moose keeps out of the pond, for all its wandering.
      for (var i = 0; i < 60 * 60; i++) {
        world.update(1 / 60);
        expect(vit.swimming, isFalse);
      }
      expect(world.hitTest(vit.centre), vit.id);
    });
  });

  group('night', () {
    test('at night the animals sleep and stay put; the one picked wakes up', () {
      final world = _world(sky: FarmSky.at(DateTime(2026, 7, 1, 1)));
      final before = {for (final d in world.ducks) d.id: d.position};
      for (var i = 0; i < 600; i++) {
        world.update(1 / 60);
      }
      expect(world.ducks.every((d) => d.asleep), isTrue);
      expect({for (final d in world.ducks) d.id: d.position}, before);

      world.select(world.ducks.first.id);
      expect(world.ducks.first.asleep, isFalse);
      expect(world.ducks.skip(1).every((d) => d.asleep), isTrue);

      world.setSky(FarmSky.at(DateTime(2026, 7, 1, 12)));
      expect(world.ducks.any((d) => d.asleep), isFalse);
    });

    test('each season brings its weather, which stays on the farm', () {
      for (final (month, kind) in [
        (4, FlakeKind.rain),
        (7, FlakeKind.firefly),
        (10, FlakeKind.leaf),
        (1, FlakeKind.snow),
      ]) {
        final world = _world(sky: FarmSky.at(DateTime(2026, month, 5, 12)));
        expect(world.flakes.map((f) => f.kind), contains(kind), reason: 'month $month');
        for (var i = 0; i < 600; i++) {
          world.update(1 / 60);
        }
        final bounds = (Offset.zero & world.layout.size).inflate(12);
        expect(world.flakes.every((f) => bounds.contains(f.position)), isTrue);
      }
      final winter = _world(sky: FarmSky.at(DateTime(2026, 1, 5, 12)));
      expect(winter.flakes.map((f) => f.kind).toSet(), {FlakeKind.snow});
    });
  });

  testWidgets('a family set to moose in Settings is a moose on the farm, asleep at night', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final store = MemorySettingsStore();
    await openApp(tester, '/settings', store);

    await tester.scrollUntilVisible(find.text('VisionTransformer'), 200, scrollable: visibleList());
    await tester.pumpAndSettle();
    final row = find.ancestor(of: find.text('VisionTransformer'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: row, matching: find.text('Duck')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moose').last);
    await tester.pumpAndSettle();
    expect(store.getString('farmAnimals'), 'VisionTransformer=moose');

    // Midnight in summer.
    containerOf(tester).read(clockProvider.notifier).state = DateTime(2026, 7, 1, 0, 30);
    routerOf(tester).go('/farm');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.semantics.byLabel(RegExp(r'^vit-small, moose')), findsOne);
    expect(find.textContaining('Summer, night'), findsOneWidget);
    expect(find.textContaining('VisionTransformer (moose)'), findsOneWidget);

    // The farm's own settings sheet can make it a duck again.
    await tester.tap(find.byTooltip('Farm settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make them all ducks'));
    await tester.pumpAndSettle();
    expect(store.getString('farmAnimals'), isNull);
    await tester.ensureVisible(find.text('Always day'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always day'));
    await tester.pumpAndSettle();
    expect(store.getString('farmTimeOfDay'), 'day');
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel(RegExp(r'^vit-small, duck')), findsOne);
    expect(find.textContaining('Summer, day'), findsOneWidget);
    semantics.dispose();
  });
}
