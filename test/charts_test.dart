import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/app/theme.dart';
import 'package:models_app/features/run_detail/widgets/layer_grad_norm_chart.dart';
import 'package:models_app/models/layer_stats.dart';
import 'package:models_app/models/metric_series.dart';
import 'package:models_app/shared/widgets/histogram_view.dart';
import 'package:models_app/shared/widgets/line_chart_card.dart';
import 'package:models_app/shared/widgets/sparkline.dart';

Future<void> pumpInApp(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: ListView(children: [child])),
    ),
  );
  await tester.pumpAndSettle();
}

MetricSeries series(List<double> values) => MetricSeries(
  name: 'loss',
  points: [for (final (i, v) in values.indexed) MetricPoint(i * 1000, v)],
);

void main() {
  testWidgets('a line chart with NaN and infinity renders the finite part', (tester) async {
    await pumpInApp(
      tester,
      LineChartCard(
        title: 'Loss',
        lines: [
          ChartLine(
            label: 'Train',
            color: ChartColors.train,
            series: series([2.3, 1.2, 0.8, double.infinity, 0.7, double.nan]),
          ),
          ChartLine(
            label: 'Validation',
            color: ChartColors.validation,
            series: series([2.4, double.negativeInfinity, 0.9]),
          ),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('NaN'), findsOneWidget, reason: 'the header shows the latest value as is');
    expect(
      find.bySemanticsLabel(RegExp(r'^Loss chart\. Train: latest NaN, range 0\.700')),
      findsOneWidget,
    );
  });

  testWidgets('a line chart with only non-finite values says so', (tester) async {
    await pumpInApp(
      tester,
      LineChartCard(
        title: 'Loss',
        lines: [
          ChartLine(
            label: 'Train',
            color: ChartColors.train,
            series: series([double.nan, double.nan]),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('No finite values to plot'), findsOneWidget);
  });

  testWidgets('a line chart with no points says there is no data yet', (tester) async {
    await pumpInApp(
      tester,
      LineChartCard(
        title: 'Loss',
        lines: [ChartLine(label: 'Train', color: ChartColors.train, series: series([]))],
      ),
    );
    expect(find.text('No data yet'), findsOneWidget);
  });

  testWidgets('y-axis ticks are round numbers with consistent precision', (tester) async {
    await pumpInApp(
      tester,
      LineChartCard(
        title: 'Loss',
        lines: [
          ChartLine(label: 'Train', color: ChartColors.train, series: series([14.7, 4, 1, 0.25])),
        ],
      ),
    );
    // Axis 0–15 in steps of 5; the extreme ticks (0, 15) are hidden.
    expect(find.text('5'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('5.000'), findsNothing);
  });

  testWidgets('sparklines tolerate NaN, infinity and all-NaN values', (tester) async {
    await pumpInApp(
      tester,
      const Column(
        children: [
          Sparkline(values: [1, double.nan, 0.5, double.infinity, 0.2], color: ChartColors.train),
          Sparkline(values: [double.nan, double.nan], color: ChartColors.train),
          Sparkline(values: [], color: ChartColors.train),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('trendOf', () {
    expect(trendOf([3, 2, 1]), 'falling');
    expect(trendOf([1, 2, 3]), 'rising');
    expect(trendOf([1, 1.001]), 'flat');
    expect(trendOf([double.nan, 1, 0.5, double.nan]), 'falling');
    expect(trendOf([]), 'flat');
  });

  testWidgets('a layer with a NaN gradient norm is flagged, not hidden', (tester) async {
    await pumpInApp(
      tester,
      const LayerGradNormChart(
        layers: [
          LayerGradNorm(layerName: 'conv1', gradNorm: 0.4),
          LayerGradNorm(layerName: 'fc', gradNorm: double.nan),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel(RegExp('1 layer has no finite value')), findsOneWidget);
  });

  testWidgets('a histogram with nothing to draw says why', (tester) async {
    await pumpInApp(
      tester,
      const Column(
        children: [
          HistogramView(
            histogram: Histogram(min: double.nan, max: double.nan, counts: [0, 0, 0]),
            color: ChartColors.activation,
          ),
          HistogramView(
            histogram: Histogram(min: 0, max: 0, counts: [0, 0], zeroCount: 64),
            color: ChartColors.activation,
          ),
        ],
      ),
    );
    expect(find.text('No finite values'), findsOneWidget);
    expect(find.text('All values are zero'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a log-scale chart skips values it cannot draw', (tester) async {
    await pumpInApp(
      tester,
      LineChartCard(
        title: 'Loss',
        logScale: true,
        lines: [
          ChartLine(
            label: 'Train',
            color: ChartColors.train,
            series: series([2.3, 0, -1, 0.5, double.nan, 0.25]),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel(RegExp(r'^Loss chart, log scale\.')), findsOneWidget);
    expect(find.text('0.5'), findsWidgets, reason: 'a round log tick');
  });

  testWidgets('a log-scale chart of only zeros says so', (tester) async {
    await pumpInApp(
      tester,
      LineChartCard(
        title: 'Loss',
        logScale: true,
        lines: [
          ChartLine(label: 'Train', color: ChartColors.train, series: series([0, 0])),
        ],
      ),
    );
    expect(find.text('No positive values to plot on a log scale'), findsOneWidget);
  });
}
