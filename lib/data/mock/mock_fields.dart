import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/field_snapshot.dart';
import '../../models/metric_series.dart';
import '../../models/run_insights.dart';
import 'curve_generator.dart';

/// A demo field: snapshots made up on demand (and kept), as a neural
/// operator would log them.
class MockField {
  MockField._({
    required this.name,
    required this.shape,
    required this.steps,
    required this.make,
    this.kind = FieldKind.output,
    this.frames = 1,
    this.layer,
    this.position,
    this.worstOf,
  });

  final String name;
  final List<int> shape;
  final List<int> steps;
  final FieldKind kind;
  final int frames;
  final String? layer;
  final int? position;
  final String? worstOf;
  final FieldSnapshot Function(int step) make;
  final _cache = <int, FieldSnapshot>{};

  FieldSnapshot? snapshot(int step) =>
      steps.contains(step) ? _cache.putIfAbsent(step, () => make(step)) : null;

  FieldSummary summary() => FieldSummary(
    name: name,
    kind: kind,
    shape: shape,
    frames: frames,
    layer: layer,
    position: position,
    worstOf: worstOf,
    steps: List.unmodifiable([
      for (final step in steps)
        // Layers have no target, so no errors: no need to make them up yet.
        // Layers and weights have no target, so no errors: no need to make them up yet.
        FieldStep(
          step: step,
          stats: kind == FieldKind.layer || kind == FieldKind.weights
              ? const {}
              : snapshot(step)!.stats,
        ),
    ]),
  );
}

