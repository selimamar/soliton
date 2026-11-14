import 'model_helpers.dart';

/// What makes a run a simulation (a PDE solve, or any computation stepping
/// through time or iterating to convergence), as `soliton.simulate()`
/// describes it. Its values are ordinary metrics, its simulated time the
/// metric [time].
class SimulationInfo {
  const SimulationInfo({
    this.tEnd,
    this.time,
    this.cflLimit,
    this.monitor,
    this.preview = const [],
    this.diverged = false,
  });

  factory SimulationInfo.fromJson(Map<String, Object?> json) => SimulationInfo(
    tEnd: (json['tEnd'] as num?)?.toDouble(),
    time: json['time'] == null ? null : decodeDouble(json['time']),
    cflLimit: (json['cflLimit'] as num?)?.toDouble(),
    monitor: json['monitor'] as String?,
    preview: List.unmodifiable([
      for (final v in (json['preview'] as List?) ?? const []) decodeDouble(v),
    ]),
    diverged: json['diverged'] as bool? ?? false,
  );

  /// The metric holding the simulated time, and the time step.
  static const timeKey = 'sim/t';
  static const timeStepKey = 'sim/dt';

  /// The simulated time it runs to; null for a steady solve (its progress
  /// is then its iterations, `Run.totalSteps`).
  final double? tEnd;

  /// The latest simulated time logged.
  final double? time;

  /// Drawn on the chart of a value named "cfl".
  final double? cflLimit;

  /// The value previewed in the list, e.g. `energy`; [preview] its values.
  final String? monitor;
  final List<double> preview;

  /// Crashed because a value turned NaN or infinite.
  final bool diverged;

  /// How far through [tEnd] it is (0–1), or null if that isn't known.
  double? get timeProgress {
    final (end, now) = (tEnd, time);
    if (end == null || end <= 0 || now == null || !now.isFinite) return null;
    return (now / end).clamp(0.0, 1.0).toDouble();
  }

  Map<String, Object?> toJson() => {
    'tEnd': ?tEnd,
    'time': time == null ? null : encodeDouble(time!),
    'cflLimit': ?cflLimit,
    'monitor': ?monitor,
    'preview': [for (final v in preview) encodeDouble(v)],
    if (diverged) 'diverged': true,
  };

  @override
  bool operator ==(Object other) =>
      other is SimulationInfo &&
      other.tEnd == tEnd &&
      (other.time == null || time == null ? other.time == time : sameDouble(other.time!, time!)) &&
      other.cflLimit == cflLimit &&
      other.monitor == monitor &&
      sameDoubles(other.preview, preview) &&
      other.diverged == diverged;

  @override
  int get hashCode => Object.hash(
    tEnd,
    time == null ? null : doubleHash(time!),
    cflLimit,
    monitor,
    Object.hashAll(preview.map(doubleHash)),
    diverged,
  );
}
