import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/mock/mock_run_repository.dart';
import 'package:soliton/data/providers.dart';

import 'test_app.dart';

// A live update refreshes allRunsProvider; the lists the screens show
// (runsProvider, simulationsProvider) are rebuilt from it. While that
// happens the screen keeps its list: swapping it for a spinner made it
// flash at every update.
void main() {
  // Slow enough that the refresh is still loading a frame later.
  MockRunRepository slow() => MockRunRepository(latency: const Duration(milliseconds: 300));

  // Removes the app, so the slow repository's timers end with the test.
  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the runs list stays on screen while it refreshes', (tester) async {
    await tester.pumpWidget(buildApp(repository: slow()));
    await tester.pumpAndSettle();
    expect(find.text('resnet50-cifar'), findsOneWidget);

    containerOf(tester).invalidate(allRunsProvider);
    await tester.pump(); // the refresh has started, not finished
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('resnet50-cifar'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('resnet50-cifar'), findsOneWidget);
    await closeApp(tester);
  });

  testWidgets('so does the simulations list', (tester) async {
    await tester.pumpWidget(buildApp(repository: slow()));
    await tester.pumpAndSettle();
    routerOf(tester).go('/compute');
    await tester.pumpAndSettle();
    final simulation = (await containerOf(tester).read(simulationsProvider.future)).first.name;
    expect(find.text(simulation), findsOneWidget);

    containerOf(tester).invalidate(allRunsProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(simulation), findsOneWidget);
    await tester.pumpAndSettle();
    await closeApp(tester);
  });
}
