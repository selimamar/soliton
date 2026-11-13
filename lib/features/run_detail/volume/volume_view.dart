import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:material_ui/material_ui.dart';

import 'volume_renderer.dart';

/// A 3D field drawn by [renderVolume], in its bounding box. Drag to turn
/// it, pinch or Ctrl/⌘ + scroll to zoom: the camera belongs to the parent
/// ([camera], [onCamera]), so several views can turn together.
///
/// While [draft] (being turned, or a rollout playing) it renders at low
/// resolution, to keep up; then sharp.
class VolumeView extends StatefulWidget {
  const VolumeView({
    super.key,
    required this.volume,
    required this.style,
    required this.camera,
    required this.onCamera,
    required this.semanticLabel,
    this.onInteracting,
    this.draft = false,
    this.axisNames,
  });

  final Volume volume;
  final VolumeStyle style;
  final VolumeCamera camera;
  final ValueChanged<VolumeCamera> onCamera;
  final ValueChanged<bool>? onInteracting;
  final bool draft;

  /// Names for the box's axes (e.g. x, y, z); default 0, 1, 2.
  final List<String>? axisNames;
  final String semanticLabel;

  /// Pixels across, sharp and while turning.
  static const sharpResolution = 150;
  static const draftResolution = 64;

  @override
  State<VolumeView> createState() => _VolumeViewState();
}

class _VolumeViewState extends State<VolumeView> {
  // The last render, and what it was made from: rendering is the slow part,
  // so it is redone only when one of these changes.
  Int32List? _pixels;
  Float32List? _values;
  VolumeStyle? _style;
  VolumeCamera? _camera;
  int _resolution = 0;
  int _steps = 0;
  int _background = 0;
  late VolumeCamera _startCamera;

