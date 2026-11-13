import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/data/mock/mock_run_repository.dart';
import 'package:models_app/data/mock/mock_runs.dart';
import 'package:models_app/features/run_detail/system_usage.dart';
import 'package:models_app/models/metric_series.dart';
import 'package:models_app/models/run.dart';
import 'package:models_app/models/system_info.dart';

import 'test_app.dart';

MetricSeries series(String name, List<double> values) =>
    MetricSeries(name: name, points: [for (final (i, v) in values.indexed) MetricPoint(i * 10, v)]);

/// Demo data as an older logger would have sent it: no system information.
class NoSystemRepository extends MockRunRepository {
  NoSystemRepository() : super(latency: Duration.zero);

  static Run _strip(Run run) => Run.fromJson({...run.toJson(), 'system': null});

  @override
  Future<List<Run>> fetchRuns() async => [for (final run in await super.fetchRuns()) _strip(run)];

  @override
  Future<Run> fetchRun(String runId) async => _strip(await super.fetchRun(runId));

  @override
  Future<Map<String, MetricSeries>> fetchMetrics(String runId) async => {
    for (final MapEntry(:key, :value) in (await super.fetchMetrics(runId)).entries)
      if (!MetricKeys.isSystem(key)) key: value,
  };
}

Future<void> openSystemTab(WidgetTester tester, String runId) async {
  routerOf(tester).go('/runs/$runId');
  await tester.pumpAndSettle();
  await tester.tap(find.text('System'));
  await tester.pumpAndSettle();
}

