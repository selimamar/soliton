import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/field_snapshot.dart';
import '../../models/layer_info.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../models/run_insights.dart';
import '../../models/simulation_info.dart';
import '../../models/system_info.dart';
import 'curve_generator.dart';
import 'mock_fields.dart';
import 'mock_job_times.dart';
import 'mock_runs.dart';

/// The demo simulations, as `soliton.simulate()` would log them: two
/// running (a 2D shear layer, 3D convection), one that diverged, a steady
/// solve, and a finished cylinder wake.
List<MockRun> buildMockSimulations(DateTime now) => [
  _kelvinHelmholtz(now),
  _rayleighBenard(now),
  _burgers(now),
  _darcy(now),
  _cylinderWake(now),
];

MockRun _kelvinHelmholtz(DateTime now) {
  final steps = [for (var s = 0; s <= 32000; s += 200) s];
  double t(int step) => 6.4 * step / 32000;
  final noise = math.Random(31);
  double jitter(double scale) => (noise.nextDouble() * 2 - 1) * scale;
  return _simulation(
    id: 'kelvin-helmholtz-2048',
    project: 'turbulence',
    host: 'Sherlock',
    status: RunStatus.live,
    startedAt: now.subtract(const Duration(hours: 3, minutes: 22)),
    steps: steps,
    values: {
      SimulationInfo.timeKey: [for (final s in steps) t(s)],
      SimulationInfo.timeStepKey: [for (final s in steps) 2e-4 * (1 + 0.08 * math.sin(s / 3000))],
      'energy': [for (final s in steps) 0.5 * (1 - 4e-5 * t(s)) + jitter(2e-5)],
      'enstrophy': [for (final s in steps) 20 + 60 * math.pow(_tanh(t(s) / 2.5), 2) + jitter(0.6)],
      'cfl': [for (final s in steps) 0.45 + 0.12 * _tanh(t(s) / 3) + jitter(0.02)],
    },
    setup: const {
      'Equation': 'Incompressible Navier–Stokes, vorticity form',
      'Method': 'Fourier spectral · RK443',
      'Grid': '2048 × 2048, periodic',
      'Reynolds number': '1e4',
      'Initial condition': 'Shear layer + noise',
      'Code': 'Dedalus 3',
      'MPI ranks': '64',
    },
    info: const SimulationInfo(tEnd: 10, cflLimit: 1, monitor: 'enstrophy'),
    queued: const Duration(hours: 1, minutes: 25),
    timeLimit: const Duration(hours: 48),
    system: const SystemInfo(
      hostname: 'sh04-02n11.int',
      cpu: 'AMD EPYC 9654 96-Core Processor',
      cpuCores: 64,
      memoryGb: 256,
      python: '3.12.4',
      slurm: {'jobId': '53110482', 'jobName': 'kh-2048', 'partition': 'normal'},
    ),
    fields: [
      simulatedField(
        'vorticity',
        shape: const [96, 96],
        steps: [for (var s = 0; s <= 32000; s += 4000) s],
        domain: const FieldDomain(extent: [(0, 1), (0, 1)], axes: ['y', 'x']),
        values: (step) => _grid2(96, 96, (x, y) => _shearLayer(x, y, t(step))),
      ),
    ],
    seed: 31,
    tags: const ['production'],
  );
}

/// Two shear layers of opposite sign on the periodic unit square, rolling
/// up into vortices as time goes on.
double _shearLayer(double x, double y, double t) {
  final amp = 0.012 + 0.06 * _tanh(t / 2);
  double layer(double centre, double sign) {
    var d = y - centre;
    if (d > 0.5) d -= 1;
    if (d < -0.5) d += 1;
    final wave = amp * math.sin(2 * math.pi * 2 * x + sign * 0.6 * t);
    final yy = d - wave;
    final roll = 1 + 7 * amp * math.sin(2 * math.pi * 4 * x - sign * 1.4 * t + 9 * yy);
    return sign * math.exp(-math.pow(yy / 0.045, 2)) * roll;
  }

  return layer(0.25, 1) + layer(0.75, -1);
}

