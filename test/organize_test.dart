import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/mock/mock_runs.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/live_updates.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';
import 'package:soliton/data/tags.dart';
import 'package:soliton/features/runs_list/run_groups.dart';
import 'package:soliton/models/layer_info.dart';
import 'package:soliton/models/run.dart';

import 'fake_server.dart';
import 'test_app.dart';

List<Run> demoRuns() => [for (final m in buildMockRuns(DateTime(2026, 11, 12))) m.run];

Run tagged(Run run, List<String> tags, {String notes = ''}) =>
    Run.fromJson({...run.toJson(), 'tags': tags, 'notes': notes});

Map<String, List<String>> summary(List<RunGroup> groups) => {
  for (final group in groups) group.label: [for (final run in group.runs) run.id],
};

Future<void> openGroupingMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Group and order runs'));
  await tester.pumpAndSettle();
}

/// Scrolls the Overview to [finder] and taps it.
Future<void> tapInOverview(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 100, scrollable: visibleList());
  await tester.pumpAndSettle(); // Let the scroll come to rest.
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> addTag(WidgetTester tester, String tag) async {
  await tapInOverview(tester, find.text('Add tag'));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Tag'), tag);
  await tester.pump(); // Enables the button.
  await tester.tap(find.widgetWithText(FilledButton, 'Add'));
  await tester.pumpAndSettle();
}

