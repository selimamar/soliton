import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/models/layer_info.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/models/run_cost.dart';
import 'package:soliton/models/system_info.dart';
import 'package:soliton/shared/formatters.dart';

import 'test_app.dart';

void main() {
  test('formatDollars rounds to two significant figures', () {
    expect(formatDollars(38.4), r'$38');
    expect(formatDollars(112), r'$110');
    expect(formatDollars(3.84), r'$3.80');
    expect(formatDollars(4), r'$4');
    expect(formatDollars(9.96), r'$10');
    expect(formatDollars(0.423), r'$0.42');
    expect(formatDollars(1234), r'$1,200');
    expect(formatDollars(152000), r'$150k');
    expect(formatDollars(0.001), r'< $0.01');
    expect(formatCost(38.4), r'≈ $38');
    expect(formatCost(0.001), r'< $0.01');
  });

  test('GPUs are priced by model, as whole words', () {
    expect(gpuPriceOf('NVIDIA A100-SXM4-80GB'), ('A100', 2.5));
    expect(gpuPriceOf('NVIDIA H100 80GB HBM3'), ('H100', 4.0));
    expect(gpuPriceOf('NVIDIA A10G'), ('A10G', 1.0));
    expect(gpuPriceOf('NVIDIA A10'), ('A10', 0.8));
    expect(gpuPriceOf('NVIDIA L40S'), ('L40S', 1.5));
    expect(gpuPriceOf('NVIDIA L4'), ('L4', 0.8));
    expect(gpuPriceOf('Tesla V100-SXM2-32GB'), ('V100', 2.5));
    expect(gpuPriceOf('NVIDIA GeForce RTX 4090'), ('4090', 0.5));
    expect(gpuPriceOf('Some Accelerator'), isNull);
  });

  group('HourlyPrice', () {
    test('adds up the GPUs', () {
      final price = HourlyPrice.of(
        const SystemInfo(
          gpus: [
            GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
            GpuInfo(name: 'NVIDIA A10G', memoryGb: 24),
          ],
        ),
      )!;
      expect(price.dollars, 2);
      expect(price.basis, '2 × A10G at a typical cloud price');
      expect(price.logged, isFalse);
    });

    test('a logged price wins, and zero hides the estimate', () {
      const gpus = [GpuInfo(name: 'NVIDIA H100', memoryGb: 80)];
      final logged = HourlyPrice.of(const SystemInfo(gpus: gpus, pricePerHour: 1.2))!;
      expect((logged.dollars, logged.logged), (1.2, true));
      expect(HourlyPrice.of(const SystemInfo(gpus: gpus, pricePerHour: 0)), isNull);
    });

    test('CPU-only runs are priced per core; unknown machines not at all', () {
      expect(HourlyPrice.of(const SystemInfo(cpuCores: 16))!.dollars, closeTo(0.8, 1e-9));
      expect(HourlyPrice.of(const SystemInfo()), isNull);
      expect(HourlyPrice.of(null), isNull);
      expect(
        HourlyPrice.of(const SystemInfo(gpus: [GpuInfo(name: 'Mystery GPU', memoryGb: 8)])),
        isNull,
        reason: 'better nothing than a made-up price',
      );
    });

    test('pricePerHour survives JSON', () {
      const info = SystemInfo(cpuCores: 4, pricePerHour: 3.5);
      expect(SystemInfo.fromJson(info.toJson()), info);
    });
  });

  test('estimateCost: so far, and the expected total of a live run', () {
    final start = DateTime(2026, 1, 1);
    Run run(RunStatus status) => Run(
      id: 'r',
      name: 'r',
      project: 'p',
      host: 'h',
      status: status,
      startedAt: start,
      endedAt: status == RunStatus.live ? null : start.add(const Duration(hours: 2)),
      currentStep: 250,
      totalSteps: 1000,
      currentEpoch: 0,
      totalEpochs: 4,
      hyperparameters: const {},
      architecture: const LayerInfo(name: 'm', type: 'M'),
      lossPreview: const [],
      system: const SystemInfo(gpus: [GpuInfo(name: 'NVIDIA H100', memoryGb: 80)]),
    );
    final now = start.add(const Duration(hours: 1));
    // An hour at $4/h, a quarter done: $16 in all.
    expect(estimateCost(run(RunStatus.live), now), (soFar: 4.0, total: 16.0));
    // Ended after two hours: no projection.
    expect(estimateCost(run(RunStatus.finished), now), (soFar: 8.0, total: null));
  });

  testWidgets('the Overview shows the estimated cost', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar');
    await tester.scrollUntilVisible(find.text('Cost so far'), 200, scrollable: visibleList());
    // 3h 12m on one A100 at about $2.50/h.
    expect(find.text(r'≈ $8'), findsOneWidget);
    expect(find.text('Expected total'), findsOneWidget);
    expect(find.text(r'≈ $2.50/h'), findsOneWidget);
    expect(
      find.text('Estimated: run time × 1 × A100 at a typical cloud price.'),
      findsOneWidget,
    );
  });
}
