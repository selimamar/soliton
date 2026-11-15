import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';

import '../../models/run.dart';
import 'farm_settings.dart';
import 'farm_sky.dart';

/// Where things are on the farm, worked out from the size of the canvas:
/// the coop and its nest top left, the pond top right, the pasture below.
/// The same layout fits a phone (portrait) and a desktop window (wide).
/// The nest grows to fit its [eggs], in rows when they don't fit in one.
class FarmLayout {
  factory FarmLayout(Size size, {int eggs = 0, double bottomInset = 0}) {
    final w = size.width, h = size.height;
    final coop = Rect.fromLTWH(18, 18, math.min(w * 0.36, 200), math.min(h * 0.15, 100));
    final widest = math.max(coop.width, math.min(w * 0.5, coop.width * 1.6));
    final perRow = math.max(1, math.min(math.max(eggs, 1), ((widest - 24) / eggSpacing).floor()));
    final rows = math.max(1, (eggs / perRow).ceil());
    final nestWidth = math.max(coop.width * 0.95, perRow * eggSpacing + 24);
    final nestHeight = 50 + (rows - 1) * eggSpacing;
    final nest = Rect.fromLTWH(
      math.max(coop.center.dx - nestWidth / 2, 12),
      coop.bottom + 15,
      nestWidth,
      nestHeight,
    );
    final rx = math.min(w * 0.2, 150.0), ry = math.min(coop.height * 0.62, 70.0);
    final pond = Rect.fromCenter(
      center: Offset(math.max(w * 0.73, coop.right + rx + 24), coop.top + ry + 4),
      width: rx * 2,
      height: ry * 2,
    );
    final pasture = Rect.fromLTRB(
      28,
      math.max(nest.bottom, pond.bottom) + 40,
      w - 28,
      math.max(h - 16 - bottomInset, math.max(nest.bottom, pond.bottom) + 80),
    );
    return FarmLayout._(size, eggs, bottomInset, perRow, coop, nest, pond, pasture, [
      (Offset(52, h - 56 - bottomInset), 40.0),
      (Offset(w - 40, pasture.top + pasture.height * 0.6), 20.0),
    ]);
  }

  const FarmLayout._(
    this.size,
    this.eggs,
    this.bottomInset,
    this._perRow,
    this.coop,
    this.nest,
    this.pond,
    this.pasture,
    this.trees,
  );

  /// Room for one egg and its progress ring.
  static const eggSpacing = 30.0;

  final Size size;

  /// How many eggs the nest was sized for.
  final int eggs;

  /// What the system covers at the bottom (a phone's gesture bar), which
  /// ducks keep clear of; the grass still runs to the edge.
  final double bottomInset;
  final int _perRow;
  final Rect coop;

  /// The nest's ellipse, under the coop: eggs sit in it.
  final Rect nest;

  /// The pond's ellipse (its drawn edge wobbles around it).
  final Rect pond;

  /// Where ducks walk when they aren't swimming.
  final Rect pasture;

  /// Treetops: centre and radius.
  final List<(Offset, double)> trees;

  /// Whether [p] is in the water (well inside the pond's edge).
  bool inPond(Offset p) {
    final dx = (p.dx - pond.center.dx) / (pond.width / 2);
    final dy = (p.dy - pond.center.dy) / (pond.height / 2);
    return dx * dx + dy * dy < 0.7;
  }

  /// Where egg [i] of [count] sits: in rows across the nest, the last row
  /// centred.
  Offset eggSlot(int i, int count) {
    final rows = math.max(1, (count / _perRow).ceil());
    final row = i ~/ _perRow;
    final inRow = row == rows - 1 ? count - row * _perRow : _perRow;
    final col = i % _perRow;
    return Offset(
      nest.center.dx + (col - (inRow - 1) / 2) * eggSpacing,
      nest.center.dy + 10 + (row - (rows - 1) / 2) * eggSpacing,
    );
  }
}

/// A finished run: an animal (a duck unless its model family is set to
/// another) that walks about the farm.
class FarmDuck {
  FarmDuck._(this.run, this.position, this.animal, this.scale) : target = position;

  Run run;

  /// Where its feet are.
  Offset position;
  Offset target;

  /// Which animal it is, from its model family.
  FarmAnimal animal;

