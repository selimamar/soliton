import '../models/dataset.dart';
import '../models/field_snapshot.dart';
import '../models/layer_stats.dart';
import '../models/metric_series.dart';
import '../models/run.dart';
import '../models/run_insights.dart';
import '../models/run_output.dart';
import '../models/logged_image.dart';
import 'run_repository.dart';

/// No runs, simulations or datasets: what the app reads while no server is
/// connected and demo data is off. Anything asked for by id doesn't exist.
class EmptyRunRepository implements RunRepository {
  const EmptyRunRepository();

  @override
  Future<List<Run>> fetchRuns() async => const [];

  @override
  Future<Run> fetchRun(String runId) => Future.error(RunNotFoundException(runId));

  @override
  Future<Map<String, MetricSeries>> fetchMetrics(String runId) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<List<LayerStats>> fetchLayerStats(String runId) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<List<LayerGradNorm>> fetchLayerGradNorms(String runId) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<List<FieldSummary>> fetchFields(String runId) => Future.error(RunNotFoundException(runId));

  @override
  Future<List<ImageSeries>> fetchImages(String runId) => Future.error(RunNotFoundException(runId));

  @override
  Future<LoggedImage> fetchImage(String runId, String name, int step) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<FieldSnapshot> fetchFieldSnapshot(String runId, String name, int step) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<List<LoggedSeries<EvalStep>>> fetchEvals(String runId) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<List<LoggedSeries<CurveStep>>> fetchCurves(String runId) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<Map<String, Map<String, LatestMetric>>> fetchLatestMetrics(List<String> names) async =>
      const {};

  @override
  Future<RunOutput> fetchOutput(String runId) => Future.error(RunNotFoundException(runId));

  @override
  Future<List<Dataset>> fetchDatasets() async => const [];

  @override
  Future<Dataset> fetchDataset(String datasetId) =>
      Future.error(DatasetNotFoundException(datasetId));

  @override
  Future<Run> updateNotes(String runId, {List<String>? tags, String? notes}) =>
      Future.error(RunNotFoundException(runId));

  @override
  Future<void> deleteRun(String runId) async {}

  @override
  Future<Run> requestStop(String runId) => Future.error(RunNotFoundException(runId));

  @override
  Future<void> deleteDataset(String datasetId) async {}
}
