import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// A tiny line chart without axes, for previews in lists.
///
/// Drawn with a [CustomPainter] rather than a chart library: it is cheap
/// enough to render dozens of them while scrolling. Non-finite values (NaN,
/// ±∞) leave a gap in the line.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.height = 28,
    this.strokeWidth = 1.5,
    this.endDotColor,
    this.grid = false,
    this.semanticLabel,
  });

  final List<double> values;
  final Color color;
  final double height;
  final double strokeWidth;

  /// When set, a dot of this colour marks the latest value.
  final Color? endDotColor;

  /// Whether to draw a faint grid behind the line (the Lab style).
  final bool grid;

  /// What screen readers announce for this chart. Without one, the chart is
  /// treated as decoration.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final chart = SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          values,
          color,
          strokeWidth,
          endDotColor,
          grid ? Theme.of(context).colorScheme.outlineVariant : null,
        ),
      ),
    );
    if (semanticLabel == null) return chart;
    return Semantics(container: true, label: semanticLabel, image: true, child: chart);
  }
}

/// "rising", "falling" or "flat": the overall direction of [values], for
/// semantic labels. Ignores non-finite values.
String trendOf(List<double> values) {
  final finite = values.where((v) => v.isFinite).toList();
  if (finite.length < 2) return 'flat';
  final first = finite.first;
  final last = finite.last;
  final scale = finite.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
  if (scale == 0 || (last - first).abs() < scale * 0.02) return 'flat';
  return last > first ? 'rising' : 'falling';
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color, this.strokeWidth, this.endDotColor, this.gridColor);

  final List<double> values;
  final Color color;
  final double strokeWidth;
  final Color? endDotColor;
  final Color? gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (gridColor case final grid?) {
      final paint = Paint()
        ..color = grid
        ..strokeWidth = 1;
      for (var i = 1; i < 4; i++) {
        final y = size.height * i / 4;
        final x = size.width * i / 4;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
    }
    if (values.length < 2) return;

    double? minV;
    double? maxV;
    for (final v in values) {
      if (!v.isFinite) continue;
      if (minV == null || v < minV) minV = v;
      if (maxV == null || v > maxV) maxV = v;
    }
    if (minV == null || maxV == null) return;
    final low = minV;
    final range = maxV - low;

    // Leave room for the stroke (and the end dot) at the edges.
    final dotRadius = endDotColor == null ? 0.0 : strokeWidth + 1.5;
    final inset = dotRadius > strokeWidth ? dotRadius : strokeWidth;
    Offset pointAt(int i) {
      final x = i / (values.length - 1) * (size.width - dotRadius);
      final normalized = range == 0 ? 0.5 : (values[i] - low) / range;
      final y = inset + (1 - normalized) * (size.height - 2 * inset);
      return Offset(x, y);
    }

    final path = Path();
    Offset? last;
    var penDown = false;
    for (var i = 0; i < values.length; i++) {
      if (!values[i].isFinite) {
        penDown = false; // Gap.
        continue;
      }
      final p = pointAt(i);
      last = p;
      if (penDown) {
        path.lineTo(p.dx, p.dy);
      } else {
        path.moveTo(p.dx, p.dy);
        penDown = true;
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    if (endDotColor case final dot? when last != null) {
      canvas.drawCircle(last, dotRadius, Paint()..color = dot);
    }
  }

  // Compares contents, not identity: callers often build a fresh list with
  // the same values on every rebuild.
  @override
  bool shouldRepaint(_SparklinePainter old) =>
      !listEquals(old.values, values) ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.endDotColor != endDotColor ||
      old.gridColor != gridColor;
}