  /// How big it's drawn: grows with the parameter count, see
  /// [FarmWorld.scaleFor].
  double scale;

  /// Asleep for the night: it lies still with its eyes shut.
  bool asleep = false;

  /// 1 when it faces right, -1 when left.
  double facing = 1;

  /// Phase of the walk cycle, in radians.
  double gait = 0;
  bool walking = false;
  bool swimming = false;

  /// Seconds until it picks a new place to go, while it stands still.
  double wait = 0;

  /// Seconds until it next looks around or preens.
  double idleIn = 0;
  DuckPose? pose;

  /// Seconds into [pose].
  double poseTime = 0;

  /// Seconds until it blinks; negative while the eye is shut.
  double blinkIn = 2;

  /// 0 to 1 as it pops out of its egg; 1 once grown.
  double pop = 1;

  String get id => run.id;
  bool get blinking => blinkIn < 0 || asleep;

  /// Where its body is, for tapping and for marking it.
  Offset get centre => position.translate(0, -animal.centre * scale);
}

/// A bit of weather (or a firefly), drifting across the farm.
class FarmFlake {
  FarmFlake._(this.kind, this.position, this.phase, this.speed);

  final FlakeKind kind;
  Offset position;

  /// Where it is in its sway, spin or blink, in radians.
  double phase;

  /// 0.5 to 1.5: some drift faster than others.
  final double speed;
}

enum FlakeKind { rain, petal, glint, leaf, snow, firefly }

/// What a standing duck does now and then.
enum DuckPose { look, preen }

/// A live or crashed run: an egg in the nest.
class FarmEgg {
  FarmEgg._(this.run, this.position);

  Run run;
  Offset position;

  String get id => run.id;
  bool get crashed => run.status == RunStatus.crashed;
  double get progress => run.progress;

  /// How big it's drawn, a little larger for bigger models.
  double get scale => 0.82 + 0.08 * math.log(math.max(run.parameterCount, 1e5) / 1e5) / math.ln10;

  Offset get centre => position.translate(0, -10);
}

/// A half of a hatched egg's shell, flying off.
class FarmShard {
  FarmShard._(this.position, this.velocity, this.spin, {required this.top});

  Offset position;
  Offset velocity;
  final double spin;

  /// The top half (else the bottom one).
  final bool top;
  double age = 0;

  static const life = 0.7;
}

/// The farm's state: a duck per finished run, an egg per live or crashed
/// one, and where everything is. Plain Dart, so tests can step it.
///
/// [sync] it with the runs whenever they change; a run that finishes hatches
/// out of its egg. [update] it every frame while it [animate]s; when it
/// doesn't (reduced motion), ducks stand in rows and nothing moves.
class FarmWorld extends ChangeNotifier {
  FarmWorld({int seed = 1, this.animate = true})
    : _random = math.Random(seed),
      _weatherRandom = math.Random(seed + 1);

  final math.Random _random;

  /// Weather has its own, so it doesn't change where animals wander.
  final math.Random _weatherRandom;

  /// Whether ducks walk about. Off for reduced motion and screen readers.
  bool animate;

  FarmLayout? _layout;
  FarmLayout get layout => _layout!;

  /// Oldest first, which is also the order of their labels.
  final List<FarmDuck> ducks = [];

  /// Oldest first, in their places in the nest.
  final List<FarmEgg> eggs = [];
  final List<FarmShard> shards = [];

  /// The run tapped on, whose duck stands still.
  String? selectedId;

  /// Model types (`architecture.type`) of the runs, sorted: a duck's colour
  /// is its type's index in this list.
  List<String> families = const [];

  /// Which animal each model family is; the rest are ducks.
  Map<String, FarmAnimal> animals = const {};

  /// The season and light, from the clock.
  FarmSky sky = FarmSky.day;

  /// The season's weather, and fireflies in warm seasons.
  final List<FarmFlake> flakes = [];

  /// Seconds since the farm started.
  double time = 0;

  /// Goes up whenever ducks or eggs come or go, or the selection changes,
  /// so painters know their semantics (and still pictures) are stale.
  int version = 0;

  /// How big a duck is drawn for [parameters]: a log scale, so a 45M
  /// model is larger than a 0.6M one without dwarfing it.
  static double scaleFor(int parameters) =>
      (0.52 + 0.3 * math.log(math.max(parameters, 1) / 1e5) / math.ln10).clamp(0.7, 1.6);

