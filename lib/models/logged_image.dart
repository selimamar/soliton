import 'dart:convert';
import 'dart:typed_data';

/// A picture the script logs at some steps (`run.log_image`), e.g. a phase
/// portrait or a confusion matrix, without the pictures themselves.
class ImageSeries {
  const ImageSeries({required this.name, required this.steps});

  factory ImageSeries.fromJson(Map<String, Object?> json) => ImageSeries(
    name: json['name']! as String,
    steps: List.unmodifiable([
      for (final step in (json['steps'] as List?) ?? const [])
        ImageStep.fromJson(step as Map<String, Object?>),
    ]),
  );

  final String name;

  /// In step order.
  final List<ImageStep> steps;

  Map<String, Object?> toJson() => {
    'name': name,
    'steps': [for (final s in steps) s.toJson()],
  };
}

/// One logged picture's step, size and caption.
class ImageStep {
  const ImageStep({required this.step, this.width = 0, this.height = 0, this.caption});

  factory ImageStep.fromJson(Map<String, Object?> json) => ImageStep(
    step: (json['step']! as num).toInt(),
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
    caption: json['caption'] as String?,
  );

  final int step;
  final int width;
  final int height;
  final String? caption;

  /// Width over height; 4:3 when unknown (an older JPEG header, say).
  double get aspectRatio => width > 0 && height > 0 ? width / height : 4 / 3;

  Map<String, Object?> toJson() => {
    'step': step,
    'width': width,
    'height': height,
    'caption': caption,
  };
}

/// One logged picture: a PNG or JPEG file.
class LoggedImage {
  const LoggedImage({
    required this.name,
    required this.step,
    required this.format,
    required this.bytes,
    this.width = 0,
    this.height = 0,
    this.caption,
  });

  factory LoggedImage.fromJson(Map<String, Object?> json) => LoggedImage(
    name: json['name']! as String,
    step: (json['step']! as num).toInt(),
    format: json['format'] as String? ?? 'png',
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
    caption: json['caption'] as String?,
    bytes: base64Decode(json['data']! as String),
  );

  final String name;
  final int step;

  /// "png" or "jpeg".
  final String format;
  final Uint8List bytes;
  final int width;
  final int height;
  final String? caption;
}

/// The run has no picture of that name at that step. Retrying won't help.
class ImageNotFoundException implements Exception {
  const ImageNotFoundException(this.name, this.step);

  final String name;
  final int step;

  @override
  String toString() => 'ImageNotFoundException: no image "$name" at step $step';
}
