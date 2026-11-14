import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/app/theme.dart';
import 'package:models_app/data/mock/mock_runs.dart';
import 'package:models_app/features/farm/farm_painter.dart';
import 'package:models_app/features/farm/farm_world.dart';
import 'package:models_app/features/settings/settings_providers.dart';
import 'package:models_app/models/run.dart';

import 'test_app.dart';

List<Run> _runs() => [for (final mock in buildMockRuns(DateTime(2026, 11, 13))) mock.run];

Run _finished(Run run) => Run.fromJson({...run.toJson(), 'status': 'finished'});

FarmWorld _world(List<Run> runs, {bool animate = true}) => FarmWorld(seed: 3, animate: animate)
  ..resize(const Size(360, 600))
  ..sync(runs);

/// A figure's label in the run's sheet (Lab writes them in capitals).
Finder _figure(String label) =>
    find.byWidgetPredicate((w) => w is Text && w.data?.toLowerCase() == label.toLowerCase());

/// Farm tests run with reduced motion unless they say otherwise: the ducks
/// then stand still, so `pumpAndSettle` settles.
void _reduceMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
    disableAnimations: true,
  );
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void main() {
  test('ducks grow with their parameter count, within bounds', () {
    final sizes = [
      for (final p in [0, 600000, 2400000, 23500000, 1000000000]) FarmWorld.scaleFor(p),
    ];
    for (var i = 1; i < sizes.length; i++) {
      expect(sizes[i], greaterThanOrEqualTo(sizes[i - 1]));
    }
    expect(sizes.first, 0.7);
    expect(sizes.last, 1.6);
  });

  test('finished runs are ducks, live and crashed ones eggs', () {
    final runs = _runs();
    final world = _world(runs);
    expect(world.ducks.length, runs.where((r) => r.status == RunStatus.finished).length);
    expect(world.eggs.length, runs.where((r) => r.status != RunStatus.finished).length);
    for (final egg in world.eggs) {
      expect(world.layout.nest.inflate(16).contains(egg.position), isTrue, reason: egg.id);
    }
  });

  test('a run that finishes hatches out of its egg', () {
    final runs = _runs();
    final world = _world(runs);
    final live = runs.firstWhere((r) => r.status == RunStatus.live);
    final ducks = world.ducks.length;

    world.sync([for (final run in runs) run.id == live.id ? _finished(run) : run]);
    expect(world.eggs.map((e) => e.id), isNot(contains(live.id)));
    expect(world.ducks.length, ducks + 1);
    final chick = world.ducks.firstWhere((d) => d.id == live.id);
    expect(chick.pop, 0, reason: 'it pops out of the shell');
    expect(world.shards, hasLength(2));

    for (var i = 0; i < 60; i++) {
      world.update(1 / 60);
    }
    expect(chick.pop, 1);
    expect(world.shards, isEmpty);
  });

  test('ducks stay on the farm and stand still when selected', () {
    final world = _world(_runs());
    final picked = world.ducks.first;
    world.select(picked.id);
    final where = picked.position;
    final bounds = Offset.zero & world.layout.size;
    for (var i = 0; i < 60 * 60; i++) {
      world.update(1 / 60);
      for (final duck in world.ducks) {
        expect(bounds.contains(duck.position), isTrue, reason: '${duck.id} at ${duck.position}');
      }
    }
    expect(picked.position, where);
    expect(world.ducks.any((d) => d.swimming || d.position != d.target), isTrue);
  });

  test('without motion, ducks stand in rows inside the pasture', () {
    final world = _world(_runs(), animate: false);
    for (final duck in world.ducks) {
      expect(world.layout.pasture.contains(duck.position), isTrue, reason: duck.id);
    }
    final before = [for (final d in world.ducks) d.position];
    world.update(1);
    expect([for (final d in world.ducks) d.position], before);
  });

  test("ducks keep clear of a phone's gesture bar", () {
    final world = FarmWorld(seed: 3)
      ..resize(const Size(360, 600), bottomInset: 34)
      ..sync(_runs());
    for (var i = 0; i < 60 * 30; i++) {
      world.update(1 / 60);
      for (final duck in world.ducks) {
        expect(duck.position.dy, lessThanOrEqualTo(600 - 34), reason: duck.id);
      }
    }
  });

  test('a tap finds the duck or egg under it, with room for a thumb', () {
    final world = _world(_runs(), animate: false);
    final duck = world.ducks.first;
    expect(world.hitTest(duck.centre.translate(20, 0)), duck.id);
    expect(world.hitTest(world.eggs.first.centre), world.eggs.first.id);
    expect(world.hitTest(const Offset(-100, -100)), isNull);
  });

  for (final style in AppStyle.values) {
    testWidgets('the farm opens from the runs list and leads to a run (${style.label})', (
      tester,
    ) async {
      _reduceMotion(tester);
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await openApp(tester);
      containerOf(tester).read(appStyleProvider.notifier).set(style);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Farm: runs as ducks and eggs'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/farm');
      expect(tester.takeException(), isNull);

      // A finished run is a duck; tapping it brings up its figures.
      tester.semantics.tap(find.semantics.byLabel(RegExp(r'^vit-small, duck')));
      await tester.pumpAndSettle();
      expect(_figure('Final loss'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.bySemanticsLabel('Open full analysis'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/runs/vit-small');

      // A live run is an egg, and leads to its metrics.
      routerOf(tester).go('/farm');
      await tester.pumpAndSettle();
      tester.semantics.tap(find.semantics.byLabel(RegExp(r'^resnet50-cifar, egg')));
      await tester.pumpAndSettle();
      expect(_figure('Hatches in'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Watch it train'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/runs/resnet50-cifar?tab=metrics');
      semantics.dispose();
    });
  }

  testWidgets('a finger on an egg opens its sheet', (tester) async {
    tester.view.physicalSize = const Size(375 * 2, 812 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await openApp(tester);
    routerOf(tester).go('/farm');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final paint = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is FarmCreaturesPainter,
    );
    final world = (tester.widget<CustomPaint>(paint).painter! as FarmCreaturesPainter).world;
    final egg = world.eggs.first;
    await tester.tapAt(tester.getTopLeft(paint) + egg.centre);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(world.selectedId, egg.id);
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  testWidgets('Back and Esc close the sheet before leaving the farm', (tester) async {
    _reduceMotion(tester);
    final semantics = tester.ensureSemantics();
    await openApp(tester, '/farm');
    Future<void> pick() async {
      tester.semantics.tap(find.semantics.byLabel(RegExp(r'^vit-small, duck')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close'), findsOneWidget);
    }

    // Android's Back gesture or button.
    await pick();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close'), findsNothing);
    expect(locationOf(tester), '/farm');

    // A desktop keyboard's Esc.
    await pick();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close'), findsNothing);

    // With nothing open, Back leaves the farm.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(locationOf(tester), '/');
    semantics.dispose();
  });

  testWidgets('a mouse pointer turns into a hand over a duck', (tester) async {
    _reduceMotion(tester);
    await openApp(tester, '/farm');
    final paint = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is FarmCreaturesPainter,
    );
    final world = (tester.widget<CustomPaint>(paint).painter! as FarmCreaturesPainter).world;
    final origin = tester.getTopLeft(paint);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    MouseCursor cursor() => RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;

    await mouse.addPointer(location: origin + world.layout.pasture.bottomRight);
    await mouse.moveTo(origin + world.ducks.first.centre);
    await tester.pumpAndSettle();
    expect(cursor(), SystemMouseCursors.click);
    await mouse.moveTo(origin + world.layout.pasture.bottomRight - const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(cursor(), isNot(SystemMouseCursors.click));
  });

  testWidgets('ducks walk while the farm is on screen, and stop when it is left', (tester) async {
    await openApp(tester);
    routerOf(tester).go('/farm');
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isTrue, reason: 'the ducks keep moving');

    // Tapping grass far from everyone selects nothing.
    await tester.tapAt(tester.getBottomRight(find.byType(Scaffold)) - const Offset(4, 4));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_figure('Final loss'), findsNothing);

    routerOf(tester).go('/');
    await tester.pumpAndSettle();
    expect(locationOf(tester), '/');
  });
}
