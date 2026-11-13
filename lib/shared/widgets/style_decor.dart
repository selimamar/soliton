import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import 'sparkline.dart';

// Small pieces of decoration that set the Lab and Ink styles apart. Each is
// a cheap painter or a few widgets; none repaints while the page scrolls.

/// A faint dot grid behind [child] in the Lab style, like graph paper on an
/// instrument screen. Other styles get [child] unchanged.
class StyleBackground extends StatelessWidget {
  const StyleBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (AppTheme.styleOf(context) != AppStyle.lab) return child;
    return CustomPaint(
      painter: _DotGridPainter(Theme.of(context).colorScheme.outlineVariant),
      // The list scrolls in its own layer, so the dots are painted once.
      child: RepaintBoundary(child: child),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  _DotGridPainter(this.color);

  final Color color;
  static const _step = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [
      for (var y = _step / 2; y < size.height; y += _step)
        for (var x = _step / 2; x < size.width; x += _step) Offset(x, y),
    ];
    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}

/// Two L-shaped marks on opposite corners of [child], like the corners of a
/// viewfinder (Lab run cards).
class CornerMarks extends StatelessWidget {
  const CornerMarks({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(foregroundPainter: _CornerMarksPainter(color), child: child);
}

class _CornerMarksPainter extends CustomPainter {
  _CornerMarksPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const arm = 8.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(1, arm)
        ..lineTo(1, 1)
        ..lineTo(arm, 1)
        ..moveTo(size.width - arm, size.height - 1)
        ..lineTo(size.width - 1, size.height - 1)
        ..lineTo(size.width - 1, size.height - arm),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CornerMarksPainter old) => old.color != color;
}

/// Progress as a row of ten blocks (Lab).
class BlockProgress extends StatelessWidget {
  const BlockProgress({super.key, required this.value, required this.label});

  /// 0 to 1.
  final double value;

  /// What screen readers announce, e.g. "Training progress".
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filled = (value * 10).round();
    return Semantics(
      label: label,
      value: '${(value * 100).toStringAsFixed(0)}%',
      child: Row(
        children: [
          for (var i = 0; i < 10; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: Container(
                height: 5,
                color: i < filled ? scheme.primary : scheme.outlineVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A dotted line that fills the space between a label and its value, as in
/// a table of contents.
class DottedLeader extends StatelessWidget {
  const DottedLeader({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(double.infinity, 12),
    painter: _DottedPainter(Theme.of(context).colorScheme.outline),
  );
}

class _DottedPainter extends CustomPainter {
  _DottedPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 4.0; x < size.width - 4; x += 4) {
      canvas.drawCircle(Offset(x, size.height - 2), 0.7, paint);
    }
  }

  @override
  bool shouldRepaint(_DottedPainter old) => old.color != color;
}

/// A loss curve drawn as a small figure: with axes and their range (Ink) or
/// over a grid (Lab), and the step range underneath.
class FigureChart extends StatelessWidget {
  const FigureChart({
    super.key,
    required this.values,
    required this.color,
    required this.lastStep,
    required this.semanticLabel,
    this.endDotColor,
  });

  final List<double> values;
  final Color color;
  final Color? endDotColor;

  /// The step of the last value, for the x axis.
  final int lastStep;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lab = AppTheme.styleOf(context) == AppStyle.lab;
    final small = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: AppText.tabular,
    );
    final finite = values.where((v) => v.isFinite);
    String fmt(double v) => v.toStringAsPrecision(2);
    final axis = BorderSide(color: scheme.onSurface.withValues(alpha: 0.7), width: 0.8);

    final chart = Container(
      decoration: lab
          ? null
          : BoxDecoration(
              border: Border(left: axis, bottom: axis),
            ),
      padding: lab ? null : const EdgeInsets.only(left: 4, bottom: 4),
      child: Sparkline(
        values: values,
        color: color,
        height: 64,
        strokeWidth: 1.6,
        endDotColor: endDotColor,
        grid: lab,
        semanticLabel: semanticLabel,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!lab && finite.isNotEmpty) ...[
              SizedBox(
                height: 68,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(fmt(finite.reduce((a, b) => a > b ? a : b)), style: small),
                    Text(fmt(finite.reduce((a, b) => a < b ? a : b)), style: small),
                  ],
                ),
              ),
              const SizedBox(width: 4),
            ],
            Expanded(child: chart),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            if (!lab) const SizedBox(width: 28),
            Text('0', style: small),
            const Spacer(),
            Text('${_steps(lastStep)} steps', style: small),
          ],
        ),
      ],
    );
  }

  static String _steps(int step) =>
      step >= 1000 ? '${(step / 1000).toStringAsFixed(step >= 10000 ? 0 : 1)}k' : '$step';
}

/// "3e-4" as a mathematician writes it, "3 × 10⁻⁴"; anything else as is.
String scientific(String value) {
  const superscripts = {
    '-': '⁻',
    '+': '',
    '0': '⁰',
    '1': '¹',
    '2': '²',
    '3': '³',
    '4': '⁴',
    '5': '⁵',
    '6': '⁶',
    '7': '⁷',
    '8': '⁸',
    '9': '⁹',
  };
  return value.replaceAllMapped(
    RegExp(r'\b(\d+(?:\.\d+)?)e([+-]?\d+)\b'),
    (m) => '${m[1]} × 10${m[2]!.split('').map((c) => superscripts[c] ?? c).join()}',
  );
}