/// The vorticity of a 2D turbulent flow on the unit torus (the classic FNO
/// Navier–Stokes benchmark), as the demo FNO would log it: snapshots at a
/// fixed time, a cut through them, rollouts over time (2D and a 1D cut),
/// the space-time volume an FNO-3D predicts, and what each layer outputs.
///
/// The "model" learns low wavenumbers first and high ones late (spectral
/// bias), with phase errors that grow along a rollout and fade with
/// training.
List<MockField> navierStokesFields({
  required int currentStep,
  required int totalSteps,
  required int every,
  int seed = 7,
}) {
  final flow = _Flow(seed);
  List<int> stepsEvery(int n) => List.unmodifiable([for (var s = 0; s <= currentStep; s += n) s]);
  final steps = stepsEvery(every);
  final slowSteps = stepsEvery(every * 2);
  double progress(int step) => step / totalSteps;

  FieldSnapshot output(
    String name,
    int step,
    List<int> shape, {
    required int frames,
    required Float32List Function(int frame, double? progress) frame,
    List<double>? times,
    FieldDomain domain = const FieldDomain(),
    List<double> Function(double? progress)? spectrum,
  }) => _outputSnapshot(
    name,
    step,
    shape,
    progress: progress(step),
    frames: frames,
    frame: frame,
    times: times,
    domain: domain,
    spectrum: spectrum,
  );

  const size = 64, line = 256;
  const rolloutSize = 32, rolloutLine = 128, frames = 16;
  final times = List<double>.unmodifiable([for (var f = 0; f < frames; f++) f * 0.1]);

  final fields = [
    MockField._(
      name: 'vorticity',
      shape: const [size, size],
      steps: steps,
      make: (step) => output(
        'vorticity',
        step,
        const [size, size],
        frames: 1,
        frame: (_, p) => flow.grid(size, 0, p),
        domain: _square,
        spectrum: (p) => flow.spectrum(size, 0, p),
      ),
    ),
    MockField._(
      name: 'vorticity, y = 0.5',
      shape: const [line],
      steps: steps,
      make: (step) => output(
        'vorticity, y = 0.5',
        step,
        const [line],
        frames: 1,
        frame: (_, p) => flow.line(line, 0.5, 0, p),
        domain: _line,
      ),
    ),
    MockField._(
      name: 'rollout',
      shape: const [rolloutSize, rolloutSize],
      frames: frames,
      steps: slowSteps,
      make: (step) => output(
        'rollout',
        step,
        const [rolloutSize, rolloutSize],
        frames: frames,
        times: times,
        frame: (f, p) => flow.grid(rolloutSize, times[f], p),
        domain: _square,
        spectrum: (p) => flow.spectrum(rolloutSize, times.last, p),
      ),
    ),
    MockField._(
      name: 'rollout, y = 0.5',
      shape: const [rolloutLine],
      frames: frames,
      steps: slowSteps,
      make: (step) => output(
        'rollout, y = 0.5',
        step,
        const [rolloutLine],
        frames: frames,
        times: times,
        frame: (f, p) => flow.line(rolloutLine, 0.5, times[f], p),
        domain: _line,
      ),
    ),
    // FNO-3D treats time as a third axis: one (x, y, t) volume, t last.
    MockField._(
      name: 'vorticity (x, y, t)',
      shape: const [rolloutSize, rolloutSize, frames],
      steps: slowSteps,
      make: (step) => output(
        'vorticity (x, y, t)',
        step,
        const [rolloutSize, rolloutSize, frames],
        frames: 1,
        frame: (_, p) {
          final volume = Float32List(rolloutSize * rolloutSize * frames);
          for (var t = 0; t < frames; t++) {
            final plane = flow.grid(rolloutSize, times[t], p); // [y][x]
            for (var y = 0; y < rolloutSize; y++) {
              for (var x = 0; x < rolloutSize; x++) {
                volume[(x * rolloutSize + y) * frames + t] = plane[y * rolloutSize + x];
              }
            }
          }
          return volume;
        },
        domain: _spaceTime,
      ),
    ),
  ];

  // A 3D flow over time (like a 3D Navier–Stokes rollout): blobs of
  // vorticity drifting and decaying in a periodic box.
  final flow3d = _Flow3d(seed + 1);
  const cube = 24, cubeFrames = 12;
  final cubeTimes = List<double>.unmodifiable([for (var f = 0; f < cubeFrames; f++) f * 0.1]);
  fields.add(
    MockField._(
      name: '3D rollout',
      shape: const [cube, cube, cube],
      frames: cubeFrames,
      steps: slowSteps,
      make: (step) => output(
        '3D rollout',
        step,
        const [cube, cube, cube],
        frames: cubeFrames,
        times: cubeTimes,
        frame: (f, p) => flow3d.grid(cube, cubeTimes[f], p),
        domain: _box,
        spectrum: (p) => flow3d.spectrum(cube, cubeTimes.last, p),
      ),
    ),
  );

  // Inside the model: the lifting layer sees the input and the (x, y)
  // grid it is given, so a ramp shows; each block moves the field closer to
  // the output, with small-scale texture from channel mixing in between.
  const layers = [
    ('lifting', [size, size, 32], 'mean of 32 channels'),
    ('blocks.0', [32, size, size], 'mean of 32 channels'),
    ('blocks.1', [32, size, size], 'mean of 32 channels'),
    ('blocks.2', [32, size, size], 'mean of 32 channels'),
    ('blocks.3', [32, size, size], 'mean of 32 channels'),
    ('projection', [size, size, 1], '1 channel'),
  ];
  final input = flow.grid(size, -0.5, null);
  for (final (position, (layer, layerShape, reduction)) in layers.indexed) {
    final depth = position / (layers.length - 1);
    final last = position == layers.length - 1;
    fields.add(
      MockField._(
        name: 'layers/$layer',
        kind: FieldKind.layer,
        layer: layer,
        position: position,
        shape: const [size, size],
        steps: slowSteps,
        make: (step) {
          final out = flow.grid(size, 0, progress(step));
          final values = Float32List(size * size);
          for (var i = 0; i < values.length; i++) {
            final x = (i % size) / size, y = (i ~/ size) / size;
            final ramp = position == 0 ? 0.8 * (x + y - 1) : 0.0;
            final texture =
                0.6 *
                math.sin(math.pi * depth) *
                math.sin(2 * math.pi * (9 * x + 4 * y) + position) *
                math.cos(2 * math.pi * (3 * x - 7 * y));
            values[i] = last
                ? out[i]
                : 0.4 * ((1 - depth) * input[i] + depth * out[i]) + ramp + texture;
          }
          return FieldSnapshot(
            name: 'layers/$layer',
            step: step,
            kind: FieldKind.layer,
            shape: const [size, size],
            prediction: values,
            layer: layer,
            reduction: reduction,
            layerShape: layerShape,
          );
        },
      ),
    );
  }
  return fields;
}

/// A snapshot of an output field: [frame] gives each frame of the
/// prediction (at training [progress]) or, with null, of the truth.
FieldSnapshot _outputSnapshot(
  String name,
  int step,
  List<int> shape, {
  required double progress,
  required int frames,
  required Float32List Function(int frame, double? progress) frame,
  List<double>? times,
  FieldDomain domain = const FieldDomain(),
  List<double> Function(double? progress)? spectrum,
  FieldKind kind = FieldKind.output,
  String? layer,
  int? sample,
}) {
  final size = shape.fold(1, (a, b) => a * b);
  final prediction = Float32List(frames * size);
  final target = Float32List(frames * size);
  for (var f = 0; f < frames; f++) {
    prediction.setAll(f * size, frame(f, progress));
    target.setAll(f * size, frame(f, null));
  }
  return FieldSnapshot(
    name: name,
    step: step,
    kind: kind,
    layer: layer,
    sample: sample,
    shape: List.unmodifiable(shape),
    originalShape: List.unmodifiable([for (final n in shape) n * 2]),
    frames: frames,
    times: times,
    prediction: prediction,
    target: target,
    stats: Map.unmodifiable(_errorStats(prediction, target)),
    domain: domain,
    spectrum: spectrum == null
        ? null
        : () {
            final predicted = spectrum(progress);
            return FieldSpectrum(
              k: List.unmodifiable([for (var k = 1; k <= predicted.length; k++) k.toDouble()]),
              prediction: List.unmodifiable(predicted),
              target: List.unmodifiable(spectrum(null)),
            );
          }(),
    frameStats: frames == 1
        ? const {}
        : Map.unmodifiable({
            FieldStatKeys.relL2: List<double>.unmodifiable([
              for (var f = 0; f < frames; f++)
                _errorStats(
                  Float32List.sublistView(prediction, f * size, (f + 1) * size),
                  Float32List.sublistView(target, f * size, (f + 1) * size),
                )[FieldStatKeys.relL2]!,
            ]),
            ..._physics(prediction, target, frames, size),
          }),
  );
}

