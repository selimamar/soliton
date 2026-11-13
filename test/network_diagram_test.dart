import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:models_app/data/mock/mock_architectures.dart';
import 'package:models_app/data/mock/mock_flows.dart';
import 'package:models_app/data/mock/mock_runs.dart';
import 'package:models_app/features/run_detail/network_layout.dart';
import 'package:models_app/features/run_detail/tabs/overview_tab.dart';
import 'package:models_app/models/model_flow.dart';
import 'package:models_app/models/run.dart';

import 'test_app.dart';

FlowLayer layer(String name, String type, FlowKind kind, int width, {int parameters = 0}) =>
    FlowLayer(
      name: name,
      type: type,
      kind: kind,
      shape: [width],
      width: width,
      parameters: parameters,
    );

/// nn.Sequential(Linear(32, 128), ReLU(), Linear(128, 128), ReLU(), ...):
/// what `modelsapp demo` trains.
const mlp = ModelFlow(
  input: FlowInput(shape: [32], width: 32),
  layers: [
    FlowLayer(
      name: '0',
      type: 'Linear',
      kind: FlowKind.linear,
      shape: [128],
      width: 128,
      parameters: 4224,
    ),
    FlowLayer(name: '1', type: 'ReLU', kind: FlowKind.activation, shape: [128], width: 128),
    FlowLayer(
      name: '2',
      type: 'Linear',
      kind: FlowKind.linear,
      shape: [128],
      width: 128,
      parameters: 16512,
    ),
    FlowLayer(name: '3', type: 'ReLU', kind: FlowKind.activation, shape: [128], width: 128),
    FlowLayer(
      name: '4',
      type: 'Linear',
      kind: FlowKind.linear,
      shape: [64],
      width: 64,
      parameters: 8256,
    ),
    FlowLayer(name: '5', type: 'ReLU', kind: FlowKind.activation, shape: [64], width: 64),
    FlowLayer(
      name: '6',
      type: 'Linear',
      kind: FlowKind.linear,
      shape: [10],
      width: 10,
      parameters: 650,
    ),
  ],
);

List<String> labels(List<DiagramColumn> columns) => [for (final c in columns) c.toString()];

/// A demo run without its flow, like a run logged by an older logger.
Run withoutFlow(Run run) {
  final json = run.toJson();
  final architecture = Map.of(json['architecture']! as Map<String, Object?>)
    ..remove('flow')
    ..remove('input');
  return Run.fromJson({...json, 'architecture': architecture});
}

