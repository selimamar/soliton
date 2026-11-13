import 'dart:math' as math;

import '../../models/layer_info.dart';
import '../../models/model_flow.dart';
import '../../shared/formatters.dart';

/// How a column's units are drawn: neurons, or feature maps.
enum UnitShape { circle, square }

/// One column of the network diagram: the model's input, one layer, or a
/// block of layers shown together.
class DiagramColumn {
  const DiagramColumn({
    required this.title,
    required this.detail,
    required this.width,
    required this.shape,
    required this.description,
    this.repeat = 1,
    this.isBlock = false,
    this.isInput = false,
  });

  /// First label line, e.g. `Conv2d`, `layer1`, `blocks.0` or `Input`.
  final String title;

  /// Second label line, e.g. `64`, `×3 · 256` or `3×32×32`.
  final String detail;

  /// Features or channels the column stands for; null if unknown.
  final int? width;

  final UnitShape shape;

  /// The full story, for the tooltip.
  final String description;

  /// How many identical blocks in a row this column stands for.
  final int repeat;

  /// Several layers shown as one column.
  final bool isBlock;

  final bool isInput;

  @override
  bool operator ==(Object other) =>
      other is DiagramColumn &&
      other.title == title &&
      other.detail == detail &&
      other.width == width &&
      other.shape == shape &&
      other.description == description &&
      other.repeat == repeat &&
      other.isBlock == isBlock &&
      other.isInput == isInput;

  @override
  int get hashCode =>
      Object.hash(title, detail, width, shape, description, repeat, isBlock, isInput);

  @override
  String toString() => '$title $detail';
}

/// How many units a column of [width] draws, and whether it stands for more
/// than that (drawn with an ellipsis in the middle). Grows with the
/// logarithm of the width, so 10 and 1,000 look different but both fit.
({int count, bool more}) unitsShown(int? width) {
  if (width == null || width <= 0) return (count: 3, more: true);
  if (width <= 5) return (count: width, more: false);
  final count = math.min(10, 4 + (math.log(width / 5) / math.ln2).round());
  return (count: count, more: true);
}

/// The columns to draw for [flow]: the input, then each layer that has
/// weights (linear, convolution, embedding, recurrent, attention).
/// Normalisation, activations, dropout and pooling are mentioned on the
/// layer before them.
///
/// With more than [maxColumns] columns, layers are grouped by the module
/// that contains them (e.g. ResNet's `layer1`), as deep as still fits, and
/// identical blocks in a row are drawn once with a count (`×6`). [tree]
/// gives the blocks' types.
List<DiagramColumn> diagramColumns(ModelFlow flow, {LayerInfo? tree, int maxColumns = 11}) {
  final units = <_Unit>[];
  for (final layer in flow.layers) {
    if (layer.isDrawn) {
      units.add(_Unit(layer));
    } else if (units.isNotEmpty) {
      units.last.after.add(layer);
    }
  }
  if (units.isEmpty) return const [];

  final input = flow.input;
  final budget = math.max(1, maxColumns - (input != null ? 1 : 0));
  var groups = [
    for (final unit in units) _Group(unit.layer.name, [unit]),
  ];
  if (units.length > budget) {
    final deepest = units.map((u) => u.path.length).reduce(math.max);
    for (var depth = deepest - 1; depth >= 1; depth--) {
      groups = _collapseRepeats(_groupAt(units, depth));
      if (groups.length <= budget) break;
    }
  }

  final types = <String, String>{};
  if (tree != null) _collectTypes(tree, types);
  return [
    if (input != null) _inputColumn(input, firstIsConv: units.first.layer.kind == FlowKind.conv),
    for (final group in groups)
      group.isSingleLayer ? group.units.single.column() : group.column(types),
  ];
}

/// A drawn layer plus the parameter-free (or normalising) layers after it.
class _Unit {
  _Unit(this.layer);

  final FlowLayer layer;
  final after = <FlowLayer>[];

  List<String> get path => layer.name.split('.');

  /// The layers after this one that belong to module [key], or (if null)
  /// sit next to it in its own module: whatever runs after a block, or
  /// starts the next one, isn't part of it.
  Iterable<FlowLayer> afterWithin(String? key) {
    if (key != null) return after.where((l) => l.name == key || l.name.startsWith('$key.'));
    final parent = _parent(layer.name);
    return after.where((l) => _parent(l.name) == parent);
  }

  /// Shape after the layers that follow, e.g. after pooling (not after
  /// flattening, which only changes the bookkeeping).
  List<int> outputShape([String? within]) =>
      afterWithin(within).where((l) => l.kind != FlowKind.reshape).lastOrNull?.shape ?? layer.shape;

  int parameters([String? within]) =>
      afterWithin(within).fold(layer.parameters, (sum, l) => sum + l.parameters);

  /// Same for identical layers in different blocks.
  String signature(String within) =>
      '${layer.type}:${layer.width}:${afterWithin(within).map((l) => l.type).join(',')}';

