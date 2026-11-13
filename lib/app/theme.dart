import 'package:material_ui/material_ui.dart';

import '../models/run.dart';

/// Light and dark Material 3 themes built from a single seed colour.
abstract final class AppTheme {
  static const seedColor = Color(0xFF3E63DD);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
    );
  }
}

/// Colours that carry the same meaning in every chart of the app.
abstract final class ChartColors {
  static const train = Color(0xFF378ADD);
  static const validation = Color(0xFFD85A30);
  static const accuracy = Color(0xFF1D9E75);
  static const learningRate = Color(0xFFBA7517);
  static const gradient = Color(0xFF7F77DD);
  static const activation = Color(0xFF1D9E75);
  static const other = Color(0xFF888780);

  /// One per run on the compare screen, in order.
  static const runs = [
    Color(0xFF378ADD),
    Color(0xFFD85A30),
    Color(0xFF1D9E75),
    Color(0xFF7F77DD),
    Color(0xFFBA7517),
    Color(0xFFD4537E),
  ];
}

/// Colour and label for each [RunStatus].
extension RunStatusStyle on RunStatus {
  String get label => switch (this) {
    RunStatus.live => 'Live',
    RunStatus.finished => 'Finished',
    RunStatus.crashed => 'Crashed',
  };

  /// Text and accent colour of the status. Chosen per brightness so small
  /// text keeps at least 4.5:1 contrast on its own tinted background
  /// (see `StatusChip`).
  Color color(ColorScheme scheme) => switch (this) {
    RunStatus.live =>
      scheme.brightness == Brightness.light ? const Color(0xFF0A6649) : const Color(0xFF6FDDB5),
    RunStatus.finished => scheme.onSurfaceVariant,
    RunStatus.crashed => scheme.error,
  };
}
