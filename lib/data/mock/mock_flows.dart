import '../../models/model_flow.dart';

// What the logger would record on the first forward pass of the demo
// models: every module call in order, with output shapes (no batch
// dimension) and parameter counts. Names follow the usual PyTorch
// implementations (torchvision's ResNet, nanoGPT, timm's ViT, a classic UNet).

/// ResNet-50 on 32×32 CIFAR images.
ModelFlow resnet50CifarFlow() {
  final f = _FlowBuilder()
    ..conv('conv1', 3, 64, kernel: 7, size: 16)
    ..norm('bn1', 'BatchNorm2d', [64, 16, 16])
    ..op('relu', 'ReLU', FlowKind.activation, [64, 16, 16])
    ..op('maxpool', 'MaxPool2d', FlowKind.pool, [64, 8, 8]);
  var channels = 64;
  var size = 8;
  for (final (stage, planes, blocks, stride) in [
    (1, 64, 3, 1),
    (2, 128, 4, 2),
    (3, 256, 6, 2),
    (4, 512, 3, 2),
  ]) {
    for (var b = 0; b < blocks; b++) {
      final name = 'layer$stage.$b';
      final out = size ~/ (b == 0 ? stride : 1);
      f
        ..conv('$name.conv1', channels, planes, kernel: 1, size: size)
        ..norm('$name.bn1', 'BatchNorm2d', [planes, size, size])
        ..op('$name.relu', 'ReLU', FlowKind.activation, [planes, size, size])
        ..conv('$name.conv2', planes, planes, kernel: 3, size: out)
        ..norm('$name.bn2', 'BatchNorm2d', [planes, out, out])
        ..op('$name.relu', 'ReLU', FlowKind.activation, [planes, out, out])
        ..conv('$name.conv3', planes, planes * 4, kernel: 1, size: out)
        ..norm('$name.bn3', 'BatchNorm2d', [planes * 4, out, out]);
      if (b == 0) {
        f
          ..conv('$name.downsample.0', channels, planes * 4, kernel: 1, size: out)
          ..norm('$name.downsample.1', 'BatchNorm2d', [planes * 4, out, out]);
      }
      f.op('$name.relu', 'ReLU', FlowKind.activation, [planes * 4, out, out]);
      channels = planes * 4;
      size = out;
    }
  }
  f
    ..op('avgpool', 'AdaptiveAvgPool2d', FlowKind.pool, [2048, 1, 1])
    ..linear('fc', 2048, 10, tokens: null);
  return f.build(const FlowInput(shape: [3, 32, 32], width: 3));
}

/// A small GPT: 6 blocks of width 384, 1,024-token context.
ModelFlow gptTinyFlow() {
  const dim = 384, context = 1024;
  final f = _FlowBuilder()
    ..embedding('wte', 50257, dim, context)
    ..embedding('wpe', context, dim, context)
    ..op('drop', 'Dropout', FlowKind.dropout, [context, dim]);
  for (var i = 0; i < 6; i++) {
    final name = 'blocks.$i';
    f
      ..norm('$name.ln_1', 'LayerNorm', [context, dim])
      ..linear('$name.attn.c_attn', dim, 3 * dim, tokens: context)
      ..linear('$name.attn.c_proj', dim, dim, tokens: context)
      ..op('$name.attn.resid_dropout', 'Dropout', FlowKind.dropout, [context, dim])
      ..norm('$name.ln_2', 'LayerNorm', [context, dim])
      ..linear('$name.mlp.c_fc', dim, 4 * dim, tokens: context)
      ..op('$name.mlp.gelu', 'GELU', FlowKind.activation, [context, 4 * dim])
      ..linear('$name.mlp.c_proj', 4 * dim, dim, tokens: context)
      ..op('$name.mlp.dropout', 'Dropout', FlowKind.dropout, [context, dim]);
  }
  f
    ..norm('ln_f', 'LayerNorm', [context, dim])
    ..linear('lm_head', dim, 50257, tokens: context, bias: false);
  return f.build(const FlowInput(shape: [context], tokens: true));
}

