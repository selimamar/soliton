import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/semantics.dart' show SemanticsProperties;
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../models/run.dart';
import '../../shared/formatters.dart';
import 'farm_palette.dart';
import 'farm_world.dart';

// The farm is drawn in two layers: the scene (grass, coop, nest, pond,
// trees), painted once per size and style, and the creatures (ducks, eggs,
// shell shards, labels), repainted every frame. Shapes are drawn in a duck's
// own coordinates, feet at the origin and facing right, about 50 units tall.

/// How a duck or an egg is labelled in the figure: (a), (b)… in Ink, 01,
/// 02… in Lab, nothing in Paper.
String? farmLabel(AppStyle style, int index) => switch (style) {
  AppStyle.paper => null,
  AppStyle.ink => index < 26 ? '(${String.fromCharCode(0x61 + index)})' : '(${index + 1})',
  AppStyle.lab => (index + 1).toString().padLeft(2, '0'),
};

/// What a screen reader says for [run] on the farm.
String farmSemanticsLabel(Run run) {
  final kind = switch (run.status) {
    RunStatus.queued => 'egg not yet laid, queued',
    RunStatus.finished => 'duck',
    RunStatus.live => 'egg, ${(run.progress * 100).round()}% trained',
    RunStatus.crashed => 'cracked egg, crashed',
  };
  final params = run.parameterCount > 0 ? ', ${formatCount(run.parameterCount)} parameters' : '';
  return '${run.name}, $kind$params';
}

/// Paints the farm's ground, buildings and pond: everything that doesn't
/// move. Wrap it in a [RepaintBoundary]: it only repaints when the size or
/// style changes.
class FarmScenePainter extends CustomPainter {
  FarmScenePainter({required this.layout, required this.palette, required this.labelStyle});

  final FarmLayout layout;
  final FarmPalette palette;

