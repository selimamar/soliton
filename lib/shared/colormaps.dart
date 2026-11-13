import 'package:material_ui/material_ui.dart';

/// A colour scale for heatmaps: [at] maps 0..1 to a colour, through a
/// 257-entry table interpolated between a few anchor colours (an odd
/// number of entries, so 0.5 is exactly the middle anchor: white for zero
/// error on the diverging map).
class Colormap {
  Colormap._(this.name, List<Color> anchors)
    : anchors = List.unmodifiable(anchors),
      _table = _build(anchors);

  /// Perceptually uniform and readable in grey, for field values
  /// (matplotlib's viridis, sampled at 9 points).
  static final viridis = Colormap._('viridis', const [
    Color(0xFF440154),
    Color(0xFF472D7B),
    Color(0xFF3B528B),
    Color(0xFF2C728E),
    Color(0xFF21918C),
    Color(0xFF28AE80),
    Color(0xFF5EC962),
    Color(0xFFADDC30),
    Color(0xFFFDE725),
  ]);

  /// Blue below zero, white at zero, red above: for signed errors, on a
  /// scale centred on zero (ColorBrewer's RdBu, reversed).
  static final diverging = Colormap._('diverging', const [
    Color(0xFF2166AC),
    Color(0xFF4393C3),
    Color(0xFF92C5DE),
    Color(0xFFD1E5F0),
    Color(0xFFF7F7F7),
    Color(0xFFFDDBC7),
    Color(0xFFF4A582),
    Color(0xFFD6604D),
    Color(0xFFB2182B),
  ]);

  final String name;
  final List<Color> anchors;
  final List<int> _table;

  /// The colour for [t] in 0..1 (clamped), as 0xAARRGGBB.
  int argbAt(double t) => _table[(t.clamp(0.0, 1.0) * _last).round()];

  static const _last = 256;

  Color at(double t) => Color(argbAt(t));

  static List<int> _build(List<Color> anchors) => List.unmodifiable([
    for (var i = 0; i <= _last; i++)
      () {
        final x = i / _last * (anchors.length - 1);
        final low = x.floor().clamp(0, anchors.length - 2);
        return Color.lerp(anchors[low], anchors[low + 1], x - low)!.toARGB32();
      }(),
  ]);
}
