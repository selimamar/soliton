import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/dataset.dart';
import '../../models/field_snapshot.dart';
import '../../models/run.dart';
import '../../models/system_info.dart';

/// The datasets each demo run trains on, by run id.
List<String> mockRunDatasets(String runId) => switch (runId) {
  'resnet50-cifar' || 'vit-small' => const ['cifar10'],
  'gpt-tiny' => const ['openwebtext'],
  'unet-seg' => const ['carvana'],
  'fno3d-turbulence' => const ['turbulence-3d-box'],
  _ when runId == 'fno-navier-stokes' || runId.startsWith('fno-ns-') => const ['ns2d-vorticity-v3'],
  _ => const [],
};

/// The demo datasets: what the demo runs train on, what two demo
/// simulations wrote, and an experiment nothing uses yet. [runs] are all
/// demo runs and simulations, to say who made and used each.
List<Dataset> buildMockDatasets(DateTime now, List<Run> runs) {
  DatasetUser user(Run r) => DatasetUser(
    id: r.id,
    name: r.name,
    project: r.project,
    status: r.status,
    simulation: r.isSimulation,
  );
  List<DatasetUser> usedBy(String id) => [
    for (final r in runs)
      if (r.datasets.contains(id)) user(r),
  ];
  DatasetUser? madeBy(String runId) {
    for (final r in runs) {
      if (r.id == runId) return user(r);
    }
    return null;
  }

  SystemInfo? systemOf(String runId) {
    for (final r in runs) {
      if (r.id == runId) return r.system;
    }
    return null;
  }

  const gb = 1000 * 1000 * 1000;
  return [
    Dataset(
      id: 'ns2d-vorticity-v3',
      name: 'ns2d-vorticity',
      version: 'v3',
      description:
          '2D incompressible Navier–Stokes on the unit torus, vorticity form, '
          'viscosity 1e-3; random initial vorticity, solved to t = 50.',
      samples: 1200,
      splits: const {'train': 1000, 'test': 200},
      sampleShape: const [64, 64, 50],
      sizeBytes: (0.98 * gb).round(),
      files: 1,
      format: 'HDF5',
      location: '/scratch/users/demo/data/navier-stokes/ns_v1e-3.h5',
      host: 'Sherlock',
      source: 'FNO benchmark',
      fingerprint: 'a41f09c2e7d1b356',
      usedBy: usedBy('ns2d-vorticity-v3'),
      variables: const [
        DatasetVariable(
          name: 'a',
          description: 'Initial vorticity',
          shape: [1200, 64, 64],
          dtype: 'float32',
          min: -2.9,
          max: 3.1,
          mean: 0,
          std: 0.97,
        ),
        DatasetVariable(
          name: 'u',
          description: 'Vorticity over time',
          shape: [1200, 64, 64, 50],
          dtype: 'float32',
          min: -4.1,
          max: 4.3,
          mean: 0,
          std: 0.88,
        ),
        DatasetVariable(
          name: 't',
          description: 'Time',
          shape: [50],
          dtype: 'float32',
          min: 1,
          max: 50,
        ),
      ],
      previews: [
        for (var i = 0; i < 4; i++) _preview('sample $i', 48, 48, (x, y) => _vortices(x, y, i)),
      ],
      createdAt: now.subtract(const Duration(days: 11)),
      updatedAt: now.subtract(const Duration(hours: 1)),
    ),
    Dataset(
      id: 'turbulence-3d-box',
      name: 'turbulence-3d-box',
      description: 'Decaying homogeneous turbulence in a periodic box, 20 snapshots each.',
      samples: 512,
      splits: const {'train': 448, 'val': 64},
      sampleShape: const [32, 32, 32, 20],
      sizeBytes: (1.34 * gb).round(),
      files: 8,
      format: 'HDF5',
      location: '/scratch/users/demo/data/turbulence-3d/',
      host: 'Sherlock',
      source: 'Simulated',
      fingerprint: '5c0e88a1f4b2d907',
      usedBy: usedBy('turbulence-3d-box'),
      variables: const [
        DatasetVariable(
          name: 'vorticity',
          description: 'Vorticity magnitude',
          shape: [512, 32, 32, 32, 20],
          dtype: 'float32',
          min: 0,
          max: 18.2,
          mean: 2.4,
          std: 1.9,
        ),
      ],
      previews: [
        for (var i = 0; i < 4; i++)
          _preview('sample $i', 32, 32, (x, y) => _vortices(x, y, 10 + i).abs()),
      ],
      createdAt: now.subtract(const Duration(days: 20)),
      updatedAt: now.subtract(const Duration(days: 2)),
    ),
    Dataset(
      id: 'rb3d-snapshots',
      name: 'rb3d-snapshots',
      description: 'Temperature, velocity and pressure every 0.5 time units, Ra = 1e8.',
      samples: 400,
      sampleShape: const [5, 256, 256, 256],
      sizeBytes: 1200 * gb,
      files: 400,
      format: 'Zarr',
      location: 'gs://demo-convection/rb3d-snapshots.zarr',
      host: 'GCP',
      source: 'Simulated',
      fingerprint: '91d3aa0be6c45f12',
      madeBy: madeBy('rayleigh-benard-3d'),
      system: systemOf('rayleigh-benard-3d'),
      variables: const [
        DatasetVariable(
          name: 'T',
          description: 'Temperature',
          shape: [400, 256, 256, 256],
          dtype: 'float32',
          min: 0,
          max: 1,
        ),
        DatasetVariable(
          name: 'u',
          description: 'Velocity',
          shape: [400, 3, 256, 256, 256],
          dtype: 'float32',
          min: -0.41,
          max: 0.43,
        ),
        DatasetVariable(
          name: 'p',
          description: 'Pressure',
          shape: [400, 256, 256, 256],
          dtype: 'float32',
          min: -0.08,
          max: 0.09,
        ),
      ],
      previews: [
        for (var i = 0; i < 4; i++)
          _preview(
            'sample ${i * 100}',
            48,
            24,
            (x, y) =>
                (1 - y) + 0.3 * math.sin(math.pi * y) * math.cos(2 * math.pi * (x * 2 + 0.2 * i)),
          ),
      ],
      createdAt: now.subtract(const Duration(hours: 1)),
      updatedAt: now.subtract(const Duration(minutes: 5)),
    ),
    Dataset(
      id: 'cylinder-wake-fields',
      name: 'cylinder-wake-fields',
      description: 'Vorticity behind a cylinder at Re = 200, after the wake settled.',
      samples: 600,
      sampleShape: const [48, 128],
      sizeBytes: (0.015 * gb).round(),
      files: 1,
      format: 'NumPy (npz)',
      location: '/home/ubuntu/runs/cylinder-wake/fields.npz',
      host: 'AWS',
      source: 'Simulated',
      fingerprint: '0b7f3e21c9a8d654',
      madeBy: madeBy('cylinder-wake-re200'),
      system: systemOf('cylinder-wake-re200'),
      variables: const [
        DatasetVariable(
          name: 'vorticity',
          shape: [600, 48, 128],
          dtype: 'float32',
          min: -2.6,
          max: 2.6,
          mean: 0,
          std: 0.41,
        ),
        DatasetVariable(name: 't', shape: [600], dtype: 'float64', min: 200, max: 300),
      ],
      previews: [
        for (var i = 0; i < 4; i++) _preview('sample ${i * 150}', 96, 36, (x, y) => _wake(x, y, i)),
      ],
      createdAt: now.subtract(const Duration(days: 2)),
      updatedAt: now.subtract(const Duration(days: 2)),
    ),
    Dataset(
      id: 'piv-channel-flow',
      name: 'piv-channel-flow',
      description: 'Particle image velocimetry of a turbulent channel, Re_tau = 550.',
      samples: 18000,
      sampleShape: const [2, 128, 256],
      sizeBytes: 210 * gb,
      files: 36,
      format: 'NetCDF',
      location: '/lab-nas/piv/channel-2026-10/',
      host: 'Lab NAS',
      source: 'Experiment',
      fingerprint: 'e2a6c04d81f9b375',
      variables: const [
        DatasetVariable(
          name: 'u',
          description: 'Streamwise velocity',
          unit: 'm/s',
          shape: [18000, 128, 256],
          dtype: 'float32',
          min: -0.2,
          max: 1.9,
        ),
        DatasetVariable(
          name: 'v',
          description: 'Wall-normal velocity',
          unit: 'm/s',
          shape: [18000, 128, 256],
          dtype: 'float32',
          min: -0.6,
          max: 0.6,
        ),
      ],
      previews: [
        for (var i = 0; i < 4; i++)
          _preview(
            'frame ${i * 4500}',
            64,
            32,
            (x, y) =>
                1.2 * math.pow(math.sin(math.pi * y), 0.3) +
                0.15 * math.sin(17 * x + 5 * y + i) * math.sin(math.pi * y),
          ),
      ],
      createdAt: now.subtract(const Duration(days: 30)),
      updatedAt: now.subtract(const Duration(days: 30)),
    ),
    Dataset(
      id: 'cifar10',
      name: 'cifar10',
      description: '60,000 colour images in 10 classes.',
      samples: 60000,
      splits: const {'train': 50000, 'test': 10000},
      sampleShape: const [32, 32, 3],
      sizeBytes: (0.178 * gb).round(),
      files: 6,
      format: 'NumPy',
      location: '/scratch/users/demo/data/cifar10/',
      host: 'Sherlock',
      source: 'Imported',
      fingerprint: '7d1c55e0a39b2f48',
      usedBy: usedBy('cifar10'),
      variables: const [
        DatasetVariable(
          name: 'images',
          shape: [60000, 32, 32, 3],
          dtype: 'uint8',
          min: 0,
          max: 255,
        ),
        DatasetVariable(
          name: 'labels',
          description: '10 classes',
          shape: [60000],
          dtype: 'int64',
          min: 0,
          max: 9,
        ),
      ],
      createdAt: now.subtract(const Duration(days: 40)),
      updatedAt: now.subtract(const Duration(days: 40)),
    ),
    Dataset(
      id: 'openwebtext',
      name: 'openwebtext',
      description: 'Web text, tokenized with the GPT-2 tokenizer.',
      sizeBytes: 18 * gb,
      files: 2,
      format: 'Binary',
      location: 's3://demo-text/openwebtext/',
      host: 'AWS',
      source: 'Imported',
      fingerprint: '3f8b0d6a2c1e9475',
      usedBy: usedBy('openwebtext'),
      variables: const [
        DatasetVariable(name: 'tokens', shape: [9035582489], dtype: 'uint16', min: 0, max: 50256),
      ],
      createdAt: now.subtract(const Duration(days: 9)),
      updatedAt: now.subtract(const Duration(days: 9)),
    ),
    Dataset(
      id: 'carvana',
      name: 'carvana',
      description: 'Car photos with their masks.',
      samples: 5088,
      splits: const {'train': 4580, 'val': 508},
      sampleShape: const [1280, 1918, 3],
      sizeBytes: (24.4 * gb).round(),
      files: 10176,
      format: 'JPEG',
      location: '/scratch/users/demo/data/carvana/',
      host: 'Sherlock',
      source: 'Kaggle',
      fingerprint: 'c4e19a7b06d2f583',
      usedBy: usedBy('carvana'),
      createdAt: now.subtract(const Duration(days: 6)),
      updatedAt: now.subtract(const Duration(days: 6)),
    ),
  ];
}

