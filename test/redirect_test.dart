import 'package:flutter_test/flutter_test.dart';

import 'test_app.dart';

/// A link to a simulation under /runs, or to a training run under
/// /compute (typed, or an old bookmark), opens it where it belongs.
void main() {
  testWidgets('a simulation linked under /runs opens in Compute, on the same tab', (tester) async {
    await openApp(tester, '/runs/kelvin-helmholtz-2048?tab=fields');
    expect(locationOf(tester), '/compute/kelvin-helmholtz-2048?tab=fields');
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a run linked under /compute opens as a run; Diagnostics become Metrics', (
    tester,
  ) async {
    await openApp(tester, '/compute/fno-navier-stokes?tab=diagnostics');
    expect(locationOf(tester), '/runs/fno-navier-stokes?tab=metrics');
    expect(find.text('Layers'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tab only one of them has opens the Overview', (tester) async {
    await openApp(tester, '/runs/kelvin-helmholtz-2048?tab=layers');
    expect(locationOf(tester), '/compute/kelvin-helmholtz-2048');
  });
}