/// Per frame mean, mean square and minimum, as the logger sends them for a
/// rollout's conservation checks.
Map<String, List<double>> _physics(
  Float32List prediction,
  Float32List target,
  int frames,
  int size,
) {
  List<double> per(Float32List data, double Function(Float32List) of) => List.unmodifiable([
    for (var f = 0; f < frames; f++) of(Float32List.sublistView(data, f * size, (f + 1) * size)),
  ]);
  double mean(Float32List v) => v.fold(0.0, (a, b) => a + b) / v.length;
  double meanSquare(Float32List v) => v.fold(0.0, (a, b) => a + b * b) / v.length;
  double minimum(Float32List v) => v.reduce(math.min);
  return {
    FieldStatKeys.mean: per(prediction, mean),
    FieldStatKeys.meanSquare: per(prediction, meanSquare),
    FieldStatKeys.min: per(prediction, minimum),
    FieldStatKeys.targetMean: per(target, mean),
    FieldStatKeys.targetMeanSquare: per(target, meanSquare),
    FieldStatKeys.targetMin: per(target, minimum),
  };
}

/// The demo domains: the unit square (rows are y), a cut along x, an
/// (x, y, t) volume, and a periodic box of side 2π.
const _square = FieldDomain(extent: [(0, 1), (0, 1)], axes: ['y', 'x']);
const _line = FieldDomain(extent: [(0, 1)], axes: ['x']);
const _spaceTime = FieldDomain(extent: [(0, 1), (0, 1), (0, 1.5)], axes: ['x', 'y', 't']);
const _box = FieldDomain(
  extent: [(0, 2 * math.pi), (0, 2 * math.pi), (0, 2 * math.pi)],
  axes: ['x', 'y', 'z'],
);

/// A 3D turbulent flow in a periodic box, as a demo FNO-3D would log it: the
/// vorticity at a fixed time, a rollout over time, and what each layer
/// outputs, all 3D.
List<MockField> turbulence3dFields({
  required int currentStep,
  required int totalSteps,
  required int every,
  int seed = 11,
}) {
  final flow = _Flow3d(seed);
  List<int> stepsEvery(int n) => List.unmodifiable([for (var s = 0; s <= currentStep; s += n) s]);
  final steps = stepsEvery(every);
  final slowSteps = stepsEvery(every * 2);
  double progress(int step) => step / totalSteps;
  const size = 32, cube = 24, frames = 10;
  final times = List<double>.unmodifiable([for (var f = 0; f < frames; f++) f * 0.1]);

  final fields = [
    MockField._(
      name: 'vorticity',
      shape: const [size, size, size],
      steps: steps,
      make: (step) => _outputSnapshot(
        'vorticity',
        step,
        const [size, size, size],
        progress: progress(step),
        frames: 1,
        frame: (_, p) => flow.grid(size, 0, p),
        domain: _box,
        spectrum: (p) => flow.spectrum(size, 0, p),
      ),
    ),
    MockField._(
      name: 'rollout',
      shape: const [cube, cube, cube],
      frames: frames,
      steps: slowSteps,
      make: (step) => _outputSnapshot(
        'rollout',
        step,
        const [cube, cube, cube],
        progress: progress(step),
        frames: frames,
        times: times,
        frame: (f, p) => flow.grid(cube, times[f], p),
        domain: _box,
        spectrum: (p) => flow.spectrum(cube, times.last, p),
      ),
    ),
  ];

  // Inside the model, all 3D: the lifting layer sees the input and the
  // (x, y, z) grid it is given (a ramp); each block moves the field closer
  // to the output, with small-scale texture from channel mixing.
  const layers = [
    ('lifting', [size, size, size, 20], 'mean of 20 channels'),
    ('blocks.0', [20, size, size, size], 'mean of 20 channels'),
    ('blocks.1', [20, size, size, size], 'mean of 20 channels'),
    ('blocks.2', [20, size, size, size], 'mean of 20 channels'),
    ('blocks.3', [20, size, size, size], 'mean of 20 channels'),
    ('projection', [size, size, size, 1], '1 channel'),
  ];
  final input = flow.grid(size, -0.5, null);
  for (final (position, (layer, layerShape, reduction)) in layers.indexed) {
    final depth = position / (layers.length - 1);
    final last = position == layers.length - 1;
    fields.add(
      MockField._(
        name: 'layers/$layer',
        kind: FieldKind.layer,
        layer: layer,
        position: position,
        shape: const [size, size, size],
        steps: slowSteps,
        make: (step) {
          final out = flow.grid(size, 0, progress(step));
          final values = Float32List(size * size * size);
          for (var i = 0; i < values.length; i++) {
            final x = (i ~/ (size * size)) / size;
            final y = ((i ~/ size) % size) / size;
            final z = (i % size) / size;
            final ramp = position == 0 ? 0.6 * (x + y + z - 1.5) : 0.0;
            final texture =
                0.5 *
                math.sin(math.pi * depth) *
                math.sin(2 * math.pi * (5 * x + 3 * y) + position) *
                math.cos(2 * math.pi * (4 * z - 2 * x));
            values[i] = last
                ? out[i]
                : 0.4 * ((1 - depth) * input[i] + depth * out[i]) + ramp + texture;
          }
          return FieldSnapshot(
            name: 'layers/$layer',
            step: step,
            kind: FieldKind.layer,
            shape: const [size, size, size],
            prediction: values,
            layer: layer,
            reduction: reduction,
            layerShape: layerShape,
          );
        },
      ),
    );
  }
  return fields;
}