  /// The model type a run's colour comes from; null if it wasn't logged.
  static String? familyOf(Run run) =>
      run.architecture.isLeaf && run.architecture.type == 'Model' ? null : run.architecture.type;

  FarmAnimal animalOf(Run run) => animals[familyOf(run)] ?? FarmAnimal.duck;

  /// Sets which animal each model family is; animals already on the farm
  /// change on the spot.
  void setAnimals(Map<String, FarmAnimal> value) {
    if (mapEquals(value, animals)) return;
    animals = value;
    for (final duck in ducks) {
      final animal = animalOf(duck.run);
      if (animal == duck.animal) continue;
      duck
        ..animal = animal
        ..scale = scaleFor(duck.run.parameterCount) * animal.size;
      if (!animal.swims && layout.inPond(duck.position)) {
        duck
          ..position = _pastureSpot()
          ..target = duck.position;
      }
    }
    version++;
    notifyListeners();
  }

  /// Moves the farm on to [value]'s season and light; a new season brings
  /// its weather.
  void setSky(FarmSky value) {
    if (value == sky) return;
    final season = sky.season;
    sky = value;
    if (value.season != season || flakes.isEmpty) _makeWeather();
    for (final duck in ducks) {
      duck.asleep = value.asleep && duck.id != selectedId;
    }
    notifyListeners();
  }

  int familyIndexOf(Run run) {
    final family = familyOf(run);
    return family == null ? -1 : families.indexOf(family);
  }

  /// Starts or stops the ducks walking about; stopped, they stand in rows.
  void setAnimate(bool value) {
    if (value == animate) return;
    animate = value;
    shards.clear();
    if (_layout != null && !value) _standInRows();
    version++;
    notifyListeners();
  }

  void select(String? id) {
    if (id == selectedId) return;
    selectedId = id;
    // The one you pick wakes up to be looked at.
    for (final duck in ducks) {
      duck.asleep = sky.asleep && duck.id != id;
    }
    version++;
    notifyListeners();
  }

  /// Fits the farm to [size], moving everyone with it.
  void resize(Size size, {double bottomInset = 0}) {
    final old = _layout;
    if (old != null &&
        old.size == size &&
        old.eggs == eggs.length &&
        old.bottomInset == bottomInset) {
      return;
    }
    _layout = FarmLayout(size, eggs: eggs.length, bottomInset: bottomInset);
    if (old != null) {
      Offset move(Offset p) =>
          Offset(p.dx / old.size.width * size.width, p.dy / old.size.height * size.height);
      for (final duck in ducks) {
        duck
          ..position = layout.pasture.contains(duck.position) || old.inPond(duck.position)
              ? move(duck.position)
              : _pastureSpot()
          ..target = duck.position;
      }
    }
    if (!animate) _standInRows();
    _placeEggs();
    _makeWeather();
    version++;
  }

  /// Brings the farm up to date with [runs]. Call [resize] first.
  void sync(List<Run> runs) {
    final byId = {for (final run in runs) run.id: run};
    var changed = false;

    ducks.removeWhere((d) => !byId.containsKey(d.id) || byId[d.id]!.status != RunStatus.finished);
    final eggCount = eggs.length;
    eggs.removeWhere((e) {
      final run = byId[e.id];
      if (run == null) return true;
      if (run.status == RunStatus.finished) {
        _hatch(e, run);
        return true;
      }
      return false;
    });
    changed |= eggCount != eggs.length;

    final known = {for (final d in ducks) d.id, for (final e in eggs) e.id};
    for (final duck in ducks) {
      duck.run = byId[duck.id]!;
    }
    for (final egg in eggs) {
      egg.run = byId[egg.id]!;
    }
    for (final run in runs) {
      if (known.contains(run.id)) continue;
      changed = true;
      if (run.status == RunStatus.finished) {
        ducks.add(_newDuck(run, _pastureSpot()));
      } else {
        eggs.add(FarmEgg._(run, layout.nest.center));
      }
    }

    int byAge(Run a, Run b) => a.startedAt.compareTo(b.startedAt);
    ducks.sort((a, b) => byAge(a.run, b.run));
    eggs.sort((a, b) => byAge(a.run, b.run));
    families = {for (final run in runs) ?familyOf(run)}.toList()..sort();
    if (selectedId != null && !byId.containsKey(selectedId)) selectedId = null;

    if (layout.eggs != eggs.length) {
      // The nest grows or shrinks to fit; the pasture below moves with it.
      _layout = FarmLayout(layout.size, eggs: eggs.length, bottomInset: layout.bottomInset);
      changed = true;
    }
    if (!animate) _standInRows();
    _placeEggs();
    if (changed) version++;
  }

