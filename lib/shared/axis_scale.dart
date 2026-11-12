import 'dart:math' as math;

/// A chart axis whose bounds and tick spacing are round numbers.
typedef AxisScale = ({double min, double max, double interval});

/// A "nice" axis covering [min] to [max] with about [ticks] intervals.
///
/// The interval is 1, 2 or 5 times a power of ten, and the bounds are
/// multiples of it, so tick labels read 0, 5, 10, 15 instead of 0, 5.244, ...
/// Both values must be finite.
AxisScale niceAxis(double min, double max, {int ticks = 4}) {
  assert(min.isFinite && max.isFinite, 'niceAxis needs finite bounds');
  if (max < min) (min, max) = (max, min);
  if (max == min) {
    // A flat line: open up a small range around it.
    final pad = min == 0 ? 1.0 : min.abs() * 0.1;
    min -= pad;
    max += pad;
  }
  final interval = niceInterval((max - min) / ticks);
  return (
    min: (min / interval).floor() * interval,
    max: (max / interval).ceil() * interval,
    interval: interval,
  );
}

/// The smallest of 1, 2 or 5 times a power of ten that is >= [rough].
double niceInterval(double rough) {
  assert(rough > 0 && rough.isFinite, 'niceInterval needs a positive, finite value');
  final magnitude = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
  final fraction = rough / magnitude;
  final nice = fraction <= 1
      ? 1
      : fraction <= 2
      ? 2
      : fraction <= 5
      ? 5
      : 10;
  return nice * magnitude;
}
