import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/shared/widgets/line_chart_card.dart';

import 'test_app.dart';

void main() {
  group('compare', () {
    testWidgets('picking two runs shows them side by side', (tester) async {
      await openApp(tester);
      await tester.tap(find.byTooltip('Pick runs to compare or delete'));
      await tester.pumpAndSettle();
      expect(find.text('Pick runs'), findsOneWidget);
      final compare = find.widgetWithText(FilledButton, 'Compare');
      expect(tester.widget<FilledButton>(compare).onPressed, isNull, reason: 'needs two runs');

      await tester.tap(find.text('resnet50-cifar'));
      await tester.pump();
      await tester.tap(find.text('gpt-tiny'));
      await tester.pump();
      expect(find.text('2 picked'), findsOneWidget);
      expect(locationOf(tester), '/', reason: 'picking does not open the run');

      await tester.tap(compare);
      await tester.pumpAndSettle();
      expect(Uri.parse(locationOf(tester)).queryParameters['runs'], 'resnet50-cifar,gpt-tiny');
      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Settings that differ'), findsOneWidget);
      // Below the settings: scroll to the curves.
      await tester.scrollUntilVisible(find.text('Train loss'), 200, scrollable: visibleList());
      expect(find.text('Train loss'), findsOneWidget);
      final chart = tester.widget<LineChartCard>(find.byType(LineChartCard).first);
      expect(chart.lines.map((l) => l.label), ['resnet50-cifar', 'gpt-tiny']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stopping leaves the list as it was', (tester) async {
      await openApp(tester);
      await tester.tap(find.byTooltip('Pick runs to compare or delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop picking'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Runs')), findsOneWidget);
      await tester.tap(find.text('resnet50-cifar'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/runs/resnet50-cifar');
    });

    testWidgets('a link with one run asks for another', (tester) async {
      await openApp(tester, '/compare?runs=resnet50-cifar');
      expect(find.text('Pick at least two runs to compare.'), findsOneWidget);
    });

    testWidgets('an unknown run in the link is reported', (tester) async {
      await openApp(tester, '/compare?runs=resnet50-cifar,nope');
      expect(find.text('Run not found'), findsOneWidget);
    });
  });

  group('chart options', () {
    LineChartCard lossChart(WidgetTester tester) => tester.widget<LineChartCard>(
      find.byWidgetPredicate((w) => w is LineChartCard && w.title == 'Loss'),
    );

    testWidgets('log scale and epochs are applied and remembered', (tester) async {
      final store = MemorySettingsStore();
      await openApp(tester, '/runs/resnet50-cifar', store);
      await tester.tap(find.text('Metrics'));
      await tester.pumpAndSettle();
      expect(lossChart(tester).logScale, isFalse);
      expect(lossChart(tester).xAxis.label, 'Step');

      await tester.tap(find.text('Log scale'));
      await tester.pumpAndSettle();
      expect(lossChart(tester).logScale, isTrue);
      expect(find.bySemanticsLabel(RegExp(r'^Loss chart, log scale\.')), findsOneWidget);

      await tester.tap(find.text('Epochs'));
      await tester.pumpAndSettle();
      expect(lossChart(tester).xAxis.label, 'Epoch');
      expect(lossChart(tester).xAxis.position(196), 1.0, reason: '19,600 steps / 100 epochs');
      expect(tester.takeException(), isNull);

      expect(store.getBool('logScale'), isTrue);
      expect(store.getString('xAxisUnit'), 'epochs');
    });

    testWidgets('saved chart options are used from the start', (tester) async {
      final store = MemorySettingsStore({'logScale': true, 'xAxisUnit': 'epochs'});
      await openApp(tester, '/runs/unet-seg', store);
      await tester.tap(find.text('Metrics'));
      await tester.pumpAndSettle();
      expect(lossChart(tester).logScale, isTrue);
      expect(lossChart(tester).xAxis.label, 'Epoch');
      expect(tester.takeException(), isNull, reason: 'NaN and log scale together');
    });
  });

  group('alerts', () {
    RunAlert crash() => const RunAlert(
      runId: 'unet-seg',
      name: 'unet-seg',
      kind: AlertKind.crashed,
      message: 'Loss became NaN',
    );

    testWidgets('a crash shows an alert that opens the run', (tester) async {
      await openApp(tester);
      containerOf(tester).read(runAlertsProvider.notifier).show(crash());
      await tester.pumpAndSettle(); // Let the snack bar slide in.
      expect(find.text('unet-seg crashed: Loss became NaN'), findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/runs/unet-seg');
    });

    testWidgets('an alert goes away by itself', (tester) async {
      await openApp(tester);
      containerOf(tester).read(runAlertsProvider.notifier).show(crash());
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a run that won\'t finish in time shows an alert', (tester) async {
      const alert = RunAlert(
        runId: 'resnet50-cifar',
        name: 'resnet50-cifar',
        kind: AlertKind.timeLimit,
        message: 'At this pace it needs about 5h more',
      );
      await openApp(tester);
      containerOf(tester).read(runAlertsProvider.notifier).show(alert);
      await tester.pumpAndSettle();
      expect(find.text("resnet50-cifar won't finish before its Slurm time limit"), findsOneWidget);
    });

    testWidgets('the time-limit alert can be turned off', (tester) async {
      await openApp(tester, '/', MemorySettingsStore({'notifyOnTimeLimit': false}));
      containerOf(tester)
          .read(runAlertsProvider.notifier)
          .show(
            const RunAlert(
              runId: 'resnet50-cifar',
              name: 'resnet50-cifar',
              kind: AlertKind.timeLimit,
            ),
          );
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a training problem shows an alert', (tester) async {
      await openApp(tester);
      containerOf(tester)
          .read(runAlertsProvider.notifier)
          .show(
            const RunAlert(
              runId: 'resnet50-cifar',
              name: 'resnet50-cifar',
              kind: AlertKind.health,
              message: 'train/loss is NaN at step 1,200',
            ),
          );
      await tester.pumpAndSettle();
      expect(
        find.text('resnet50-cifar needs a look: train/loss is NaN at step 1,200'),
        findsOneWidget,
      );
    });

    testWidgets('a queued job starting shows an alert, unless turned off', (tester) async {
      const started = RunAlert(
        runId: 'resnet50-cifar',
        name: 'resnet50-cifar',
        kind: AlertKind.jobStarted,
        message: 'Started after 2 h 15 min in the queue.',
      );
      await openApp(tester);
      containerOf(tester).read(runAlertsProvider.notifier).show(started);
      await tester.pumpAndSettle();
      expect(
        find.text('resnet50-cifar started. Started after 2 h 15 min in the queue.'),
        findsNothing,
        reason: 'not said twice',
      );
      expect(find.text('resnet50-cifar started after 2 h 15 min in the queue'), findsOneWidget);
    });

    testWidgets('the health and job-start alerts can be turned off', (tester) async {
      await openApp(
        tester,
        '/',
        MemorySettingsStore({'notifyOnHealth': false, 'notifyOnJobStart': false}),
      );
      final alerts = containerOf(tester).read(runAlertsProvider.notifier);
      alerts.show(const RunAlert(runId: 'a', name: 'a', kind: AlertKind.health));
      await tester.pump();
      alerts.show(const RunAlert(runId: 'b', name: 'b', kind: AlertKind.jobStarted));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('alerts that are turned off stay quiet', (tester) async {
      await openApp(tester, '/', MemorySettingsStore({'notifyOnCrash': false}));
      containerOf(tester).read(runAlertsProvider.notifier).show(crash());
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('settings are saved when changed', (tester) async {
      final store = MemorySettingsStore();
      await openApp(tester, '/settings', store);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      // The switch is below the style picker: scroll to it.
      await tester.scrollUntilVisible(
        find.text('When a run finishes'),
        200,
        scrollable: visibleList(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('When a run finishes'));
      await tester.pumpAndSettle();
      expect(store.getBool('notifyOnFinish'), isFalse);
      expect(store.getString('themeMode'), 'dark');
    });
  });
}
