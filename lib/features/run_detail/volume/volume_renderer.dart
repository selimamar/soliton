/// A small CPU ray marcher for 3D fields: volume rendering, maximum
/// intensity projection and isosurfaces, seen through an orthographic
/// camera that orbits the field's bounding box.
///
/// Pure Dart (no Flutter), so it is easy to test; `volume_view.dart` draws
/// the pixels it makes.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A 3D grid of values, axis 0 slowest: value (i, j, k) is at
/// `(i * sizes[1] + j) * sizes[2] + k`. Axis 0 is drawn left to right, axis
/// 1 front to back and axis 2 upwards (so an (x, y, t) field has time going
/// up).
class Volume {
  Volume(this.values, this.sizes) : assert(values.length == sizes[0] * sizes[1] * sizes[2]);

  final Float32List values;
  final List<int> sizes;
}

enum VolumeMode {
  /// See-through: the further a value is from the background value, the
  /// more it shows.
  volume,

  /// The most extreme value along each ray.
  maxProjection,

  /// A shaded surface where values reach a level (both signs for a signed
  /// field).
  isosurface,
}

/// Where the camera looks from: [yaw] around the vertical axis, [pitch]
/// above the horizon (radians), and [zoom] (1: the whole box fits).
class VolumeCamera {
  const VolumeCamera({this.yaw = -0.6, this.pitch = 0.45, this.zoom = 1});

  final double yaw;
  final double pitch;
  final double zoom;

  static const maxPitch = 1.45;

  VolumeCamera turned(double dYaw, double dPitch) =>
      VolumeCamera(yaw: yaw + dYaw, pitch: (pitch + dPitch).clamp(-maxPitch, maxPitch), zoom: zoom);

  VolumeCamera zoomed(double factor) =>
      VolumeCamera(yaw: yaw, pitch: pitch, zoom: (zoom * factor).clamp(0.4, 6.0));

  /// The camera's right, up and towards-the-camera directions.
  ({Vec3 right, Vec3 up, Vec3 back}) get basis {
    final back = Vec3(
      math.cos(pitch) * math.cos(yaw),
      math.cos(pitch) * math.sin(yaw),
      math.sin(pitch),
    );
    final right = const Vec3(0, 0, 1).cross(back).normalized();
    return (right: right, up: back.cross(right), back: back);
  }

  /// Half the width of the view, in box units (the box's longest side is 2).
  double get halfView => 1.9 / zoom;

  @override
  bool operator ==(Object other) =>
      other is VolumeCamera && other.yaw == yaw && other.pitch == pitch && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(yaw, pitch, zoom);
}

/// How values become colours.
class VolumeStyle {
  const VolumeStyle({
    required this.mode,
    required this.low,
    required this.high,
    required this.colors,
    this.opacity = 0.5,
    this.level = 0.5,
  });

  final VolumeMode mode;

  /// The colour scale's ends.
  final double low;
  final double high;

  /// 257 colours from [low] to [high], as 0xAARRGGBB.
  final List<int> colors;

  /// How dense the volume looks (0..1).
  final double opacity;

  /// The isosurface level, as a fraction (0..1) of the way from the
  /// background value to the most extreme value.
  final double level;

  /// The "nothing here" value: zero for a signed field (and for errors),
  /// else the end of the range nearest zero. Values far from it show most.
  double get reference => low < 0 && high > 0
      ? 0
      : low >= 0
      ? low
      : high;

  /// The largest distance from [reference] within the range.
  double get maxDeviation => math.max((high - reference).abs(), (low - reference).abs());

  @override
  bool operator ==(Object other) =>
      other is VolumeStyle &&
      other.mode == mode &&
      other.low == low &&
      other.high == high &&
      identical(other.colors, colors) &&
      other.opacity == opacity &&
      other.level == level;

  @override
  int get hashCode => Object.hash(mode, low, high, colors, opacity, level);
}

