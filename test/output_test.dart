import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/api_run_repository.dart';
import 'package:soliton/data/services/server_connection.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/features/run_detail/widgets/output_card.dart';
import 'package:soliton/models/run_output.dart';

import 'fake_server.dart';
import 'test_app.dart';

void main() {
  test('reads the server\'s output and counts what it no longer has', () {
    final output = RunOutput.fromJson({
      'lines': ['epoch 1', 'RuntimeError: NaN'],
      'total': 1502,
    });
    expect(output.lines.last, 'RuntimeError: NaN');
    expect(output.dropped, 1500);
    expect(RunOutput.fromJson({}).lines, isEmpty);
  });

  test('the repository fetches a run\'s output from the server', () async {
    final server = FakeServer();
    final repository = ApiRunRepository(
      server.clientFor(ServerConnection.parse('https://runs.example.com', 'secret')!),
    );
    final output = await repository.fetchOutput('unet-seg');
    expect(output.lines.first, startsWith('soliton: run unet-seg'));
    expect(output.lines.last, startsWith('RuntimeError: Loss became NaN'));
  });

  group('a crashed run', () {
    testWidgets('shows its traceback first on the Overview, once shown', (tester) async {
      await openApp(tester, '/runs/unet-seg', MemorySettingsStore({'showCrashOutput': true}));
      expect(find.byType(OutputCard), findsOneWidget);
      expect(find.textContaining('Traceback (most recent call last):'), findsOneWidget);
      expect(find.textContaining('RuntimeError: Loss became NaN'), findsOneWidget);
      expect(
        find.byType(OutputCard).hitTestable(),
        findsOneWidget,
        reason: 'on screen without scrolling',
      );
    });

    testWidgets('opens all of its output, to copy', (tester) async {
      await openApp(tester, '/runs/unet-seg', MemorySettingsStore({'showCrashOutput': true}));
      final button = find.byIcon(Icons.open_in_full);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Output · unet-seg'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.tap(find.byTooltip('Copy all'));
      await tester.pump();
      expect(find.textContaining('Copied'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Output · unet-seg'), findsNothing);
    });

    testWidgets('is hidden until shown, and stays as left', (tester) async {
      final store = MemorySettingsStore();
      await openApp(tester, '/runs/unet-seg', store);
      expect(find.byType(OutputCard), findsOneWidget, reason: 'its title shows, to open it');
      expect(find.textContaining('Traceback'), findsNothing);
      expect(find.textContaining('Hidden on crashed runs'), findsOneWidget);

      await tester.tap(find.byTooltip('Show output'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Traceback'), findsOneWidget);
      expect(store.getBool('showCrashOutput'), isTrue);

      await openApp(tester, '/compute/burgers-shock-fd', store);
      expect(find.textContaining('sim.log('), findsOneWidget);
      await tester.tap(find.byTooltip('Hide output'));
      await tester.pumpAndSettle();
      expect(find.textContaining('sim.log('), findsNothing);
      expect(store.getBool('showCrashOutput'), isFalse);
    });

    testWidgets('hiding it leaves live runs\' output alone', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      await tester.scrollUntilVisible(find.byType(OutputCard), 200, scrollable: visibleList());
      expect(find.textContaining('epoch 42/100'), findsOneWidget);
      expect(find.byTooltip('Hide output'), findsNothing);
    });
  });

  testWidgets('a live run shows the end of its output further down', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar');
    await tester.scrollUntilVisible(find.byType(OutputCard), 200, scrollable: visibleList());
    expect(find.textContaining('epoch 42/100'), findsOneWidget);
    expect(find.textContaining('Traceback'), findsNothing);
  });

  testWidgets('a diverged simulation shows its output too', (tester) async {
    await openApp(tester, '/compute/burgers-shock-fd', MemorySettingsStore({'showCrashOutput': true}));
    expect(find.byType(OutputCard), findsOneWidget);
    expect(find.textContaining('sim.log('), findsOneWidget);
  });
}