/// The demo flow: a sum of Fourier modes that drift and decay over time,
/// and a "model" of it that misses high wavenumbers early in training and
/// drifts out of phase along a rollout.
class _Flow {
  _Flow(int seed) {
    final random = math.Random(seed);
    for (var kx = 0; kx <= 8; kx++) {
      for (var ky = -8; ky <= 8; ky++) {
        if (kx == 0 && ky <= 0) continue; // (k) and (-k) are the same mode.
        final k = math.sqrt(kx * kx + ky * ky);
        if (k > 8) continue;
        _modes.add(
          _Mode(
            kx: kx,
            ky: ky,
            k: k,
            amplitude: math.pow(k, -1.4) * (0.5 + random.nextDouble()),
            phase: random.nextDouble() * 2 * math.pi,
            speed: (random.nextDouble() - 0.5) * 6,
            phaseError: (random.nextDouble() - 0.5) * 1.2,
            drift: (random.nextDouble() - 0.5) * 2,
          ),
        );
      }
    }
    for (var i = 0; i < 6; i++) {
      _noise.add(
        _Mode(
          kx: 10 + random.nextInt(5),
          ky: random.nextInt(21) - 10,
          k: 12,
          amplitude: 0.05,
          phase: random.nextDouble() * 2 * math.pi,
          speed: 0,
          phaseError: 0,
          drift: 0,
        ),
      );
    }
  }

  final _modes = <_Mode>[];
  final _noise = <_Mode>[];
  final _tables = <int, ({List<Float64List> cos, List<Float64List> sin})>{};

  /// Each mode's amplitude and phase at time [t]: the truth, or the model's
  /// prediction at training [progress] (0..1).
  List<({_Mode mode, double amplitude, double phase})> _coefficients(double t, double? progress) {
    final result = <({_Mode mode, double amplitude, double phase})>[];
    for (final m in _modes) {
      var phase = m.phase + m.speed * t;
      var amplitude = m.amplitude * math.exp(-0.02 * m.k * m.k * t.abs());
      if (progress != null) {
        amplitude *= 1 - math.exp(-progress * 30 / m.k);
        final untrained = math.exp(-progress * 8);
        phase += m.phaseError * untrained + m.drift * t * (0.15 + untrained);
      }
      result.add((mode: m, amplitude: amplitude, phase: phase));
    }
    if (progress != null) {
      final spurious = math.exp(-progress * 6) * (1 + t);
      for (final m in _noise) {
        result.add((mode: m, amplitude: spurious * m.amplitude, phase: m.phase));
      }
    }
    return result;
  }

  /// cos and sin of 2πkx/n for every wavenumber k in -16..16 and grid point x.
  ({List<Float64List> cos, List<Float64List> sin}) _table(int n) => _tables.putIfAbsent(n, () {
    List<Float64List> make(double Function(double) f) => [
      for (var k = -16; k <= 16; k++)
        Float64List.fromList([for (var i = 0; i < n; i++) f(2 * math.pi * k * i / n)]),
    ];
    return (cos: make(math.cos), sin: make(math.sin));
  });

