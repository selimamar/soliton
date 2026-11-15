import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/features/run_detail/widgets/stop_button.dart';
import 'package:soliton/models/run.dart';

import 'test_app.dart';

void main() {
  testWidgets('a live run can be asked to stop, and says so until it ends', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar');
    await tester.tap(find.byTooltip('Stop'));
    await tester.pumpAndSettle();
    expect(find.text('Stop resnet50-cifar?'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(find.text('Asked resnet50-cifar to stop'), findsOneWidget);
    expect(find.textContaining('Asked to stop just now'), findsOneWidget);
    expect(find.byTooltip('Stop'), findsNothing, reason: 'asked once');
  });

  testWidgets('cancelling asks nothing; ended runs have no Stop', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar');
    await tester.tap(find.byTooltip('Stop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Asked to stop'), findsNothing);

    await openApp(tester, '/runs/unet-seg');
    expect(find.byTooltip('Stop'), findsNothing);
  });

  test('the stop request survives JSON, and only shows while live', () {
    final now = DateTime.utc(2026, 11, 14, 12);
    final live = buildMockRuns(now).first.run;
    final asked = Run.fromJson({
      ...live.toJson(),
      'stopRequestedAt': now.subtract(const Duration(minutes: 3)).toIso8601String(),
    });
    expect(Run.fromJson(asked.toJson()), asked);
    expect(stopRequestedText(asked, now), startsWith('Asked to stop 3 min ago.'));
    expect(stopRequestedText(Run.fromJson({...asked.toJson(), 'status': 'finished'}), now), isNull);
    expect(Run.fromJson({...live.toJson()}..remove('stopRequestedAt')).stopRequestedAt, isNull);
  });
}
