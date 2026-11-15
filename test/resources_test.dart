import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/features/run_detail/resource_fit.dart';
import 'package:soliton/features/run_detail/system_usage.dart';
import 'package:soliton/features/run_detail/widgets/resources_card.dart';
import 'package:soliton/models/layer_info.dart';
import 'package:soliton/models/metric_series.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/models/system_info.dart';

import 'test_app.dart';

final _start = DateTime.utc(2026, 11, 14, 8);

Run _run({
  RunStatus status = RunStatus.finished,
  Duration took = const Duration(hours: 2),
  double memoryGb = 64,
  double cores = 16,
  int gpus = 2,
  Map<String, String> slurm = const {'jobId': '123'},
}) => Run(
  id: 'r',
  name: 'r',
  project: '',
  host: 'Sherlock',
  status: status,
  startedAt: _start,
  endedAt: status == RunStatus.live ? null : _start.add(took),
  currentStep: 100,
  totalSteps: 100,
  currentEpoch: 0,
  totalEpochs: 0,
  hyperparameters: const {},
  architecture: const LayerInfo(name: 'r', type: 'Model'),
  lossPreview: const [],
  system: SystemInfo(
    cpuCores: cores,
    memoryGb: memoryGb,
    gpus: [
      for (var i = 0; i < gpus; i++) const GpuInfo(name: 'NVIDIA A100-SXM4-80GB', memoryGb: 80),
    ],
    slurm: {
      ...slurm,
      'startTime': _start.toIso8601String(),
      'timeLimitAt': _start.add(const Duration(hours: 12)).toIso8601String(),
    },
  ),
);

MetricSeries _series(String name, List<double> values) =>
    MetricSeries(name: name, points: [for (final (i, v) in values.indexed) MetricPoint(i, v)]);

SystemUsage _usage({
  List<double> memory = const [2, 9, 8],
  List<double> cpu = const [5, 15, 10],
  List<List<double>> gpu = const [
    [88, 92],
    [0, 2],
  ],
}) => SystemUsage.from({
  MetricKeys.memoryGb: _series(MetricKeys.memoryGb, memory),
  MetricKeys.cpu: _series(MetricKeys.cpu, cpu),
  for (final (i, values) in gpu.indexed) ...{
    MetricKeys.gpu(i, 'utilization'): _series(MetricKeys.gpu(i, 'utilization'), values),
    MetricKeys.gpu(i, 'memory_gb'): _series(MetricKeys.gpu(i, 'memory_gb'), [10, 18]),
  },
});

void main() {
  test('a job that asked for far more than it used is told what would do', () {
    final fit = ResourceFit.of(_run(), _usage())!;
    final rows = {for (final row in fit.rows) row.label: row};
    expect(rows['Memory']!.used, '9.00 GB peak of 64 GB');
    expect(rows['Memory']!.advice, '13 GB would do.');
    expect(rows['CPUs']!.used, '1.6 cores busy on average (at most 2.4 cores) of 16 cores');
    expect(rows['GPUs']!.advice, startsWith('GPU 1 was nearly idle: 1 would do'));
    expect(rows['GPU memory']!.advice, contains('less memory'));
    expect(rows['Time']!.used, '2h 0m of 12h 0m');
    expect(fit.flags, ['--mem=13G', '-c 3', '-G 1', '--time=03:00:00']);
  });

  test('a job close to its memory limit is warned, and a crash says nothing of time', () {
    final fit = ResourceFit.of(
      _run(status: RunStatus.crashed, memoryGb: 48, gpus: 1),
      _usage(
        memory: const [20, 47],
        gpu: const [
          [95, 97],
        ],
      ),
    )!;
    final memory = fit.rows.firstWhere((r) => r.label == 'Memory');
    expect(memory.warning, isTrue);
    expect(memory.advice, 'Close to its limit: ask for more (--mem=72G).');
    expect(fit.rows.firstWhere((r) => r.label == 'Time').advice, isNull);
    expect(fit.flags, ['-c 3']);
  });

  test('a job that fit its request gets no advice', () {
    final fit = ResourceFit.of(
      _run(took: const Duration(hours: 10), memoryGb: 16, cores: 4, gpus: 1),
      _usage(
        memory: const [10, 12],
        cpu: const [60, 90],
        gpu: const [
          [90, 95],
        ],
      ),
    )!;
    expect(fit.flags, isEmpty);
    expect(fit.rows.where((r) => r.warning), isEmpty);
  });

  test('a job finishing near its time limit is told to ask for more', () {
    final fit = ResourceFit.of(_run(took: const Duration(hours: 11, minutes: 30)), _usage())!;
    expect(fit.rows.firstWhere((r) => r.label == 'Time').warning, isTrue);
    expect(fit.flags, isNot(contains(startsWith('--time'))));
  });

  test('averages use the server\'s mean over every value, not the downsampled points', () {
    final usage = SystemUsage.from({
      MetricKeys.cpu: const MetricSeries(
        name: MetricKeys.cpu,
        points: [MetricPoint(0, 10), MetricPoint(1, 90)],
        mean: 15,
      ),
    });
    final fit = ResourceFit.of(_run(gpus: 0), usage)!;
    expect(fit.rows.firstWhere((r) => r.label == 'CPUs').used, startsWith('2.4 cores busy'));
    expect(
      MetricSeries(
        name: 'x',
        points: [for (var i = 0; i < 100; i++) MetricPoint(i, i % 10 == 0 ? 90 : 10)],
      ).downsampled(10).mean,
      closeTo(18, 1e-9),
    );
  });

  test('only for an ended Slurm job', () {
    expect(ResourceFit.of(_run(status: RunStatus.live), _usage()), isNull);
    expect(ResourceFit.of(_run(slurm: const {}), _usage()), isNotNull, reason: 'its time limit');
    expect(formatSlurmTime(const Duration(days: 1, hours: 6)), '1-06:00:00');
  });

  test('a single busy core reads as one core', () {
    final fit = ResourceFit.of(
      _run(cores: 1, gpus: 0),
      _usage(cpu: const [99.2, 99.8], gpu: const []),
    )!;
    expect(
      fit.rows.firstWhere((r) => r.label == 'CPUs').used,
      '1 core busy on average (at most 1 core) of 1 core',
    );
  });

  testWidgets('a finished sweep run shows what to ask for next time', (tester) async {
    await openApp(tester, '/runs/fno-ns-m8-w32');
    await tester.scrollUntilVisible(find.byType(ResourcesCard), 200, scrollable: visibleList());
    expect(find.text('Resources'), findsOneWidget);
    expect(find.text('Next time, ask for'), findsOneWidget);
    expect(find.textContaining('--time='), findsOneWidget);
  });
}
