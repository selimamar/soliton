import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/app/app.dart';
import 'package:models_app/app/router.dart';
import 'package:models_app/data/mock/mock_run_repository.dart';
import 'package:models_app/data/providers.dart';
import 'package:models_app/data/run_repository.dart';

/// The whole app on demo data without network delay (or on [repository]).
Widget buildApp({RunRepository? repository}) => ProviderScope(
  overrides: [
    runRepositoryProvider.overrideWithValue(
      repository ?? MockRunRepository(latency: Duration.zero),
    ),
  ],
  child: const ModelsApp(),
);

/// The Riverpod container of the app pumped with [buildApp].
ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ModelsApp)));

GoRouter routerOf(WidgetTester tester) => containerOf(tester).read(routerProvider);

/// The current location, e.g. `/runs/unet-seg`.
String locationOf(WidgetTester tester) =>
    routerOf(tester).routerDelegate.currentConfiguration.uri.toString();

/// The vertical list currently on screen. Kept-alive tabs leave other lists
/// in the tree, so `scrollUntilVisible` needs to be told which one to use.
Finder visibleList() => find
    .byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)
    .hitTestable()
    .first;

/// Pumps the app and opens [location] directly, like a deep link.
Future<void> openApp(WidgetTester tester, [String location = '/']) async {
  await tester.pumpWidget(buildApp());
  await tester.pumpAndSettle();
  if (location != '/') {
    routerOf(tester).go(location);
    await tester.pumpAndSettle();
  }
}