void main() {
  group('diagram columns', () {
    test('a small MLP: one column per Linear layer, activations noted', () {
      final columns = diagramColumns(mlp);
      expect(labels(columns), ['Input 32', 'Linear 128', 'Linear 128', 'Linear 64', 'Linear 10']);
      expect(columns.first.isInput, isTrue);
      expect(columns[1].description, contains('Then ReLU'));
      expect(columns[2].repeat, 1, reason: 'layers are only merged when there are too many');
      expect(columns.every((c) => c.shape == UnitShape.circle), isTrue);
    });

    test('ResNet-50: stages on a phone, blocks with repeats on a wider screen', () {
      final narrow = diagramColumns(resnet50CifarFlow(), tree: resnet50Cifar(), maxColumns: 7);
      expect(labels(narrow), [
        'Input 3×32×32',
        'Conv2d 64',
        'layer1 256',
        'layer2 512',
        'layer3 1,024',
        'layer4 2,048',
        'Linear 10',
      ]);
      expect(narrow[1].shape, UnitShape.square, reason: 'convolution channels');
      expect(narrow[2].description, startsWith('layer1 (Sequential)\n10 layers'));
      expect(narrow[1].description, contains('Then BatchNorm2d, ReLU, MaxPool2d'));

      final wide = diagramColumns(resnet50CifarFlow(), tree: resnet50Cifar());
      expect(wide.map((c) => c.title), [
        'Input',
        'Conv2d',
        'layer1.0',
        'layer1.1',
        'layer2.0',
        'layer2.1',
        'layer3.0',
        'layer3.1',
        'layer4.0',
        'layer4.1',
        'Linear',
      ]);
      expect(wide[3].repeat, 2);
      expect(wide[3].detail, '×2 · 256');
      expect(wide[3].description, contains('2 identical blocks of 3 layers'));
      expect(wide[2].description, contains('4 layers'), reason: 'the first block also downsamples');
    });

    test('transformer blocks collapse into one column, even before a final norm', () {
      final gpt = diagramColumns(gptTinyFlow(), tree: gptTiny());
      expect(labels(gpt), [
        'Tokens 1024',
        'Embedding 384',
        'Embedding 384',
        'blocks.0 ×6 · 384',
        'Linear 50,257',
      ]);
      expect(gpt[3].description, startsWith('blocks.0–5 (TransformerBlock)'));
      expect(gpt[2].description, isNot(contains('LayerNorm')), reason: 'ln_1 is part of block 0');

      final vit = diagramColumns(vitSmallFlow(), tree: vitSmall());
      expect(labels(vit), ['Input 3×224×224', 'Conv2d 384', 'blocks.0 ×12 · 384', 'Linear 10']);
    });

    test('a UNet shows its way down and up', () {
      final columns = diagramColumns(unetFlow(), tree: unet());
      expect(columns.map((c) => c.title), [
        'Input',
        'inc',
        'down1',
        'down2',
        'down3',
        'down4',
        'up1',
        'up2',
        'up3',
        'up4',
        'Conv2d',
      ]);
      expect(columns.map((c) => c.width).skip(1), [64, 128, 256, 512, 1024, 512, 256, 128, 64, 2]);
    });

    test('nothing to draw without layers that have weights', () {
      final flow = ModelFlow(layers: [layer('act', 'ReLU', FlowKind.activation, 8)]);
      expect(diagramColumns(flow), isEmpty);
    });

    test('a layer with parameters of an unknown kind is drawn', () {
      final flow = ModelFlow(
        layers: [
          layer('mixer', 'TokenMixer', FlowKind.other, 64, parameters: 100),
          layer('scale', 'Scale', FlowKind.other, 64),
        ],
      );
      expect(labels(diagramColumns(flow)), ['TokenMixer 64']);
    });

    test('units grow with the logarithm of the width', () {
      expect(unitsShown(3), (count: 3, more: false));
      expect(unitsShown(10), (count: 5, more: true));
      expect(unitsShown(128), (count: 9, more: true));
      expect(unitsShown(50257), (count: 10, more: true));
      expect(unitsShown(null), (count: 3, more: true));
    });
  });

  group('JSON', () {
    test("the logger's flow is read from the architecture", () {
      final flow = ModelFlow.fromArchitectureJson({
        'name': 'SmallCNN',
        'type': 'SmallCNN',
        'children': <Object?>[],
        'input': {
          'shape': [3, 8, 8],
          'tokens': false,
          'width': 3,
        },
        'flow': [
          {
            'name': 'features.0',
            'type': 'Conv2d',
            'kind': 'conv',
            'shape': [16, 8, 8],
            'width': 16,
            'parameters': 448,
          },
          {'name': 'x', 'type': 'Mystery', 'kind': 'from-a-newer-logger', 'shape': <Object?>[]},
        ],
      })!;
      expect(flow.input, const FlowInput(shape: [3, 8, 8], width: 3));
      expect(flow.layers.first.kind, FlowKind.conv);
      expect(flow.layers.last.kind, FlowKind.other);
      expect(flow.layers.last.width, isNull);
    });

    test('a run without a flow has none, and keeps none', () {
      final run = withoutFlow(buildMockRuns(DateTime(2026, 11, 12)).first.run);
      expect(run.flow, isNull);
      expect((run.toJson()['architecture']! as Map).containsKey('flow'), isFalse);
    });
  });

  group('Overview', () {
    testWidgets('shows the data, the loss and the network diagram', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      await tester.scrollUntilVisible(
        find.text('Training samples'),
        200,
        scrollable: visibleList(),
      );
      expect(find.text('Training samples'), findsOneWidget);
      expect(find.text('50,000'), findsWidgets);
      expect(find.text('CrossEntropyLoss(label_smoothing=0.1)'), findsOneWidget);

      final diagram = find.bySemanticsLabel(RegExp(r'^Network diagram, .*Input, 3 by 32 by 32;'));
      await tester.scrollUntilVisible(diagram, 200, scrollable: visibleList());
      expect(diagram, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('holding a layer explains it', (tester) async {
      await openApp(tester, '/runs/resnet50-cifar');
      final block = find.text('layer1.0');
      await tester.scrollUntilVisible(block, 200, scrollable: visibleList());
      await tester.pumpAndSettle(); // Let the scroll come to rest.
      await tester.longPress(block);
      await tester.pumpAndSettle();
      expect(find.textContaining('layer1.0 (Bottleneck)'), findsOneWidget);
    });

    testWidgets('fits a phone without overflowing', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      for (final id in ['resnet50-cifar', 'gpt-tiny', 'unet-seg', 'vit-small']) {
        await openApp(tester, '/runs/$id');
        await tester.scrollUntilVisible(
          find.bySemanticsLabel(RegExp('^Network diagram')),
          200,
          scrollable: visibleList(),
        );
        expect(tester.takeException(), isNull, reason: id);
      }
    });

    testWidgets('without a flow, says how to get one', (tester) async {
      final run = withoutFlow(buildMockRuns(DateTime(2026, 11, 12)).first.run);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: OverviewTab(run: run)),
          ),
        ),
      );
      final hint = find.textContaining('appears once the model has run with run.watch(model)');
      await tester.scrollUntilVisible(hint, 200);
      expect(hint, findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Network diagram')), findsNothing);
    });
  });
}