/// Renders [volume] seen by [camera] into [width] × [height] pixels
/// (0xAARRGGBB, row by row), over [background]. [steps] samples per ray
/// through the box's longest side.
Int32List renderVolume(
  Volume volume,
  VolumeCamera camera,
  VolumeStyle style, {
  required int width,
  required int height,
  required int background,
  int steps = 96,
}) {
  final pixels = Int32List(width * height)..fillRange(0, width * height, background);
  final n = volume.sizes;
  final longest = n.reduce(math.max).toDouble();
  // Half extents of the box: the longest side spans -1..1.
  final ex = n[0] / longest, ey = n[1] / longest, ez = n[2] / longest;
  final (:right, :up, :back) = camera.basis;
  final dir = -back;
  final half = camera.halfView;
  final aspect = width / height;
  final ds = 2 / steps;
  final values = volume.values;
  final n1 = n[1], n2 = n[2];
  final span = style.high - style.low;
  final reference = style.reference;
  final deviation = style.maxDeviation;
  final threshold = style.level.clamp(0.02, 0.98) * deviation;
  final density = 14 * style.opacity * style.opacity + 0.5;
  final bgR = (background >> 16) & 0xFF, bgG = (background >> 8) & 0xFF, bgB = background & 0xFF;
  // Light from over the viewer's shoulder.
  final light = (back + up * 0.6 + right * 0.3).normalized();

  // The value at continuous voxel coordinates (trilinear), or NaN outside.
  double sample(double x, double y, double z) {
    // Grid points sit at cell centres: -0.5..n-0.5 covers the box.
    x = x.clamp(0, n[0] - 1);
    y = y.clamp(0, n[1] - 1);
    z = z.clamp(0, n[2] - 1);
    final x0 = x.floor(), y0 = y.floor(), z0 = z.floor();
    final x1 = math.min(x0 + 1, n[0] - 1),
        y1 = math.min(y0 + 1, n1 - 1),
        z1 = math.min(z0 + 1, n2 - 1);
    final fx = x - x0, fy = y - y0, fz = z - z0;
    double at(int i, int j, int k) => values[(i * n1 + j) * n2 + k];
    final c00 = at(x0, y0, z0) * (1 - fz) + at(x0, y0, z1) * fz;
    final c01 = at(x0, y1, z0) * (1 - fz) + at(x0, y1, z1) * fz;
    final c10 = at(x1, y0, z0) * (1 - fz) + at(x1, y0, z1) * fz;
    final c11 = at(x1, y1, z0) * (1 - fz) + at(x1, y1, z1) * fz;
    return (c00 * (1 - fy) + c01 * fy) * (1 - fx) + (c10 * (1 - fy) + c11 * fy) * fx;
  }

  int colorOf(double v) {
    final t = span > 0 ? ((v - style.low) / span).clamp(0.0, 1.0) : 0.5;
    return style.colors[(t * (style.colors.length - 1)).round()];
  }

  // Voxel coordinates change linearly along a ray: v(t) = a + b t.
  final bx = dir.x / ex * 0.5 * n[0], by = dir.y / ey * 0.5 * n1, bz = dir.z / ez * 0.5 * n2;

  for (var py = 0; py < height; py++) {
    final sv = (1 - 2 * (py + 0.5) / height) * half;
    for (var px = 0; px < width; px++) {
      final su = (2 * (px + 0.5) / width - 1) * half * aspect;
      final ox = back.x * 4 + right.x * su + up.x * sv;
      final oy = back.y * 4 + right.y * su + up.y * sv;
      final oz = back.z * 4 + right.z * su + up.z * sv;
      // Where the ray enters and leaves the box (slab method).
      var tNear = -double.infinity, tFar = double.infinity;
      if (!_slab(ox, dir.x, ex, (t0, t1) {
            tNear = math.max(tNear, t0);
            tFar = math.min(tFar, t1);
          }) ||
          !_slab(oy, dir.y, ey, (t0, t1) {
            tNear = math.max(tNear, t0);
            tFar = math.min(tFar, t1);
          }) ||
          !_slab(oz, dir.z, ez, (t0, t1) {
            tNear = math.max(tNear, t0);
            tFar = math.min(tFar, t1);
          }) ||
          tNear >= tFar) {
        continue;
      }
      final ax = (ox / ex * 0.5 + 0.5) * n[0] - 0.5;
      final ay = (oy / ey * 0.5 + 0.5) * n1 - 0.5;
      final az = (oz / ez * 0.5 + 0.5) * n2 - 0.5;
      double vx(double t) => ax + bx * t;
      double vy(double t) => ay + by * t;
      double vz(double t) => az + bz * t;

      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      var best = double.nan, bestDeviation = -1.0;
      double? previous;
      for (var t = tNear + ds / 2; t < tFar; t += ds) {
        final v = sample(vx(t), vy(t), vz(t));
        if (!v.isFinite) continue;
        final dev = (v - reference).abs();
        switch (style.mode) {
          case VolumeMode.maxProjection:
            if (dev > bestDeviation) {
              bestDeviation = dev;
              best = v;
            }
          case VolumeMode.volume:
            final w = deviation > 0 ? math.pow(dev / deviation, 1.5).toDouble() : 0.0;
            final alpha = 1 - math.exp(-density * w * ds * 4);
            final c = colorOf(v);
            final k = (1 - a) * alpha;
            r += k * ((c >> 16) & 0xFF);
            g += k * ((c >> 8) & 0xFF);
            b += k * (c & 0xFF);
            a += k;
          case VolumeMode.isosurface:
            if (dev >= threshold) {
              // Back up to where the level was crossed, then shade.
              var tHit = t;
              if (previous != null) {
                final before = (previous - reference).abs();
                final f = dev > before ? (threshold - before) / (dev - before) : 1.0;
                tHit = t - ds * (1 - f.clamp(0.0, 1.0));
              }
              final hx = vx(tHit), hy = vy(tHit), hz = vz(tHit);
              final normal = Vec3(
                (sample(hx + 1, hy, hz) - sample(hx - 1, hy, hz)) / ex,
                (sample(hx, hy + 1, hz) - sample(hx, hy - 1, hz)) / ey,
                (sample(hx, hy, hz + 1) - sample(hx, hy, hz - 1)) / ez,
              ).normalized();
              final shade = 0.3 + 0.7 * normal.dot(light).abs();
              final c = colorOf(sample(hx, hy, hz));
              r = shade * ((c >> 16) & 0xFF);
              g = shade * ((c >> 8) & 0xFF);
              b = shade * (c & 0xFF);
              a = 1;
            }
        }
        if (a > 0.98) break;
        previous = v;
      }
      if (style.mode == VolumeMode.maxProjection && best.isFinite) {
        final c = colorOf(best);
        r = ((c >> 16) & 0xFF).toDouble();
        g = ((c >> 8) & 0xFF).toDouble();
        b = (c & 0xFF).toDouble();
        a = 1;
      }
      if (a <= 0) continue;
      final rest = 1 - a;
      final red = (r + rest * bgR).round().clamp(0, 255);
      final green = (g + rest * bgG).round().clamp(0, 255);
      final blue = (b + rest * bgB).round().clamp(0, 255);
      pixels[py * width + px] = 0xFF000000 | (red << 16) | (green << 8) | blue;
    }
  }
  return pixels;
}

