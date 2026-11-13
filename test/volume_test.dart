import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:models_app/features/run_detail/volume/volume_renderer.dart';
import 'package:models_app/shared/colormaps.dart';

const background = 0xFF101010;

/// A 16³ volume, 0 outside and [value] in a cube at the centre.
Volume cube([double value = 1]) {
  const n = 16;
  final values = Float32List(n * n * n);
  for (var i = 5; i < 11; i++) {
    for (var j = 5; j < 11; j++) {
      for (var k = 5; k < 11; k++) {
        values[(i * n + j) * n + k] = value;
      }
    }
  }
  return Volume(values, const [n, n, n]);
}

VolumeStyle style(VolumeMode mode, {double low = 0, double high = 1}) =>
    VolumeStyle(mode: mode, low: low, high: high, colors: Colormap.viridis.table, level: 0.5);

/// Pixels are stored as signed 32-bit ints; colours are unsigned.
int centre(Int32List pixels, int n) => pixels[(n ~/ 2) * n + n ~/ 2].toUnsigned(32);

void main() {
  for (final camera in const [
    VolumeCamera(),
    VolumeCamera(yaw: 1.3, pitch: -0.9),
    VolumeCamera(yaw: 0, pitch: 0),
  ]) {
    test('the centre of a bright cube shows, the corners stay background (${camera.yaw})', () {
      for (final mode in VolumeMode.values) {
        final pixels = renderVolume(
          cube(),
          camera,
          style(mode),
          width: 40,
          height: 40,
          background: background,
        );
        expect(centre(pixels, 40), isNot(background), reason: '$mode');
        expect(pixels.first.toUnsigned(32), background, reason: '$mode: outside the box');
      }
    });
  }

  test('max projection shows the extreme value in its colour', () {
    final pixels = renderVolume(
      cube(),
      const VolumeCamera(),
      style(VolumeMode.maxProjection),
      width: 30,
      height: 30,
      background: background,
    );
    expect(centre(pixels, 30), Colormap.viridis.argbAt(1));
  });

  test('a signed field shows both signs: zero is the background value', () {
    final negative = renderVolume(
      cube(-1),
      const VolumeCamera(),
      style(VolumeMode.isosurface, low: -1, high: 1),
      width: 30,
      height: 30,
      background: background,
    );
    expect(centre(negative, 30), isNot(background));
    expect(style(VolumeMode.volume, low: -1, high: 1).reference, 0);
    expect(style(VolumeMode.volume, low: 2, high: 5).reference, 2);
  });

  test('turning the camera keeps the box in view', () {
    var camera = const VolumeCamera();
    for (var i = 0; i < 50; i++) {
      camera = camera.turned(0.3, 0.2);
    }
    expect(camera.pitch, lessThanOrEqualTo(VolumeCamera.maxPitch));
    final corner = projectBoxPoint(camera, const [16, 16, 16], 1, 1, 1);
    expect(corner.x.abs(), lessThan(1));
    expect(corner.y.abs(), lessThan(1));
  });

  test('a sharp render of a 64³ field is quick enough', () {
    final random = math.Random(1);
    const n = 64;
    final volume = Volume(
      Float32List.fromList([for (var i = 0; i < n * n * n; i++) random.nextDouble()]),
      const [n, n, n],
    );
    final watch = Stopwatch()..start();
    renderVolume(
      volume,
      const VolumeCamera(),
      style(VolumeMode.volume),
      width: 150,
      height: 150,
      background: background,
      steps: 96,
    );
    // ignore: avoid_print
    print('150 × 150, 96 steps: ${watch.elapsedMilliseconds} ms');
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
