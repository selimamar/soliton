import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/field_snapshot.dart';

/// A demo field: snapshots made up on demand (and kept), as a neural
/// operator would log them.
class MockField {
  MockField._(this.name, this.shape, this.steps, this._make);

  final String name;
  final List<int> shape;
  final List<int> steps;
  final FieldSnapshot Function(int step) _make;
  final _cache = <int, FieldSnapshot>{};

  FieldSnapshot? snapshot(int step) =>
      steps.contains(step) ? _cache.putIfAbsent(step, () => _make(step)) : null;

  FieldSummary summary() => FieldSummary(
    name: name,
    shape: shape,
    steps: List.unmodifiable([
      for (final step in steps) FieldStep(step: step, stats: snapshot(step)!.stats),
    ]),
  );
}

/// The vorticity of a 2D turbulent flow on the unit torus (the classic FNO
/// Navier–Stokes benchmark), and a 1D cut through it at y = 0.5.
///
/// The "model" learns low wavenumbers first and high ones late (spectral
/// bias), with a phase error and a little spurious noise that fade with
/// training: the error maps show small-scale structure that slowly goes
/// away, as in a real run.
List<MockField> navierStokesFields({
  required int currentStep,
  required int totalSteps,
  required int every,
  int seed = 7,
}) {
  final random = math.Random(seed);
  final modes = <_Mode>[];
  for (var kx = 0; kx <= 8; kx++) {
    for (var ky = -8; ky <= 8; ky++) {
      if (kx == 0 && ky <= 0) continue; // (k) and (-k) are the same mode.
      final k = math.sqrt(kx * kx + ky * ky);
      if (k > 8) continue;
      modes.add(
        _Mode(
          kx: kx,
          ky: ky,
          amplitude: math.pow(k, -1.4) * (0.5 + random.nextDouble()),
          phase: random.nextDouble() * 2 * math.pi,
          phaseError: (random.nextDouble() - 0.5) * 1.2,
        ),
      );
    }
  }
  final noise = [
    for (var i = 0; i < 6; i++)
      _Mode(
        kx: 10 + random.nextInt(5),
        ky: random.nextInt(21) - 10,
        amplitude: 0.05,
        phase: random.nextDouble() * 2 * math.pi,
        phaseError: 0,
      ),
  ];
  final steps = [for (var s = 0; s <= currentStep; s += every) s];

  double truth(double x, double y) {
    var sum = 0.0;
    for (final m in modes) {
      sum += m.amplitude * math.sin(2 * math.pi * (m.kx * x + m.ky * y) + m.phase);
    }
    return sum;
  }

  double predicted(double x, double y, double progress) {
    var sum = 0.0;
    for (final m in modes) {
      final k = math.sqrt(m.kx * m.kx + m.ky * m.ky);
      final learned = 1 - math.exp(-progress * 30 / k);
      final phase = m.phase + m.phaseError * math.exp(-progress * 8);
      sum += learned * m.amplitude * math.sin(2 * math.pi * (m.kx * x + m.ky * y) + phase);
    }
    final spurious = math.exp(-progress * 6);
    for (final m in noise) {
      sum += spurious * m.amplitude * math.sin(2 * math.pi * (m.kx * x + m.ky * y) + m.phase);
    }
    return sum;
  }

  FieldSnapshot make(String name, int step, int rows, int columns, double Function(int) yOf) {
    final progress = step / totalSteps;
    final prediction = Float32List(rows * columns);
    final target = Float32List(rows * columns);
    for (var r = 0; r < rows; r++) {
      final y = yOf(r);
      for (var c = 0; c < columns; c++) {
        final x = c / columns;
        prediction[r * columns + c] = predicted(x, y, progress);
        target[r * columns + c] = truth(x, y);
      }
    }
    return FieldSnapshot(
      name: name,
      step: step,
      shape: List.unmodifiable(rows == 1 ? [columns] : [rows, columns]),
      originalShape: List.unmodifiable(rows == 1 ? [columns] : [rows * 2, columns * 2]),
      prediction: prediction,
      target: target,
      stats: Map.unmodifiable(_errorStats(prediction, target)),
    );
  }

  const size = 64;
  const line = 256;
  return [
    MockField._(
      'vorticity',
      const [size, size],
      steps,
      (step) => make('vorticity', step, size, size, (r) => r / size),
    ),
    MockField._(
      'vorticity, y = 0.5',
      const [line],
      steps,
      (step) => make('vorticity, y = 0.5', step, 1, line, (_) => 0.5),
    ),
  ];
}

class _Mode {
  const _Mode({
    required this.kx,
    required this.ky,
    required this.amplitude,
    required this.phase,
    required this.phaseError,
  });

  final int kx, ky;
  final double amplitude, phase, phaseError;
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
