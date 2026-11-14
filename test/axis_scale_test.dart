import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/shared/axis_scale.dart';

void main() {
  test('smallerNiceInterval steps down 5, 2, 1, keeping ticks round', () {
    expect(smallerNiceInterval(50), 20);
    expect(smallerNiceInterval(5), 2);
    expect(smallerNiceInterval(2), 1);
    expect(smallerNiceInterval(1), 0.5);
    expect(smallerNiceInterval(0.5), closeTo(0.2, 1e-12));
  });

  test('niceInterval rounds up to 1, 2 or 5 times a power of ten', () {
    expect(niceInterval(1), 1);
    expect(niceInterval(1.2), 2);
    expect(niceInterval(3), 5);
    expect(niceInterval(7), 10);
    expect(niceInterval(0.37), closeTo(0.5, 1e-12));
    expect(niceInterval(0.00023), closeTo(0.0005, 1e-15));
    expect(niceInterval(3600), 5000);
  });

  test('niceAxis covers the data with round bounds', () {
    final axis = niceAxis(0.25, 14.7);
    expect(axis.interval, 5);
    expect(axis.min, 0);
    expect(axis.max, 15);
  });

  test('niceAxis handles negative and tiny ranges', () {
    final negative = niceAxis(-3.2, 7.9);
    expect(negative.min, lessThanOrEqualTo(-3.2));
    expect(negative.max, greaterThanOrEqualTo(7.9));
    expect(negative.interval, 5);

    final tiny = niceAxis(1e-5, 3e-4);
    expect(tiny.interval, closeTo(1e-4, 1e-15));
    expect(tiny.min, 0);
    expect(tiny.max, closeTo(3e-4, 1e-15));
  });

  test('niceAxis opens up a flat line', () {
    final flat = niceAxis(2, 2);
    expect(flat.min, lessThan(2));
    expect(flat.max, greaterThan(2));

    final zero = niceAxis(0, 0);
    expect(zero.min, lessThan(0));
    expect(zero.max, greaterThan(0));
  });

  test('niceAxis accepts swapped bounds', () {
    expect(niceAxis(10, 0), niceAxis(0, 10));
  });

  group('logAxis', () {
    test('a loss from 2.3 to 0.25 gets 1-2-5 ticks', () {
      final axis = logAxis(0.25, 2.3);
      expect(axis.min, closeTo(0.2, 1e-12));
      expect(axis.max, closeTo(5, 1e-12));
      expect(axis.ticks.map((t) => double.parse(t.toStringAsPrecision(6))), [0.2, 0.5, 1, 2, 5]);
    });

    test('wide ranges only tick powers of ten', () {
      final axis = logAxis(0.003, 40);
      expect(axis.ticks.map((t) => double.parse(t.toStringAsPrecision(6))), [
        0.001,
        0.01,
        0.1,
        1,
        10,
        100,
      ]);
    });

    test('very wide ranges skip powers of ten, keeping about six ticks', () {
      final axis = logAxis(3e-12, 5e3);
      expect(axis.ticks.length, lessThanOrEqualTo(8));
      expect(axis.min, lessThanOrEqualTo(3e-12));
      expect(axis.max, greaterThanOrEqualTo(5e3));
    });

    test('a flat line opens up to the neighbouring ticks', () {
      final axis = logAxis(1, 1);
      expect(axis.min, lessThan(1));
      expect(axis.max, greaterThan(1));
    });
  });
}