  /// For Lab's zone labels (COOP, INCUBATOR).
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final l = layout;
    final fill = Paint();
    canvas.drawRect(Offset.zero & size, fill..color = p.ground);
    switch (p.style) {
      case AppStyle.paper:
        _paperScene(canvas, size, p, l);
      case AppStyle.ink:
        _inkScene(canvas, size, p, l);
      case AppStyle.lab:
        _labScene(canvas, size, p, l);
    }
  }

  /// The dirt path from the nest down to the bottom edge, as a centre line.
  static Path _pathLine(FarmLayout l, Size size) => Path()
    ..moveTo(l.nest.center.dx, l.nest.bottom - 4)
    ..cubicTo(
      l.nest.center.dx - 40,
      l.nest.bottom + size.height * 0.3,
      size.width * 0.55,
      size.height * 0.6,
      size.width * 0.45,
      size.height + 10,
    );

  static Iterable<Offset> _scatter(FarmLayout l, int seed, double perArea) sync* {
    final random = math.Random(seed);
    final p = l.pasture;
    final count = (p.width * p.height * perArea).round().clamp(8, 160);
    for (var i = 0; i < count; i++) {
      yield Offset(p.left + random.nextDouble() * p.width, p.top + random.nextDouble() * p.height);
    }
  }

  void _paperScene(Canvas canvas, Size size, FarmPalette p, FarmLayout l) {
    final fill = Paint();
    for (final dot in _scatter(l, 3, 1 / 2600)) {
      canvas.drawCircle(dot, 1.8, fill..color = p.groundMark);
    }
    canvas.drawPath(
      _pathLine(l, size),
      Paint()
        ..color = p.path
        ..style = PaintingStyle.stroke
        ..strokeWidth = 40,
    );
    // The coop's roof from above, its shady half darker, and its door.
    final coop = RRect.fromRectAndRadius(l.coop, const Radius.circular(4));
    canvas.drawRRect(coop, fill..color = p.roof);
    canvas
      ..save()
      ..clipRRect(coop)
      ..drawRect(
        Rect.fromLTRB(l.coop.left, l.coop.top, l.coop.center.dx, l.coop.bottom),
        fill..color = p.roofShade,
      )
      ..restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(l.coop.center.dx, l.coop.bottom), width: 36, height: 8),
        const Radius.circular(2),
      ),
      fill..color = p.dark ? const Color(0xFF5A3A2A) : const Color(0xFF7A4A35),
    );
    _nest(canvas, p, l, fill, outline: null);
    final pond = _blob(l.pond);
    canvas.drawPath(pond, fill..color = p.water);
    canvas.drawPath(
      _blob(l.pond.deflate(l.pond.shortestSide * 0.08).shift(const Offset(4, 3))),
      fill..color = p.waterLight,
    );
    _waterMarks(canvas, l, p.waterMark, 1.5);
    for (final (centre, r) in l.trees) {
      canvas
        ..drawCircle(centre, r, fill..color = p.tree)
        ..drawCircle(centre.translate(-r * 0.22, -r * 0.27), r * 0.66, fill..color = p.treeLight);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius((Offset.zero & size).deflate(6), const Radius.circular(4)),
      Paint()
        ..color = p.border
        ..style = PaintingStyle.stroke,
    );
  }

  void _inkScene(Canvas canvas, Size size, FarmPalette p, FarmLayout l) {
    final fill = Paint();
    final line = Paint()
      ..color = p.line!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      _pathLine(l, size),
      Paint()
        ..color = p.path
        ..style = PaintingStyle.stroke
        ..strokeWidth = 40,
    );
    // Sparse stipple for the grass, in small clusters.
    for (final dot in _scatter(l, 4, 1 / 8000)) {
      for (final o in const [Offset.zero, Offset(3, 1.5), Offset(1.2, 3.2)]) {
        canvas.drawCircle(dot + o, 0.9, fill..color = p.groundMark);
      }
    }
    // The coop, its shady half lightly hatched.
    final coop = l.coop;
    canvas.drawRect(coop, fill..color = p.roof);
    final shade = Rect.fromLTRB(coop.left, coop.top, coop.center.dx, coop.bottom);
    canvas
      ..drawRect(shade, fill..color = p.roofShade)
      ..save()
      ..clipRect(shade);
    final hatch = Paint()
      ..color = p.groundMark
      ..strokeWidth = 0.7;
    for (var x = shade.left - shade.height; x < shade.right; x += 6) {
      canvas.drawLine(Offset(x, shade.bottom), Offset(x + shade.height, shade.top), hatch);
    }
    canvas
      ..restore()
      ..drawRect(coop, line)
      ..drawLine(Offset(coop.center.dx, coop.top), Offset(coop.center.dx, coop.bottom), line);
    final door = Rect.fromLTWH(coop.center.dx - 16, coop.bottom, 32, 6);
    canvas
      ..drawRect(door, fill..color = p.roof)
      ..drawRect(door, line..strokeWidth = 0.8);
    _nest(canvas, p, l, fill, outline: line..strokeWidth = 0.9);
    final pond = _blob(l.pond);
    canvas
      ..drawPath(pond, fill..color = p.water)
      ..drawPath(pond, line..strokeWidth = 1);
    _waterMarks(canvas, l, p.waterMark, 0.9);
    for (final (centre, r) in l.trees) {
      canvas
        ..drawCircle(centre, r, fill..color = p.tree)
        ..drawCircle(centre, r, line..strokeWidth = 1);
      final leaf = Paint()
        ..color = p.treeLight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      for (final o in [Offset(-r * 0.4, -r * 0.15), Offset(r * 0.05, r * 0.3)]) {
        final a = centre + o;
        canvas.drawPath(
          Path()
            ..moveTo(a.dx, a.dy)
            ..quadraticBezierTo(a.dx + r * 0.15, a.dy - r * 0.2, a.dx + r * 0.3, a.dy),
          leaf,
        );
      }
    }
    canvas.drawRect((Offset.zero & size).deflate(8), line..strokeWidth = 0.8);
  }

  void _labScene(Canvas canvas, Size size, FarmPalette p, FarmLayout l) {
    final fill = Paint();
    final dots = <Offset>[
      for (var y = 8.0; y < size.height; y += 16)
        for (var x = 8.0; x < size.width; x += 16) Offset(x, y),
    ];
    canvas.drawPoints(
      PointMode.points,
      dots,
      Paint()
        ..color = p.groundMark
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
    final outline = Paint()
      ..color = p.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    drawDashed(
      canvas,
      _pathLine(l, size),
      Paint()
        ..color = p.path
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round,
      dash: 0.1,
      gap: 5,
    );
    final coop = RRect.fromRectAndRadius(l.coop, const Radius.circular(2));
    canvas
      ..drawRRect(coop, fill..color = p.roof)
      ..drawRRect(coop, outline);
    _label(canvas, 'COOP', l.coop.topLeft.translate(8, 6), p.muted);
    final incubator = l.nest.inflate(6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(incubator, const Radius.circular(2)),
      fill..color = p.nest,
    );
    drawDashed(
      canvas,
      Path()..addRRect(RRect.fromRectAndRadius(incubator, const Radius.circular(2))),
      Paint()
        ..color = p.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
      dash: 4,
      gap: 3,
    );
    _label(canvas, 'INCUBATOR', incubator.bottomLeft.translate(0, 4), p.accent);
    // The pond as contour lines, like a depth chart.
    canvas.drawPath(_blob(l.pond), fill..color = p.water);
    for (final (i, k) in const [1.0, 0.78, 0.56, 0.34].indexed) {
      final r = Rect.fromCenter(
        center: l.pond.center,
        width: l.pond.width * k,
        height: l.pond.height * k,
      );
      canvas.drawPath(
        _blob(r),
        Paint()
          ..color = p.accent.withValues(alpha: 1 - i * 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8,
      );
    }
    for (final (centre, r) in l.trees) {
      canvas.drawCircle(centre, r * 0.75, outline);
      canvas
        ..drawLine(centre.translate(-4, 0), centre.translate(4, 0), outline..color = p.muted)
        ..drawLine(centre.translate(0, -4), centre.translate(0, 4), outline);
      outline.color = p.border;
    }
    for (var y = 40.0; y < size.height; y += 40) {
      canvas
        ..drawLine(Offset(0, y), Offset(6, y), outline)
        ..drawLine(Offset(size.width - 6, y), Offset(size.width, y), outline);
    }
    for (var x = 40.0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, size.height - 6), Offset(x, size.height), outline);
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: labelStyle.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
    painter.dispose();
  }

  void _nest(Canvas canvas, FarmPalette p, FarmLayout l, Paint fill, {required Paint? outline}) {
    canvas.drawOval(l.nest, fill..color = p.nest);
    if (outline != null) canvas.drawOval(l.nest, outline);
    canvas.drawOval(
      Rect.fromCenter(
        center: l.nest.center.translate(0, 2),
        width: l.nest.width * 0.78,
        height: l.nest.height * 0.62,
      ),
      fill..color = p.nestInner,
    );
    final straw = Paint()
      ..color = p.straw
      ..strokeWidth = outline == null ? 2 : 0.8
      ..strokeCap = StrokeCap.round;
    final n = l.nest;
    for (final (a, b) in [
      (Offset(n.left + 8, n.center.dy - 10), const Offset(10, 4)),
      (Offset(n.right - 22, n.center.dy - 12), const Offset(12, 5)),
      (Offset(n.left + 14, n.center.dy + 16), const Offset(12, -3)),
      (Offset(n.right - 28, n.center.dy + 16), const Offset(14, -2)),
    ]) {
      canvas.drawLine(a, a + b, straw);
    }
  }

  void _waterMarks(Canvas canvas, FarmLayout l, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    final c = l.pond.center, rx = l.pond.width / 2, ry = l.pond.height / 2;
    for (final (x, y, w) in const [
      (-0.65, -0.45, 0.32),
      (-0.05, -0.75, 0.26),
      (0.4, 0.1, 0.3),
      (-0.45, 0.6, 0.24),
    ]) {
      final a = c + Offset(x * rx, y * ry);
      canvas.drawLine(a, a.translate(w * rx, 0), paint);
    }
  }

  @override
  bool shouldRepaint(FarmScenePainter old) =>
      old.layout.size != layout.size ||
      old.palette.style != palette.style ||
      old.palette.dark != palette.dark ||
      old.palette.accent != palette.accent;
}

