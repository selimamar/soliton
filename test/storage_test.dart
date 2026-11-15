import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';
import 'package:soliton/features/run_detail/tabs/overview_tab.dart';
import 'package:soliton/features/settings/storage_screen.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/models/storage_report.dart';

import 'fake_server.dart';
import 'test_app.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Future<void> openStorage(WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        store: MemorySettingsStore({'serverAddress': 'https://runs.example.com'}),
        tokens: MemoryTokenStore('secret'),
        overrides: [apiClientFactoryProvider.overrideWithValue(server.clientFor)],
      ),
    );
    await tester.pumpAndSettle();
    routerOf(tester).go('/settings');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Storage'), 300, scrollable: visibleList());
    await tester.tap(find.text('Storage'));
    await tester.pumpAndSettle();
  }

  testWidgets('Settings shows how much space each run takes', (tester) async {
    await openStorage(tester);
    expect(find.byType(StorageScreen), findsOneWidget);
    expect(find.text('9 MB'), findsOneWidget, reason: 'the database');
    expect(find.textContaining('2.5 MB can be given back'), findsOneWidget);
    expect(find.text('resnet50-cifar'), findsOneWidget);
    expect(find.text('unet-seg'), findsOneWidget);
    expect(find.text('4.5 MB'), findsNWidgets(2));
  });

  testWidgets('an ended run is thinned after asking; a live one can\'t be', (tester) async {
    await openStorage(tester);
    expect(find.byTooltip('Thin out resnet50-cifar'), findsNothing, reason: 'still live');
    await tester.tap(find.byTooltip('Thin out unet-seg'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining("can't be undone"),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Thin out'));
    await tester.pumpAndSettle();
    expect(server.thinned, {'unet-seg'});
    expect(find.textContaining('about 4.2 MB freed'), findsOneWidget);
    expect(find.textContaining('thinned'), findsWidgets);
    expect(find.byTooltip('Thin out unet-seg'), findsNothing, reason: 'nothing left to thin');
  });

  testWidgets('cancelling leaves the run as it was', (tester) async {
    await openStorage(tester);
    await tester.tap(find.byTooltip('Thin out unet-seg'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.thinned, isEmpty);
  });

  testWidgets('old runs are thinned in one go, showing how many first', (tester) async {
    await openStorage(tester);
    await tester.tap(find.text('Thin old runs…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();
    expect(find.text('No run that old has anything to thin.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.thinned, isEmpty);
  });

  testWidgets('freed space is given back after asking', (tester) async {
    await openStorage(tester);
    await tester.tap(find.text('Give back 2.5 MB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Give back'));
    await tester.pumpAndSettle();
    expect(server.compacted, 1);
    expect(find.text('Database 9 MB → 6.5 MB.'), findsOneWidget);
    expect(find.text('Give back 2.5 MB'), findsNothing);
  });

  testWidgets('a run opens from the list', (tester) async {
    await openStorage(tester);
    await tester.tap(find.text('unet-seg'));
    await tester.pumpAndSettle();
    expect(locationOf(tester), '/runs/unet-seg');
  });

  test('a thinned run says what it kept', () {
    final sample = buildMockRuns(DateTime.utc(2026, 11, 14)).first.run;
    final run = Run.fromJson({
      ...sample.toJson(),
      'thinnedAt': '2026-11-15T03:00:00Z',
      'thinnedTo': 1000,
    });
    expect(thinnedNote(run), contains('each curve keeps 1,000 points'));
    expect(Run.fromJson(run.toJson()), run, reason: 'JSON round trip');
    expect(thinnedNote(sample), isNull);
  });

  test('the server says which runs have something to thin', () {
    final run = RunStorage.fromJson({
      'runId': 'a',
      'status': 'finished',
      'bytes': 10,
      'thinnable': true,
    });
    expect(run.thinnable, isTrue);
    expect(
      RunStorage.fromJson({'runId': 'b', 'status': 'finished'}).thinnable,
      isFalse,
      reason: 'not said: nothing to thin',
    );
  });
}
