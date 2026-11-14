import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/providers.dart';

import 'test_app.dart';

/// Taps Delete in the confirmation dialog.
Future<void> confirm(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
  await tester.pumpAndSettle();
}

void main() {
  group('a run', () {
    testWidgets('is deleted from its page, after asking', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      await tester.tap(find.byTooltip('Delete run'));
      await tester.pumpAndSettle();
      expect(find.text('Delete run "resnet50-cifar"?'), findsOneWidget);
      expect(
        find.textContaining("It's still running: what it logs next brings it back"),
        findsOneWidget,
        reason: 'a live run comes back with its next upload',
      );

      await confirm(tester);
      expect(locationOf(tester), '/');
      expect(find.text('Deleted resnet50-cifar'), findsOneWidget);
      expect(find.text('resnet50-cifar'), findsNothing);
      final runs = await containerOf(tester).read(allRunsProvider.future);
      expect(runs.map((r) => r.id), isNot(contains('resnet50-cifar')));
    });

    testWidgets('stays when the dialog is cancelled', (tester) async {
      await openApp(tester, '/runs/unet-seg');
      await tester.tap(find.byTooltip('Delete run'));
      await tester.pumpAndSettle();
      expect(find.textContaining('still running'), findsNothing, reason: 'it crashed');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/runs/unet-seg');
      final runs = await containerOf(tester).read(allRunsProvider.future);
      expect(runs.map((r) => r.id), contains('unet-seg'));
    });
  });

  group('the runs list', () {
    testWidgets('a long press starts picking; the picked runs are deleted', (tester) async {
      await openApp(tester);
      await tester.longPress(find.text('resnet50-cifar'));
      await tester.pumpAndSettle();
      expect(find.text('1 picked'), findsOneWidget);
      expect(locationOf(tester), '/', reason: 'a long press does not open the run');
      await tester.tap(find.text('gpt-tiny'));
      await tester.pump();
      expect(find.text('2 picked'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete picked runs'));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 runs?'), findsOneWidget);
      await confirm(tester);
      expect(find.text('Deleted 2 runs'), findsOneWidget);
      expect(find.text('resnet50-cifar'), findsNothing);
      expect(find.text('gpt-tiny'), findsNothing);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Runs')),
        findsOneWidget,
        reason: 'picking ends',
      );
    });

    testWidgets('pick all picks the runs shown, and Compare takes up to six', (tester) async {
      await openApp(tester);
      await tester.tap(find.byTooltip('Pick runs to compare or delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pick all shown'));
      await tester.pump();
      final count = (await containerOf(tester).read(runsProvider.future)).length;
      expect(count, greaterThan(6));
      expect(find.text('$count picked'), findsOneWidget);
      final compare = find.widgetWithText(FilledButton, 'Compare');
      expect(tester.widget<FilledButton>(compare).onPressed, isNull);
      await tester.tap(find.byTooltip('Pick none'));
      await tester.pump();
      expect(find.text('Pick runs'), findsOneWidget);
    });
  });

  group('a simulation', () {
    testWidgets('is deleted from its page, back to Compute', (tester) async {
      await openApp(tester, '/compute/burgers-shock-fd');
      await tester.tap(find.byTooltip('Delete simulation'));
      await tester.pumpAndSettle();
      expect(find.text('Delete simulation "burgers-shock-fd"?'), findsOneWidget);
      await confirm(tester);
      expect(locationOf(tester), '/compute');
      expect(find.text('burgers-shock-fd'), findsNothing);
      expect(find.text('kelvin-helmholtz-2048'), findsOneWidget);
    });

    testWidgets('can be picked in the list and deleted', (tester) async {
      await openApp(tester, '/compute');
      await tester.longPress(find.text('kelvin-helmholtz-2048'));
      await tester.pumpAndSettle();
      expect(find.text('1 picked'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete picked simulations'));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(find.text('Deleted kelvin-helmholtz-2048'), findsOneWidget);
      expect(find.text('kelvin-helmholtz-2048'), findsNothing);
    });
  });

  group('a dataset', () {
    testWidgets('is forgotten from its page, its files untouched', (tester) async {
      await openApp(tester, '/data/piv-channel-flow');
      await tester.tap(find.byTooltip('Delete dataset'));
      await tester.pumpAndSettle();
      expect(find.textContaining("the files aren't touched"), findsOneWidget);
      await confirm(tester);
      expect(locationOf(tester), '/data');
      expect(find.text('7'), findsOneWidget, reason: 'of 8 datasets');
    });

    testWidgets('can be picked in the list and deleted', (tester) async {
      await openApp(tester, '/data');
      await tester.tap(find.byTooltip('Pick datasets to delete'));
      await tester.pumpAndSettle();
      expect(find.text('Pick datasets'), findsOneWidget);
      await tester.ensureVisible(find.text('cifar10'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cifar10'));
      await tester.pump();
      expect(locationOf(tester), '/data', reason: 'picking does not open it');
      await tester.tap(find.byTooltip('Delete picked datasets'));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(find.text('cifar10'), findsNothing);
    });

    testWidgets('no longer lists a deleted run as a user', (tester) async {
      await openApp(tester, '/data');
      // The demo data answers after a (zero) delay: frames move the fake clock.
      final deleting = containerOf(tester).read(deleterProvider).deleteRuns(['vit-small']);
      await tester.pumpAndSettle();
      expect(await deleting, (deleted: 1, error: null));
      final cifar = (await containerOf(tester).read(datasetsProvider.future))
          .firstWhere((d) => d.id == 'cifar10');
      expect(cifar.usedBy.map((u) => u.id), ['resnet50-cifar']);
    });
  });
}
