import 'package:flutter_test/flutter_test.dart';
import 'package:models_app/shared/formatters.dart';

void main() {
  test('formatCount', () {
    expect(formatCount(512), '512');
    expect(formatCount(9408), '9.4k');
    expect(formatCount(23500000), '23.5M');
    expect(formatCount(2000000000), '2B');
  });

  test('formatCount promotes to the next unit instead of printing 1000', () {
    expect(formatCount(999), '999');
    expect(formatCount(999.4), '999');
    expect(formatCount(999.5), '1k');
    expect(formatCount(999949), '999.9k');
    expect(formatCount(999950), '1M');
    expect(formatCount(999999), '1M');
    expect(formatCount(999999999), '1B');
    expect(formatCount(-999999), '-1M');
  });

  test('formatInt', () {
    expect(formatInt(0), '0');
    expect(formatInt(999), '999');
    expect(formatInt(8232), '8,232');
    expect(formatInt(1234567), '1,234,567');
    expect(formatInt(-4500), '-4,500');
  });

  test('formatMetric', () {
    expect(formatMetric(0.41234), '0.412');
    expect(formatMetric(0.0003), '3.0e-4');
    expect(formatMetric(123.456), '123.5');
    expect(formatMetric(double.nan), 'NaN');
    expect(formatMetric(double.infinity), '∞');
    expect(formatMetric(double.negativeInfinity), '-∞');
    expect(formatMetric(0), '0');
  });

  test('formatMetric switches precision where rounding would overflow', () {
    expect(formatMetric(9.9994), '9.999');
    expect(formatMetric(9.9996), '10.0');
    expect(formatMetric(999.94), '999.9');
    expect(formatMetric(999.97), '1k');
    expect(formatMetric(52000), '52k');
  });

  test('formatPercent', () {
    expect(formatPercent(0.913), '91.3%');
    expect(formatPercent(0), '0.0%');
    expect(formatPercent(1), '100.0%');
  });

  test('formatAxisTick uses the precision of the tick interval', () {
    expect(formatAxisTick(0, 5), '0');
    expect(formatAxisTick(1e-12, 0.5), '0');
    expect(formatAxisTick(10, 5), '10');
    expect(formatAxisTick(2.5, 0.5), '2.5');
    expect(formatAxisTick(0.3, 0.1), '0.3');
    expect(formatAxisTick(0.30000000000000004, 0.1), '0.3');
    expect(formatAxisTick(0.004, 0.002), '0.004');
    expect(formatAxisTick(3e-4, 1e-4), '3e-4');
    expect(formatAxisTick(1.5e-4, 5e-5), '1.5e-4');
    expect(formatAxisTick(20000, 10000), '20k');
    expect(formatAxisTick(2500, 500), '2500');
  });

  test('formatPercentAxisTick', () {
    expect(formatPercentAxisTick(0.4, 0.2), '40%');
    expect(formatPercentAxisTick(0.95, 0.05), '95%');
    expect(formatPercentAxisTick(0.925, 0.005), '92.5%');
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 42)), '42s');
    expect(formatDuration(const Duration(minutes: 12, seconds: 5)), '12m 5s');
    expect(formatDuration(const Duration(hours: 3, minutes: 12)), '3h 12m');
    expect(formatDuration(const Duration(days: 2, hours: 4)), '2d 4h');
  });

  test('formatTimeAgo', () {
    final now = DateTime(2026, 11, 11, 12);
    expect(formatTimeAgo(now.subtract(const Duration(seconds: 30)), now: now), 'just now');
    expect(formatTimeAgo(now.subtract(const Duration(minutes: 5)), now: now), '5m ago');
    expect(formatTimeAgo(now.subtract(const Duration(hours: 3)), now: now), '3h ago');
    expect(formatTimeAgo(now.subtract(const Duration(days: 2)), now: now), '2d ago');
  });
}
