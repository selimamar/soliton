import 'dart:convert';
import 'dart:typed_data';

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

  test('a picture is as big as its own header says, and a huge one isn\'t drawn', () {
    // A 2 x 2 PNG's header, saying 60000 x 60000: a small, very compressible
    // file can, and decoding it would run the app out of memory.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAAAAABX3VL4AAAADklEQVR4nGM4cYLhxAkACWYDIUK1MmAAAAAASUVORK5CYII=',
    );
    final bomb = Uint8List.fromList(png)..setRange(16, 24, [0, 0, 0xEA, 0x60, 0, 0, 0xEA, 0x60]);
    LoggedImage read(Uint8List data, {String format = 'png'}) => LoggedImage.fromJson({
      'name': 'x',
      'step': 0,
      'format': format,
      'width': 2,
      'height': 2,
      'data': base64Encode(data),
    });
    expect((read(png).width, read(png).height, read(png).drawable), (2, 2, true));
    expect((read(bomb).width, read(bomb).drawable), (60000, false), reason: 'the claim was 2 x 2');

    final jpeg = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0, 16, ...'JFIF'.codeUnits, 0, ...List.filled(9, 0), //
      0xFF, 0xC0, 0, 11, 8, 0x23, 0x28, 0, 20, 1, 0, 0, 0, 0xFF, 0xD9,
    ]);
    final image = read(jpeg, format: 'jpeg');
    expect((image.width, image.height, image.drawable), (20, 9000, false));
  });
}
