import 'model_helpers.dart';

/// How a whole validation set went at one step (`run.log_eval`): the
/// relative L2 error of every sample, summarized, and its worst samples.
class EvalStep {
  const EvalStep({
    required this.step,
    required this.count,
    this.stats = const {},
    this.histogram,
    this.worst = const [],
  });

  factory EvalStep.fromJson(Map<String, Object?> json) => EvalStep(
    step: (json['step']! as num).toInt(),
    count: (json['count']! as num).toInt(),
    stats: Map.unmodifiable({
      for (final e in ((json['stats'] as Map?) ?? const {}).entries)
        e.key as String: decodeDouble(e.value),
    }),
    histogram: switch (json['histogram']) {
      final Map<String, Object?> h => ErrorHistogram(
        edges: List.unmodifiable([for (final v in h['edges']! as List) decodeDouble(v)]),
        counts: List.unmodifiable([for (final v in h['counts']! as List) (v as num).toInt()]),
      ),
      _ => null,
    },
    worst: List.unmodifiable([
      for (final w in (json['worst'] as List?) ?? const [])
        WorstSample(
          rank: ((w as Map)['rank'] as num).toInt(),
          sample: (w['sample'] as num).toInt(),
          relL2: decodeDouble(w['relL2']),
        ),
    ]),
  );

  final int step;

  /// Samples in the validation set.
  final int count;

  /// `median`, `p90`, `max`, `mean`, `min` (relative L2) and `nonFinite`.
  final Map<String, double> stats;
  final ErrorHistogram? histogram;

  /// Worst first.
  final List<WorstSample> worst;

  Map<String, Object?> toJson() => {
    'step': step,
    'count': count,
    'stats': {for (final e in stats.entries) e.key: encodeDouble(e.value)},
    'histogram': histogram == null
        ? null
        : {
            'edges': [for (final v in histogram!.edges) encodeDouble(v)],
            'counts': histogram!.counts,
          },
    'worst': [
      for (final w in worst) {'rank': w.rank, 'sample': w.sample, 'relL2': encodeDouble(w.relL2)},
    ],
  };
}

/// Counts of samples per error bin; [edges] has one more entry than
/// [counts], log-spaced.
class ErrorHistogram {
  const ErrorHistogram({required this.edges, required this.counts});

  final List<double> edges;
  final List<int> counts;
}

/// One of a validation set's worst samples: the field snapshot named
/// `worst/<name>/<rank>` holds its prediction and target.
class WorstSample {
  const WorstSample({required this.rank, required this.sample, required this.relL2});

  final int rank;

  /// Its index in the validation set.
  final int sample;
  final double relL2;

  /// The field snapshot with this sample, for the field [name].
  String fieldName(String name) => 'worst/$name/$rank';
}

/// A curve logged at one step (`run.log_curve`), e.g. the error against
/// the grid resolution or a PDE parameter.
class CurveStep {
  const CurveStep({
    required this.step,
    required this.x,
    required this.y,
    this.xLabel = '',
    this.yLabel = '',
    this.trainRange,
  });

  factory CurveStep.fromJson(Map<String, Object?> json) => CurveStep(
    step: (json['step']! as num).toInt(),
    x: List.unmodifiable([for (final v in json['x']! as List) decodeDouble(v)]),
    y: List.unmodifiable([for (final v in json['y']! as List) decodeDouble(v)]),
    xLabel: json['xLabel'] as String? ?? '',
    yLabel: json['yLabel'] as String? ?? '',
    trainRange: switch (json['trainRange']) {
      [final a, final b] => (decodeDouble(a), decodeDouble(b)),
      _ => null,
    },
  );

  final int step;
  final List<double> x;
  final List<double> y;
  final String xLabel;
  final String yLabel;

  /// The x values seen in training: outside it, the model extrapolates.
  final (double, double)? trainRange;

  Map<String, Object?> toJson() => {
    'step': step,
    'x': [for (final v in x) encodeDouble(v)],
    'y': [for (final v in y) encodeDouble(v)],
    'xLabel': xLabel,
    'yLabel': yLabel,
    'trainRange': trainRange == null
        ? null
        : [encodeDouble(trainRange!.$1), encodeDouble(trainRange!.$2)],
  };
}

/// Everything logged under one name, in step order: evals or curves.
class LoggedSeries<T> {
  const LoggedSeries({required this.name, required this.steps});

  final String name;
  final List<T> steps;

  /// The latest step at or before [step]; the first one if none is.
  T atOrBefore(int step, int Function(T) stepOf) {
    var chosen = steps.first;
    for (final s in steps) {
      if (stepOf(s) <= step) chosen = s;
    }
    return chosen;
  }

  static LoggedSeries<T> fromJson<T>(
    Map<String, Object?> json,
    T Function(Map<String, Object?>) item,
  ) => LoggedSeries(
    name: json['name']! as String,
    steps: List.unmodifiable([
      for (final s in json['steps']! as List) item(s as Map<String, Object?>),
    ]),
  );
}

/// A metric's latest value (by step) and its lowest finite one, per run:
/// what a sweep compares.
class LatestMetric {
  const LatestMetric({required this.latest, this.min});

  factory LatestMetric.fromJson(Map<String, Object?> json) => LatestMetric(
    latest: decodeDouble(json['latest']),
    min: json['min'] == null ? null : decodeDouble(json['min']),
  );

  final double latest;
  final double? min;

  Map<String, Object?> toJson() => {
    'latest': encodeDouble(latest),
    'min': min == null ? null : encodeDouble(min!),
  };
}
