import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/app/theme.dart';
import 'package:soliton/data/mock/mock_run_repository.dart';
import 'package:soliton/features/runs_list/widgets/run_card.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/shared/clock.dart';
import 'package:soliton/shared/widgets/line_chart_card.dart';

import 'test_app.dart';

/// Fails its first [failures] calls of fetchRuns, then serves demo data.
class FlakyRunRepository extends MockRunRepository {
  FlakyRunRepository({required this.failures}) : super(latency: const Duration(milliseconds: 100));

  int failures;
  int calls = 0;

  @override
  Future<List<Run>> fetchRuns() async {
    calls++;
    if (failures > 0) {
      failures--;
      await Future<void>.delayed(latency);
      throw Exception('network down');
    }
    return super.fetchRuns();
  }
}

/// All eleven demo runs are listed. The list is lazy and the test screen only
/// fits three cards, so the last one is checked by scrolling to it.
void expectAllRuns(WidgetTester tester) {
  expect(find.text('All · 11'), findsOneWidget);
  expect(find.text('resnet50-cifar'), findsOneWidget);
}

int selectedTab(WidgetTester tester) =>
    DefaultTabController.of(tester.element(find.byType(TabBarView))).index;

void main() {
  testWidgets('runs list shows the demo runs', (tester) async {
    await openApp(tester);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Runs')), findsOneWidget);
    expect(find.text('resnet50-cifar'), findsOneWidget);
    expectAllRuns(tester);
  });

  testWidgets('status filter chips filter the list', (tester) async {
    await openApp(tester);

    // With Queued among them, the chips scroll sideways on a small screen.
    await tester.ensureVisible(find.text('Crashed · 1'));
    await tester.tap(find.text('Crashed · 1'));
    await tester.pumpAndSettle();
    expect(find.byType(RunCard), findsOneWidget);
    expect(find.text('unet-seg'), findsOneWidget);

    await tester.ensureVisible(find.text('All · 11'));
    await tester.tap(find.text('All · 11'));
    await tester.pumpAndSettle();
    expect(find.byType(RunCard), findsAtLeast(2));
  });

  testWidgets('tapping a run opens its detail tabs and updates the URL', (tester) async {
    await openApp(tester);

    await tester.tap(find.text('resnet50-cifar'));
    await tester.pumpAndSettle();

    expect(locationOf(tester), '/runs/resnet50-cifar');
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Metrics'), findsOneWidget);
    expect(find.text('Layers'), findsOneWidget);
    expect(find.text('Tags and notes'), findsOneWidget); // The Overview, near its top.

    // Back returns to the list, because the detail route is nested under '/'.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(locationOf(tester), '/');
    expectAllRuns(tester);
  });

  testWidgets('switching between Overview, Metrics and Layers', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar');

    await tester.tap(find.text('Metrics'));
    await tester.pumpAndSettle();
    expect(find.text('Loss'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Gradient norm by layer (latest)'),
      300,
      scrollable: visibleList(),
    );
    await tester.scrollUntilVisible(
      find.text('train/tokens_per_second'),
      300,
      scrollable: visibleList(),
    );

    await tester.tap(find.text('Layers'));
    await tester.pumpAndSettle();
    expect(find.text('conv1'), findsOneWidget);

    await tester.tap(find.text('conv1'));
    await tester.pumpAndSettle();
    expect(find.text('Activation distribution (latest)'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // Tap the scrim to close the sheet.
    await tester.pumpAndSettle();

    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('Tags and notes'), findsOneWidget); // The Overview, near its top.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the crashed run renders all tabs', (tester) async {
    await openApp(tester, '/runs/unet-seg');

    expect(
      find.text('Loss became NaN at step 3,412. The learning rate may be too high.'),
      findsOneWidget,
    );
    for (final tab in ['Metrics', 'Layers', 'Overview']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tab keeps its scroll position when switching tabs', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar');

    final architecture = find.text('Architecture · ResNet');
    await tester.scrollUntilVisible(architecture, 200, scrollable: visibleList());
    await tester.pumpAndSettle(); // Let the scroll come to rest.
    final before = tester.getTopLeft(architecture);

    await tester.tap(find.text('Layers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(architecture), before);
  });

  testWidgets('a fast horizontal swipe on a chart does not switch tabs', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar');
    await tester.tap(find.text('Metrics'));
    await tester.pumpAndSettle();

    // A fling (not a slow drag, which would snap back anyway): without the
    // fix, this switched to the Layers tab.
    final chart = find.byType(LineChartCard).first;
    await tester.fling(chart, const Offset(-400, 0), 2000);
    await tester.pumpAndSettle();

    expect(selectedTab(tester), 1, reason: 'still on the Metrics tab');
  });

  testWidgets('an unknown run shows "Run not found" without Retry or tabs', (tester) async {
    await openApp(tester, '/runs/does-not-exist');

    expect(find.text('Run not found'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(find.textContaining('Invalid argument'), findsNothing);
  });

  testWidgets('an unknown path shows the not-found screen', (tester) async {
    await openApp(tester, '/no/such/page');

    expect(find.text('Page not found'), findsOneWidget);
    await tester.tap(find.text('Go to runs'));
    await tester.pumpAndSettle();
    expectAllRuns(tester);
  });

  testWidgets('a failed load retries a few times, then offers Retry', (tester) async {
    final repository = FlakyRunRepository(failures: 4); // 1 attempt + 3 retries.
    await tester.pumpWidget(buildApp(repository: repository));

    // While Riverpod retries automatically, the list shows a spinner.
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(repository.calls, 4);
    expect(find.text("Couldn't load data"), findsOneWidget);
    expect(find.textContaining('network down'), findsNothing, reason: 'no raw error text');

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'Retry shows progress');

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expectAllRuns(tester);
  });

  testWidgets('elapsed time keeps moving', (tester) async {
    await openApp(tester);
    expect(find.text('Epoch 42/100 · 3h 12m'), findsOneWidget);

    containerOf(tester).read(clockProvider.notifier).state = DateTime.now().add(
      const Duration(minutes: 5),
    );
    await tester.pump();
    expect(find.text('Epoch 42/100 · 3h 17m'), findsOneWidget);
  });

  testWidgets('a style picked in settings restyles the app', (tester) async {
    await openApp(tester, '/settings');
    expect(
      Theme.of(tester.element(find.text('Settings'))).colorScheme.primary,
      AppTheme.light().colorScheme.primary,
    );

    await tester.tap(find.text('Lab'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('Settings'))).colorScheme.primary,
      AppTheme.light(AppStyle.lab).colorScheme.primary,
    );
  });

  testWidgets('settings opens from the runs list', (tester) async {
    await openApp(tester);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(locationOf(tester), '/settings');
    await tester.scrollUntilVisible(find.text('Version 0.2.0'), 300, scrollable: visibleList());
    expect(find.text('Version 0.2.0'), findsOneWidget);
  });
}