  Int32List _render(int resolution, int background) {
    final longest = widget.volume.sizes.reduce(math.max);
    final steps = widget.draft ? 48 : (longest * 1.5).round().clamp(48, 160);
    if (_pixels == null ||
        !identical(_values, widget.volume.values) ||
        _style != widget.style ||
        _camera != widget.camera ||
        _resolution != resolution ||
        _steps != steps ||
        _background != background) {
      _pixels = renderVolume(
        widget.volume,
        widget.camera,
        widget.style,
        width: resolution,
        height: resolution,
        background: background,
        steps: steps,
      );
      _values = widget.volume.values;
      _style = widget.style;
      _camera = widget.camera;
      _resolution = resolution;
      _steps = steps;
      _background = background;
    }
    return _pixels!;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = scheme.surfaceContainerHighest.toARGB32();
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.biggest.shortestSide;
          final resolution = math.max(
            16,
            math.min(
              side.round(),
              widget.draft ? VolumeView.draftResolution : VolumeView.sharpResolution,
            ),
          );
          final pixels = _render(resolution, background);
          return Semantics(
            image: true,
            label: widget.semanticLabel,
            child: Listener(
              // Ctrl/⌘ + wheel zooms (and a trackpad pinch); a plain wheel
              // scrolls the page, as everywhere else in the app.
              onPointerSignal: (event) {
                final keys = HardwareKeyboard.instance;
                if (event is PointerScrollEvent && (keys.isControlPressed || keys.isMetaPressed)) {
                  GestureBinding.instance.pointerSignalResolver.register(event, (event) {
                    final dy = (event as PointerScrollEvent).scrollDelta.dy;
                    widget.onCamera(widget.camera.zoomed(math.exp(-dy / 300)));
                  });
                } else if (event is PointerScaleEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(event, (event) {
                    widget.onCamera(widget.camera.zoomed((event as PointerScaleEvent).scale));
                  });
                }
              },
              child: RawGestureDetector(
                gestures: {
                  _EagerScaleGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<_EagerScaleGestureRecognizer>(
                        _EagerScaleGestureRecognizer.new,
                        (recognizer) => recognizer
                          ..onStart = (_) {
                            _startCamera = widget.camera;
                            widget.onInteracting?.call(true);
                          }
                          ..onUpdate = (details) {
                            final turned = widget.camera.turned(
                              -details.focalPointDelta.dx * 0.012,
                              details.focalPointDelta.dy * 0.012,
                            );
                            widget.onCamera(
                              details.pointerCount > 1
                                  ? VolumeCamera(
                                      yaw: turned.yaw,
                                      pitch: turned.pitch,
                                      zoom: _startCamera.zoomed(details.scale).zoom,
                                    )
                                  : turned,
                            );
                          }
                          ..onEnd = (_) => widget.onInteracting?.call(false),
                      ),
                },
                child: CustomPaint(
                  size: Size.square(side),
                  painter: _PixelsPainter(pixels, _resolution),
                  foregroundPainter: _BoxPainter(
                    camera: widget.camera,
                    sizes: widget.volume.sizes,
                    color: scheme.onSurfaceVariant,
                    labelStyle: Theme.of(context).textTheme.labelSmall!
                        .copyWith(color: scheme.onSurfaceVariant),
                    names: widget.axisNames,
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

/// Wins the gesture arena as soon as a finger lands, so turning the view
/// doesn't scroll the page instead.
class _EagerScaleGestureRecognizer extends ScaleGestureRecognizer {
  _EagerScaleGestureRecognizer({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// [pixels] (resolution × resolution, 0xAARRGGBB) as a square, one quad
/// per pixel, in a single draw call.
class _PixelsPainter extends CustomPainter {
  _PixelsPainter(this.pixels, this.resolution);

  final Int32List pixels;
  final int resolution;

  @override
  void paint(Canvas canvas, Size size) {
    final n = resolution;
    final positions = Float32List(n * n * 12);
    final colors = Int32List(n * n * 6);
    final d = size.width / n;
    for (var r = 0; r < n; r++) {
      final top = r * d, bottom = (r + 1) * d + 0.5; // Overlap a little: no seams.
      for (var c = 0; c < n; c++) {
        final i = r * n + c;
        final left = c * d, right = (c + 1) * d + 0.5;
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
        colors.fillRange(i * 6, i * 6 + 6, pixels[i]);
      }
    }
    final vertices = ui.Vertices.raw(VertexMode.triangles, positions, colors: colors);
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
  }

  @override
  bool shouldRepaint(_PixelsPainter old) => !identical(old.pixels, pixels);
}

/// The bounding box's edges, and which axis is which.
class _BoxPainter extends CustomPainter {
  _BoxPainter({
    required this.camera,
    required this.sizes,
    required this.color,
    required this.labelStyle,
    this.names,
  });

  final VolumeCamera camera;
  final List<int> sizes;
  final Color color;
  final TextStyle labelStyle;
  final List<String>? names;

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(double x, double y, double z) {
      final p = projectBoxPoint(camera, sizes, x, y, z);
      return Offset((p.x + 1) / 2 * size.width, (1 - p.y) / 2 * size.height);
    }

    final paint = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    const corners = [-1.0, 1.0];
    for (final a in corners) {
      for (final b in corners) {
        canvas
          ..drawLine(at(-1, a, b), at(1, a, b), paint)
          ..drawLine(at(a, -1, b), at(a, 1, b), paint)
          ..drawLine(at(a, b, -1), at(a, b, 1), paint);
      }
    }
    // The three edges from the first corner, labelled with their axis.
    final axisPaint = Paint()
      ..color = color
      ..strokeWidth = 2;
    final origin = at(-1, -1, -1);
    for (final (axis, end) in [(0, at(1, -1, -1)), (1, at(-1, 1, -1)), (2, at(-1, -1, 1))]) {
      canvas.drawLine(origin, end, axisPaint);
      final label = TextPainter(
        text: TextSpan(
          text: names != null && axis < names!.length ? names![axis] : '$axis',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final away = end - origin;
      final nudge = away.distance == 0 ? Offset.zero : away / away.distance * 8;
      label.paint(canvas, end + nudge - Offset(label.width / 2, label.height / 2));
      label.dispose();
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.camera != camera ||
      old.color != color ||
      !identical(old.sizes, sizes) ||
      old.names != names;
}