  FarmDuck _newDuck(Run run, Offset at) {
    final animal = animalOf(run);
    return FarmDuck._(run, at, animal, scaleFor(run.parameterCount) * animal.size)
      ..asleep = sky.asleep
      ..facing = _random.nextBool() ? 1 : -1
      ..wait = _random.nextDouble() * 2
      ..idleIn = 1 + _random.nextDouble() * 3
      ..blinkIn = 1 + _random.nextDouble() * 3;
  }

  void _hatch(FarmEgg egg, Run run) {
    version++;
    if (!animate) {
      ducks.add(_newDuck(run, _pastureSpot()));
      return;
    }
    shards
      ..add(FarmShard._(egg.position, const Offset(-78, -156), -5, top: true))
      ..add(FarmShard._(egg.position, const Offset(78, -36), 5, top: false));
    ducks.add(
      _newDuck(run, egg.position.translate(0, 14))
        ..pop = 0
        ..facing = 1
        ..target = Offset(layout.nest.center.dx + 30, layout.pasture.top + 30),
    );
  }

  void _placeEggs() {
    for (final (i, egg) in eggs.indexed) {
      egg.position = layout.eggSlot(i, eggs.length);
    }
  }

  /// Still ducks stand in rows across the pasture, oldest first.
  void _standInRows() {
    final p = layout.pasture;
    final columns = math.max(1, (p.width / 64).floor());
    final step = p.width / columns;
    for (final (i, duck) in ducks.indexed) {
      duck
        ..position = Offset(p.left + step * (i % columns + 0.5), p.top + 50 + 72 * (i ~/ columns))
        ..target = duck.position
        ..facing = 1
        ..walking = false
        ..swimming = false
        ..pop = 1;
    }
  }

  Offset _pastureSpot() {
    final p = layout.pasture;
    return Offset(
      p.left + _random.nextDouble() * p.width,
      p.top + 30 + _random.nextDouble() * math.max(1, p.height - 30),
    );
  }

  void _pickTarget(FarmDuck duck) {
    if (_random.nextDouble() < (duck.animal.swims ? 0.25 : 0)) {
      final a = _random.nextDouble() * 2 * math.pi, r = _random.nextDouble() * 0.55;
      duck.target =
          layout.pond.center +
          Offset(
            math.cos(a),
            math.sin(a),
          ).scale(layout.pond.width / 2 * r, layout.pond.height / 2 * r);
    } else {
      duck.target = _pastureSpot();
    }
    duck.wait = 1 + _random.nextDouble() * 2.7;
  }

  /// Moves everything on by [dt] seconds.
  void update(double dt) {
    if (!animate || _layout == null) return;
    time += dt;
    for (final duck in ducks) {
      if (duck.id == selectedId || duck.asleep) {
        duck
          ..walking = false
          ..pose = null;
      } else if (duck.pose != null) {
        duck.poseTime += dt;
        if (duck.poseTime > 1) duck.pose = null;
      } else {
        final d = duck.target - duck.position;
        final distance = d.distance;
        if (distance < 1) {
          duck.walking = false;
          duck.wait -= dt;
          if (duck.wait < 0) {
            _pickTarget(duck);
          } else if ((duck.idleIn -= dt) < 0) {
            duck
              ..idleIn = 1.5 + _random.nextDouble() * 2.5
              ..pose = _random.nextBool() ? DuckPose.look : DuckPose.preen
              ..poseTime = 0;
          }
        } else {
          final speed = (25 + 12 / duck.scale) * duck.animal.speed * (duck.swimming ? 0.8 : 1);
          duck.position += d / distance * math.min(speed * dt, distance);
          if (d.dx.abs() > 1.5) duck.facing = d.dx.sign;
          duck.walking = true;
        }
      }
      duck.swimming = layout.inPond(duck.position);
      // Four legs take longer strides than two.
      final strides = duck.animal == FarmAnimal.duck || duck.animal == FarmAnimal.goose ? 1 : 0.55;
      if (duck.walking) duck.gait += (duck.swimming ? 7 : 15.6 * strides) * dt;
      duck.blinkIn -= dt;
      if (duck.blinkIn < -0.08) duck.blinkIn = 2.3 + _random.nextDouble() * 3.3;
      duck.pop = math.min(1, duck.pop + dt * 2.1);
    }
    for (final shard in shards) {
      shard
        ..age += dt
        ..position += shard.velocity * dt
        ..velocity = shard.velocity.translate(0, 470 * dt);
    }
    shards.removeWhere((s) => s.age > FarmShard.life);
    _blowWeather(dt);
    notifyListeners();
  }

