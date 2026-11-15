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

  factory LoggedImage.fromJson(Map<String, Object?> json) {
    final bytes = base64Decode(json['data']! as String);
    final format = json['format'] as String? ?? 'png';
    // The file's own size, which is what gets decoded; the server's is a claim.
    final (width, height) = headerSize(bytes, format);
    return LoggedImage(
      name: json['name']! as String,
      step: (json['step']! as num).toInt(),
      format: format,
      width: width,
      height: height,
      caption: json['caption'] as String?,
      bytes: bytes,
    );
  }

  /// The most pixels a side the app draws (the server's limit too).
  static const maxSide = 8192;

  /// Whether it is safe to decode: a PNG or JPEG of at most [maxSide] a
  /// side. A small, very compressible file can say 60000 x 60000, and
  /// decoding it would run the app out of memory.
  bool get drawable => width > 0 && height > 0 && width <= maxSide && height <= maxSide;

  /// (width, height) from a PNG's or JPEG's own header; (0, 0) if none.
  static (int, int) headerSize(Uint8List data, String format) {
    int u16(int i) => data[i] << 8 | data[i + 1];
    int u32(int i) => u16(i) << 16 | u16(i + 2);
    if (format == 'png') {
      final ihdr = data.length >= 24 && String.fromCharCodes(data, 12, 16) == 'IHDR';
      return ihdr ? (u32(16), u32(20)) : (0, 0);
    }
    if (data.length < 3 || data[0] != 0xFF || data[1] != 0xD8) return (0, 0);
    var i = 2;
    while (i + 9 < data.length) {
      if (data[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = data[i + 1];
      if (marker == 0xFF) {
        i++;
      } else if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
      } else if (_jpegFrames.contains(marker)) {
        return (u16(i + 7), u16(i + 5));
      } else {
        i += 2 + u16(i + 2);
      }
    }
    return (0, 0);
  }

  static const _jpegFrames = {
    0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF, //
  };

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
