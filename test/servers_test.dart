import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/saved_servers.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';

import 'fake_server.dart';
import 'test_app.dart';

ServerConnection at(String address, String token) => ServerConnection.parse(address, token)!;

/// A container over [settings] and [tokens], started the way the app is:
/// with the tokens secure storage held at launch.
ProviderContainer started(MemorySettingsStore settings, MemoryTokenStore tokens) {
  final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(settings),
      tokenStoreProvider.overrideWithValue(tokens),
      savedTokenProvider.overrideWithValue(tokens.token),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('an older app\'s one server becomes the first of the list', () {
    final container = started(
      MemorySettingsStore({'serverAddress': 'https://runs.example.com'}),
      MemoryTokenStore('secret'),
    );
    final list = container.read(serversProvider);
    expect(list.servers.single.name, 'runs.example.com');
    expect(container.read(connectionProvider), at('https://runs.example.com', 'secret'));
  });

  test('several servers, each with its own token; switching and a restart keep them', () async {
    final settings = MemorySettingsStore();
    final tokens = MemoryTokenStore();
    var container = started(settings, tokens);
    final servers = container.read(serversProvider.notifier);
    servers.connect(at('https://lab.example.com', 'lab-token'), name: 'Lab');
    servers.connect(at('http://localhost:8100', 'sherlock-token'), name: 'Sherlock test');
    await pumpEventQueue();
    expect(container.read(connectionProvider), at('http://localhost:8100', 'sherlock-token'));

    final lab = container.read(serversProvider).servers.firstWhere((s) => s.name == 'Lab');
    servers.switchTo(lab.id);
    await pumpEventQueue();
    expect(container.read(connectionProvider), at('https://lab.example.com', 'lab-token'));
    expect(settings.getString('servers'), isNot(contains('token')), reason: 'tokens kept apart');

    container = started(settings, tokens); // The app starts again.
    expect(container.read(serversProvider).servers.map((s) => s.name), ['Lab', 'Sherlock test']);
    expect(container.read(connectionProvider), at('https://lab.example.com', 'lab-token'));
  });

  test('the same address again replaces its token; rename and remove', () async {
    final container = started(MemorySettingsStore(), MemoryTokenStore());
    final servers = container.read(serversProvider.notifier);
    servers.connect(at('https://lab.example.com', 'old'), name: 'Lab');
    servers.connect(at('lab.example.com', 'new'));
    var list = container.read(serversProvider);
    expect(list.servers, hasLength(1));
    expect(list.servers.single.name, 'Lab', reason: 'kept without a new name');
    expect(container.read(connectionProvider)?.token, 'new');

    servers.rename(list.currentId!, 'Lab GPU box');
    expect(container.read(serversProvider).current?.name, 'Lab GPU box');
    servers.remove(list.currentId!);
    list = container.read(serversProvider);
    expect(list.servers, isEmpty);
    expect(list.currentId, isNull);
    expect(list.tokens, isEmpty);
    expect(container.read(connectionProvider), isNull);
  });

  testWidgets('the Servers screen switches between saved servers', (tester) async {
    final server = FakeServer();
    final settings = MemorySettingsStore();
    final tokens = MemoryTokenStore();
    await tester.pumpWidget(
      buildApp(
        store: settings,
        tokens: tokens,
        overrides: [apiClientFactoryProvider.overrideWithValue(server.clientFor)],
      ),
    );
    await tester.pumpAndSettle();
    containerOf(tester).read(serversProvider.notifier)
      ..connect(at('https://runs.example.com', 'secret'), name: 'Lab')
      ..connect(at('https://other.example.com', 'secret'), name: 'Cloud');
    routerOf(tester).go('/settings/server');
    await tester.pumpAndSettle();
    expect(find.text('Servers'), findsWidgets);
    expect(find.text('Lab'), findsOneWidget);
    expect(find.text('Cloud'), findsOneWidget);

    await tester.tap(find.text('Lab'));
    await tester.pumpAndSettle();
    expect(find.text('Showing Lab'), findsOneWidget);
    expect(containerOf(tester).read(connectionProvider)?.address, 'https://runs.example.com');

    await tester.tap(find.byTooltip('More for Cloud'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Cloud'), findsNothing);
    expect(containerOf(tester).read(serversProvider).servers.single.name, 'Lab');
  });

  test('tokens from secure storage: the map, or an older app\'s plain one', () {
    expect(ServerList.decodeTokens('{"tokens":{"a":"x","b":"y"}}'), {'a': 'x', 'b': 'y'});
    expect(ServerList.decodeTokens('plain', fallbackId: 'server-1'), {'server-1': 'plain'});
    expect(ServerList.decodeTokens(null), isEmpty);
    expect(ServerList.hostOf('http://localhost:8100'), 'localhost:8100');
  });
}
