import 'model_helpers.dart';

/// The layers a model ran, in order, with the shape of each one's output.
///
/// The logger records this on the model's first forward pass after
/// `run.watch(model)`. It is drawn as the network diagram. The architecture
/// tree ([LayerInfo]) says how the model is built; this says what runs.
class ModelFlow {
  /// Pass an unmodifiable (e.g. `const`) [layers] list.
  const ModelFlow({this.input, required this.layers});

  /// Reads the `input` and `flow` fields of an architecture's JSON; null if
  /// the run has none (not watched yet, or logged by an older logger).
  static ModelFlow? fromArchitectureJson(Map<String, Object?> json) {
    final flow = json['flow'];
    if (flow is! List) return null;
    return ModelFlow(
      input: switch (json['input']) {
        final Map<String, Object?> input => FlowInput.fromJson(input),
        _ => null,
      },
      layers: List.unmodifiable([
        for (final layer in flow) FlowLayer.fromJson(layer as Map<String, Object?>),
      ]),
    );
  }

  /// What went into the model, if it was a tensor.
  final FlowInput? input;

  /// Every leaf module call, in order (a module called twice is listed twice).
  final List<FlowLayer> layers;

  /// The fields [fromArchitectureJson] reads.
  Map<String, Object?> toArchitectureJson() => {
    'input': input?.toJson(),
    'flow': [for (final layer in layers) layer.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is ModelFlow && other.input == input && deepListEquals(other.layers, layers);

  @override
  int get hashCode => Object.hash(input, Object.hashAll(layers));
}

/// The model's input: its shape without the batch dimension.
class FlowInput {
  const FlowInput({required this.shape, this.width, this.tokens = false});

  factory FlowInput.fromJson(Map<String, Object?> json) => FlowInput(
    shape: _ints(json['shape']),
    width: (json['width'] as num?)?.toInt(),
    tokens: json['tokens'] == true,
  );

  /// E.g. `[3, 32, 32]` for CIFAR images, `[1024]` for a sequence of tokens.
  final List<int> shape;

  /// Features or channels the first layer takes; null for tokens.
  final int? width;

  /// True for integer inputs, e.g. token ids going into an embedding.
  final bool tokens;

  Map<String, Object?> toJson() => {'shape': shape, 'width': width, 'tokens': tokens};

  @override
  bool operator ==(Object other) =>
      other is FlowInput &&
      deepListEquals(other.shape, shape) &&
      other.width == width &&
      other.tokens == tokens;

  @override
  int get hashCode => Object.hash(Object.hashAll(shape), width, tokens);
}

/// What a layer does, as far as the diagram cares.
enum FlowKind {
  linear,
  conv,
  embedding,
  recurrent,
  attention,
  norm,
  activation,
  dropout,
  pool,
  reshape,
  other;

  static FlowKind parse(Object? name) =>
      FlowKind.values.where((kind) => kind.name == name).firstOrNull ?? FlowKind.other;
}

/// One call of one module.
class FlowLayer {
  const FlowLayer({
    required this.name,
    required this.type,
    required this.kind,
    required this.shape,
    this.width,
    this.parameters = 0,
  });

  factory FlowLayer.fromJson(Map<String, Object?> json) => FlowLayer(
    name: json['name']! as String,
    type: json['type']! as String,
    kind: FlowKind.parse(json['kind']),
    shape: _ints(json['shape']),
    width: (json['width'] as num?)?.toInt(),
    parameters: (json['parameters'] as num?)?.toInt() ?? 0,
  );

  /// Module name, e.g. `layer1.0.conv1`; matches the architecture tree.
  final String name;

  /// Module class, e.g. `Conv2d`.
  final String type;

  final FlowKind kind;

  /// Output shape without the batch dimension, e.g. `[64, 16, 16]`.
  final List<int> shape;

  /// Output channels (convolutions) or features (everything else).
  final int? width;

  /// Parameters of this module, including any sub-modules.
  final int parameters;

  /// Drawn as a column of the diagram, rather than noted on the one before.
  bool get isDrawn => switch (kind) {
    FlowKind.linear ||
    FlowKind.conv ||
    FlowKind.embedding ||
    FlowKind.recurrent ||
    FlowKind.attention => true,
    FlowKind.other => parameters > 0,
    _ => false,
  };

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'kind': kind.name,
    'shape': shape,
    'width': width,
    'parameters': parameters,
  };

  @override
  bool operator ==(Object other) =>
      other is FlowLayer &&
      other.name == name &&
      other.type == type &&
      other.kind == kind &&
      deepListEquals(other.shape, shape) &&
      other.width == width &&
      other.parameters == parameters;

  @override
  int get hashCode => Object.hash(name, type, kind, Object.hashAll(shape), width, parameters);
}

List<int> _ints(Object? json) =>
    List.unmodifiable([for (final n in (json as List?) ?? const []) (n as num).toInt()]);
