import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import 'farm_palette.dart';
import 'farm_settings.dart';
import 'farm_world.dart';

// The farm's other animals, drawn like the ducks: from the side, in the
// animal's own coordinates, feet at the origin and facing right, a duck
// being about 50 units tall. The canvas is already moved, scaled and
// flipped to face the way the animal walks.

/// Paints [beast] (a moose, goose, beaver or bear; ducks are drawn by the
/// creatures painter). [line] outlines it in Ink and Lab.
void paintBeast(
  Canvas canvas,
  FarmPalette p,
  FarmDuck beast, {
  required double time,
  required Paint? line,
}) {
  final (body, shade, detail) = p.beast(beast.animal);
  final b = _Beast(canvas, p, beast, time, line, body, shade, detail);
  switch (beast.animal) {
    case FarmAnimal.moose:
      b.moose();
    case FarmAnimal.goose:
      b.goose();
    case FarmAnimal.beaver:
      b.beaver();
    case FarmAnimal.bear:
      b.bear();
    case FarmAnimal.duck:
      break;
  }
}

class _Beast {
  _Beast(this.canvas, this.p, this.a, this.time, this.line, this.body, this.shade, this.detail);

  final Canvas canvas;
  final FarmPalette p;
  final FarmDuck a;
  final double time;
  final Paint? line;
  final Color body, shade, detail;

  final fill = Paint();

  double get _phase => (a.id.hashCode % 628) / 100;

  /// Fills [path] in [colour] and outlines it (Ink, Lab).
  void shape(Path path, Color colour, {double outline = 1}) {
    canvas.drawPath(path, fill..color = colour);
    if (line case final line?) {
      final width = line.strokeWidth;
      canvas.drawPath(path, line..strokeWidth = width * outline);
      line.strokeWidth = width;
    }
  }

  Path oval(double cx, double cy, double w, double h) =>
      Path()..addOval(Rect.fromCenter(center: Offset(cx, cy), width: w, height: h));

  /// Hooves, paws and a beaver's feet: dark in Paper, the line colour else.
  Color get _feet => switch (p.style) {
    AppStyle.paper => p.dark ? const Color(0xFF1C1E21) : const Color(0xFF3A3530),
    _ => Color.lerp(body, p.line, 0.45)!,
  };

  /// The eye: a dot, a slit while blinking or asleep, with a glint.
  void eye(Offset at, {double r = 1.6, bool onDark = false}) {
    canvas.drawOval(
      Rect.fromCenter(center: at, width: r * 2.2, height: a.blinking ? 0.7 : r * 2.6),
      fill..color = onDark ? const Color(0xFFF2F2F0) : p.eye,
    );
    if (!a.blinking && !onDark) {
      canvas.drawCircle(
        at.translate(r * 0.4, -r * 0.5),
        r * 0.4,
        fill..color = p.dark && p.style != AppStyle.paper ? p.ground : Colors.white,
      );
    }
  }

