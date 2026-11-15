import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/api_client.dart';
import 'package:soliton/data/services/backup_saver.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';
import 'package:soliton/features/run_detail/tabs/overview_tab.dart';
import 'package:soliton/features/settings/storage_screen.dart';
import 'package:soliton/models/run.dart';
import 'package:soliton/models/storage_report.dart';

import 'fake_server.dart';
import 'test_app.dart';

/// Keeps what it is given in memory instead of Downloads or a share sheet.
class FakeSaver extends BackupSaver {
  final saved = <String, List<int>>{};

  @override
  String get destination => 'it goes to your Downloads folder';

  @override
  Future<String?> save(String fileName, Stream<List<int>> bytes, {Rect? origin}) async {
    saved[fileName] = [await for (final chunk in bytes) ...chunk];
    return 'Saved to Downloads as $fileName.';
  }
}

void main() {
  late FakeServer server;
  late FakeSaver saver;

  setUp(() {
    server = FakeServer();
    saver = FakeSaver();
  });

  Future<void> openStorage(WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        store: MemorySettingsStore({'serverAddress': 'https://runs.example.com'}),
        tokens: MemoryTokenStore('secret'),
        overrides: [
          apiClientFactoryProvider.overrideWithValue(server.clientFor),
          backupSaverProvider.overrideWithValue(saver),
        ],
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

  testWidgets('a backup is downloaded after saying what it holds', (tester) async {
    await openStorage(tester);
    await tester.tap(find.text('Download a backup'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.textContaining('Keep it somewhere private')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('your Downloads folder')),
      findsOneWidget,
    );
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(server.backups, 1);
    final (name, bytes) = (saver.saved.keys.single, saver.saved.values.single);
    expect(name, matches(RegExp(r'^soliton-runs\.example\.com-\d{4}-\d\d-\d\d-\d{6}\.db$')));
    expect(utf8.decode(bytes), startsWith('SQLite format 3'));
    expect(find.textContaining('Saved to Downloads as soliton-'), findsOneWidget);
    expect(find.text('Downloading a backup'), findsNothing, reason: 'the progress closes');
  });

  testWidgets('cancelling the question downloads nothing', (tester) async {
    await openStorage(tester);
    await tester.tap(find.text('Download a backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.backups, 0);
    expect(saver.saved, isEmpty);
  });

  testWidgets('a backup the server refuses says why and saves nothing', (tester) async {
    server.backupRefusal = 'Not enough free disk space on the server for a copy';
    await openStorage(tester);
    await tester.tap(find.text('Download a backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Not enough free disk space on the server for a copy'), findsOneWidget);
    expect(saver.saved, isEmpty);
  });

  testWidgets('a PostgreSQL server points to pg_dump instead', (tester) async {
    server.engine = 'postgresql';
    await openStorage(tester);
    expect(find.text('Download a backup'), findsNothing);
    expect(find.textContaining('back it up with pg_dump'), findsOneWidget);
  });

  testWidgets('a run opens from the list', (tester) async {
    await openStorage(tester);
    await tester.tap(find.text('unet-seg'));
    await tester.pumpAndSettle();
    expect(locationOf(tester), '/runs/unet-seg');
  });

  test('a backup download that stops sending gives up', () async {
    // Sends a little, then nothing, without ever finishing.
    final source = StreamController<List<int>>()..add([1, 2, 3]);
    addTearDown(source.close);
    final stalled = MockClient.streaming(
      (request, _) async => http.StreamedResponse(source.stream, 200),
    );
    final client = ApiClient(
      ServerConnection.parse('https://runs.example.com', 'secret')!,
      httpClient: stalled,
      stallLimit: const Duration(milliseconds: 50),
    );
    final download = await client.downloadBackup();
    await expectLater(download.bytes.toList(), throwsA(isA<TimeoutException>()));
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