Future<void> writeNote(WidgetTester tester, String text) async {
  await tapInOverview(tester, find.textContaining(RegExp('Add a note|Edit note')));
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  group('grouping', () {
    test('by project, model, dataset and host, from what the runs logged', () {
      final runs = demoRuns();
      expect(summary(groupRuns(runs, RunGrouping.project)), {
        'image-classification': ['resnet50-cifar', 'vit-small'],
        'language-models': ['gpt-tiny'],
        'neural-operators': [
          'fno-navier-stokes',
          'fno3d-turbulence',
          'fno-ns-m8-w32',
          'fno-ns-m8-w64',
          'fno-ns-m16-w32',
          'fno-ns-m16-w64',
          'queued-52340117',
        ],
        'segmentation': ['unet-seg'],
      });
      expect(groupRuns(runs, RunGrouping.model).map((g) => g.label), [
        'FNO2d',
        'FNO3d',
        'GPT',
        'ResNet',
        'UNet',
        'VisionTransformer',
        'Model not logged', // The queued job.
      ]);
      expect(summary(groupRuns(runs, RunGrouping.dataset))['CIFAR-10'], [
        'resnet50-cifar',
        'vit-small',
      ]);
      expect(groupRuns(runs, RunGrouping.host).map((g) => g.label), ['AWS', 'GCP', 'Sherlock']);
      expect(groupRuns(runs, RunGrouping.none).single.runs, runs);
    });

    test('runs without one come last', () {
      final runs = demoRuns();
      final noProject = Run.fromJson({
        ...runs.first.toJson(),
        'id': 'x',
        'project': '',
        'architecture': const LayerInfo(name: 'x', type: 'Model').toJson(),
        'hyperparameters': {'data.Dataset': 'MNIST'},
      });
      final byProject = groupRuns([noProject, ...runs], RunGrouping.project);
      expect((byProject.last.label, byProject.last.isRest), ('No project', true));
      expect(groupRuns([noProject], RunGrouping.model).single.label, 'Model not logged');
      expect(groupRuns([noProject], RunGrouping.dataset).single.label, 'MNIST', reason: 'nested');
    });

    test('by tag: a run is in each of its tags, ignoring case', () {
      final [a, b, c, ...] = demoRuns();
      final groups = groupRuns([
        tagged(a, ['baseline', 'cifar']),
        tagged(b, ['Baseline']),
        c,
      ], RunGrouping.tag);
      expect(summary(groups), {
        'baseline': ['resnet50-cifar', 'gpt-tiny'],
        'cifar': ['resnet50-cifar'],
        'No tags': ['unet-seg'],
      });
    });

    test('tags are cleaned up as the server does', () {
      expect(cleanTags([' a ', 'A', '', 'b', 'x' * 41]), ['a', 'b']);
      expect(cleanTags([for (var i = 0; i < 30; i++) 't$i']), hasLength(maxTags));
    });
  });

  group('JSON', () {
    test('tags and notes survive a round trip; older servers send none', () {
      final run = tagged(demoRuns().first, ['best'], notes: 'Try 1e-4');
      expect(Run.fromJson(run.toJson()), run);
      final old = {...run.toJson()}
        ..remove('tags')
        ..remove('notes');
      expect(Run.fromJson(old).tags, isEmpty);
      expect(Run.fromJson(old).notes, '');
    });
  });

  group('runs list', () {
    testWidgets('groups by project, folds a group, and remembers the choice', (tester) async {
      final store = MemorySettingsStore();
      await openApp(tester, '/', store);
      await openGroupingMenu(tester);
      await tester.tap(find.text('By project'));
      await tester.pumpAndSettle();

      expect(find.text('image-classification'), findsOneWidget);
      expect(find.text('2 runs'), findsOneWidget);
      expect(store.getString('runsGroupBy'), 'project');

      await tester.tap(find.text('image-classification'));
      await tester.pumpAndSettle();
      expect(find.text('resnet50-cifar'), findsNothing, reason: 'folded away');
      expect(find.text('gpt-tiny'), findsOneWidget);

      await tester.tap(find.text('image-classification'));
      await tester.pumpAndSettle();
      expect(find.text('resnet50-cifar'), findsOneWidget);
    });
  });

  group('tags and notes', () {
    testWidgets('a tag added on a run groups it in the list', (tester) async {
      await openApp(tester, '/runs/unet-seg');
      await addTag(tester, ' needs-rerun ');
      expect(find.widgetWithText(InputChip, 'needs-rerun'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('needs-rerun'), findsOneWidget, reason: 'on the run card');

      await openGroupingMenu(tester);
      await tester.tap(find.text('By tag'));
      await tester.pumpAndSettle();
      expect(find.text('1 run'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('No tags'), 300, scrollable: visibleList());
    });

    testWidgets('tags used elsewhere are suggested, and tags can be removed', (tester) async {
      await openApp(tester, '/runs/unet-seg');
      await addTag(tester, 'ablation');
      routerOf(tester).go('/runs/gpt-tiny');
      await tester.pumpAndSettle();
      await tapInOverview(tester, find.text('Add tag'));
      await tester.tap(find.widgetWithText(ActionChip, 'ablation'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'ablation'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove tag ablation'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'ablation'), findsNothing);
    });

    testWidgets('a note shows on the run and its first line on the card', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      expect(find.textContaining('No note yet'), findsOneWidget);
      await writeNote(tester, 'Plateau after epoch 40.\nTry a longer warmup.');
      expect(find.text('Plateau after epoch 40.\nTry a longer warmup.'), findsOneWidget);
      expect(find.text('Edit note'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Plateau after epoch 40.'), findsOneWidget);
    });

    group('on a server', () {
      late FakeServer server;

      Widget app() => buildApp(
        store: MemorySettingsStore({'serverAddress': 'https://runs.example.com'}),
        tokens: MemoryTokenStore('secret'),
        overrides: [
          apiClientFactoryProvider.overrideWithValue((c) => server.clientFor(c)),
          liveSocketConnectorProvider.overrideWithValue(FakeLiveSockets().connect),
        ],
      );

      setUp(() => server = FakeServer());

      testWidgets('saves the note there', (tester) async {
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        routerOf(tester).go('/runs/unet-seg');
        await tester.pumpAndSettle();
        await writeNote(tester, 'Diverged: LR 0.1 is too high');
        expect(find.text('Diverged: LR 0.1 is too high'), findsOneWidget);
        expect(server.edits, [
          {'notes': 'Diverged: LR 0.1 is too high'},
        ], reason: 'only the note, so tags edited elsewhere are kept');
      });

      testWidgets("keeps the text when it can't save", (tester) async {
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        routerOf(tester).go('/runs/unet-seg');
        await tester.pumpAndSettle();
        server.down = true;
        await writeNote(tester, 'Important thought');
        expect(find.textContaining("Couldn't save."), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Important thought'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget, reason: 'still open');
      });
    });
  });
}
