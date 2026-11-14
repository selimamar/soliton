import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/shared/widgets/line_chart_card.dart';

import 'test_app.dart';

void main() {
  group('compare', () {
    testWidgets('picking two runs shows them side by side', (tester) async {
      await openApp(tester);
      await tester.tap(find.byTooltip('Compare runs'));
      await tester.pumpAndSettle();
      expect(find.text('Pick runs to compare'), findsOneWidget);
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
      expect(find.text('Train loss'), findsOneWidget);
      final chart = tester.widget<LineChartCard>(find.byType(LineChartCard).first);
      expect(chart.lines.map((l) => l.label), ['resnet50-cifar', 'gpt-tiny']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stopping leaves the list as it was', (tester) async {
      await openApp(tester);
      await tester.tap(find.byTooltip('Compare runs'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop comparing'));
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
      status: RunStatus.crashed,
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
      await tester.ensureVisible(find.text('When a run finishes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('When a run finishes'));
      await tester.pumpAndSettle();
      expect(store.getBool('notifyOnFinish'), isFalse);
      expect(store.getString('themeMode'), 'dark');
    });
  });
}
