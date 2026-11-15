import 'run.dart';

/// How much space a server's database takes, and each run's share
/// (`GET /api/storage`).
class StorageReport {
  const StorageReport({
    required this.engine,
    this.bytes,
    this.free,
    required this.runs,
    this.thinPoints = 1000,
  });

  factory StorageReport.fromJson(Map<String, Object?> json) {
    final database = json['database'] as Map<String, Object?>? ?? const {};
    return StorageReport(
      engine: database['engine'] as String? ?? 'sqlite',
      bytes: (database['bytes'] as num?)?.toInt(),
      free: (database['free'] as num?)?.toInt(),
      runs: List.unmodifiable([
        for (final run in (json['runs'] as List?) ?? const [])
          RunStorage.fromJson(run as Map<String, Object?>),
      ]),
      thinPoints: (json['thinPoints'] as num?)?.toInt() ?? 1000,
    );
  }

  /// "sqlite" or "postgresql".
  final String engine;

  /// The database's size on disk; null if the server can't tell.
  final int? bytes;

  /// Space a compact would give back to the disk (SQLite only).
  final int? free;

  /// Largest first.
  final List<RunStorage> runs;

  /// Points per curve a thinned run keeps.
  final int thinPoints;

  bool get canCompact => engine == 'sqlite' && (free ?? 0) > 0;
}

/// One run's share of the database: an estimate from what it stores.
class RunStorage {
  const RunStorage({
    required this.runId,
    required this.name,
    this.project = '',
    required this.status,
    this.endedAt,
    required this.bytes,
    this.points = 0,
    this.layerPoints = 0,
    this.snapshots = 0,
    this.thinnedAt,
    this.simulation = false,
    this.thinnable = false,
  });

  factory RunStorage.fromJson(Map<String, Object?> json) => RunStorage(
    runId: json['runId']! as String,
    name: json['name'] as String? ?? json['runId']! as String,
    project: json['project'] as String? ?? '',
    status: RunStatus.values.asNameMap()[json['status']] ?? RunStatus.finished,
    endedAt: _time(json['endedAt']),
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    points: (json['points'] as num?)?.toInt() ?? 0,
    layerPoints: (json['layerPoints'] as num?)?.toInt() ?? 0,
    snapshots: (json['snapshots'] as num?)?.toInt() ?? 0,
    thinnedAt: _time(json['thinnedAt']),
    simulation: json['simulation'] == true,
    thinnable: json['thinnable'] == true,
  );

  final String runId;
  final String name;
  final String project;
  final RunStatus status;
  final DateTime? endedAt;
  final int bytes;

  /// Values of scalar metrics, layer statistics, field snapshots it keeps.
  final int points;
  final int layerPoints;
  final int snapshots;

  /// When it was thinned out; null if it keeps everything.
  final DateTime? thinnedAt;

  /// A simulation (shown under Compute), not a training run.
  final bool simulation;

  bool get ended => status == RunStatus.finished || status == RunStatus.crashed;

  /// Whether thinning would free anything: it ended, and keeps more points
  /// of some curve than a thinned one does, or older field snapshots (the
  /// server tells).
  final bool thinnable;

  static DateTime? _time(Object? value) => value is String ? DateTime.tryParse(value) : null;
}
