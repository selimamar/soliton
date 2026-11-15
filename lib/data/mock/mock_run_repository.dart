import '../../models/dataset.dart';
import '../../models/field_snapshot.dart';
import '../../models/layer_stats.dart';
import '../../models/metric_series.dart';
import '../../models/run.dart';
import '../../models/run_insights.dart';
import '../../models/run_output.dart';
import '../../models/logged_image.dart';
import '../run_repository.dart';
import '../tags.dart';
import 'mock_runs.dart';
import 'mock_datasets.dart';
import 'mock_output.dart';
import 'mock_simulations.dart';
import 'mock_images.dart';

/// A [RunRepository] serving generated demo data, with a fake network delay.
/// Edited tags and notes, and deletions, are kept in memory, until the app
/// restarts.
class MockRunRepository implements RunRepository {
  MockRunRepository({this.latency = const Duration(milliseconds: 350)})
    : _runs = _build(DateTime.now());

  static List<MockRun> _build(DateTime now) => [
    for (final r in [...buildMockRuns(now), ...buildMockSimulations(now)])
      if (mockRunDatasets(r.run.id) case final datasets when datasets.isNotEmpty)
        MockRun(
          run: Run.fromJson({...r.run.toJson(), 'datasets': datasets}),
          metrics: r.metrics,
          layerStats: r.layerStats,
          fields: r.fields,
          extras: r.extras,
        )
      else
        r,
  ];

  final _builtAt = DateTime.now();
  final _deletedDatasets = <String>{};

  /// Rebuilt when a run is deleted, so no dataset names it any more.
  late List<Dataset> _datasets = _buildDatasets();

  List<Dataset> _buildDatasets() => [
    for (final d in buildMockDatasets(_builtAt, [for (final r in _runs) r.run]))
      if (!_deletedDatasets.contains(d.id)) d,
  ];

  @override
  Future<void> deleteRun(String runId) async {
    await Future<void>.delayed(latency);
    _runs.removeWhere((r) => r.run.id == runId);
    _edited.remove(runId);
    _datasets = _buildDatasets();
  }

  /// Runs asked to stop, and when (demo data: they keep "running").
  final _stopRequested = <String, DateTime>{};

  @override
  Future<Run> requestStop(String runId) async {
    await Future<void>.delayed(latency);
    _find(runId);
    _stopRequested[runId] ??= DateTime.now();
    return _withEdits(_find(runId).run);
  }

  @override
  Future<void> deleteDataset(String datasetId) async {
    await Future<void>.delayed(latency);
    _deletedDatasets.add(datasetId);
    _datasets = _buildDatasets();
  }

  @override
  Future<List<Dataset>> fetchDatasets() async {
    await Future<void>.delayed(latency);
    return _datasets;
  }

  @override
  Future<Dataset> fetchDataset(String datasetId) async {
    await Future<void>.delayed(latency);
    for (final dataset in _datasets) {
      if (dataset.id == datasetId) return dataset;
    }
    throw DatasetNotFoundException(datasetId);
  }

  final Duration latency;
  final List<MockRun> _runs;
  final _edited = <String, ({List<String> tags, String notes})>{};

  @override
  Future<List<Run>> fetchRuns() async {
    await Future<void>.delayed(latency);
    return [for (final r in _runs) _withEdits(r.run)];
  }

  @override
  Future<Run> fetchRun(String runId) async {
    await Future<void>.delayed(latency);
    return _withEdits(_find(runId).run);
  }

  @override
  Future<Run> updateNotes(String runId, {List<String>? tags, String? notes}) async {
    await Future<void>.delayed(latency);
    final run = _withEdits(_find(runId).run);
    _edited[runId] = (
      tags: List.unmodifiable(tags == null ? run.tags : cleanTags(tags)),
      notes: notes ?? run.notes,
    );
    return _withEdits(run);
  }