  /// A leg from [hip], [length] long and [thick], swinging as it walks.
  /// [phase] sets which legs move together (a diagonal trot).
  void leg(Offset hip, double length, double thick, double phase, Color colour, {Color? foot}) {
    final ph = a.gait + phase;
    final swing = a.walking ? math.sin(ph) * 0.38 : 0.0;
    final lift = a.walking ? math.max(0.0, math.cos(ph)) * length * 0.12 : 0.0;
    final end = hip + Offset(math.sin(swing) * length, math.cos(swing) * length - lift);
    final paint = Paint()
      ..color = colour
      ..strokeWidth = thick
      ..strokeCap = StrokeCap.round;
    if (line case final line?) {
      canvas.drawLine(
        hip,
        end,
        Paint()
          ..color = line.color
          ..strokeWidth = thick + line.strokeWidth * 2
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawLine(hip, end, paint);
    if (foot != null) {
      canvas.drawLine(
        end.translate(0, -thick * 0.3),
        end.translate(thick * 0.2, 0),
        paint
          ..color = foot
          ..strokeWidth = thick * 1.05,
      );
    }
  }

  /// How far the body sinks: lying down asleep, or low in the water.
  double sink({required double lying, double swimming = 0}) {
    if (a.swimming) return swimming + math.sin(time * 3.6 + _phase) * 0.8;
    if (a.asleep) return lying;
    return a.walking ? -math.sin(a.gait).abs() * 1.2 : 0;
  }

  void moose() {
    final legs = !a.swimming && !a.asleep;
    if (legs) {
      leg(const Offset(-14, -30), 30, 4.2, math.pi, shade, foot: _feet);
      leg(const Offset(16, -32), 32, 4.2, 0, shade, foot: _feet);
    }
    canvas
      ..save()
      ..translate(0, sink(lying: 24));
    shape(oval(-5, -38, 54, 24), body);
    shape(oval(8, -46, 28, 15), body);
    shape(oval(-30, -42, 5, 6), shade);
    canvas.restore();
    if (legs) {
      leg(const Offset(-22, -30), 30, 4.6, 0, body, foot: _feet);
      leg(const Offset(9, -32), 32, 4.6, math.pi, body, foot: _feet);
    }
    canvas
      ..save()
      ..translate(0, sink(lying: 24))
      ..translate(_headBob(), _sleepDroop(6));
    // Neck, head with its long drooping nose, the bell under the chin.
    shape(
      Path()
        ..moveTo(12, -50)
        ..quadraticBezierTo(22, -56, 28, -56)
        ..lineTo(30, -46)
        ..quadraticBezierTo(22, -42, 14, -38)
        ..close(),
      body,
    );
    shape(oval(33, -38.5, 4.5, 8), shade, outline: 0.8);
    shape(oval(31, -52, 20, 12), body);
    shape(oval(40, -48.5, 11, 10), shade);
    canvas.drawCircle(const Offset(43.5, -48), 1, fill..color = _feet);
    shape(oval(24, -60, 5, 9), shade, outline: 0.8);
    // Broad, flat antlers with a few points.
    shape(
      Path()
        ..moveTo(25, -58)
        ..quadraticBezierTo(20, -63, 12, -64)
        ..lineTo(7, -73)
        ..lineTo(12, -70.5)
        ..lineTo(13, -77)
        ..lineTo(17, -72)
        ..lineTo(20, -79)
        ..lineTo(23, -72)
        ..lineTo(27, -76)
        ..lineTo(28, -66)
        ..quadraticBezierTo(28, -61, 27, -58)
        ..close(),
      detail,
      outline: 0.8,
    );
    eye(const Offset(31, -55));
    canvas.restore();
  }

  void goose() {
    final swimming = a.swimming;
    if (!swimming && !a.asleep) {
      for (var i = 0; i < 2; i++) {
        final ph = a.gait + i * math.pi, hx = -3.0 + i * 5;
        final fx = a.walking ? hx + math.sin(ph) * 4 : hx;
        final fy = a.walking ? -math.max(0.0, math.cos(ph)) * 3 : 0.0;
        canvas.drawLine(
          Offset(hx, -12),
          Offset(fx, fy - 1),
          Paint()
            ..color = p.style == AppStyle.paper ? detail : p.line!
            ..strokeWidth = p.style == AppStyle.paper ? 2.4 : 1.3
            ..strokeCap = StrokeCap.round,
        );
        shape(
          Path()
            ..moveTo(fx - 3, fy)
            ..lineTo(fx + 6, fy)
            ..quadraticBezierTo(fx + 7, fy - 2.5, fx + 4, fy - 3)
            ..lineTo(fx - 1, fy - 3)
            ..close(),
          p.style == AppStyle.paper ? detail : p.bill,
          outline: 0.8,
        );
      }
    }
    final rock = a.walking && !swimming ? math.sin(a.gait) * 4 : 0.0;
    canvas
      ..save()
      ..translate(0, sink(lying: 9, swimming: 9))
      ..translate(0, -12)
      ..rotate(rock * math.pi / 180)
      ..translate(0, 12);
    shape(
      Path()
        ..moveTo(-27, -34)
        ..cubicTo(-20, -33, -15, -33, -12, -31)
        ..cubicTo(-2, -34, 12, -33, 16, -25)
        ..cubicTo(20, -17, 15, -11, 3, -11)
        ..lineTo(-10, -11)
        ..cubicTo(-21, -11, -24, -19, -23, -26)
        ..cubicTo(-23, -29, -25, -32, -27, -34)
        ..close(),
      body,
    );
    shape(
      Path()
        ..moveTo(-14, -26)
        ..cubicTo(-9, -32, 4, -32, 9, -25)
        ..cubicTo(3, -20, -8, -20, -14, -26)
        ..close(),
      shade,
      outline: 0.8,
    );
    // The long black neck, then the head with its white cheek.
    canvas
      ..save()
      ..translate(_headBob(), 0);
    // Asleep, the neck lies back along its body, head on its back.
    if (a.asleep) {
      canvas
        ..translate(8, -26)
        ..rotate(-1.5)
        ..scale(0.72)
        ..translate(-8, 26);
    }
    shape(
      Path()
        ..moveTo(6, -27)
        ..cubicTo(9, -38, 10, -50, 13, -60)
        ..lineTo(20, -60)
        ..cubicTo(18, -50, 16, -38, 14, -25)
        ..close(),
      detail,
    );
    shape(oval(18, -62.5, 15, 11), detail);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(15.5, -60), width: 6, height: 5),
      fill..color = p.style == AppStyle.lab ? p.ground : const Color(0xFFF7F7F4),
    );
    shape(
      Path()
        ..moveTo(24.5, -65)
        ..quadraticBezierTo(30, -64, 31, -62)
        ..quadraticBezierTo(29, -60.5, 24.5, -60.5)
        ..close(),
      p.style == AppStyle.paper ? detail : p.bill,
      outline: 0.8,
    );
    eye(const Offset(20.5, -64.5), r: 1.3, onDark: p.style != AppStyle.lab);
    canvas
      ..restore()
      ..restore();
  }

