import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/app/theme.dart';
import 'package:models_app/data/mock/mock_run_repository.dart';
import 'package:models_app/data/mock/mock_runs.dart';
import 'package:models_app/data/services/settings_store.dart';
import 'package:models_app/features/runs_list/run_groups.dart';
import 'package:models_app/features/settings/settings_providers.dart';
import 'package:models_app/models/metric_series.dart';
import 'package:models_app/models/run.dart';
import 'package:models_app/models/run_insights.dart';

import 'test_app.dart';

List<Run> _runs() => [for (final m in buildMockRuns(DateTime(2026, 11, 13))) m.run];

List<String> _ids(List<(Run, RunScore)> ranked) => [for (final (run, _) in ranked) run.id];

void main() {
  group('ranking', () {
    final runs = _runs().take(4).toList();
    final ids = [for (final r in runs) r.id];
    Map<String, Map<String, LatestMetric>> logged(
      String metric,
      Map<String, (double latest, double? min)> values,
    ) => {
      for (final MapEntry(:key, :value) in values.entries)
        key: {metric: LatestMetric(latest: value.$1, min: value.$2)},
    };

    test('newest first leaves the order alone', () {
      final ranked = rankRuns(runs, RunOrder.newest, const {});
      expect(_ids(ranked), ids);
      expect(ranked.every((e) => e.$2.rank == null), isTrue);
    });

    test('a loss ranks runs by their lowest value, lowest first', () {
      final ok = runs.where((r) => r.status != RunStatus.crashed).toList();
      final ranked = rankRuns(
        ok,
        RunOrder.valLoss,
        logged(MetricKeys.valLoss, {
          ok[0].id: (0.9, 0.5), // Its best was 0.5, though it ended at 0.9.
          ok[1].id: (0.3, 0.3),
          ok[2].id: (0.7, null),
        }),
      );
      expect(_ids(ranked), [ok[1].id, ok[0].id, ok[2].id]);
      expect([for (final (_, s) in ranked) s.rank], [1, 2, 3]);
      expect(ranked.first.$2.best, isTrue);
      expect(ranked[1].$2.value, 0.5);
    });

    test('accuracy ranks by the latest value, highest first', () {
      final ranked = rankRuns(
        runs.take(2).toList(),
        RunOrder.valAccuracy,
        logged(MetricKeys.valAccuracy, {ids[0]: (0.81, 0.1), ids[1]: (0.93, 0.1)}),
      );
      expect(_ids(ranked), [ids[1], ids[0]]);
    });

    test('crashed runs and runs without the metric come last, unranked', () {
      final crashed = runs.firstWhere((r) => r.status == RunStatus.crashed);
      final others = runs.where((r) => r != crashed).toList();
      final ranked = rankRuns(
        runs,
        RunOrder.valLoss,
        logged(MetricKeys.valLoss, {
          crashed.id: (0.01, 0.01), // Best of all, but it crashed.
          others[0].id: (double.nan, null),
          others[1].id: (0.2, 0.2),
          others[2].id: (0.4, 0.4),
        }),
      );
      expect(_ids(ranked).take(2), [others[1].id, others[2].id]);
      expect(
        {for (final (run, s) in ranked.skip(2)) run.id: s.rank},
        {others[0].id: null, crashed.id: null},
      );
      expect(ranked.firstWhere((e) => e.$1 == crashed).$2.value, 0.01, reason: 'still shown');
    });

    test('ties keep the order given', () {
      final ranked = rankRuns(
        runs.take(3).toList(),
        RunOrder.trainLoss,
        logged(MetricKeys.trainLoss, {for (final id in ids.take(3)) id: (0.5, 0.5)}),
      );
      expect(_ids(ranked), ids.take(3).toList());
    });
  });

  for (final style in AppStyle.values) {
    testWidgets('grouped and ordered by validation loss, each group is a leaderboard '
        '(${style.label})', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final store = MemorySettingsStore();
      await openApp(tester, '/', store);
      containerOf(tester).read(appStyleProvider.notifier).set(style);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Group and order runs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('By project'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Group and order runs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Validation loss, lowest first'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(store.getString('runsGroupBy'), 'project');
      expect(store.getString('runsOrderBy'), 'valLoss');

      // The same ranking the list should show, worked out from the data.
      final repository = MockRunRepository(latency: Duration.zero);
      // Real time: the repository's calls wait on timers.
      final (runs, logged) = (await tester.runAsync(
        () async => (
          await repository.fetchRuns(),
          await repository.fetchLatestMetrics([MetricKeys.valLoss]),
        ),
      ))!;
      final project = [
        for (final r in runs)
          if (r.project == 'neural-operators') r,
      ];
      final expected = [
        for (final (run, score) in rankRuns(project, RunOrder.valLoss, logged))
          if (score.rank != null) run.id,
      ];
      expect(expected.length, greaterThan(2));

      // The group's best run, then its runner-up just below it.
      // Ink writes the rank and the name as one text ("1. fno-…").
      final best = find.textContaining(expected[0]), second = find.textContaining(expected[1]);
      await tester.scrollUntilVisible(best, 200, scrollable: visibleList());
      await tester.pumpAndSettle();
      await tester.drag(visibleList(), Offset(0, -tester.getTopLeft(best).dy + 120));
      await tester.pumpAndSettle();
      expect(second, findsOneWidget);
      expect(tester.getTopLeft(best).dy, lessThan(tester.getTopLeft(second).dy));
      expect(tester.takeException(), isNull);
    });
  }
}
