/// Small, pure helpers that turn numbers into short display strings.
library;

import 'dart:math' as math;

/// 23500000 -> "23.5M", 9408 -> "9.4k", 512 -> "512", 999999 -> "1M".
String formatCount(num value) {
  final abs = value.abs();
  // Thresholds sit where rounding to one decimal would reach 1000 of the
  // smaller unit, so 999,999 becomes "1M" rather than "1000k".
  if (abs >= 999.95e6) return '${_trim(value / 1e9)}B';
  if (abs >= 999.95e3) return '${_trim(value / 1e6)}M';
  if (abs >= 999.5) return '${_trim(value / 1e3)}k';
  return value.round().toString();
}

/// 8232 -> "8,232".
String formatInt(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// A metric value with a sensible number of digits:
/// 0.41234 -> "0.412", 0.0003 -> "3.0e-4", 123.456 -> "123.5", 52000 -> "52k".
String formatMetric(double value) {
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value > 0 ? '∞' : '-∞';
  final abs = value.abs();
  if (abs == 0) return '0';
  if (abs < 1e-2) return value.toStringAsExponential(1);
  // Thresholds account for rounding: 9.9996 would otherwise print "10.000".
  if (abs < 9.9995) return value.toStringAsFixed(3);
  if (abs < 999.95) return value.toStringAsFixed(1);
  return formatCount(value);
}

/// A position in a domain, with up to 3 significant digits and no trailing
/// zeros: 1 -> "1", 0.0078125 -> "0.00781", 6.2832 -> "6.28", 1.5e-6 ->
/// "1.5e-6".
String formatCoordinate(double value) {
  if (!value.isFinite) return formatMetric(value);
  final abs = value.abs();
  if (abs == 0) return '0';
  if (abs < 1e-3 || abs >= 1e5) {
    return value
        .toStringAsExponential(1)
        .replaceFirst(RegExp(r'\.0e'), 'e')
        .replaceFirst('e+', 'e');
  }
  var text = abs >= 1000 ? value.round().toString() : value.toStringAsPrecision(3);
  if (text.contains('.') && !text.contains('e')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// "3.2%", "0.45%", "0.0031%": relative errors span orders of magnitude.
String formatRelativeError(double fraction) {
  if (!fraction.isFinite) return formatMetric(fraction);
  final percent = fraction * 100;
  if (percent == 0) return '0%';
  return '${percent >= 1 ? percent.toStringAsFixed(1) : percent.toStringAsPrecision(2)}%';
}

/// A duration in seconds, in the unit that reads best: "4.2 ms",
/// "850 µs", "2.1 s", "3m 12s".
String formatSeconds(double seconds) {
  if (!seconds.isFinite) return formatMetric(seconds);
  if (seconds >= 60) return formatDuration(Duration(milliseconds: (seconds * 1000).round()));
  if (seconds >= 1) return '${formatCoordinate(seconds)} s';
  if (seconds >= 1e-3) return '${formatCoordinate(seconds * 1e3)} ms';
  return '${formatCoordinate(seconds * 1e6)} µs';
}

/// 0.913 -> "91.3%".
String formatPercent(double fraction) => '${(fraction * 100).toStringAsFixed(1)}%';

/// An axis tick label with just enough precision to tell ticks [interval]
/// apart: (2.5, 0.5) -> "2.5", (10, 5) -> "10", (1.5e-4, 5e-5) -> "1.5e-4",
/// (20000, 10000) -> "20k".
String formatAxisTick(double value, double interval) {
  if (value.abs() < interval * 1e-6) return '0';
  if (interval >= 1000) return formatCount(value);
  if (interval < 1e-3) {
    final digits = math.max(0, _exponent(value.abs()) - _exponent(interval));
    return value.toStringAsExponential(digits);
  }
  return value.toStringAsFixed(math.max(0, -_exponent(interval)));
}

/// A value already on a 0–100 scale: 87.2 -> "87%", 3.46 -> "3.5%".
String formatPercentValue(double value) =>
    '${value.toStringAsFixed(value.abs() < 10 && value != 0 ? 1 : 0)}%';

/// Axis ticks for [formatPercentValue]: (50, 25) -> "50%".
String formatPercentValueTick(double value, double interval) =>
    '${formatAxisTick(value, interval)}%';

/// Gigabytes: 61.234 -> "61.2 GB", 0.5 -> "0.50 GB", 1152 -> "1,152 GB".
String formatGb(double value) {
  if (value.abs() >= 1000) return '${formatInt(value.round())} GB';
  return '${value.toStringAsFixed(value.abs() < 10 ? 2 : 1)} GB';
}

/// Like [formatAxisTick], for fractions shown as percentages:
/// (0.4, 0.2) -> "40%", (0.95, 0.05) -> "95%", (0.925, 0.005) -> "92.5%".
String formatPercentAxisTick(double fraction, double interval) =>
    '${formatAxisTick(fraction * 100, interval * 100)}%';

/// A log-axis tick (1, 2 or 5 times a power of ten): 0.5 -> "0.5",
/// 2 -> "2", 0.002 -> "0.002", 5e-5 -> "5e-5", 20000 -> "20k".
String formatLogTick(double tick) {
  if (tick >= 1000) return formatCount(tick);
  if (tick >= 1e-3) {
    var text = tick.toStringAsFixed(3);
    if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
    return text;
  }
  return tick.toStringAsExponential(0);
}

/// Durations as "2d 4h", "3h 12m", "12m 5s" or "42s".
String formatDuration(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

/// "just now", "5m ago", "3h ago", "2d ago".
String formatTimeAgo(DateTime time, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(time);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Formats with one decimal and drops a trailing ".0": 23.0 -> "23", 9.4 -> "9.4".
String _trim(num value) {
  final s = value.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Power of ten of [value]: 0.05 -> -2, 1 -> 0, 250 -> 2. The epsilon keeps
/// exact powers of ten (whose logarithm is slightly off) on the right side.
int _exponent(double value) => (math.log(value) / math.ln10 + 1e-9).floor();