MockRun _rayleighBenard(DateTime now) {
  final steps = [for (var s = 0; s <= 4120; s += 40) s];
  double t(int step) => step / 100;
  final noise = math.Random(37);
  double jitter(double scale) => (noise.nextDouble() * 2 - 1) * scale;
  return _simulation(
    id: 'rayleigh-benard-3d',
    project: 'convection',
    host: 'GCP',
    status: RunStatus.live,
    startedAt: now.subtract(const Duration(hours: 1, minutes: 5)),
    steps: steps,
    values: {
      SimulationInfo.timeKey: [for (final s in steps) t(s)],
      SimulationInfo.timeStepKey: [for (final _ in steps) 0.01],
      'nusselt': [for (final s in steps) 1 + 11.8 * _tanh(t(s) / 8) + jitter(0.3)],
      'kinetic_energy': [for (final s in steps) 0.02 * math.pow(_tanh(t(s) / 6), 2) + jitter(4e-4)],
      'cfl': [for (final s in steps) 0.3 + 0.15 * _tanh(t(s) / 10) + jitter(0.02)],
    },
    setup: const {
      'Equation': 'Boussinesq (Rayleigh–Bénard)',
      'Method': 'Finite volume · WENO',
      'Grid': '256 × 256 × 256',
      'Rayleigh number': '1e8',
      'Prandtl number': '1',
      'Boundaries': 'No-slip plates, periodic sides',
      'Code': 'Oceananigans',
    },
    info: const SimulationInfo(tEnd: 200, cflLimit: 1, monitor: 'nusselt'),
    system: const SystemInfo(
      hostname: 'a2-highgpu-1g',
      cpu: 'Intel Xeon @ 2.20GHz',
      cpuCores: 12,
      memoryGb: 85,
      gpus: [GpuInfo(name: 'NVIDIA A100-SXM4-40GB', memoryGb: 40)],
    ),
    fields: [
      simulatedField(
        'temperature',
        shape: const [32, 32, 32],
        steps: const [800, 1600, 2400, 3200, 4000],
        domain: const FieldDomain(extent: [(0, 1), (0, 2), (0, 2)], axes: ['z', 'y', 'x']),
        values: (step) => _grid3(32, (z, y, x) {
          final a = 0.35 * _tanh(t(step) / 10);
          return (1 - z) +
              a * math.sin(math.pi * z) * math.cos(2 * math.pi * x) * math.cos(2 * math.pi * y) +
              0.08 * math.sin(math.pi * z) * math.sin(6 * x + 3 * y + t(step));
        }),
      ),
    ],
    seed: 37,
  );
}

MockRun _burgers(DateTime now) {
  final steps = [for (var s = 0; s <= 830; s += 10) s];
  double t(int step) => step / 1000;
  final last = steps.last;
  return _simulation(
    id: 'burgers-shock-fd',
    project: 'numerics',
    host: 'Sherlock',
    status: RunStatus.crashed,
    startedAt: now.subtract(const Duration(hours: 2, minutes: 15)),
    endedAt: now.subtract(const Duration(hours: 2)),
    statusMessage: 'Diverged at t = 0.83: energy is NaN',
    steps: steps,
    values: {
      SimulationInfo.timeKey: [for (final s in steps) t(s)],
      SimulationInfo.timeStepKey: [for (final _ in steps) 1e-3],
      'energy': [
        for (final s in steps)
          s == last
              ? double.nan
              : 0.25 * (1 - 0.1 * t(s)) + (t(s) > 0.72 ? 900 * math.pow(t(s) - 0.72, 3) : 0),
      ],
      'cfl': [
        for (final s in steps) 0.5 + 0.2 * t(s) + (t(s) > 0.7 ? 60 * math.pow(t(s) - 0.7, 2) : 0),
      ],
    },
    setup: const {
      'Equation': 'Inviscid Burgers 1D',
      'Method': 'Central differences · forward Euler',
      'Grid': '256 points, periodic',
      'Initial condition': 'u = −sin(2πx)',
    },
    info: const SimulationInfo(tEnd: 1, cflLimit: 1, monitor: 'energy', diverged: true),
    queued: const Duration(minutes: 12),
    timeLimit: const Duration(hours: 6),
    system: const SystemInfo(cpu: 'Intel Xeon Gold 6230', cpuCores: 4, memoryGb: 16),
    fields: [
      simulatedField(
        'u',
        shape: const [256],
        steps: const [0, 200, 400, 600, 800],
        domain: const FieldDomain(extent: [(0, 1)], axes: ['x']),
        values: (step) => _burgersProfile(256, t(step)),
      ),
    ],
    seed: 41,
  );
}

/// u = −sin(2πx) steepening into a shock, with the oscillations of an
/// unstable scheme growing near it at the end.
Float32List _burgersProfile(int n, double t) {
  final values = Float32List(n);
  for (var i = 0; i < n; i++) {
    final x = i / n;
    var u = -math.sin(2 * math.pi * x);
    for (var k = 0; k < 30; k++) {
      u = -math.sin(2 * math.pi * (x - 0.25 * u * t));
    }
    if (t > 0.7) {
      u += 2.5 * (t - 0.7) * math.sin(70 * math.pi * x) * math.exp(-math.pow((x - 0.5) / 0.08, 2));
    }
    values[i] = u;
  }
  return values;
}

