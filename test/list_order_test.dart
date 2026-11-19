import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/mock/mock_datasets.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/data/mock/mock_simulations.dart';
import 'package:soliton/features/compute/simulation_order.dart';
import 'package:soliton/features/data/dataset_order.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/models/dataset.dart';
import 'package:soliton/shared/widgets/group_order.dart';

import 'test_app.dart';

void main() {
  final now = DateTime.utc(2026, 11, 14, 12);

  group('groupItems', () {
    test('groups ignoring case, sorted by name, the rest last', () {
      final groups = groupItems<String>(
        ['a', 'b', 'c', 'd'],
        (item) => switch (item) {
          'a' => ['sherlock'],
          'b' => ['AWS', 'aws'], // The same group once.
          'c' => ['Sherlock', 'GCP'],
          _ => [null, '  '],
        },
        'Unknown host',
      );
      expect(
        [for (final g in groups) '${g.label}: ${g.items.join(',')}${g.isRest ? ' (rest)' : ''}'],
        ['AWS: b', 'GCP: c', 'sherlock: a,c', 'Unknown host: d (rest)'],
      );
    });

    test('stableSorted keeps the given order for ties', () {
      expect(stableSorted(['b2', 'a1', 'b1', 'a2'], (x, y) => x[0].compareTo(y[0])), [
        'a1',
        'a2',
        'b2',
        'b1',
      ]);
    });
  });

  group('Data', () {
    final runs = [
      for (final m in [...buildMockRuns(now), ...buildMockSimulations(now)]) m.run,
    ];
    final datasets = buildMockDatasets(now, runs);

    test('ordered newest, by name, largest or most used first', () {
      List<String> names(DatasetOrder order) => [
        for (final d in orderDatasets(datasets, order)) d.name,
      ];
      final newest = orderDatasets(datasets, DatasetOrder.newest);
      for (var i = 1; i < newest.length; i++) {
        final (a, b) = (newest[i - 1], newest[i]);
        expect(
          (a.updatedAt ?? a.createdAt)!.isBefore((b.updatedAt ?? b.createdAt)!),
          isFalse,
          reason: '${a.name} before ${b.name}',
        );
      }
      expect(names(DatasetOrder.name), [...names(DatasetOrder.name)]..sort());
      final sizes = [for (final d in orderDatasets(datasets, DatasetOrder.size)) d.sizeBytes ?? -1];
      expect(sizes, [...sizes]..sort((a, b) => b.compareTo(a)));
      final uses = [
        for (final d in orderDatasets(datasets, DatasetOrder.mostUsed)) d.usedBy.length,
      ];
      expect(uses, [...uses]..sort((a, b) => b.compareTo(a)));
    });

    test('a dataset without a size or date comes last', () {
      const bare = Dataset(id: 'bare', name: 'bare');
      expect(orderDatasets([bare, ...datasets], DatasetOrder.size).last.id, 'bare');
      expect(orderDatasets([bare, ...datasets], DatasetOrder.newest).last.id, 'bare');
    });

    test('grouped by host, format or the projects that used it', () {
      Map<String, List<String>> summary(DatasetGrouping by) => {
        for (final g in groupDatasets(datasets, by)) g.label: [for (final d in g.items) d.name],
      };
      expect(summary(DatasetGrouping.host)['Sherlock'], contains('ns2d-vorticity'));
      expect(summary(DatasetGrouping.format)['HDF5'], contains('turbulence-3d-box'));
      final byProject = groupDatasets(datasets, DatasetGrouping.project);
      final used = datasets.where((d) => d.usedBy.isNotEmpty || d.madeBy != null);
      for (final d in used) {
        final projects = {d.madeBy?.project, ...d.usedBy.map((u) => u.project)}
          ..removeWhere((p) => p == null || p.isEmpty);
        for (final project in projects) {
          expect(
            byProject.firstWhere((g) => g.label.toLowerCase() == project!.toLowerCase()).items,
            contains(d),
          );
        }
      }
      expect(groupDatasets(datasets, DatasetGrouping.none).single.items, datasets);
    });

    testWidgets('the menu groups the list by host, and a group folds away', (tester) async {
      await openApp(tester, '/data');
      await tester.tap(find.byTooltip('Group and order datasets'));
      await tester.pumpAndSettle();
      expect(find.text('Most used first'), findsOneWidget);
      await tester.tap(find.text('By host'));
      await tester.pumpAndSettle();
      expect(find.text('Sherlock'), findsWidgets);
      final header = find.widgetWithText(GroupHeader, 'Sherlock');
      expect(header, findsOneWidget);
      final shown = find.text('ns2d-vorticity · v3');
      expect(shown, findsOneWidget);
      await tester.ensureVisible(header);
      await tester.pumpAndSettle();
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(shown, findsNothing, reason: 'folded away');
    });

    testWidgets('the order is kept after a restart', (tester) async {
      final store = MemorySettingsStore();
      await openApp(tester, '/data', store);
      await tester.tap(find.byTooltip('Group and order datasets'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Largest first'));
      await tester.pumpAndSettle();
      expect(store.getString('datasetsOrderBy'), 'size');
    });
  });

  group('Compute', () {
    final simulations = [for (final m in buildMockSimulations(now)) m.run];

    test('ordered newest, by name, longest running or furthest along', () {
      final newest = orderSimulations(simulations, SimulationOrder.newest, now);
      for (var i = 1; i < newest.length; i++) {
        expect(newest[i - 1].startedAt.isBefore(newest[i].startedAt), isFalse);
      }
      final names = [
        for (final s in orderSimulations(simulations, SimulationOrder.name, now)) s.name,
      ];
      expect(names, [...names]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));
      final times = [
        for (final s in orderSimulations(simulations, SimulationOrder.longest, now))
          s.elapsedAt(now),
      ];
      expect(times, [...times]..sort((a, b) => b.compareTo(a)));
      final progress = [
        for (final s in orderSimulations(simulations, SimulationOrder.progress, now)) s.progress,
      ];
      expect(progress, [...progress]..sort((a, b) => b.compareTo(a)));
    });

    testWidgets('the menu groups simulations by project', (tester) async {
      await openApp(tester, '/compute');
      await tester.tap(find.byTooltip('Group and order simulations'));
      await tester.pumpAndSettle();
      expect(find.text('By model'), findsNothing, reason: 'simulations have no model');
      await tester.tap(find.text('By project'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(GroupHeader, 'turbulence'), findsOneWidget);
      expect(find.textContaining('simulation'), findsWidgets);
    });
  });
}