/// A smooth, slightly irregular closed curve around the ellipse in [r]:
/// the pond's edge.
Path _blob(Rect r) {
  const n = 10;
  final points = [
    for (var i = 0; i < n; i++)
      () {
        final a = i / n * 2 * math.pi;
        final k = 1 + 0.07 * math.sin(3 * a + 0.5) + 0.04 * math.cos(5 * a);
        return r.center + Offset(math.cos(a) * r.width / 2 * k, math.sin(a) * r.height / 2 * k);
      }(),
  ];
  // Catmull-Rom through the points, as cubic Béziers.
  final path = Path()..moveTo(points[0].dx, points[0].dy);
  for (var i = 0; i < n; i++) {
    final p0 = points[(i - 1 + n) % n], p1 = points[i];
    final p2 = points[(i + 1) % n], p3 = points[(i + 2) % n];
    final c1 = p1 + (p2 - p0) / 6, c2 = p2 - (p3 - p1) / 6;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path..close();
}

/// Strokes [path] as dashes of [dash] with [gap] between (a short [dash]
/// and round caps make dots).
void drawDashed(
  Canvas canvas,
  Path path,
  Paint paint, {
  required double dash,
  required double gap,
}) {
  for (final metric in path.computeMetrics()) {
    for (var d = 0.0; d < metric.length; d += dash + gap) {
      canvas.drawPath(metric.extractPath(d, math.min(d + dash, metric.length)), paint);
    }
  }
}

/// Parses the few SVG path commands the shapes below use (M, L, H, C, Q
/// and Z, absolute, plus relative l).
Path svgPath(String d) {
  final tokens = RegExp(r'[MLHCQZl]|-?\d*\.?\d+').allMatches(d).map((m) => m[0]!).toList();
  final path = Path();
  var i = 0, command = 'M';
  var x = 0.0, y = 0.0;
  double next() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    if (RegExp(r'^[A-Za-z]$').hasMatch(tokens[i])) command = tokens[i++];
    switch (command) {
      case 'M':
        path.moveTo(x = next(), y = next());
        command = 'L';
      case 'L':
        path.lineTo(x = next(), y = next());
      case 'l':
        path.lineTo(x += next(), y += next());
      case 'H':
        path.lineTo(x = next(), y);
      case 'C':
        final c = [next(), next(), next(), next()];
        path.cubicTo(c[0], c[1], c[2], c[3], x = next(), y = next());
      case 'Q':
        final c = [next(), next()];
        path.quadraticBezierTo(c[0], c[1], x = next(), y = next());
      case 'Z':
        path.close();
    }
  }
  return path;
}

