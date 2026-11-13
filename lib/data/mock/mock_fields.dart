import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/field_snapshot.dart';

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
  });

  final String name;
  final List<int> shape;
  final List<int> steps;
  final FieldKind kind;
  final int frames;
  final String? layer;
  final int? position;
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
    steps: List.unmodifiable([
      for (final step in steps)
        // Layers have no target, so no errors: no need to make them up yet.
        FieldStep(step: step, stats: kind == FieldKind.layer ? const {} : snapshot(step)!.stats),
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
  }) {
    final size = shape.fold(1, (a, b) => a * b);
    final prediction = Float32List(frames * size);
    final target = Float32List(frames * size);
    for (var f = 0; f < frames; f++) {
      prediction.setAll(f * size, frame(f, progress(step)));
      target.setAll(f * size, frame(f, null));
    }
    return FieldSnapshot(
      name: name,
      step: step,
      shape: List.unmodifiable(shape),
      originalShape: List.unmodifiable([for (final n in shape) n * 2]),
      frames: frames,
      times: times,
      prediction: prediction,
      target: target,
      stats: Map.unmodifiable(_errorStats(prediction, target)),
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
            }),
    );
  }

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
      ),
    ),
  ];

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
