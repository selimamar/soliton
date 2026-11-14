import 'field_snapshot.dart';
import 'model_helpers.dart';
import 'run.dart';
import 'system_info.dart';

/// A dataset the server knows about (`soliton.register_dataset`, or
/// `soliton data scan`): what it is, where it lives, what is in it, who
/// made it and who trained on it. The data itself stays where it is.
class Dataset {
  const Dataset({
    required this.id,
    required this.name,
    this.version = '',
    this.description = '',
    this.samples,
    this.splits = const {},
    this.sampleShape,
    this.sizeBytes,
    this.files,
    this.format = '',
    this.location = '',
    this.host = '',
    this.source = '',
    this.fingerprint = '',
    this.system,
    this.madeBy,
    this.usedBy = const [],
    this.variables = const [],
    this.previews = const [],
    this.createdAt,
    this.updatedAt,
  });

  factory Dataset.fromJson(Map<String, Object?> json) => Dataset(
    id: json['id']! as String,
    name: json['name']! as String,
    version: json['version'] as String? ?? '',
    description: json['description'] as String? ?? '',
    samples: (json['samples'] as num?)?.toInt(),
    splits: Map.unmodifiable({
      for (final MapEntry(:key, :value) in ((json['splits'] as Map?) ?? const {}).entries)
        key as String: (value as num).toInt(),
    }),
    sampleShape: switch (json['sampleShape']) {
      final List<Object?> s => List.unmodifiable([for (final n in s) (n! as num).toInt()]),
      _ => null,
    },
    sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
    files: (json['files'] as num?)?.toInt(),
    format: json['format'] as String? ?? '',
    location: json['location'] as String? ?? '',
    host: json['host'] as String? ?? '',
    source: json['source'] as String? ?? '',
    fingerprint: json['fingerprint'] as String? ?? '',
    system: switch (json['system']) {
      final Map<String, Object?> s => SystemInfo.fromJson(s),
      _ => null,
    },
    madeBy: switch (json['madeBy']) {
      final Map<String, Object?> m => DatasetUser.fromJson(m),
      _ => null,
    },
    usedBy: List.unmodifiable([
      for (final u in (json['usedBy'] as List?) ?? const [])
        DatasetUser.fromJson(u as Map<String, Object?>),
    ]),
    variables: List.unmodifiable([
      for (final v in (json['variables'] as List?) ?? const [])
        DatasetVariable.fromJson(v as Map<String, Object?>),
    ]),
    previews: List.unmodifiable([
      for (final p in (json['previews'] as List?) ?? const [])
        FieldSnapshot.fromJson({...p as Map<String, Object?>, 'step': 0, 'prediction': p['data']}),
    ]),
    createdAt: switch (json['createdAt']) {
      final String s => DateTime.parse(s),
      _ => null,
    },
    updatedAt: switch (json['updatedAt']) {
      final String s => DateTime.parse(s),
      _ => null,
    },
  );

  final String id;
  final String name;

  /// E.g. `v3`; empty if not given.
  final String version;
  final String description;

  /// How many samples, and how they're split (e.g. `{'train': 8000}`).
  final int? samples;
  final Map<String, int> splits;

  /// One sample's shape, e.g. `[64, 64, 50]`.
  final List<int>? sampleShape;
  final int? sizeBytes;

  /// Files it is made of (1 for a single file).
  final int? files;

  /// E.g. `HDF5`, `NumPy`, `Zarr`.
  final String format;

  /// Where it is (a path on [host], e.g. `Sherlock`).
  final String location;
  final String host;

  /// How it was obtained, e.g. `Simulated`, `Experiment`, `FNO benchmark`.
  final String source;

  /// Changes when the files do.
  final String fingerprint;

  /// The machine it was made on, when its maker said.
  final SystemInfo? system;

  /// The run or simulation that made it.
  final DatasetUser? madeBy;

  /// The runs (and simulations) that train or are evaluated on it.
  final List<DatasetUser> usedBy;
  final List<DatasetVariable> variables;

  /// A few samples, small (only on the dataset's own page).
  final List<FieldSnapshot> previews;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// "ns2d-vorticity · v3".
  String get title => version.isEmpty ? name : '$name · $version';
}

/// A run or simulation, as a dataset names it.
class DatasetUser {
  const DatasetUser({
    required this.id,
    required this.name,
    this.project = '',
    this.status,
    this.simulation = false,
  });

  factory DatasetUser.fromJson(Map<String, Object?> json) => DatasetUser(
    id: json['id']! as String,
    name: json['name'] as String? ?? json['id']! as String,
    project: json['project'] as String? ?? '',
    status: RunStatus.values.asNameMap()[json['status']],
    simulation: json['simulation'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String project;

  /// Null if the server doesn't have the run (yet).
  final RunStatus? status;
  final bool simulation;
}

/// An array in a dataset, e.g. the vorticity `w`, with its range over the
/// first samples.
class DatasetVariable {
  const DatasetVariable({
    required this.name,
    this.description = '',
    this.unit = '',
    this.shape,
    this.dtype = '',
    this.min,
    this.max,
    this.mean,
    this.std,
  });

  factory DatasetVariable.fromJson(Map<String, Object?> json) {
    double? number(Object? v) => v == null ? null : decodeDouble(v);
    return DatasetVariable(
      name: json['name']! as String,
      description: json['description'] as String? ?? '',
      unit: json['unit'] as String? ?? '',
      shape: switch (json['shape']) {
        final List<Object?> s => List.unmodifiable([for (final n in s) (n! as num).toInt()]),
        _ => null,
      },
      dtype: json['dtype'] as String? ?? '',
      min: number(json['min']),
      max: number(json['max']),
      mean: number(json['mean']),
      std: number(json['std']),
    );
  }

  final String name;
  final String description;
  final String unit;
  final List<int>? shape;
  final String dtype;
  final double? min;
  final double? max;
  final double? mean;
  final double? std;
}
