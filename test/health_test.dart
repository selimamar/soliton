import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/features/run_detail/widgets/health_card.dart';
import 'package:soliton/models/health_warning.dart';
import 'package:soliton/models/run.dart';

import 'test_app.dart';

void main() {
  group('training health', () {
    testWidgets('a run\'s problems lead its Overview, with what helps', (tester) async {
      await openApp(tester, '/runs/unet-seg');
      expect(find.byType(HealthCard), findsOneWidget);
      expect(find.text('Loss is NaN'), findsOneWidget);
      expect(find.text('train/loss is NaN at step 3,412'), findsOneWidget);
      expect(find.text('Gradients blew up'), findsOneWidget);
      expect(find.textContaining('clip_grad_norm_'), findsOneWidget);
    });

    testWidgets('a healthy run has no health card', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      expect(find.byType(HealthCard), findsNothing);
    });

    test('read from the server, skipping kinds this app doesn\'t know', () {
      final sample = buildMockRuns(DateTime.utc(2026, 11, 14)).first.run;
      final run = Run.fromJson({
        ...sample.toJson(),
        'health': [
          {
            'kind': 'divergence',
            'step': 900,
            'message': 'train/loss climbed back up',
            'at': '2026-11-14T08:00:00Z',
          },
          {'kind': 'boredom', 'step': 950, 'message': 'from a newer logger'},
        ],
      });
      expect(run.health, [
        HealthWarning(
          kind: HealthKind.divergence,
          step: 900,
          message: 'train/loss climbed back up',
          at: DateTime.utc(2026, 11, 14, 8),
        ),
      ]);
      expect(Run.fromJson(run.toJson()), run, reason: 'JSON round trip');
      expect(
        Run.fromJson({...sample.toJson()}..remove('health')).health,
        isEmpty,
        reason: 'older server',
      );
    });
  });
}