/// Intersects a ray (origin [o], direction [d]) with the slab -e..e on one
/// axis: calls [range] with where it enters and leaves, or returns false
/// if the ray runs alongside the slab, outside it.
bool _slab(double o, double d, double e, void Function(double t0, double t1) range) {
  if (d.abs() < 1e-12) return o >= -e && o <= e;
  final t0 = (-e - o) / d, t1 = (e - o) / d;
  t0 < t1 ? range(t0, t1) : range(t1, t0);
  return true;
}

/// Where a point of the box ([x], [y], [z] in -1..1 of each half extent)
/// lands on the screen, in -1..1 of the view's half height (x to the right,
/// y up). For drawing the box's edges over the render.
({double x, double y}) projectBoxPoint(
  VolumeCamera camera,
  List<int> sizes,
  double x,
  double y,
  double z,
) {
  final longest = sizes.reduce(math.max).toDouble();
  final p = Vec3(x * sizes[0] / longest, y * sizes[1] / longest, z * sizes[2] / longest);
  final (:right, :up, back: _) = camera.basis;
  return (x: p.dot(right) / camera.halfView, y: p.dot(up) / camera.halfView);
}

/// A 3D vector.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x, y, z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -() => Vec3(-x, -y, -z);
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) => Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  Vec3 normalized() {
    final length = math.sqrt(dot(this));
    return length == 0 ? this : this * (1 / length);
  }
}
