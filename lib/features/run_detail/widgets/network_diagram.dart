import 'package:material_ui/material_ui.dart';

import '../../../models/layer_info.dart';
import '../../../models/model_flow.dart';
import '../network_layout.dart';

/// The model as the usual picture of a neural network: a column of units
/// per layer, left to right in the order the layers run, each column
/// connected to the next. Units grow with the layer's width (features or
/// channels) on a log scale; an ellipsis means there are more. Squares are
/// convolution channels, circles everything else.
class NetworkDiagram extends StatelessWidget {
  const NetworkDiagram({super.key, required this.flow, this.tree});

  final ModelFlow flow;

  /// For the names of grouped blocks.
  final LayerInfo? tree;

  static const _minSpacing = 42.0;
  static const _maxSpacing = 88.0;
  static const _unitGap = 13.0;
  static const _nodesHeight = 10 * _unitGap + 16;
  static const _labelHeight = 36.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        // A small figure: at most 10 layers or blocks, fewer on a phone.
        final maxColumns = (available / _minSpacing).floor().clamp(4, 11);
        final columns = diagramColumns(flow, tree: tree, maxColumns: maxColumns);
        if (columns.isEmpty) return const SizedBox.shrink();

        final spacing = (available / columns.length).clamp(_minSpacing, _maxSpacing);
        final width = spacing * columns.length;
        final labelStyle = theme.textTheme.labelSmall;
        final diagram = SizedBox(
          width: width,
          height: _nodesHeight + _labelHeight,
          child: Stack(
            children: [
              Positioned.fill(
                bottom: _labelHeight,
                child: CustomPaint(
                  painter: _NetworkPainter(
                    columns: columns,
                    spacing: spacing,
                    unitGap: _unitGap,
                    colors: _DiagramColors.of(theme.colorScheme),
                  ),
                ),
              ),
              for (final (i, column) in columns.indexed)
                Positioned(
                  left: i * spacing,
                  top: 0,
                  bottom: 0,
                  width: spacing,
                  child: Tooltip(
                    message: column.description,
                    child: Container(
                      color: Colors.transparent,
                      alignment: Alignment.bottomCenter,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: SizedBox(
                        height: _labelHeight,
                        child: Column(
                          children: [
                            Text(
                              column.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: labelStyle?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              column.detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: labelStyle?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );

        return Semantics(
          container: true,
          label:
              'Network diagram, in the order the layers run: '
              '${columns.map(_spoken).join('; ')}',
          child: ExcludeSemantics(
            child: width > available
                ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: diagram)
                : Center(child: diagram),
          ),
        );
      },
    );
  }

  static String _spoken(DiagramColumn column) {
    final detail = column.detail.replaceAll('×', ' by ').replaceAll(' · ', ', ');
    return detail.isEmpty ? column.title : '${column.title}, $detail';
  }
}

class _DiagramColors {
  const _DiagramColors({
    required this.input,
    required this.hidden,
    required this.output,
    required this.edge,
    required this.block,
    required this.blockOutline,
    required this.ellipsis,
  });

  factory _DiagramColors.of(ColorScheme scheme) => _DiagramColors(
    input: scheme.secondary,
    hidden: scheme.primary,
    output: scheme.tertiary,
    edge: scheme.outline.withValues(alpha: 0.35),
    block: scheme.surfaceContainerHighest,
    blockOutline: scheme.outlineVariant,
    ellipsis: scheme.onSurfaceVariant,
  );

  final Color input;
  final Color hidden;
  final Color output;
  final Color edge;
  final Color block;
  final Color blockOutline;
  final Color ellipsis;

  @override
  bool operator ==(Object other) =>
      other is _DiagramColors &&
      other.input == input &&
      other.hidden == hidden &&
      other.output == output &&
      other.edge == edge &&
      other.block == block &&
      other.blockOutline == blockOutline &&
      other.ellipsis == ellipsis;

  @override
  int get hashCode => Object.hash(input, hidden, output, edge, block, blockOutline, ellipsis);
}

class _NetworkPainter extends CustomPainter {
  _NetworkPainter({
    required this.columns,
    required this.spacing,
    required this.unitGap,
    required this.colors,
  });

  final List<DiagramColumn> columns;
  final double spacing;
  final double unitGap;
  final _DiagramColors colors;

  static const _radius = 4.5;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    // Unit positions per column; null marks the ellipsis slot.
    final positions = [
      for (final (i, column) in columns.indexed)
        _positions(column, Offset((i + 0.5) * spacing, centerY)),
    ];

    for (final (i, column) in columns.indexed) {
      if (column.isBlock) _paintBlock(canvas, column, positions[i]);
    }

    final edge = Paint()
      ..color = colors.edge
      ..strokeWidth = 0.7;
    for (var i = 0; i + 1 < columns.length; i++) {
      for (final a in positions[i].nonNulls) {
        for (final b in positions[i + 1].nonNulls) {
          canvas.drawLine(a, b, edge);
        }
      }
    }

    for (final (i, column) in columns.indexed) {
      final color = column.isInput
          ? colors.input
          : i == columns.length - 1
          ? colors.output
          : colors.hidden;
      final fill = Paint()..color = color;
      for (final position in positions[i]) {
        if (position == null) continue;
        if (column.shape == UnitShape.square) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCircle(center: position, radius: _radius),
              const Radius.circular(1.5),
            ),
            fill,
          );
        } else {
          canvas.drawCircle(position, _radius, fill);
        }
      }
      _paintEllipsis(canvas, positions[i]);
    }
  }

  List<Offset?> _positions(DiagramColumn column, Offset center) {
    final (:count, :more) = unitsShown(column.width);
    final gap = more ? count ~/ 2 : -1;
    return [
      for (var k = 0; k < count; k++)
        k == gap ? null : center.translate(0, (k - (count - 1) / 2) * unitGap),
    ];
  }

  void _paintBlock(Canvas canvas, DiagramColumn column, List<Offset?> positions) {
    final ys = [for (final p in positions) ?p?.dy];
    final x = positions.nonNulls.first.dx;
    final rect = Rect.fromLTRB(
      x - _radius - 6,
      ys.first - _radius - 6,
      x + _radius + 6,
      ys.last + _radius + 6,
    );
    final outline = Paint()
      ..color = colors.blockOutline
      ..style = PaintingStyle.stroke;
    // Repeated blocks look stacked.
    for (var copy = column.repeat > 1 ? 2 : 0; copy >= 1; copy--) {
      final behind = RRect.fromRectAndRadius(
        rect.translate(copy * 3.0, -copy * 3.0),
        const Radius.circular(8),
      );
      canvas
        ..drawRRect(behind, Paint()..color = colors.block)
        ..drawRRect(behind, outline);
    }
    final front = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas
      ..drawRRect(front, Paint()..color = colors.block)
      ..drawRRect(front, outline);
  }

  void _paintEllipsis(Canvas canvas, List<Offset?> positions) {
    final index = positions.indexOf(null);
    if (index < 0) return;
    final above = positions[index - 1]!;
    final dot = Paint()..color = colors.ellipsis;
    for (final dy in [-3.5, 0.0, 3.5]) {
      canvas.drawCircle(above.translate(0, unitGap + dy), 1.1, dot);
    }
  }

  @override
  bool shouldRepaint(_NetworkPainter old) =>
      old.spacing != spacing ||
      old.unitGap != unitGap ||
      old.colors != colors ||
      !_sameColumns(old.columns, columns);

  static bool _sameColumns(List<DiagramColumn> a, List<DiagramColumn> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