abstract final class _Shapes {
  static final body = svgPath(
    'M-22 -33 C-19 -34 -15 -31 -12 -29 C-3 -31 9 -31 14 -24 C18 -18 14 -11 3 -11 H-8 '
    'C-17 -11 -20 -17 -19 -24 C-19 -27 -21 -30 -22 -33Z',
  );
  static final belly = svgPath(
    'M-18.6 -20.5 C-16.6 -14 -12 -11.5 -6 -11.5 H3 C9.5 -11.5 14.5 -14 14.6 -19 '
    'C10 -15 -6 -14 -18.6 -20.5Z',
  );
  static final wing = svgPath('M-12 -24 C-8 -29 3 -29 7 -23 C2 -19 -7 -19 -12 -24Z');
  static final neck = svgPath('M4 -27 C3 -32 3 -36 4 -39 L15 -39 C15 -35 14 -31 13 -25Z');
  static final neckSides = svgPath(
    'M4 -27.5 C3 -31 3 -34 3.4 -36.5 M13 -25.5 C14 -30 14.8 -34 15.2 -36',
  );
  static final shine = svgPath('M3 -46 C5 -50 11 -51 14 -49');
  static final bill = svgPath(
    'M16 -43 C22 -43.5 26.5 -41.5 26.5 -39.5 C26.5 -37.5 22 -36.5 16.5 -37Z',
  );
  static final mouth = svgPath('M17 -39.6 C20 -39.4 23 -39.4 26 -39.6');
  static final foot = svgPath('M-2 0 L7 0 Q8 -2.5 5 -3 L0 -3Z');
  static final shell = svgPath(
    'M0 -26 C7.5 -26 10.5 -14 10.5 -8 C10.5 -1 6 2 0 2 C-6 2 -10.5 -1 -10.5 -8 '
    'C-10.5 -14 -7.5 -26 0 -26Z',
  );
  static final shellShade = svgPath(
    'M10.5 -8 C10.5 -1 6 2 0 2 C-4 2 -7.5 0.5 -9.3 -2.5 C-4 -1 6 -2 10.4 -9.5Z',
  );
  static final crack = svgPath('M-10 -12 l4 3 l3 -4 l3 4 l4 -3 l5 2');
  static final hairlines = svgPath('M-7 -16 l3 3 l-1 3 l4 2 M7 -18 l-2 4 l2 3');
  static final shellTop = svgPath(
    'M0 -26 C7.5 -26 10.5 -14 10.5 -11 L6 -14 L2 -10 L-2 -14 L-6 -10 L-10.5 -12 '
    'C-10.5 -14 -7.5 -26 0 -26Z',
  );
  static final shellBottom = svgPath(
    'M-10.5 -12 L-6 -10 L-2 -14 L2 -10 L6 -14 L10.5 -11 C10.5 -1 6 2 0 2 '
    'C-6 2 -10.5 -1 -10.5 -12Z',
  );
}

