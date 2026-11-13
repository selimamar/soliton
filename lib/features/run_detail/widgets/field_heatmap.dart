import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../../shared/colormaps.dart';
import '../../../shared/formatters.dart';

/// A grid point of a 2D field: row 0 is the first row of the array, drawn
/// at the top (as `matplotlib.imshow` does by default).
typedef GridPoint = ({int row, int column});

/// A 2D field as a heatmap, one cell per grid point (no smoothing, so what
/// you see is what was logged). Values between [low] and [high] span
/// [colormap]; NaN cells are drawn in the surface colour. Tap or drag to
/// pick a point; the [selected] one gets a crosshair.
class FieldHeatmap extends StatelessWidget {
  const FieldHeatmap({
    super.key,
    required this.data,
    required this.rows,
    required this.columns,
    required this.low,
    required this.high,
    required this.colormap,
    required this.semanticLabel,
    this.selected,
    this.onSelect,
    this.aspectRatio,
    this.markedRow,
  });

  final Float32List data;
  final int rows;
  final int columns;
  final double low;
  final double high;
  final Colormap colormap;
  final String semanticLabel;
  final GridPoint? selected;
  final ValueChanged<GridPoint>? onSelect;

  /// Width over height; default: one square per grid point (a single row
  /// would be a hairline, so pass e.g. 8 for that).
  final double? aspectRatio;

  /// A row to mark with a line across the map (e.g. the current frame of a
  /// space-time map).
  final int? markedRow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: aspectRatio ?? columns / rows,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          void pick(Offset position) {
            final column = (position.dx / size.width * columns).floor().clamp(0, columns - 1);
            final row = (position.dy / size.height * rows).floor().clamp(0, rows - 1);
            onSelect?.call((row: row, column: column));
          }

          return Semantics(
            image: true,
            label: semanticLabel,
            child: GestureDetector(
              // Without [onSelect], leave taps to whatever holds the map
              // (e.g. a tappable tile).
              onTapDown: onSelect == null ? null : (details) => pick(details.localPosition),
              onPanDown: onSelect == null ? null : (details) => pick(details.localPosition),
              onPanUpdate: onSelect == null ? null : (details) => pick(details.localPosition),
              // The cells repaint only when the data changes, not when the
              // picked point moves.
              child: CustomPaint(
                size: size,
                foregroundPainter: _PointPainter(
                  rows: rows,
                  columns: columns,
                  selected: selected,
                  markedRow: markedRow,
                  color: scheme.onSurface,
                ),
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: size,
                    painter: _HeatmapPainter(
                      data: data,
                      rows: rows,
                      columns: columns,
                      low: low,
                      high: high,
                      colormap: colormap,
                      missing: scheme.surfaceContainerHighest,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.data,
    required this.rows,
    required this.columns,
    required this.low,
    required this.high,
    required this.colormap,
    required this.missing,
  });

  final Float32List data;
  final int rows, columns;
  final double low, high;
  final Colormap colormap;
  final Color missing;

  @override
  void paint(Canvas canvas, Size size) {
    // Two triangles per cell, all in one draw call: fast enough for
    // 512 × 512, and synchronous (unlike decoding an image).
    final cells = rows * columns;
    final positions = Float32List(cells * 12);
    final colors = Int32List(cells * 6);
    final dx = size.width / columns;
    final dy = size.height / rows;
    final span = high - low;
    final missingArgb = missing.toARGB32();
    for (var r = 0; r < rows; r++) {
      final top = r * dy, bottom = (r + 1) * dy;
      for (var c = 0; c < columns; c++) {
        final i = r * columns + c;
        final left = c * dx, right = (c + 1) * dx;
        final p = i * 12;
        positions
          ..[p] = left
          ..[p + 1] = top
          ..[p + 2] = right
          ..[p + 3] = top
          ..[p + 4] = right
          ..[p + 5] = bottom
          ..[p + 6] = left
          ..[p + 7] = top
          ..[p + 8] = right
          ..[p + 9] = bottom
          ..[p + 10] = left
          ..[p + 11] = bottom;
        final v = data[i];
        final argb = !v.isFinite ? missingArgb : colormap.argbAt(span > 0 ? (v - low) / span : 0.5);
        colors.fillRange(i * 6, i * 6 + 6, argb);
      }
    }
    final vertices = ui.Vertices.raw(VertexMode.triangles, positions, colors: colors);
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      !identical(old.data, data) ||
      old.rows != rows ||
      old.columns != columns ||
      old.low != low ||
      old.high != high ||
      old.colormap != colormap ||
      old.missing != missing;
}

/// A ring around the picked grid point.
class _PointPainter extends CustomPainter {
  _PointPainter({
    required this.rows,
    required this.columns,
    required this.selected,
    required this.color,
    this.markedRow,
  });

  final int rows, columns;
  final GridPoint? selected;
  final Color color;
  final int? markedRow;

  @override
  void paint(Canvas canvas, Size size) {
    final dx = size.width / columns;
    final dy = size.height / rows;
    if (markedRow case final row?) {
      final y = (row + 0.5) * dy;
      canvas
        ..drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..strokeWidth = 4,
        )
        ..drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = color
            ..strokeWidth = 1.5,
        );
    }
    if (selected case final point?) {
      final center = Offset((point.column + 0.5) * dx, (point.row + 0.5) * dy);
      final outline = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      final halo = Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4;
      final radius = (dx > dy ? dx : dy).clamp(5.0, 12.0);
      canvas
        ..drawCircle(center, radius, halo)
        ..drawCircle(center, radius, outline);
    }
  }

  @override
  bool shouldRepaint(_PointPainter old) =>
      old.selected != selected ||
      old.markedRow != markedRow ||
      old.color != color ||
      old.rows != rows ||
      old.columns != columns;
}

/// A horizontal colour bar with the values at both ends (and zero, for a
/// scale centred on it).
class ColorBar extends StatelessWidget {
  const ColorBar({super.key, required this.colormap, required this.low, required this.high});

  final Colormap colormap;
  final double low;
  final double high;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final centred = low < 0 && high > 0 && (low + high).abs() < 1e-9 * (high - low);
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(colors: colormap.anchors),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(formatMetric(low), style: style),
              const Spacer(),
              if (centred) Text('0', style: style),
              if (centred) const Spacer(),
              Text(formatMetric(high), style: style),
            ],
          ),
        ],
      ),
    );
  }
}
