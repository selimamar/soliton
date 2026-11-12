/// Equality and JSON helpers shared by the model classes.
///
/// Kept here (rather than using Flutter's `listEquals` or
/// `package:collection`) so the models stay plain Dart.
library;

/// Element-wise equality of two lists.
bool deepListEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Entry-wise equality of two maps (order is ignored).
bool deepMapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Like `==`, but NaN equals NaN. Logged metrics can be NaN, and two copies
/// of the same data should compare equal.
bool sameDouble(double a, double b) => a == b || (a.isNaN && b.isNaN);

/// Element-wise [sameDouble] of two lists.
bool sameDoubles(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!sameDouble(a[i], b[i])) return false;
  }
  return true;
}

/// A hash consistent with [sameDouble].
int doubleHash(double value) => value.isNaN ? 0 : value.hashCode;

/// JSON has no NaN or infinity, so those travel as the strings
/// `"NaN"`, `"Infinity"` and `"-Infinity"`.
Object encodeDouble(double value) {
  if (value.isNaN) return 'NaN';
  if (value == double.infinity) return 'Infinity';
  if (value == double.negativeInfinity) return '-Infinity';
  return value;
}

/// Reverses [encodeDouble].
double decodeDouble(Object? json) => switch (json) {
  num() => json.toDouble(),
  'NaN' => double.nan,
  'Infinity' => double.infinity,
  '-Infinity' => double.negativeInfinity,
  _ => throw FormatException('Not a number: $json'),
};