  /// The vorticity on an n × n grid at time [t], row by row (rows are y):
  /// the truth, or the prediction at [progress].
  Float32List grid(int n, double t, double? progress) {
    final table = _table(n);
    final values = Float64List(n * n);
    for (final c in _coefficients(t, progress)) {
      // sin(a + b + φ) = sin(a) cos(b + φ) + cos(a) sin(b + φ), a from x, b from y.
      final cx = table.cos[c.mode.kx + 16], sx = table.sin[c.mode.kx + 16];
      final cy = table.cos[c.mode.ky + 16], sy = table.sin[c.mode.ky + 16];
      final cp = math.cos(c.phase), sp = math.sin(c.phase);
      for (var r = 0; r < n; r++) {
        final cosB = cy[r] * cp - sy[r] * sp; // cos(b + φ)
        final sinB = sy[r] * cp + cy[r] * sp; // sin(b + φ)
        final row = r * n;
        for (var col = 0; col < n; col++) {
          values[row + col] += c.amplitude * (sx[col] * cosB + cx[col] * sinB);
        }
      }
    }
    return Float32List.fromList(values);
  }

  /// Energy per wavenumber shell |k| = 1 .. n/2 on an n × n grid at time
  /// [t]: each sine mode of amplitude a puts a²/2 into its shell.
  List<double> spectrum(int n, double t, double? progress) {
    final energy = List<double>.filled(n ~/ 2, 0);
    for (final c in _coefficients(t, progress)) {
      final shell = math.sqrt(c.mode.kx * c.mode.kx + c.mode.ky * c.mode.ky).round();
      if (shell >= 1 && shell <= energy.length) energy[shell - 1] += c.amplitude * c.amplitude / 2;
    }
    return energy;
  }

  /// The vorticity along y = [y] at n points in x.
  Float32List line(int n, double y, double t, double? progress) {
    final values = Float64List(n);
    for (final c in _coefficients(t, progress)) {
      for (var i = 0; i < n; i++) {
        values[i] +=
            c.amplitude * math.sin(2 * math.pi * (c.mode.kx * i / n + c.mode.ky * y) + c.phase);
      }
    }
    return Float32List.fromList(values);
  }
}

/// A few 3D Fourier modes that drift and decay, and a model of them that
/// learns slowly and drifts out of phase along a rollout.
class _Flow3d {
  _Flow3d(int seed) {
    final random = math.Random(seed);
    for (var i = 0; i < 10; i++) {
      final k = [for (var a = 0; a < 3; a++) random.nextInt(5) - 2];
      if (k.every((v) => v == 0)) k[0] = 1;
      final size = math.sqrt(k.fold(0, (sum, v) => sum + v * v));
      _modes.add((
        k: k,
        size: size,
        amplitude: math.pow(size, -1.2) * (0.6 + random.nextDouble()),
        phase: random.nextDouble() * 2 * math.pi,
        speed: (random.nextDouble() - 0.5) * 5,
        drift: (random.nextDouble() - 0.5) * 3,
      ));
    }
  }

  final _modes =
      <({List<int> k, double size, double amplitude, double phase, double speed, double drift})>[];

  ({double amplitude, double phase}) _mode(
    ({List<int> k, double size, double amplitude, double phase, double speed, double drift}) m,
    double t,
    double? progress,
  ) {
    var amplitude = m.amplitude * math.exp(-0.04 * m.size * m.size * t);
    var phase = m.phase + m.speed * t;
    if (progress != null) {
      amplitude *= 1 - math.exp(-progress * 25 / m.size);
      phase += m.drift * t * (0.2 + math.exp(-progress * 8));
    }
    return (amplitude: amplitude, phase: phase);
  }

  /// Energy per wavenumber shell |k| = 1 .. n/2 on an n³ grid at time [t].
  List<double> spectrum(int n, double t, double? progress) {
    final energy = List<double>.filled(n ~/ 2, 0);
    for (final m in _modes) {
      final shell = m.size.round();
      final a = _mode(m, t, progress).amplitude;
      if (shell >= 1 && shell <= energy.length) energy[shell - 1] += a * a / 2;
    }
    return energy;
  }

  /// The field on an n³ grid at time [t] (axis 0 slowest): the truth, or
  /// the prediction at training [progress]. Each mode is a product of
  /// per-axis complex exponentials, so no trigonometry per point.
  Float32List grid(int n, double t, double? progress) {
    final values = Float64List(n * n * n);
    for (final m in _modes) {
      final (:amplitude, :phase) = _mode(m, t, progress);
      List<(double, double)> axis(int k) => [
        for (var i = 0; i < n; i++)
          (math.cos(2 * math.pi * k * i / n), math.sin(2 * math.pi * k * i / n)),
      ];
      final ax = axis(m.k[0]), ay = axis(m.k[1]), az = axis(m.k[2]);
      final cp = math.cos(phase), sp = math.sin(phase);
      for (var i = 0; i < n; i++) {
        final (c0, s0) = ax[i];
        final ci = c0 * cp - s0 * sp, si = s0 * cp + c0 * sp;
        for (var j = 0; j < n; j++) {
          final (c1, s1) = ay[j];
          final cij = ci * c1 - si * s1, sij = si * c1 + ci * s1;
          final row = (i * n + j) * n;
          for (var k = 0; k < n; k++) {
            final (c2, s2) = az[k];
            values[row + k] += amplitude * (sij * c2 + cij * s2); // sin(a + b + c + φ)
          }
        }
      }
    }
    return Float32List.fromList(values);
  }
}