/// A UNet for 2-class segmentation of 256×256 images.
ModelFlow unetFlow() {
  final f = _FlowBuilder();
  void doubleConv(String name, int inChannels, int outChannels, int size) {
    f
      ..conv('$name.0', inChannels, outChannels, kernel: 3, size: size)
      ..norm('$name.1', 'BatchNorm2d', [outChannels, size, size])
      ..op('$name.2', 'ReLU', FlowKind.activation, [outChannels, size, size])
      ..conv('$name.3', outChannels, outChannels, kernel: 3, size: size)
      ..norm('$name.4', 'BatchNorm2d', [outChannels, size, size])
      ..op('$name.5', 'ReLU', FlowKind.activation, [outChannels, size, size]);
  }

  doubleConv('inc.double_conv', 3, 64, 256);
  var size = 256;
  for (final (i, inChannels, outChannels) in [
    (1, 64, 128),
    (2, 128, 256),
    (3, 256, 512),
    (4, 512, 1024),
  ]) {
    size ~/= 2;
    f.op('down$i.maxpool_conv.0', 'MaxPool2d', FlowKind.pool, [inChannels, size, size]);
    doubleConv('down$i.maxpool_conv.1.double_conv', inChannels, outChannels, size);
  }
  for (final (i, inChannels) in [(1, 1024), (2, 512), (3, 256), (4, 128)]) {
    size *= 2;
    f.conv(
      'up$i.up',
      inChannels,
      inChannels ~/ 2,
      kernel: 2,
      size: size,
      type: 'ConvTranspose2d',
      bias: true,
    );
    doubleConv('up$i.conv.double_conv', inChannels, inChannels ~/ 2, size);
  }
  f.conv('outc.conv', 64, 2, kernel: 1, size: 256, bias: true);
  return f.build(const FlowInput(shape: [3, 256, 256], width: 3));
}

/// ViT-S/16 on 224×224 images, 10 classes.
ModelFlow vitSmallFlow() {
  const dim = 384, tokens = 197;
  final f = _FlowBuilder()
    ..conv('patch_embed.proj', 3, dim, kernel: 16, size: 14, bias: true)
    ..op('pos_drop', 'Dropout', FlowKind.dropout, [tokens, dim]);
  for (var i = 0; i < 12; i++) {
    final name = 'blocks.$i';
    f
      ..norm('$name.norm1', 'LayerNorm', [tokens, dim])
      ..linear('$name.attn.qkv', dim, 3 * dim, tokens: tokens)
      ..linear('$name.attn.proj', dim, dim, tokens: tokens)
      ..norm('$name.norm2', 'LayerNorm', [tokens, dim])
      ..linear('$name.mlp.fc1', dim, 4 * dim, tokens: tokens)
      ..op('$name.mlp.act', 'GELU', FlowKind.activation, [tokens, 4 * dim])
      ..linear('$name.mlp.fc2', 4 * dim, dim, tokens: tokens);
  }
  f
    ..norm('norm', 'LayerNorm', [tokens, dim])
    ..linear('head', dim, 10, tokens: null);
  return f.build(const FlowInput(shape: [3, 224, 224], width: 3));
}

class _FlowBuilder {
  final _layers = <FlowLayer>[];

  ModelFlow build(FlowInput input) => ModelFlow(input: input, layers: List.unmodifiable(_layers));

  void conv(
    String name,
    int inChannels,
    int outChannels, {
    required int kernel,
    required int size,
    String type = 'Conv2d',
    bool bias = false,
  }) => _add(
    name,
    type,
    FlowKind.conv,
    [outChannels, size, size],
    width: outChannels,
    parameters: inChannels * outChannels * kernel * kernel + (bias ? outChannels : 0),
  );

  /// [tokens]: the sequence length, or null for one vector per sample.
  void linear(
    String name,
    int inFeatures,
    int outFeatures, {
    required int? tokens,
    bool bias = true,
  }) => _add(
    name,
    'Linear',
    FlowKind.linear,
    [?tokens, outFeatures],
    width: outFeatures,
    parameters: inFeatures * outFeatures + (bias ? outFeatures : 0),
  );

  void embedding(String name, int count, int dim, int tokens) => _add(
    name,
    'Embedding',
    FlowKind.embedding,
    [tokens, dim],
    width: dim,
    parameters: count * dim,
  );

  /// Normalisation: a scale and a shift per channel or feature.
  void norm(String name, String type, List<int> shape) {
    final channels = type == 'LayerNorm' ? shape.last : shape.first;
    _add(name, type, FlowKind.norm, shape, width: channels, parameters: 2 * channels);
  }

  void op(String name, String type, FlowKind kind, List<int> shape) =>
      _add(name, type, kind, shape, width: shape.length >= 3 ? shape.first : shape.last);

  void _add(
    String name,
    String type,
    FlowKind kind,
    List<int> shape, {
    required int width,
    int parameters = 0,
  }) {
    _layers.add(
      FlowLayer(
        name: name,
        type: type,
        kind: kind,
        shape: List.unmodifiable(shape),
        width: width,
        parameters: parameters,
      ),
    );
  }
}