  UnitShape get shape => layer.kind == FlowKind.conv ? UnitShape.square : UnitShape.circle;

  DiagramColumn column() {
    final then = _distinct(afterWithin(null).map((l) => l.type));
    return DiagramColumn(
      title: layer.type,
      detail: _formatWidth(layer.width),
      width: layer.width,
      shape: shape,
      description: [
        '${layer.name} (${layer.type})',
        'Output ${_formatShape(outputShape())}',
        '${formatInt(parameters())} parameters',
        if (then.isNotEmpty) 'Then ${then.join(', ')}',
      ].join('\n'),
    );
  }
}

/// Consecutive layers inside one module, e.g. `layer1.0`; [repeat] blocks
/// in a row when identical blocks were collapsed.
class _Group {
  _Group(this.key, this.units);

  /// Module name, e.g. `layer1.0`.
  final String key;

  /// The layers of one block (the first one, when [repeat] > 1).
  final List<_Unit> units;

  int repeat = 1;

  /// Name of the last collapsed block, e.g. `layer1.2`.
  String? lastKey;

  bool get isSingleLayer => units.length == 1 && repeat == 1;

  /// Equal for identical blocks: same layers, same widths.
  String get signature => units.map((u) => u.signature(key)).join('|');

  DiagramColumn column(Map<String, String> types) {
    final last = units.last;
    final type = types[key];
    final parameters = units.fold(0, (sum, u) => sum + u.parameters(key)) * repeat;
    final name = lastKey == null ? key : '$key–${lastKey!.split('.').last}';
    return DiagramColumn(
      title: _shortName(key),
      detail: [if (repeat > 1) '×$repeat', _formatWidth(last.layer.width)].join(' · '),
      width: last.layer.width,
      shape: last.shape,
      repeat: repeat,
      isBlock: true,
      description: [
        type == null ? name : '$name ($type)',
        repeat > 1 ? '$repeat identical blocks of ${_layers(units.length)}' : _layers(units.length),
        'Output ${_formatShape(last.outputShape(key))}',
        '${formatInt(parameters)} parameters',
      ].join('\n'),
    );
  }
}

DiagramColumn _inputColumn(FlowInput input, {required bool firstIsConv}) {
  final shape = _formatShape(input.shape);
  return DiagramColumn(
    title: input.tokens ? 'Tokens' : 'Input',
    detail: shape,
    width: input.width,
    shape: firstIsConv || input.shape.length >= 3 ? UnitShape.square : UnitShape.circle,
    isInput: true,
    description: input.tokens ? 'Input: $shape tokens' : 'Input: $shape',
  );
}

List<_Group> _groupAt(List<_Unit> units, int depth) {
  final groups = <_Group>[];
  for (final unit in units) {
    final key = unit.path.take(depth).join('.');
    if (groups.isNotEmpty && groups.last.key == key) {
      groups.last.units.add(unit);
    } else {
      groups.add(_Group(key, [unit]));
    }
  }
  return groups;
}

/// Merges identical blocks in a row (`blocks.0`, `blocks.1`, ...).
List<_Group> _collapseRepeats(List<_Group> groups) {
  final merged = <_Group>[];
  for (final group in groups) {
    final previous = merged.lastOrNull;
    if (previous != null && _nextBlock(previous, group)) {
      previous.repeat++;
      previous.lastKey = group.key;
    } else {
      merged.add(group);
    }
  }
  return merged;
}

bool _nextBlock(_Group previous, _Group group) {
  final a = (previous.lastKey ?? previous.key).split('.');
  final b = group.key.split('.');
  if (a.length != b.length || a.length < 2) return false;
  final indexA = int.tryParse(a.last);
  final indexB = int.tryParse(b.last);
  if (indexA == null || indexB == null || indexB <= indexA) return false;
  for (var i = 0; i < a.length - 1; i++) {
    if (a[i] != b[i]) return false;
  }
  return previous.signature == group.signature;
}

/// `layer1`, or `h.3` rather than a bare `3`. Repeats show their first
/// block (the count is on the next line; the tooltip has the range): a
/// column is too narrow for `layer1.1–2`.
String _shortName(String key) {
  final path = key.split('.');
  final numbered = path.length >= 2 && int.tryParse(path.last) != null;
  return numbered ? path.sublist(path.length - 2).join('.') : path.last;
}

String _parent(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(0, dot);
}

void _collectTypes(LayerInfo node, Map<String, String> types) {
  types[node.name] = node.type;
  for (final child in node.children) {
    _collectTypes(child, types);
  }
}

List<String> _distinct(Iterable<String> items) {
  final seen = <String>[];
  for (final item in items) {
    if (seen.isEmpty || seen.last != item) seen.add(item);
  }
  return seen;
}

String _layers(int count) => count == 1 ? '1 layer' : '$count layers';

String _formatWidth(int? width) => width == null ? '' : formatInt(width);

String _formatShape(List<int> shape) => shape.isEmpty ? 'a single number' : shape.join('×');
