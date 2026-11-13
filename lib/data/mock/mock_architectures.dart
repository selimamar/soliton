import '../../models/layer_info.dart';

// Architecture trees for the demo runs. Parameter counts are close to the
// real models, so the numbers on screen look plausible.

LayerInfo resnet50Cifar() => LayerInfo(
  name: 'resnet50',
  type: 'ResNet',
  children: [
    const LayerInfo(name: 'conv1', type: 'Conv2d', ownParameters: 9408),
    const LayerInfo(name: 'bn1', type: 'BatchNorm2d', ownParameters: 128),
    _stage('layer1', blocks: 3, parameters: 215808),
    _stage('layer2', blocks: 4, parameters: 1219584),
    _stage('layer3', blocks: 6, parameters: 7098368),
    _stage('layer4', blocks: 3, parameters: 14964736),
    const LayerInfo(name: 'fc', type: 'Linear', ownParameters: 20490),
  ],
);

LayerInfo gptTiny() => LayerInfo(
  name: 'gpt',
  type: 'GPT',
  children: [
    const LayerInfo(name: 'wte', type: 'Embedding', ownParameters: 50257 * 384),
    const LayerInfo(name: 'wpe', type: 'Embedding', ownParameters: 1024 * 384),
    LayerInfo(
      name: 'blocks',
      type: 'ModuleList',
      children: [for (var i = 0; i < 6; i++) _transformerBlock('blocks.$i', dim: 384)],
    ),
    const LayerInfo(name: 'ln_f', type: 'LayerNorm', ownParameters: 768),
    // Weights are tied to `wte`, so no extra parameters.
    const LayerInfo(name: 'lm_head', type: 'Linear', ownParameters: 0),
  ],
);

LayerInfo unet() => const LayerInfo(
  name: 'unet',
  type: 'UNet',
  children: [
    LayerInfo(name: 'inc', type: 'DoubleConv', ownParameters: 38976),
    LayerInfo(name: 'down1', type: 'Down', ownParameters: 221952),
    LayerInfo(name: 'down2', type: 'Down', ownParameters: 886272),
    LayerInfo(name: 'down3', type: 'Down', ownParameters: 3542016),
    LayerInfo(name: 'down4', type: 'Down', ownParameters: 14161920),
    LayerInfo(name: 'up1', type: 'Up', ownParameters: 9177600),
    LayerInfo(name: 'up2', type: 'Up', ownParameters: 2295040),
    LayerInfo(name: 'up3', type: 'Up', ownParameters: 574208),
    LayerInfo(name: 'up4', type: 'Up', ownParameters: 143808),
    LayerInfo(name: 'outc', type: 'Conv2d', ownParameters: 130),
  ],
);

LayerInfo vitSmall() => LayerInfo(
  name: 'vit',
  type: 'VisionTransformer',
  children: [
    const LayerInfo(name: 'patch_embed', type: 'PatchEmbed', ownParameters: 295296),
    const LayerInfo(name: 'pos_embed', type: 'Parameter', ownParameters: 75648),
    LayerInfo(
      name: 'blocks',
      type: 'ModuleList',
      children: [for (var i = 0; i < 12; i++) _transformerBlock('blocks.$i', dim: 384)],
    ),
    const LayerInfo(name: 'norm', type: 'LayerNorm', ownParameters: 768),
    const LayerInfo(name: 'head', type: 'Linear', ownParameters: 3850),
  ],
);

/// A 2D Fourier neural operator (Li et al.): 4 spectral blocks of width 32,
/// keeping 12 × 12 Fourier modes, on (vorticity, x, y) inputs.
LayerInfo fno2d() => LayerInfo(
  name: 'fno',
  type: 'FNO2d',
  children: [
    const LayerInfo(name: 'lifting', type: 'Linear', ownParameters: 3 * 32 + 32),
    LayerInfo(
      name: 'blocks',
      type: 'ModuleList',
      children: [
        for (var i = 0; i < 4; i++)
          LayerInfo(
            name: 'blocks.$i',
            type: 'FNOBlock',
            children: [
              // Two corners of complex weights: in × out × 12 × 12 × 2 × 2 reals.
              LayerInfo(name: 'blocks.$i.spectral', type: 'SpectralConv2d', ownParameters: 589824),
              LayerInfo(name: 'blocks.$i.w', type: 'Conv2d', ownParameters: 32 * 32 + 32),
            ],
          ),
      ],
    ),
    const LayerInfo(name: 'projection.0', type: 'Linear', ownParameters: 32 * 128 + 128),
    const LayerInfo(name: 'projection.1', type: 'Linear', ownParameters: 128 + 1),
  ],
);

/// A 3D Fourier neural operator: 4 spectral blocks of width 20, keeping
/// 8 × 8 × 8 Fourier modes, on (vorticity, x, y, z) inputs.
LayerInfo fno3d() => LayerInfo(
  name: 'fno',
  type: 'FNO3d',
  children: [
    const LayerInfo(name: 'lifting', type: 'Linear', ownParameters: 4 * 20 + 20),
    LayerInfo(
      name: 'blocks',
      type: 'ModuleList',
      children: [
        for (var i = 0; i < 4; i++)
          LayerInfo(
            name: 'blocks.$i',
            type: 'FNOBlock',
            children: [
              // Four corners of complex weights: in × out × 8³ × 4 × 2 reals.
              LayerInfo(name: 'blocks.$i.spectral', type: 'SpectralConv3d', ownParameters: 1638400),
              LayerInfo(name: 'blocks.$i.w', type: 'Conv3d', ownParameters: 20 * 20 + 20),
            ],
          ),
      ],
    ),
    const LayerInfo(name: 'projection.0', type: 'Linear', ownParameters: 20 * 128 + 128),
    const LayerInfo(name: 'projection.1', type: 'Linear', ownParameters: 128 + 1),
  ],
);

/// A ResNet stage of [blocks] bottleneck blocks sharing [parameters].
LayerInfo _stage(String name, {required int blocks, required int parameters}) => LayerInfo(
  name: name,
  type: 'Sequential',
  children: [
    for (var i = 0; i < blocks; i++)
      LayerInfo(name: '$name.$i', type: 'Bottleneck', ownParameters: parameters ~/ blocks),
  ],
);

/// A standard pre-norm transformer block with a 4x MLP.
LayerInfo _transformerBlock(String name, {required int dim}) => LayerInfo(
  name: name,
  type: 'TransformerBlock',
  children: [
    LayerInfo(name: '$name.ln_1', type: 'LayerNorm', ownParameters: 2 * dim),
    LayerInfo(name: '$name.attn', type: 'Attention', ownParameters: 4 * dim * dim + 4 * dim),
    LayerInfo(name: '$name.ln_2', type: 'LayerNorm', ownParameters: 2 * dim),
    LayerInfo(name: '$name.mlp', type: 'MLP', ownParameters: 8 * dim * dim + 5 * dim),
  ],
);
