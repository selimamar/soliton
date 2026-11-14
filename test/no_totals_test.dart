import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/models/run.dart';

/// Runs logged without `total_steps` or `total_epochs` (the logger allows
/// both): no "Epoch 330/0", "Step 2,390 of 0" or "0.0%".
void main() {
  final now = DateTime.utc(2026, 11, 14, 18, 30);
  final sample = buildMockRuns(now).firstWhere((r) => r.run.status == RunStatus.live).run;
  Run run({int totalSteps = 0, int totalEpochs = 0, int epoch = 0, int step = 2390}) =>
      Run.fromJson({
        ...sample.toJson(),
        'totalSteps': totalSteps,
        'totalEpochs': totalEpochs,
        'currentEpoch': epoch,
        'currentStep': step,
        'simulation': null,
      });

  test('the epoch reads "42/100", "42" without a total, or nothing without epochs', () {
    expect(run(totalEpochs: 100, epoch: 42).epochText, '42/100');
    expect(run(epoch: 341).epochText, '341');
    expect(run().epochText, isNull);
  });

  test('without total steps there is no end: no progress and no time left', () {
    expect(run(totalSteps: 4028).hasEnd, isTrue);
    final open = run();
    expect(open.hasEnd, isFalse);
    expect(open.estimatedRemainingAt(now), isNull, reason: 'not "0s left"');
    expect(open.estimatedEndAt(now), isNull);
  });
}