MockRun _darcy(DateTime now) {
  final steps = [for (var s = 0; s <= 37; s++) s];
  final noise = math.Random(43);
  return _simulation(
    id: 'darcy-heterogeneous',
    project: 'porous-media',
    host: 'Sherlock',
    status: RunStatus.finished,
    startedAt: now.subtract(const Duration(days: 1, minutes: 4)),
    endedAt: now.subtract(const Duration(days: 1)),
    statusMessage: 'Converged in 37 iterations',
    steps: steps,
    totalSteps: 100,
    values: {
      'residual': [
        for (final s in steps) math.pow(10, -9 * s / 37) * (1 + 0.3 * noise.nextDouble()),
      ],
    },
    setup: const {
      'Equation': 'Darcy flow 2D, −∇·(k∇p) = f',
      'Method': 'P1 finite elements · CG + AMG',
      'Mesh': '128 × 128, 32,768 triangles',
      'Permeability': 'Log-normal random field',
      'Boundaries': 'p = 0 on the boundary',
      'Code': 'FEniCSx',
    },
    info: const SimulationInfo(monitor: 'residual'),
    // The same solve repeated over the permeability contrast: a parameter
    // study, logged with sim.log_curve.
    curves: [
      LoggedSeries(
        name: 'outflow vs permeability contrast',
        steps: [
          CurveStep(
            step: 37,
            x: const [1, 3, 10, 30, 100, 300, 1000],
            y: List.unmodifiable([
              for (final c in const [1, 3, 10, 30, 100, 300, 1000])
                1 / (1 + 0.45 * math.log(c) / math.ln10) / (1 + 0.02 * math.sqrt(c)),
            ]),
            xLabel: 'Permeability contrast',
            yLabel: 'Outflow (normalized)',
          ),
        ],
      ),
    ],
    queued: const Duration(hours: 7, minutes: 30),
    timeLimit: const Duration(hours: 24),
    system: const SystemInfo(cpu: 'Intel Xeon Gold 6230', cpuCores: 4, memoryGb: 16),
    fields: [
      simulatedField(
        'pressure',
        shape: const [64, 64],
        steps: const [1, 5, 37],
        domain: const FieldDomain(extent: [(0, 1), (0, 1)], axes: ['y', 'x']),
        values: (step) => _grid2(64, 64, (x, y) {
          final converged = 1 - math.pow(0.45, step);
          return converged *
              math.sin(math.pi * x) *
              math.sin(math.pi * y) *
              (1 + 0.35 * math.sin(9 * x) * math.cos(7 * y) + 0.15 * math.sin(23 * x * y));
        }),
      ),
    ],
    seed: 43,
  );
}

MockRun _cylinderWake(DateTime now) {
  final steps = [for (var s = 0; s <= 60000; s += 500) s];
  double t(int step) => step * 0.005;
  final noise = math.Random(47);
  double jitter(double scale) => (noise.nextDouble() * 2 - 1) * scale;
  double onset(double time) => _tanh(time / 40);
  return _simulation(
    id: 'cylinder-wake-re200',
    project: 'aerodynamics',
    host: 'AWS',
    status: RunStatus.finished,
    startedAt: now.subtract(const Duration(days: 2, hours: 9)),
    endedAt: now.subtract(const Duration(days: 2)),
    steps: steps,
    values: {
      SimulationInfo.timeKey: [for (final s in steps) t(s)],
      SimulationInfo.timeStepKey: [for (final _ in steps) 0.005],
      'lift_coefficient': [
        for (final s in steps)
          0.7 * math.sin(2 * math.pi * 0.197 * t(s)) * onset(t(s)) + jitter(0.01),
      ],
      'drag_coefficient': [
        for (final s in steps)
          1.33 +
              0.05 * math.sin(2 * math.pi * 0.394 * t(s)) * onset(t(s)) +
              0.4 * math.exp(-t(s) / 3) +
              jitter(0.005),
      ],
      'cfl': [for (final s in steps) 0.8 + 0.05 * onset(t(s)) + jitter(0.01)],
    },
    setup: const {
      'Equation': 'Incompressible Navier–Stokes 2D',
      'Method': 'Finite volume · PIMPLE',
      'Mesh': '1.2M cells, O-grid around the cylinder',
      'Reynolds number': '200',
      'Boundaries': 'Uniform inflow, no-slip cylinder',
      'Code': 'OpenFOAM v2406 (pimpleFoam)',
    },
    info: const SimulationInfo(tEnd: 300, cflLimit: 1, monitor: 'lift_coefficient'),
    system: const SystemInfo(cpu: 'AMD EPYC 7R13', cpuCores: 32, memoryGb: 64),
    fields: [
      simulatedField(
        'vorticity',
        shape: const [48, 128],
        steps: [for (var s = 10000; s <= 60000; s += 10000) s],
        domain: const FieldDomain(extent: [(-2, 2), (0, 10)], axes: ['y', 'x']),
        values: (step) => _grid2(128, 48, (u, v) => _wake(10 * u, 4 * v - 2, t(step))),
      ),
    ],
    seed: 47,
  );
}