  Run _withEdits(Run run) {
    final edit = _edited[run.id];
    final stop = _stopRequested[run.id];
    if (edit == null && stop == null) return run;
    return Run.fromJson({
      ...run.toJson(),
      if (edit != null) ...{'tags': edit.tags, 'notes': edit.notes},
      if (stop != null) 'stopRequestedAt': stop.toIso8601String(),
    });
  }

  @override
  Future<Map<String, MetricSeries>> fetchMetrics(String runId) async {
    await Future<void>.delayed(latency);
    return _find(runId).metrics;
  }

  @override
  Future<List<LayerStats>> fetchLayerStats(String runId) async {
    await Future<void>.delayed(latency);
    return _find(runId).layerStats;
  }

  @override
  Future<List<LayerGradNorm>> fetchLayerGradNorms(String runId) async {
    await Future<void>.delayed(latency);
    return [
      for (final layer in _find(runId).layerStats)
        LayerGradNorm(layerName: layer.layerName, gradNorm: layer.gradNorm.latest ?? double.nan),
    ];
  }

  @override
  Future<List<FieldSummary>> fetchFields(String runId) async {
    await Future<void>.delayed(latency);
    return [for (final field in _find(runId).fields) field.summary()];
  }

  @override
  Future<FieldSnapshot> fetchFieldSnapshot(String runId, String name, int step) async {
    await Future<void>.delayed(latency);
    for (final field in _find(runId).fields) {
      if (field.name == name) {
        if (field.snapshot(step) case final snapshot?) return snapshot;
      }
    }
    throw FieldNotFoundException(name, step);
  }

  late final Map<String, List<LoggedImage>> _images = mockImages(
    (id) => _runs.where((r) => r.run.id == id).firstOrNull?.run.currentStep ?? 0,
  );

  @override
  Future<List<ImageSeries>> fetchImages(String runId) async {
    await Future<void>.delayed(latency);
    _find(runId);
    final byName = <String, List<LoggedImage>>{};
    for (final image in _images[runId] ?? const <LoggedImage>[]) {
      byName.putIfAbsent(image.name, () => []).add(image);
    }
    return [
      for (final MapEntry(key: name, value: images) in byName.entries)
        ImageSeries(
          name: name,
          steps: [
            for (final i in images)
              ImageStep(step: i.step, width: i.width, height: i.height, caption: i.caption),
          ],
        ),
    ];
  }

  @override
  Future<LoggedImage> fetchImage(String runId, String name, int step) async {
    await Future<void>.delayed(latency);
    _find(runId);
    for (final image in _images[runId] ?? const <LoggedImage>[]) {
      if (image.name == name && image.step == step) return image;
    }
    throw ImageNotFoundException(name, step);
  }

  @override
  Future<List<LoggedSeries<EvalStep>>> fetchEvals(String runId) async {
    await Future<void>.delayed(latency);
    return _find(runId).evals;
  }

  @override
  Future<List<LoggedSeries<CurveStep>>> fetchCurves(String runId) async {
    await Future<void>.delayed(latency);
    return _find(runId).curves;
  }

  @override
  Future<RunOutput> fetchOutput(String runId) async {
    await Future<void>.delayed(latency);
    return mockOutput(_find(runId).run);
  }

  @override
  Future<Map<String, Map<String, LatestMetric>>> fetchLatestMetrics(List<String> names) async {
    await Future<void>.delayed(latency);
    return {
      for (final mock in _runs)
        if (names.where(mock.metrics.containsKey).isNotEmpty)
          mock.run.id: {
            for (final name in names)
              if (mock.metrics[name] case final series? when series.points.isNotEmpty)
                name: LatestMetric(
                  latest: series.points.last.value,
                  min: series.points
                      .map((p) => p.value)
                      .where((v) => v.isFinite)
                      .fold<double?>(null, (a, b) => a == null || b < a ? b : a),
                ),
          },
    };
  }

  MockRun _find(String runId) =>
      _runs.firstWhere((r) => r.run.id == runId, orElse: () => throw RunNotFoundException(runId));
}