class _Mode {
  const _Mode({
    required this.kx,
    required this.ky,
    required this.k,
    required this.amplitude,
    required this.phase,
    required this.speed,
    required this.phaseError,
    required this.drift,
  });

  final int kx, ky;
  final double k, amplitude, phase, speed, phaseError, drift;
}

/// As the logger computes them (`_fields.py`).
Map<String, double> _errorStats(Float32List prediction, Float32List target) {
  var errorSquares = 0.0, targetSquares = 0.0, maxError = 0.0;
  for (var i = 0; i < prediction.length; i++) {
    final e = prediction[i] - target[i];
    errorSquares += e * e;
    targetSquares += target[i] * target[i];
    maxError = math.max(maxError, e.abs());
  }
  return {
    FieldStatKeys.relL2: math.sqrt(errorSquares / targetSquares),
    FieldStatKeys.rmse: math.sqrt(errorSquares / prediction.length),
    FieldStatKeys.maxError: maxError,
  };
}

// What a demo operator run logs besides its fields ---------------------------------

/// A demo run's validation sets, curves, extra fields (worst samples,
/// Fourier weights) and extra metrics (loss terms, per-variable errors,
/// timings).
class MockExtras {
  MockExtras({
    this.fields = const [],
    this.makeEvals,
    this.curves = const [],
    this.metrics = const {},
  });

  final List<MockField> fields;
  final List<LoggedSeries<EvalStep>> Function()? makeEvals;

  /// Made on first use: they need the worst samples' snapshots.
  late final List<LoggedSeries<EvalStep>> evals = makeEvals?.call() ?? const [];
  final List<LoggedSeries<CurveStep>> curves;
  final Map<String, MetricSeries> metrics;
}

/// For the 2D Navier–Stokes demo run.
MockExtras navierStokesExtras({
  required CurveGenerator curves,
  required List<MockField> fields,
  required int currentStep,
  required int totalSteps,
  required int every,
  int seed = 7,
}) {
  final evalSteps = _stepsEvery(currentStep, every * 2);
  final vorticity = fields.firstWhere((f) => f.name == 'vorticity');
  final worst = [
    for (var rank = 1; rank <= 4; rank++)
      _worstField(
        'vorticity',
        rank,
        evalSteps,
        totalSteps,
        seed: seed,
        sample: 17 + 41 * rank,
        (flow, p) {
          return flow.grid(64, 0, p);
        },
        shape: const [64, 64],
        domain: _square,
        flow: _Flow(seed + 100 + rank),
      ),
  ];
  return MockExtras(
    fields: [
      ...worst,
      ..._weightFields(evalSteps, totalSteps, const [12, 12], seed),
    ],
    makeEvals: () => [
      _evalSeries('vorticity', evalSteps, 200, seed, worst, (step) {
        return vorticity.snapshot(step)!.stats[FieldStatKeys.relL2]!;
      }),
    ],
    curves: _curves(currentStep, every * 4, totalSteps, resolutions: const [32, 64, 128, 256]),
    metrics: {
      ..._lossTerms(curves),
      ..._errorMetrics(curves, ['vorticity', 'velocity'], finalError: 0.06),
      ..._timings(curves, inference: 0.0042, solver: 2.1),
    },
  );
}

/// For the 3D turbulence demo run: 3D worst samples and 3D Fourier weights.
MockExtras turbulence3dExtras({
  required CurveGenerator curves,
  required List<MockField> fields,
  required int currentStep,
  required int totalSteps,
  required int every,
  int seed = 11,
}) {
  final evalSteps = _stepsEvery(currentStep, every * 2);
  final vorticity = fields.firstWhere((f) => f.name == 'vorticity');
  final worst = [
    for (var rank = 1; rank <= 3; rank++)
      _worstField(
        'vorticity',
        rank,
        evalSteps,
        totalSteps,
        seed: seed,
        sample: 9 + 23 * rank,
        (flow, p) => flow.grid(24, 0, p),
        shape: const [24, 24, 24],
        domain: _box,
        flow: _Flow3d(seed + 100 + rank),
      ),
  ];
  return MockExtras(
    fields: [
      ...worst,
      ..._weightFields(evalSteps, totalSteps, const [8, 8, 8], seed),
    ],
    makeEvals: () => [
      _evalSeries('vorticity', evalSteps, 100, seed, worst, (step) {
        return vorticity.snapshot(step)!.stats[FieldStatKeys.relL2]!;
      }),
    ],
    curves: _curves(currentStep, every * 4, totalSteps, resolutions: const [16, 32, 64]),
    metrics: {
      ..._lossTerms(curves),
      ..._errorMetrics(curves, ['u', 'v', 'w'], finalError: 0.03),
      ..._timings(curves, inference: 0.031, solver: 48),
    },
  );
}