/// A von Kármán vortex street behind a cylinder at (1, 0).
double _wake(double x, double y, double t) {
  var w = 0.0;
  // The cylinder's boundary layers, shed alternately.
  w += 2 * math.exp(-(math.pow(x - 1.2, 2) + math.pow(y - 0.5, 2)) / 0.05);
  w -= 2 * math.exp(-(math.pow(x - 1.2, 2) + math.pow(y + 0.5, 2)) / 0.05);
  final phase = (0.197 * t * 2.5) % 2.5;
  for (var k = 0; k < 8; k++) {
    final xk = 1.6 + phase + 1.25 * k;
    final yk = (k.isEven ? 1 : -1) * 0.4;
    w += (k.isEven ? 1 : -1) * 1.4 * math.exp(-(math.pow(x - xk, 2) + math.pow(y - yk, 2)) / 0.12);
  }
  return x < 0.8 ? 0 : w;
}

MockRun _simulation({
  required String id,
  required String project,
  required String host,
  required RunStatus status,
  required DateTime startedAt,
  DateTime? endedAt,
  String? statusMessage,
  required List<int> steps,
  required Map<String, List<double>> values,
  required Map<String, String> setup,
  required SimulationInfo info,
  required SystemInfo system,
  Duration? queued,
  Duration? timeLimit,
  int totalSteps = 0,
  List<MockField> fields = const [],
  List<LoggedSeries<CurveStep>> curves = const [],
  List<String> tags = const [],
  required int seed,
}) {
  final metrics = {
    for (final MapEntry(:key, value: v) in values.entries)
      key: MetricSeries(
        name: key,
        points: List.unmodifiable([for (final (i, s) in steps.indexed) MetricPoint(s, v[i])]),
      ),
  };
  final generator = CurveGenerator(
    seed: seed,
    currentStep: steps.last,
    totalSteps: math.max(totalSteps, steps.last),
    every: math.max(1, steps.last ~/ 120),
  );
  final monitored = info.monitor == null ? null : values[info.monitor];
  final stride = monitored == null ? 1 : math.max(1, monitored.length ~/ 60);
  return MockRun(
    run: Run(
      id: id,
      name: id,
      project: project,
      host: host,
      status: status,
      startedAt: startedAt,
      endedAt: endedAt,
      currentStep: steps.last,
      totalSteps: totalSteps,
      currentEpoch: 0,
      totalEpochs: 0,
      hyperparameters: setup,
      architecture: LayerInfo(name: id, type: 'Model'),
      lossPreview: const [],
      statusMessage: statusMessage,
      tags: tags,
      system: withJobTimes(system, startedAt, queued: queued, timeLimit: timeLimit),
      simulation: SimulationInfo(
        tEnd: info.tEnd,
        time: values[SimulationInfo.timeKey]?.last,
        cflLimit: info.cflLimit,
        monitor: info.monitor,
        preview: List.unmodifiable([
          if (monitored != null)
            for (var i = 0; i < monitored.length; i += stride) monitored[i],
        ]),
        diverged: info.diverged,
      ),
    ),
    metrics: Map.unmodifiable({...metrics, ...mockSystemMetrics(generator, system)}),
    layerStats: const [],
    fields: fields,
    extras: curves.isEmpty ? null : MockExtras(curves: curves),
  );
}

/// [f] on an [nx] × [ny] grid of the unit square, row by row (rows are y).
Float32List _grid2(int nx, int ny, double Function(double x, double y) f) {
  final values = Float32List(nx * ny);
  for (var j = 0; j < ny; j++) {
    for (var i = 0; i < nx; i++) {
      values[j * nx + i] = f((i + 0.5) / nx, (j + 0.5) / ny);
    }
  }
  return values;
}

/// [f] on an [n]³ grid of the unit cube, z slowest.
Float32List _grid3(int n, double Function(double z, double y, double x) f) {
  final values = Float32List(n * n * n);
  for (var k = 0; k < n; k++) {
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        values[(k * n + j) * n + i] = f((k + 0.5) / n, (j + 0.5) / n, (i + 0.5) / n);
      }
    }
  }
  return values;
}

double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}