  /// The run under [point], if any: the topmost duck or egg whose body is
  /// within a thumb's reach (at least 24 px, so small ones stay easy to tap).
  String? hitTest(Offset point) {
    String? best;
    var bestDistance = double.infinity;
    void consider(String id, Offset centre, double reach) {
      final d = (point - centre).distance;
      if (d <= reach && d < bestDistance) {
        best = id;
        bestDistance = d;
      }
    }

    for (final duck in ducks) {
      consider(duck.id, duck.centre, math.max(24, (duck.animal.centre + 4) * duck.scale));
    }
    for (final egg in eggs) {
      consider(egg.id, egg.centre, 24);
    }
    return best;
  }

  /// Scatters the season's weather over the farm, as much as fits its size.
  void _makeWeather() {
    flakes.clear();
    final size = _layout?.size;
    if (size == null || size.isEmpty) return;
    final area = size.width * size.height;
    final r = _weatherRandom;
    void add(FlakeKind kind, double perArea, {Rect? within}) {
      final box = within ?? Offset.zero & size;
      final n = (area * perArea).round().clamp(3, 120);
      for (var i = 0; i < n; i++) {
        flakes.add(
          FarmFlake._(
            kind,
            Offset(box.left + r.nextDouble() * box.width, box.top + r.nextDouble() * box.height),
            r.nextDouble() * 2 * math.pi,
            0.5 + r.nextDouble(),
          ),
        );
      }
    }

    switch (sky.season) {
      case FarmSeason.spring:
        add(FlakeKind.rain, 1 / 4500);
        add(FlakeKind.petal, 1 / 26000);
        add(FlakeKind.firefly, 1 / 30000);
      case FarmSeason.summer:
        add(
          FlakeKind.glint,
          1 / 60000,
          within: layout.pond.deflate(layout.pond.shortestSide * 0.2),
        );
        add(FlakeKind.firefly, 1 / 16000);
      case FarmSeason.autumn:
        add(FlakeKind.leaf, 1 / 9000);
      case FarmSeason.winter:
        add(FlakeKind.snow, 1 / 3200);
    }
  }

  /// Moves the weather on by [dt] seconds, wrapping round the edges.
  void _blowWeather(double dt) {
    final size = layout.size;
    for (final f in flakes) {
      final v = switch (f.kind) {
        FlakeKind.rain => Offset(-40 * f.speed, 360 * f.speed),
        FlakeKind.petal => Offset(30 * f.speed, 18 + math.sin(f.phase) * 14),
        FlakeKind.leaf => Offset(70 * f.speed, 22 + math.sin(f.phase) * 20),
        FlakeKind.snow => Offset(math.sin(f.phase) * 14, 26 * f.speed),
        FlakeKind.firefly => Offset(math.cos(f.phase * 0.7) * 10, math.sin(f.phase * 0.9) * 8),
        FlakeKind.glint => Offset.zero,
      };
      f
        ..position += v * dt
        ..phase += dt * (f.kind == FlakeKind.firefly ? 2.2 : 1.8) * f.speed;
      var Offset(:dx, :dy) = f.position;
      if (dy > size.height + 10) dy -= size.height + 20;
      if (dy < -10) dy += size.height + 20;
      if (dx > size.width + 10) dx -= size.width + 20;
      if (dx < -10) dx += size.width + 20;
      f.position = Offset(dx, dy);
    }
  }
}
