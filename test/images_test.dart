import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:soliton/data/providers.dart';
import 'package:soliton/data/services/settings_store.dart';
import 'package:soliton/data/services/token_store.dart';
import 'package:soliton/features/run_detail/widgets/images_card.dart';
import 'package:soliton/models/logged_image.dart';

import 'fake_server.dart';
import 'test_app.dart';

void main() {
  testWidgets('a run\'s pictures show on its Fields tab, step by step', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar?tab=fields');
    expect(find.byType(ImagesCards), findsOneWidget);
    expect(find.text('confusion matrix'), findsOneWidget);
    expect(find.text('Validation set'), findsOneWidget, reason: 'the latest, by default');
    expect(find.byType(Image), findsOneWidget);

    await tester.ensureVisible(find.byType(Slider));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Slider), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Validation set; cats and dogs get mixed up'), findsOneWidget);
  });

  testWidgets('a picture opens large, to zoom in', (tester) async {
    await openApp(tester, '/runs/resnet50-cifar?tab=fields');
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('a run without pictures or fields says how to log them', (tester) async {
    await openApp(tester, '/runs/gpt-tiny?tab=fields');
    expect(find.byType(ImagesCards), findsNothing);
    expect(find.textContaining('run.log_image(name, figure)'), findsOneWidget);
  });

  testWidgets('pictures come from the server', (tester) async {
    final server = FakeServer(runIds: {'resnet50-cifar'});
    await tester.pumpWidget(
      buildApp(
        store: MemorySettingsStore({'serverAddress': 'https://runs.example.com'}),
        tokens: MemoryTokenStore('secret'),
        overrides: [apiClientFactoryProvider.overrideWithValue(server.clientFor)],
      ),
    );
    await tester.pumpAndSettle();
    routerOf(tester).go('/runs/resnet50-cifar?tab=fields');
    await tester.pumpAndSettle();
    expect(find.text('confusion matrix'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  test('read from the server', () {
    final series = ImageSeries.fromJson({
      'name': 'phase portrait',
      'steps': [
        {'step': 100, 'width': 800, 'height': 400, 'caption': 'epoch 1'},
        {'step': 200},
      ],
    });
    expect(series.steps.map((s) => s.step), [100, 200]);
    expect(series.steps.first.aspectRatio, 2);
    expect(series.steps.last.aspectRatio, 4 / 3, reason: 'size unknown');
    final image = LoggedImage.fromJson({
      'name': 'phase portrait',
      'step': 100,
      'format': 'png',
      'width': 1,
      'height': 1,
      'data': 'iVBORw0KGgo=',
    });
    expect(image.bytes.take(4), [0x89, 0x50, 0x4e, 0x47]);
  });
}
