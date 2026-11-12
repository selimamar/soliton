import 'model_helpers.dart';

/// One node in a model's architecture tree.
///
/// A node is either a leaf (e.g. a single `Conv2d`) or a group that contains
/// other nodes (e.g. a ResNet stage made of several bottleneck blocks).
class LayerInfo {
  /// Pass an unmodifiable (e.g. `const`) [children] list.
  const LayerInfo({
    required this.name,
    required this.type,
    this.ownParameters = 0,
    this.children = const [],
  });

  factory LayerInfo.fromJson(Map<String, Object?> json) => LayerInfo(
    name: json['name']! as String,
    type: json['type']! as String,
    ownParameters: (json['ownParameters'] as num?)?.toInt() ?? 0,
    children: List.unmodifiable([
      for (final c in (json['children'] as List?) ?? const [])
        LayerInfo.fromJson(c as Map<String, Object?>),
    ]),
  );

  /// Module name, e.g. `layer1` or `blocks.3.attn`.
  final String name;

  /// Module class, e.g. `Conv2d`, `Linear`, `TransformerBlock`.
  final String type;

  /// Parameters held directly by this node (not by its children).
  final int ownParameters;

  final List<LayerInfo> children;

  bool get isLeaf => children.isEmpty;

  /// Parameters of this node plus all of its descendants.
  int get totalParameters => ownParameters + children.fold(0, (sum, c) => sum + c.totalParameters);

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'ownParameters': ownParameters,
    'children': [for (final c in children) c.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is LayerInfo &&
      other.name == name &&
      other.type == type &&
      other.ownParameters == ownParameters &&
      deepListEquals(other.children, children);

  @override
  int get hashCode => Object.hash(name, type, ownParameters, Object.hashAll(children));
}
