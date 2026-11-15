import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/features/compare/settings_diff.dart';
import 'package:soliton/models/run.dart';

import 'test_app.dart';

Run withSettings(Run base, Map<String, String> settings) =>
    Run.fromJson({...base.toJson(), 'hyperparameters': settings});

void main() {
  // A run whose logger recorded no code version (AWS: no demo one).
  final base = buildMockRuns(DateTime(2026, 11, 14)).firstWhere((m) => m.run.host == 'AWS').run;

  test('only the settings that differ, a missing one counting as different', () {
    final a = withSettings(base, {'Optimizer': 'Adam', 'Width': '32', 'Modes': '8'});
    final b = withSettings(base, {'Optimizer': 'Adam', 'Width': '64', 'Dropout': '0.1'});
    final (:differ, :same) = diffSettings([a, b]);
    expect(differ, ['Width', 'Modes', 'Dropout']);
    expect(same, ['Optimizer']);
    expect(diffSettings([a, a]).differ, isEmpty);
  });

  testWidgets('Compare shows what changed between sweep runs, the rest folded away', (
    tester,
  ) async {
    await openApp(tester, '/compare?runs=fno-ns-m8-w32,fno-ns-m16-w64');
    await tester.scrollUntilVisible(find.text('Settings that differ'), 200, scrollable: visibleList());
    expect(find.text('Fourier modes'), findsOneWidget);
    expect(find.text('8 × 8'), findsOneWidget);
    expect(find.text('16 × 16'), findsOneWidget);
    expect(find.text('Width'), findsOneWidget);
    expect(find.text('Optimizer'), findsNothing, reason: 'the same in both: folded');
    expect(find.text('Code version'), findsOneWidget, reason: 'a newer commit for m16-w64');
    expect(find.text('9f3e2b7'), findsOneWidget);
    await tester.tap(find.textContaining('Show the'));
    await tester.pumpAndSettle();
    expect(find.text('Optimizer'), findsOneWidget);
  });
}
