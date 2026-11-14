import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/features/compute/simulation_text.dart';
import 'package:soliton/models/layer_info.dart';
import 'package:soliton/models/metric_series.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/models/simulation_info.dart';

import 'test_app.dart';

void main() {
  final start = DateTime(2026, 1, 1);
  Run simulation({
    RunStatus status = RunStatus.live,
    SimulationInfo info = const SimulationInfo(tEnd: 10, time: 2.5),
    int step = 500,
    int totalSteps = 0,
  }) => Run(
    id: 's',
    name: 's',
    project: 'p',
    host: 'h',
    status: status,
    startedAt: start,
    currentStep: step,
    totalSteps: totalSteps,
    currentEpoch: 0,
    totalEpochs: 0,
    hyperparameters: const {'Equation': 'Burgers'},
    architecture: const LayerInfo(name: 's', type: 'Model'),
    lossPreview: const [],
    simulation: info,
  );

  group('simulations', () {
    test('progress and time left go by simulated time', () {
      final now = start.add(const Duration(hours: 1));
      final run = simulation();
      expect(run.isSimulation, isTrue);
      expect(run.progress, 0.25);
      // A quarter of the way in an hour: three more.
      expect(run.estimatedRemainingAt(now), const Duration(hours: 3));
      expect(describeSimulation(run, now), 't = 2.5 of 10 · ~3h 0m left');
    });

    test('a steady solve goes by iterations', () {
      final now = start.add(const Duration(minutes: 4));
      final open = simulation(info: const SimulationInfo(), step: 12);
      expect(open.estimatedRemainingAt(now), isNull, reason: 'no maximum: unknown');
      expect(describeSimulation(open, now), 'Iteration 12');
      final capped = simulation(info: const SimulationInfo(), step: 25, totalSteps: 100);
      expect(capped.progress, 0.25);
      expect(describeSimulation(capped, now), 'Iteration 25 of 100 · ~12m 0s left');
    });

    test('a diverged simulation says so', () {
      final run = Run.fromJson({
        ...simulation(status: RunStatus.crashed).toJson(),
        'statusMessage': 'Diverged at t = 0.83: energy is NaN',
        'simulation': {'tEnd': 1, 'time': 'NaN', 'diverged': true},
      });
      expect(simulationStatusLabel(run), 'Diverged');
      expect(run.simulation!.time!.isNaN, isTrue);
      expect(describeSimulation(run, start), 'Diverged at t = 0.83: energy is NaN');
      expect(Run.fromJson(run.toJson()), run, reason: 'JSON round trip');
    });

    test('simulated time at any step, between the logged ones', () {
      final times = SimulatedTimes.from({
        SimulationInfo.timeKey: const MetricSeries(
          name: SimulationInfo.timeKey,
          points: [MetricPoint(0, 0), MetricPoint(100, 1), MetricPoint(300, 2)],
        ),
      })!;
      expect(times.at(50), 0.5);
      expect(times.at(200), 1.5);
      expect(times.at(1000), 2, reason: 'held at the end');
      expect(SimulatedTimes.from(const {}), isNull, reason: 'a steady solve');
    });

    test('values are named for people', () {
      expect(describeValue('kinetic_energy'), 'Kinetic energy');
      expect(describeValue('cfl'), 'CFL number');
      expect(describeValue(SimulationInfo.timeStepKey), 'Time step');
    });
  });

  group('Compute', () {
    testWidgets('the sections bar opens the simulations, kept apart from runs', (tester) async {
      await openApp(tester);
      expect(find.text('kelvin-helmholtz-2048'), findsNothing, reason: 'not a training run');
      await tester.tap(find.text('Compute'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/compute');
      expect(find.text('All · 5'), findsOneWidget);
      expect(find.text('kelvin-helmholtz-2048'), findsOneWidget);
      expect(find.textContaining('t = 6.4 of 10'), findsOneWidget);
      expect(find.text('DIVERGED'), findsOneWidget);
      expect(find.text('Diverged at t = 0.83: energy is NaN'), findsOneWidget);

      await tester.tap(find.text('Crashed · 1'));
      await tester.pumpAndSettle();
      expect(find.text('kelvin-helmholtz-2048'), findsNothing);
      expect(find.text('burgers-shock-fd'), findsOneWidget);

      await tester.tap(find.text('Runs').last);
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/');
    });

    testWidgets('a simulation: where it is, its values against time, its fields', (tester) async {
      await openApp(tester, '/compute');
      await tester.tap(find.text('kelvin-helmholtz-2048'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/compute/kelvin-helmholtz-2048');
      expect(find.text('Compute'), findsNothing, reason: 'it covers the sections bar');
      expect(find.text('Simulated time'), findsOneWidget);
      expect(find.text('t = 6.4'), findsOneWidget);
      expect(find.text('Time step'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Setup'), 200, scrollable: visibleList());
      expect(find.text('Fourier spectral · RK443'), findsOneWidget);

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('Enstrophy'), findsWidgets, reason: 'the monitored value first');
      expect(find.text('Simulated time t'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('CFL number').first,
        200,
        scrollable: visibleList(),
      );
      expect(find.text('Limit'), findsOneWidget, reason: 'the CFL limit is drawn');

      await tester.tap(find.text('Fields'));
      await tester.pumpAndSettle();
      expect(find.text('t = 6.4'), findsWidgets, reason: 'snapshots at their simulated time');
      expect(find.text('Field'), findsWidgets);
      expect(find.text('Prediction'), findsNothing);

      await tester.tap(find.text('System'));
      await tester.pumpAndSettle();
      expect(find.text('Runs on'), findsOneWidget);
      expect(find.text('Trained on'), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('while the simulation runs'),
        300,
        scrollable: visibleList(),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a diverged simulation marks where on its charts', (tester) async {
      await openApp(tester, '/compute/burgers-shock-fd?tab=diagnostics');
      expect(find.text('DIVERGED'), findsOneWidget);
      expect(find.text('Diverged'), findsWidgets, reason: 'the line on the charts');
      expect(find.textContaining('then NaN'), findsOneWidget);
    });

    testWidgets('a steady solve: iterations, residual, a parameter study, its field', (
      tester,
    ) async {
      await openApp(tester, '/compute/darcy-heterogeneous');
      expect(find.text('Iterations'), findsOneWidget);
      expect(find.text('of at most 100'), findsOneWidget);
      expect(find.text('Iteration'), findsOneWidget, reason: 'its steps are iterations');
      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('Residual'), findsWidgets);
      expect(find.text('Iteration'), findsWidgets);
      final curve = find.text('Outflow vs permeability contrast');
      await tester.scrollUntilVisible(curve, 300, scrollable: visibleList());
      expect(curve, findsOneWidget, reason: 'sim.log_curve, on Diagnostics');
      expect(find.text('Iteration 37'), findsOneWidget);

      await tester.tap(find.text('Fields'));
      await tester.pumpAndSettle();
      expect(find.text('Iteration 37'), findsWidgets, reason: 'snapshots by iteration');
      expect(find.text('Outflow vs permeability contrast'), findsNothing, reason: 'not twice');
      expect(tester.takeException(), isNull);
    });
  });
}
