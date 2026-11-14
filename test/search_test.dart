import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/features/runs_list/runs_list_screen.dart';
import 'package:soliton/shared/search.dart';

import 'test_app.dart';

Future<void> search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(ListSearchField), query);
  await tester.pumpAndSettle();
}

void main() {
  test('every word must be in some field, ignoring case', () {
    expect(matchesSearch('', ['anything']), isTrue);
    expect(matchesSearch('  ', ['anything']), isTrue);
    expect(matchesSearch('FNO', ['fno-navier-stokes']), isTrue);
    expect(matchesSearch('fno sherlock', ['fno-navier-stokes', 'Sherlock']), isTrue);
    expect(matchesSearch('fno aws', ['fno-navier-stokes', 'Sherlock']), isFalse);
    expect(matchesSearch('x', [null, '']), isFalse);
  });

  group('the runs list', () {
    testWidgets('shows only the runs that match, with their counts', (tester) async {
      await openApp(tester);
      final runs = await containerOf(tester).read(runsProvider.future);
      final fno = searchRuns(runs, 'fno');
      expect(fno.length, inInclusiveRange(1, runs.length - 1));

      await search(tester, 'fno');
      expect(find.text('resnet50-cifar'), findsNothing);
      expect(find.text('fno-navier-stokes'), findsOneWidget);
      expect(find.text('All · ${fno.length}'), findsOneWidget, reason: 'counts follow the search');

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('resnet50-cifar'), findsOneWidget);
      expect(find.text('All · ${runs.length}'), findsOneWidget);
    });

    testWidgets('finds runs by tag, host and project too', (tester) async {
      await openApp(tester);
      await search(tester, 'aws');
      expect(find.text('gpt-tiny'), findsOneWidget, reason: 'it runs on AWS');
      expect(find.text('resnet50-cifar'), findsNothing);
      await search(tester, 'image-classification');
      expect(find.text('resnet50-cifar'), findsOneWidget);
    });

    testWidgets('says when nothing matches', (tester) async {
      await openApp(tester);
      await search(tester, 'nothing-is-called-this');
      expect(find.text('No runs match "nothing-is-called-this"'), findsOneWidget);
    });

    testWidgets('the search stays when coming back from a run', (tester) async {
      await openApp(tester);
      await search(tester, 'fno');
      await tester.tap(find.text('fno-navier-stokes'));
      await tester.pumpAndSettle();
      routerOf(tester).go('/');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListSearchField, 'fno'), findsOneWidget);
      expect(find.text('resnet50-cifar'), findsNothing);
    });

    testWidgets('pick all picks only the runs found', (tester) async {
      await openApp(tester);
      await search(tester, 'aws');
      await tester.tap(find.byTooltip('Pick runs to compare or delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pick all shown'));
      await tester.pump();
      expect(find.text('1 picked'), findsOneWidget);
    });
  });

  testWidgets('Compute searches its simulations', (tester) async {
    await openApp(tester, '/compute');
    await search(tester, 'burgers');
    expect(find.text('burgers-shock-fd'), findsOneWidget);
    expect(find.text('kelvin-helmholtz-2048'), findsNothing);
    await search(tester, 'zzz');
    expect(find.text('No simulations match "zzz"'), findsOneWidget);
  });

  testWidgets('Data searches its datasets, and totals what it finds', (tester) async {
    await openApp(tester, '/data');
    await search(tester, 'cifar');
    expect(find.text('cifar10'), findsOneWidget);
    expect(find.text('ns2d-vorticity · v3'), findsNothing);
    expect(find.text('1'), findsOneWidget, reason: 'Datasets: 1');
    await search(tester, 'zzz');
    expect(find.text('No datasets match "zzz"'), findsOneWidget);
  });
}
