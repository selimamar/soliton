import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/board_providers.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/saved_servers.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';
import 'package:soliton/features/board/board_screen.dart';
import 'package:soliton/models/board_card.dart';

import 'fake_server.dart';
import 'test_app.dart';

const lab = SavedServer(id: 's1', name: 'Lab', address: 'https://lab.example.com');
const laptop = SavedServer(id: 's2', name: 'Laptop', address: 'https://laptop.example.com');

Map<String, Object?> card(
  String id,
  String title, {
  String project = '',
  String column = 'todo',
  List<Map<String, Object?>> links = const [],
  String? tag,
}) => {
  'id': id,
  'title': title,
  'project': project,
  'column': column,
  'position': 0,
  'notes': '',
  'checklist': <Object>[],
  'links': links,
  'tag': tag,
  'due': null,
  'createdAt': '2026-11-10T09:00:00Z',
  'updatedAt': '2026-11-10T09:00:00Z',
};

/// A screen of [width] × [height] logical pixels for this test.
void screen(WidgetTester tester, double width, double height) {
  tester.view
    ..physicalSize = Size(width, height)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  test('a card goes to the server and back unchanged', () {
    final original = BoardCard(
      id: 'c1',
      title: 'Sweep modes',
      project: 'FNO paper',
      column: BoardColumn.running,
      position: 2.5,
      notes: 'Plateau near 40k.',
      checklist: const [
        ChecklistItem(text: 'Copy settings', done: true),
        ChecklistItem(text: 'Submit'),
      ],
      links: const [
        BoardLink(kind: BoardLinkKind.run, id: 'fno-ns'),
        BoardLink(kind: BoardLinkKind.dataset, id: 'ns2d', server: 'https://lab.example.com'),
      ],
      tag: 'sweep',
      due: DateTime(2026, 11, 18),
    );
    final json = original.toJson();
    expect(json['due'], '2026-11-18');
    expect(json['column'], 'running');
    final back = BoardCard.fromJson({...json, 'id': 'c1'});
    expect(back.toJson(), json);
    expect(back.checked, 1);
    expect(BoardColumn.parse('later'), BoardColumn.todo, reason: 'unknown columns are To do');
  });

  group('on demo data', () {
    testWidgets('the Board section shows lanes by project with live links', (tester) async {
      screen(tester, 1000, 1600);
      await openApp(tester);
      await tester.tap(find.text('Board'));
      await tester.pumpAndSettle();
      expect(locationOf(tester), '/board');
      for (final lane in ['neural-operators', 'convection', 'aerodynamics', 'No project']) {
        expect(find.text(lane), findsOneWidget, reason: lane);
      }
      expect(find.text('Sweep Fourier modes and width'), findsOneWidget);
      // The sweep card's tag gathers the four sweep runs.
      expect(find.textContaining('sweep · 4 runs'), findsOneWidget);
      expect(find.text('2/4 · due ${_inFourDays()}'), findsOneWidget);
    });

    testWidgets('a card opens, and edits to it are kept', (tester) async {
      screen(tester, 1000, 1600);
      await openApp(tester, '/board');
      await tester.tap(find.text('Sweep Fourier modes and width'));
      await tester.pumpAndSettle();
      expect(find.text('Copy settings from fno-navier-stokes'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Add a step'), 'Write it up');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Running'));
      await tester.pumpAndSettle();

      final saved = containerOf(tester).read(boardProvider).value!.byKey('demo-sweep')!.card;
      expect(saved.checklist.last.text, 'Write it up');
      expect(saved.column, BoardColumn.running);

      // A linked run opens its page.
      await tester.scrollUntilVisible(
        find.text('fno-navier-stokes').first,
        200,
        scrollable: visibleList(),
      );
      await tester.tap(find.text('fno-navier-stokes').first);
      await tester.pumpAndSettle();
      // Opened over the board, so going back returns to it.
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('fno-navier-stokes'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Copy settings from fno-navier-stokes'), findsOneWidget);
    });

    testWidgets('a new card goes at the end of its lane\'s column', (tester) async {
      await openApp(tester, '/board');
      await tester.tap(find.byTooltip('New card'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Check the data loader');
      await tester.enterText(find.widgetWithText(TextField, 'Project'), 'convection');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Ideas'));
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      // It opens: the title field shows it.
      expect(find.widgetWithText(TextField, 'Check the data loader'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      final board = containerOf(tester).read(boardProvider).value!;
      expect(
        board.cell('convection', BoardColumn.ideas).single.card.title,
        'Check the data loader',
      );
    });

    testWidgets('on a phone: one column at a time, and a long press drags a card to a tab', (
      tester,
    ) async {
      screen(tester, 390, 844);
      await openApp(tester, '/board');
      // To do first, with each column's count on its tab.
      expect(find.text('Sweep Fourier modes and width'), findsOneWidget);
      expect(find.text('3D turbulence model'), findsNothing);
      expect(find.bySemanticsLabel('Running, 2 cards'), findsOneWidget);
      await tester.tap(find.text('RUNNING'));
      await tester.pumpAndSettle();
      expect(find.text('3D turbulence model'), findsOneWidget);
      expect(find.text('Sweep Fourier modes and width'), findsNothing);

      final drag = await tester.startGesture(tester.getCenter(find.text('3D turbulence model')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await drag.moveTo(tester.getCenter(find.text('DONE')));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      final card = containerOf(tester).read(boardProvider).value!.byKey('demo-fno3d')!.card;
      expect((card.column, card.project), (BoardColumn.done, 'neural-operators'));
      expect(find.text('Moved "3D turbulence model" to Done'), findsOneWidget);
      expect(find.text('3D turbulence model'), findsNothing, reason: 'Running is still shown');

      // A card opens over the section bar.
      await tester.tap(find.text('Rayleigh–Bénard reference run'));
      await tester.pumpAndSettle();
      expect(find.text('Card'), findsOneWidget);
      expect(find.byType(NavigationBar).hitTestable(), findsNothing);
    });

    testWidgets('on a phone, the dialogs fit above the keyboard', (tester) async {
      screen(tester, 412, 915);
      await openApp(tester, '/board');
      // The keyboard takes the bottom 40% of the screen.
      tester.view.viewInsets = const FakeViewPadding(bottom: 370);
      await tester.tap(find.byTooltip('New card'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sweep Fourier modes and width'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Link a run, simulation or dataset'),
        200,
        scrollable: visibleList(),
      );
      await tester.tap(find.text('Link a run, simulation or dataset'));
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 370);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Link to'), findsOneWidget);
    });

    testWidgets('moving and hiding Done', (tester) async {
      await openApp(tester, '/board');
      final container = containerOf(tester);
      await container
          .read(boardProvider.notifier)
          .move('demo-quota', project: 'neural-operators', column: BoardColumn.done);
      await tester.pumpAndSettle();
      final board = container.read(boardProvider).value!;
      expect(board.cell('neural-operators', BoardColumn.done).single.card.id, 'demo-quota');
      expect(find.text('No project'), findsNothing, reason: 'its only card moved away');

      await tester.tap(find.byTooltip('Hide done'));
      await tester.pumpAndSettle();
      expect(find.text('Ask about more A100 hours'), findsNothing);
      expect(container.read(boardHideDoneProvider), isTrue);
    });
  });

  testWidgets('without a server or demo data, the board asks for a server', (tester) async {
    await tester.pumpWidget(buildApp(overrides: const []));
    await tester.pumpAndSettle();
    routerOf(tester).go('/board');
    await tester.pumpAndSettle();
    expect(find.textContaining('Connect a server to keep a board'), findsOneWidget);
    expect(find.byTooltip('New card'), findsNothing);
  });

  group('with two servers', () {
    late FakeServer labServer, laptopServer;
    late FakeLiveSockets sockets;

    setUp(() {
      labServer = FakeServer(runIds: const {'resnet50-cifar'});
      laptopServer = FakeServer(runIds: const {'unet-seg'});
      sockets = FakeLiveSockets();
      labServer.board['a'] = card(
        'a',
        'Tune the ResNet',
        project: 'vision',
        links: [
          {'kind': 'run', 'id': 'resnet50-cifar', 'server': ''},
          // On the laptop: linked by its address.
          {'kind': 'run', 'id': 'unet-seg', 'server': 'https://laptop.example.com/'},
        ],
      );
      laptopServer.board['b'] = card(
        'b',
        'Segment the new images',
        project: 'vision',
        column: 'ideas',
      );
    });

    Future<void> open(WidgetTester tester, {String current = 's1'}) async {
      const list = ServerList(servers: [lab, laptop], tokens: {'s1': 'secret', 's2': 'secret'});
      await tester.pumpWidget(
        buildApp(
          store: MemorySettingsStore({
            ServerList.serversKey: list.encodeServers(),
            ServerList.currentKey: current,
          }),
          tokens: MemoryTokenStore(list.encodeTokens()),
          overrides: [
            apiClientFactoryProvider.overrideWithValue(
              (connection) => connection.address == lab.address
                  ? labServer.clientFor(connection)
                  : laptopServer.clientFor(connection),
            ),
            liveSocketConnectorProvider.overrideWithValue(sockets.connect),
          ],
        ),
      );
      await tester.pumpAndSettle();
      routerOf(tester).go('/board');
      await tester.pumpAndSettle();
    }

    testWidgets('one board pools every server\'s cards, whichever one is shown', (tester) async {
      await open(tester);
      expect(find.text('Tune the ResNet'), findsOneWidget);
      expect(find.text('Segment the new images'), findsOneWidget);
      expect(find.text('vision'), findsOneWidget, reason: 'one lane for the project on both');
      // Both links resolve, the laptop's run too, though only the lab is shown.
      final board = containerOf(tester).read(boardProvider).value!;
      final servers = containerOf(tester).read(serversProvider);
      final a = board.byKey('s1~a')!;
      expect(
        [for (final link in a.card.links) BoardLinks.pooledId(a, link, servers)],
        ['s1~resnet50-cifar', 's2~unet-seg'],
      );
      expect(find.text('unet-seg'), findsOneWidget);
    });

    testWidgets('a card is saved on its own server; links to another carry its address', (
      tester,
    ) async {
      await open(tester);
      final container = containerOf(tester);
      final notifier = container.read(boardProvider.notifier);
      expect(
        [for (final s in notifier.homes) s?.name],
        ['Lab', 'Laptop'],
        reason: 'shown one first',
      );

      final added = await notifier.add(server: laptop, title: 'Compare both', project: 'vision');
      await tester.pumpAndSettle();
      expect(added.key, startsWith('s2~'));
      expect(laptopServer.board[added.card.id]?['title'], 'Compare both');
      expect(labServer.board.keys, ['a']);

      final servers = container.read(serversProvider);
      final link = BoardLinks.linkTo(added, BoardLinkKind.run, 's1~resnet50-cifar', servers);
      expect(link.server, lab.address);
      expect(BoardLinks.linkTo(added, BoardLinkKind.run, 's2~unet-seg', servers).server, '');
      await notifier.save(added.withCard(added.card.copyWith(links: [link])));
      expect(laptopServer.board[added.card.id]?['links'], [
        {'kind': 'run', 'id': 'resnet50-cifar', 'server': lab.address},
      ]);

      await notifier.delete(added.key);
      expect(laptopServer.board.containsKey(added.card.id), isFalse);
    });

    testWidgets('a linked run on another server switches the runs list to it', (tester) async {
      screen(tester, 1300, 900);
      await open(tester);
      await tester.tap(find.text('Tune the ResNet'));
      await tester.pumpAndSettle();
      // Wide: the card opens beside the board.
      expect(find.byType(BoardScreen), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      await tester.tap(find.text('unet-seg').last);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(serversProvider).currentId, 's2');
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Now showing Laptop'), findsOneWidget);
    });

    testWidgets('an old server without a board is named, the others still show', (tester) async {
      laptopServer.hasBoard = false;
      await open(tester);
      expect(find.text('Tune the ResNet'), findsOneWidget);
      expect(find.textContaining('Laptop is too old to keep a board'), findsOneWidget);
      expect(
        [for (final s in containerOf(tester).read(boardProvider.notifier).homes) s?.name],
        ['Lab'],
      );
    });

    testWidgets('a change from another device shows up live', (tester) async {
      await open(tester);
      for (final socket in sockets.opened) {
        socket.push({'type': 'ready'});
      }
      labServer.board['c'] = card('c', 'Added on the phone', project: 'vision');
      sockets.opened.first.push({'type': 'board', 'event': 'updated', 'cardId': 'c'});
      await tester.pumpAndSettle();
      expect(find.text('Added on the phone'), findsOneWidget);
    });
  });
}

String _inFourDays() {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final day = DateTime.now().add(const Duration(days: 4));
  return '${months[day.month - 1]} ${day.day}';
}
