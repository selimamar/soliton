import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/data/mock/mock_run_repository.dart';
import 'package:models_app/features/runs_list/run_groups.dart';
import 'package:models_app/models/field_snapshot.dart';
import 'package:models_app/shared/widgets/xy_chart_card.dart';

import 'test_app.dart';

/// A tall screen, so whole cards are built (the lists are lazy).
void useTallScreen(WidgetTester tester, {double height = 3200}) {
  tester.view.physicalSize = Size(900, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 300, scrollable: visibleList());

void main() {
  final repository = MockRunRepository(latency: Duration.zero);

  test('a demo operator run logs a validation set with its worst samples', () async {
    for (final runId in ['fno-navier-stokes', 'fno3d-turbulence']) {
      final [evals] = await repository.fetchEvals(runId);
      final latest = evals.steps.last;
      expect(latest.histogram!.counts.reduce((a, b) => a + b), latest.count, reason: runId);
      expect(latest.stats['median']!, lessThan(latest.stats['p90']!));
      expect(latest.stats['max'], latest.worst.first.relL2, reason: 'the worst sample tops it');
      final fields = await repository.fetchFields(runId);
      final worst = fields.where((f) => f.kind == FieldKind.worst).toList();
      expect(worst.map((f) => f.worstOf).toSet(), {'vorticity'});
      final snapshot = await repository.fetchFieldSnapshot(
        runId,
        latest.worst.first.fieldName('vorticity'),
        latest.step,
      );
      expect(snapshot.sample, latest.worst.first.sample);
    }
  });

  test('demo fields carry their domain, spectrum and rollout physics', () async {
    final step = (await repository.fetchFields('fno-navier-stokes')).first.steps.last.step;
    final vorticity = await repository.fetchFieldSnapshot('fno-navier-stokes', 'vorticity', step);
    expect(vorticity.domain.axes, ['y', 'x']);
    expect(vorticity.spectrum!.k.length, 32);
    final rollout = await repository.fetchFieldSnapshot('fno-navier-stokes', 'rollout', 6000);
    expect(rollout.frameStats[FieldStatKeys.targetMeanSquare], hasLength(rollout.frames));
  });

  test('curves, Fourier weights and sweep metrics', () async {
    final curves = await repository.fetchCurves('fno-navier-stokes');
    expect(curves.map((c) => c.name), ['error vs resolution', 'error vs viscosity']);
    expect(curves.last.steps.last.trainRange, (5e-4, 2e-3));
    final weights = [
      for (final f in await repository.fetchFields('fno3d-turbulence'))
        if (f.kind == FieldKind.weights) f,
    ];
    expect(weights, hasLength(4));
    expect(weights.first.shape, [8, 8, 8]);
    final latest = await repository.fetchLatestMetrics(['val/rel_l2', 'perf/inference_s']);
    expect(latest.keys, containsAll(['fno-ns-m8-w32', 'fno-ns-m16-w64', 'fno-navier-stokes']));
    expect(
      latest['fno-ns-m16-w64']!['val/rel_l2']!.min,
      lessThan(latest['fno-ns-m8-w32']!['val/rel_l2']!.min!),
    );
  });

  group('Fields tab', () {
    testWidgets('shows the spectrum, the validation set and the curves', (tester) async {
      useTallScreen(tester, height: 4800);
      await openApp(tester, '/runs/fno-navier-stokes?tab=fields');
      expect(find.text('Energy spectrum'), findsOneWidget);
      await scrollTo(tester, find.text('Validation set'));
      expect(find.text('200 samples · step 7,000'), findsOneWidget);
      for (final label in ['Median', '90% under', 'Worst']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.textContaining('· sample '), findsNWidgets(4), reason: 'the 4 worst samples');
      await scrollTo(tester, find.text('Error vs viscosity'));
      expect(find.text('Shaded: seen in training'), findsOneWidget);
      expect(find.text('Error vs resolution'), findsOneWidget);
      await scrollTo(tester, find.text('Fourier weights'));
      expect(find.text('blocks.0.spectral.weights1'), findsOneWidget);
    });

    testWidgets('a worst sample opens in full', (tester) async {
      useTallScreen(tester, height: 4800);
      await openApp(tester, '/runs/fno-navier-stokes?tab=fields');
      await scrollTo(tester, find.text('Validation set'));
      await tester.tap(find.textContaining('#1 · sample '));
      await tester.pumpAndSettle();
      expect(find.textContaining('#1 worst'), findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    });

    testWidgets('a rollout shows its physics, mean square and minimum too', (tester) async {
      useTallScreen(tester, height: 4800);
      await openApp(tester, '/runs/fno-navier-stokes?tab=fields');
      await tester.tap(find.text('rollout'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Physics along the rollout'));
      expect(find.text('Mean, prediction'), findsOneWidget);
      await tester.tap(find.text('Mean square'));
      await tester.pumpAndSettle();
      expect(find.text('Mean square, truth'), findsOneWidget);
    });

    testWidgets('maps show where they are in the domain', (tester) async {
      useTallScreen(tester);
      await openApp(tester, '/runs/fno3d-turbulence?tab=fields');
      await tester.tap(find.text('Slices'));
      await tester.pumpAndSettle();
      expect(find.textContaining('across x = 3.24'), findsOneWidget, reason: 'the middle x slice');
      expect(find.text('z 0 → 6.28 across, y 0 → 6.28 down'), findsOneWidget);
    });

    testWidgets('cards can be exported as images', (tester) async {
      useTallScreen(tester);
      await openApp(tester, '/runs/fno-navier-stokes?tab=fields');
      expect(find.byTooltip('Export as an image'), findsWidgets);
    });
  });

  group('Metrics tab', () {
    testWidgets('loss terms and the error per variable get their own charts', (tester) async {
      useTallScreen(tester);
      await openApp(tester, '/runs/fno3d-turbulence?tab=metrics');
      expect(find.text('Loss terms'), findsOneWidget);
      for (final term in ['data', 'pde', 'bc']) {
        expect(find.text(term), findsOneWidget);
      }
      expect(find.text('Relative L2 per variable'), findsOneWidget);
      for (final variable in ['All variables', 'u', 'v', 'w']) {
        expect(find.text(variable), findsOneWidget);
      }
      expect(find.text('loss/pde'), findsNothing, reason: 'not again under Other metrics');
    });
  });

  testWidgets('the Overview shows how much faster than the solver a model is', (tester) async {
    useTallScreen(tester);
    await openApp(tester, '/runs/fno-navier-stokes');
    expect(find.textContaining('× faster'), findsOneWidget);
    expect(find.text('Model, per sample'), findsOneWidget);
  });

  testWidgets('Compare shows the same field from each run', (tester) async {
    useTallScreen(tester, height: 4000);
    await openApp(tester, '/compare?runs=fno-navier-stokes,fno3d-turbulence');
    await scrollTo(tester, find.text('Fields'));
    await tester.pumpAndSettle();
    expect(find.text('Each run at its latest step, on shared colour scales.'), findsOneWidget);
    expect(find.textContaining('Ground truth ('), findsOneWidget);
    expect(find.text('Prediction'), findsNWidgets(2));
  });

  group('Sweep', () {
    testWidgets('a grid over two hyperparameters, the best run marked', (tester) async {
      useTallScreen(tester);
      await openApp(tester, '/sweep');
      expect(find.text('neural-operators'), findsOneWidget, reason: 'the project with most runs');
      expect(find.text('Relative L2 (validation)'), findsWidgets);
      // Two of the axes the sweep varied:
      expect(find.text('Width'), findsWidgets);
      expect(find.text('16 × 16'), findsWidgets);
      await tester.tap(find.text('Scatter'));
      await tester.pumpAndSettle();
      expect(find.byType(XYChartCard), findsOneWidget);
    });

    testWidgets('opens from the runs list', (tester) async {
      await openApp(tester);
      await tester.tap(find.byTooltip('Sweep: runs by hyperparameters'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/sweep');
    });
  });

  test('runs can be grouped by the PDE they solve', () async {
    final runs = await MockRunRepository(latency: Duration.zero).fetchRuns();
    final groups = {for (final g in groupRuns(runs, RunGrouping.pde)) g.label: g.runs.length};
    expect(groups['Navier–Stokes 2D, vorticity form'], 5);
    expect(groups['Navier–Stokes 3D, periodic box'], 1);
    expect(groups['No PDE logged'], 4);
  });
}