/// A sample as a small map: [f] on an [nx] × [ny] grid (rows are y).
FieldSnapshot _preview(String name, int nx, int ny, double Function(double x, double y) f) {
  final values = Float32List(nx * ny);
  for (var j = 0; j < ny; j++) {
    for (var i = 0; i < nx; i++) {
      values[j * nx + i] = f((i + 0.5) / nx, (j + 0.5) / ny);
    }
  }
  return FieldSnapshot(name: name, step: 0, shape: [ny, nx], prediction: values);
}

/// A few vortices of either sign on the unit torus, placed by [seed].
double _vortices(double x, double y, int seed) {
  final random = math.Random(seed);
  var w = 0.0;
  for (var k = 0; k < 7; k++) {
    final cx = random.nextDouble(), cy = random.nextDouble();
    final sign = random.nextBool() ? 1 : -1;
    final size = 0.004 + 0.01 * random.nextDouble();
    var dx = (x - cx).abs(), dy = (y - cy).abs();
    dx = math.min(dx, 1 - dx);
    dy = math.min(dy, 1 - dy);
    w += sign * math.exp(-(dx * dx + dy * dy) / size);
  }
  return w;
}

/// A vortex street behind a cylinder, shifted along by [phase].
double _wake(double x, double y, int phase) {
  final px = 10 * x, py = 4 * y - 2;
  if (px < 0.8) return 0;
  var w = 0.0;
  for (var k = 0; k < 8; k++) {
    final xk = 1.6 + 0.6 * phase + 1.25 * k;
    final yk = (k.isEven ? 1 : -1) * 0.4;
    w += (k.isEven ? 1 : -1) * math.exp(-(math.pow(px - xk, 2) + math.pow(py - yk, 2)) / 0.12);
  }
  return w;
}