void main() {
  group('usage', () {
    test('system series are sorted out by GPU', () {
      final usage = SystemUsage.from({
        'train/loss': series('train/loss', [1]),
        'system/gpu.1.utilization': series('', [50, 90]),
        'system/gpu.0.utilization': series('', [40, 70]),
        'system/gpu.0.memory_gb': series('', [10, 30]),
        'system/gpu.1.memory_gb': series('', [12, 32]),
        'system/cpu': series('', [20]),
        'system/memory_gb': series('', [4, 6]),
      });
      expect(usage.gpus.keys, [0, 1]);
      expect(usage.gpuSeries('utilization').keys, [0, 1]);
      expect(usage.latestGpuMean('utilization'), 80);
      expect(usage.latestGpuSum('memory_gb'), 62);
      expect(usage.latestGpuMean('power'), isNull);
      expect(usage.cpu?.latest, 20);
      expect(usage.memoryGb?.latest, 6);
      expect(
        SystemUsage.from({
          'train/loss': series('', [1]),
        }).isEmpty,
        isTrue,
      );
    });

    test('the machine is described most useful first', () {
      final info = buildMockRuns(DateTime(2026, 11, 12)).first.run.system!;
      expect(describeSystem(info), [
        ('GPU', '1 × NVIDIA A100-SXM4-80GB (80 GB)'),
        ('GPU driver', '550.54.15'),
        ('CPU', 'AMD EPYC 7543 32-Core Processor · 16 cores'),
        ('Memory', '64 GB'),
        ('Software', 'Python 3.12.4 · PyTorch 2.5.1 · CUDA 12.4 · cuDNN 9.1.0'),
        ('OS', 'Rocky Linux 8.10 (Linux 4.18.0)'),
        ('Machine', 'sh03-12n07.int'),
        ('Slurm job', '52091377 · resnet50-cifar'),
        ('Partition', 'gpu'),
        ('Cluster', 'sherlock'),
      ]);
      expect(describeSystem(const SystemInfo(python: '3.9.18')), [('Software', 'Python 3.9.18')]);
    });

    test('cores read naturally, including a container\'s fraction of one', () {
      expect(describeCores(16), '16 cores');
      expect(describeCores(1), '1 core');
      expect(describeCores(0.5), '0.5 cores');
      final info = SystemInfo.fromJson({'cpu': 'AMD EPYC 7R13', 'cpuCores': 1.5});
      expect(describeSystem(info).first, ('CPU', 'AMD EPYC 7R13 · 1.5 cores'));
    });

    test('GPUs are counted by kind', () {
      expect(
        describeGpus(const [
          GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
          GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
          GpuInfo(name: 'NVIDIA L4', memoryGb: 23.6),
        ]),
        '2 × NVIDIA A10G (24 GB), 1 × NVIDIA L4 (23.6 GB)',
      );
    });
  });

  group('JSON', () {
    test("the logger's description is read, with what it left out missing", () {
      final info = SystemInfo.fromJson({
        'hostname': 'n1',
        'cpuCores': 8,
        'gpus': [
          {'name': 'NVIDIA H100 80GB HBM3', 'memoryGb': 79.6},
        ],
        'slurm': {'jobId': '123', 'partition': 'gpu'},
        'fromANewerLogger': true,
      });
      expect(info.gpus.single.memoryGb, 79.6);
      expect(info.python, isNull);
      expect(SystemInfo.fromJson(info.toJson()), info);
      expect(info.gpuMemoryGb, 79.6);
    });

    test('runs keep it through a round trip; older servers send none', () {
      for (final mock in buildMockRuns(DateTime(2026, 11, 12))) {
        expect(Run.fromJson(mock.run.toJson()), mock.run);
      }
      final run = buildMockRuns(DateTime(2026, 11, 12)).first.run;
      expect(Run.fromJson({...run.toJson()}..remove('system')).system, isNull);
    });
  });

  group('System tab', () {
    testWidgets('shows what the run trained on and how busy it kept it', (tester) async {
      await openApp(tester);
      await openSystemTab(tester, 'resnet50-cifar');

      expect(find.text('Trained on'), findsOneWidget);
      expect(find.text('1 × NVIDIA A100-SXM4-80GB (80 GB)'), findsOneWidget);
      expect(find.text('52091377 · resnet50-cifar'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('GPU use'), 200, scrollable: visibleList());
      expect(find.text('GPU use'), findsOneWidget, reason: 'latest-value tile');
      expect(find.textContaining('/ 80 GB'), findsOneWidget, reason: 'GPU memory of the total');
      expect(find.text('Log scale'), findsNothing, reason: 'no use for it here');

      await tester.scrollUntilVisible(find.text('GPU use (%)'), 200, scrollable: visibleList());
      expect(find.text('GPU use (%)'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('CPU (% of 16 cores)'),
        200,
        scrollable: visibleList(),
      );
      expect(find.text('CPU (% of 16 cores)'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('GPU power (W)'), 300, scrollable: visibleList());
      expect(tester.takeException(), isNull);
    });

    testWidgets('several GPUs get a line each', (tester) async {
      await openApp(tester);
      await openSystemTab(tester, 'gpt-tiny');
      expect(find.text('4 × NVIDIA A10G (24 GB)'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('GPU use (mean of 4)'),
        200,
        scrollable: visibleList(),
      );
      expect(find.text('GPU use (mean of 4)'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('GPU use (%)'), 200, scrollable: visibleList());
      expect(find.text('GPU 3'), findsWidgets, reason: 'in the legend');
    });

    testWidgets('fits a phone', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await openApp(tester);
      for (final id in ['resnet50-cifar', 'gpt-tiny']) {
        await openSystemTab(tester, id);
        await tester.scrollUntilVisible(find.text('GPU power (W)'), 300, scrollable: visibleList());
        expect(tester.takeException(), isNull, reason: id);
      }
    });

    testWidgets('says so when an older logger sent nothing', (tester) async {
      await tester.pumpWidget(buildApp(repository: NoSystemRepository()));
      await tester.pumpAndSettle();
      await openSystemTab(tester, 'resnet50-cifar');
      expect(find.textContaining('No system information for this run'), findsOneWidget);
    });
  });
}