/// For the small sweep runs: only what a sweep compares.
MockExtras sweepExtras({required CurveGenerator curves, required int modes, required int width}) {
  final error = 0.02 * math.pow(12 / modes, 0.6) * math.pow(32 / width, 0.4);
  final cost = math.pow(modes / 12, 2) * math.pow(width / 32, 2);
  return MockExtras(
    metrics: {
      ..._errorMetrics(curves, const [], finalError: error.toDouble()),
      ..._timings(curves, inference: 0.0042 * cost, solver: 2.1),
    },
  );
}

List<int> _stepsEvery(int currentStep, int every) =>
    List.unmodifiable([for (var s = 0; s <= currentStep; s += every) s]);

/// A worst validation sample: a different flow, which the model gets
/// worse (as if it had trained for a fraction of the time).
MockField _worstField<F>(
  String name,
  int rank,
  List<int> steps,
  int totalSteps,
  Float32List Function(F flow, double? progress) grid, {
  required int seed,
  required int sample,
  required List<int> shape,
  required FieldDomain domain,
  required F flow,
}) => MockField._(
  name: 'worst/$name/$rank',
  kind: FieldKind.worst,
  layer: '$name #$rank',
  position: rank,
  worstOf: name,
  shape: shape,
  steps: steps,
  make: (step) => _outputSnapshot(
    'worst/$name/$rank',
    step,
    shape,
    progress: step / totalSteps * (0.45 - 0.05 * rank),
    frames: 1,
    frame: (_, p) => grid(flow, p),
    domain: domain,
    kind: FieldKind.worst,
    layer: '$name #$rank',
    sample: sample,
  ),
);

/// The validation set's errors at each step: lognormal around the shown
/// sample's error, with the worst samples' real errors at the top.
LoggedSeries<EvalStep> _evalSeries(
  String name,
  List<int> steps,
  int count,
  int seed,
  List<MockField> worst,
  double Function(int step) typical,
) {
  final random = math.Random(seed);
  final shape = [for (var i = 0; i < count - worst.length; i++) random.nextDouble()];
  double gaussian(double u, double v) =>
      math.sqrt(-2 * math.log(u.clamp(1e-9, 1))) * math.cos(2 * math.pi * v);
  final noise = [for (var i = 0; i + 1 < shape.length; i += 2) gaussian(shape[i], shape[i + 1])];
  return LoggedSeries(
    name: name,
    steps: List.unmodifiable([
      for (final step in steps)
        () {
          final worstErrors = [for (final w in worst) w.snapshot(step)!.stats[FieldStatKeys.relL2]!]
            ..sort((a, b) => b.compareTo(a));
          final cap = worstErrors.isEmpty ? double.infinity : worstErrors.last;
          final base = typical(step);
          final errors = [
            for (var i = 0; i < count - worst.length; i++)
              math.min(base * math.exp(0.35 * noise[i % noise.length]), cap * 0.98),
            ...worstErrors,
          ]..sort();
          double quantile(double q) => errors[((errors.length - 1) * q).round()];
          final low = math.log(errors.first) / math.ln10, high = math.log(errors.last) / math.ln10;
          const bins = 24;
          final counts = List<int>.filled(bins, 0);
          for (final e in errors) {
            final b = ((math.log(e) / math.ln10 - low) / (high - low) * bins).floor();
            counts[b.clamp(0, bins - 1)]++;
          }
          return EvalStep(
            step: step,
            count: count,
            stats: {
              'median': quantile(0.5),
              'p90': quantile(0.9),
              'max': errors.last,
              'min': errors.first,
              'mean': errors.reduce((a, b) => a + b) / errors.length,
              'nonFinite': 0,
            },
            histogram: ErrorHistogram(
              edges: List.unmodifiable([
                for (var i = 0; i <= bins; i++)
                  math.pow(10, low + (high - low) * i / bins).toDouble(),
              ]),
              counts: List.unmodifiable(counts),
            ),
            worst: List.unmodifiable([
              for (final (i, w) in worst.indexed)
                WorstSample(rank: i + 1, sample: w.make(step).sample!, relL2: worstErrors[i]),
            ]),
          );
        }(),
    ]),
  );
}