/// Text painters for the labels, laid out once per string.
class FarmTextCache {
  final _painters = <(String, TextStyle), TextPainter>{};

  TextPainter get(String text, TextStyle style) => _painters[(text, style)] ??= TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();

  void clear() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
  }
}

/// Paints the ducks, eggs, flying shell and labels; repaints whenever the
/// [world] moves on. Also tells screen readers where each run is.
class FarmCreaturesPainter extends CustomPainter {
  FarmCreaturesPainter({
    required this.world,
    required this.palette,
    required this.labelStyle,
    required this.text,
    required this.onSelect,
  }) : _version = world.version,
       super(repaint: world);

  final FarmWorld world;
  final FarmPalette palette;

  /// Ink's (a), (b)… and Lab's 01, 02… and egg readouts.
  final TextStyle labelStyle;
  final FarmTextCache text;
  final ValueChanged<String> onSelect;
  final int _version;

  bool get _outlined => palette.line != null;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    for (final egg in world.eggs) {
      _egg(canvas, egg);
    }
    for (final shard in world.shards) {
      _shard(canvas, shard);
    }
    final standing = [...world.ducks]..sort((a, b) => a.position.dy.compareTo(b.position.dy));
    for (final duck in standing) {
      _duck(canvas, duck);
    }
    // Labels on top, so a duck walking by doesn't hide another's.
    if (p.style != AppStyle.paper) {
      for (final (i, duck) in world.ducks.indexed) {
        final selected = duck.id == world.selectedId;
        final style = labelStyle.copyWith(color: selected ? p.accent : null);
        final s = duck.scale * duck.pop;
        // Centred over the head, clear of the bill.
        _text(
          canvas,
          farmLabel(p.style, i)!,
          duck.position.translate(duck.facing * 9.5 * s, -53 * s),
          style,
          centred: true,
          above: true,
        );
      }
    }
    for (final egg in world.eggs) {
      if (p.style == AppStyle.lab) {
        _text(
          canvas,
          egg.crashed ? 'ERR' : '${(egg.progress * 100).round()}%',
          egg.position.translate(0, 8),
          labelStyle.copyWith(color: egg.crashed ? p.alert : p.accent),
          centred: true,
        );
      } else if (p.style == AppStyle.ink && egg.crashed) {
        _text(canvas, '†', egg.position.translate(11, -30), labelStyle.copyWith(color: p.alert));
      }
    }
    if (p.style == AppStyle.lab) _hud(canvas, size);
  }

  /// Paints [s] at [at]: its top-left corner, or the middle of its top
  /// ([centred]) or bottom ([centred] and [above]) edge.
  void _text(
    Canvas canvas,
    String s,
    Offset at,
    TextStyle style, {
    bool centred = false,
    bool above = false,
  }) {
    final painter = text.get(s, style);
    at = at.translate(centred ? -painter.width / 2 : 0, above ? -painter.height : 0);
    if (p.style == AppStyle.ink) {
      // A halo in the page colour keeps the label readable over anything.
      text
          .get(
            s,
            style.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3.5
                ..strokeJoin = StrokeJoin.round
                ..color = p.ground,
            ),
          )
          .paint(canvas, at);
    }
    painter.paint(canvas, at);
  }

  FarmPalette get p => palette;

  void _duck(Canvas canvas, FarmDuck duck) {
    final (colour, shade) = p.family(world.familyIndexOf(duck.run));
    final phase = (duck.id.hashCode % 628) / 100;
    final lift = duck.id == world.selectedId && p.style != AppStyle.lab ? 1.08 : 1.0;
    final bump = duck.pop < 1 ? 1 + math.sin(duck.pop * math.pi) * 0.25 : 1.0;
    final strokeWidth = p.style == AppStyle.lab ? 1.2 : 1.0;
    final line = _outlined
        ? (Paint()
            ..color = p.line!
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round)
        : null;
    final fill = Paint();

    canvas
      ..save()
      ..translate(duck.position.dx, duck.position.dy)
      ..scale(duck.scale * duck.pop * bump * lift);
    if (duck.swimming) {
      final rx = 20 + math.sin(world.time * 4.8 + phase) * 3;
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(0, -6), width: rx * 2, height: 12),
        Paint()
          ..color = p.ripple.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = p.style == AppStyle.paper ? 1.6 : 1,
      );
    } else {
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 32, height: 9),
        fill..color = p.shadow,
      );
    }
    canvas.scale(duck.facing, 1);

    if (!duck.swimming) {
      for (var i = 0; i < 2; i++) {
        final ph = duck.gait + i * math.pi, hx = -3.0 + i * 5;
        final fx = duck.walking ? hx + math.sin(ph) * 4 : hx;
        final fy = duck.walking ? -math.max(0.0, math.cos(ph)) * 3 : 0.0;
        final legColour = p.style == AppStyle.paper ? (i == 0 ? p.billShade : p.bill) : p.line!;
        canvas.drawLine(
          Offset(hx, -12),
          Offset(fx, fy - 1),
          Paint()
            ..color = legColour
            ..strokeWidth = p.style == AppStyle.paper ? 2.4 : 1.3
            ..strokeCap = StrokeCap.round,
        );
        final foot = _Shapes.foot.shift(Offset(fx - 1, fy));
        canvas.drawPath(foot, fill..color = p.style == AppStyle.paper ? legColour : p.bill);
        if (line != null) canvas.drawPath(foot, line..strokeWidth = 0.8);
      }
      line?.strokeWidth = strokeWidth;
    }

    // The body rocks as it waddles and floats lower when it swims.
    final rock = duck.walking && !duck.swimming ? math.sin(duck.gait) * 5 : 0.0;
    final bob = duck.swimming
        ? 8 + math.sin(world.time * 3.6 + phase) * 0.8
        : duck.walking
        ? -math.sin(duck.gait).abs() * 1.4
        : 0.0;
    canvas
      ..save()
      ..translate(0, bob)
      ..translate(0, -12)
      ..rotate(rock * math.pi / 180)
      ..translate(0, 12);
    canvas.drawPath(_Shapes.body, fill..color = colour);
    if (line != null) canvas.drawPath(_Shapes.body, line);
    if (p.style != AppStyle.lab) canvas.drawPath(_Shapes.belly, fill..color = shade);
    canvas.drawPath(_Shapes.wing, fill..color = shade);
    if (line != null) canvas.drawPath(_Shapes.wing, line..strokeWidth = strokeWidth * 0.8);
    line?.strokeWidth = strokeWidth;

    // The head: looks about, tucks down to preen, bobs as it walks.
    var turn = 0.0, hx = 0.0, hy = 0.0;
    if (duck.pose != null) {
      final k = math.sin(math.min(1, duck.poseTime) * math.pi);
      if (duck.pose == DuckPose.look) {
        turn = math.sin(duck.poseTime * 4.8) * 12 * k;
      } else {
        turn = -50 * k;
        hx = -6 * k;
        hy = 6 * k;
      }
    } else if (duck.walking && !duck.swimming) {
      hx = math.sin(duck.gait * 2) * 1.2;
    }
    canvas
      ..save()
      ..translate(hx, hy)
      ..translate(9, -28)
      ..rotate(turn * math.pi / 180)
      ..translate(-9, 28);
    canvas.drawCircle(const Offset(9.5, -41), 9.5, fill..color = colour);
    if (line != null) canvas.drawCircle(const Offset(9.5, -41), 9.5, line);
    canvas.drawPath(_Shapes.neck, fill..color = colour);
    if (line != null) canvas.drawPath(_Shapes.neckSides, line);
    if (p.style == AppStyle.paper) {
      canvas.drawPath(
        _Shapes.shine,
        Paint()
          ..color = Colors.white.withValues(alpha: p.dark ? 0.35 : 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawPath(_Shapes.bill, fill..color = p.bill);
    if (line != null) canvas.drawPath(_Shapes.bill, line..strokeWidth = strokeWidth * 0.9);
    canvas.drawPath(
      _Shapes.mouth,
      Paint()
        ..color = p.billShade
        ..style = PaintingStyle.stroke
        ..strokeWidth = p.style == AppStyle.ink ? 0.6 : 0.9,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: const Offset(12.5, -43.5),
        width: 3.8,
        height: duck.blinking ? 0.8 : 5,
      ),
      fill..color = p.eye,
    );
    if (!duck.blinking) {
      canvas.drawCircle(
        const Offset(13.2, -44.4),
        0.7,
        fill..color = p.dark && p.style != AppStyle.paper ? p.ground : Colors.white,
      );
    }
    canvas
      ..restore()
      ..restore()
      ..restore();
  }

  void _egg(Canvas canvas, FarmEgg egg) {
    final i = world.eggs.indexOf(egg);
    final fill = Paint();
    var wobble = 0.0;
    if (world.animate && !egg.crashed) {
      final amp = egg.progress > 0.92
          ? 4 + math.sin(world.time * 54) * 2
          : (math.sin(world.time * 1.8 + i * 2) > 0.6 ? 2.0 : 0.0);
      wobble = math.sin(world.time * 21 + i) * amp;
    }
    canvas
      ..save()
      ..translate(egg.position.dx, egg.position.dy)
      ..rotate(wobble * math.pi / 180)
      ..scale(egg.scale);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, 1), width: 20, height: 6),
      fill..color = p.shadow,
    );
    if (!egg.crashed) {
      const ring = Rect.fromLTRB(-15, -26, 15, 4);
      final ink = p.style == AppStyle.ink;
      canvas
        ..drawOval(
          ring,
          Paint()
            ..color = p.ringTrack
            ..style = PaintingStyle.stroke
            ..strokeWidth = ink ? 1.6 : 2.5,
        )
        ..drawArc(
          ring,
          -math.pi / 2,
          2 * math.pi * egg.progress,
          false,
          Paint()
            ..color = p.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = ink ? 1.8 : 2.5
            ..strokeCap = StrokeCap.round,
        );
    }
    canvas.drawPath(_Shapes.shell, fill..color = egg.crashed ? p.crashedShell : p.shell);
    if (p.style != AppStyle.lab) {
      canvas.drawPath(
        _Shapes.shellShade,
        fill..color = egg.crashed ? p.crashedShade : p.shellShade,
      );
    }
    if (p.style == AppStyle.paper && !egg.crashed) {
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(-4, -17), width: 4, height: 7),
        fill..color = Colors.white.withValues(alpha: p.dark ? 0.4 : 1),
      );
    }
    if (_outlined) {
      final outline = Paint()
        ..color = egg.crashed && p.style == AppStyle.lab ? p.alert : p.line!
        ..style = PaintingStyle.stroke
        ..strokeWidth = p.style == AppStyle.lab ? 1.1 : 1;
      if (egg.crashed && p.style == AppStyle.ink) {
        drawDashed(canvas, _Shapes.shell, outline, dash: 2.5, gap: 2);
      } else {
        canvas.drawPath(_Shapes.shell, outline);
      }
    }
    final crackColour = switch (p.style) {
      AppStyle.paper => p.dark ? p.muted : const Color(0xFF59616B),
      AppStyle.ink => p.line!,
      AppStyle.lab => egg.crashed ? p.alert : p.line!,
    };
    final crack = Paint()
      ..color = crackColour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeJoin = StrokeJoin.round;
    if (egg.crashed) {
      canvas.drawPath(_Shapes.crack, crack);
    } else if (egg.progress > 0.7) {
      canvas.drawPath(
        _Shapes.hairlines,
        crack
          ..strokeWidth = 0.9
          ..color = crackColour.withValues(alpha: egg.progress > 0.92 ? 1 : 0.45),
      );
    }
    canvas.restore();
  }

  void _shard(Canvas canvas, FarmShard shard) {
    final alpha = (1 - shard.age / FarmShard.life).clamp(0.0, 1.0);
    canvas
      ..save()
      ..translate(shard.position.dx, shard.position.dy)
      ..rotate(shard.age * shard.spin * 300 * math.pi / 180);
    final path = shard.top ? _Shapes.shellTop : _Shapes.shellBottom;
    canvas.drawPath(path, Paint()..color = p.shell.withValues(alpha: alpha));
    if (_outlined) {
      canvas.drawPath(
        path,
        Paint()
          ..color = p.line!.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke,
      );
    }
    canvas.restore();
  }

  /// Lab: the selected duck in a viewfinder, with crosshairs to the edges
  /// and a readout of where it is.
  void _hud(Canvas canvas, Size size) {
    final id = world.selectedId;
    final duck = world.ducks.where((d) => d.id == id).firstOrNull;
    if (duck == null) return;
    final c = duck.centre;
    final r = 30 * duck.scale;
    const arm = 8.0;
    final paint = Paint()
      ..color = p.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - r, c.dy - r + arm)
        ..lineTo(c.dx - r, c.dy - r)
        ..lineTo(c.dx - r + arm, c.dy - r)
        ..moveTo(c.dx + r - arm, c.dy - r)
        ..lineTo(c.dx + r, c.dy - r)
        ..lineTo(c.dx + r, c.dy - r + arm)
        ..moveTo(c.dx + r, c.dy + r - arm)
        ..lineTo(c.dx + r, c.dy + r)
        ..lineTo(c.dx + r - arm, c.dy + r)
        ..moveTo(c.dx - r + arm, c.dy + r)
        ..lineTo(c.dx - r, c.dy + r)
        ..lineTo(c.dx - r, c.dy + r - arm),
      paint,
    );
    drawDashed(
      canvas,
      Path()
        ..moveTo(0, c.dy)
        ..lineTo(c.dx - r - 4, c.dy)
        ..moveTo(c.dx + r + 4, c.dy)
        ..lineTo(size.width, c.dy)
        ..moveTo(c.dx, 0)
        ..lineTo(c.dx, c.dy - r - 4),
      paint..strokeWidth = 0.7,
      dash: 2,
      gap: 3,
    );
    final readout =
        'x${c.dx.round().toString().padLeft(3, '0')} '
        'y${duck.position.dy.round().toString().padLeft(3, '0')} '
        '${formatCount(duck.run.parameterCount)}';
    // Fresh each time: the numbers change every frame.
    final painter = TextPainter(
      text: TextSpan(
        text: readout,
        style: labelStyle.copyWith(color: const Color(0xFF2DD4BF)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final box = Rect.fromLTWH(10, 10, painter.width + 12, painter.height + 8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(2)),
      Paint()..color = const Color(0xFF0B0D0F),
    );
    painter
      ..paint(canvas, box.topLeft.translate(6, 4))
      ..dispose();
  }

  @override
  bool shouldRepaint(FarmCreaturesPainter old) =>
      old.world != world || old.palette.style != palette.style || old.palette.dark != palette.dark;

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (final duck in world.ducks)
          CustomPainterSemantics(
            key: ValueKey('duck ${duck.id}'),
            rect: Rect.fromCircle(center: duck.centre, radius: 24),
            properties: SemanticsProperties(
              label: farmSemanticsLabel(duck.run),
              button: true,
              selected: duck.id == world.selectedId,
              textDirection: TextDirection.ltr,
              onTap: () => onSelect(duck.id),
            ),
          ),
        for (final egg in world.eggs)
          CustomPainterSemantics(
            key: ValueKey('egg ${egg.id}'),
            rect: Rect.fromCircle(center: egg.centre, radius: 22),
            properties: SemanticsProperties(
              label: farmSemanticsLabel(egg.run),
              button: true,
              selected: egg.id == world.selectedId,
              textDirection: TextDirection.ltr,
              onTap: () => onSelect(egg.id),
            ),
          ),
      ];

  @override
  bool shouldRebuildSemantics(FarmCreaturesPainter oldDelegate) =>
      oldDelegate._version != world.version;
}
