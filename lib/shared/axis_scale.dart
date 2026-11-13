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

/// A logarithmic axis: positive bounds and round ticks between them.
typedef LogAxisScale = ({double min, double max, List<double> ticks});

/// A log axis covering [min] to [max] (both positive), with ticks at 1, 2
/// and 5 times a power of ten, or only at powers of ten when the range
/// spans more than two of them. The bounds are ticks too.
LogAxisScale logAxis(double min, double max) {
  assert(min > 0 && max > 0 && min.isFinite && max.isFinite, 'logAxis needs positive bounds');
  if (max < min) (min, max) = (max, min);
  final first = _decade(min);
  final last = _decade(max) + 1;
  final span = last - first; // Powers of ten covered.
  final mantissas = span > 2 ? const [1.0] : const [1.0, 2.0, 5.0];
  // Wide ranges: every n-th power of ten, so there are at most ~6 ticks.
  final every = span > 6 ? (span / 6).ceil() : 1;
  final candidates = [
    for (var e = first - every; e <= last + every; e++)
      if (e % every == 0)
        for (final m in mantissas) m * math.pow(10, e).toDouble(),
  ];
  const tolerance = 1e-9;
  var lower = candidates.lastWhere((c) => c <= min * (1 + tolerance));
  var upper = candidates.firstWhere((c) => c >= max * (1 - tolerance));
  if (lower == upper) {
    // A flat line on a tick: open up to the neighbouring ticks.
    final i = candidates.indexOf(lower);
    lower = candidates[i - 1];
    upper = candidates[i + 1];
  }
  return (
    min: lower,
    max: upper,
    ticks: [
      for (final c in candidates)
        if (c >= lower && c <= upper) c,
    ],
  );
}

/// Power of ten of [value], robust to rounding (1000 → 3, 999.9 → 2).
int _decade(double value) => (math.log(value) / math.ln10 + 1e-9).floor();
