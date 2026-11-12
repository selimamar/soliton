import 'package:flutter_test/flutter_test.dart';
import 'package:models_app/shared/axis_scale.dart';

void main() {
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
}
