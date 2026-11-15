import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/api_client.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';

import 'fake_server.dart';
import 'test_app.dart';

void main() {
  late FakeServer server;

  setUp(() => server = FakeServer());

  Future<void> openSettings(WidgetTester tester, {bool connected = true}) async {
    await tester.pumpWidget(
      buildApp(
        store: MemorySettingsStore({
          if (connected) 'serverAddress': 'https://runs.example.com',
        }),
        tokens: connected ? MemoryTokenStore('secret') : null,
        overrides: [apiClientFactoryProvider.overrideWithValue(server.clientFor)],
      ),
    );
    await tester.pumpAndSettle();
    routerOf(tester).go('/settings');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('About'), 300, scrollable: visibleList());
  }

  SwitchListTile jobSwitch(WidgetTester tester) =>
      tester.widget(find.widgetWithText(SwitchListTile, 'Separate token for jobs'));

  testWidgets('turning it on shows the new job token once; turning it off asks first', (
    tester,
  ) async {
    await openSettings(tester);
    expect(find.text('Advanced security'), findsOneWidget);
    expect(jobSwitch(tester).value, isFalse);

    await tester.tap(find.text('Separate token for jobs'));
    await tester.pumpAndSettle();
    expect(find.text('job-token-1'), findsOneWidget);
    expect(find.textContaining('shown only this once'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(server.jobToken, isTrue);
    expect(jobSwitch(tester).value, isTrue);

    await tester.tap(find.text('New job token'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make new token'));
    await tester.pumpAndSettle();
    expect(find.text('job-token-2'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Separate token for jobs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.jobToken, isTrue, reason: 'cancelled');
    await tester.tap(find.text('Separate token for jobs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(server.jobToken, isFalse);
    expect(jobSwitch(tester).value, isFalse);
    expect(find.text('New job token'), findsNothing);
  });

  testWidgets('an older server says it needs updating', (tester) async {
    server.jobToken = null;
    await openSettings(tester);
    expect(find.text('Needs a newer server.'), findsOneWidget);
    expect(jobSwitch(tester).onChanged, isNull);
  });

  testWidgets('only while connected to a server', (tester) async {
    await openSettings(tester, connected: false);
    expect(find.text('Advanced security'), findsNothing);
  });

  test('the job token used as the app\'s token is named as such', () async {
    final client = ApiClient(
      ServerConnection.parse('https://runs.example.com', 'job')!,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'detail': 'This is the job token: it can only add runs and data.'}),
          403,
        ),
      ),
    );
    await expectLater(
      client.checkSession(),
      throwsA(isA<UnauthorizedException>().having((e) => e.jobToken, 'jobToken', isTrue)),
    );
  });
}