/// Four FNO blocks' spectral weights over [modes] (2D or 3D): large at low
/// wavenumbers, and the high ones filling in as training goes on.
List<MockField> _weightFields(List<int> steps, int totalSteps, List<int> modes, int seed) => [
  for (var block = 0; block < 4; block++)
    MockField._(
      name: 'weights/blocks.$block.spectral.weights1',
      kind: FieldKind.weights,
      layer: 'blocks.$block.spectral.weights1',
      position: block,
      shape: modes,
      steps: steps,
      make: (step) {
        final p = step / totalSteps;
        final random = math.Random(seed + block);
        final count = modes.fold(1, (a, b) => a * b);
        final values = Float32List(count);
        for (var i = 0; i < count; i++) {
          var rest = i, k2 = 0;
          for (final n in modes.reversed) {
            final k = rest % n;
            rest ~/= n;
            k2 += k * k;
          }
          final k = math.sqrt(k2.toDouble());
          values[i] = math.exp(-k / (1.5 + 7 * p + block)) * (0.6 + 0.4 * random.nextDouble());
        }
        final channels = modes.length == 3 ? 20 : 32;
        return FieldSnapshot(
          name: 'weights/blocks.$block.spectral.weights1',
          step: step,
          kind: FieldKind.weights,
          shape: List.unmodifiable(modes),
          prediction: values,
          layer: 'blocks.$block.spectral.weights1',
          reduction: 'mean |w| over $channels × $channels channels',
          layerShape: List.unmodifiable([channels, channels, ...modes]),
        );
      },
    ),
];

/// Error against resolution (the model trained at the second one) and
/// against viscosity (trained on 5e-4 to 2e-3), every [every] steps.
List<LoggedSeries<CurveStep>> _curves(
  int currentStep,
  int every,
  int totalSteps, {
  required List<double> resolutions,
}) {
  final steps = _stepsEvery(currentStep, every);
  double base(int step) => 0.9 * math.exp(-5 * step / totalSteps) + 0.03;
  const viscosities = [1e-4, 2e-4, 5e-4, 1e-3, 2e-3, 5e-3, 1e-2];
  double distance(double nu) => (math.log(nu / 1e-3) / math.ln10).abs();
  return [
    LoggedSeries(
      name: 'error vs resolution',
      steps: List.unmodifiable([
        for (final step in steps)
          CurveStep(
            step: step,
            x: List.unmodifiable(resolutions),
            y: List.unmodifiable([
              for (final (i, _) in resolutions.indexed)
                base(step) * (1 + 0.12 * (i - 1).abs() + (i == 0 ? 0.15 : 0)),
            ]),
            xLabel: 'Resolution',
            yLabel: 'Relative L2',
            trainRange: (resolutions[1], resolutions[1]),
          ),
      ]),
    ),
    LoggedSeries(
      name: 'error vs viscosity',
      steps: List.unmodifiable([
        for (final step in steps)
          CurveStep(
            step: step,
            x: List.unmodifiable(viscosities),
            y: List.unmodifiable([
              for (final nu in viscosities)
                base(step) * (1 + 1.8 * math.pow(math.max(0, distance(nu) - 0.3), 2)),
            ]),
            xLabel: 'Viscosity',
            yLabel: 'Relative L2',
            trainRange: (5e-4, 2e-3),
          ),
      ]),
    ),
  ];
}

/// A physics-informed loss in three terms: data, PDE residual, boundary.
Map<String, MetricSeries> _lossTerms(CurveGenerator curves) => {
  for (final (term, start, end) in [('data', 0.9, 0.012), ('pde', 2.5, 0.03), ('bc', 0.4, 0.002)])
    'loss/$term': curves.decay('loss/$term', start: start, end: end),
};

/// The relative L2 error on validation, overall and per variable.
Map<String, MetricSeries> _errorMetrics(
  CurveGenerator curves,
  List<String> variables, {
  required double finalError,
}) => {
  'val/rel_l2': curves.decay('val/rel_l2', start: 0.95, end: finalError, interval: 100),
  for (final (i, v) in variables.indexed)
    'val/rel_l2/$v': curves.decay(
      'val/rel_l2/$v',
      start: 0.95,
      end: finalError * (0.7 + 0.45 * i),
      interval: 100,
    ),
};

/// Seconds per sample: the model's inference and the numerical solver's.
Map<String, MetricSeries> _timings(
  CurveGenerator curves, {
  required double inference,
  required double solver,
}) => {
  'perf/inference_s': curves.approach(
    'perf/inference_s',
    start: inference * 1.1,
    end: inference,
    noise: inference * 0.03,
    interval: 500,
  ),
  'perf/solver_s': curves.approach(
    'perf/solver_s',
    start: solver,
    end: solver,
    noise: solver * 0.01,
    interval: 500,
  ),
};

/// A simulated field, as `Simulation.log_field` logs it: one snapshot per
/// step, with nothing to compare it to (no target, no errors).
MockField simulatedField(
  String name, {
  required List<int> shape,
  required List<int> steps,
  required Float32List Function(int step) values,
  FieldDomain domain = const FieldDomain(),
}) => MockField._(
  name: name,
  shape: shape,
  steps: steps,
  make: (step) => FieldSnapshot(
    name: name,
    step: step,
    shape: List.unmodifiable(shape),
    prediction: values(step),
    domain: domain,
  ),
);
