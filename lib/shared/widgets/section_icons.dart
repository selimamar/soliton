import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Line-drawn icons for the Runs and Compute sections, which the Material
/// set has no match for. They size and colour themselves like an [Icon]
/// (from [size], or else the surrounding [IconTheme]); [bold] draws a
/// heavier line, for the selected tab.
class SectionIcon extends StatelessWidget {
  const SectionIcon._(this._shape, {super.key, this.size, this.bold = false});

  /// A training curve over a baseline: Runs.
  const SectionIcon.runs({Key? key, double? size, bool bold = false})
    : this._(_Shape.runs, key: key, size: size, bold: bold);

  /// A wavelet: Compute (simulations).
  const SectionIcon.compute({Key? key, double? size, bool bold = false})
    : this._(_Shape.compute, key: key, size: size, bold: bold);

  final _Shape _shape;
  final double? size;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 24;
    final color = (theme.color ?? const Color(0xFF000000)).withValues(
      alpha: (theme.color?.a ?? 1) * (theme.opacity ?? 1),
    );
    return Semantics(
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: side,
        child: CustomPaint(painter: _SectionIconPainter(_shape, color, bold)),
      ),
    );
  }
}

enum _Shape { runs, compute }

class _SectionIconPainter extends CustomPainter {
  _SectionIconPainter(this.shape, this.color, this.bold);

  final _Shape shape;
  final Color color;
  final bool bold;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 24-unit grid, like Material icons.
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = bold ? 2.5 : 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    switch (shape) {
      case _Shape.runs:
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 15)
            ..lineTo(8, 9)
            ..lineTo(12, 12)
            ..lineTo(16, 6.5)
            ..lineTo(20.5, 10.5),
          paint,
        );
        canvas.drawLine(const Offset(3.5, 19.5), const Offset(20.5, 19.5), paint);
      case _Shape.compute:
        // A Morlet-like wavelet, 2 to 22 across: a cosine under a Gaussian
        // envelope, so it peaks in the middle and dies out to flat ends.
        final path = Path();
        const steps = 64;
        for (var i = 0; i <= steps; i++) {
          final x = -1 + 2 * i / steps;
          final y = math.exp(-x * x / (2 * 0.4 * 0.4)) * math.cos(2 * math.pi * x);
          final point = Offset(12 + 10 * x, 13 - 7.5 * y);
          i == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SectionIconPainter old) =>
      old.shape != shape || old.color != color || old.bold != bold;
}