  void beaver() {
    final legs = !a.swimming;
    canvas
      ..save()
      ..translate(0, sink(lying: 2, swimming: 9));
    // The flat, scaly tail out behind.
    canvas
      ..save()
      ..translate(-20, -5)
      ..rotate(a.walking ? math.sin(a.gait * 2) * 0.06 - 0.08 : -0.08);
    final tail = Path()..addRRect(RRect.fromLTRBR(-22, -3.5, 2, 3.5, const Radius.circular(3.5)));
    shape(tail, detail);
    final scales = Paint()
      ..color = p.style == AppStyle.paper ? shade : (p.line ?? shade).withValues(alpha: 0.5)
      ..strokeWidth = 0.6;
    for (var x = -18.0; x < 0; x += 4) {
      canvas.drawLine(Offset(x, -3), Offset(x + 2, 3), scales);
    }
    canvas.restore();
    if (legs) {
      leg(const Offset(-12, -5), 5, 4.5, math.pi, shade, foot: _feet);
      leg(const Offset(8, -5), 5, 4.5, 0, shade, foot: _feet);
    }
    shape(oval(-3, -12, 42, 22), body);
    shape(oval(-6, -9, 28, 10), shade, outline: 0);
    if (legs) {
      leg(const Offset(-16, -4), 4, 4.8, 0, body, foot: _feet);
      leg(const Offset(4, -4), 4, 4.8, math.pi, body, foot: _feet);
    }
    canvas.translate(_headBob() * 0.6, _sleepDroop(3));
    shape(oval(17, -14, 17, 15.5), body);
    shape(oval(13.5, -21, 4.5, 4.5), shade, outline: 0.8);
    shape(oval(23, -11.5, 8, 6.5), shade, outline: 0.7);
    canvas.drawCircle(const Offset(26, -13.5), 1.6, fill..color = _feet);
    // Two front teeth.
    final teeth = Path()..addRect(const Rect.fromLTWH(22.2, -8.8, 3, 3.6));
    shape(teeth, const Color(0xFFFFF6E0), outline: 0.6);
    eye(const Offset(19, -17), r: 1.4);
    canvas.restore();
  }

  void bear() {
    final legs = !a.asleep;
    if (legs) {
      leg(const Offset(-12, -20), 18, 8.5, math.pi, shade, foot: _feet);
      leg(const Offset(14, -20), 18, 8.5, 0, shade, foot: _feet);
    }
    canvas
      ..save()
      ..translate(0, sink(lying: 14));
    shape(oval(-30, -34, 7, 7), shade, outline: 0.8);
    shape(oval(-4, -29, 52, 31), body);
    shape(oval(7, -37, 28, 19), body, outline: 0);
    canvas.restore();
    if (legs) {
      leg(const Offset(-19, -20), 18, 9, 0, body, foot: _feet);
      leg(const Offset(8, -20), 18, 9, math.pi, body, foot: _feet);
    }
    canvas
      ..save()
      ..translate(0, sink(lying: 14))
      ..translate(_headBob(), _sleepDroop(5));
    shape(oval(18.5, -44.5, 8, 8), shade, outline: 0.8);
    shape(oval(25, -34, 22, 21), body);
    shape(oval(27.5, -45.5, 8, 8), body, outline: 0.8);
    shape(oval(35, -30.5, 12, 9.5), detail, outline: 0.8);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(40.2, -32.5), width: 4.6, height: 3.6),
      fill..color = _feet,
    );
    eye(const Offset(28.5, -38));
    canvas.restore();
  }

  /// The head nods as it walks.
  double _headBob() => a.walking && !a.swimming ? math.sin(a.gait * 2) * 1 : 0;

  /// The head rests lower while it sleeps.
  double _sleepDroop(double by) => a.asleep ? by : 0;
}
