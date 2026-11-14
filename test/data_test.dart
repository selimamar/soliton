import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/models/dataset.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/shared/formatters.dart';

import 'test_app.dart';

void main() {
  test('formatBytes', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(980000000), '980 MB');
    expect(formatBytes(1.34e9), '1.34 GB');
    expect(formatBytes(1.2e12), '1.2 TB');
    expect(formatBytes(999.7e6), '1 GB');
  });

  test('a dataset reads the server\'s JSON, previews and NaN included', () {
    final dataset = Dataset.fromJson({
      'id': 'ns2d-v3',
      'name': 'ns2d',
      'version': 'v3',
      'samples': 1200,
      'splits': {'train': 1000, 'test': 200},
      'sampleShape': [64, 64, 50],
      'variables': [
        {'name': 'w', 'min': -4.1, 'max': 'NaN'},
      ],
      'previews': [
        {'name': 'sample 0', 'shape': [2, 2], 'min': -1.0, 'max': 1.0, 'data': 'AAD//wAA//8='},
      ],
      'madeBy': {'id': 'gen', 'name': 'gen', 'status': 'live', 'simulation': true},
      'usedBy': [
        {'id': 'fno', 'name': 'fno', 'status': 'finished'},
        {'id': 'gone', 'name': 'gone'},
      ],
      'updatedAt': '2026-11-14T09:00:00Z',
    });
    expect(dataset.title, 'ns2d · v3');
    expect(dataset.variables.single.max!.isNaN, isTrue);
    final preview = dataset.previews.single;
    expect(preview.shape, [2, 2]);
    expect(preview.prediction[0], -1, reason: 'code 0 is the minimum');
    expect(preview.prediction[1].isNaN, isTrue, reason: 'code 65535 is NaN');
    expect(dataset.madeBy!.simulation, isTrue);
    expect(dataset.usedBy.last.status, isNull, reason: 'a run the server no longer has');
    expect(dataset.usedBy.first.status, RunStatus.finished);
  });

  group('Data', () {
    testWidgets('the sections bar opens the datasets', (tester) async {
      await openApp(tester);
      await tester.tap(find.text('Data'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/data');
      expect(find.text('Datasets'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.text('ns2d-vorticity · v3'), findsOneWidget);
      expect(find.text('Used by 5 runs'), findsOneWidget);
      expect(find.text('1,200 samples · 64 × 64 × 50 · HDF5'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Made by rayleigh-benard-3d'),
        200,
        scrollable: visibleList(),
      );
      expect(find.text('Not used yet'), findsWidgets);
    });

    testWidgets('a dataset: contents, samples, origin, and the runs on it', (tester) async {
      await openApp(tester, '/data');
      await tester.tap(find.text('ns2d-vorticity · v3'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/data/ns2d-vorticity-v3');
      expect(find.text('Data'), findsNothing, reason: 'it covers the sections bar');
      expect(find.text('64×64×50'), findsOneWidget);
      expect(find.text('train 1,000 · test 200'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('4 of 1,200'), 200, scrollable: visibleList());
      expect(find.text('4 of 1,200'), findsOneWidget);
      final usedBy = find.text('Used by · 5');
      await tester.scrollUntilVisible(usedBy, 300, scrollable: visibleList());
      expect(find.text('/scratch/users/demo/data/navier-stokes/ns_v1e-3.h5'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('fno-navier-stokes'), 200, scrollable: visibleList());
      await tester.tap(find.text('fno-navier-stokes'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/runs/fno-navier-stokes');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a run links to its data, and data to the simulation that made it', (
      tester,
    ) async {
      await openApp(tester, '/runs/fno-navier-stokes');
      final chip = find.text('ns2d-vorticity-v3');
      await tester.scrollUntilVisible(chip, 200, scrollable: visibleList());
      expect(find.text('Trained on'), findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/data/ns2d-vorticity-v3');

      routerOf(tester).go('/data/rb3d-snapshots');
      await tester.pumpAndSettle();
      final maker = find.text('rayleigh-benard-3d ›');
      await tester.scrollUntilVisible(maker, 300, scrollable: visibleList());
      expect(find.textContaining('Made on'), findsWidgets, reason: 'the simulation\'s machine');
      await tester.ensureVisible(maker);
      await tester.pumpAndSettle();
      await tester.tap(maker);
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/compute/rayleigh-benard-3d');
    });

    testWidgets('an unknown dataset says so, without retrying', (tester) async {
      await openApp(tester, '/data/nope');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('nope'), findsWidgets);
    });
  });
}
